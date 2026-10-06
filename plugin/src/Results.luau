--!strict
-- Immutable, JSON-safe execution snapshots. Retrieval never executes the
-- original chunk again, and retained data has a separate, explicit ceiling.
local HttpService = game:GetService("HttpService")
local Dispatch = require(script.Parent.Dispatch)
local Serialize = require(script.Parent.Serialize)
local Results = {}
local TTL = 120
local CAPACITY = 8
local MAX_BYTES = 131072
local snapshots: { [string]: any } = {}
local order: { string } = {}

local function prune()
	local now = os.clock()
	for index = #order, 1, -1 do
		local id = order[index]
		if not snapshots[id] or snapshots[id].expires <= now then
			snapshots[id] = nil
			table.remove(order, index)
		end
	end
end

function Results.capture(value: any): { [string]: any }
	prune()
	local bytes, nodes = MAX_BYTES - 1000, 10000
	local omitted: { string } = {}
	local truncated = false
	local visiting: { [any]: boolean } = {}
	local function missing(path: string): string
		truncated = true
		if #omitted < 5 then table.insert(omitted, string.sub(path, 1, 128)) end
		return "<not retained>"
	end
	local function copy(raw: any, depth: number, path: string): any
		nodes -= 1
		bytes -= 48
		if nodes < 0 or bytes < 100 then return missing(path) end
		if typeof(raw) ~= "table" then
			local encoded = if typeof(raw) == "function" or typeof(raw) == "thread" then "<" .. typeof(raw) .. ">" else Serialize.value(raw)
			if typeof(encoded) == "string" then
				-- Six bytes per byte covers JSON's longest escape, including control
				-- characters. Keep the string whole or make the loss explicit.
				local size = #HttpService:JSONEncode(encoded)
				if size > bytes then return missing(path) end
				bytes -= size
			end
			return encoded
		end
		if depth >= 16 or visiting[raw] then return missing(path) end
		visiting[raw] = true
		local out: { [any]: any } = {}
		-- Roblox's JSON encoder prefers numeric array keys over named keys in
		-- mixed tables. Normalize maps explicitly so a named field is not lost
		-- between this VM and the bridge. Pure arrays retain numeric indexes.
		local array, keyCount = true, 0
		for key in raw do
			keyCount += 1
			if typeof(key) ~= "number" or key % 1 ~= 0 or key < 1 or key > #raw then array = false end
			if keyCount > 10000 then array = false; break end
		end
		array = array and keyCount == #raw
		local count = 0
		for key, item in raw do
			count += 1
			if count > 10000 or nodes <= 0 or bytes < 100 then
				missing(path .. ".*")
				break
			end
			local name = if array then key else tostring(key)
			local keyBytes = #tostring(name) * 6
			if keyBytes > bytes or #tostring(name) > 512 then
				missing(path .. ".<key>")
				break
			end
			bytes -= keyBytes
			if out[name] ~= nil then missing(path .. ".<duplicate key>") end
			out[name] = copy(item, depth + 1, path .. "." .. tostring(name))
		end
		visiting[raw] = nil
		return out
	end
	local data = copy(value, 0, "result")
	local id = HttpService:GenerateGUID(false)
	-- Even a hostile value cannot turn the cache into an unbounded allocation.
	if #HttpService:JSONEncode(data) > MAX_BYTES then
		data = missing("result")
	end
	while #order >= CAPACITY do snapshots[table.remove(order, 1)] = nil end
	snapshots[id] = { data = data, expires = os.clock() + TTL, truncated = truncated, omitted = omitted }
	table.insert(order, id)
	return { resultId = id, expiresIn = TTL, retainedTruncated = truncated, omittedPaths = if truncated then omitted else nil }
end

