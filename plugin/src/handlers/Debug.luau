--!strict
--[[
	Breakpoints and runtime inspection, through `ScriptDebuggerService`.

	Not `DebuggerManager`, which is the legacy service and refuses plugins
	outright -- it wants the LocalUser capability. ScriptDebuggerService is
	PluginSecurity throughout and is what Roblox shipped to replace it.

	Two things shape this design, both learned rather than assumed.

	The service reports "ScriptDebuggerService was never initialized" until a
	callback is attached, in an editor session and a running playtest alike. So
	`OnStopped` is installed before anything else is attempted.

	And `OnStopped` must return its resume decision synchronously. It cannot yield
	waiting for an agent to look at the stack and decide what to do, which rules
	out interactive stepping over a request/response protocol entirely. What works
	instead is a tracepoint: the callback captures the stack and variables into a
	buffer, lets execution continue, and the agent reads the snapshots afterwards.
	For finding out what a value was at a moment in time -- which is what a
	debugger is usually reached for -- that is as good, and it does not leave the
	user's Studio frozen mid-frame.

	The documented return shape is contradictory -- the API dump says the callback
	returns a Dictionary, Roblox's own announcement returns
	`Enum.DebuggerResumeType.Resume` directly -- and this file used to hedge by
	never stopping at all, which is worth recording because the hedge cost the
	whole feature. `ContinueExecution = true` means the debugger does not stop;
	not stopping means `OnStopped` never runs; and `OnStopped` is the only place
	a stack or a variable is readable. Every capture breakpoint verified, fired,
	and recorded nothing, while logpoints on the same lines printed normally --
	so the half that needed no callback worked and hid that the other half was
	dead.

	The enum is the right return. It resumes cleanly: a script with a breakpoint
	mid-loop ran to completion untouched, so stopping to capture costs the run
	nothing and strands nothing.

	There is no third option. `DebuggerResumeType` offers StepInto, StepOut,
	StepOver and Resume, and none of them means "stay stopped", so a breakpoint
	that holds a thread for someone to look at is not expressible here -- which
	is why nothing in this file offers one.
]]

local ScriptDebuggerService = game:GetService("ScriptDebuggerService")

local Dispatch = require(script.Parent.Parent.Dispatch)
local Paths = require(script.Parent.Parent.Paths)

-- Snapshots are far heavier than log lines: each carries a stack and its
-- variables. A tight cap keeps a breakpoint inside a loop from exhausting memory
-- before anyone reads it.
local MAX_SNAPSHOTS = 40
local MAX_FRAMES = 12
local MAX_VARIABLES = 40

local Debug = {}

local service = ScriptDebuggerService :: any

local snapshots: { { [string]: any } } = {}
local overflow = 0
local installed = false
local installError: string? = nil

--[[
	Flattens whatever the service hands back.

	Every one of these shapes is undocumented, so nothing is indexed by a guessed
	field name. Keys are taken as they come and values stringified, which means an
	unfamiliar shape arrives readable instead of arriving empty.
]]
local function flatten(value: any, depth: number): any
	if depth > 3 then
		return "<nested>"
	end
	local kind = typeof(value)
	if kind ~= "table" then
		if kind == "Instance" then
			return (value :: Instance):GetFullName()
		end
		if kind == "EnumItem" then
			return tostring(value)
		end
		return if kind == "string" or kind == "number" or kind == "boolean"
			then value
			else tostring(value)
	end

	local source = value :: { [any]: any }
	local out: { [string]: any } = {}
	local count = 0
	for key, item in source do
		count += 1
		if count > MAX_VARIABLES then
			out["..."] = "more"
			break
		end
		out[tostring(key)] = flatten(item, depth + 1)
	end
	return out
end

