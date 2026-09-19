--!strict
-- Shared bounded execution results in the VM that calls run.
local LogService = game:GetService("LogService")
local Serialize = require(script.Parent.Serialize)
-- A chunk that prints in a loop would otherwise return a response no context
-- window can hold.
local MAX_OUTPUT_LINES = 200
local MAX_RETURN_VALUES = 10

-- Returned tables are walked rather than counted, but not without limit: a
-- chunk that returns a whole config tree, or one with a cycle in it, must not be
-- able to produce a response nothing can read.
local MAX_TABLE_ENTRIES = 50
local MAX_TABLE_DEPTH = 4

local function describe(value: any, depth: number?, seen: { [any]: boolean }?): any
	local level = depth or 0
	local visited = seen or {}
	local kind = typeof(value)

	if kind == "function" or kind == "thread" then
		return string.format("<%s>", kind)
	end
	if kind ~= "table" then
		return Serialize.value(value)
	end

	local source = value :: { [any]: any }
	-- Named separately from the depth cap, because they mean opposite things to
	-- a reader. The depth cap says "there is more below this"; a cycle says
	-- "this is the table you are already inside". Reporting the second as the
	-- first printed `t.self.self.self` as three distinct nested tables, which
	-- reads as real structure that does not exist.
	if visited[source] then
		return "<circular reference>"
	end
	if level >= MAX_TABLE_DEPTH then
		return "<nested table>"
	end
	visited[source] = true

	local count = 0
	for _ in source do
		count += 1
	end

	-- Arrays keep their shape so they read as lists on the other side; anything
	-- with non-sequential keys becomes a map with stringified keys.
	if count == #source then
		local list: { any } = {}
		for index, item in ipairs(source) do
			if index > MAX_TABLE_ENTRIES then
				table.insert(list, string.format("<%d more>", count - MAX_TABLE_ENTRIES))
				break
			end
			table.insert(list, describe(item, level + 1, visited))
		end
		-- Cleared on the way out so the same table appearing twice side by side
		-- still renders twice; only a table containing itself is a cycle.
		visited[source] = nil
		return list
	end

	local map: { [string]: any } = {}
	local shown = 0
	for key, item in source do
		shown += 1
		if shown > MAX_TABLE_ENTRIES then
			map["..."] = string.format("<%d more>", count - MAX_TABLE_ENTRIES)
			break
		end
		map[tostring(key)] = describe(item, level + 1, visited)
	end
	visited[source] = nil
	return map
end

local Runtime = {}
Runtime.describe = describe
function Runtime.run(chunk: () -> ...any, timeout: number?): { [string]: any }
	-- Captured rather than inferred: a chunk's prints are usually the point, and
	-- reading them back from the log afterwards would also pick up whatever else
	-- the place logged in the meantime.
	local output: { { [string]: any } } = {}
	local connection = LogService.MessageOut:Connect(function(message, messageType)
		if #output < MAX_OUTPUT_LINES then
			table.insert(output, {
				message = message,
				level = if messageType == Enum.MessageType.MessageError
					then "error"
					elseif messageType == Enum.MessageType.MessageWarning then "warning"
					else "print",
			})
		end
	end)

	local started = os.clock()
	local results: any = nil
	if timeout then
		local worker = task.spawn(function() results = table.pack(pcall(chunk :: any)) end)
		local deadline = started + timeout
		while results == nil and os.clock() < deadline do task.wait() end
		if results == nil then
			task.cancel(worker)
			results = table.pack(false, "CLIENT_TIMEOUT: execution exceeded " .. tostring(timeout) .. "s")
		end
	else
		results = table.pack(pcall(chunk :: () -> ...any))
	end
	local elapsed = os.clock() - started

	--[[
		MessageOut is deferred: `print` returns before the event fires, so
		disconnecting straight after the chunk finished captured nothing at all.
		A short settle picks the lines up.

		It is bounded and stops as soon as the flow stops, rather than waiting a
		fixed period, so a chunk that logged nothing costs almost no time and one
		that logged plenty is not truncated.
	]]
	local settleDeadline = os.clock() + 0.5
	local seen = #output
	local quietFrames = 0
	while os.clock() < settleDeadline and quietFrames < 3 do
		task.wait()
		if #output == seen then
			quietFrames += 1
		else
			seen = #output
			quietFrames = 0
		end
	end

	connection:Disconnect()

	if not results[1] then
		return {
			ok = false,
			error = tostring(results[2]),
			output = output,
			milliseconds = math.floor(elapsed * 1000 + 0.5),
		}
	end

	local returned: { any } = {}
	for index = 2, math.min(results.n, MAX_RETURN_VALUES + 1) do
		-- A nil return is written out rather than dropped. `table.insert` of nil
		-- does nothing, so `return a, nil, b` came back as two values and every
		-- one after the nil shifted into the wrong position.
		local value = results[index]
		table.insert(returned, if value == nil then "nil" else describe(value))
	end

	return {
		ok = true,
		returned = returned,
		output = output,
		milliseconds = math.floor(elapsed * 1000 + 0.5),
	}
end
return Runtime
