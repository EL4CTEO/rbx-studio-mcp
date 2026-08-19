--!strict
--[[
	The output log, kept ourselves.

	`LogService:GetLogHistory()` looks like the right API and cannot be relied on.
	Measured: in an editor session it returns a handful of lines from around
	startup and then stops growing -- prints made later never appear -- and in a
	playtest server's DataModel it succeeds and returns nothing at all, even
	immediately after something printed there. The call reports no error either
	way, so the tool built on it answered "the log is empty" for a place that was
	logging steadily, which is worse than answering nothing.

	`LogService.MessageOut` does fire reliably in both. So the buffer is filled
	from the event, seeded once from whatever history the API does offer, and kept
	from growing without bound.

	This has to be connected at plugin load rather than when a read arrives:
	anything logged before the first subscription is gone for good.
]]

local LogService = game:GetService("LogService")
local ScriptContext = game:GetService("ScriptContext")

-- Roughly what the Output window keeps. Big enough that a playtest's worth of
-- logging survives, small enough to stay cheap to hold and to scan.
local CAPACITY = 2000

-- Trimming in batches rather than one entry per insert: a chunk that logs in a
-- loop would otherwise shift the whole array on every single line.
local SLACK = 500

-- How far back an arriving stack trace will look for the error line it belongs
-- to. The two events fire within moments of each other, so anything beyond a
-- handful of entries is a mismatch rather than a late delivery.
local CORRELATION_WINDOW = 20

export type Entry = {
	level: string,
	message: string,
	timestamp: number,
	-- Present on errors once the matching stack trace has been correlated.
	stack: string?,
	source: string?,
}

local LEVELS: { [number]: string } = {
	[Enum.MessageType.MessageOutput.Value] = "print",
	[Enum.MessageType.MessageInfo.Value] = "info",
	[Enum.MessageType.MessageWarning.Value] = "warning",
	[Enum.MessageType.MessageError.Value] = "error",
}

local LogBuffer = {}

local entries: { Entry } = {}
local dropped = 0
local started = false
local startedAt = 0

--[[
	Stack traces that arrived before the error line they describe.

	`ScriptContext.Error` and `LogService.MessageOut` are independent events for
	the same failure and there is no guaranteed order between them, so the trace
	is held here until its line shows up rather than being dropped for arriving
	first.
]]
local orphanedStacks: { [string]: { stack: string, source: string? } } = {}
local orphanCount = 0

local function push(message: string, messageType: Enum.MessageType, timestamp: number?)
	local level = LEVELS[messageType.Value] or "print"
	local entry: Entry = {
		level = level,
		message = message,
		timestamp = timestamp or os.time(),
	}

	-- Claim a trace that beat its own error line here.
	if level == "error" then
		local waiting = orphanedStacks[message]
		if waiting then
			entry.stack = waiting.stack
			entry.source = waiting.source
			orphanedStacks[message] = nil
			orphanCount -= 1
		end
	end

	table.insert(entries, entry)

	if #entries > CAPACITY + SLACK then
		local excess = #entries - CAPACITY
		entries = table.move(entries, excess + 1, #entries, 1, {})
		dropped += excess
	end
end

--[[
	Attaches a stack trace to the error it belongs to.

	Correlated by message text because the engine offers nothing better: the two
	events carry no shared identifier. Matching the most recent unattached error
	with the same text is right in every case that matters, and the worst outcome
	if two identical errors interleave is that a trace lands on the wrong one of
	two identical lines.
]]
local function attachStack(message: string, stack: string, source: string?)
	local first = math.max(1, #entries - CORRELATION_WINDOW + 1)
	for index = #entries, first, -1 do
		local entry = entries[index]
		if entry.level == "error" and entry.message == message and entry.stack == nil then
			entry.stack = stack
			entry.source = source
			return
		end
	end

	-- Not logged yet. Held for the line to claim, with a cap so a flood of
	-- errors that never surface cannot grow this without bound.
	if orphanCount < CAPACITY then
		if orphanedStacks[message] == nil then
			orphanCount += 1
		end
		orphanedStacks[message] = { stack = stack, source = source }
	end
end

--[[
	Begins recording. Safe to call more than once; only the first call connects,
	so a reload cannot end up with two subscriptions writing every line twice.
]]
function LogBuffer.start()
	if started then
		return
	end
	started = true
	startedAt = os.time()

	-- Seeded before subscribing so the backlog stays in order ahead of live
	-- lines. MessageOut only fires for messages after the connection, so nothing
	-- is counted twice.
	local ok, history = pcall(function()
		return LogService:GetLogHistory()
	end)
	if ok and typeof(history) == "table" then
		for _, item in history :: { { [string]: any } } do
			local kind = item.messageType
			if item.message ~= nil and typeof(kind) == "EnumItem" then
				push(tostring(item.message), kind :: Enum.MessageType, item.timestamp)
			end
		end
	end

	LogService.MessageOut:Connect(function(message: string, messageType: Enum.MessageType)
		push(message, messageType)
	end)

	--[[
		Stack traces, which MessageOut does not carry.

		Without this an error in the log is a message and nothing else, while the
		trace arrives separately as loose "Stack Begin / Script X, Line N / Stack
		End" prints that read as unrelated output. Attaching it to the error turns
		three ambiguous lines into one answer with a script and a line number.

		`ErrorDetailed` would be the richer source and is closed to plugins --
		it needs the RobloxScript capability. `Error` is reachable and carries
		message, trace and originating script, which is the part that matters.
	]]
	pcall(function()
		ScriptContext.Error:Connect(function(message: string, stack: string, source: Instance?)
			local origin: string? = nil
			if typeof(source) == "Instance" then
				local named = pcall(function()
					origin = source:GetFullName()
				end)
				if not named then
					origin = source.Name
				end
			end
			attachStack(message, stack, origin)
		end)
	end)
end

--[[
	Everything held, oldest first, plus how much fell off the front. Returned as a
	copy so a caller filtering it cannot disturb the buffer.
]]
function LogBuffer.all(): ({ Entry }, number)
	return table.move(entries, 1, #entries, 1, {}), dropped
end

--[[
	How long this buffer has been recording, in seconds.

	An empty log is ambiguous without it. In a playtest the plugin loads at the
	same moment as the place's own scripts, so a script that logs on startup can
	beat the subscription -- and "nothing was logged" then looks identical to
	"recording began after the thing you are asking about". Reporting the window
	lets the two be told apart instead of guessed at.
]]
function LogBuffer.recordingSeconds(): number
	if not started then
		return 0
	end
	return math.max(0, os.time() - startedAt)
end

return LogBuffer