-- Preview an oversized child by its shape. It remains retrievable by drilling
-- into its path, unlike the old irrecoverable nested-table marker.
local function preview(value: any, path: { any }): any
	if #HttpService:JSONEncode(value) <= 6000 then return value end
	if typeof(value) == "string" then return { resultPath = path, kind = "string", bytes = #value } end
	local keys: { string } = {}
	local bytes = 0
	if typeof(value) == "table" then
		for key in value do
			local name = tostring(key)
			local cost = #HttpService:JSONEncode(name) + 1
			if #keys >= 20 or bytes + cost > 1000 then break end
			bytes += cost
			table.insert(keys, name)
		end
		table.sort(keys)
	end
	return { resultPath = path, kind = "table", keys = keys, valueTruncated = true }
end

function Results.read(params: { [string]: any }): { [string]: any }
	prune()
	local snapshot = snapshots[params.resultId]
	if not snapshot then
		Dispatch.fail("RESULT_EXPIRED", "The result expired, was evicted, or belongs to another session/client.",
			"Keep the original target, player and studioId. Do not rerun mutating code just to retrieve its output.")
	end
	local path = params.resultPath or { "returned", 1 }
	local value = snapshot.data
	for _, key in path do
		if typeof(value) ~= "table" then Dispatch.fail("BAD_RESULT_PATH", "The result path descends through a scalar.") end
		if value[key] == nil and value[tostring(key)] == nil then Dispatch.fail("BAD_RESULT_PATH", "This key is absent from the retained result.") end
		value = if value[key] ~= nil then value[key] else value[tostring(key)]
	end
	local offset = math.max(0, tonumber(params.resultOffset) or 0)
	local result: { [string]: any } = { resultId = params.resultId, resultPath = path, offset = offset,
		kind = typeof(value), expiresIn = math.max(0, math.floor(snapshot.expires - os.clock())),
		retainedTruncated = snapshot.truncated, omittedPaths = if snapshot.truncated then snapshot.omitted else nil }
	if typeof(value) == "string" then
		local finish = math.min(#value, offset + 4000)
		-- Offsets are UTF-8 bytes. Do not split a character at the page boundary.
		while finish < #value and finish > offset do
			local nextByte = string.byte(value, finish + 1)
			if nextByte < 128 or nextByte >= 192 then break end
			finish -= 1
		end
		result.value = string.sub(value, offset + 1, finish)
		result.total = #value
		result.nextOffset = if finish < #value then finish else nil
		while #HttpService:JSONEncode(result) > 10000 and finish > offset do
			finish = offset + math.floor((finish - offset) / 2)
			while finish > offset do
				local nextByte = string.byte(value, finish + 1)
				if not nextByte or nextByte < 128 or nextByte >= 192 then break end
				finish -= 1
			end
			result.value = string.sub(value, offset + 1, finish)
			result.nextOffset = if finish < #value then finish else nil
		end
	elseif typeof(value) == "table" then
		local keys: { any } = {}
		for key in value do table.insert(keys, key) end
		table.sort(keys, function(a, b)
			if typeof(a) == "number" and typeof(b) == "number" then return a < b end
			return tostring(a) < tostring(b)
		end)
		local items: { any } = {}
		result.items = items
		result.total = #keys
		local limit = math.clamp(tonumber(params.resultLimit) or 25, 1, 100)
		for index = offset + 1, math.min(#keys, offset + limit) do
			local key = keys[index]
			local childPath = table.clone(path)
			table.insert(childPath, key)
			local item = value[key]
			if params.resultFields and typeof(item) == "table" then
				local projected: { [string]: any } = {}
				for _, field in params.resultFields do projected[field] = item[field] end
				item = projected
			end
			table.insert(items, { key = key, value = preview(item, childPath) })
			if #HttpService:JSONEncode(result) > 10000 then
				table.remove(items)
				if #items == 0 then
					Dispatch.fail("RESULT_PAGE_TOO_LARGE", "The retained result's path or key exceeds the page budget.",
						"Read a shorter parent resultPath with resultFields, or return shorter keys.")
				end
				break
			end
		end
		result.nextOffset = if offset + #items < #keys then offset + #items else nil
	else
		result.value = value
	end
	return result
end

return Results
