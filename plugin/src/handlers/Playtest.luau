--!strict
--[[
	Driving Studio's playtests.

	`StudioTestService`, not `RunService:Run`. Run/Pause/Stop are marked
	PluginSecurity and are permitted, and they do nothing: called from a real
	plugin handler -- not just through the loadstring sandbox, which was the first
	wrong explanation -- `Run()` returns successfully and leaves Studio in edit
	mode with nothing logged. StudioTestService is the service Roblox added for
	this, and it reaches further: Play mode with a character, and multiplayer
	tests, neither of which RunService offered at all.

	The Execute calls yield until the test ends -- specifically until something
	inside the session calls `EndTest`. That is the wrong shape for a request
	that should answer promptly, so the call is started on its own task and the
	reply describes the state it reached. The result, whenever the test finally
	produces one, is kept for a later `state` to collect.
]]

local RunService = game:GetService("RunService")
local StudioTestService = game:GetService("StudioTestService")

local Dispatch = require(script.Parent.Parent.Dispatch)

-- Long enough for Studio to actually enter the mode before the state is read
-- back, so the reply describes what happened rather than what was asked for.
local SETTLE_SECONDS = 1.5

local Playtest = {}

-- Supplied by the plugin entrypoint, which owns persistent plugin settings.
-- Read on every request so another panel context's choice is not cached here.
local readAllowed: () -> any = function() return nil end
local writeAllowed: (boolean) -> () = function() error("Playtest settings are not initialized") end
function Playtest.setup(read: () -> any, write: (boolean) -> ())
	readAllowed, writeAllowed = read, write
end
function Playtest.isAllowed(): boolean
	return readAllowed() ~= false
end
function Playtest.setAllowed(value: boolean)
	writeAllowed(value)
end
local function requireAllowed()
	if not Playtest.isAllowed() then
		Dispatch.fail("PLAYTEST_DISABLED", "Playtests are disabled by the user.",
			"Do not start or simulate a playtest. Continue using edit-mode tools and static inspection where possible.\nRun `playtests on` in the Studio MCP panel to re-enable playtesting.")
	end
end

-- Outcome of the most recent test, which arrives long after the call that
-- started it returned.
local pending = false
local lastResult: any = nil
local lastError: string? = nil
local startedAt: number? = nil

local function service(): any
	return StudioTestService :: any
end

local function editModeActive(): boolean?
	local ok, value = pcall(function()
		return service().EditModeActive
	end)
	return if ok and typeof(value) == "boolean" then value else nil
end

local function state(): { [string]: any }
	local players = {}
	for _, player in game:GetService("Players"):GetPlayers() do
		table.insert(players, { name = player.Name, userId = player.UserId })
	end
	return {
		playtestsAllowed = Playtest.isAllowed(),
		isEdit = RunService:IsEdit(),
		isRunning = RunService:IsRunning(),
		isRunMode = RunService:IsRunMode(),
		editModeActive = editModeActive(),
		playerCount = #players,
		players = if #players > 0 then players else nil,
		testPending = pending,
		-- Kept from the previous test rather than discarded, since whatever
		-- EndTest returned is the only thing a test session can hand back.
		lastResult = lastResult,
		lastError = lastError,
		runningForSeconds = if startedAt then math.floor(os.clock() - startedAt) else nil,
	}
end

--[[
	Starts a test without waiting for it to finish.

	Every failure here has to survive on its own thread: nothing is watching it
	by the time it fails, so the reason is stored for the next `state` instead of
	being raised into a caller that has already been answered.
]]
local function launch(name: string, call: () -> any)
	pending = true
	lastResult = nil
	lastError = nil
	startedAt = os.clock()

	task.spawn(function()
		local ok, result = pcall(function()
			-- Recheck after scheduling: OFF may have been entered while queued.
			requireAllowed()
			return call()
		end)
		pending = false
		startedAt = nil
		if ok then
			lastResult = result
		else
			lastError = if typeof(result) == "table" and result.code == "PLAYTEST_DISABLED"
				then result.code .. ": " .. result.message .. "\n" .. result.hint
				else string.format("%s failed: %s", name, tostring(result))
		end
	end)
end

