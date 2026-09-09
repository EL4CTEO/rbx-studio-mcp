--!strict
--[[
	Terrain: the one category of Roblox building this server could not touch.

	Everything else here addresses instances by path, because everything else IS
	an instance. Terrain is not: it is a voxel field owned by one object, with no
	children to name and no properties to set. An agent asked for a hill had
	exactly one route -- `execute_luau` with hand-written FillBall calls -- which
	is the escape hatch, so it carried no validation, no undo grouping, and no
	way to report what it had actually done.

	The shapes are Roblox's own: block, ball, cylinder and wedge, plus a region
	fill and a material swap. That is deliberately the whole surface. Voxel-level
	writes (`WriteVoxels`, the `_beta` buffer APIs) would multiply the schema for
	a capability an agent cannot use well -- reasoning about a raw occupancy grid
	over a round trip is not something to encourage -- and the four solids
	compose into everything people actually ask for.

	Every write is one undo step. Terrain edits are large and destructive by
	nature: filling a region the wrong size is not a typo you spot in a diff, it
	is a landscape you have to get back, and Ctrl+Z is how.
]]

local Workspace = game:GetService("Workspace")

local Dispatch = require(script.Parent.Parent.Dispatch)
local Serialize = require(script.Parent.Parent.Serialize)
local Undo = require(script.Parent.Parent.Undo)

local Terrain = {}

--[[
	Voxels are 4 studs, always.

	`FillRegion` and `ReadVoxels` take a resolution argument, and 4 is the only
	value the engine accepts -- anything else throws. It is a parameter for
	forward compatibility rather than a choice, so it is not exposed: an agent
	given the knob would spend calls discovering that.
]]
local RESOLUTION = 4

--[[
	How many voxels one call may touch.

	A region is a volume, so a request three times too large in each axis is
	twenty-seven times the work, and Studio does not stream that -- it blocks.
	Past this the call is refused with the number it would have written, which
	is more useful than a Studio that stops responding for a minute.
]]
local MAX_VOXELS = 4_000_000

local function terrain(): Terrain
	local found = Workspace:FindFirstChildOfClass("Terrain")
	if found == nil then
		Dispatch.fail(
			"NO_TERRAIN",
			"This place has no Terrain object.",
			"Terrain is created with the place; a place saved without it cannot be filled."
		)
	end
	return found :: Terrain
end

--[[
	Reads a required value out of the request, coercing it the way every other
	tool does.

	`Serialize.parse` is the same path `create` and `modify` use, so "0, 50, 0",
	"Enum.Material.Grass" and "Grass" all mean here exactly what they mean
	there. A terrain tool that accepted a different spelling of Vector3 than the
	rest of the server would be a small, permanent tax on everyone using it.
]]
local function need(params: { [string]: any }, field: string, valueType: string): any
	local raw = params[field]
	if raw == nil then
		Dispatch.fail("BAD_PARAMS", string.format("`%s` is required.", field))
	end
	local ok, value, why = Serialize.parse(raw, valueType)
	if not ok then
		Dispatch.fail(
			"BAD_PARAMS",
			string.format("`%s` is not a %s: %s", field, valueType, tostring(why))
		)
	end
	return value
end

local function optionalNumber(params: { [string]: any }, field: string, fallback: number): number
	local raw = params[field]
	if raw == nil then
		return fallback
	end
	local value = tonumber(raw)
	if value == nil then
		Dispatch.fail("BAD_PARAMS", string.format("`%s` must be a number.", field))
	end
	return value :: number
end

--[[
	A CFrame from a position and an optional orientation in degrees.

	Terrain's fills are placed by CFrame, but an agent thinks in position plus
	rotation the way the Properties panel presents a part -- and gets the
	multiplication order wrong when asked to build one. Composing it here means
	a rotated wedge is `orientation: "0, 45, 0"` rather than a CFrame expression
	that has to be right first time.
]]
local function placement(params: { [string]: any }): CFrame
	local position = need(params, "position", "Vector3") :: Vector3
	local raw = params.orientation
	if raw == nil then
		return CFrame.new(position)
	end
	local ok, angles = Serialize.parse(raw, "Vector3")
	if not ok then
		Dispatch.fail("BAD_PARAMS", '`orientation` is three degrees, e.g. "0, 45, 0".')
	end
	local turn = angles :: Vector3
	return CFrame.new(position)
		* CFrame.Angles(math.rad(turn.X), math.rad(turn.Y), math.rad(turn.Z))
