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

--[[
	Workspaces at least this big make Stop freeze Studio from build 743 on.

	Measured on the DevForum (topic 4933776): ~220k instances, almost all rig
	`AnimSaves` keyframe trees, took 3-4s to stop on 742 and 65-75s on 743, all
	of it in the playtest server's "Clearing Workspace". The whole UI hangs, so
	without a warning the agent sees a stop that timed out and the user sees a
	crashed Studio. Set well below the reported case: the cost grows with the
	count, and a 50k place already stalls noticeably.
]]
local LARGE_WORKSPACE = 50_000
local SLOW_STOP_BUILD = 743
local HEAVIEST_SHOWN = 3

-- 0 when the build cannot be read, which turns the check off rather than
-- failing the playtest call it rides on.
local function studioBuild(): number
	local ok, text = pcall(version)
	return if ok and typeof(text) == "string" then tonumber(string.match(text, "^%d+%.(%d+)")) or 0 else 0
end

--[[
	How many instances Workspace holds and which of its children hold most.

	nil when the place is small or the build predates the regression, so the
	common case costs one descendant count and adds nothing to the reply.
]]
local function heavyWorkspace(): { [string]: any }?
	if studioBuild() < SLOW_STOP_BUILD then
		return nil
	end
	local descendants = workspace:GetDescendants()
	local total = #descendants
	if total < LARGE_WORKSPACE then
		return nil
	end
	local heaviest = {}
	for _, child in workspace:GetChildren() do
		table.insert(heaviest, { path = child:GetFullName(), instances = #child:GetDescendants() + 1 })
	end
	table.sort(heaviest, function(a, b)
		return a.instances > b.instances
	end)
	for index = #heaviest, HEAVIEST_SHOWN + 1, -1 do
		heaviest[index] = nil
	end
	-- AnimSaves is named because it is the cause in every report so far, and
	-- it can sit inside a rig that is not itself one of the heaviest children.
	-- Nested AnimSaves are not double counted: only the outermost is measured.
	local animSaves = 0
	for _, instance in descendants do
		if instance.Name == "AnimSaves" and instance:FindFirstAncestor("AnimSaves") == nil then
			animSaves += #instance:GetDescendants() + 1
		end
	end
	return {
		instances = total,
		heaviest = heaviest,
		animSavesInstances = if animSaves > 0 then animSaves else nil,
		build = studioBuild(),
	}
end

local function editModeActive(): boolean?
	local ok, value = pcall(function()
		return service().EditModeActive
	end)
	return if ok and typeof(value) == "boolean" then value else nil
end

local function state(): { [string]: any }
	local players = {}
	-- Only while a test runs: straight after `stop` the editor still lists the
	-- departing player for a moment, and the reply said one was present.
	if RunService:IsRunning() then
		for _, player in game:GetService("Players"):GetPlayers() do
			table.insert(players, { name = player.Name, userId = player.UserId })
		end
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
	if op == "play" or op == "run" or op == "multiplayer" or op == "addPlayers" then requireAllowed() end
	local before = state()

	if op == "state" then
		return { changed = false, state = before }
	end

	--[[
		More players joining a test already running: staggered joins, lobby
		fill-up, the race a second player hits that the first never does.

		Served by the playtest's server session, the only place AddPlayers may be
		called from; the MCP server routes it there. Returns straight away --
		new clients take seconds to load, and the caller polls `state` for them.
	]]
	if op == "addPlayers" then
		if RunService:IsEdit() or not RunService:IsServer() then
			Dispatch.fail(
				"NOT_RUNNING",
				"Players can only be added from the server of a running test.",
				"Start one with `playtest op=\"multiplayer\"` first."
			)
		end
		local count = tonumber(params.players) or 1
		if count < 1 or count > 8 then
			Dispatch.fail("BAD_PARAMS", "players must be between 1 and 8.")
		end
		local ok, err = pcall(function()
			service():AddPlayers(count)
		end)
		if not ok then
			Dispatch.fail(
				"ADD_PLAYERS_FAILED",
				string.format("Studio refused to add players: %s", tostring(err)),
				"AddPlayers works in a multiplayer test only, not in Play or Run."
			)
		end
		return { changed = true, state = before }
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
		-- Measured before the teardown is scheduled: the size is what decides
		-- how long the caller should wait for it.
		local heavy = heavyWorkspace()
		task.delay(0.25, function()
			pcall(function()
				service():EndTest(params.value or "stopped by studio-mcp")
			end)
		end)
		return { changed = true, deferred = true, state = before, heavyWorkspace = heavy }
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
		-- Said at the start too, so the agent can warn the user before the
		-- stop that freezes Studio rather than after it. Not for Run, which
		-- has no separate DataModel to tear down.
		heavyWorkspace = if op ~= "run" then heavyWorkspace() else nil,
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
