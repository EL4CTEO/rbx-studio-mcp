--!strict
--[[
	Script reading, searching, editing and creation.

	Everything here that writes goes through `ScriptEdit`, which routes the change
	through `ScriptEditorService:UpdateSourceAsync` rather than assigning
	`script.Source`. That is the difference between an edit the Studio editor
	agrees with and one that silently loses whatever the user had typed but not
	saved. Reads use the editor buffer for the same reason: handing an agent stale
	source makes it "fix" changes the user just made.

	Source undo is the script editor's own, per script -- a ChangeHistoryService
	recording cannot capture an editor write. What a batch gets instead is
	all-or-nothing application (see `edit`) and the shared mutation lock, so two
	batches never interleave their writes.

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
	Whether a script is really the source of truth, or a copy of a file on disk.

	Studio can bind a script to a file outside it -- the external-editor
	workflows, and the Auto-Reimport beta. When that binding exists, whatever is
	written here is overwritten the next time the file changes, and the write
	looks like it worked right up until it silently does not. That failure is
	invisible from inside the data model: the script has a Source property like
	any other.

	`InstanceFileSyncService` knows, and says so at plugin identity. It is read
	only -- there is no call here that starts, stops or redirects a sync -- so
	the worst this can do is add a sentence to a reply.

	Guarded end to end, and deliberately silent when unavailable: a Studio
	without the service, or a place with no sync set up, should cost this note
	and nothing else.
]]
local function syncedFile(target: Instance): string?
	local service = game:FindService("InstanceFileSyncService")
	if service == nil then
		return nil
	end
	local ok, status = pcall(function()
		return (service :: any):GetStatus(target)
	end)
	if not ok or status == nil then
		return nil
	end
	local name = tostring(status):gsub("Enum%.InstanceFileSyncStatus%.", "")
	-- "NotSynced" is the ordinary case and saying it every time would be noise.
	if name == "NotSynced" or name == "Unknown" or name == "nil" then
		return nil
	end
	return name
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

	--[[
		Each entry may carry its own line window, because the shape that actually
		comes up is "line 40 of this one, line 300 of that one" -- and a single
		range shared across the whole batch forced one call per script, which is
		what batching this tool was for in the first place.

		A plain string still means the whole file, or the batch-wide range when
		one was given.
	]]
	for _, entry in paths do
		local windowed = typeof(entry) == "table"
		local path = if windowed then entry.path else entry
		local ok, resolved = pcall(resolveScript, path)
		if not ok then
			local err = resolved :: any
			local reason = if typeof(err) == "table"
				then (if err.hint then err.message .. " " .. err.hint else err.message)
				else tostring(err)
			table.insert(failures, string.format("%s: %s", tostring(path), reason))
			continue
		end

		local target = resolved :: LuaSourceContainer
		local whole = ScriptEdit.read(target)
		local lines = TextEdit.toLines(whole)
		local askedStart = if windowed and entry.startLine ~= nil
			then tonumber(entry.startLine)
			else tonumber(params.startLine)
		local askedEnd = if windowed and entry.endLine ~= nil
			then tonumber(entry.endLine)
			else tonumber(params.endLine)
		local startLine = math.max(askedStart or 1, 1)
		local endLine = math.min(askedEnd or #lines, #lines)

		local window: { string } = {}
		table.move(lines, startLine, endLine, 1, window)

		table.insert(items, {
			path = Paths.of(target, memo),
			className = target.ClassName,
			lineCount = #lines,
			startLine = startLine,
			endLine = askedEnd,
			source = table.concat(window, "\n"),
			-- Of the whole file, never of the window: `edit` compares it against
			-- the live source, and a fingerprint of forty lines out of four
			-- hundred would call an edit safe that it is not.
			revision = ScriptEdit.revisionOf(target, whole),
			-- Absent unless the script is bound to a file on disk, in which case
			-- editing it here is a race against whatever writes that file.
			fileSync = syncedFile(target),
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

	Phase one reads, phase two writes, and the editor yields in between, so the
	user can type into a script after it was read. Each write therefore checks,
	inside the editor's own callback, that the text is still what phase one
	transformed, and a restore only puts back text that is still ours. Anything
	newer is kept and named, rather than silently overwritten on either path.
]]
local function editBatch(params: { [string]: any }): { [string]: any }
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
		--[[
			Refuse before transforming, not after.

			An edit that names the revision it was written against is asking to
			be applied to that exact text. If the file has moved on, the honest
			answer is to stop: a line range still applies cleanly to changed
			source, it just lands on the wrong lines, and a `source` edit throws
			away everything written since it was read. Both look like success.

			Checked here so the whole batch fails with nothing written, which is
			the promise every other phase-one failure already makes.
		]]
		local live: string? = nil
		for _, edit in grouped[target] :: { TextEdit.Edit } do
			local stated = (edit :: any).revision
			if typeof(stated) ~= "string" or stated == "" then
				continue
			end
			live = live or ScriptEdit.revisionOf(target, before)
			if stated ~= live then
				Dispatch.fail(
					"STALE_SCRIPT",
					string.format(
						"%s changed since it was read (expected %s, found %s).",
						target:GetFullName(),
						stated,
						live :: string
					),
					"Somebody else edited it -- another agent, or the user typing in the "
						.. "editor. Read it again with script_read and rebuild the edit "
						.. "against what is there now."
				)
			end
		end

		local after = TextEdit.apply(target:GetFullName(), before, grouped[target] :: { TextEdit.Edit })
		table.insert(pending, { target = target, before = before, after = after })
	end

	-- Phase two: write. `written` is the compensation log for a mid-batch
	-- failure, and holds every script whose write reached the editor -- a write
	-- whose confirmation failed afterwards has still changed the script.
	local written: { Pending } = {}
	local memo: Paths.NameIndex = {}
	local results: { { [string]: any } } = {}

	for _, entry in pending do
		local committed = false
		-- Wrapped in a closure rather than passed to pcall directly: `write`
		-- returns nothing, and pcall's typed signature expects a value back.
		local ok, err = pcall(function()
			ScriptEdit.write(entry.target, function(current)
				if current ~= entry.before then
					Dispatch.fail(
						"STALE_SCRIPT",
						string.format("%s changed while this batch was being written.", entry.target:GetFullName()),
						"Somebody typed into it after it was read. Read it again with "
							.. "script_read and rebuild the edit against what is there now."
					)
				end
				committed = entry.after ~= entry.before
				return entry.after
			end)
		end)
		if committed then
			table.insert(written, entry)
		end

		if not ok then
			local kept: { string } = {}
			for index = #written, 1, -1 do
				local done = written[index]
				-- Nothing to undo when the editor never took the write -- and a
				-- write it refused (a locked script) would only be refused again.
				if ScriptEdit.read(done.target) == done.before then
					continue
				end
				local restored, restoreError = pcall(function()
					ScriptEdit.write(done.target, function(current)
						if current == done.after then
							return done.before
						end
						if current ~= done.before then
							Dispatch.fail("ROLLBACK_CONFLICT", "edited again since this batch wrote it; that text was kept")
						end
						return current
					end)
				end)
				if not restored then
					local reason = if typeof(restoreError) == "table" then restoreError.message else tostring(restoreError)
					table.insert(kept, string.format("%s (%s)", done.target:GetFullName(), tostring(reason)))
				end
			end
			--[[
				Said outright when the rollback could not finish.

				The batch promises all-or-nothing, and a restore that fails leaves
				part of it applied. Reporting only the original error would let the
				agent believe nothing changed and retry on top of a half-applied edit.
			]]
			if #kept > 0 then
				local reason = if typeof(err) == "table" then err.message else tostring(err)
				Dispatch.fail(
					"PARTIAL_EDIT",
					string.format("%s The batch could not be fully rolled back.", tostring(reason)),
					"Still edited, left as they are: " .. table.concat(kept, "; ")
						.. ". Read these scripts before retrying."
				)
			end
			error(err, 0)
		end

		table.insert(results, {
			path = Paths.of(entry.target, memo),
			className = entry.target.ClassName,
			edits = #(grouped[entry.target] :: { TextEdit.Edit }),
			lineCount = #TextEdit.toLines(entry.after),
			lineDelta = #TextEdit.toLines(entry.after) - #TextEdit.toLines(entry.before),
			-- Of what is there now, not of what was asked for: the editor can
			-- normalise the text it is handed, and a rev that does not match the
			-- live buffer would refuse the very next edit as stale.
			rev = ScriptEdit.revisionOf(entry.target),
		})
	end

	return { items = results }
end

function Scripts.edit(params: { [string]: any }): { [string]: any }
	return Undo.exclusive(function()
		return editBatch(params)
	end)
end

--[[
	Searches script source. Matches come from the editor buffer, so text the user
	has typed but not saved is found too -- which is the state an agent about to
	edit the file actually needs to see.

	`patterns` takes up to 16 literal needles searched in one pass. Looking for
	every caller of three functions used to be three calls, each reading every
	script's buffer again; the reads are the cost, not the matching.

	`mode` picks what comes back: matching lines (the default), one row per
	matching script, or only per-needle counts of matching lines -- the cheap
	way to ask "how widespread is this" before deciding to read anything.
]]
local GREP_MAX_NEEDLES = 16
-- Characters of rows handed back, estimated per row. The server clips to its
-- own response limit as well; this keeps a search over long minified lines from
-- building a reply far past it only for most of it to be thrown away.
local GREP_BUDGET = 18_000
local GREP_LONG_LINE = 256

function Scripts.grep(params: { [string]: any }): { [string]: any }
	local needles: { string } = {}
	local literal = params.literal == true
	local patterns = params.patterns
	if patterns ~= nil then
		if params.pattern ~= nil or typeof(patterns) ~= "table" or #patterns == 0 or #patterns > GREP_MAX_NEEDLES then
			Dispatch.fail(
				"BAD_PARAMS",
				string.format("Pass either `pattern` or 1-%d `patterns`, not both.", GREP_MAX_NEEDLES)
			)
		end
		-- Always literal: the point is identifiers, and mixing Lua patterns into a
		-- batch makes one bad escape fail every needle with it.
		literal = true
		for _, needle in patterns do
			if typeof(needle) ~= "string" or needle == "" then
				Dispatch.fail("BAD_PARAMS", "Every entry in `patterns` must be a non-empty string.")
			end
			table.insert(needles, needle)
		end
	elseif typeof(params.pattern) == "string" and params.pattern ~= "" then
		table.insert(needles, params.pattern)
	else
		Dispatch.fail("BAD_PARAMS", "script_grep requires a `pattern` or `patterns`.")
	end

	local mode = params.mode or "lines"
	if mode ~= "lines" and mode ~= "files" and mode ~= "counts" then
		Dispatch.fail("BAD_PARAMS", string.format("%q is not a grep mode.", tostring(mode)), "Use lines, files or counts.")
	end

	local root = if params.path then Paths.resolve(params.path) else game
	local ignoreCase = params.ignoreCase == true
	local contextLines = math.clamp(tonumber(params.contextLines) or DEFAULT_CONTEXT, 0, 10)
	local limit = math.clamp(tonumber(params.limit) or 100, 1, MAX_MATCHES)
	local offset = math.max(0, tonumber(params.offset) or 0)
	local classFilter = params.className

	if ignoreCase then
		for index, needle in needles do
			needles[index] = string.lower(needle)
		end
	end

	local targets: { LuaSourceContainer } = {}
	local function consider(instance: Instance)
		if not instance:IsA("LuaSourceContainer") then
			return
		end
		if root == game and Scope.isNoisy(instance) then
			return
		end
		if classFilter and not instance:IsA(classFilter) then
			return
		end
		table.insert(targets, instance :: LuaSourceContainer)
	end
	-- The root itself counts: `path` naming one script searches that script,
	-- where it used to search only its (usually absent) children.
	consider(root)
	for _, instance in root:GetDescendants() do
		consider(instance)
	end

	if #targets > MAX_SCRIPTS then
		Dispatch.fail(
			"TOO_BROAD",
			string.format("That search covers %d scripts, over the %d limit.", #targets, MAX_SCRIPTS),
			"Narrow it with `path` to search one service or folder instead of the whole place."
		)
	end

	--[[
		A fixed order, so `offset` means the same thing on every page.

		`GetDescendants` does not return one (see `stableOrder` in Discover): page
		two came from a different ordering than page one, repeating some matches
		and silently skipping others. By full name, with the debug id separating
		same-named scripts.
	]]
	local keys: { [Instance]: string } = {}
	for _, target in targets do
		local ok, id = pcall(function()
			return target:GetDebugId()
		end)
		keys[target] = target:GetFullName() .. "\0" .. (if ok then id else "")
	end
	table.sort(targets, function(a: Instance, b: Instance): boolean
		return keys[a] < keys[b]
	end)

	local function badPattern(needle: string, reason: any): never
		Dispatch.fail(
			"BAD_PATTERN",
			string.format("%s is not a valid Lua pattern: %s", needle, tostring(reason)),
			"Lua patterns escape with %, not backslash, and have no alternation. "
				.. "Set `literal` to search for the text exactly as written."
		)
	end

	-- Which needles occur on `text`, or nil. An invalid Lua pattern raises rather
	-- than simply not matching, so it is reported as a pattern problem.
	local function hits(text: string): { number }?
		local found: { number }? = nil
		for index, needle in needles do
			local ok, from = pcall(string.find, text, needle, 1, literal)
			if not ok then
				badPattern(needle, from)
			end
			if from then
				found = found or {}
				table.insert(found :: { number }, index)
			end
		end
		return found
	end

	--[[
		One search over the whole file before splitting it into lines.

		Most scripts in a place do not contain what is being looked for, and
		splitting each into a line table only to find nothing was most of the cost
		of a place-wide search. A pattern that matches no line cannot match the
		whole file either -- except one anchored with `^` or `$`, which mean line
		ends here but file ends there, so those skip this shortcut.
	]]
	-- Any trailing `$` counts, escaped or not: skipping the shortcut costs speed,
	-- taking it wrongly would hide matches.
	local anchored = false
	if not literal then
		for _, needle in needles do
			if string.sub(needle, 1, 1) == "^" or string.sub(needle, -1) == "$" then
				anchored = true
			end
		end
	end

	local matches: { { [string]: any } } = {}
	local counts: { number } = table.create(#needles, 0)
	local total = 0
	local matchedFiles = 0
	local budget = GREP_BUDGET
	local full = false
	local memo: Paths.NameIndex = {}

	-- Rows stop at `limit` or the budget, whichever comes first; `total` keeps
	-- counting either way, so the cursor the server builds from the rows actually
	-- shown picks up exactly where this reply stopped.
	local function emit(entry: { [string]: any }, cost: number): boolean
		if full or #matches >= limit then
			return false
		end
		if cost > budget and #matches > 0 then
			full = true
			return false
		end
		budget -= cost
		table.insert(matches, entry)
		return true
	end

	for _, target in targets do
		local source = ScriptEdit.read(target)
		local searchable = if ignoreCase then string.lower(source) else source
		if not anchored and hits(searchable) == nil then
			continue
		end

		local lines = TextEdit.toLines(source)
		local path: string? = nil
		local revision: string? = nil
		local fileMatches = 0

		for number, line in lines do
			local found = hits(if ignoreCase then string.lower(line) else line)
			if found == nil then
				continue
			end
			fileMatches += 1
			for _, index in found do
				counts[index] += 1
			end
			if mode ~= "lines" then
				continue
			end

			total += 1
			if total <= offset or full or #matches >= limit then
				continue
			end

			path = path or Paths.of(target, memo)
			revision = revision or ScriptEdit.revisionOf(target, source)
			local entry: { [string]: any } = {
				path = path,
				revision = revision,
				line = number,
				text = line,
				-- Only when there is more than one needle to tell apart.
				needles = if #needles > 1 then found else nil,
			}
			local cost = #line + 80
			if contextLines > 0 then
				local before: { string } = {}
				local after: { string } = {}
				table.move(lines, math.max(number - contextLines, 1), number - 1, 1, before)
				table.move(lines, number + 1, math.min(number + contextLines, #lines), 1, after)
				entry.before = before
				entry.after = after
				for _, text in before do
					cost += #text + 4
				end
				for _, text in after do
					cost += #text + 4
				end
			end
			-- A single line longer than the whole budget -- minified or generated
			-- code -- is cut rather than never shown, which would stall the cursor.
			if cost > budget and #matches == 0 then
				entry.before, entry.after = nil, nil
				entry.text = string.sub(line, 1, GREP_LONG_LINE)
				entry.truncated = true
				cost = GREP_LONG_LINE + 80
			end
			emit(entry, cost)
		end

		if fileMatches > 0 then
			matchedFiles += 1
			if mode == "files" then
				total += 1
				if total > offset then
					path = path or Paths.of(target, memo)
					emit({
						path = path,
						className = target.ClassName,
						revision = ScriptEdit.revisionOf(target, source),
						matches = fileMatches,
					}, #(path :: string) + 60)
				end
			end
		end
	end

	return {
		items = matches,
		total = total,
		offset = offset,
		searched = #targets,
		counts = if mode == "counts" then counts else nil,
		matchedFiles = if mode == "counts" then matchedFiles else nil,
	}
end

--[[
	Names the starter container a script was just parented into, or nil.

	These four are copied into the player rather than run where they sit, so a
	`Script` with a non-Legacy RunContext inside one runs BOTH in the original
	and in every copy. Roblox does warn about it -- "will cause it to run
	multiple times" -- but that warning is emitted by Studio itself and never
	reaches `console`, so an agent following the "prefer Script with runContext
	Client over LocalScript" advice writes a double-running script and is given
	no way to find out.
]]
--[[
	Assigning `Source` fails at 200,000 characters or more ("Provided string
	length ... is greater than or equal to max length (200000)"), while
	`UpdateSourceAsync` takes far more -- measured writing 279,000. Sources at
	the limit are written through the editor instead of refused.
]]
local SOURCE_PROPERTY_LIMIT = 200000

local STARTER_CONTAINERS = {
	"StarterGui",
	"StarterPack",
	"StarterPlayerScripts",
	"StarterCharacterScripts",
}

local function starterContainer(instance: Instance): string?
	for _, className in STARTER_CONTAINERS do
		if instance:FindFirstAncestorOfClass(className :: any) then
			return className
		end
	end
	return nil
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
			Dispatch.fail("BAD_PARAMS", string.format("scripts[%d] has no `name`.", position - 1))
		end
		if not CREATABLE[request.className] then
			Dispatch.fail(
				"BAD_PARAMS",
				string.format('scripts[%d] has className "%s".', position - 1, tostring(request.className)),
				"Use Script, LocalScript or ModuleScript. Prefer a Script with "
					.. "runContext Client over LocalScript in new work -- except inside "
					.. "StarterGui, StarterPack, StarterPlayerScripts or "
					.. "StarterCharacterScripts, where LocalScript is still the right "
					.. "class."
			)
		end
	end

	-- No shared path memo here: each creation changes its parent's children, so a
	-- cached sibling grouping would go stale mid-batch and mis-number the paths.
	local warnings: { string } = {}
	local oversized: { { target: LuaSourceContainer, source: string } } = {}

	local created, recorded = Undo.record("StudioMCP.ScriptCreate", "MCP create script", function()
		local created: { { [string]: any } } = {}

		for _, request in requests do
			local parent = Paths.resolve(request.parent)
			local instance = Instance.new(request.className) :: LuaSourceContainer

			instance.Name = request.name
			if typeof(request.source) == "string" then
				if #request.source < SOURCE_PROPERTY_LIMIT then
					(instance :: ScriptEdit.SourceContainer).Source = request.source
				else
					table.insert(oversized, { target = instance, source = request.source })
				end
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

			if instance:IsA("Script") and instance.RunContext ~= Enum.RunContext.Legacy then
				local container = starterContainer(instance)
				if container then
					--[[
						A Tool is the exception, and a common enough one to be
						worth separating.

						The general warning ends "make it a LocalScript", which
						is right for a bare script in StarterGui or StarterPack
						and WRONG for the inside of a weapon: damage, ammo and
						hit detection belong on the server, and a LocalScript
						there hands all three to the client. The duplicate the
						warning is about is harmless here too -- the copy left in
						StarterPack is never held by anyone, so nothing it
						listens for ever fires.
					]]
					local insideTool = false
					local walk: Instance? = instance.Parent
					while walk ~= nil and walk ~= game do
						if walk:IsA("Tool") then
							insideTool = true
							break
						end
						walk = walk.Parent
					end

					if insideTool then
						table.insert(
							warnings,
							string.format(
								"%s is a Script with RunContext %s inside a Tool in %s. That is "
									.. "usually right -- the Tool is copied into each player's "
									.. "Backpack and the script runs there, on the server, which "
									.. "is where damage and ammo belong. The copy left behind in "
									.. "%s also runs, but nobody holds it, so nothing it waits for "
									.. "happens. Keep it a Script, not a LocalScript.",
								instance.Name,
								instance.RunContext.Name,
								container,
								container
							)
						)
					else
						table.insert(
							warnings,
							string.format(
								'%s is a Script with RunContext %s inside %s. That container is '
									.. "COPIED into each player, so the script runs once where it "
									.. "sits and again in every copy. Make it a LocalScript "
									.. "instead -- a Legacy Script there would not run at all. "
									.. "Studio warns about this in its own Output, which `console` "
									.. "cannot read.",
								instance.Name,
								instance.RunContext.Name,
								container
							)
						)
					end
				end
			end

			table.insert(created, {
				path = Paths.of(instance),
				className = instance.ClassName,
			})
		end

		return created
	end)

	-- After the recording, because the editor write yields. Undoing the create
	-- still removes these scripts whole, source and all.
	--
	-- The scripts already exist at this point, so a failed write is reported as
	-- what it is -- created, but without their source -- instead of as a failed
	-- create an agent would retry into duplicates. And the write only fills a
	-- script that is still empty: anything else is somebody else's text.
	for _, entry in oversized do
		local ok, err = pcall(function()
			Undo.exclusive(function()
				ScriptEdit.write(entry.target, function(current)
					if current ~= "" then
						Dispatch.fail("STALE_SCRIPT", "edited before its source could be written; that text was kept")
					end
					return entry.source
				end)
			end)
		end)
		if not ok then
			local reason = if typeof(err) == "table" then err.message else tostring(err)
			Dispatch.fail(
				"PARTIAL_CREATE",
				string.format("%s was created, but its source was not written: %s", Paths.of(entry.target), tostring(reason)),
				"The script exists. Read it and write the source with script_edit rather than creating it again."
			)
		end
	end

	return {
		items = created,
		undoStep = if recorded then "MCP create script" else nil,
		warnings = if #warnings > 0 then warnings else nil,
	}
end

--[[
	Opens a script in the user's editor, at a line.

	The gap this closes is a conversational one. An agent that has found the bug
	says "it is line 214 of Combat" and the user then has to go and find Combat,
	open it, and scroll -- every time, for every finding. `ScriptEditorService`
	can just put it on their screen.

	Deliberately not automatic. Nothing else in this server opens windows, and a
	tool that rearranged the user's editor as a side effect of reading a file
	would be intolerable on a batch of twenty. It happens when it is asked for.
]]
function Scripts.open(params: { [string]: any }): { [string]: any }
	local target = resolveScript(params.path)
	local line = math.max(tonumber(params.line) or 1, 1)

	local service = game:GetService("ScriptEditorService")
	local ok, err = pcall(function()
		(service :: any):OpenScriptDocumentAsync(target)
	end)
	if not ok then
		Dispatch.fail(
			"OPEN_FAILED",
			string.format("Could not open %s: %s", target:GetFullName(), tostring(err))
		)
	end

	--[[
		Moving the cursor is a second, separate operation, and a failure to move
		it is not a failure to open. A document that opened but did not scroll is
		still in front of the user; raising here would report the whole thing as
		broken over the smaller half.
	]]
	local movedTo: number? = nil
	pcall(function()
		for _, document in (service :: any):GetScriptDocuments() do
			if document:GetScript() == target then
				document:RequestSetSelectionAsync(line, 1, line, 1)
				movedTo = line
				break
			end
		end
	end)

	return {
		path = Paths.of(target),
		className = target.ClassName,
		opened = true,
		line = movedTo,
	}
end

function Scripts.register()
	Dispatch.registerAll("script", {
		open = Scripts.open,
		read = Scripts.read,
		edit = Scripts.edit,
		grep = Scripts.grep,
		create = Scripts.create,
	})
end

return Scripts