end

--[[
	Refuses a fill big enough to hang Studio, and says how big it was.

	The number matters more than the refusal. "Too large" invites a retry at a
	guess; the voxel count against the cap tells the caller how much to shrink
	it, and is usually the moment they notice they wrote studs where they meant
	something smaller.
]]
local function guard(size: Vector3, what: string)
	local voxels = math.ceil(size.X / RESOLUTION)
		* math.ceil(size.Y / RESOLUTION)
		* math.ceil(size.Z / RESOLUTION)
	if voxels > MAX_VOXELS then
		Dispatch.fail(
			"REGION_TOO_LARGE",
			string.format(
				"%s covers about %d voxels; the limit is %d.",
				what,
				voxels,
				MAX_VOXELS
			),
			"Fill it in smaller pieces, or use a coarser shape."
		)
	end
	return voxels
end

local function material(params: { [string]: any }, field: string, fallback: Enum.Material?): Enum.Material
	local raw = params[field]
	if raw == nil then
		if fallback ~= nil then
			return fallback
		end
		Dispatch.fail("BAD_PARAMS", string.format("`%s` is required.", field))
	end
	local ok, value, why = Serialize.parse(raw, "Material")
	if not ok then
		Dispatch.fail(
			"BAD_PARAMS",
			string.format("`%s` is not a material: %s", field, tostring(why)),
			"Try Grass, Rock, Sand, Water, Snow, Basalt, or Air to carve."
		)
	end
	return value :: Enum.Material
end

--[[
	Fills one or more solids, as a single undo step.

	Batched for the same reason `create` is: terrain is built out of overlapping
	primitives -- a hill is several balls, a road is a row of blocks -- and one
	Ctrl+Z should take back the thing that was made rather than its last
	component.
]]
function Terrain.fill(params: { [string]: any }): { [string]: any }
	local shapes = params.shapes
	if typeof(shapes) ~= "table" or #shapes == 0 then
		Dispatch.fail("BAD_PARAMS", "`shapes` must be a non-empty array.")
	end

	local field = terrain()
	local filled: { { [string]: any } } = {}
	local total = 0

	local _, recorded = Undo.record("StudioMCP.TerrainFill", "MCP terrain fill", function()
		for index, shape in shapes :: { any } do
			if typeof(shape) ~= "table" then
				Dispatch.fail("BAD_PARAMS", string.format("shapes[%d] must be an object.", index))
			end

			local kind = string.lower(tostring(shape.shape or "block"))
			-- Air is a material, not a special case: carving a cave is filling
			-- with Air, and letting it through the ordinary path means `fill`
			-- both builds and digs with one schema.
			local chosen = material(shape, "material", Enum.Material.Grass)
			local at = placement(shape)
			local voxels

			if kind == "block" then
				local size = need(shape, "size", "Vector3") :: Vector3
				voxels = guard(size, string.format("shapes[%d]", index))
				field:FillBlock(at, size, chosen)
			elseif kind == "ball" then
				local radius = optionalNumber(shape, "radius", 0)
				if radius <= 0 then
					Dispatch.fail("BAD_PARAMS", string.format("shapes[%d] needs a `radius`.", index))
				end
				voxels = guard(Vector3.new(radius, radius, radius) * 2, string.format("shapes[%d]", index))
				field:FillBall(at.Position, radius, chosen)
			elseif kind == "cylinder" then
				local radius = optionalNumber(shape, "radius", 0)
				local height = optionalNumber(shape, "height", 0)
				if radius <= 0 or height <= 0 then
					Dispatch.fail(
						"BAD_PARAMS",
						string.format("shapes[%d] needs a `radius` and a `height`.", index)
					)
				end
				voxels = guard(Vector3.new(radius * 2, height, radius * 2), string.format("shapes[%d]", index))
				field:FillCylinder(at, height, radius, chosen)
			elseif kind == "wedge" then
				local size = need(shape, "size", "Vector3") :: Vector3
				voxels = guard(size, string.format("shapes[%d]", index))
				field:FillWedge(at, size, chosen)
			else
				Dispatch.fail(
					"BAD_PARAMS",
					string.format("shapes[%d]: unknown shape %q.", index, kind),
					"Use block, ball, cylinder or wedge."
				)
			end

			total += voxels
			table.insert(filled, {
				shape = kind,
				material = chosen.Name,
				position = Serialize.value(at.Position),
				voxels = voxels,
			})
		end
	end)

	return { filled = filled, voxels = total, undoable = recorded }
