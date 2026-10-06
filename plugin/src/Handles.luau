--!strict
-- Session-local instance references. Nothing is written to the place. Roblox
-- can collect a Lua Instance wrapper even while the engine instance is still
-- parented, so addressable handles need bounded strong references, not weak
-- values. Deleted/detached instances are refused and released on lookup.
local HttpService = game:GetService("HttpService")
local Dispatch = require(script.Parent.Dispatch)

local Handles = {}
local prefix = "@mcp:" .. HttpService:GenerateGUID(false) .. ":"
local nextId = 0
local ids: { [Instance]: number } = setmetatable({}, { __mode = "k" }) :: any
local values: { [number]: Instance } = {}
local CAPACITY = 5000
local ring: { [number]: number } = {}
local slot = 0

-- A stable number for ordering same-named siblings. Allocating one takes no
-- handle slot: sorting a large folder must not evict handles already issued.
function Handles.id(instance: Instance): number
	local id = ids[instance]
	if not id then
		nextId += 1
		id = nextId
		ids[instance] = id
	end
	return id
end

-- Only handed-out handles occupy the bounded cache. Old handles fail rather
-- than point at a replacement with the same name.
function Handles.of(instance: Instance): string
	local id = Handles.id(instance)
	if values[id] == nil then
		slot = slot % CAPACITY + 1
		local previous = ring[slot]
		if previous then values[previous] = nil end
		ring[slot] = id
		values[id] = instance
	end
	return prefix .. tostring(id)
end

function Handles.resolve(handle: string): Instance
	local suffix = if string.sub(handle, 1, #prefix) == prefix then string.sub(handle, #prefix + 1) else ""
	local id = tonumber(suffix)
	local instance = if id then values[id] else nil
	if instance == nil or (instance ~= game and not instance:IsDescendantOf(game)) then
		if id then values[id] = nil end
		Dispatch.fail("STALE_HANDLE", "This handle is expired, destroyed, or belongs to another session/client.",
			"Query the instance again in the same context. A handle never falls back to a name lookup.")
	end
	return instance :: Instance
end

return Handles
