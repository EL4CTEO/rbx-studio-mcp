--!strict
--[[
	MicroProfiler captures, read through Roblox's own LibMP.

	The Script Performance window (`perf.profile`) only sees Luau. Most frame
	spikes are not Luau: physics, rendering, replication, a GC step, an engine
	job. The MicroProfiler sees all of it, scope by scope and thread by thread,
	and until now the only way to get it in front of an agent was a manual dump
	and a screenshot.

	LibMP (github.com/Roblox/libmp, MIT) is the official reader for
	`MicroProfilerService`'s binary channel. It is 3.3 MB of generated Luau, so it
	is NOT packed into the plugin: the server ships it and this module fetches it
	the first time a capture is asked for, then keeps it for the session. A
	plugin that never profiles never pays for it.

	Durations are attributed frame-locally (a scope that began in an earlier
	frame only counts from this frame's start), and self time is inclusive time
	minus the inclusive time of direct children -- the number that says where the
	work actually happened rather than which scope happened to contain it.
]]

local Dispatch = require(script.Parent.Dispatch)
local Net = require(script.Parent.Net)

local MicroProfiler = {}

local DEFAULT_FRAMES = 64
local MAX_FRAMES = 256
local DEFAULT_TOP = 20
local MAX_TOP = 60
-- Steps between yields while walking a capture. Keeps Studio responsive on a
-- 256-frame capture of a busy session without making a small one slower.
local YIELD_EVERY = 25_000

--[[
	Scopes that are the absence of work. They dominate any ranking by time --
	"Sleep" was 10 s of a 64-frame capture in an idle Studio -- and say nothing.
]]
local IDLE_NAMES = {
	["Sleep"] = true,
	["Wait"] = true,
	["Idle"] = true,
	["WaitForFrame"] = true,
	["WaitForSingleObject"] = true,
	["Yield"] = true,
}

local libmp: any = nil
local loadMs: number? = nil

local function compile(source: string): any
	local ok, chunk = pcall(loadstring :: any, source, "=LibMP")
	if ok and typeof(chunk) == "function" then
		return chunk()
	end
	-- A playtest server disables loadstring; a ModuleScript still compiles.
	local module = Instance.new("ModuleScript")
	module.Name = "LibMP"
	local settable = pcall(function()
		module.Source = source
	end)
	if not settable then
		module:Destroy()
		Dispatch.fail("LIBMP_UNAVAILABLE", "This session can neither loadstring nor set a script's source, so LibMP cannot load here.")
	end
	local required, result = pcall(require, module)
	module:Destroy()
	if not required then
		Dispatch.fail("LIBMP_UNAVAILABLE", string.format("LibMP failed to load: %s", tostring(result)))
	end
	return result
end

local function load(): any
	if libmp ~= nil then
		return libmp
	end
	local started = os.clock()
	local response = Net.request("GET", "/vendor/libmp", nil)
	if not response.ok or #response.body < 1000 then
		Dispatch.fail(
			"LIBMP_UNAVAILABLE",
			string.format("Could not fetch LibMP from the server: %s", tostring(response.error or response.statusCode)),
			"Update the MCP server; LibMP ships with it from 1.0.5."
		)
	end
	local loaded = compile(response.body)
	if typeof(loaded) ~= "table" or loaded.Control == nil then
		Dispatch.fail("LIBMP_UNAVAILABLE", "LibMP loaded but did not return its module table.")
	end
	if not loaded.Control:IsBackendReady() then
		Dispatch.fail(
			"LIBMP_UNAVAILABLE",
			"MicroProfilerService is not reachable or its data format is newer than this LibMP.",
			"Update the MCP server to get a newer LibMP."
		)
	end
	libmp = loaded
	loadMs = math.round((os.clock() - started) * 1000)
	return loaded
end

-- " RBX Worker C" and " RBX Worker K" are one pool; ranking them apart splits
-- one hot job into a dozen small-looking rows.
local function threadClass(name: string): string
	local trimmed = string.match(name, "^%s*(.-)%s*$") or name
	local pool = string.match(trimmed, "^(RBX Worker) %a$")
	if pool then
		return pool
	end
	pool = string.match(trimmed, "^(HttpClientHandler::worker)")
	return pool or trimmed
end

local function percentile(sorted: { number }, p: number): number
	if #sorted == 0 then
		return 0
	end
	local index = math.clamp(math.ceil(#sorted * p), 1, #sorted)
	return sorted[index]
end

local function round(value: number): number
	return math.round(value * 1000) / 1000
end

type Row = {
	thread: string,
	timer: number,
	total: number,
	self: number,
	calls: number,
	perFrame: { [number]: number },
}

function MicroProfiler.capture(params: { [string]: any }): { [string]: any }
	local firstLoad = libmp == nil
	local LibMP = load()
	local control = LibMP.Control

	local frames = math.clamp(math.floor(tonumber(params.frames) or DEFAULT_FRAMES), 4, MAX_FRAMES)
	local top = math.clamp(math.floor(tonumber(params.top) or DEFAULT_TOP), 1, MAX_TOP)
	local filter = if typeof(params.filter) == "string" and params.filter ~= "" then string.lower(params.filter) else nil
	local threadFilter = if typeof(params.thread) == "string" and params.thread ~= "" then string.lower(params.thread) else nil
	local includeIdle = params.includeIdle == true
	local sortBy = if params.sort == "total" then "total" else "self"

	control:SetFrameLimit(frames)
	control:EnableProfiler(true)
	control:EnableCapture(true)

	-- The profiler records a rolling window, so a capture is the last `frames`
	-- frames. Waiting long enough to fill it at 60 FPS (plus slack) is the only
	-- wait needed; `seconds` lets a caller hold it open across a known spike.
	local wait = tonumber(params.seconds) or (frames / 60 + 0.5)
	task.wait(math.clamp(wait, 0.2, 30))

	local captured = control:CaptureToBufferSync()
	if params.keepRunning ~= true then
		control:EnableProfiler(false)
	end
	if captured == nil then
		Dispatch.fail("NO_CAPTURE", "The MicroProfiler returned no capture.", "Try again; the first capture after enabling can be empty.")
	end

	local session = LibMP.Session.OpenFromBuffer(captured)
	if not session or not session:IsValid() then
		if session then
			session:Dispose()
		end
		Dispatch.fail("NO_CAPTURE", "The capture could not be opened.")
	end

	local ok, result = pcall(function()
		local global = session:FetchGlobalDesc()
		local tick = global.TickToMsCpu
		local frameMin, frameMax = session:GetFrameIdMin(), session:GetFrameIdMax()
		if frameMin == 0 and frameMax == 0 then
			Dispatch.fail("NO_CAPTURE", "The capture holds no frames yet.", "Capture again after a second.")
		end

		-- Frame times from the CPU frame boundaries.
		local frameMs: { [number]: number } = {}
		local frameList: { number } = {}
		for frameId = frameMin, frameMax do
			local desc = session:FetchFrameDesc(frameId)
			if desc and not desc.IsPaused then
				local ms = (desc.TickEndCpu - desc.TickStartCpu) * tick
				if ms > 0 then
					frameMs[frameId] = ms
					table.insert(frameList, ms)
				end
			end
		end
		local sortedFrames = table.clone(frameList)
		table.sort(sortedFrames)
		local worstFrame, worstMs = 0, -1
		for frameId, ms in frameMs do
			if ms > worstMs then
				worstFrame, worstMs = frameId, ms
			end
		end
		local sum = 0
		for _, ms in frameList do
			sum += ms
		end

		-- Thread names, and which threads to walk.
		local threadName: { [number]: string } = {}
		local threadIds: { number } = {}
		local threadCount = 0
		for _, id in session:FetchThreadIds() do
			local desc = session:FetchThreadDesc(id)
			if not desc.IsGpu then
				threadCount += 1
				local class = threadClass(desc.ThreadName)
				threadName[id] = class
				if threadFilter == nil or string.find(string.lower(desc.ThreadName), threadFilter, 1, true) then
					table.insert(threadIds, id)
				end
			end
		end
		if #threadIds == 0 then
			Dispatch.fail("NOT_FOUND", string.format("No CPU thread matches %q.", tostring(params.thread)), 'Main thread is "RBX Main"; workers are "RBX Worker".')
		end

		local iterator = session:CreateLogIterator()
		iterator:Configure({
			ThreadIds = threadIds,
			SkipGpuThreads = true,
			SkipEvents = true,
			SkipPausedFrames = true,
		})
		local state = iterator:GetState()

		local rows: { [string]: Row } = {}
		local kids: { [number]: { [number]: number } } = {}
		local steps = 0
		while iterator:Step() do
			steps += 1
			if steps % YIELD_EVERY == 0 then
				task.wait()
			end
			if state:IsExit() and not state:ThreadStackIsUnderflowed() then
				local level = state:ThreadStackDepth()
				local element = iterator:GetCurrentThreadStackElement(level)
				if element then
					local thread = state:ThreadId()
					local duration = math.max(0, (state:Timestamp() - element:EnterTimestampFrameLocal()) * tick)
					local children = kids[thread]
					if children == nil then
						children = {}
						kids[thread] = children
					end
					local self = math.max(0, duration - (children[level] or 0))
					children[level] = 0
					if level > 0 then
						children[level - 1] = (children[level - 1] or 0) + duration
					end

					local timer = state:TimerId()
					local class = threadName[thread] or "?"
					local key = class .. "\0" .. timer
					local row = rows[key]
					if row == nil then
						row = { thread = class, timer = timer, total = 0, self = 0, calls = 0, perFrame = {} }
						rows[key] = row
					end
					row.total += duration
					row.self += self
					row.calls += 1
					local frameId = state:FrameId()
					row.perFrame[frameId] = (row.perFrame[frameId] or 0) + duration
				end
			end
		end
		iterator:Dispose()

		-- Names, filters, ranking.
		local timerCache: { [number]: { name: string, group: string } } = {}
		local groupCache: { [number]: string } = {}
		local function describe(timer: number)
			local cached = timerCache[timer]
			if cached then
				return cached
			end
			local desc = session:FetchTimerDesc(timer)
			local group = groupCache[desc.GroupId]
			if group == nil then
				group = session:FetchGroupDesc(desc.GroupId).GroupName
				groupCache[desc.GroupId] = group
			end
			cached = { name = desc.TimerName, group = group :: string }
			timerCache[timer] = cached
			return cached
		end

		local frameCount = math.max(1, #frameList)
		local ranked = {}
		local idleMs = 0
		for _, row in rows do
			local info = describe(row.timer)
			if IDLE_NAMES[info.name] and not includeIdle then
				idleMs += row.self
				continue
			end
			if filter ~= nil
				and not string.find(string.lower(info.name), filter, 1, true)
				and not string.find(string.lower(info.group), filter, 1, true)
			then
				continue
			end
			local peak, peakFrame = 0, 0
			for frameId, ms in row.perFrame do
				if ms > peak then
					peak, peakFrame = ms, frameId
				end
			end
			table.insert(ranked, {
				thread = row.thread,
				group = info.group,
				name = info.name,
				selfMs = round(row.self),
				totalMs = round(row.total),
				avgMs = round(row.total / frameCount),
				peakMs = round(peak),
				peakFrame = peakFrame,
				calls = row.calls,
				worst = row.perFrame[worstFrame],
			})
		end
		table.sort(ranked, function(a, b)
			if sortBy == "total" then
				return a.totalMs > b.totalMs
			end
			return a.selfMs > b.selfMs
		end)

		-- What filled the worst frame, so a spike names its cause directly.
		local worstScopes = {}
		for _, entry in ranked do
			if entry.worst and entry.worst > 0 then
				table.insert(worstScopes, entry)
			end
		end
		table.sort(worstScopes, function(a, b)
			return a.worst > b.worst
		end)
		local worstList = {}
		for i = 1, math.min(8, #worstScopes) do
			local entry = worstScopes[i]
			table.insert(worstList, {
				thread = entry.thread,
				name = entry.group .. "/" .. entry.name,
				ms = round(entry.worst),
			})
		end

		local scopes = {}
		for i = 1, math.min(top, #ranked) do
			local entry = ranked[i]
			entry.worst = nil
			table.insert(scopes, entry)
		end

		local export: string? = nil
		if params.export == true then
			local okExport, html = pcall(function()
				return LibMP.Tools:ConvertToBuffer(session, LibMP.Enums.ContainerFormat.CompressedHtml)
			end)
			if okExport and html ~= nil then
				export = buffer.tostring(html)
			end
		end

		return {
			frames = #frameList,
			frameRange = { frameMin, frameMax },
			threads = threadCount,
			walkedThreads = #threadIds,
			steps = steps,
			captureBytes = buffer.len(captured),
			frameMs = {
				avg = round(sum / frameCount),
				p50 = round(percentile(sortedFrames, 0.5)),
				p95 = round(percentile(sortedFrames, 0.95)),
				max = round(math.max(worstMs, 0)),
				worstFrame = worstFrame,
			},
			idleMs = round(idleMs),
			sort = sortBy,
			scopes = scopes,
			matched = #ranked,
			worstFrameScopes = worstList,
			html = export,
			exportFailed = if params.export == true and export == nil then true else nil,
			libmpLoadMs = if firstLoad then loadMs else nil,
			profilerLeftOn = params.keepRunning == true,
		}
	end)
	session:Dispose()
	if not ok then
		error(result, 0)
	end
	return result
end

return MicroProfiler
