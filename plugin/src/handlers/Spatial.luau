--!strict
--[[
	Spatial queries: casts, and "what is in this box".

	These answer the one question the Explorer cannot: what is actually THERE.
	A path tells you an instance exists and where its own pivot sits; it does not
	tell you that the door frame overlaps the wall, that the spawn is buried a
	stud inside the floor, or that nothing at all stands between the turret and
	the player. Every one of those is a query against the world, and before this
	the only way to run one was `execute_luau`.

	All of it goes through a WorldRoot rather than through `workspace` directly,
	for the same reason collision groups do: a `WorldModel` inside a ViewportFrame
	is its own world with its own parts and its own collision groups, and a query
	hard-coded to the Workspace can only ever lie about it.

	The `collisionGroup` field is the point of doing this now. Roblox moved
	collision group management onto WorldRoot in September 2026, and spatial
	queries inside a WorldModel now honour groups the way Workspace always has.
	A cast run in the wrong group reports a clear path through a wall the player
	cannot walk through -- a wrong answer that looks exactly like a right one.
]]

local Workspace = game:GetService("Workspace")

local Dispatch = require(script.Parent.Parent.Dispatch)
local Paths = require(script.Parent.Parent.Paths)
local Serialize = require(script.Parent.Parent.Serialize)

local Spatial = {}

-- A query that returns every part in a large place is not an answer, it is a
-- transcript. Callers narrow with `filter` or raise this deliberately.
local DEFAULT_LIMIT = 50
local MAX_LIMIT = 500

--[[
	Which world the query runs in. Same rule as collision groups: the Workspace
	unless a WorldModel is named, and anything that is not a WorldRoot is refused
	by name rather than left to fail inside the engine call.
]]
local function root(params: { [string]: any }): Instance
	local path = params.worldModel
	if typeof(path) ~= "string" or path == "" then
		return Workspace
	end

	local instance = Paths.resolve(path)
	if not instance:IsA("WorldRoot") then
		Dispatch.fail(
			"BAD_PARAMS",
			string.format("%s is a %s, not a WorldModel.", path, instance.ClassName),
			"Spatial queries run on a WorldRoot: the Workspace, or a WorldModel "
				.. "inside a ViewportFrame. Omit `worldModel` for the Workspace."
		)
	end
	return instance
end

local function vector(value: any, field: string): Vector3
	if typeof(value) == "table" then
		local list = value :: { any }
		local x, y, z = tonumber(list[1]), tonumber(list[2]), tonumber(list[3])
		if x and y and z then
			return Vector3.new(x, y, z)
		end
	end
	if typeof(value) == "string" then
		local ok, parsed = Serialize.parse(value, "Vector3")
		if ok and typeof(parsed) == "Vector3" then
			return parsed
		end
	end
	Dispatch.fail(
		"BAD_PARAMS",
		string.format("`%s` is not a position.", field),
		'Write it the way the Properties panel does: "12, 0, 5".'
	)
	error("unreachable")
end

local function optionalVector(value: any, field: string): Vector3?
	if value == nil or value == "" then
		return nil
	end
	return vector(value, field)
end

--[[
	Builds the filter every query shares.

	`ignore` and `only` are the same engine field with the list flipped, because
	"everything except the character" and "only the doors" are both common and
	only one of them is expressible at a time. Naming a path that no longer
	exists is a caller mistake worth reporting: silently querying against an
	empty filter gives a plausible answer to the wrong question.
]]
local function buildParams(params: { [string]: any }): RaycastParams
	local query = RaycastParams.new()

	local list = params.only or params.ignore
	if list ~= nil then
		if typeof(list) ~= "table" then
			Dispatch.fail("BAD_PARAMS", "`ignore` and `only` take a list of paths.")
		end
		local resolved, missing = Paths.resolveMany(list :: { string })
		if #missing > 0 then
			Dispatch.fail(
				"NOT_FOUND",
				string.format("Could not resolve: %s", table.concat(missing, ", "))
			)
		end
		query.FilterDescendantsInstances = resolved
		query.FilterType = if params.only ~= nil
			then Enum.RaycastFilterType.Include
			else Enum.RaycastFilterType.Exclude
	end

	if typeof(params.collisionGroup) == "string" and params.collisionGroup ~= "" then
		query.CollisionGroup = params.collisionGroup
	end
	-- Off by default, matching the engine. A caller asking "can the player see
	-- the exit" usually does want water ignored; one asking "what is here" does
	-- not, and neither can be guessed.
	query.RespectCanCollide = params.respectCanCollide == true
	query.IgnoreWater = params.ignoreWater == true
	query.BruteForceAllSlow = false
	return query
end

local function describeHit(result: RaycastResult, origin: Vector3): { [string]: any }
	return {
		path = Paths.of(result.Instance),
		class = result.Instance.ClassName,
		position = Serialize.value(result.Position),
		normal = Serialize.value(result.Normal),
		material = tostring(result.Material):gsub("Enum%.Material%.", ""),
		distance = math.round((result.Position - origin).Magnitude * 100) / 100,
	}
end

local function describePart(part: BasePart): { [string]: any }
	return {
		path = Paths.of(part),
		class = part.ClassName,
		position = Serialize.value(part.Position),
		size = Serialize.value(part.Size),
		collisionGroup = part.CollisionGroup,
		canCollide = part.CanCollide,
	}
end

