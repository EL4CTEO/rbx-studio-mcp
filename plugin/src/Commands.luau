--!strict
--[[
	What the console's prompt row does with a line.

	Split from `Console` on purpose. The console owns a log and a widget; half of
	these answers are about the transport, the port setting, the place, or the
	bridge, and wiring all of that into the console to answer `status` would make
	the console the whole plugin.

	Two kinds of line arrive here and they are told apart by one rule: the first
	word is either a command in this table or it is not. If it is, it runs here
	or on the bridge and prints in milliseconds. If it is not, the whole line is
	a request for an agent, and goes to the bridge to be run by whichever coding
	tool the user has installed. Nothing has to be marked, quoted or prefixed --
	`doctor` is a command and "make the door open when I touch it" is not, and no
	person needs that explained.

	Commands answered on the bridge are listed here too, with `remote = true`, so
	`help` and Tab-completion describe the whole surface rather than only the
	half that happens to run in Luau.
]]

local ScriptEditorService = game:GetService("ScriptEditorService")
local Selection = game:GetService("Selection")
local ServerStorage = game:GetService("ServerStorage")

local Config = require(script.Parent.Config)
local Console = require(script.Parent.Console)
local Net = require(script.Parent.Net)
local ThemePicker = require(script.Parent.ThemePicker)
local Themes = require(script.Parent.Themes)

local Commands = {}

export type Hooks = {
	-- Drops the connection and dials again. Owned by init.server, which is the
	-- only thing holding the transport's lifecycle.
	reconnect: () -> (),
	-- `plugin:SetSetting` is not reachable from a ModuleScript, so anything that
	-- has to outlive the session is handed back to the script that can persist it.
	savePort: (number) -> (),
	saveTheme: (string) -> (),
	-- Whether the panel may open itself on load, and the setter for it.
	autoOpen: () -> boolean,
	saveAutoOpen: (boolean) -> (),
	-- The transport's own view of the connection, which the console only ever
	-- receives second-hand as a string to display.
	status: () -> string,
	studioId: () -> string,
}

local hooks: Hooks? = nil

function Commands.setup(value: Hooks)
	hooks = value
end

type Entry = {
	name: string,
	usage: string,
	summary: string,
	-- Answered by the bridge rather than here. Listed all the same: a user
	-- should not have to know which side of the wire a command lives on.
	remote: boolean?,
	run: ((args: { string }) -> ())?,
}

local entries: { Entry } = {}
local byName: { [string]: Entry } = {}

local function define(entry: Entry)
	table.insert(entries, entry)
	byName[entry.name] = entry
end

--[[
	Sends a command to the bridge and prints whatever comes back.

	Answers arrive as rows rather than as text, so the bridge decides what a
	warning IS and this decides what a warning looks like. Both sides formatting
	is how a diagnostic ends up rendered two different ways in one log.
]]
local function remote(command: string, args: { string }, line: string)
	local current = hooks
	local response = Net.postJson("/console", {
		studioId = if current ~= nil then current.studioId() else "",
		command = command,
		args = args,
		line = line,
	})

	if not response.ok then
		Console.setPromptBusy(false)
		Console.log("error", string.format("%s failed", command), response.error)
		return
	end

	local decoded = Net.decode(response.body)
	--[[
		The bridge is the authority on whether an agent is running, so the caret
		follows its answer rather than what this side assumed when it sent the
		line. A prompt that never started -- no harness on PATH is the common one
		-- would otherwise leave the panel looking busy for the rest of the
		session.
	]]
	Console.setPromptBusy(typeof(decoded) == "table" and (decoded :: any).running == true)

	local rows = if typeof(decoded) == "table" then (decoded :: any).lines else nil
	if typeof(rows) ~= "table" then
		Console.log("error", string.format("%s returned nothing readable", command))
		return
	end

	for _, row in rows :: { any } do
		if typeof(row) == "table" and typeof(row.message) == "string" then
			local level = if typeof(row.level) == "string" then row.level else "dim"
			Console.log(
				level :: any,
				row.message,
				if typeof(row.detail) == "string" then row.detail else nil
			)
		end
	end
end

-- Local commands ----------------------------------------------------------

define({
	name = "help",
	usage = "help",
	summary = "list every command",
	run = function()
		Console.log("info", "commands")
		for _, entry in entries do
			Console.log("dim", "   " .. entry.usage, entry.summary)
		end
		Console.log(
			"dim",
			"   anything else",
			"sent to a coding agent -- run `agent` to see which"
		)
	end,
})

