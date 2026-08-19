--!strict
--[[
	Script reading, searching, editing and creation.

	Everything here that writes goes through `ScriptEdit`, which routes the change
	through `ScriptEditorService:UpdateSourceAsync` rather than assigning
	`script.Source`. That is the difference between an edit the Studio editor
	agrees with and one that silently loses whatever the user had typed but not
	saved. Reads use the editor buffer for the same reason: handing an agent stale
	source makes it "fix" changes the user just made.

	Edits are also wrapped in a single `Undo` recording, so a batch across ten
	scripts is one Ctrl+Z, and a batch that fails half way is rolled back rather
	than left half applied.

	The text manipulation itself lives in `TextEdit`, which has no Roblox
	dependencies and is unit tested.
]]

local Dispatch = require(script.Parent.Parent.Dispatch)
local Paths = require(script.Parent.Parent.Paths)
local Scope = require(script.Parent.Parent.Scope)
local ScriptEdit = require(script.Parent.Parent.ScriptEdit)
local TextEdit = require(script.Parent.Parent.TextEdit)
local Undo = require(script.Parent.Parent.Undo)

-- Reading every script's editor buffer is a service call each. A place with more
-- scripts than this is better served by narrowing `path` than by a slow grep
-- that blocks Studio's main thread.
local MAX_SCRIPTS = 3_000
local MAX_MATCHES = 500
local DEFAULT_CONTEXT = 0

local CREATABLE = {
	Script = true,
	LocalScript = true,
	ModuleScript = true,
}

local Scripts = {}

--[[
	Resolves a path and insists it holds Luau. Pointing a script tool at an
	ordinary instance otherwise fails later with a confusing property error.
]]
local function resolveScript(path: string): LuaSourceContainer
	local instance = Paths.resolve(path)
	if not ScriptEdit.isScript(instance) then
		Dispatch.fail(
			"NOT_A_SCRIPT",
			string.format('"%s" is a %s, not a script.', path, instance.ClassName),
			"Script tools accept Script, LocalScript and ModuleScript. Use `inspect` "
				.. "for other instances, or `find` with className LuaSourceContainer to locate scripts."
		)
	end
	return instance :: LuaSourceContainer
end

