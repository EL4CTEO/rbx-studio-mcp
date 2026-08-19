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

local ScriptContext = game:GetService("ScriptContext")
local RunService = game:GetService("RunService")
local ScriptProfilerService = game:GetService("ScriptProfilerService")
local Stats = game:GetService("Stats")

local Dispatch = require(script.Parent.Parent.Dispatch)
local LogBuffer = require(script.Parent.Parent.LogBuffer)
local Paths = require(script.Parent.Parent.Paths)

-- The log holds thousands of lines in a busy session; an unbounded tail would
-- swamp any context window.
local MAX_LOG_ENTRIES = 500
local DEFAULT_LOG_ENTRIES = 100

-- Profiling is a blocking wait, so the ceiling is what a caller will sit through
-- rather than what the profiler can manage.
local MAX_PROFILE_SECONDS = 30
local DEFAULT_PROFILE_SECONDS = 5
local PROFILE_DATA_TIMEOUT = 5

-- Uncovered line numbers are listed, not just counted, but a script that never
-- ran at all would otherwise list every line it has.
local MAX_UNCOVERED_LINES = 50

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

local function flag(name: string): boolean?
	local ok, value = pcall(function()
		return (Stats :: any)[name]
	end)
	if ok and typeof(value) == "boolean" then
		return value
	end
	return nil
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

	-- Read from our own buffer, not LogService:GetLogHistory(). See LogBuffer for
	-- why: the engine's history stops growing after startup in an editor session
	-- and is empty outright in a playtest, without reporting either as a failure.
	local history, evicted = LogBuffer.all()

	local entries: { { [string]: any } } = {}
	local matched = 0

	for _, item in history do
		local kind = item.level
		if level and kind ~= level then
			continue
		end

		local message = item.message
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
		-- Lines lost to the buffer's own capacity, as opposed to ones trimmed to
		-- satisfy this call's limit. Only the first is a reason to worry.
		evicted = if evicted > 0 then evicted else nil,
		recordingSeconds = LogBuffer.recordingSeconds(),
	}
end

--[[
	A snapshot of the engine's own counters -- what the Developer Console shows on
	its Performance and Memory tabs.
]]
function Perf.snapshot(): { [string]: any }
	--[[
		Read one tag at a time, not with `GetMemoryUsageMbAllCategories`.

		The aggregate call is the obvious one and is closed to us: it now requires
		the InternalTest capability, so from a plugin it only ever raises "the
		current thread cannot call 'GetMemoryUsageMbAllCategories'". Measured, not
		assumed -- and the same refusal comes back in an editor session and in a
		playtest, so there is no context in which waiting for it pays off.

		`GetMemoryUsageMbForTag` carries no such restriction, and walking
		`Enum.DeveloperMemoryTag` reaches every category the Developer Console's
		Memory tab shows. Zero-valued tags are dropped so the list stays readable.
	]]
	local memory: { { [string]: any } } = {}
	local memoryProblem: string? = nil

	for _, tag in Enum.DeveloperMemoryTag:GetEnumItems() do
		local ok, value = pcall(function()
			return Stats:GetMemoryUsageMbForTag(tag)
		end)
		if not ok then
			-- One refusal means the whole route is shut, not that this tag is
			-- special; stop rather than repeat the same failure for every item.
			memoryProblem = string.format("Stats refused the call: %s", tostring(value))
			break
		end
		if typeof(value) == "number" and value > 0 then
			table.insert(memory, { category = tag.Name, megabytes = round(value, 2) })
		end
	end

	table.sort(memory, function(a, b)
		return a.megabytes > b.megabytes
	end)

	local okTotal, total = pcall(function()
		return Stats:GetTotalMemoryUsageMb()
	end)

	--[[
		A playtest server has no renderer, so every drawing counter reads zero --
		zero draw calls, zero triangles, no frame time. Left unexplained that is
		the most flattering possible misreading of a place's performance, so the
		snapshot says outright that those numbers are absent rather than good.
	]]
	local headless = RunService:IsRunning() and RunService:IsServer() and not RunService:IsClient()

	return {
		renderless = headless or nil,
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
			-- Studio only accumulates the per-category breakdown while this is on,
			-- so an empty list means "not measured" rather than "nothing used".
			trackingEnabled = flag("MemoryTrackingEnabled"),
			categories = memory,
			problem = if #memory == 0 then memoryProblem else nil,
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

--[[
	Line coverage: which lines of which scripts actually ran.

	Coverage has to be switched on for a script before that script executes, so a
	call that only reads the stats reports nothing on a first run. `enable` turns
	it on for named scripts; the caller then plays, and reads back afterwards.
]]
function Perf.coverage(params: { [string]: any }): { [string]: any }
	local enabled: { string } = {}
	for _, path in (params.enable or {}) :: { string } do
		local target = Paths.resolve(path)
		local ok = pcall(function()
			ScriptContext:EnableCoverage(target)
		end)
		if ok then
			table.insert(enabled, Paths.of(target))
		end
	end

	local ok, stats = pcall(function()
		return ScriptContext:GetCoverageStats()
	end)
	if not ok or typeof(stats) ~= "table" then
		return { enabled = enabled, scripts = {}, problem = tostring(stats) }
	end

	--[[
		The payload is undocumented, so this is the shape measured from a real
		capture rather than a guess: each entry is `{ Script = Instance, GetHits =
		function }`, and `GetHits()` returns an array indexed by line number.

		The values carry three distinct meanings, and conflating them is what an
		earlier attempt here did:
		  -1  the line cannot be instrumented at all -- blank, a comment, an `end`
		   0  instrumented and never executed: the lines worth reporting
		  >0  the number of times it ran

		Counting every element as instrumented drags the denominator up by every
		blank line and comment in the file, which understates coverage on exactly
		the well-commented code most likely to be measured.
	]]
	local scripts: { { [string]: any } } = {}
	local unrecognised: any = nil

	for _, entry in stats :: { any } do
		if typeof(entry) ~= "table" then
			unrecognised = stats
			break
		end

		local record = entry :: { [string]: any }
		local target = record.Script or record.script
		local getHits = record.GetHits

		if typeof(getHits) ~= "function" then
			unrecognised = stats
			break
		end

		local gotHits, hits = pcall(getHits, record)
		if not gotHits or typeof(hits) ~= "table" then
			unrecognised = stats
			break
		end

		local instrumented = 0
		local covered = 0
		-- The lines that never ran are the entire point of asking, so they are
		-- named rather than left to be inferred from a percentage.
		local missed: { number } = {}

		for line, count in hits :: { number } do
			if typeof(count) ~= "number" or count < 0 then
				continue
			end
			instrumented += 1
			if count > 0 then
				covered += 1
			elseif #missed < MAX_UNCOVERED_LINES then
				table.insert(missed, line)
			end
		end

		table.sort(missed)

		table.insert(scripts, {
			path = if typeof(target) == "Instance" then Paths.of(target) else tostring(target),
			instrumentedLines = instrumented,
			coveredLines = covered,
			uncoveredLines = missed,
			percent = if instrumented > 0
				then math.floor(covered / instrumented * 1000 + 0.5) / 10
				else 0,
		})
	end

	return {
		enabled = enabled,
		scripts = scripts,
		raw = unrecognised,
	}
end

function Perf.register()
	Dispatch.registerAll("perf", {
		console = Perf.console,
		snapshot = function()
			return Perf.snapshot()
		end,
		profile = Perf.profile,
		coverage = Perf.coverage,
	})
end

return Perf
