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
	Replaces source through the editor. `transform` receives the current text and
	returns the replacement; returning the input unchanged is a no-op.

	Raises SCRIPT_LOCKED when the write is refused, which normally means the
	script is a package member or is owned by another Team Create session.
]]
function ScriptEdit.write(target: LuaSourceContainer, transform: (string) -> string)
	local ok, err = pcall(function()
		ScriptEditorService:UpdateSourceAsync(target, transform)
	end)
	if ok then
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
	Applies a line-range replacement. Lines are 1-based and inclusive, matching
	what `script_read` returns, so an agent can read lines 40-60 and write back
	to exactly those numbers without an off-by-one conversion.
]]
function ScriptEdit.replaceLines(
	target: LuaSourceContainer,
	startLine: number,
	endLine: number,
	replacement: string
)
	ScriptEdit.write(target, function(source)
		local lines = ScriptEdit.toLines(source)
		if startLine < 1 or startLine > #lines + 1 then
			Dispatch.fail(
				"BAD_RANGE",
				string.format(
					"startLine %d is outside %s, which has %d lines.",
					startLine,
					target:GetFullName(),
					#lines
				),
				"Call script_read on this script first to get current line numbers; "
					.. "they shift after every edit."
			)
		end

		local result: { string } = {}
		table.move(lines, 1, startLine - 1, 1, result)
		for _, line in ScriptEdit.toLines(replacement) do
			table.insert(result, line)
		end
		if endLine < #lines then
			table.move(lines, endLine + 1, #lines, #result + 1, result)
		end
		return table.concat(result, "\n")
	end)
end

function ScriptEdit.toLines(source: string): { string }
	local lines: { string } = {}
	for line in string.gmatch(source .. "\n", "([^\n]*)\n") do
		table.insert(lines, line)
	end
	-- gmatch on the sentinel newline yields one trailing empty entry.
	if #lines > 0 and lines[#lines] == "" then
		table.remove(lines)
	end
	return lines
end

--[[
	True for instances that hold Luau source. Used to keep script tools from
	being pointed at ordinary instances with a confusing property error.
]]
function ScriptEdit.isScript(instance: Instance): boolean
	return instance:IsA("LuaSourceContainer")
end

return ScriptEdit
