--!strict
-- Shared bounded execution results in the VM that calls run.
local LogService = game:GetService("LogService")
local LogBuffer = require(script.Parent.LogBuffer)
local Serialize = require(script.Parent.Serialize)
local Results = require(script.Parent.Results)
-- A chunk that prints in a loop would otherwise return a response no context
-- window can hold.
local MAX_OUTPUT_LINES = 200
local MAX_RETURN_VALUES = 10

-- Returned tables are walked rather than counted, but not without limit: a
-- chunk that returns a whole config tree, or one with a cycle in it, must not be
-- able to produce a response nothing can read.
local MAX_TABLE_ENTRIES = 50
local MAX_TABLE_DEPTH = 4
type Budget = { nodes: number, chars: number, omitted: boolean? }

local function clipped(text: string, cap: number): string
	local last = cap
	while last > 0 do
		local byte = string.byte(text, last + 1)
		if byte < 128 or byte >= 192 then break end
		last -= 1
	end
	return string.sub(text, 1, last) .. "<truncated>"
end

local function describe(value: any, depth: number?, seen: { [any]: boolean }?, shared: Budget?): any
	local budget = shared or {nodes = 300, chars = 10000}
	budget.nodes -= 1
	budget.chars -= 30
	if budget.nodes < 0 or budget.chars < 100 then budget.omitted = true; return "<budget exceeded>" end
	local level = depth or 0
	local visited = seen or {}
	local kind = typeof(value)

	if kind == "function" or kind == "thread" then
		return string.format("<%s>", kind)
	end
	if kind ~= "table" then
		local result = Serialize.value(value)
		if typeof(result) == "string" then
			local cap = math.min(2000, math.floor(budget.chars / 6))
			budget.chars -= math.min(#result, cap) * 6
			if #result > cap then budget.omitted = true end
			return if #result > cap then clipped(result, cap) else result
		end
		return result
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
		budget.omitted = true
		return "<nested table>"
	end
	visited[source] = true

	local count = 0
	local isArray = true
	for key in source do
		if typeof(key) ~= "number" or key < 1 or key > #source or key % 1 ~= 0 then isArray = false end
		count += 1
		if count > MAX_TABLE_ENTRIES then break end
	end

	-- Arrays keep their shape so they read as lists on the other side; anything
	-- with non-sequential keys becomes a map with stringified keys.
	if isArray and (count == #source or count > MAX_TABLE_ENTRIES) then
		local list: { any } = {}
		for index, item in ipairs(source) do
			if index > MAX_TABLE_ENTRIES or budget.nodes <= 0 or budget.chars < 100 then
				budget.omitted = true
				table.insert(list, "<more entries>")
				break
			end
			table.insert(list, describe(item, level + 1, visited, budget))
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
		if shown > MAX_TABLE_ENTRIES or budget.nodes <= 0 or budget.chars < 100 then
			budget.omitted = true
			map["..."] = "<more entries>"
			break
		end
		local name = string.sub(tostring(key), 1, 100)
		budget.chars -= #name * 6
		map[name] = describe(item, level + 1, visited, budget)
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
	local fullOutput: { { [string]: any } } = {}
	local fullOutputBytes = 0
	local outputTruncated = false
	local outputChars, outputDropped = 0, 0
	local connection = LogService.MessageOut:Connect(function(message, messageType, context)
		if #fullOutput < MAX_OUTPUT_LINES and fullOutputBytes + #message <= 131072 then
			fullOutputBytes += #message
			table.insert(fullOutput, { message = message, level = tostring(messageType) })
		end
		if #output < MAX_OUTPUT_LINES and outputChars < 8000 then
			-- A structured log's context rides on the line, as it does in `console`.
			local encoded = LogBuffer.encodeContext(context)
			if encoded then
				message ..= "  " .. encoded
			end
			if #message > math.min(2000, 8000 - outputChars) then
				outputTruncated = true
				message = clipped(message, math.min(2000, 8000 - outputChars))
			end
			outputChars += #message
			table.insert(output, {
				message = message,
				level = if messageType == Enum.MessageType.MessageError
					then "error"
					elseif messageType == Enum.MessageType.MessageWarning then "warning"
					elseif messageType == Enum.MessageType.MessageInfo then "info"
					else "print",
			})
		else outputDropped += 1 end
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
			error = string.sub(tostring(results[2]), 1, 2000),
			output = output,
			milliseconds = math.floor(elapsed * 1000 + 0.5),
		}
	end

	local returned: { any } = {}
	local budget: Budget = {nodes = 300, chars = 6000}
	for index = 2, math.min(results.n, MAX_RETURN_VALUES + 1) do
		-- A nil return is written out rather than dropped. `table.insert` of nil
		-- does nothing, so `return a, nil, b` came back as two values and every
		-- one after the nil shifted into the wrong position.
		local value = results[index]
		table.insert(returned, if value == nil then "nil" else describe(value, nil, nil, budget))
	end

	local response: { [string]: any } = {
		ok = true,
		returned = returned,
		outputDropped = if outputDropped > 0 then outputDropped else nil,
		returnsDropped = if results.n > MAX_RETURN_VALUES + 1 then results.n - MAX_RETURN_VALUES - 1 else nil,
		output = output,
		milliseconds = math.floor(elapsed * 1000 + 0.5),
	}
	if budget.omitted or outputTruncated or outputDropped > 0 or response.returnsDropped then
		local fullReturned: { any } = {}
		for index = 2, results.n do
			table.insert(fullReturned, if results[index] == nil then "nil" else results[index])
		end
		local notRetained = #output + outputDropped - #fullOutput
		local retained = Results.capture({ returned = fullReturned, output = fullOutput,
			outputNotRetained = if notRetained > 0 then notRetained else nil })
		for key, value in retained do response[key] = value end
		response.truncated = true
		response.outputNotRetained = if notRetained > 0 then notRetained else nil
	end
	return response
end
return Runtime
