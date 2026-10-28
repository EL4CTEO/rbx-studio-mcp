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
	-- An empty extent is not a small fill, it is no fill: the engine raised
	-- "Extents cannot be empty" from inside the recording, and that came back as
	-- an unstructured HANDLER_ERROR with no hint which side was zero.
	if size.X <= 0 or size.Y <= 0 or size.Z <= 0 then
		Dispatch.fail(
			"BAD_PARAMS",
			string.format("%s has a size of %s, which is empty.", what, tostring(size)),
			"Every side of the size has to be greater than zero."
		)
	end
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
				Dispatch.fail("BAD_PARAMS", string.format("shapes[%d] must be an object.", index - 1))
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
				voxels = guard(size, string.format("shapes[%d]", index - 1))
				field:FillBlock(at, size, chosen)
			elseif kind == "ball" then
				local radius = optionalNumber(shape, "radius", 0)
				if radius <= 0 then
					Dispatch.fail("BAD_PARAMS", string.format("shapes[%d] needs a `radius`.", index - 1))
				end
				voxels = guard(Vector3.new(radius, radius, radius) * 2, string.format("shapes[%d]", index - 1))
				field:FillBall(at.Position, radius, chosen)
			elseif kind == "cylinder" then
				local radius = optionalNumber(shape, "radius", 0)
				local height = optionalNumber(shape, "height", 0)
				if radius <= 0 or height <= 0 then
					Dispatch.fail(
						"BAD_PARAMS",
						string.format("shapes[%d] needs a `radius` and a `height`.", index - 1)
					)
				end
				voxels = guard(Vector3.new(radius * 2, height, radius * 2), string.format("shapes[%d]", index - 1))
				field:FillCylinder(at, height, radius, chosen)
			elseif kind == "wedge" then
				local size = need(shape, "size", "Vector3") :: Vector3
				voxels = guard(size, string.format("shapes[%d]", index - 1))
				field:FillWedge(at, size, chosen)
			else
				Dispatch.fail(
					"BAD_PARAMS",
					string.format("shapes[%d]: unknown shape %q.", index - 1, kind),
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
	which is the question worth asking before any of the above.
]]
function Terrain.stats(_params: { [string]: any }): { [string]: any }
	local field = terrain()

	--[[
		No bounds, and no limit.

		`MaxExtents` reads like the bounding box of the terrain that exists and is
		not: it answers -32000..32000 on an empty place and a full one alike. Nor
		is it a limit in studs -- a fill at 140,000 studs out still landed -- so
		the `limitStuds = 32000` this used to report was wrong as well.

		There is no engine call for the occupied box, and finding it means
		reading every voxel in the world, which is far too expensive for a
		question meant to be cheap. `cells` answers the one that matters.
	]]
	return {
		cells = field:CountCells(),
		waterColor = Serialize.value(field.WaterColor),
		-- Through Serialize so a float32 reads 0.15, not 0.15000000596046448.
		waterWaveSize = Serialize.value(field.WaterWaveSize),
	}
end

--[[
	Custom terrain materials: the 64 slots a place's terrain paints from.

	Slots 0 and 1 are Air and Water and cannot be changed. 2-22 hold the stock
	materials out of the box, and the rest are empty until someone defines one.
	A slot is a base material, an optional MaterialVariant name and a tint.

	Read off the live engine rather than documented anywhere: an empty slot
	answers `GetMaterialSlot` with NO values, not with nil-filled ones, which is
	why every read here goes through `readSlot`.

	Not undoable. `SetMaterialSlot` is not recorded by ChangeHistoryService, so
	every write reports what the slot held before, which is the way back.
	Painting with a custom slot is Roblox-script-only (`FillBlockSlot` and
	friends), so filling with one is left to the Terrain Editor.
]]
local SLOT_COUNT = 64
local FIRST_EDITABLE = 2

local function readSlot(field: Terrain, slot: number): { [string]: any }?
	local values = table.pack(field:GetMaterialSlot(slot))
	if values.n == 0 or values[1] == nil then
		return nil
	end
	return {
		slot = slot,
		base = (values[1] :: Enum.Material).Name,
		variant = if values[2] ~= nil and values[2] ~= "" then values[2] else nil,
		color = Serialize.value(values[3]),
	}
end

local function slotIndex(raw: any, what: string): number
	local slot = tonumber(raw)
	if slot == nil or slot % 1 ~= 0 or slot < FIRST_EDITABLE or slot >= SLOT_COUNT then
		Dispatch.fail(
			"BAD_PARAMS",
			string.format("%s: `slot` must be a whole number from %d to %d.", what, FIRST_EDITABLE, SLOT_COUNT - 1),
			"Slots 0 and 1 are Air and Water and cannot be changed."
		)
	end
	return slot :: number
end

