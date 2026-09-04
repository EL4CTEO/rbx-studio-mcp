--!strict
--[[
	rbx-studio -- plugin entry point.

	Owns the toolbar UI, this window's Studio identity, and the command loop.
	Handlers do the actual work; this file only wires them to the transport and
	reports what is happening to the console widget.
]]

local HttpService = game:GetService("HttpService")
local RunService = game:GetService("RunService")

local Config = require(script.Config)
local Console = require(script.Console)
local Dispatch = require(script.Dispatch)
local History = require(script.History)
local LogBuffer = require(script.LogBuffer)
local Mirror = require(script.Mirror)
local Phrase = require(script.Phrase)
local Themes = require(script.Themes)
local Transport = require(script.Transport)
local Debug = require(script.handlers.Debug)
local Assets = require(script.handlers.Assets)
local Capture = require(script.handlers.Capture)
local Character = require(script.handlers.Character)
local Geometry = require(script.handlers.Geometry)
local World = require(script.handlers.World)
local Discover = require(script.handlers.Discover)
local Exec = require(script.handlers.Exec)
local Instances = require(script.handlers.Instances)
local Perf = require(script.handlers.Perf)
local Playtest = require(script.handlers.Playtest)
local Viewport = require(script.handlers.Viewport)
local Input = require(script.handlers.Input)
local Device = require(script.handlers.Device)
local Api = require(script.handlers.Api)
local Scripts = require(script.handlers.Scripts)
local Session = require(script.handlers.Session)

local SETTING_PORT = "port"
local SETTING_AUTOCONNECT = "autoConnect"
local SETTING_FORCE_POLL = "forcePoll"
local SETTING_THEME = "theme"
local SETTING_WIDGET_OPEN = "widgetOpen"
local SETTING_WIDGET_SIZE = "widgetSize"

--[[
	A fresh id per plugin load, which in practice means one per Studio window.

	This was originally persisted with `plugin:SetSetting`, on the reasoning that a
	stable id keeps reconnects mapping to the same session. That is wrong as soon
	as the user opens a second window: plugin settings live in one file shared by
	every Studio process, so both windows announce the same id, and the server
	treats the second connection as the first one reconnecting -- closing the
	original stream and making it impossible to address the two places separately.

	Held in memory instead. A reconnect within one load (the SSE stream hits its
	30-minute cap) reuses this id, and `plugin.Unloading` detaches cleanly on
	reload, so ghost entries do not accumulate.
]]
local SESSION_ID = HttpService:GenerateGUID(false)

local function studioId(): string
	return SESSION_ID
end

--[[
	Whether this copy of the plugin can reach the bridge at all.

	Pressing Play loads the plugin into the playtest's DataModels as well as the
	editor's, and HttpService refuses every request from a client one: "Http
	requests can only be executed by game server". The transport read that as a
	dropped connection and retried forever, filling the console with red while
	nothing was actually wrong.

	The editor session and the play session's server can both connect and are
	worth connecting -- addressing a running server is useful. The client half
	simply says so once and stops.
]]
local function canConnect(): (boolean, string?)
	if RunService:IsEdit() or RunService:IsServer() then
		return true, nil
	end
	--[[
		The wording names the fix, because the symptom is indistinguishable
		from a broken server: a user watching this window during a playtest
		sees a console that logs nothing while tools plainly work, and has no
		way to guess that the activity is in a different view of the same
		Studio. Reported once here and again as the strip's caption, since
		one line scrolled off the top is easy to miss.
	]]
	return false,
		"client view of a playtest -- Studio forbids client sessions from making HTTP "
			.. "requests, so this panel cannot reach the bridge itself. It is MIRRORING "
			.. "the playtest's server session instead, so the log and the strip below "
			.. "are live. Switch to the Server view (Test tab, Current: Server) for the "
			.. "session that is actually connected."
end

-- First thing, before any handler or the transport can log: the buffer only
-- holds what was printed after it subscribed, so every line ahead of this call
-- is unrecoverable. This runs even in a client session that will never connect,
-- since the console tool reads it and connectivity is a separate question.
LogBuffer.start()

local storedPort = plugin:GetSetting(SETTING_PORT)
if typeof(storedPort) == "number" then
	Config.setPort(storedPort)
end

Transport.setForcePoll(plugin:GetSetting(SETTING_FORCE_POLL) == true)

