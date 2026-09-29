--!strict
--[[
	Editor-safe script reading and writing.

	Every other Roblox Studio MCP server assigns `script.Source` directly. That is
	wrong in a specific, silent way: when the script is open in the Studio script
	editor, the editor holds its own buffer, and a direct Source write either gets
	overwritten by that buffer or discards the user's unsaved edits. Roblox added
	`ScriptEditorService:UpdateSourceAsync` precisely to close this gap -- it
	routes the change through the editor so the open document, its undo stack and
	the saved source all stay in agreement.

	The cost is that it yields, so every write here is async. That is the whole
	reason handlers are allowed to yield.
]]

local ScriptEditorService = game:GetService("ScriptEditorService")

local Dispatch = require(script.Parent.Dispatch)

local ScriptEdit = {}

export type SourceContainer = LuaSourceContainer & { Source: string }

--[[
	Reads current source. `GetEditorSource` is preferred over `.Source` because it
	returns the editor's live buffer, including edits the user has typed but not
	saved -- reading `.Source` there would hand the agent stale code and it would
	then "fix" changes the user just made.
]]
function ScriptEdit.read(target: LuaSourceContainer): string
	local ok, source = pcall(function()
		return ScriptEditorService:GetEditorSource(target)
	end)
	if ok and typeof(source) == "string" then
		return source
	end
	return (target :: SourceContainer).Source
end

--[[
	A short fingerprint of a script's source, for detecting that it moved.

	Handed out by `script_read` and passed back to `script_edit`, and kept by
	`sync` to tell which side of a synced script changed. `edit`, which refuses to write when
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
function ScriptEdit.fingerprint(source: string): string
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
	A script's revision, computed once per distinct text.

	Fingerprinting walks every byte in Luau, and `sync` asks for the revision of
	every script in a place on each run -- so a place with megabytes of code paid
	for hashing all of it after every save, to learn that one file changed. The
	text is kept beside its revision per script, and a lookup whose text is the
	same string skips the hash: Luau interns strings, so that comparison is a
	pointer check, not a second pass over the source.

	Weak keys, so a deleted script's entry goes with it.
]]
local revisions: { [Instance]: { source: string, revision: string } } = setmetatable({}, { __mode = "k" }) :: any

function ScriptEdit.revisionOf(target: LuaSourceContainer, source: string?): string
	local text = source or ScriptEdit.read(target)
	local cached = revisions[target]
	if cached ~= nil and cached.source == text then
		return cached.revision
	end
	local revision = ScriptEdit.fingerprint(text)
	revisions[target] = { source = text, revision = revision }
	return revision
end

--[[
	Makes sure a write that reported success actually stuck.

	`UpdateSourceAsync` returns true and the editor buffer shows the new text --
	and then, a third of a second later, the freshly opened document finishes
	loading and overwrites the buffer with the source from disk. The write is
	gone, nothing raised, and the tool reports the edit applied. Measured:

		updateOk    = true
		immediately = "M.rate = 99"   <- the write landed
		after 0.5s  = "M.rate = 60"   <- and was thrown away

	Reading back straight after the write therefore proves nothing; the first
	version of this check did exactly that, saw a match, and returned happy
	while the edit was still about to be discarded. The read has to happen after
	the load could have finished.

	Nothing here opens editor tabs any more, so the loading document that
	caused this is only reachable when the USER opens one in the same moment we
	write to it -- rare, and cheap enough to cover anyway. One settle, one read,
	and a rewrite if it did not take.

	A rewrite only ever replaces `original`, the text our write replaced. That
	is what a finishing load puts back. Anything else in the buffer is somebody
	typing after the write landed, and rewriting it "to make ours stick" would
	delete their work -- so that is reported instead, and their text is kept.
]]
local SETTLE = 0.2

local function confirm(target: LuaSourceContainer, produced: string?, original: string?)
	if produced == nil or produced == original then
		return
	end

	--[[
		No document, no race. The overwrite comes from an editor tab that was
		loading while we wrote; a tab opened afterwards loads the new source. So
		a script nobody has open is confirmed by one read, instead of paying the
		settle -- which cost every written script 200ms, one after another, on
		every script_edit and script_create.
	]]
	local found, document = pcall(function()
		return ScriptEditorService:FindScriptDocument(target)
	end)
	if found and document == nil and ScriptEdit.read(target) == produced then
		return
	end

	-- Three rounds: the race is with one load, so a single rewrite settles it,
	-- and a script that discards three identical writes is failing for a reason
	-- repeating will not fix.
	for _ = 1, 3 do
		task.wait(SETTLE)
		local current = ScriptEdit.read(target)
		if current == produced then
			return
		end
		if current ~= original then
			break
		end
		pcall(function()
			ScriptEditorService:UpdateSourceAsync(target, function(source)
				-- Checked again at commit time: the user may have typed since the read.
				return if source == original then produced :: string else source
			end)
		end)
	end

	if ScriptEdit.read(target) ~= produced then
		Dispatch.fail(
			"VERIFY_FAILED",
			string.format("%s changed while the write was being confirmed.", target:GetFullName()),
			"The newer text was kept, not overwritten. Read the script again before retrying."
		)
	end
end

--[[
	Replaces source through the editor. `transform` receives the current text --
	read at commit time, so it is where a "has this changed since I read it"
	check belongs -- and returns the replacement; returning the input unchanged
	is a no-op.

	`transform` is allowed to raise a structured Dispatch failure -- a bad line
	range is only discoverable once the authoritative source is in hand. Such a
	failure is stashed rather than thrown from inside the callback: throwing
	there would surface as an opaque engine error and lose the code and hint the
	agent needs. The callback instead returns the text untouched, making that one
	script a no-op, and the original failure is re-raised afterwards.

	Raises SCRIPT_LOCKED when the write is refused, which normally means the
	script is a package member or is owned by another Team Create session.
]]
function ScriptEdit.write(target: LuaSourceContainer, transform: (string) -> string)
	local pending: any = nil

	local produced: string? = nil
	local original: string? = nil
	local ok, err = pcall(function()
		ScriptEditorService:UpdateSourceAsync(target, function(source)
			local applied, result = pcall(transform, source)
			if applied then
				original = source
				produced = result
				return result
			end
			pending = result
			return source
		end)
	end)

	if pending ~= nil then
		error(pending, 0)
	end
	if ok then
		confirm(target, produced, original)
		return
	end

	local message = tostring(err)
	if string.find(string.lower(message), "lock") or string.find(string.lower(message), "permission") then
		Dispatch.fail(
			"SCRIPT_LOCKED",
			string.format("Studio refused to edit %s: %s", target:GetFullName(), message),
			"The script is usually locked because it belongs to a package or is "
				.. "checked out by another Team Create user. Ask the user to unlock it, "
				.. "or edit a different script."
		)
	end
	Dispatch.fail(
		"EDIT_FAILED",
		string.format("Could not edit %s: %s", target:GetFullName(), message)
	)
end

--[[
	True for instances that hold Luau source. Used to keep script tools from
	being pointed at ordinary instances with a confusing property error.
]]
function ScriptEdit.isScript(instance: Instance): boolean
	return instance:IsA("LuaSourceContainer")
end

return ScriptEdit
