--!strict
--[[
	Driving Studio's simulation: run, pause, stop.

	`RunService:Run/Pause/Stop` are PluginSecurity, so this is permitted -- but it
	must be called from the plugin itself. Called through `execute_luau`, which
	compiles with `loadstring`, `Run()` returns successfully and does nothing at
	all: no error, no warning, no state change. That is a property of the compiled
	chunk's capabilities, not of the API, and it is why this lives in a handler
	rather than being left to the escape hatch.

	What this controls is Run mode -- the simulation running in the current
	DataModel -- not Play mode, which spawns a separate session with a character.
	The distinction matters enough to report: scripts run either way, but there is
	no player, so anything gated on `Players.PlayerAdded` never fires.
]]

local RunService = game:GetService("RunService")

local Dispatch = require(script.Parent.Parent.Dispatch)

-- Long enough for the mode change to land before the state is read back, so the
-- reply describes what happened rather than what was asked for.
local SETTLE_SECONDS = 0.35

local Playtest = {}

local function state(): { [string]: any }
	return {
		isEdit = RunService:IsEdit(),
		isRunning = RunService:IsRunning(),
		isRunMode = RunService:IsRunMode(),
		isPaused = RunService:IsRunning() and not RunService:IsRunMode(),
		playerCount = #game:GetService("Players"):GetPlayers(),
	}
end

function Playtest.control(params: { [string]: any }): { [string]: any }
	local op = params.op
	local before = state()

	local action: () -> ()
	if op == "run" then
		if before.isRunning then
			return { changed = false, reason = "already running", state = before }
		end
		action = function()
			RunService:Run()
		end
	elseif op == "pause" then
		if not before.isRunning then
			return { changed = false, reason = "not running", state = before }
		end
		action = function()
			RunService:Pause()
		end
	elseif op == "stop" then
		if before.isEdit and not before.isRunning then
			return { changed = false, reason = "not running", state = before }
		end
		action = function()
			RunService:Stop()
		end
	elseif op == "state" then
		return { changed = false, state = before }
	else
		Dispatch.fail("BAD_PARAMS", string.format("unknown op %q", tostring(op)))
	end

	local ok, err = pcall(action)
	if not ok then
		Dispatch.fail(
			"REFUSED",
			string.format("Studio refused to %s: %s", tostring(op), tostring(err))
		)
	end

	task.wait(SETTLE_SECONDS)
	local after = state()

	-- Reported rather than assumed. This is the exact call that silently did
	-- nothing when compiled through loadstring, so a caller is told whether the
	-- mode actually moved instead of inferring it from the absence of an error.
	local moved = after.isRunning ~= before.isRunning or after.isRunMode ~= before.isRunMode

	return {
		changed = moved,
		reason = if moved then nil else "Studio accepted the call but the mode did not change",
		state = after,
	}
end

function Playtest.register()
	Dispatch.registerAll("playtest", {
		control = Playtest.control,
	})
end

return Playtest
