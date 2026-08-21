--!strict
--[[
	Turns a command into something a person can read at a glance.

	The console used to print the wire name: `-> script.edit`, `-> instances.create`.
	That tells you the plugin is alive and nothing else. Watching an agent work,
	the interesting question is always "what is it touching" -- and the answer is
	sitting right there in the parameters, one field away from being shown.

	So `script.edit` on ServerScriptService.KillBrick becomes "Edit KillBrick",
	and `instances.create` with eight children becomes "Create 8 instances in
	Workspace". The subject is what the user recognises; the op is what the
	protocol needed.

	Three rules hold this together:

	  Name the subject, not the path. "KillBrick" is what someone called their
	  script; "ServerScriptService.Systems.KillBrick" is where it lives, and it
	  buries the recognisable part behind the part that never changes.

	  Count when there are several. "Edit 4 scripts" is worth reading. Listing
	  four paths in a 76-pixel-wide log line is not.

	  Never invent. An unknown op falls back to a tidied version of its own name
	  rather than a guess, because a console that lies about what ran is worse
	  than one that reads awkwardly.
]]

local Phrase = {}

-- The tail of a dotted path is the bit a human named. Everything before it is
-- Roblox's filing system.
local function leaf(path: any): string?
	if typeof(path) ~= "string" or path == "" then
		return nil
	end
	local last = string.match(path, "([^%.]+)$")
	if last == nil or last == "" then
		return nil
	end
	-- Array indexing survives into the name -- "Part[3]" is meaningfully
	-- different from "Part" when there are several siblings.
	return last
end

local function count(value: any): number
	if typeof(value) ~= "table" then
		return 0
	end
	return #(value :: { any })
end

--[[
	"1 script" / "4 scripts", without the caller assembling it each time.
]]
local function plural(n: number, singular: string, pluralForm: string?): string
	local word = if n == 1 then singular else (pluralForm or (singular .. "s"))
	return string.format("%d %s", n, word)
end

--[[
	Describes a list of paths: the name when there is one, a count when there are
	several. This is the shape most batch tools take.
]]
local function subjectOf(paths: any, noun: string): string
	local total = count(paths)
	if total == 1 then
		local name = leaf((paths :: { any })[1])
		if name ~= nil then
			return name
		end
	end
	if total > 1 then
		return plural(total, noun)
	end
	return noun
end

--[[
	Capitalises an op fragment for the fallback. `snapshots` -> `Snapshots`.
]]
local function titleCase(value: string): string
	return (string.upper(string.sub(value, 1, 1)) .. string.sub(value, 2))
end

type Describer = (params: { [string]: any }) -> string