--[[
	The console's colour preset, restored before anything is drawn.

	Applied here rather than after mounting so the panel is built in the right
	palette from the start -- restoring it afterwards would flash the default
	theme for a frame on every Studio launch. An unknown id (a preset renamed,
	or a setting written by a newer build) falls back to the default rather than
	failing, which is `Themes.get`'s job.
]]
local storedTheme = plugin:GetSetting(SETTING_THEME)
if typeof(storedTheme) == "string" then
	Themes.use(storedTheme)
end

--[[
	Whether the restore above still has to be pushed into the console.

	`Themes.use` moves the ACTIVE ID, and anything that reads the palette live
	picks the change up for free -- which is why the prism cell came back on the
	saved preset. `Console` does not read it live: it caches the palette in an
	upvalue at module load, deliberately, so that forty read sites stay plain
	field accesses. Module load happens at the `require` above, which is BEFORE
	this line, so the cache held the default while the id said otherwise, and a
	reload came back as the saved prism drawn in the default's colours.

	It cannot simply be applied here either -- the console is not mounted yet.
	So it is remembered and applied the moment it can be, right after mounting.
]]
local themeNeedsApplying = typeof(storedTheme) == "string" and Themes.activeId() == storedTheme

Session.register()
Discover.register()
Debug.register()
Instances.register()
Perf.register(plugin)
Playtest.register()
Capture.register()
Assets.register()
Character.register()
Geometry.register()
World.register()
Exec.register()
Viewport.register()
Scripts.register()
Input.register()
Device.register()
Api.register()

--[[
	The toolbar button.

	The icon has to be an uploaded asset: `CreateButton` takes a content string,
	and the only ones Studio resolves are `rbxassetid://` for uploaded images and
	`rbxasset://` for files that ship inside Studio itself. A path to something in
	this repository is not one of them, which is why the mark in `assets/` has to
	go through an upload before it can appear here.

	It used to borrow `textures/ui/common/robux.png` -- a Robux coin, sitting in
	the toolbar next to a plugin that has nothing to do with purchases.
]]
local toolbar = plugin:CreateToolbar("rbx-studio")
local button = toolbar:CreateButton(
	"rbx-studio",
	"Show the rbx-studio console",
	"rbxassetid://125390773465346"
)
button.ClickableWhenViewportHidden = true

--[[
	The panel, opened and sized the way the user last left it -- in EVERY
	DataModel, which is the whole point.

	Pressing Play loads this plugin again into the playtest's DataModels, and a
	dock widget belongs to the DataModel that created it: the editor's is hidden
	along with the editor's view, and the playtest's is a brand new widget that
	Studio brings up closed and at the default size. So the panel vanished on
	every playtest and came back, when the user re-opened it from the toolbar,
	as a 560x320 float with whatever size they had chosen thrown away.

	Studio's own restore does not cross that boundary, so the preference is kept
	here instead and passed in as the INITIAL state, with `overrideEnabledRestore`
	set so it is honoured rather than second-guessed. Written only from the
	editor session -- see below -- so a playtest starting or ending can never
	record a decision the user did not make.
]]
local storedOpen = plugin:GetSetting(SETTING_WIDGET_OPEN)
local wantOpen = if typeof(storedOpen) == "boolean" then storedOpen else true

local floatWidth, floatHeight = 560, 320
local storedSize = plugin:GetSetting(SETTING_WIDGET_SIZE)
if typeof(storedSize) == "table" then
	local saved = storedSize :: { [string]: any }
	local x, y = tonumber(saved.x), tonumber(saved.y)
	-- Guarded against nonsense: a zero or absurd size saved from a docked or
	-- mid-teardown widget would otherwise be unrecoverable without clearing
	-- settings by hand.
	if x ~= nil and y ~= nil and x >= 360 and y >= 200 and x <= 4000 and y <= 4000 then
		floatWidth, floatHeight = math.floor(x), math.floor(y)
	end
end

local widget = plugin:CreateDockWidgetPluginGuiAsync(
	"StudioMCP_Console",
	DockWidgetPluginGuiInfo.new(
		Enum.InitialDockState.Float,
		wantOpen,
		-- Override Studio's own enabled-restore: ours is the one that survives
		-- the hop into a playtest DataModel, and two restores disagreeing is
		-- what produced a panel that was open in the editor and closed in play.
		true,
		floatWidth,
		floatHeight,
		360,
		200
	)
)
widget.Title = "rbx-studio"