--[[
	Builds the record for one stop.

	Each lookup is guarded on its own. A stop that yields a thread id but no
	readable variables is still worth keeping, and losing the whole snapshot to
	one failed call would waste the only moment the data existed.
]]
local function capture(stopped: any)
	local record: { [string]: any } = {
		at = os.time(),
		stopped = flatten(stopped, 0),
	}

	--[[
		`ThreadIds`, plural, holding an array -- measured from a real stop:

			{ ThreadIds = {3002}, Reason = Enum.ScriptStoppedReason.Breakpoint }

		Reading `ThreadId` instead cost nothing visible: snapshots still arrived,
		carrying the reason and nothing else, so a breakpoint looked like it was
		working while the stack and variables it exists to collect were never
		fetched.
	]]
	local threadId: any = nil
	if typeof(stopped) == "table" then
		local ids = (stopped :: any).ThreadIds
		threadId = if typeof(ids) == "table" then (ids :: { any })[1] else (stopped :: any).ThreadId
	end

	if threadId ~= nil then
		local ok, trace = pcall(function()
			return service:GetStackTrace(threadId)
		end)
		if ok then
			record.stack = flatten(trace, 0)

			-- Variables hang off a frame, so they are only reachable once the
			-- trace has given up a frame id.
			local frames = if typeof(trace) == "table" then (trace :: any).Frames else nil
			if typeof(frames) == "table" then
				local locals: { any } = {}
				for index, frame in frames :: { any } do
					if index > MAX_FRAMES then
						break
					end
					-- `Id`, measured: a frame is {Id, Line, Name, ScriptPath}. The
					-- StackFrame *instance* used by Studio's own debugger calls
					-- it FrameId, which is what this read first, and the
					-- mismatch cost only the variables -- the frame itself still
					-- listed, so the stack looked complete.
					local raw = frame :: any
					local frameId = if typeof(frame) == "table" then (raw.Id or raw.FrameId) else nil
					if frameId ~= nil then
						local gotVars, vars = pcall(function()
							return service:GetRootVariables(frameId)
						end)
						table.insert(locals, {
							frame = flatten(frame, 1),
							variables = if gotVars then flatten(vars, 1) else tostring(vars),
						})
					end
				end
				record.frames = locals
			end
		else
			record.stackError = tostring(trace)
		end
	end

	if #snapshots >= MAX_SNAPSHOTS then
		table.remove(snapshots, 1)
		overflow += 1
	end
	table.insert(snapshots, record)
end

--[[
	Attaches the callback, which is also what initialises the service.

	The resume decision follows Roblox's own example and returns the enum rather
	than the Dictionary the dump describes. That is settled by observation now,
	not by preference: breakpoints stop, this returns, and the stopped script
	carries on to its last line.
]]
local function install(): boolean
	if installed then
		return true
	end

	local ok, err = pcall(function()
		service.OnStopped = function(stopped: any): any
			-- Capture must never be what keeps a thread paused.
			pcall(capture, stopped)
			return Enum.DebuggerResumeType.Resume
		end
	end)

	if not ok then
		installError = tostring(err)
		return false
	end
	installed = true
	installError = nil
	return true
end

local function requireService()
	if not install() then
		Dispatch.fail(
			"NO_DEBUGGER",
			string.format(
				"ScriptDebuggerService is not available in this session: %s",
				tostring(installError)
			),
			"It is a beta API; the Studio build may not expose it yet."
		)
	end
end