define({
	name = "clear",
	usage = "clear",
	summary = "empty the log",
	run = function()
		Console.clear()
	end,
})

define({
	name = "reconnect",
	usage = "reconnect",
	summary = "drop the connection and dial the bridge again",
	run = function()
		local current = hooks
		if current then
			current.reconnect()
		end
	end,
})

define({
	name = "status",
	usage = "status",
	summary = "connection, bridge, build and theme",
	run = function()
		local current = hooks
		Console.log("info", "session")
		Console.log(
			"dim",
			"   connection",
			if current ~= nil then current.status() else "unknown"
		)
		Console.log("dim", "   bridge", Config.baseUrl())
		Console.log(
			"dim",
			"   plugin",
			string.format(
				"v%s  build %s  protocol %d",
				Config.PLUGIN_VERSION,
				Config.BUILD_ID,
				Config.PROTOCOL_VERSION
			)
		)
		Console.log("dim", "   theme", Themes.activeId())
	end,
})

define({
	name = "clients",
	usage = "clients",
	summary = "which MCP clients share this bridge",
	run = function()
		Console.reportClients()
	end,
})

define({
	name = "theme",
	usage = "theme [name]",
	summary = "switch colour preset, or list them",
	run = function(args)
		local wanted = args[1]
		if wanted == nil then
			local active = Themes.activeId()
			Console.log("info", "themes")
			for _, theme in Themes.list() do
				Console.log(
					if theme.id == active then "ok" else "dim",
					"   " .. theme.id,
					if theme.id == active then "in use" else nil
				)
			end
			return
		end

		-- `Themes.use` answers false both for an unknown id and for re-picking
		-- the current one, so the two are separated here rather than reported as
		-- the same shrug.
		if wanted == Themes.activeId() then
			Console.log("dim", string.format("already on %s", wanted))
			return
		end
		if not Themes.use(wanted) then
			Console.log("error", string.format("no theme called %q", wanted), "run `theme` to list them")
			return
		end

		Console.applyTheme()
		ThemePicker.applyTheme()
		local current = hooks
		if current then
			current.saveTheme(wanted)
		end
		Console.log("ok", string.format("theme: %s", wanted))
	end,
})

define({
	name = "visuals",
	usage = "visuals",
	summary = "show or hide the activity band",
	run = function()
		local shown = Console.toggleVisuals()
		Console.log("dim", if shown then "visuals on" else "visuals off")
	end,
})

define({
	name = "autoopen",
	usage = "autoopen [on|off]",
	summary = "let this panel open itself, or only ever from the toolbar",
	run = function(args)
		local current = hooks
		if current == nil then
			return
		end

		local wanted = args[1]
		if wanted == nil then
			Console.log(
				"dim",
				if current.autoOpen()
					then "autoopen on -- the panel opens with the place, and with Play"
					else "autoopen off -- the panel opens only from the toolbar button"
			)
			return
		end

		local value: boolean
		if wanted == "on" then
			value = true
		elseif wanted == "off" then
			value = false
		else
			Console.log("error", string.format("%q is not on or off", wanted), "autoopen [on|off]")
			return
		end

		if value == current.autoOpen() then
			Console.log("dim", string.format("already autoopen %s", wanted))
			return
		end

		current.saveAutoOpen(value)
		--[[
			Said plainly, because nothing about it can be seen from here.

			A dock widget's initial state is decided when Studio creates it, and
			this one already exists -- so the change shows up at the next load,
			not now. A setting that appears to do nothing is a setting the user
			runs again, and then a third time, before deciding it is broken.
		]]
		if value then
			Console.log("ok", "autoopen on", "the panel will come back on its own")
		else
			Console.log(
				"ok",
				"autoopen off",
				"from the next place or playtest, open it from the toolbar"
			)
		end
	end,
})