--[[
	One entry per op. Each reads its own parameters, because what identifies a
	call differs completely between them: a script edit is about a path, a
	playtest is about a mode, a find is about what was searched for.
]]
local DESCRIBERS: { [string]: Describer } = {
	["script.read"] = function(params)
		return "Read " .. subjectOf(params.paths, "script")
	end,
	["script.edit"] = function(params)
		local edits = params.edits
		local total = count(edits)
		if total == 1 then
			local name = leaf((edits :: { any })[1].path)
			if name ~= nil then
				return "Edit " .. name
			end
		end
		-- Several edits often land on one script, and "Edit 3 scripts" would be
		-- wrong when it is three changes to one file.
		local seen: { [string]: boolean } = {}
		local distinct = 0
		for _, edit in (edits or {}) :: { { [string]: any } } do
			local name = leaf(edit.path)
			if name ~= nil and not seen[name] then
				seen[name] = true
				distinct += 1
			end
		end
		if distinct == 1 then
			for name in seen do
				return string.format("Edit %s (%s)", name, plural(total, "change"))
			end
		end
		return string.format("Edit %s", plural(distinct, "script"))
	end,
	["script.create"] = function(params)
		local scripts = params.scripts
		if count(scripts) == 1 then
			local one = (scripts :: { any })[1]
			local className = if typeof(one.className) == "string" then one.className else "Script"
			return string.format("Create %s %s", one.name or "script", className)
		end
		return "Create " .. plural(count(scripts), "script")
	end,
	["script.grep"] = function(params)
		local pattern = if typeof(params.pattern) == "string" then params.pattern else "?"
		return string.format('Search scripts for "%s"', pattern)
	end,

	["instances.create"] = function(params)
		local instances = params.instances
		local total = count(instances)
		if total == 1 then
			local one = (instances :: { any })[1]
			local name = one.name or one.className or "instance"
			local where = leaf(one.parent)
			return if where ~= nil
				then string.format("Create %s in %s", name, where)
				else "Create " .. name
		end
		local where = if total > 0 then leaf((instances :: { any })[1].parent) else nil
		return if where ~= nil
			then string.format("Create %s in %s", plural(total, "instance"), where)
			else "Create " .. plural(total, "instance")
	end,
	["instances.modify"] = function(params)
		local targets = params.targets
		-- Each target carries its own path list, so the honest count is the
		-- total across them rather than the number of entries.
		local total = 0
		local onlyName: string? = nil
		for _, target in (targets or {}) :: { { [string]: any } } do
			local paths = count(target.paths)
			total += paths
			if paths >= 1 and onlyName == nil then
				onlyName = leaf((target.paths :: { any })[1])
			end
		end
		if total == 1 and onlyName ~= nil then
			return "Modify " .. onlyName
		end
		return "Modify " .. plural(total, "instance")
	end,
	["instances.delete"] = function(params)
		return "Delete " .. subjectOf(params.paths, "instance")
	end,
	["instances.move"] = function(params)
		local items = params.items
		local total = count(items)
		local cloning = total > 0 and (items :: { any })[1].mode == "clone"
		local verb = if cloning then "Clone" else "Move"
		if total == 1 then
			local one = (items :: { any })[1]
			local what = leaf(one.path)
			local where = leaf(one.to)
			if what ~= nil and where ~= nil then
				return string.format("%s %s to %s", verb, what, where)
			end
			if what ~= nil then
				return verb .. " " .. what
			end
		end
		return string.format("%s %s", verb, plural(total, "instance"))
	end,

	["discover.tree"] = function(params)
		local where = leaf(params.path)
		return if where ~= nil then "Browse " .. where else "Browse the place"
	end,
	["discover.inspect"] = function(params)
		return "Inspect " .. subjectOf(params.paths, "instance")
	end,
	["discover.find"] = function(params)
		if typeof(params.tag) == "string" and params.tag ~= "" then
			return string.format('Find things tagged "%s"', params.tag)
		end
		if typeof(params.nameContains) == "string" and params.nameContains ~= "" then
			return string.format('Find "%s"', params.nameContains)
		end
		if typeof(params.className) == "string" and params.className ~= "" then
			return string.format("Find every %s", params.className)
		end
		return "Search the place"
	end,

	["script.debugSet"] = function()
		return "Set breakpoints"
	end,
	["debug.set"] = function(params)
		local breakpoints = params.breakpoints
		local total = count(breakpoints)
		if total == 1 then
			local one = (breakpoints :: { any })[1]
			local name = leaf(one.path)
			if name ~= nil then
				return string.format("Break on %s:%s", name, tostring(one.line))
			end
		end
		return "Set " .. plural(total, "breakpoint")
	end,
	["debug.clear"] = function(params)
		local name = leaf(params.path)
		return if name ~= nil then "Clear breakpoints in " .. name else "Clear all breakpoints"
	end,
	["debug.snapshots"] = function()
		return "Read what the breakpoints caught"
	end,
	["debug.exceptions"] = function(params)
		return string.format("Break on errors: %s", tostring(params.mode or "Unhandled"))
	end,

	["perf.console"] = function(params)
		if typeof(params.level) == "string" and params.level ~= "" then
			return string.format("Read the %s log", params.level)
		end
		if typeof(params.pattern) == "string" and params.pattern ~= "" then
			return string.format('Search output for "%s"', params.pattern)
		end
		return "Read the output log"
	end,
	["perf.snapshot"] = function()
		return "Measure performance"
	end,
	["perf.profile"] = function(params)
		return string.format("Profile scripts for %ss", tostring(params.seconds or 5))
	end,
	["perf.coverage"] = function(params)
		local total = count(params.enable)
		if total > 0 then
			return "Instrument " .. plural(total, "script")
		end
		return "Read line coverage"
	end,

	["playtest.control"] = function(params)
		local op = tostring(params.op or "state")
		if op == "play" then
			return "Start a playtest"
		elseif op == "run" then
			return "Run the place"
		elseif op == "multiplayer" then
			return string.format("Start a %s test", plural(tonumber(params.players) or 2, "player"))
		elseif op == "stop" then
			return "Stop the playtest"
		elseif op == "endTest" then
			return "End the test"
		end
		return "Check the playtest"
	end,

	["exec.run"] = function(params)
		local source = if typeof(params.source) == "string" then params.source else ""

		--[[
			Says what the code is about, not what its first line says.

			This used to show the opening line verbatim, which produced entries
			like "Run: local GenerationService = game:GetServi..." -- a fragment
			of a variable declaration, cut mid-word, telling the reader nothing
			except that some code ran. The declaration is never the point of a
			snippet; it is the setup before it.

			So the services it touches stand in for it. That is the one thing a
			snippet reliably says about itself, it is short, and it is what
			someone glancing at the console actually wants: which part of Studio
			is being poked.
		]]
		local services: { string } = {}
		local seen: { [string]: boolean } = {}
		for name in string.gmatch(source, 'GetService%("([%w_]+)"%)') do
			if not seen[name] then
				seen[name] = true
				table.insert(services, name)
			end
		end

		local lines = 0
		for _ in string.gmatch(source, "[^\r\n]+") do
			lines += 1
		end

		if #services == 1 then
			return "Run Luau on " .. services[1]
		elseif #services == 2 then
			return string.format("Run Luau on %s and %s", services[1], services[2])
		elseif #services > 2 then
			return string.format("Run Luau on %s and %d more", services[1], #services - 1)
		end
		return if lines <= 1 then "Run Luau" else string.format("Run Luau (%d lines)", lines)
	end,

	["viewport.select"] = function(params)
		local total = count(params.paths)
		if total == 0 then
			return "Clear the selection"
		end
		return "Select " .. subjectOf(params.paths, "instance")
	end,
	["viewport.raycast"] = function()
		return "Cast a ray"
	end,

	["capture.screenshot"] = function()
		return "Take a screenshot"
	end,
	["capture.playtestId"] = function()
		return "Capture the playtest view"
	end,
	["capture.decode"] = function()
		return "Read back the capture"
	end,

	["viewport.focus"] = function(params)
		local name = leaf(params.path)
		return if name ~= nil then "Look at " .. name else "Move the camera"
	end,
	["viewport.camera"] = function()
		return "Move the camera"
	end,

	["geometry.combine"] = function(params)
		local op = tostring(params.op or "union")
		local name = leaf(params.path)
		local verb = if op == "subtract" then "Cut" elseif op == "intersect" then "Intersect" else "Merge"
		if op == "subtract" and name ~= nil then
			local from = count(params.with)
			return string.format("Cut %s out of %s", plural(from, "shape"), name)
		end
		return if name ~= nil then string.format("%s %s", verb, name) else verb .. " parts"
	end,
	["geometry.fragment"] = function(params)
		local name = leaf(params.path)
		return if name ~= nil
			then string.format("Shatter %s into %s", name, plural(tonumber(params.pieces) or 8, "piece"))
			else "Shatter a part"
	end,

	["assets.insert"] = function(params)
		return string.format("Insert asset %s", tostring(params.assetId or "?"))
	end,

	["world.history"] = function(params)
		local action = tostring(params.action or "status")
		if action == "status" then
			return "Check the undo history"
		end
		local steps = tonumber(params.steps) or 1
		return string.format("%s %s", if action == "undo" then "Undo" else "Redo", plural(steps, "step"))
	end,
	["world.collision"] = function(params)
		local action = tostring(params.action or "list")
		local group = if typeof(params.group) == "string" then params.group else "?"
		if action == "list" then
			return "List collision groups"
		elseif action == "create" then
			return "Create collision group " .. group
		elseif action == "assign" then
			return string.format("Put %s in %s", plural(count(params.paths), "instance"), group)
		end
		return string.format("Set %s against %s", group, tostring(params.with or "?"))
	end,

	["character.moveTo"] = function(params)
		local name = leaf(params.path)
		return if name ~= nil then "Walk to " .. name else string.format("Walk to %s", tostring(params.to or "?"))
	end,
	["character.act"] = function(params)
		local action = tostring(params.action or "jump")
		return titleCase(action) .. " the character"
	end,
	["character.state"] = function()
		return "Check the character"
	end,

	["studio.status"] = function()
		return "Check Studio"
	end,
	["studio.ping"] = function()
		return "Ping"
	end,
	["studio.transport"] = function(params)
		local mode = params.mode
		return if typeof(mode) == "string" and mode ~= ""
			then string.format("Switch to %s transport", mode)
			else "Check the transport"
	end,

	--[[
		The one a person actually watches: a live playtest is the point where
		"what is the AI doing" stops being abstract, and a console line reading
		"Input send" says nothing a bystander could act on. One step names the
		key or point; several collapse to a count, same as every other batch op.
	]]
	["input.send"] = function(params)
		local steps = params.steps
		local total = count(steps)
		if total == 1 then
			local step = (steps :: { any })[1]
			local kind = tostring(step.kind or "key")
			if kind == "key" then
				local action = tostring(step.action or "tap")
				local verb = if action == "press" then "Hold" elseif action == "release" then "Release" else "Press"
				return string.format("%s %s", verb, tostring(step.key or "?"))
			elseif kind == "click" then
				return string.format("Click (%s, %s)", tostring(step.x or "?"), tostring(step.y or "?"))
			elseif kind == "move" then
				return "Move the pointer"
			elseif kind == "text" then
				return string.format('Type "%s"', tostring(step.text or ""))
			end
		end
		return "Send " .. plural(total, "input step")
	end,

	["api.describe"] = function(params)
		local className = params.className
		return if typeof(className) == "string" and className ~= ""
			then "Look up " .. className
			else "Look up a class"
	end,
	["api.classes"] = function(params)
		local needle = params.contains
		return if typeof(needle) == "string" and needle ~= ""
			then string.format('Search classes for "%s"', needle)
			else "List classes"
	end,

	["perf.scene"] = function(params)
		local section = params.section
		return if typeof(section) == "string" and section ~= ""
			then "Measure the " .. section
			else "Measure the scene"
	end,

	["device.list"] = function()
		return "List devices"
	end,
	["device.set"] = function(params)
		local id = params.device
		return if typeof(id) == "string" and id ~= "" then "Emulate " .. id else "Emulate a device"
	end,
	["device.stop"] = function()
		return "Stop emulating a device"
	end,
	["device.state"] = function()
		return "Check the emulated device"
	end,
}

--[[
	What kind of work an op is, for anything that wants to colour it.

	Grouped by what it does to the place rather than by which handler owns it,
	because that is the distinction someone watching cares about: reading is
	safe and constant, writing changes their game, and running executes code.
]]
local KINDS: { [string]: string } = {
	discover = "read",
	studio = "read",
	viewport = "read",
	capture = "read",
	instances = "write",
	geometry = "write",
	assets = "write",
	world = "write",
	exec = "run",
	playtest = "run",
	character = "run",
	-- Live keys and clicks into a running playtest are an action, not a read,
	-- and belong beside character/exec rather than defaulting to "read".
	input = "run",
	debug = "debug",
	perf = "debug",
	api = "read",
	device = "read",
}

function Phrase.kindOf(op: string): string
	local group = string.match(op, "^([^%.]+)%.") or op
	-- Reads within the script group, writes outside it: a script edit changes
	-- the game, a read or a grep does not, and they are far apart in weight.
	if group == "script" then
		local action = string.match(op, "%.(.+)$") or ""
		return if action == "read" or action == "grep" then "read" else "write"
	end
	return KINDS[group] or "read"
end

--[[
	The readable form of one command.

	Never throws and never yields: this runs on the path that logs every call,
	including the ones that are about to fail, and a console that errors while
	describing an error would take the diagnosis with it.
]]
function Phrase.of(op: string, params: { [string]: any }?): string
	local describer = DESCRIBERS[op]
	if describer ~= nil then
		local ok, described = pcall(describer, params or {})
		if ok and typeof(described) == "string" and described ~= "" then
			return described
		end
	end

	-- Unknown op, or a describer that met a shape it did not expect. Tidy the
	-- wire name rather than inventing a subject for it: "instances.create"
	-- becomes "Instances create", which is honest about knowing no better.
	local group, action = string.match(op, "^([^%.]+)%.(.+)$")
	if group ~= nil and action ~= nil then
		return titleCase(group) .. " " .. action
	end
	return titleCase(op)
end

return Phrase
