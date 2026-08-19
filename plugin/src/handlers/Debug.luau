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

	Freezing is the hazard worth designing against here. The documented return
	shape is contradictory: the API dump says the callback returns a Dictionary,
	while Roblox's own announcement returns `Enum.DebuggerResumeType.Resume`
	directly. Rather than gamble on which, breakpoints carry
	`ContinueExecution = true` unless a caller explicitly asks otherwise, so a
	wrong return cannot strand a paused thread.
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

	local threadId = if typeof(stopped) == "table" then (stopped :: any).ThreadId else nil

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
					local frameId = if typeof(frame) == "table" then (frame :: any).FrameId else nil
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

	The resume decision follows Roblox's own example and returns the enum. The
	dump disagrees and says Dictionary; since the two cannot both be satisfied,
	breakpoints default to not pausing at all, which makes the disagreement
	harmless rather than a frozen session.
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

			`ContinueExecution` defaults on so a breakpoint records and moves on
			rather than halting the session. Turning it off is a caller's explicit
			choice, and the tool says what it costs.
		]]
		local descriptor: { [string]: any } = {
			Line = tonumber(item.line),
			ContinueExecution = item.pause ~= true,
		}
		if typeof(item.condition) == "string" and item.condition ~= "" then
			descriptor.Condition = item.condition
		end
		if typeof(item.logMessage) == "string" and item.logMessage ~= "" then
			descriptor.LogMessage = item.logMessage
		end

		local ok, result = pcall(function()
			return service:AddBreakpoint(target, descriptor)
		end)

		if ok then
			table.insert(added, {
				path = Paths.of(target),
				line = descriptor.Line,
				pauses = not descriptor.ContinueExecution,
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
	Dispatch.registerAll("debug", {
		set = Debug.set,
		clear = Debug.clear,
		snapshots = Debug.snapshots,
		exceptions = Debug.exceptions,
	})
end

return Debug
