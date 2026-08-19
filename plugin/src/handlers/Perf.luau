--!strict
--[[
	Output and performance: the Developer Console and Script Performance windows,
	readable by an agent.

	These are the panels a developer opens when something is slow or broken, and
	no other Studio MCP server exposes them. Being able to say "which script is
	eating the frame" without the user reading a graph and describing it back is
	the difference between diagnosing a problem and guessing at one.

	`Stats` time properties are in seconds and reported here in milliseconds,
	because every frame budget a developer reasons about is quoted in ms.
]]

local LogService = game:GetService("LogService")
local ScriptProfilerService = game:GetService("ScriptProfilerService")
local Stats = game:GetService("Stats")

local Dispatch = require(script.Parent.Parent.Dispatch)

-- The log holds thousands of lines in a busy session; an unbounded tail would
-- swamp any context window.
local MAX_LOG_ENTRIES = 500
local DEFAULT_LOG_ENTRIES = 100

-- Profiling is a blocking wait, so the ceiling is what a caller will sit through
-- rather than what the profiler can manage.
local MAX_PROFILE_SECONDS = 30
local DEFAULT_PROFILE_SECONDS = 5
local PROFILE_DATA_TIMEOUT = 5

local LEVELS: { [number]: string } = {
	[Enum.MessageType.MessageOutput.Value] = "print",
	[Enum.MessageType.MessageInfo.Value] = "info",
	[Enum.MessageType.MessageWarning.Value] = "warning",
	[Enum.MessageType.MessageError.Value] = "error",
}

local Perf = {}

local function round(value: number, places: number): number
	local scale = 10 ^ places
	return math.floor(value * scale + 0.5) / scale
end

--[[
	Reads a Stats property without assuming it exists. The set has changed across
	engine versions, and one missing counter should not fail the whole snapshot.
]]
local function stat(name: string): number?
	local ok, value = pcall(function()
		return (Stats :: any)[name]
	end)
	if ok and typeof(value) == "number" then
		return value
	end
	return nil
end

local function millis(name: string): number?
	local seconds = stat(name)
	return if seconds then round(seconds * 1000, 3) else nil
end

local function rounded(name: string, places: number): number?
	local value = stat(name)
	return if value then round(value, places) else nil
end