function Debug.set(params: { [string]: any }): { [string]: any }
	requireService()

	local requested = params.breakpoints
	if typeof(requested) ~= "table" then
		Dispatch.fail("BAD_PARAMS", "debug set requires a `breakpoints` array.")
	end

	local added: { { [string]: any } } = {}
	local failed: { { [string]: any } } = {}

	for _, item in requested :: { { [string]: any } } do
		local target = Paths.resolve(item.path)
		if not target:IsA("LuaSourceContainer") then
			Dispatch.fail(
				"NOT_A_SCRIPT",
				string.format("%s is a %s, not a script.", item.path, target.ClassName)
			)
		end

		--[[
			Capitalised keys, from Roblox's example -- `Line`, `Condition`,
			`LogMessage`, `ContinueExecution`. Lowercase `line` was rejected.

			`ContinueExecution` decides whether the debugger stops at all, and
			stopping is the only thing that raises `OnStopped` -- which is the
			only place a stack or a variable can be read. So a breakpoint that
			continues past itself captures nothing, ever.

			That was this file's default, on the reasoning that not stopping was
			the safe choice: a wrong return from the callback could strand a
			paused thread, and never pausing made that impossible. It also made
			the feature impossible. Measured on a line proven to fire -- the same
			breakpoint, same condition, differing only here -- it captured
			nothing across two sessions, while the identical breakpoint carrying
			a LogMessage printed on cue.

			Stopping is not the hazard it was assumed to be. `OnStopped` returns
			`Resume` and the thread continues on its own: the probe script ran to
			completion, printing every line after the breakpoint, with no one
			touching Studio. So capture stops, and a LogMessage -- which the
			engine prints without help -- does not need to.
		]]
		local logMessage = if typeof(item.logMessage) == "string" and item.logMessage ~= ""
			then item.logMessage
			else nil
		local descriptor: { [string]: any } = {
			Line = tonumber(item.line),
			ContinueExecution = logMessage ~= nil,
		}
		if typeof(item.condition) == "string" and item.condition ~= "" then
			descriptor.Condition = item.condition
		end
		if logMessage ~= nil then
			descriptor.LogMessage = logMessage
		end

		local ok, result = pcall(function()
			return service:AddBreakpoint(target, descriptor)
		end)

		if ok then
			table.insert(added, {
				path = Paths.of(target),
				line = descriptor.Line,
				-- What it will do when hit, since the two kinds behave nothing
				-- alike: one writes a line to the output, the other stops long
				-- enough to read the stack and then resumes itself.
				mode = if logMessage ~= nil then "log" else "capture",
				result = flatten(result, 1),
			})
		else
			table.insert(failed, { path = item.path, line = descriptor.Line, error = tostring(result) })
		end
	end

	return { added = added, failed = failed, installed = installed }
end

function Debug.clear(params: { [string]: any }): { [string]: any }
	requireService()

	local path = params.path
	if typeof(path) == "string" and path ~= "" then
		local target = Paths.resolve(path)
		local line = tonumber(params.line)
		if line == nil then
			Dispatch.fail("BAD_PARAMS", "removing one breakpoint needs a `line`.")
		end
		local ok, removed = pcall(function()
			return service:RemoveBreakpoint(target, line)
		end)
		return { removed = ok and removed == true, path = Paths.of(target), line = line }
	end

	local ok, err = pcall(function()
		service:ClearBreakpoints()
	end)
	if not ok then
		Dispatch.fail("REFUSED", string.format("ClearBreakpoints refused: %s", tostring(err)))
	end
	return { cleared = true }
end

function Debug.snapshots(params: { [string]: any }): { [string]: any }
	local limit = math.clamp(tonumber(params.limit) or 10, 1, MAX_SNAPSHOTS)

	local out: { { [string]: any } } = {}
	local first = math.max(1, #snapshots - limit + 1)
	for index = first, #snapshots do
		table.insert(out, snapshots[index])
	end

	if params.clear == true then
		snapshots = {}
		overflow = 0
	end

	return {
		items = out,
		total = #snapshots,
		overflow = if overflow > 0 then overflow else nil,
		installed = installed,
	}
end

function Debug.exceptions(params: { [string]: any }): { [string]: any }
	requireService()

	local mode = tostring(params.mode or "Unhandled")
	local item = (Enum.DebugBreakModeType :: any)[mode]
	if item == nil then
		Dispatch.fail("BAD_PARAMS", string.format("unknown break mode %q", mode))
	end

	local ok, err = pcall(function()
		service:SetExceptionBreakMode(item)
	end)
	if not ok then
		Dispatch.fail("REFUSED", string.format("SetExceptionBreakMode refused: %s", tostring(err)))
	end
	return { mode = mode }
end

function Debug.register()
	--[[
		Installed at load, not on the first debug request.

		A breakpoint is registered in one session and hit in another: the editor
		holds it, the playtest's DataModel runs the code and raises the stop. That
		second session is created by pressing play, long after any tool call
		reached the first, so waiting for a request to install the callback leaves
		exactly the session that does the stopping without one -- and a breakpoint
		that verifies, fires, and records nothing.

		Attaching it here costs a callback assignment per session and means every
		session is ready before anything needs it.
	]]
	install()

	Dispatch.registerAll("debug", {
		set = Debug.set,
		clear = Debug.clear,
		snapshots = Debug.snapshots,
		exceptions = Debug.exceptions,
	})
end

return Debug
