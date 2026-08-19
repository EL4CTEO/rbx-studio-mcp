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

-- Roughly what the Output window keeps. Big enough that a playtest's worth of
-- logging survives, small enough to stay cheap to hold and to scan.
local CAPACITY = 2000

-- Trimming in batches rather than one entry per insert: a chunk that logs in a
-- loop would otherwise shift the whole array on every single line.
local SLACK = 500

export type Entry = {
	level: string,
	message: string,
	timestamp: number,
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

local function push(message: string, messageType: Enum.MessageType, timestamp: number?)
	table.insert(entries, {
		level = LEVELS[messageType.Value] or "print",
		message = message,
		timestamp = timestamp or os.time(),
	})

	if #entries > CAPACITY + SLACK then
		local excess = #entries - CAPACITY
		entries = table.move(entries, excess + 1, #entries, 1, {})
		dropped += excess
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
end

--[[
	Everything held, oldest first, plus how much fell off the front. Returned as a
	copy so a caller filtering it cannot disturb the buffer.
]]
function LogBuffer.all(): ({ Entry }, number)
	return table.move(entries, 1, #entries, 1, {}), dropped
end

return LogBuffer
