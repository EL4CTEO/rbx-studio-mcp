--!strict
--[[
	Script reading, searching, editing and creation.

	Everything here that writes goes through `ScriptEdit`, which routes the change
	through `ScriptEditorService:UpdateSourceAsync` rather than assigning
	`script.Source`. That is the difference between an edit the Studio editor
	agrees with and one that silently loses whatever the user had typed but not
	saved. Reads use the editor buffer for the same reason: handing an agent stale
	source makes it "fix" changes the user just made.

	Edits share the mutation lock and use per-document editor history. Failed
	batches compensate only unchanged writes, reporting unresolved conflicts.

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
	A short fingerprint of a script's source, for detecting that it moved.

	Handed out by `read` and passed back to `edit`, which refuses to write when
	the live source no longer matches. That is the only thing standing between
	two agents on one place and a silent overwrite: a line-range edit computed
	against source somebody has since changed still applies cleanly, it just
	applies to the wrong lines, and nothing anywhere reports it.

	FNV-1a over the whole string, with the length appended. Not a security
	hash and does not need to be -- it is guarding against ordinary concurrent
	editing, not against someone constructing a collision. The length is there
	because it is free and rules out the whole class of same-length accidents.

	The multiply is split into 16-bit halves on purpose. `hash * 16777619` with
	a 32-bit hash reaches 2^56, past the 2^53 where doubles stop being exact,
	so the low bits -- the ones that carry the mixing -- would be quietly
	rounded away.
]]
local function fingerprint(source: string): string
	local hash = 2166136261
	local length = #source
	local index = 1
	while index <= length do
		local last = math.min(index + 511, length)
		local chunk = { string.byte(source, index, last) }
		for _, byte in chunk do
			hash = bit32.bxor(hash, byte)
			local low = bit32.band(hash, 0xFFFF)
			local high = bit32.rshift(hash, 16)
			-- 16777619 == 0x01000193, so 0x0193 is 403 and 0x0100 is 256.
			hash = bit32.band(low * 403 + bit32.lshift(bit32.band(high * 403 + low * 256, 0xFFFF), 16), 0xFFFFFFFF)
		end
		index = last + 1
	end
	return string.format("%08x-%x", hash, length)
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
			revision = fingerprint(whole),
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
]]
local function editUnlocked(params: { [string]: any }): { [string]: any }
	local deadline = Dispatch.deadline()
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
	type Pending = { target: LuaSourceContainer, before: string, after: string, produced: boolean? }
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
			live = live or fingerprint(before)
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

	-- Phase two: write. `written` is the compensation log for a mid-batch failure.
	local written: { Pending } = {}
	local memo: Paths.NameIndex = {}
	local results: { { [string]: any } } = {}

	for _, entry in pending do
		table.insert(written, entry)
		-- Wrapped in a closure rather than passed to pcall directly: `write`
		-- returns nothing, and pcall's typed signature expects a value back.
		local ok, err = pcall(function()
			Dispatch.checkDeadline()
			ScriptEdit.write(entry.target, function(current)
				Dispatch.checkDeadline(deadline)
				if current ~= entry.before then
					Dispatch.fail("STALE_SCRIPT", entry.target:GetFullName() .. " changed before the write committed.",
						"Read it again and rebuild the edit against the current source.")
				end
				entry.produced = entry.after ~= entry.before
				return entry.after
			end)
		end)

		if not ok then
			local remaining: { string } = {}
			for index = #written, 1, -1 do
				local done = written[index]
				if not done.produced then continue end
				local restored, restoreError = pcall(function()
					ScriptEdit.write(done.target, function(current)
						if current == done.before then return current end
						if current ~= done.after then
							Dispatch.fail("ROLLBACK_CONFLICT", "Newer text was preserved.")
						end
						return done.before
					end)
				end)
				if not restored then
					local reason = if typeof(restoreError) == "table" then restoreError.message else tostring(restoreError)
					table.insert(remaining, done.target:GetFullName() .. ": " .. tostring(reason))
				end
			end
			if #remaining > 0 then
				local reason = if typeof(err) == "table" then err.message else tostring(err)
				Dispatch.fail("PARTIAL_EDIT", tostring(reason), "Not restored (read these before retrying): " .. table.concat(remaining, "; "))
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
			rev = fingerprint(ScriptEdit.read(entry.target)),
		})
	end

	return { items = results }
end

function Scripts.edit(params: { [string]: any }): { [string]: any }
	return Undo.exclusive(function() return editUnlocked(params) end)
end

