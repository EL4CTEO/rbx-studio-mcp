--!strict
--[[
	Saved data: DataStore and MemoryStore.

	Everything else this server exposes reads the place -- instances, properties,
	source. None of it can answer the most common bug report a Roblox game gets,
	which is some version of "my stuff was gone when I rejoined". That question is
	not about the place at all. It is about a row in a data store, and until now
	the only way to look at one was to write a script, run it, and read the
	output.

	Two backends live here because they are the same shape to a caller and
	nothing else about them is alike:

	* `DataStoreService` is permanent, per-player, and the thing people lose
	  money and progress in. It keeps version history, which is what makes this
	  tool safe to point at a live game: you can read what a key held an hour ago
	  without touching what it holds now.
	* `MemoryStoreService` is a shared scratchpad that expires -- matchmaking
	  queues, session locks, live leaderboards. Measured: it works from Studio
	  with no setup at all, unlike DataStore.

	The gate is worth stating up front, because it is the first thing anyone
	hits. DataStore refuses every call from Studio until "Enable Studio Access to
	API Services" is ticked in Game Settings -> Security, and the refusal is a
	raw HTTP 502 that says nothing about the checkbox. `gate` below turns it into
	the sentence the user needs. MemoryStore has no such gate.
]]

local DataStoreService = game:GetService("DataStoreService")
local HttpService = game:GetService("HttpService")
local MemoryStoreService = game:GetService("MemoryStoreService")

local Dispatch = require(script.Parent.Parent.Dispatch)

local Data = {}

--[[
	Rows returned in one call.

	Deliberately modest. Every row is a key name plus, for a get, a whole saved
	value -- and a player's save can be tens of kilobytes of JSON. A page that
	filled the agent's context with someone's inventory would make the next
	question unanswerable, so paging is the default and the cursor is honest.
]]
local DEFAULT_LIMIT = 50
local MAX_LIMIT = 200

--[[
	Seconds a MemoryStore write survives without an explicit expiry.

	An hour. These are session-lifetime values by design, and a tool that wrote
	them with the 45-day maximum would leave test data outliving the test by a
	month and a half.
]]
local DEFAULT_TTL = 3600

--[[
	Turns the API-services refusal into the one sentence that fixes it.

	Every DataStore call fails identically while the setting is off, with a 502
	and "Studio access to APIs is not allowed" buried in it. That text names
	neither the setting nor where it lives, and an agent reading a 502 will
	reasonably conclude the service is down and stop -- which is the wrong
	conclusion about a checkbox.

	Anything else is re-raised as it came: a budget exhaustion, a bad key name
	and a network failure all say useful things already.
]]
local function gate(err: any, what: string): never
	local reason = tostring(err)
	if
		string.find(reason, "not allowed", 1, true)
		or string.find(reason, "403", 1, true)
		or string.find(reason, "Error code: 7", 1, true)
	then
		Dispatch.fail(
			"API_ACCESS_DISABLED",
			"This place does not allow Studio to reach data stores yet.",
			"In Studio: File -> Game Settings -> Security -> turn on \"Enable Studio "
				.. "Access to API Services\", then try again. The place must also be "
				.. "published. MemoryStore (kind=\"memory\") needs none of this."
		)
	end
	Dispatch.fail("DATASTORE_FAILED", string.format("%s failed: %s", what, reason))
end

local function limitOf(params: { [string]: any }): number
	return math.clamp(tonumber(params.limit) or DEFAULT_LIMIT, 1, MAX_LIMIT)
end

--[[
	Which store the call is about.

	`scope` is passed through rather than defaulted away: a game that used scopes
	has its data under them, and a tool that could only see the global scope
	would report an empty store and be believed.
]]
local function storeOf(params: { [string]: any }): any
	local name = params.store
	if typeof(name) ~= "string" or name == "" then
		Dispatch.fail("BAD_PARAMS", "this needs a `store` name.", 'Call op="list" with no store to see them.')
	end
	local scope = if typeof(params.scope) == "string" and params.scope ~= "" then params.scope else nil
	local ok, store = pcall(function()
		if scope then
			return DataStoreService:GetDataStore(name, scope)
		end
		return DataStoreService:GetDataStore(name)
	end)
	if not ok then
		gate(store, "opening the data store")
	end
	return store
end

