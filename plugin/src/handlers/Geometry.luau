--!strict
--[[
	Solid modelling: union, subtract, intersect, fragment.

	`GeometryService` is the modern replacement for the old `BasePart:UnionAsync`
	pair, and nothing else in this space exposes it. It is how a shape that is
	not a box gets built without importing a mesh: cut a doorway out of a wall,
	round a corner off a platform, punch windows through a facade.

	Every operation returns *new* parts rather than editing in place, and the
	originals are left alone unless the caller asks for them to go. That is the
	engine's design and it is worth preserving: a subtraction that silently ate
	its inputs would make an unwanted result unrecoverable.

	The results carry the source part's appearance. Roblox hands back bare
	MeshParts with default material and colour, which for a wall cut from brick
	produces a grey slab where a brick wall was -- correct geometry that looks
	like a mistake, and the sort of thing a caller then has to notice and fix.
]]

local GeometryService = game:GetService("GeometryService")

local Dispatch = require(script.Parent.Parent.Dispatch)
local Paths = require(script.Parent.Parent.Paths)
local Undo = require(script.Parent.Parent.Undo)

local Geometry = {}

-- Appearance carried from the source part onto every result.
local CARRIED = {
	"Material", "Color", "Transparency", "Reflectance", "CastShadow",
	"Anchored", "CanCollide", "CanTouch", "CanQuery", "CollisionGroup",
}

local OPERATIONS: { [string]: string } = {
	union = "UnionAsync",
	subtract = "SubtractAsync",
	intersect = "IntersectAsync",
}

--[[
	Copies the look of the original onto a result.

	Guarded per property: the results are MeshParts and the source may be any
	BasePart, so a property that does not exist on one of them should cost that
	property rather than the whole operation.
]]
local function carryAppearance(source: BasePart, target: BasePart)
	for _, property in CARRIED do
		pcall(function()
			(target :: any)[property] = (source :: any)[property]
		end)
	end
end

local function parseVector(text: any): Vector3?
	if typeof(text) ~= "string" or text == "" then
		return nil
	end
	local x, y, z = string.match(text, "^%s*(-?[%d%.]+)%s*,%s*(-?[%d%.]+)%s*,%s*(-?[%d%.]+)%s*$")
	if x == nil then
		return nil
	end
	return Vector3.new(tonumber(x) :: number, tonumber(y) :: number, tonumber(z) :: number)
end

local function resolveParts(paths: any, what: string): { BasePart }
	if typeof(paths) ~= "table" or #(paths :: { any }) == 0 then
		Dispatch.fail("BAD_PARAMS", string.format("geometry needs %s.", what))
	end
	local parts: { BasePart } = {}
	for _, path in paths :: { string } do
		local instance = Paths.resolve(path)
		if not instance:IsA("BasePart") then
			Dispatch.fail(
				"NOT_A_PART",
				string.format("%s is a %s, not a part.", path, instance.ClassName)
			)
		end
		table.insert(parts, instance :: BasePart)
	end
	return parts
end

