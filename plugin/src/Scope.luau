--!strict
--[[
	Which parts of the DataModel a search is allowed to wander into.

	`game:GetChildren()` returns ~122 instances, nearly all of them engine
	singletons like TraceRouteService and HSRDataContentProvider that no one
	authors content into. Listing them costs thousands of tokens and buries the
	handful of containers that matter.

	A "show it if it has children" rule was tried first and let too much through:
	MemStorageService alone reports 197 children of pure engine state. So the root
	level is an explicit allowlist of the containers a place is actually authored
	in. Everything else stays reachable by passing its path directly, and callers
	report how many were hidden so that is discoverable.
]]

local Scope = {}

Scope.ROOT_ALWAYS = {
	Workspace = true,
	Players = true,
	Lighting = true,
	ReplicatedFirst = true,
	ReplicatedStorage = true,
	ServerScriptService = true,
	ServerStorage = true,
	StarterGui = true,
	StarterPack = true,
	StarterPlayer = true,
	SoundService = true,
	Teams = true,
	MaterialService = true,
	TextChatService = true,
	Chat = true,
	LocalizationService = true,
	TestService = true,
}

--[[
	The top-level service an instance sits under, or the instance itself when it
	is one. Used to hide whole branches (everything inside CoreGui) rather than
	just the service node.
]]
function Scope.topService(instance: Instance): Instance?
	if instance == game then
		return nil
	end

	local current = instance
	local parent = current.Parent
	while parent ~= nil and parent ~= game do
		current = parent
		parent = current.Parent
	end

	-- Landing on `game` means `current` is the service. Landing on nil means the
	-- instance is detached from the DataModel, which is not noise to filter.
	if parent == game then
		return current
	end
	return nil
end

function Scope.isVisibleService(service: Instance): boolean
	return Scope.ROOT_ALWAYS[service.Name] == true
end

--[[
	True for instances the caller almost certainly did not mean to see. Only
	applied when walking from the DataModel root; an explicit `path` into a
	hidden service is always honoured.
]]
function Scope.isNoisy(instance: Instance): boolean
	local service = Scope.topService(instance)
	return service ~= nil and not Scope.isVisibleService(service)
end

return Scope