--[[
	Remember what the user does with the panel, from the editor only.

	The editor session is the one whose Enabled and size changes are actually
	the user's: a playtest DataModel's widget is created, shown and destroyed by
	Studio around the test, and letting those transitions write would persist a
	"closed" the user never asked for -- reintroducing the bug through the back
	door.
]]
if RunService:IsEdit() then
	local unloading = false
	plugin.Unloading:Connect(function()
		unloading = true
	end)

	widget:GetPropertyChangedSignal("Enabled"):Connect(function()
		if not unloading then
			plugin:SetSetting(SETTING_WIDGET_OPEN, widget.Enabled)
		end
	end)

	-- Only a real, sane size, and only while the panel is up: a hidden or
	-- collapsing widget reports sizes that are not a choice.
	local function persistSize(): boolean
		local size = widget.AbsoluteSize
		if unloading or not widget.Enabled or size.X < 360 or size.Y < 200 then
			return false
		end
		plugin:SetSetting(SETTING_WIDGET_SIZE, { x = math.floor(size.X), y = math.floor(size.Y) })
		return true
	end

	widget:GetPropertyChangedSignal("AbsoluteSize"):Connect(persistSize)

	--[[
		Seed from the size Studio has already restored, rather than waiting for
		a resize that may never come.

		Without this the setting stays empty until the user happens to drag the
		panel's edge, so the first playtest inherits the 560x320 default and the
		window visibly shrinks -- which is the same complaint as it vanishing,
		one step later. Studio settles the geometry a few frames after the widget
		is created and fires no change event for it, so it is polled briefly and
		then left alone.
	]]
	task.defer(function()
		for _ = 1, 40 do
			if persistSize() then
				return
			end
			task.wait(0.1)
		end
	end)
end

local currentStatus: Transport.Status = "disconnected"

local function refreshMeta()
	Console.setStatus(
		currentStatus,
		string.format(
			"127.0.0.1:%d  %s  build %s",
			Config.getPort(),
			Transport.getMode(),
			Config.BUILD_ID
		)
	)
	button:SetActive(currentStatus == "connected")
end

local connect: () -> ()

Console.mount(widget, {
	onReconnect = function()
		Console.log("info", "reconnect requested")
		Transport.stop()
		task.wait(0.2)
		connect()
	end,
	onClear = function()
		Console.clear()
	end,
	onTheme = function(id)
		plugin:SetSetting(SETTING_THEME, id)
		Console.log("dim", string.format("theme: %s", id))
	end,
})

-- The saved preset, now that there is something to paint. Done immediately
-- after mounting and before the first line is logged, so nothing is ever drawn
-- in the wrong palette.
if themeNeedsApplying then
	Console.applyTheme()
end

