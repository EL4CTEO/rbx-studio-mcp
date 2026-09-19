--!strict
-- Passive, bounded RemoteEvent observations shared by the server and client.
local Paths = require(script.Parent.Paths)
local Trace = {}
local MAX_EVENTS = 1000 -- per direction; disconnect at the cap, never keep raw payloads
local MAX_REMOTES = 128
local MAX_ROWS = 20
local MAX_VISITS = 10000

local function brief(value: string, limit: number): string
	local clipped = string.sub(value, 1, limit)
	-- ASCII keeps invalid UTF-8, controls and JSON escaping from expanding output.
	clipped = string.gsub(clipped, "[^ -~]", "?")
	return clipped .. (if #value > limit then "..." else "")
end

local function pathOf(remote: Instance): string
	local path = Paths.of(remote)
	if #path <= 256 then return path end
	-- Keep Unicode instance names valid at the byte boundary.
	local ok, boundary = pcall(utf8.offset, path, 0, 257)
	return string.sub(path, 1, if ok and boundary then boundary - 1 else 256) .. "..."
end

local function shape(value: any, depth: number): string
	local kind = typeof(value)
	if kind == "string" then return "string:" .. string.format("%q", brief(value, 32)) end
	if kind == "number" or kind == "boolean" or kind == "nil" then return kind .. ":" .. tostring(value) end
	if kind == "Instance" then return "Instance<" .. value.ClassName .. ">" end
	if kind ~= "table" then return kind end
	if depth >= 2 then return "table{...}" end
	local parts = {}
	local key, item = next(value)
	for _ = 1, 4 do
		if key == nil then break end
		local label = if typeof(key) == "string" then brief(key, 20) else typeof(key)
		table.insert(parts, label .. "=" .. shape(item, depth + 1))
		key, item = next(value, key)
	end
	if key ~= nil then table.insert(parts, "...") end
	return brief("table{" .. table.concat(parts, ",") .. "}", 160)
end

function Trace.arguments(...: any): string
	local parts = {}
	local count = select("#", ...)
	for index = 1, math.min(count, 6) do
		table.insert(parts, shape(select(index, ...), 0))
	end
	if count > 6 then table.insert(parts, "...") end
	return brief("(" .. table.concat(parts, ", ") .. ")", 192)
end

-- Returns an idempotent stop function; its deadline also cleans up if the caller fails.
function Trace.start(root: Instance, player: Player, client: boolean, seconds: number, excluded: Instance?): () -> { [string]: any }
	local connections: { RBXScriptConnection } = {}
	local watched: { [Instance]: boolean } = {}
	local rows: { any } = {}
	local byRemote: { [Instance]: any } = {}
	local events, remotes, visits = 0, 0, 0
	local omitted, scanLimited, eventLimited = false, false, false
	local skipped = 0
	local active = true
	local started = os.clock()
	local elapsed = 0
	local timer: thread? = nil
	local function stop(): { [string]: any }
		if active then
			active = false
			elapsed = math.max(os.clock() - started, 0.001)
			for _, connection in connections do connection:Disconnect() end
			if timer then task.cancel(timer); timer = nil end
			for _, row in rows do row.callsPerSecond = math.round(row.count / elapsed * 100) / 100 end
		end
		return { items = rows, events = events, seconds = elapsed, watched = remotes,
			eventLimitReached = eventLimited, scanLimitReached = scanLimited, rowsOmitted = omitted, skipped = skipped }
	end
	local function record(remote: Instance, ...: any)
		if not active or (remote ~= root and not remote:IsDescendantOf(root)) then return end
		events += 1
		local row = byRemote[remote]
		if row == nil and #rows < MAX_ROWS then
			row = { path = pathOf(remote), direction = if client then "server -> client" else "client -> server",
				player = brief(player.Name, 64), count = 0, samples = {} }
			byRemote[remote] = row
			table.insert(rows, row)
		end
		if row then
			row.count += 1
			if #row.samples < 2 then
				local sample = Trace.arguments(...)
				if row.samples[1] ~= sample then table.insert(row.samples, sample) end
			end
		else omitted = true end
		if events >= MAX_EVENTS then eventLimited = true; stop() end
	end
	local function attach(remote: Instance)
		if not active or watched[remote] or not remote:IsA("RemoteEvent") then return end
		if excluded and (remote == excluded or remote:IsDescendantOf(excluded)) then return end
		-- Ignore all temporary bridge traffic, including overlapping MCP calls.
		local ancestor: Instance? = remote.Parent
		while ancestor and ancestor ~= game do
			if ancestor:GetAttribute("MCPClientRelay") == true then return end
			ancestor = ancestor.Parent
		end
		if remotes >= MAX_REMOTES then scanLimited = true; return end
		watched[remote] = true
		remotes += 1
		if client then
			table.insert(connections, (remote :: RemoteEvent).OnClientEvent:Connect(function(...) record(remote, ...) end))
		else
			table.insert(connections, (remote :: RemoteEvent).OnServerEvent:Connect(function(from, ...)
				if from == player then record(remote, ...) end
			end))
		end
	end
	local ok, failure = pcall(function()
		-- Subscribe first, then scan so remotes created during discovery are not missed.
		table.insert(connections, root.DescendantAdded:Connect(function(object)
			if visits >= MAX_VISITS then scanLimited = true; return end
			visits += 1
			local attached = pcall(attach, object)
			if not attached then skipped += 1 end
		end))
		local pending = { root }
		while #pending > 0 and visits < MAX_VISITS do
			local object = table.remove(pending) :: Instance
			visits += 1
			attach(object)
			local readable, children = pcall(object.GetChildren, object)
			if not readable then skipped += 1; continue end
			for _, child in children do
				if visits + #pending >= MAX_VISITS then scanLimited = true; break end
				table.insert(pending, child)
			end
		end
		if #pending > 0 then scanLimited = true end
		timer = task.delay(seconds, function() timer = nil; stop() end)
	end)
	if not ok then stop(); error(failure, 0) end
	return stop
end
return Trace
