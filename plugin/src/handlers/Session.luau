--!strict
--[[
	Session and connectivity handlers. `studio.status` is the cheapest call in the
	system and doubles as the liveness probe, so it must never touch anything
	expensive -- notably it counts descendants lazily and caps the selection.
]]

local MarketplaceService = game:GetService("MarketplaceService")
local RunService = game:GetService("RunService")
local Selection = game:GetService("Selection")

local Dispatch = require(script.Parent.Parent.Dispatch)
local Context = require(script.Parent.Parent.Context)
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

--[[
	The name the user would recognise.

	`game.Name` is the data model's name -- "Place1", "Place5" -- and has nothing
	to do with what the place is called on the Studio tab or the Creator
	Dashboard. Nothing local holds the real name: it lives on Roblox's servers, so
	it takes a lookup. Without it, a user saying "the other place, the published
	one" cannot be matched to any window, which is the whole point of being able
	to drive several Studios at once.

	Cached, including the failure, because an unpublished place would otherwise
	make a doomed web request on every status call.
]]
local NAME_RETRY_SECONDS = 60

local resolvedName: string? = nil
local resolvedFor = -1
local resolvedAt = 0

local function publishedPlaceName(): string?
	local placeId = game.PlaceId
	-- A place that has never been saved to Roblox has no id and no remote name.
	if placeId == 0 then
		return nil
	end

	local fresh = resolvedFor == placeId
		and (resolvedName ~= nil or os.clock() - resolvedAt < NAME_RETRY_SECONDS)
	if fresh then
		return resolvedName
	end

	resolvedFor = placeId
	resolvedAt = os.clock()

	local ok, info = pcall(function()
		return MarketplaceService:GetProductInfo(placeId, Enum.InfoType.Asset)
	end)
	local name = if ok and typeof(info) == "table" then (info :: any).Name else nil
	resolvedName = if typeof(name) == "string" and name ~= "" then name else nil
	return resolvedName
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

	local published = publishedPlaceName()

	return {
		openScripts = if #openScripts > 0 then openScripts else nil,
		placeName = published or (if game.Name ~= "" then game.Name else "Untitled place"),
		-- Kept separate when the two differ, so a path rooted at the data model
		-- name stays explicable next to a place called something else entirely.
		dataModelName = if published and published ~= game.Name then game.Name else nil,
		placeId = game.PlaceId,
		context = Context.of(),
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