function Playtest.control(params: { [string]: any }): { [string]: any }
	local op = params.op
	if op == "play" or op == "run" or op == "multiplayer" then requireAllowed() end
	local before = state()

	if op == "state" then
		return { changed = false, state = before }
	end

	--[[
		Ending a test has to happen inside it.

		`LeaveTest` reads like the plugin-side exit and is not: it refuses with
		"can only be called from the client DataModel of a running Studio test
		session", and a playtest client can never reach this bridge because Studio
		bars client sessions from making HTTP requests. So that route is closed for
		good, not merely awkward.

		`EndTest` works from the playtest's *server* session, which does connect --
		and its value travels back to whichever plugin called ExecutePlayModeAsync.
		The server tool routes a stop to that session; this op is what it calls.
	]]
	if op == "endTest" then
		--[[
			Deferred, because EndTest destroys the DataModel this handler is
			running in -- including the connection carrying the reply. Called
			inline it does end the test and the caller sees only DISCONNECTED,
			which reads as a failed stop for something that worked perfectly.

			The reply goes out first and the teardown follows. Whether it
			actually ended is not taken on trust either way: the caller confirms
			against the editor session, which survives.
		]]
		task.delay(0.25, function()
			pcall(function()
				service():EndTest(params.value or "stopped by studio-mcp")
			end)
		end)
		return { changed = true, deferred = true, state = before }
	end

	if op == "stop" then
		if before.isEdit and not before.isRunning and not pending then
			return { changed = false, reason = "no test is running", state = before }
		end

		-- Only reachable when the caller could not find a playtest session to end
		-- from. Stops a Run-mode session, which has no separate DataModel.
		pcall(function()
			RunService:Stop()
		end)

		task.wait(SETTLE_SECONDS)
		local after = state()
		return {
			changed = after.isRunning ~= before.isRunning or after.isEdit ~= before.isEdit,
			state = after,
		}
	end

	if pending then
		Dispatch.fail(
			"ALREADY_RUNNING",
			"A test is already running.",
			"Stop it first, or call with op 'state' to see how it is doing."
		)
	end

	-- ExecutePlayModeAsync rejects a nil argument outright -- "Argument 1 missing
	-- or nil" -- even though the parameter is a Variant, so an omitted `args`
	-- becomes an empty string rather than a failed launch.
	local args = if params.args == nil then "" else params.args
	if op == "play" then
		launch("ExecutePlayModeAsync", function()
			return service():ExecutePlayModeAsync(args)
		end)
	elseif op == "run" then
		launch("ExecuteRunModeAsync", function()
			return service():ExecuteRunModeAsync(args)
		end)
	elseif op == "multiplayer" then
		local players = tonumber(params.players) or 2
		if players < 1 or players > 8 then
			Dispatch.fail("BAD_PARAMS", "players must be between 1 and 8.")
		end
		launch("ExecuteMultiplayerTestAsync", function()
			return service():ExecuteMultiplayerTestAsync(players, args)
		end)
	else
		Dispatch.fail("BAD_PARAMS", string.format("unknown op %q", tostring(op)))
	end

	task.wait(SETTLE_SECONDS)
	local after = state()

	-- Whether the mode moved, not whether the call was accepted. Accepting and
	-- doing nothing is exactly how RunService:Run behaved here.
	local moved = after.isRunning ~= before.isRunning
		or after.isEdit ~= before.isEdit
		or after.editModeActive ~= before.editModeActive

	return {
		changed = moved or after.testPending,
		reason = if after.lastError then after.lastError
			elseif not moved and not after.testPending then "Studio accepted the call but the mode did not change"
			else nil,
		state = after,
	}
end

-- Panel-only stop, also usable in the client view which cannot make HTTP calls.
-- No state-change listener is installed: manual Play stays available while OFF.
function Playtest.stopLocal()
	if not RunService:IsEdit() and RunService:IsClient() and not RunService:IsServer() then
		service():LeaveTest()
	elseif not RunService:IsEdit() and not RunService:IsRunMode() then
		Playtest.control({ op = "endTest" })
	else
		Playtest.control({ op = "stop" })
	end
end

function Playtest.register()
	Dispatch.registerAll("playtest", {
		control = Playtest.control,
	})
end

return Playtest