local function mapOf(params: { [string]: any }): any
	local name = params.store
	if typeof(name) ~= "string" or name == "" then
		Dispatch.fail("BAD_PARAMS", 'a memory call needs a `store` name -- the sorted map\'s name.')
	end
	local ok, map = pcall(function()
		return MemoryStoreService:GetSortedMap(name)
	end)
	if not ok then
		Dispatch.fail("MEMORYSTORE_FAILED", string.format("Could not open sorted map %q: %s", name, tostring(map)))
	end
	return map
end

--[[
	A saved value, rendered for an agent to read.

	Saves are arbitrary Luau: a number, a string, or -- nearly always in practice
	-- a nested table. JSON is the only honest way to carry that across the wire,
	and it is also the form the caller will want to reason about.

	Guarded, because not everything that can be saved can be encoded. A table
	with both array and dictionary keys, or a NaN, throws inside JSONEncode;
	losing the whole read over that would be worse than describing the shape, so
	the fallback says what it was rather than pretending it was nothing.
]]
local function render(value: any): { [string]: any }
	if value == nil then
		return { exists = false }
	end

	local kind = typeof(value)
	local ok, encoded = pcall(function()
		return HttpService:JSONEncode(value)
	end)
	if ok then
		return { exists = true, type = kind, value = encoded }
	end
	return {
		exists = true,
		type = kind,
		value = tostring(value),
		note = "This value could not be encoded as JSON, so it is shown as text. "
			.. "Mixed array/dictionary tables and NaN both do this.",
	}
end

--[[
	The inverse, for writes.

	Values arrive as JSON text, which is the only shape the MCP protocol can
	carry and also the only one a caller can read back from a `get`. A bare
	string that is not valid JSON is taken as a string rather than refused --
	`value="hello"` is what someone means by "write hello", and making them type
	`"\"hello\""` would be pedantry with no upside.
]]
local function parse(raw: any): any
	if raw == nil then
		Dispatch.fail("BAD_PARAMS", "a write needs a `value`.", 'Pass JSON, e.g. {"coins":10} or 42 or "hello".')
	end
	local text = tostring(raw)
	local ok, decoded = pcall(function()
		return HttpService:JSONDecode(text)
	end)
	if ok then
		return decoded
	end
	return text
end

--[[
	How many requests are left before Roblox starts refusing.

	Carried on every reply because it is the difference between "this key is
	empty" and "this call never reached the server". The budget is per request
	type and refills over time; an agent that sees it fall to zero knows to wait
	rather than to conclude anything about the data.
]]
local function budget(requestType: Enum.DataStoreRequestType): number?
	local ok, value = pcall(function()
		return DataStoreService:GetRequestBudgetForRequestType(requestType)
	end)
	return if ok then tonumber(value) else nil
end

--[[
	Walks pages until `limit` rows or the end, whichever comes first.

	Pages are the engine's unit and they are not the caller's: one page is
	whatever size Roblox felt like returning, and a caller asking for 50 keys
	wants 50 keys, not "a page of maybe 20". `cursor` on the way back is the
	engine's own, so paging resumes exactly where it stopped rather than
	re-listing from the start.
]]
local function drain(pages: any, limit: number, read: (any) -> any): ({ any }, string?)
	local rows: { any } = {}
	while true do
		local page = pages:GetCurrentPage()
		for _, entry in page do
			if #rows >= limit then
				break
			end
			table.insert(rows, read(entry))
		end
		if #rows >= limit or pages.IsFinished then
			break
		end
		local ok, err = pcall(function()
			pages:AdvanceToNextPageAsync()
		end)
		if not ok then
			gate(err, "listing")
		end
	end

	local cursor: string? = nil
	if not pages.IsFinished then
		local ok, value = pcall(function()
			return pages.Cursor
		end)
		if ok and typeof(value) == "string" and value ~= "" then
			cursor = value
		end
	end
	return rows, cursor
end

