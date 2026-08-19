--!strict
--[[
	What the user is currently looking at in the script editor.

	`ScriptEditorService` is normally used only to read and write source. The
	document layer underneath it -- open tabs, cursor position, selected text,
	which lines are on screen -- is left untouched by every other Studio MCP
	server, and it answers the question an agent most often has to guess at: when
	the user says "fix this function", which one do they mean.

	Everything here is read-only and defensive. A ScriptDocument can close between
	being listed and being read, and the accessors throw rather than return nil
	when that happens, so each one is wrapped.
]]

local ScriptEditorService = game:GetService("ScriptEditorService")

local Paths = require(script.Parent.Paths)

-- Selected text is included so the agent can act on it without a second call,
-- but a user can select an entire file. Past this it is summarised instead.
local MAX_SELECTED_TEXT = 400

local Editor = {}

export type Document = { [string]: any }

--[[
	Reads an accessor, yielding nil rather than raising when the document closed
	underneath us. Values come back boxed in a table so a multi-value accessor
	survives the pcall boundary intact.
]]
local function safe(accessor: () -> any): any
	local ok, value = pcall(accessor)
	if ok then
		return value
	end
	return nil
end

local function describe(document: ScriptDocument): Document?
	-- The command bar is a ScriptDocument too, but it has no backing script and
	-- is not something an agent should offer to edit.
	local okCommandBar, isCommandBar = pcall(function()
		return document:IsCommandBar()
	end)
	if not okCommandBar then
		return nil
	end

	local entry: Document = { commandBar = isCommandBar == true }

	if isCommandBar then
		entry.path = "(command bar)"
	else
		local found = safe(function()
			return document:GetScript()
		end)
		if typeof(found) ~= "Instance" then
			return nil
		end
		local target = found :: Instance
		entry.path = Paths.of(target)
		entry.className = target.ClassName
	end

	entry.lineCount = safe(function()
		return document:GetLineCount()
	end)

	-- GetSelection returns cursor line/character followed by the anchor: the
	-- cursor is where the caret is, the anchor where the selection started, and
	-- they are equal when nothing is selected.
	local raw = safe(function()
		local line, character, anchorLine, anchorCharacter = document:GetSelection()
		return { line, character, anchorLine, anchorCharacter }
	end)
	if typeof(raw) == "table" then
		local selection = raw :: { number }
		entry.cursorLine = selection[1]
		entry.cursorColumn = selection[2]

		local hasSelection = selection[1] ~= selection[3] or selection[2] ~= selection[4]
		if hasSelection then
			-- Normalised, because a selection dragged upwards reports its anchor
			-- below its cursor and a raw start/end pair would read as inverted.
			local startLine = math.min(selection[1], selection[3])
			local endLine = math.max(selection[1], selection[3])
			entry.selectedLines = if startLine == endLine
				then tostring(startLine)
				else string.format("%d-%d", startLine, endLine)

			local selected = safe(function()
				return document:GetSelectedText()
			end)
			if typeof(selected) == "string" then
				entry.selectedText = if #selected > MAX_SELECTED_TEXT
					then string.sub(selected, 1, MAX_SELECTED_TEXT) .. "..."
					else selected
			end
		end
	end

	local viewport = safe(function()
		local first, last = document:GetViewport()
		return { first, last }
	end)
	if typeof(viewport) == "table" then
		local bounds = viewport :: { number }
		if bounds[1] and bounds[2] then
			entry.visibleLines = string.format("%d-%d", bounds[1], bounds[2])
		end
	end

	return entry
end

--[[
	Every script the user has open, most recently interesting first. Studio gives
	no "focused document" API, so the caller is told what is open rather than
	which tab has focus -- claiming focus we cannot observe would be worse than
	saying nothing.
]]
function Editor.documents(): { Document }
	local ok, documents = pcall(function()
		return ScriptEditorService:GetScriptDocuments()
	end)
	if not ok or typeof(documents) ~= "table" then
		return {}
	end

	local entries: { Document } = {}
	for _, document in documents :: { Instance } do
		if document:IsA("ScriptDocument") then
			local entry = describe(document)
			if entry then
				table.insert(entries, entry)
			end
		end
	end
	return entries
end

return Editor