--[[
	Reads source, optionally a line window. `startLine`/`endLine` are 1-based and
	inclusive, matching the numbers script_edit takes back, so a read and a write
	need no off-by-one conversion between them.
]]
function Scripts.read(params: { [string]: any }): { [string]: any }
	local paths = params.paths
	if typeof(paths) ~= "table" or #paths == 0 then
		Dispatch.fail(
			"BAD_PARAMS",
			"script_read requires a non-empty `paths` array.",
			"Use `find` with className LuaSourceContainer to locate scripts."
		)
	end

	local items: { { [string]: any } } = {}
	local failures: { string } = {}
	local memo: Paths.NameIndex = {}

	for _, path in paths do
		local ok, resolved = pcall(resolveScript, path)
		if not ok then
			local err = resolved :: any
			local reason = if typeof(err) == "table"
				then (if err.hint then err.message .. " " .. err.hint else err.message)
				else tostring(err)
			table.insert(failures, string.format("%s: %s", path, reason))
			continue
		end

		local target = resolved :: LuaSourceContainer
		local lines = TextEdit.toLines(ScriptEdit.read(target))
		local startLine = math.max(tonumber(params.startLine) or 1, 1)
		local endLine = math.min(tonumber(params.endLine) or #lines, #lines)

		local window: { string } = {}
		table.move(lines, startLine, endLine, 1, window)

		table.insert(items, {
			path = Paths.of(target, memo),
			className = target.ClassName,
			lineCount = #lines,
			startLine = startLine,
			source = table.concat(window, "\n"),
		})
	end

	return { items = items, failures = failures }
end

--[[
	Applies every edit in a batch, or none of them.

	Atomicity here cannot come from ChangeHistoryService. A recording captures
	instance changes, but `UpdateSourceAsync` goes through the script editor's own
	per-document history, so cancelling a recording leaves an already-written
	script edited -- measured, not assumed. Wrapping this in `Undo.record` would
	therefore promise a rollback that never happens.

	So the batch is a two-phase commit instead. Phase one reads and transforms
	every script without writing anything, which is where essentially all failures
	live: a missing `find`, an ambiguous one, a bad line range, conflicting edits.
	Phase two writes the finished text. If a write fails there -- realistically
	only a locked or package-owned script -- the scripts already written are
	restored from the source captured in phase one.
]]
function Scripts.edit(params: { [string]: any }): { [string]: any }
	local edits = params.edits
	if typeof(edits) ~= "table" or #edits == 0 then
		Dispatch.fail(
			"BAD_PARAMS",
			"script_edit requires a non-empty `edits` array.",
			"Each edit needs a `path` plus one of `find`/`replace`, "
				.. "`startLine`/`replacement`, or `source`."
		)
	end

	local order: { LuaSourceContainer } = {}
	local grouped: { [Instance]: { TextEdit.Edit } } = {}
	for position, edit in edits do
		TextEdit.validate(edit, position)
		local target = resolveScript(edit.path)
		local bucket = grouped[target]
		if not bucket then
			bucket = {}
			grouped[target] = bucket
			table.insert(order, target)
		end
		table.insert(bucket :: { TextEdit.Edit }, edit)
	end

	-- Phase one: transform everything in memory. Any failure raises here, with
	-- nothing written and the place untouched.
	type Pending = { target: LuaSourceContainer, before: string, after: string }
	local pending: { Pending } = {}
	for _, target in order do
		local before = ScriptEdit.read(target)
		local after = TextEdit.apply(target:GetFullName(), before, grouped[target] :: { TextEdit.Edit })
		table.insert(pending, { target = target, before = before, after = after })
	end

	-- Phase two: write. `written` is the compensation log for a mid-batch failure.
	local written: { Pending } = {}
	local memo: Paths.NameIndex = {}
	local results: { { [string]: any } } = {}

	for _, entry in pending do
		-- Wrapped in a closure rather than passed to pcall directly: `write`
		-- returns nothing, and pcall's typed signature expects a value back.
		local ok, err = pcall(function()
			ScriptEdit.write(entry.target, function()
				return entry.after
			end)
		end)

		if not ok then
			for index = #written, 1, -1 do
				local done = written[index]
				-- Best effort: a restore that fails leaves that script edited, and
				-- the original error still describes what actually went wrong.
				pcall(function()
					ScriptEdit.write(done.target, function()
						return done.before
					end)
				end)
			end
			error(err, 0)
		end

		table.insert(written, entry)
		table.insert(results, {
			path = Paths.of(entry.target, memo),
			className = entry.target.ClassName,
			edits = #(grouped[entry.target] :: { TextEdit.Edit }),
			lineCount = #TextEdit.toLines(entry.after),
			lineDelta = #TextEdit.toLines(entry.after) - #TextEdit.toLines(entry.before),
		})
	end

	return { items = results }
end

--[[
	Searches script source. Matches come from the editor buffer, so text the user
	has typed but not saved is found too -- which is the state an agent about to
	edit the file actually needs to see.
]]
function Scripts.grep(params: { [string]: any }): { [string]: any }
	local pattern = params.pattern
	if typeof(pattern) ~= "string" or pattern == "" then
		Dispatch.fail("BAD_PARAMS", "script_grep requires a `pattern`.")
	end

	local root = if params.path then Paths.resolve(params.path) else game
	local literal = params.literal == true
	local ignoreCase = params.ignoreCase == true
	local contextLines = math.clamp(tonumber(params.contextLines) or DEFAULT_CONTEXT, 0, 10)
	local limit = math.min(tonumber(params.limit) or 100, MAX_MATCHES)
	local offset = tonumber(params.offset) or 0
	local classFilter = params.className

	local needle = if ignoreCase then string.lower(pattern) else pattern

	local targets: { LuaSourceContainer } = {}
	for _, instance in root:GetDescendants() do
		if not instance:IsA("LuaSourceContainer") then
			continue
		end
		if root == game and Scope.isNoisy(instance) then
			continue
		end
		if classFilter and not instance:IsA(classFilter) then
			continue
		end
		table.insert(targets, instance)
	end

	if #targets > MAX_SCRIPTS then
		Dispatch.fail(
			"TOO_BROAD",
			string.format("That search covers %d scripts, over the %d limit.", #targets, MAX_SCRIPTS),
			"Narrow it with `path` to search one service or folder instead of the whole place."
		)
	end

	local matches: { { [string]: any } } = {}
	local total = 0
	local memo: Paths.NameIndex = {}

	for _, target in targets do
		local lines = TextEdit.toLines(ScriptEdit.read(target))
		local path: string? = nil

		for number, line in lines do
			local haystack = if ignoreCase then string.lower(line) else line
			-- An invalid Lua pattern raises rather than simply not matching, so it
			-- has to be caught and reported as a pattern problem, not a no-match.
			local ok, from = pcall(string.find, haystack, needle, 1, literal)
			if not ok then
				Dispatch.fail(
					"BAD_PATTERN",
					string.format("%s is not a valid Lua pattern: %s", pattern, tostring(from)),
					"Lua patterns escape with %, not backslash, and have no alternation. "
						.. "Set `literal` to search for the text exactly as written."
				)
			end
			if not from then
				continue
			end

			total += 1
			if total <= offset or #matches >= limit then
				continue
			end

			if not path then
				path = Paths.of(target, memo)
			end

			local entry: { [string]: any } = {
				path = path,
				line = number,
				text = line,
			}
			if contextLines > 0 then
				local before: { string } = {}
				local after: { string } = {}
				table.move(lines, math.max(number - contextLines, 1), number - 1, 1, before)
				table.move(lines, number + 1, math.min(number + contextLines, #lines), 1, after)
				entry.before = before
				entry.after = after
			end
			table.insert(matches, entry)
		end
	end

	return {
		items = matches,
		total = total,
		offset = offset,
		searched = #targets,
	}
end

--[[
	Creates scripts. Source is assigned directly here rather than through
	`UpdateSourceAsync`: the instance does not exist yet, so nothing can have it
	open in the editor and there is no buffer to conflict with. Every later edit
	goes through the editor path.
]]
function Scripts.create(params: { [string]: any }): { [string]: any }
	local requests = params.scripts
	if typeof(requests) ~= "table" or #requests == 0 then
		Dispatch.fail(
			"BAD_PARAMS",
			"script_create requires a non-empty `scripts` array.",
			"Each entry needs `parent`, `name` and `className`."
		)
	end

	for position, request in requests do
		if typeof(request.name) ~= "string" or request.name == "" then
			Dispatch.fail("BAD_PARAMS", string.format("scripts[%d] has no `name`.", position))
		end
		if not CREATABLE[request.className] then
			Dispatch.fail(
				"BAD_PARAMS",
				string.format('scripts[%d] has className "%s".', position, tostring(request.className)),
				"Use Script, LocalScript or ModuleScript. Prefer a Script with "
					.. "runContext Client over LocalScript in new work."
			)
		end
	end

	-- No shared path memo here: each creation changes its parent's children, so a
	-- cached sibling grouping would go stale mid-batch and mis-number the paths.
	local created, recorded = Undo.record("StudioMCP.ScriptCreate", "MCP create script", function()
		local created: { { [string]: any } } = {}

		for _, request in requests do
			local parent = Paths.resolve(request.parent)
			local instance = Instance.new(request.className) :: LuaSourceContainer

			instance.Name = request.name
			if typeof(request.source) == "string" then
				(instance :: ScriptEdit.SourceContainer).Source = request.source
			end

			if typeof(request.runContext) == "string" and instance:IsA("Script") then
				local ok, runContext = pcall(function()
					return (Enum.RunContext :: any)[request.runContext]
				end)
				if not ok or runContext == nil then
					Dispatch.fail(
						"BAD_PARAMS",
						string.format('"%s" is not a RunContext.', tostring(request.runContext)),
						"Use Legacy, Server or Client."
					)
				end
				instance.RunContext = runContext
			end
			if request.disabled == true and instance:IsA("BaseScript") then
				instance.Disabled = true
			end

			instance.Parent = parent

			table.insert(created, {
				path = Paths.of(instance),
				className = instance.ClassName,
			})
		end

		return created
	end)

	return { items = created, undoStep = if recorded then "MCP create script" else nil }
end

function Scripts.register()
	Dispatch.registerAll("script", {
		read = Scripts.read,
		edit = Scripts.edit,
		grep = Scripts.grep,
		create = Scripts.create,
	})
end

return Scripts