--[[
	The log, picked up where the last copy of this plugin left it.

	Restored before the banner below rather than after it, so the carried rows
	read as what they are -- what was on screen a moment ago -- with this
	session's first line underneath them instead of buried in the middle.

	Every session reads; only the editor writes. See `History` for why.
]]
History.attach(plugin, Console.snapshot)
local carried = History.restore()
if #carried > 0 then
	Console.restore(carried)
	Console.log(
		"dim",
		string.format("carried %d line%s over", #carried, if #carried == 1 then "" else "s"),
		if RunService:IsEdit() then "from the last session" else "from the editor"
	)
end

if RunService:IsEdit() then
	History.start()
	plugin.Unloading:Connect(function()
		History.stop()
		-- The loop cannot save what happens after it has stopped, and closing
		-- Studio is exactly when the last few rows matter most.
		History.flush()
	end)
end

--[[
	The playtest halves, joined.

	The server half can reach the bridge and sees every command; the client half
	is the one Studio actually shows during a playtest and can reach nothing. So
	the server relays its console events and the client replays them, which is
	the only way the panel in front of the user reacts to the work being done.

	Note which side sets the observer: only the SERVER. The client replays
	events through the same `Console` functions, and if it were also observing
	it would echo each one straight back into the channel.
]]
if RunService:IsEdit() then
	-- The only observer the edit session needs: every logged row marks the
	-- stored copy stale, and the save loop above decides when to write it.
	Console.setObserver(function()
		History.touch()
	end)
elseif Mirror.isPlaytestServer() then
	Mirror.startServer()
	Console.setObserver(function(kind, arguments)
		Mirror.send(kind, arguments)
	end)
	-- The channel itself stays shut until `onStatus` reports the connection;
	-- see `Mirror.open`.
elseif Mirror.isPlaytestClient() then
	Console.setMirroring(true)
	Mirror.startClient(function(kind, arguments)
		if kind == "log" then
			local level, message, detail = arguments[1], arguments[2], arguments[3]
			if typeof(level) == "string" and typeof(message) == "string" then
				Console.log(
					level :: any,
					message,
					if typeof(detail) == "string" then detail else nil
				)
			end
		elseif kind == "beginCall" then
			local title, callKind = arguments[1], arguments[2]
			if typeof(title) == "string" and typeof(callKind) == "string" then
				Console.beginCall(title, callKind)
			end
		elseif kind == "recordCall" then
			local ok, milliseconds = arguments[1], arguments[2]
			if typeof(ok) == "boolean" and typeof(milliseconds) == "number" then
				Console.recordCall(ok, milliseconds)
			end
		end
	end)
end

Console.log("info", string.format("rbx-studio v%s", Config.PLUGIN_VERSION), "build " .. Config.BUILD_ID)
Console.log("dim", string.format("place: %s (%d)", game.Name, game.PlaceId))

local function onStatus(status: Transport.Status, detail: string?)
	local previous = currentStatus
	currentStatus = status
	refreshMeta()

	-- Only narrate transitions. The transport re-reports its state on every
	-- reconnect attempt, and echoing an unchanged status would bury real events.
	if status == previous and detail == nil then
		return
	end

	if status == "connected" then
		Console.log(
			"ok",
			string.format("connected to 127.0.0.1:%d", Config.getPort()),
			if detail then "(" .. detail .. ")" else nil
		)
		-- After the row, not before it: this session's own arrival is not news
		-- to the client view, which announced its own a moment ago.
		Mirror.open()
	elseif status == "connecting" then
		Console.log("dim", string.format("connecting to 127.0.0.1:%d...", Config.getPort()))
	else
		Console.log("error", "disconnected", detail)
	end
end

--[[
	Runs each command on its own task. Handlers may yield -- `UpdateSourceAsync`
	and any `*Async` call does -- and serialising them would let one slow edit
	stall every other request on the stream.
]]
local function onCommand(id: string, op: string, params: { [string]: any }?)
	task.spawn(function()
		local startedAt = os.clock()
		--[[
			Named for what it does, not for how it travels. `script.edit` on
			ServerScriptService.Systems.KillBrick reads as "Edit KillBrick",
			which is the thing someone watching actually wants to know; the wire
			name is kept alongside so the log still maps onto the protocol when
			something needs debugging.
		]]
		local title = Phrase.of(op, params)
		--[[
			Announced synchronously, unlike the logging below.

			Deferring this looked like free latency and was not. `beginCall` sets
			two labels and some fields -- it never touches the RichText log, which
			is where the cost actually is -- and deferring it let a call that
			finished inside one frame record its result before the call had been
			announced, so the bar on the trace lost the name it was supposed to
			carry. A microsecond is not worth an ordering hazard.
		]]
		Console.beginCall(title, Phrase.kindOf(op))

		local result = Dispatch.invoke(id, op, params)
		local milliseconds = (os.clock() - startedAt) * 1000

		--[[
			The answer goes out before the console hears about it.

			This used to be the last line of the function, which put a
			`table.concat` of three hundred strings, a RichText relayout of the
			whole log, two `Instance.new` calls and a forty-bar relayout in front
			of the reply on its way back to the agent. None of that is work the
			caller asked for, and all of it was being billed to the round trip
			this project measures. Drawing happens below, on time the agent is no
			longer waiting for.
		]]
		Transport.sendResult(result)

		local elapsed = string.format("%.0fms", milliseconds)
		Console.recordCall(result.ok, milliseconds)

		if result.ok then
			Console.log("reply", title, elapsed)
		else
			local err = result.error
			Console.log(
				"error",
				string.format("%s failed: %s", title, if err then err.code else "unknown"),
				elapsed
			)
			if err and err.message then
				Console.log("dim", "   " .. err.message)
			end
		end
	end)
end

--[[
	Where a peer's call ran, in the width the detail column has.

	The latency already lives there and only about fourteen characters fit
	beside a message, so this is two letters and a space rather than "playtest
	server". Which half of a playtest it was does not matter to someone reading
	the editor's log afterwards; that it was not the editor does.
]]
local function peerTag(from: any): string
	if typeof(from) ~= "string" then
		return "peer"
	end
	return if from == "edit" then "edit" else "play"
end

--[[
	Bridge news that is not a command.

	Kept deliberately narrow: an unknown event is ignored rather than logged,
	because a newer server talking to an older plugin is a supported situation
	and "unknown event" rows would be the only symptom of it working correctly.
]]
local function onEvent(event: { [string]: any })
	if event.event == "clients" and typeof(event.count) == "number" then
		Console.setClients(event.count)
	elseif event.event == "agent" and event.state == "finished" then
		Console.agentFinished()
	elseif event.event == "peer" and typeof(event.op) == "string" then
		--[[
			A command another session on this place just finished.

			Logged as if it had run here, because as far as the user is concerned
			it did: they pressed Play, watched the agent work, pressed Stop, and
			the panel that comes back is this one. Without this it comes back with
			a hole in it exactly the length of the playtest.

			The prism is bumped too -- `beginCall` then `recordCall`, back to
			back -- so the trace carries a bar for the call and the session
			counters count it. Nothing here reaches the transport, so a peer row
			can never be announced onwards and two sessions cannot echo forever.
		]]
		local params = if typeof(event.params) == "table" then event.params else nil
		local title = Phrase.of(event.op, params)
		local milliseconds = if typeof(event.ms) == "number" then event.ms else 0
		local ok = event.ok == true
		local detail = string.format("%s %.0fms", peerTag(event.from), milliseconds)

		Console.beginCall(title, Phrase.kindOf(event.op))
		Console.recordCall(ok, milliseconds)
		if ok then
			Console.log("reply", title, detail)
		else
			Console.log("error", string.format("%s failed", title), detail)
		end
	end
end

function connect()
	local allowed, reason = canConnect()
	if not allowed then
		-- Reported as standby rather than an error: nothing failed, and this
		-- session was never going to connect.
		currentStatus = "disconnected"
		Console.log("dim", "mirroring", reason)
		Console.setStatus(
			"mirroring",
			string.format("%s  build %s", "client view", Config.BUILD_ID)
		)
		Console.setCaption("mirroring the playtest server")
		return
	end
	Transport.start(studioId(), { onCommand = onCommand, onStatus = onStatus, onEvent = onEvent })
	plugin:SetSetting(SETTING_AUTOCONNECT, true)
end

button.Click:Connect(function()
	widget.Enabled = not widget.Enabled
end)

plugin.Unloading:Connect(function()
	Transport.stop()
end)

--[[
	Switches this session between the push and long-poll transports.

	Registered here rather than in a handler module because it is the only
	command that has to reach back into the plugin object and the connection
	loop, both of which live in this file -- and registered THIS far down the
	file on purpose: `connect` is a forward-declared local, so a closure written
	above its declaration captures the global of that name instead, which is nil.
	That cost a session. The plugin loaded and connected perfectly, and then died
	the first time somebody asked it to switch transport.

	The reply is sent before the reconnect, and the reconnect is deferred:
	tearing the stream down inside the handler would strand the answer to the
	very call that asked for the switch, which is a confusing way to succeed.
]]
Dispatch.registerAll("studio", {
	transport = function(params: { [string]: any }): { [string]: any }
		local requested = params.mode
		if requested ~= nil and requested ~= "sse" and requested ~= "poll" then
			Dispatch.fail("BAD_PARAMS", 'transport mode must be "sse" or "poll".')
		end
		if requested == nil then
			return { mode = Transport.getMode(), forcePoll = Transport.getForcePoll(), changed = false }
		end

		local wantPoll = requested == "poll"
		if Transport.getMode() == requested and Transport.getForcePoll() == wantPoll then
			return { mode = Transport.getMode(), forcePoll = wantPoll, changed = false }
		end

		Transport.setForcePoll(wantPoll)
		plugin:SetSetting(SETTING_FORCE_POLL, wantPoll)
		task.defer(function()
			Transport.stop()
			task.wait(0.1)
			connect()
		end)
		return {
			mode = requested,
			forcePoll = wantPoll,
			changed = true,
			note = "Reconnecting on the new transport; the next call will use it.",
		}
	end,
})

refreshMeta()

-- Connect on load unless the user explicitly disconnected last session.
if plugin:GetSetting(SETTING_AUTOCONNECT) ~= false then
	connect()
else
	Console.log("warn", "auto-connect disabled — press reconnect to start")
end