function Geometry.combine(params: { [string]: any }): { [string]: any }
	local op = tostring(params.op or "union")
	local method = OPERATIONS[op]
	if method == nil then
		Dispatch.fail("BAD_PARAMS", string.format("unknown geometry op %q", op))
	end

	local subject = resolveParts({ params.path }, "a `path`")[1]
	local others = resolveParts(params.with, "a `with` list of parts")

	-- CollisionFidelity defaults to Default rather than Precise: precise
	-- collision on a heavily-cut mesh is expensive, and a caller who needs it
	-- for a walkable surface can say so.
	local options = {
		CollisionFidelity = Enum.CollisionFidelity[tostring(params.collisionFidelity or "Default")]
			or Enum.CollisionFidelity.Default,
		RenderFidelity = Enum.RenderFidelity[tostring(params.renderFidelity or "Automatic")]
			or Enum.RenderFidelity.Automatic,
		SplitApart = params.splitApart == true,
	}

	local ok, results = pcall(function()
		return (GeometryService :: any)[method](GeometryService, subject, others, options)
	end)
	if not ok then
		Dispatch.fail(
			"GEOMETRY_FAILED",
			string.format("%s refused: %s", method, tostring(results)),
			"Parts must overlap for subtract and intersect to produce anything."
		)
	end

	-- Same unwrapping guard as fragment, for the same reason: these three do
	-- return parts directly today, but nothing documents that, and the cost of
	-- being wrong is destroying the inputs and creating nothing.
	local produced: { BasePart } = {}
	for _, entry in results :: { any } do
		local instance = if typeof(entry) == "table" then (entry :: any).Instance else entry
		if typeof(instance) == "Instance" and (instance :: Instance):IsA("BasePart") then
			table.insert(produced, instance :: BasePart)
		end
	end

	if #produced == 0 then
		-- Not an error at the API level, but almost never what was wanted: it
		-- means the solids did not overlap the way the caller assumed.
		Dispatch.fail(
			"EMPTY_RESULT",
			string.format("%s produced no parts.", op),
			"The parts probably do not overlap. Check their positions with `inspect`."
		)
	end

	local parent = if typeof(params.parent) == "string" and params.parent ~= ""
		then Paths.resolve(params.parent)
		else subject.Parent

	local created: { string } = {}
	local removed: { string } = {}

	local _, undoable = Undo.record("MCPGeometry", "MCP " .. op, function()
		for index, part in produced do
			carryAppearance(subject, part)
			part.Name = if typeof(params.name) == "string" and params.name ~= ""
				then (if #produced == 1 then params.name else string.format("%s%d", params.name, index))
				else subject.Name
			part.Parent = parent
		end

		-- Removing the inputs is opt-in, and only once the results exist: an
		-- operation that destroyed them first and then failed would leave
		-- nothing to recover.
		if params.keepOriginals ~= true then
			for _, part in { subject, table.unpack(others) } do
				table.insert(removed, Paths.of(part))
				part:Destroy()
			end
		end

		--[[
			Paths for the produced parts are read only now, after the originals
			are gone rather than in the loop above that named and parented them.

			A result keeps the subject's name by default, so for the entire
			window before the destroy above runs, the new part and the subject
			it was built from are two same-named siblings in the same parent --
			and Paths.of correctly, but uselessly, disambiguates that with a
			`[2]` suffix that stops being true the instant the destroy runs a
			few lines later. The caller reads this path after the call returns,
			by which point the disambiguation was already wrong. Reading it here
			instead describes where the part actually is once nothing further
			in this function is going to move or remove anything -- correct
			whether or not `keepOriginals` left a real, permanent collision for
			it to still be disambiguating.
		]]
		for _, part in produced do
			table.insert(created, Paths.of(part))
		end
	end)

	return { created = created, removed = removed, undoable = undoable }
end

--[[
	Breaks a part into pieces, for destruction and debris.

	Sites are where the fractures radiate from. Left unspecified the engine
	picks them, which is what most callers want; naming them is for aiming a
	break at a point of impact.
]]
function Geometry.fragment(params: { [string]: any }): { [string]: any }
	local subject = resolveParts({ params.path }, "a `path`")[1]
	local count = math.clamp(tonumber(params.pieces) or 8, 2, 100)

	local sites: { Vector3 } = {}
	local okSites, generated = pcall(function()
		return (GeometryService :: any):GenerateFragmentSites(subject, { Count = count })
	end)
	if okSites and typeof(generated) == "table" then
		sites = generated :: { Vector3 }
	else
		-- Fall back to points scattered inside the part's own volume, so a
		-- missing helper costs randomness rather than the whole feature.
		for _ = 1, count do
			table.insert(
				sites,
				subject.Position
					+ Vector3.new(
						(math.random() - 0.5) * subject.Size.X,
						(math.random() - 0.5) * subject.Size.Y,
						(math.random() - 0.5) * subject.Size.Z
					)
			)
		end
	end

	local ok, results = pcall(function()
		return (GeometryService :: any):FragmentAsync(subject, sites, {})
	end)
	if not ok then
		Dispatch.fail("GEOMETRY_FAILED", string.format("FragmentAsync refused: %s", tostring(results)))
	end

	--[[
		`FragmentAsync` does not return parts. It returns wrappers:

			{ Index = 1, Instance = MeshPart }

		which is unlike `UnionAsync` and its siblings, which hand back the parts
		themselves. Reading them as parts is silently destructive rather than
		merely wrong, and this file did exactly that: `piece.Parent = folder` set
		a key on a Lua table, changing nothing in the data model, while
		`Paths.of` then walked that table's freshly-assigned `Name` and `Parent`
		fields and produced a completely plausible path -- so the call reported
		eight new parts by name, created none of them, and destroyed the
		original. Measured, after the pieces failed to appear in a tree listing.

		Hence the check below rather than a cast: this shape is undocumented, so
		the next engine update changing it should stop the tool loudly instead of
		eating someone's geometry again.
	]]
	local produced: { BasePart } = {}
	for _, entry in results :: { any } do
		local instance = if typeof(entry) == "table" then (entry :: any).Instance else entry
		if typeof(instance) == "Instance" and (instance :: Instance):IsA("BasePart") then
			table.insert(produced, instance :: BasePart)
		end
	end

	if #produced == 0 then
		-- Refused before the subject is touched, so a shape this file no longer
		-- understands costs the operation and not the part.
		Dispatch.fail(
			"GEOMETRY_FAILED",
			string.format(
				"FragmentAsync returned %d result(s) but none were parts this version understands.",
				#(results :: { any })
			),
			"The original is untouched. This usually means the engine's return shape changed."
		)
	end
	local parent = subject.Parent
	local created: { string } = {}

	local _, undoable = Undo.record("MCPFragment", "MCP fragment", function()
		for index, part in produced do
			carryAppearance(subject, part)
			part.Name = string.format("%s_%d", subject.Name, index)
			part.Parent = parent
			table.insert(created, Paths.of(part))
		end
		if params.keepOriginals ~= true then
			subject:Destroy()
		end
	end)

	return { created = created, pieces = #produced, undoable = undoable }
end

--[[
	Builds the motion to sweep along, as a list of CFrames.

	Three ways to say it, in the order they are checked. `positions` is the
	escape hatch; `to` is a slide; `spin` is a hinge, which is the case worth
	having -- a door, a hatch, a drawbridge. All three are sampled rather than
	solved, so `steps` trades accuracy for time: the volume is the hull of the
	samples, and too few of them on a wide arc cuts the corners off the swing.
]]
local function motionOf(subject: BasePart, params: { [string]: any }): { CFrame }
	local start = subject.CFrame
	local steps = math.clamp(tonumber(params.steps) or 12, 2, 64)

	local positions = params.positions
	if typeof(positions) == "table" and #(positions :: { any }) > 0 then
		local frames: { CFrame } = {}
		for _, entry in positions :: { any } do
			local at = parseVector(entry)
			if at == nil then
				Dispatch.fail("BAD_PARAMS", string.format("%q is not an \"x, y, z\" position.", tostring(entry)))
			end
			table.insert(frames, start.Rotation + (at :: Vector3))
		end
		return frames
	end

	local spin = tonumber(params.spin)
	if spin ~= nil and spin ~= 0 then
		local axis = parseVector(params.axis) or Vector3.yAxis
		if axis.Magnitude == 0 then
			Dispatch.fail("BAD_PARAMS", "`axis` cannot be zero.")
		end
		-- The pivot is the hinge. Defaulting it to the part's own centre makes
		-- the part spin in place, which is right for a wheel and wrong for a
		-- door -- so a door has to name its hinge edge.
		local pivot = parseVector(params.pivot) or subject.Position
		local frames: { CFrame } = {}
		for index = 0, steps - 1 do
			local angle = math.rad(spin) * (index / (steps - 1))
			local turn = CFrame.fromAxisAngle(axis.Unit, angle)
			table.insert(frames, CFrame.new(pivot) * turn * CFrame.new(-pivot) * start)
		end
		return frames
	end

	local destination = parseVector(params.to)
	if destination == nil then
		Dispatch.fail(
			"BAD_PARAMS",
			"sweep needs a motion.",
			"Give `to` for a slide, `spin` (with `pivot`) for a hinge, or `positions` for a path."
		)
	end

	local frames: { CFrame } = {}
	for index = 0, steps - 1 do
		local alpha = index / (steps - 1)
		table.insert(frames, start:Lerp(start.Rotation + (destination :: Vector3), alpha))
	end
	return frames
end

--[[
	The volume a part passes through as it moves.

	The question this answers -- "does the door hit the wall when it opens" --
	has no good answer from the data model. Positions and sizes describe where
	things are, not where something will be on its way somewhere else, and the
	usual workaround is to move the part in steps and test at each one, which
	misses anything thin enough to sit between two samples.

	`checkAgainst` is why this is worth calling rather than just building the
	volume: the swept solid is put in the world for a moment and asked what it
	overlaps. Left on (`keep`) it stays as a part; turned off it is destroyed
	once measured, so a clearance check leaves nothing behind.
]]
function Geometry.sweep(params: { [string]: any }): { [string]: any }
	local subject = resolveParts({ params.path }, "a `path`")[1]
	local frames = motionOf(subject, params)

	local ok, volume = pcall(function()
		return (GeometryService :: any):SweepPartAsync(subject, frames, {
			CollisionFidelity = Enum.CollisionFidelity[tostring(params.collisionFidelity or "Default")]
				or Enum.CollisionFidelity.Default,
		})
	end)
	if not ok or typeof(volume) ~= "Instance" then
		Dispatch.fail(
			"GEOMETRY_FAILED",
			string.format("SweepPartAsync refused: %s", tostring(volume)),
			"The part must be a solid Studio can sweep. Terrain and some mesh shapes are refused."
		)
	end

	local swept = volume :: BasePart
	local parent = if typeof(params.parent) == "string" and params.parent ~= ""
		then Paths.resolve(params.parent)
		else subject.Parent
	local keep = params.keep ~= false

	local hits: { string } = {}
	local path = ""

	local _, undoable = Undo.record("MCPSweep", "MCP sweep", function()
		carryAppearance(subject, swept)
		swept.Name = if typeof(params.name) == "string" and params.name ~= ""
			then params.name
			else subject.Name .. "_Sweep"
		swept.Anchored = true
		swept.CanCollide = false
		swept.Transparency = tonumber(params.transparency) or 0.5
		swept.Parent = parent

		--[[
			Measured while the volume is in the world, because that is the only
			state the spatial query can read. The subject is excluded: a part
			always overlaps its own swept volume, and reporting that would bury
			the answer under the one hit nobody asked about.
		]]
		local against = params.checkAgainst
		if against ~= nil then
			local overlap = OverlapParams.new()
			overlap.MaxParts = 100
			local named = if typeof(against) == "table" then against :: { any } else {}
			if #named > 0 then
				-- A named list is the question "does it hit THESE", so anything
				-- else in the way is not an answer.
				local only, _missing = Paths.resolveMany(named :: { string })
				overlap.FilterType = Enum.RaycastFilterType.Include
				overlap.FilterDescendantsInstances = only
			else
				overlap.FilterType = Enum.RaycastFilterType.Exclude
				overlap.FilterDescendantsInstances = { subject, swept }
			end
			for _, found in workspace:GetPartsInPart(swept, overlap) do
				if found ~= subject and found ~= swept then
					table.insert(hits, Paths.of(found))
				end
			end
		end

		if keep then
			path = Paths.of(swept)
		else
			swept:Destroy()
		end
	end)

	return {
		created = if keep then { path } else {},
		hits = hits,
		checked = params.checkAgainst ~= nil,
		frames = #frames,
		kept = keep,
		undoable = undoable,
	}
end

function Geometry.register()
	Dispatch.registerAll("geometry", {
		combine = Geometry.combine,
		fragment = Geometry.fragment,
		sweep = Geometry.sweep,
	})
end

return Geometry
