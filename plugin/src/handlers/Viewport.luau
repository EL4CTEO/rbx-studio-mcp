--!strict
--[[
	The viewport and the selection -- what the user is pointing at, and what they
	have highlighted.

	Selection is the counterpart to `studio_status`, which reports it: this sets
	it. Selecting what a tool just built is the cheapest way to show someone the
	result of a change, and it puts the instance in reach of Studio's own move
	and scale handles.

	Raycasting answers "what is under this point in the 3D view", which is
	otherwise unanswerable: an agent can enumerate the data model but has no way
	to know what occupies a piece of space.
]]

local Selection = game:GetService("Selection")
local StudioService = game:GetService("StudioService")
local Workspace = game:GetService("Workspace")

local Dispatch = require(script.Parent.Parent.Dispatch)
local Paths = require(script.Parent.Parent.Paths)
local Serialize = require(script.Parent.Parent.Serialize)

local MAX_SELECTION = 200
local DEFAULT_RAY_LENGTH = 1000

local Viewport = {}

local function toVector(value: any, label: string): Vector3
	local ok, parsed = Serialize.parse(value, "Vector3")
	if not ok or typeof(parsed) ~= "Vector3" then
		Dispatch.fail(
			"BAD_PARAMS",
			string.format('%s must be three numbers, e.g. "0, 50, 0".', label)
		)
	end
	return parsed :: Vector3
end

--[[
	Casts a ray through the world and reports the first thing it hits.

	`StudioService:GizmoRaycast` is used rather than `Workspace:Raycast` because
	it respects what Studio itself considers selectable -- locked parts and
	editor-only gizmos behave the way they do when the user clicks.
]]
function Viewport.raycast(params: { [string]: any }): { [string]: any }
	local origin = toVector(params.origin, "origin")
	local direction = toVector(params.direction, "direction")
	local length = tonumber(params.maxDistance) or DEFAULT_RAY_LENGTH

	local filter: { Instance } = {}
	for _, path in (params.ignore or {}) :: { string } do
		table.insert(filter, Paths.resolve(path))
	end

	local config = RaycastParams.new()
	config.FilterType = Enum.RaycastFilterType.Exclude
	config.FilterDescendantsInstances = filter

	local ok, result = pcall(function()
		return StudioService:GizmoRaycast(origin, direction.Unit * length, config)
	end)
	if not ok then
		-- Falls back rather than failing: GizmoRaycast is Studio-only and the
		-- world query is the same answer for anything that is actually solid.
		ok, result = pcall(function()
			return Workspace:Raycast(origin, direction.Unit * length, config)
		end)
	end

	if not ok or result == nil then
		return { hit = false, origin = Serialize.value(origin), direction = Serialize.value(direction.Unit) }
	end

	local cast = result :: RaycastResult
	return {
		hit = true,
		path = if cast.Instance then Paths.of(cast.Instance) else nil,
		className = if cast.Instance then cast.Instance.ClassName else nil,
		position = Serialize.value(cast.Position),
		normal = Serialize.value(cast.Normal),
		distance = math.floor(cast.Distance * 1000 + 0.5) / 1000,
		material = Serialize.value(cast.Material),
	}
end

--[[
	Sets, extends or shrinks the Studio selection.
]]
function Viewport.select(params: { [string]: any }): { [string]: any }
	local paths = params.paths
	if typeof(paths) ~= "table" then
		Dispatch.fail("BAD_PARAMS", "select requires a `paths` array.")
	end
	if #paths > MAX_SELECTION then
		Dispatch.fail(
			"TOO_MANY",
			string.format("%d paths, over the %d selection limit.", #paths, MAX_SELECTION)
		)
	end

	local instances: { Instance } = {}
	for _, path in paths :: { string } do
		table.insert(instances, Paths.resolve(path))
	end

	local mode = params.mode or "set"
	if mode == "add" then
		Selection:Add(instances)
	elseif mode == "remove" then
		Selection:Remove(instances)
	else
		Selection:Set(instances)
	end

	local current: { { [string]: any } } = {}
	local memo: Paths.NameIndex = {}
	for index, instance in Selection:Get() do
		if index > MAX_SELECTION then
			break
		end
		table.insert(current, { path = Paths.of(instance, memo), className = instance.ClassName })
	end

	return { items = current, count = #Selection:Get() }
end

function Viewport.register()
	Dispatch.registerAll("viewport", {
		raycast = Viewport.raycast,
		select = Viewport.select,
	})
end

return Viewport