--[[
	Searches script source. Matches come from the editor buffer, so text the user
	has typed but not saved is found too -- which is the state an agent about to
	edit the file actually needs to see.
]]
function Scripts.grep(params: { [string]: any }): { [string]: any }
 local needles: { string } = {}
 local literal = params.literal == true
 if params.patterns ~= nil then
  if params.pattern ~= nil or typeof(params.patterns) ~= "table" or #params.patterns == 0 or #params.patterns > 16 then
   Dispatch.fail("BAD_PARAMS", "Supply pattern or 1-16 literal patterns, not both.")
  end
  literal = true
  for _, needle in params.patterns do
   if typeof(needle) ~= "string" or needle == "" then Dispatch.fail("BAD_PARAMS", "Patterns must be non-empty strings.") end
   table.insert(needles, needle)
  end
 elseif typeof(params.pattern) == "string" and params.pattern ~= "" then
  table.insert(needles, params.pattern)
 else Dispatch.fail("BAD_PARAMS", "Supply pattern or patterns.") end
 local mode = params.mode or "lines"
 if mode ~= "lines" and mode ~= "files" and mode ~= "counts" then Dispatch.fail("BAD_PARAMS", "mode must be lines, files or counts.") end
 local ignoreCase = params.ignoreCase == true
 if ignoreCase then for i, needle in needles do needles[i] = string.lower(needle) end end
 local root = if params.path then Paths.resolve(params.path) else game
 local contextLines = math.clamp(tonumber(params.contextLines) or DEFAULT_CONTEXT, 0, 10)
 local limit = math.clamp(tonumber(params.limit) or 100, 1, MAX_MATCHES)
 local offset = math.max(0, tonumber(params.offset) or 0)
 local memo: Paths.NameIndex = {}
 local targets: { { target: LuaSourceContainer, path: string } } = {}
 local function consider(instance: Instance)
  if instance:IsA("LuaSourceContainer") and not (root == game and Scope.isNoisy(instance)) and
   (not params.className or instance:IsA(params.className)) then
   table.insert(targets, {target = instance, path = Paths.of(instance, memo)})
  end
 end
 consider(root)
 for _, instance in root:GetDescendants() do consider(instance) end
 if #targets > MAX_SCRIPTS then Dispatch.fail("TOO_BROAD", "Too many scripts; narrow path.") end
 table.sort(targets, function(a, b) return a.path < b.path end)
 local counts: { number } = table.create(#needles, 0)
 local matchedFiles, total = 0, 0
 local matches: { { [string]: any } } = {}
 local budget, exhausted = 18000, false
 local HttpService = game:GetService("HttpService")
 local function emit(entry: { [string]: any })
  if exhausted then return end
  local cost = #HttpService:JSONEncode(entry) + 1
  if cost > budget then
   if #matches > 0 then exhausted = true; return end
   entry.before, entry.after = nil, nil
   if entry.text then entry.text = string.sub(entry.text, 1, 256); entry.truncated = true end
   cost = #HttpService:JSONEncode(entry) + 1
   if cost > budget then Dispatch.fail("RESULT_TOO_LARGE", "A search row exceeds the response budget.", "Narrow the search path.") end
  end
  budget -= cost
  table.insert(matches, entry)
 end
 for _, candidate in targets do
  local source = ScriptEdit.read(candidate.target)
  local searchable = if ignoreCase then string.lower(source) else source
  local possible = false
  for _, needle in needles do
   if not literal and (string.sub(needle, 1, 1) == "^" or string.sub(needle, -1) == "$") then possible = true; break end
   local ok, found = pcall(string.find, searchable, needle, 1, literal)
   if not ok then Dispatch.fail("BAD_PATTERN", tostring(found), "Lua patterns escape with %. Use literal=true for identifiers.") end
   if found then possible = true; break end
  end
  if not possible then continue end
  local lines = TextEdit.toLines(source)
  local fileMatches = 0
  local rev: string? = nil
  for number, line in lines do
   local haystack = if ignoreCase then string.lower(line) else line
   local foundNeedles: { number } = {}
   for index, needle in needles do
    local ok, found = pcall(string.find, haystack, needle, 1, literal)
    if not ok then Dispatch.fail("BAD_PATTERN", tostring(found)) end
    if found then counts[index] += 1; table.insert(foundNeedles, index) end
   end
   if #foundNeedles == 0 then continue end
   fileMatches += 1
   if mode ~= "lines" then continue end
   total += 1
   if total <= offset or #matches >= limit or exhausted then continue end
   rev = rev or fingerprint(source)
   local entry: { [string]: any } = {path = candidate.path, className = candidate.target.ClassName, revision = rev,
    line = number, text = line, needles = if #needles > 1 then foundNeedles else nil}
   if contextLines > 0 then
    entry.before = table.move(lines, math.max(number - contextLines, 1), number - 1, 1, {})
    entry.after = table.move(lines, number + 1, math.min(number + contextLines, #lines), 1, {})
   end
   emit(entry)
  end
  if fileMatches > 0 then
   matchedFiles += 1
   if mode == "files" then
    total += 1
    if total > offset and #matches < limit then
     emit({path = candidate.path, className = candidate.target.ClassName, revision = fingerprint(source), matches = fileMatches})
    end
   end
  end
 end
 return {items = matches, total = total, offset = offset, searched = #targets,
  counts = if mode == "counts" then counts else nil, matchedFiles = if mode == "counts" then matchedFiles else nil}
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
	local deadline = Dispatch.deadline()
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
	for _, entry in oversized do
		local ok, err = pcall(function()
			Undo.exclusive(function()
				ScriptEdit.write(entry.target, function(current)
					Dispatch.checkDeadline(deadline)
					if current ~= "" then Dispatch.fail("STALE_SCRIPT", "The newly created script was edited before its initial source could be written.") end
					return entry.source
				end)
			end)
		end)
		if not ok then
			local reason = if typeof(err) == "table" then err.message else tostring(err)
			Dispatch.fail("PARTIAL_CREATE", tostring(reason), "The script instances were created; read their sources before retrying. Failed source: " .. Paths.of(entry.target))
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