end

--[[
	Swaps one material for another inside a region, leaving the shape alone.

	Distinct from `fill` because it is the common edit that a fill cannot
	express: repainting the grass on an existing hill to snow without touching
	the hill. Doing it with fills means reconstructing the terrain you already
	have, which nobody gets exactly right.
]]
function Terrain.replace(params: { [string]: any }): { [string]: any }
	local field = terrain()
	local centre = need(params, "position", "Vector3") :: Vector3
	local size = need(params, "size", "Vector3") :: Vector3
	guard(size, "the region")

	local from = material(params, "from", nil)
	local to = material(params, "to", nil)

	local region = Region3.new(centre - size / 2, centre + size / 2):ExpandToGrid(RESOLUTION)

	local _, recorded = Undo.record("StudioMCP.TerrainReplace", "MCP terrain replace", function()
		field:ReplaceMaterial(region, RESOLUTION, from, to)
	end)

	return {
		from = from.Name,
		to = to.Name,
		position = Serialize.value(centre),
		size = Serialize.value(size),
		undoable = recorded,
	}
end

--[[
	Empties the terrain, or one region of it.

	Whole-terrain clears are guarded behind an explicit `confirm`, because this
	is the only call in the server that can destroy an afternoon's landscaping
	with no path back except an undo the agent may not think to offer. Costing a
	second round trip is the correct price.
]]
function Terrain.clear(params: { [string]: any }): { [string]: any }
	local field = terrain()

	if params.position ~= nil or params.size ~= nil then
		local centre = need(params, "position", "Vector3") :: Vector3
		local size = need(params, "size", "Vector3") :: Vector3
		guard(size, "the region")
		local region = Region3.new(centre - size / 2, centre + size / 2):ExpandToGrid(RESOLUTION)
		local _, recorded = Undo.record("StudioMCP.TerrainClear", "MCP terrain clear", function()
			field:FillRegion(region, RESOLUTION, Enum.Material.Air)
		end)
		return { cleared = "region", undoable = recorded }
	end

	if params.confirm ~= true then
		Dispatch.fail(
			"CONFIRM_REQUIRED",
			"Clearing all terrain cannot be undone by anything but Ctrl+Z.",
			'Pass confirm=true to do it, or give `position` and `size` to clear one region.'
		)
	end

	local before = field:CountCells()
	local _, recorded = Undo.record("StudioMCP.TerrainClear", "MCP terrain clear", function()
		field:Clear()
	end)
	return { cleared = "all", cellsBefore = before, undoable = recorded }
end

--[[
	What is there, without reading a voxel.

	`CountCells` is the cheap answer to "does this place even use terrain",
	which is the question worth asking before any of the above. The bounding box
	tells an agent where to aim without guessing at the origin.
]]
function Terrain.stats(_params: { [string]: any }): { [string]: any }
	local field = terrain()

	--[[
		Formatted here rather than through `Serialize.value`.

		`MaxExtents` is a Region3int16 and its corners are Vector3int16, which is
		a type `Serialize.value` has no case for -- it would have fallen through
		to the generic tail and reported whatever `tostring` makes of it. The
		extents are also in VOXELS, not studs, which is the sort of unit
		confusion that produces a fill a thousand studs from where it was meant,
		so they are converted and named for what they are.
	]]
	--[[
		`MaxExtents` is deliberately not reported.

		It reads like the bounding box of the terrain that exists, and it is
		not: it is the fixed limit of where terrain is allowed to go, and it
		answers -32000, -32000, -32000 to 32000, 32000, 32000 on an empty place
		and on a full one alike. Reporting it as "where the terrain sits" was a
		misreading of the name -- checked against a place with 2220 cells in a
		160-stud patch, which returned exactly the same numbers as one with
		none.

		There is no engine call for the occupied box, and finding it means
		reading every voxel in the world, which is far too expensive for a
		question meant to be cheap. `cells` already answers the one that
		matters: whether this place uses terrain at all.
	]]
	return {
		cells = field:CountCells(),
		waterColor = Serialize.value(field.WaterColor),
		waterWaveSize = field.WaterWaveSize,
		limitStuds = 32000,
	}
end

function Terrain.register()
	Dispatch.registerAll("terrain", {
		fill = Terrain.fill,
		replace = Terrain.replace,
		clear = Terrain.clear,
		stats = Terrain.stats,
	})
end

return Terrain