define({
	name = "place",
	usage = "place",
	summary = "what this Studio window has open",
	run = function()
		Console.log("info", if game.Name ~= "" then game.Name else "Untitled place")
		Console.log("dim", "   placeId", tostring(game.PlaceId))
		Console.log("dim", "   gameId", tostring(game.GameId))
		for _, name in { "Workspace", "ServerScriptService", "ServerStorage", "ReplicatedStorage", "StarterGui" } do
			local service = game:FindFirstChild(name)
			if service ~= nil then
				Console.log("dim", "   " .. name, string.format("%d children", #service:GetChildren()))
			end
		end
	end,
})

--[[
	Every level the log can show, so `log` can be checked against a real list
	rather than silently accepting a typo and hiding everything.
]]
local LEVELS = { "ok", "error", "warn", "info", "dim", "call", "reply" }

define({
	name = "log",
	usage = "log [level|all]",
	summary = "filter the log by kind, or `all` for everything",
	run = function(args)
		local wanted = args[1]
		if wanted == nil or wanted == "all" then
			Console.setFilter(nil)
			Console.log("dim", "showing everything")
			return
		end
		if not table.find(LEVELS, wanted) then
			Console.log(
				"error",
				string.format("no level called %q", wanted),
				table.concat(LEVELS, " ") .. " all"
			)
			return
		end
		--[[
			An error filter shows warnings too.

			Someone typing `log error` is looking for what went wrong, and a
			warning is part of that answer. Filtering to the single level would
			hide the row that usually explains the failure below it.
		]]
		local levels = if wanted == "error" then { "error", "warn" } else { wanted }
		Console.setFilter(levels)
		Console.log("dim", string.format("showing %s only", table.concat(levels, " and ")))
	end,
})

define({
	name = "copy",
	usage = "copy",
	summary = "put the log somewhere it can be selected and copied",
	run = function()
		--[[
			Studio gives plugins no clipboard, and a TextLabel cannot be selected.

			So the log goes where selection and Ctrl+C already work: a script
			editor tab. The rows are written as comments -- see
			`Console.plainText` -- so the tab opens as something to read rather
			than as a wall of syntax errors, and the document is opened for the
			user rather than merely selected, which turns a two-step
			"find it in Explorer, double-click it" into typing one word.

			Parented to ServerStorage so it can never end up in a published
			place, and replaced rather than accumulated so running it twice does
			not litter the tree.
		]]
		local existing = ServerStorage:FindFirstChild("rbx-studio log")
		if existing then
			existing:Destroy()
		end
		local holder = Instance.new("Script")
		holder.Name = "rbx-studio log"
		holder.Source = Console.plainText()
		holder.Enabled = false
		holder.Parent = ServerStorage
		Selection:Set({ holder })

		--[[
			Opening is best effort, and deliberately not fatal.

			`OpenScriptDocumentAsync` yields and can fail -- the editor may
			refuse, and it is PluginSecurity, so a future Studio could withdraw
			it. The script exists and is selected either way, which is the part
			that matters; all that is lost is the convenience, so the failure is
			reported as the extra step it costs rather than as an error.
		]]
		local opened = pcall(function()
			ScriptEditorService:OpenScriptDocumentAsync(holder)
		end)
		if opened then
			Console.log("ok", "log opened in a script tab", "select all and copy")
		else
			Console.log(
				"ok",
				"log written to ServerStorage",
				"selected -- open it from Explorer and copy"
			)
		end
	end,
})

define({
	name = "port",
	usage = "port [number]",
	summary = "show, or move to, the bridge port",
	run = function(args)
		local wanted = args[1]
		if wanted == nil then
			Console.log("dim", string.format("port %d", Config.getPort()))
			return
		end
		local value = tonumber(wanted)
		if value == nil or value ~= math.floor(value) or value < 1 or value > 65535 then
			Console.log("error", string.format("%q is not a port", wanted))
			return
		end
		Config.setPort(value :: number)
		local current = hooks
		if current then
			current.savePort(value :: number)
			Console.log("ok", string.format("port %d -- reconnecting", value))
			current.reconnect()
		end
	end,
})

define({
	name = "version",
	usage = "version",
	summary = "version, build and protocol of this plugin",
	run = function()
		Console.log(
			"info",
			string.format("rbx-studio v%s", Config.PLUGIN_VERSION),
			string.format("build %s  protocol %d", Config.BUILD_ID, Config.PROTOCOL_VERSION)
		)
		Console.log("dim", "run doctor to compare it against the installed package")
	end,
})

-- Bridge commands ---------------------------------------------------------

define({ name = "doctor", usage = "doctor", summary = "check every part of the setup", remote = true })
define({ name = "studios", usage = "studios", summary = "Studio windows on this bridge", remote = true })
define({ name = "use", usage = "use <number|id>", summary = "point calls at one Studio", remote = true })
define({
	name = "agent",
	usage = "agent [use <id>|new]",
	summary = "which coding agent runs your prompts",
	remote = true,
})
define({ name = "stop", usage = "stop", summary = "cancel the running agent", remote = true })

-- Dispatch ----------------------------------------------------------------

--[[
	What a command looks like to the menu above the prompt.

	Deliberately the same three fields `help` prints. A user who learns the
	surface from the menu and a user who learns it from `help` should be
	learning the same thing, and two descriptions of one command are two things
	to keep in step.
]]
export type Suggestion = {
	name: string,
	usage: string,
	summary: string,
}

--[[
	Commands starting with `prefix`, described.

	An empty prefix answers with everything, which is what the menu shows the
	moment the field is focused: the old row said "type a command" and then left
	the reader to guess which ones existed.

	Sorted so the list does not reorder itself between keystrokes, which is
	exactly the sort of movement that makes a suggestion unreadable.
]]
function Commands.suggest(prefix: string): { Suggestion }
	local matches: { Suggestion } = {}
	for _, entry in entries do
		if string.sub(entry.name, 1, #prefix) == prefix then
			table.insert(matches, {
				name = entry.name,
				usage = entry.usage,
				summary = entry.summary,
			})
		end
	end
	table.sort(matches, function(a, b)
		return a.name < b.name
	end)
	return matches
end

--[[
	Command names starting with `prefix`, for Tab and for the hint.

	Built on `suggest` rather than beside it, so the two can never disagree
	about what matches.
]]
function Commands.complete(prefix: string): { string }
	local names: { string } = {}
	for _, suggestion in Commands.suggest(prefix) do
		table.insert(names, suggestion.name)
	end
	return names
end

--[[
	The nearest command to something that is not one.

	Only ever a hint, and only for a single edit's distance, because the whole
	point of the free-text path is that an unrecognised word is usually a
	sentence rather than a typo. Suggesting `doctor` for "door" would be worse
	than saying nothing.
]]
local function nearest(word: string): string?
	for _, entry in entries do
		local name = entry.name
		if math.abs(#name - #word) <= 1 then
			-- Cheap and sufficient: a shared prefix of everything but the last
			-- character or two catches the transpositions and dropped letters
			-- that actually happen at a prompt.
			local shared = 0
			while shared < math.min(#name, #word) and string.sub(name, shared + 1, shared + 1) == string.sub(word, shared + 1, shared + 1) do
				shared += 1
			end
			if shared >= #name - 1 and shared >= 3 then
				return name
			end
		end
	end
	return nil
end

--[[
	Runs one submitted line.

	Everything here is already off the input's thread -- `Prompt` spawns it --
	so a remote command is free to block on the bridge without freezing the
	field the user is typing into.
]]
function Commands.run(line: string)
	local trimmed = string.match(line, "^%s*(.-)%s*$") or ""
	if trimmed == "" then
		return
	end

	-- Echoed before anything runs, so the log shows what was asked as well as
	-- what came back. Without it a command that prints one line looks like a
	-- line that appeared on its own.
	Console.log("call", trimmed, "you")

	local words: { string } = {}
	for word in string.gmatch(trimmed, "%S+") do
		table.insert(words, word)
	end

	local head = string.lower(words[1])
	-- `?` is the one alias, because it is what people type before they have
	-- learned there is a `help`.
	if head == "?" then
		head = "help"
	end

	local entry = byName[head]
	if entry == nil then
		--[[
			Not a command, so it is a request.

			A single mistyped word is the one case worth querying: it is short,
			it matches something closely, and sending it to an agent would spend
			real money answering a typo.
		]]
		if #words == 1 then
			local guess = nearest(head)
			if guess ~= nil then
				Console.log("dim", string.format("no command %q -- did you mean %s?", head, guess))
				return
			end
		end
		Console.setPromptBusy(true)
		remote("prompt", words, trimmed)
		return
	end

	local args = table.move(words, 2, #words, 1, {} :: { string })

	if entry.remote then
		remote(entry.name, args, trimmed)
		return
	end

	local run = entry.run
	if run ~= nil then
		local ok, err = pcall(run, args)
		if not ok then
			Console.log("error", string.format("%s failed", entry.name), tostring(err))
		end
	end
end

return Commands