--[[
	Casts a ray, a block or a sphere.

	The three are one operation with one extra argument, and the engine treats
	them that way too -- `Blockcast` and `Spherecast` take the same params and
	return the same RaycastResult. Splitting them into three handlers would only
	mean three copies of the filter code.

	A miss is reported as `hit = false` with the distance travelled, not as an
	error and not as an empty object. "Nothing is in the way" is a real answer
	and usually the one being checked for.
]]
function Spatial.cast(params: { [string]: any }): { [string]: any }
	local world = root(params) :: WorldRoot
	local shape = tostring(params.shape or "ray")

	local origin = vector(params.from, "from")

	--[[
		Direction is given either as a target point or as a vector, because both
		are natural and they are not interchangeable. "Can the turret see the
		player" is two positions; "is there ground below" is a direction and a
		distance. Taking only one of them forces the caller to do vector maths
		in the prompt, which is exactly where an off-by-one sign lives.
	]]
	local direction: Vector3
	local to = optionalVector(params.to, "to")
	if to then
		direction = to - origin
	else
		local towards = optionalVector(params.direction, "direction")
		if not towards then
			Dispatch.fail(
				"BAD_PARAMS",
				"A cast needs somewhere to go.",
				"Give `to` for a point to aim at, or `direction` plus `distance`."
			)
			error("unreachable")
		end
		local distance = tonumber(params.distance) or 100
		direction = towards.Unit * distance
	end

	local query = buildParams(params)
	local result: RaycastResult?

	if shape == "ray" then
		result = world:Raycast(origin, direction, query)
	elseif shape == "block" then
		local size = optionalVector(params.size, "size") or Vector3.new(1, 1, 1)
		result = world:Blockcast(CFrame.new(origin), size, direction, query)
	elseif shape == "sphere" then
		local radius = tonumber(params.radius) or 1
		result = world:Spherecast(origin, radius, direction, query)
	else
		Dispatch.fail(
			"BAD_PARAMS",
			string.format("unknown cast shape %q", shape),
			'Use "ray", "block" or "sphere".'
		)
	end

	if not result then
		return {
			hit = false,
			shape = shape,
			from = Serialize.value(origin),
			travelled = math.round(direction.Magnitude * 100) / 100,
			world = Paths.of(world),
			note = "Nothing was in the way for the whole length of the cast.",
		}
	end

	local hit = describeHit(result, origin)
	hit.hit = true
	hit.shape = shape
	hit.from = Serialize.value(origin)
	hit.world = Paths.of(world)
	return hit
end

--[[
	Everything inside a volume.

	`part` is the one worth reaching for on a build: it takes an existing part
	and reports what overlaps it, which answers "is this door clipping the wall"
	directly rather than by reconstructing the door's bounds by hand.
]]
function Spatial.overlap(params: { [string]: any }): { [string]: any }
	local world = root(params) :: WorldRoot
	local region = tostring(params.region or "box")
	local limit = math.clamp(tonumber(params.limit) or DEFAULT_LIMIT, 1, MAX_LIMIT)

	local overlap = OverlapParams.new()
	local query = buildParams(params)
	overlap.FilterDescendantsInstances = query.FilterDescendantsInstances
	overlap.FilterType = query.FilterType
	overlap.CollisionGroup = query.CollisionGroup
	overlap.RespectCanCollide = query.RespectCanCollide
	-- Asked for one over the limit so the response can say whether the list was
	-- cut, instead of a caller reading exactly 50 as "there are 50".
	overlap.MaxParts = limit + 1

	local found: { BasePart }
	local about: { [string]: any } = {}

	if region == "box" then
		local centre = vector(params.at, "at")
		local size = optionalVector(params.size, "size") or Vector3.new(4, 4, 4)
		found = world:GetPartBoundsInBox(CFrame.new(centre), size, overlap)
		about.at, about.size = Serialize.value(centre), Serialize.value(size)
	elseif region == "radius" then
		local centre = vector(params.at, "at")
		local radius = tonumber(params.radius) or 4
		found = world:GetPartBoundsInRadius(centre, radius, overlap)
		about.at, about.radius = Serialize.value(centre), radius
	elseif region == "part" then
		local path = params.path
		if typeof(path) ~= "string" or path == "" then
			Dispatch.fail("BAD_PARAMS", 'region="part" needs `path`, the part to test.')
		end
		local instance = Paths.resolve(path)
		if not instance:IsA("BasePart") then
			Dispatch.fail(
				"BAD_PARAMS",
				string.format("%s is a %s, not a part.", path, instance.ClassName)
			)
		end
		local subject = instance :: BasePart
		--[[
			The subject always overlaps itself, and a caller who asked what
			touches a door does not mean the door. Added to the filter rather
			than stripped from the results, so it does not eat one of the slots
			the limit allows.
		]]
		if overlap.FilterType == Enum.RaycastFilterType.Exclude then
			local excluded = overlap.FilterDescendantsInstances
			table.insert(excluded, subject)
			overlap.FilterDescendantsInstances = excluded
		end
		found = world:GetPartsInPart(subject, overlap)
		about.path = Paths.of(subject)
	else
		Dispatch.fail(
			"BAD_PARAMS",
			string.format("unknown region %q", region),
			'Use "box", "radius" or "part".'
		)
		error("unreachable")
	end

	local truncated = #found > limit
	local items: { { [string]: any } } = {}
	for index, part in found do
		if index > limit then
			break
		end
		table.insert(items, describePart(part))
	end

	about.region = region
	about.items = items
	about.count = #items
	about.truncated = truncated
	about.world = Paths.of(world)
	if truncated then
		about.note = string.format(
			"More than %d parts are in this volume; raise `limit` or narrow with `only`.",
			limit
		)
	end
	return about
end

function Spatial.register()
	Dispatch.registerAll("spatial", {
		cast = Spatial.cast,
		overlap = Spatial.overlap,
	})
end

return Spatial
