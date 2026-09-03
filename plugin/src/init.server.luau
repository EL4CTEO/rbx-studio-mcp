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
local LogBuffer = require(script.LogBuffer)
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
			.. "requests. The playtest's server session is connected and handling this "
			.. "place; switch Studio to the Server view (Test tab, Current: Server) to "
			.. "watch it work."
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

-- Enabled by default: the whole point is that opening a place shows you it
-- connected without touching anything. Studio remembers the user's choice after
-- the first time they close it.
local widget = plugin:CreateDockWidgetPluginGuiAsync(
	"StudioMCP_Console",
	DockWidgetPluginGuiInfo.new(Enum.InitialDockState.Float, true, false, 560, 320, 360, 200)
)
widget.Title = "rbx-studio"

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
	end
end

function connect()
	local allowed, reason = canConnect()
	if not allowed then
		-- Reported as standby rather than an error: nothing failed, and this
		-- session was never going to connect.
		currentStatus = "disconnected"
		Console.log("dim", "standby", reason)
		Console.setStatus(
			"standby",
			string.format("%s  build %s", "client view", Config.BUILD_ID)
		)
		Console.setCaption("switch to the Server view to watch this playtest")
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