--[[
	The output log, newest last.

	Ordering matters: an agent reading a tail wants the most recent lines at the
	bottom, the same way the Output window reads, so an error and the lines that
	led to it stay in the order they happened.
]]
function Perf.console(params: { [string]: any }): { [string]: any }
	local limit = math.clamp(tonumber(params.limit) or DEFAULT_LOG_ENTRIES, 1, MAX_LOG_ENTRIES)
	local level = params.level
	local pattern = params.pattern

	local ok, history = pcall(function()
		return LogService:GetLogHistory()
	end)
	if not ok or typeof(history) ~= "table" then
		Dispatch.fail(
			"NO_LOG",
			"Studio would not return the output log.",
			"This usually means the Output window has never been opened in this session."
		)
	end

	local entries: { { [string]: any } } = {}
	local matched = 0

	for _, item in history :: { { [string]: any } } do
		local kind = LEVELS[item.messageType and item.messageType.Value or -1] or "print"
		if level and kind ~= level then
			continue
		end

		local message = tostring(item.message)
		if pattern then
			-- An invalid pattern raises rather than failing to match, so it is
			-- reported as a pattern problem instead of an empty result.
			local valid, position = pcall(string.find, message, pattern)
			if not valid then
				Dispatch.fail(
					"BAD_PATTERN",
					string.format("%s is not a valid Lua pattern: %s", pattern, tostring(position)),
					"Lua patterns escape with %, not backslash. Omit `pattern` to see everything."
				)
			end
			if position == nil then
				continue
			end
		end

		matched += 1
		table.insert(entries, {
			level = kind,
			message = message,
			timestamp = item.timestamp,
		})
	end

	-- Trimmed from the front: the newest lines are the ones worth keeping.
	local dropped = 0
	if #entries > limit then
		dropped = #entries - limit
		entries = table.move(entries, dropped + 1, #entries, 1, {})
	end

	return {
		items = entries,
		total = matched,
		dropped = dropped,
	}
end

--[[
	A snapshot of the engine's own counters -- what the Developer Console shows on
	its Performance and Memory tabs.
]]
function Perf.snapshot(): { [string]: any }
	local memory: { { [string]: any } } = {}
	local okMemory, categories = pcall(function()
		return Stats:GetMemoryUsageMbAllCategories()
	end)
	if okMemory and typeof(categories) == "table" then
		for name, value in categories :: { [string]: any } do
			if typeof(value) == "number" and value > 0 then
				table.insert(memory, { category = name, megabytes = round(value, 2) })
			end
		end
		table.sort(memory, function(a, b)
			return a.megabytes > b.megabytes
		end)
	end

	local okTotal, total = pcall(function()
		return Stats:GetTotalMemoryUsageMb()
	end)

	return {
		frame = {
			frameTimeMs = millis("FrameTime"),
			heartbeatTimeMs = millis("HeartbeatTime"),
			physicsStepTimeMs = millis("PhysicsStepTime"),
			renderCpuMs = millis("RenderCPUFrameTime"),
			renderGpuMs = millis("RenderGPUFrameTime"),
		},
		scene = {
			instances = stat("InstanceCount"),
			parts = stat("PrimitivesCount"),
			movingParts = stat("MovingPrimitivesCount"),
			contacts = stat("ContactsCount"),
			drawcalls = stat("SceneDrawcallCount"),
			triangles = stat("SceneTriangleCount"),
		},
		network = {
			receiveKbps = rounded("DataReceiveKbps", 1),
			sendKbps = rounded("DataSendKbps", 1),
		},
		memory = {
			totalMb = if okTotal and typeof(total) == "number" then round(total, 1) else nil,
			categories = memory,
		},
	}
end

--[[
	Runs the script profiler for a while and returns what it collected.

	This is the Script Performance window. The profiler samples at `frequency` Hz
	and reports back through an event rather than a return value, so the call
	starts it, waits, asks for the data, and stops -- blocking for the duration,
	which is why the ceiling is short.

	The payload's shape is Roblox's own and undocumented, so it is passed through
	rather than reshaped into something that might quietly misreport which script
	is expensive.
]]
function Perf.profile(params: { [string]: any }): { [string]: any }
	local seconds = math.clamp(
		tonumber(params.seconds) or DEFAULT_PROFILE_SECONDS,
		1,
		MAX_PROFILE_SECONDS
	)
	local frequency = math.clamp(tonumber(params.frequency) or 1000, 100, 10000)

	local received: string? = nil
	local connection = ScriptProfilerService.OnNewData:Connect(function(_player, jsonString)
		received = jsonString
	end)

	local started, startError = pcall(function()
		ScriptProfilerService:ServerStart(frequency)
	end)
	if not started then
		connection:Disconnect()
		Dispatch.fail(
			"PROFILER_UNAVAILABLE",
			string.format("Could not start the script profiler: %s", tostring(startError)),
			"The profiler is only available in Studio, and only one session at a time."
		)
	end

	task.wait(seconds)

	pcall(function()
		ScriptProfilerService:ServerRequestData()
	end)

	-- The data arrives on the event, so the request is followed by a bounded wait
	-- rather than assuming it has already landed.
	local deadline = os.clock() + PROFILE_DATA_TIMEOUT
	while received == nil and os.clock() < deadline do
		task.wait(0.1)
	end

	pcall(function()
		ScriptProfilerService:ServerStop()
	end)
	connection:Disconnect()

	if received == nil then
		Dispatch.fail(
			"NO_PROFILE_DATA",
			string.format("The profiler ran for %ds but returned no data.", seconds),
			"Nothing ran during the sample. Start a playtest first, or profile for longer."
		)
	end

	local okParse, parsed = pcall(function()
		return ScriptProfilerService:DeserializeJSON(received)
	end)

	return {
		seconds = seconds,
		frequency = frequency,
		data = if okParse then parsed else nil,
		raw = if okParse then nil else received,
	}
end

function Perf.register()
	Dispatch.registerAll("perf", {
		console = Perf.console,
		snapshot = function()
			return Perf.snapshot()
		end,
		profile = Perf.profile,
	})
end

return Perf
