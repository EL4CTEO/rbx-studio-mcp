--!strict
--[[
	Session and connectivity handlers. `studio.status` is the cheapest call in the
	system and doubles as the liveness probe, so it must never touch anything
	expensive -- notably it counts descendants lazily and caps the selection.
]]

local RunService = game:GetService("RunService")
local Selection = game:GetService("Selection")

local Dispatch = require(script.Parent.Parent.Dispatch)
local Editor = require(script.Parent.Parent.Editor)
local Paths = require(script.Parent.Parent.Paths)

-- `version()` is marked deprecated but remains the only way to read the Studio
-- build, and the agent needs it to know which engine APIs actually exist in this
-- session. Bound indirectly so the deprecation lint stays enabled file-wide.
local studioVersion: () -> string = (version :: any)

-- Selection can be tens of thousands of instances after a rubber-band drag.
-- Anything past this is noise for an agent and would blow the response budget.
local MAX_SELECTION = 50

-- Counting descendants of a large place is O(n) over the whole DataModel, so it
-- is cached briefly; status is polled often enough for this to matter.
local COUNT_CACHE_SECONDS = 5

local cachedCounts: { descendants: number, scripts: number }? = nil
local cachedAt = 0

local function counts(): { descendants: number, scripts: number }
	local now = os.clock()
	local cache = cachedCounts
	if cache and now - cachedAt < COUNT_CACHE_SECONDS then
		return cache
	end

	local descendants = 0
	local scripts = 0
	for _, instance in game:GetDescendants() do
		descendants += 1
		if instance:IsA("LuaSourceContainer") then
			scripts += 1
		end
	end

	local fresh = { descendants = descendants, scripts = scripts }
	cachedCounts = fresh
	cachedAt = now
	return fresh
end

local Session = {}

function Session.status(): { [string]: any }
	local selected: { { path: string, className: string } } = {}
	for index, instance in Selection:Get() do
		if index > MAX_SELECTION then
			break
		end
		table.insert(selected, { path = Paths.of(instance), className = instance.ClassName })
	end

	local totals = counts()
	-- Open tabs ride along with status rather than getting their own tool: this
	-- is the call agents are told to make first, and "which script is the user
	-- looking at" is orientation, not a separate question.
	local openScripts = Editor.documents()

	return {
		openScripts = if #openScripts > 0 then openScripts else nil,
		placeName = if game.Name ~= "" then game.Name else "Untitled place",
		placeId = game.PlaceId,
		-- RunService:IsRunning() is true for both Play and Run; IsEdit()
		-- distinguishes the authoring session from a live one.
		isRunning = RunService:IsRunning(),
		isEdit = RunService:IsEdit(),
		isRunMode = RunService:IsRunning() and not RunService:IsClient(),
		isServerView = RunService:IsServer(),
		selection = selected,
		selectionCount = #Selection:Get(),
		descendantCount = totals.descendants,
		scriptCount = totals.scripts,
		studioVersion = studioVersion(),
	}
end

--[[
	Round-trip probe used by the smoke test and by `studio_status` when the agent
	only needs to know the channel is alive.
]]
function Session.ping(params: { [string]: any }): { [string]: any }
	return { pong = true, echo = params.echo }
end

function Session.register()
	Dispatch.registerAll("studio", {
		status = function()
			return Session.status()
		end,
		ping = Session.ping,
	})
end

return Session