function Terrain.materials(params: { [string]: any }): { [string]: any }
	local field = terrain()
	local action = params.action or "list"

	local expanded: string? = nil
	pcall(function()
		expanded = tostring((Workspace :: any).ExpandedTerrain.Name)
	end)

	if action == "list" then
		local slots = {}
		local free = 0
		for slot = 0, SLOT_COUNT - 1 do
			local entry = readSlot(field, slot)
			if entry ~= nil then
				table.insert(slots, entry)
			elseif slot >= FIRST_EDITABLE then
				free += 1
			end
		end
		return { slots = slots, free = free, expandedTerrain = expanded }
	end

	local entries = params.slots
	if typeof(entries) ~= "table" or #entries == 0 then
		Dispatch.fail("BAD_PARAMS", string.format("%s needs `slots`.", action))
	end

	local changed = {}
	if action == "reset" then
		-- Every index checked before any slot is touched: a reset cannot be
		-- undone, so a bad entry must not cost the ones before it.
		local slots = {}
		for _, raw in entries do
			table.insert(slots, slotIndex(if typeof(raw) == "table" then raw.slot else raw, "reset"))
		end
		for _, slot in slots do
			local previous = readSlot(field, slot)
			field:ResetMaterialSlot(slot)
			table.insert(changed, { slot = slot, previous = previous, now = readSlot(field, slot) })
		end
		return { reset = changed, undoable = false }
	end

	if action ~= "set" then
		Dispatch.fail("BAD_PARAMS", string.format("Unknown materials action `%s`.", tostring(action)), "Use list, set or reset.")
	end

	-- Validated as a batch before anything is written, so a typo in the third
	-- entry does not leave the first two applied with no undo to take them back.
	local plan = {}
	-- Slots named outright are claimed before any free one is chosen, so an
	-- entry without a slot can never be handed one a later entry overwrites.
	local claimed: { [number]: boolean } = {}
	for index, raw in entries do
		if typeof(raw) ~= "table" then
			Dispatch.fail("BAD_PARAMS", string.format("slots[%d] must be an object.", index))
		end
		if raw.slot ~= nil then
			local slot = slotIndex(raw.slot, string.format("slots[%d]", index))
			if claimed[slot] then
				Dispatch.fail("BAD_PARAMS", string.format("slot %d is named twice.", slot))
			end
			claimed[slot] = true
		end
	end
	for index, raw in entries do
		local slot: number
		if raw.slot ~= nil then
			slot = slotIndex(raw.slot, string.format("slots[%d]", index))
		else
			local found: number? = nil
			for candidate = FIRST_EDITABLE, SLOT_COUNT - 1 do
				if not claimed[candidate] and readSlot(field, candidate) == nil then
					found = candidate
					break
				end
			end
			if found == nil then
				Dispatch.fail("TERRAIN_SLOTS_FULL", "Every custom terrain slot is in use.", "Reset one, or name a `slot` to overwrite.")
			end
			slot = found :: number
			claimed[slot] = true
		end
		local base = material(raw, "base", nil)
		if base == Enum.Material.Air or base == Enum.Material.Water then
			Dispatch.fail("BAD_PARAMS", string.format("slots[%d]: Air and Water cannot be a slot's base.", index))
		end
		local color = Color3.new(1, 1, 1)
		if raw.color ~= nil then
			local ok, value, why = Serialize.parse(raw.color, "Color3")
			if not ok then
				Dispatch.fail("BAD_PARAMS", string.format("slots[%d].color: %s", index, tostring(why)))
			end
			color = value
		else
			-- Keeps the slot's own tint when overwriting one, and starts a new
			-- slot at the base material's colour rather than at white.
			local current = table.pack(field:GetMaterialSlot(slot))
			color = if current.n >= 3 and typeof(current[3]) == "Color3"
				then current[3]
				else field:GetMaterialColor(base)
		end
		table.insert(plan, { slot = slot, base = base, variant = raw.variant or "", color = color })
	end

	for _, step in plan do
		local previous = readSlot(field, step.slot)
		local ok, why = pcall(field.SetMaterialSlot, field, step.slot, step.base, step.variant, step.color)
		if not ok then
			if #changed == 0 then
				Dispatch.fail(
					"BAD_PARAMS",
					string.format("slot %d: %s", step.slot, tostring(why)),
					"Check the MaterialVariant name and that its BaseMaterial matches `base`."
				)
			end
			-- Some slots are already written and cannot be undone, so the answer
			-- carries what they held rather than an error that would drop it.
			return {
				set = changed,
				failed = { slot = step.slot, error = tostring(why) },
				undoable = false,
				expandedTerrain = expanded,
			}
		end
		table.insert(changed, { slot = step.slot, previous = previous, now = readSlot(field, step.slot) })
	end
	return { set = changed, undoable = false, expandedTerrain = expanded }
end

function Terrain.register()
	Dispatch.registerAll("terrain", {
		fill = Terrain.fill,
		replace = Terrain.replace,
		clear = Terrain.clear,
		stats = Terrain.stats,
		materials = Terrain.materials,
	})
end

return Terrain