--[[
	Lists what exists: stores, keys, or a range of a sorted map.

	One verb rather than three because the question is one question -- "what is
	in here" -- and the answer only depends on how much of the address is
	already known. No store named: the stores. A store named: its keys. Memory:
	the map's range.
]]
function Data.list(params: { [string]: any }): { [string]: any }
	local limit = limitOf(params)
	local prefix = if typeof(params.prefix) == "string" then params.prefix else ""
	local cursor = if typeof(params.cursor) == "string" then params.cursor else ""

	if params.kind == "memory" then
		local map = mapOf(params)
		local ok, entries = pcall(function()
			return map:GetRangeAsync(Enum.SortDirection.Ascending, limit)
		end)
		if not ok then
			Dispatch.fail("MEMORYSTORE_FAILED", string.format("Could not read the map: %s", tostring(entries)))
		end
		local rows: { { [string]: any } } = {}
		for _, entry in entries :: { any } do
			local row = render(entry.value)
			row.key = tostring(entry.key)
			table.insert(rows, row)
		end
		return { kind = "memory", store = params.store, items = rows, count = #rows }
	end

	if typeof(params.store) == "string" and params.store ~= "" then
		local store = storeOf(params)
		local ok, pages = pcall(function()
			return store:ListKeysAsync(prefix, 0, cursor, false)
		end)
		if not ok then
			gate(pages, "listing keys")
		end
		local rows, next = drain(pages, limit, function(entry)
			return { key = tostring(entry.KeyName) }
		end)
		return {
			kind = "data",
			store = params.store,
			scope = params.scope,
			items = rows,
			count = #rows,
			cursor = next,
			budget = budget(Enum.DataStoreRequestType.GetAsync),
		}
	end

	local ok, pages = pcall(function()
		return DataStoreService:ListDataStoresAsync(prefix, 0, cursor)
	end)
	if not ok then
		gate(pages, "listing data stores")
	end
	local rows, next = drain(pages, limit, function(entry)
		return { store = tostring(entry.DataStoreName), created = tostring(entry.CreatedTime) }
	end)
	return { kind = "data", items = rows, count = #rows, cursor = next }
end

--[[
	Reads one key, optionally as it was at some point in the past.

	The past is the reason this is worth having. "The save is wrong" is not
	answerable by looking at the save -- you need what it held before, and
	`version` and `at` are the two ways anyone actually has of naming that: a
	version id from `op="versions"`, or a timestamp from when the player says it
	broke.
]]
function Data.get(params: { [string]: any }): { [string]: any }
	local key = params.key
	if typeof(key) ~= "string" or key == "" then
		Dispatch.fail("BAD_PARAMS", "get needs a `key`.")
	end

	if params.kind == "memory" then
		local map = mapOf(params)
		local ok, value = pcall(function()
			return map:GetAsync(key)
		end)
		if not ok then
			Dispatch.fail("MEMORYSTORE_FAILED", string.format("Could not read %q: %s", key, tostring(value)))
		end
		local row = render(value)
		row.kind = "memory"
		row.key = key
		return row
	end

	local store = storeOf(params)
	local version = if typeof(params.version) == "string" and params.version ~= "" then params.version else nil
	local at = tonumber(params.at)

	local ok, value, info = pcall(function()
		if version ~= nil then
			return store:GetVersionAsync(key, version)
		end
		if at ~= nil then
			return store:GetVersionAtTimeAsync(key, math.floor(at))
		end
		return store:GetAsync(key)
	end)
	if not ok then
		gate(value, "reading the key")
	end

	local row = render(value)
	row.kind = "data"
	row.key = key
	row.store = params.store
	row.version = version
	--[[
		`GetAsync` returns the value and a DataStoreKeyInfo beside it. The second
		return is where the useful forensics live -- when it was last written, and
		which user ids it was tagged with -- and it costs nothing to carry.
	]]
	if typeof(info) == "Instance" or typeof(info) == "userdata" then
		local okInfo = pcall(function()
			row.updated = tostring((info :: any).UpdatedTime)
			row.created = tostring((info :: any).CreatedTime)
			row.versionId = tostring((info :: any).Version)
		end)
		if not okInfo then
			row.updated = nil
		end
	end
	row.budget = budget(Enum.DataStoreRequestType.GetAsync)
	return row
end

--[[
	Every version of a key, newest first.

	Newest first because the question is nearly always "what did this look like
	before the thing that broke it", and counting forward from the beginning of
	time to find that is the wrong end to start from.
]]
function Data.versions(params: { [string]: any }): { [string]: any }
	local key = params.key
	if typeof(key) ~= "string" or key == "" then
		Dispatch.fail("BAD_PARAMS", "versions needs a `key`.")
	end
	local store = storeOf(params)
	local limit = limitOf(params)

	local ok, pages = pcall(function()
		return store:ListVersionsAsync(key, Enum.SortDirection.Descending, 0, 0, 0)
	end)
	if not ok then
		gate(pages, "listing versions")
	end

	local rows = drain(pages, limit, function(entry)
		return {
			version = tostring(entry.Version),
			created = tostring(entry.CreatedTime),
			deleted = entry.IsDeleted == true,
		}
	end)

	return {
		kind = "data",
		store = params.store,
		key = key,
		items = rows,
		count = #rows,
		hint = 'Read one with op="get" and the `version` from this list.',
	}
end

--[[
	Writes a key. Refuses to do it by accident.

	`confirm` is required on DataStore writes and on nothing else in this file,
	because this is the only operation here that cannot be undone by any means
	available to this server. There is no recording to cancel and no Ctrl+Z; the
	previous value survives only in version history, and only if the key had one.
	The confirmation is the last point at which a misread key name is cheap.

	MemoryStore writes are not confirmed. They expire on their own, they hold
	session state rather than player property, and treating them with the same
	ceremony would teach the caller to type confirm=true without reading it.
]]
function Data.set(params: { [string]: any }): { [string]: any }
	local key = params.key
	if typeof(key) ~= "string" or key == "" then
		Dispatch.fail("BAD_PARAMS", "set needs a `key`.")
	end
	local value = parse(params.value)

	if params.kind == "memory" then
		local map = mapOf(params)
		local ttl = math.clamp(tonumber(params.ttl) or DEFAULT_TTL, 1, 3888000)
		local ok, err = pcall(function()
			map:SetAsync(key, value, ttl)
		end)
		if not ok then
			Dispatch.fail("MEMORYSTORE_FAILED", string.format("Could not write %q: %s", key, tostring(err)))
		end
		return { kind = "memory", store = params.store, key = key, written = true, ttl = ttl }
	end

	if params.confirm ~= true then
		Dispatch.fail(
			"CONFIRM_REQUIRED",
			string.format("Writing %q would overwrite whatever a player has saved there.", key),
			"Nothing here can undo it -- there is no recording to cancel and no Ctrl+Z. "
				.. 'Read it first with op="get", then pass confirm=true if the new value is right.'
		)
	end

	local store = storeOf(params)
	local ok, err = pcall(function()
		store:SetAsync(key, value)
	end)
	if not ok then
		gate(err, "writing the key")
	end

	return {
		kind = "data",
		store = params.store,
		key = key,
		written = true,
		budget = budget(Enum.DataStoreRequestType.SetIncrementAsync),
		note = 'The previous value is still in version history -- op="versions" lists it.',
	}
end

--[[
	Deletes a key, with the same confirmation and one reassurance.

	`RemoveAsync` on a DataStore is a soft delete: the key stops reading back but
	its versions remain, so a removal is recoverable in a way a `set` over the
	top of a value is not. Said in the reply rather than assumed, because a
	caller who does not know that will not ask for it back.
]]
function Data.remove(params: { [string]: any }): { [string]: any }
	local key = params.key
	if typeof(key) ~= "string" or key == "" then
		Dispatch.fail("BAD_PARAMS", "remove needs a `key`.")
	end

	if params.kind == "memory" then
		local map = mapOf(params)
		local ok, err = pcall(function()
			map:RemoveAsync(key)
		end)
		if not ok then
			Dispatch.fail("MEMORYSTORE_FAILED", string.format("Could not remove %q: %s", key, tostring(err)))
		end
		return { kind = "memory", store = params.store, key = key, removed = true }
	end

	if params.confirm ~= true then
		Dispatch.fail(
			"CONFIRM_REQUIRED",
			string.format("Removing %q would take away whatever a player has saved there.", key),
			"Pass confirm=true to do it. It is recoverable -- the key's versions survive "
				.. 'a removal and op="versions" still lists them.'
		)
	end

	local store = storeOf(params)
	local ok, removed = pcall(function()
		return store:RemoveAsync(key)
	end)
	if not ok then
		gate(removed, "removing the key")
	end

	local row = render(removed)
	row.kind = "data"
	row.store = params.store
	row.key = key
	row.removed = true
	row.note = "This was the value that was removed. Its versions survive; "
		.. 'op="versions" still lists them.'
	return row
end

function Data.register()
	Dispatch.registerAll("data", {
		list = Data.list,
		get = Data.get,
		versions = Data.versions,
		set = Data.set,
		remove = Data.remove,
	})
end

return Data
