--!strict
--[[
	Questions about what this Studio build can actually do.

	Separate from the `api` handler because the answers are needed by handlers
	rather than by agents, and because getting one of them wrong is expensive:
	a capability reported as present that is not turns into a tool that fails
	with the engine's own unhelpful message.
]]

local ReflectionService = game:GetService("ReflectionService")

local Reflection = {}

local debuggerChecked = false
local debuggerPresent = false

--[[
	Whether the "Debugger Luau API" beta is on.

	This is the only free and honest test, which was established by elimination.
	With the beta OFF and Studio restarted, every obvious probe still succeeds:
	`game:GetService("ScriptDebuggerService")` returns a service, `FindService`
	finds it, assigning `OnStopped` works, and `Enum.DebuggerResumeType` exists.
	None of them means the debugger is usable. The call that actually fails is
	`AddBreakpoint`, which is no use as a check because setting a breakpoint on
	someone's script to find out whether you may set breakpoints is not a
	read-only question.

	The beta governs whether the class is in the reflection database, so asking
	for it there costs nothing and leaves nothing behind.

	Cached because the beta cannot change without restarting Studio, which ends
	this session anyway.
]]
function Reflection.hasDebugger(): boolean
	if debuggerChecked then
		return debuggerPresent
	end
	local ok, entry = pcall(function()
		return (ReflectionService :: any):GetClass("ScriptDebuggerService", {})
	end)
	debuggerPresent = ok and entry ~= nil
	debuggerChecked = true
	return debuggerPresent
end

return Reflection
