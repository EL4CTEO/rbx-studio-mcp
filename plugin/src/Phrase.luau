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
		-- The first meaningful line stands in for the whole snippet: it is
		-- almost always the call that says what the snippet is for.
		for line in string.gmatch(source, "[^\r\n]+") do
			local trimmed = string.match(line, "^%s*(.-)%s*$") or ""
			if trimmed ~= "" and string.sub(trimmed, 1, 2) ~= "--" then
				if #trimmed > 40 then
					trimmed = string.sub(trimmed, 1, 39) .. "\u{2026}"
				end
				return "Run: " .. trimmed
			end
		end
		return "Run Luau"
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

	["studio.status"] = function()
		return "Check Studio"
	end,
	["studio.ping"] = function()
		return "Ping"
	end,
}

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
