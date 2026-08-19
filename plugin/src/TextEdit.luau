--!strict
--[[
	The edit engine: pure text in, pure text out.

	Kept free of Roblox APIs on purpose. Getting a line splice or a find/replace
	subtly wrong is the one bug class here that produces no error at all -- it
	just writes the wrong code into the user's game -- so this logic is unit
	tested outside Studio (see tests/textedit.luau). Everything that actually
	touches the DataModel lives in handlers/Scripts.luau.
]]

local Dispatch = require(script.Parent.Dispatch)

local TextEdit = {}

export type Edit = {
	path: string,
	find: string?,
	replace: string?,
	replaceAll: boolean?,
	startLine: number?,
	endLine: number?,
	replacement: string?,
	source: string?,
}

type LineEdit = {
	startLine: number,
	endLine: number,
	replacement: string,
}

--[[
	Splits source into lines. A trailing newline does not produce a final empty
	line, so a round trip through `toLines`/`concat` leaves the text unchanged.
]]
function TextEdit.toLines(source: string): { string }
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
	Literal (non-pattern) find and replace.

	`string.gsub` would be shorter but treats `%` as an escape in both the needle
	and the replacement, so a single `%d` in the user's code silently changes
	meaning. Agent-supplied text has to be taken exactly as given.
]]
function TextEdit.replaceLiteral(text: string, needle: string, replacement: string, all: boolean): string
	local out: { string } = {}
	local index = 1

	while true do
		local from, to = string.find(text, needle, index, true)
		if not from or not to then
			break
		end
		table.insert(out, string.sub(text, index, from - 1))
		table.insert(out, replacement)
		index = to + 1
		if not all then
			break
		end
	end

	table.insert(out, string.sub(text, index))
	return table.concat(out)
end

function TextEdit.countLiteral(text: string, needle: string): number
	local index = 1
	local count = 0
	while true do
		local from, to = string.find(text, needle, index, true)
		if not from or not to then
			return count
		end
		count += 1
		index = to + 1
	end
end

--[[
	Rejects a malformed edit before anything is written.

	Validation is a separate pass on purpose: a batch that turns out to be
	nonsense should fail with nothing touched and no undo entry, rather than
	applying three scripts' worth of changes and then rolling them back.
]]
function TextEdit.validate(edit: Edit, position: number)
	if typeof(edit.path) ~= "string" or edit.path == "" then
		Dispatch.fail(
			"BAD_PARAMS",
			string.format("edits[%d] has no `path`.", position),
			'Every edit needs the path of the script to change, e.g. "ServerScriptService.Main".'
		)
	end

	local modes = 0
	if edit.source ~= nil then
		modes += 1
	end
	if edit.startLine ~= nil then
		modes += 1
	end
	if edit.find ~= nil then
		modes += 1
	end

	if modes == 0 then
		Dispatch.fail(
			"BAD_PARAMS",
			string.format("edits[%d] (%s) says what to edit but not how.", position, edit.path),
			"Give exactly one of: `find` + `replace`, `startLine` (+ `endLine`) + "
				.. "`replacement`, or `source` to replace the whole script."
		)
	end
	if modes > 1 then
		Dispatch.fail(
			"BAD_PARAMS",
			string.format("edits[%d] (%s) combines more than one edit mode.", position, edit.path),
			"Use `find`, `startLine` or `source` -- one per edit. Send several entries "
				.. "in the array if you need several changes."
		)
	end

	if edit.find ~= nil then
		if edit.find == "" then
			Dispatch.fail(
				"BAD_PARAMS",
				string.format("edits[%d] (%s) has an empty `find`.", position, edit.path)
			)
		end
		if typeof(edit.replace) ~= "string" then
			Dispatch.fail(
				"BAD_PARAMS",
				string.format("edits[%d] (%s) has `find` but no `replace`.", position, edit.path),
				"Pass an empty `replace` to delete the matched text."
			)
		end
	elseif edit.startLine ~= nil then
		if typeof(edit.replacement) ~= "string" then
			Dispatch.fail(
				"BAD_PARAMS",
				string.format("edits[%d] (%s) has `startLine` but no `replacement`.", position, edit.path),
				"Pass an empty `replacement` to delete those lines."
			)
		end
	end
end

--[[
	Applies every edit destined for one script to its source text. `path` is used
	only for error messages.

	Order is fixed rather than left to the caller: line edits run first, bottom
	up, so all their numbers refer to the file as the agent read it instead of
	drifting as earlier edits resize it. Find/replace edits then run in the given
	order against the result, which is safe because they address text, not
	positions.
]]
function TextEdit.apply(path: string, source: string, edits: { Edit }): string
	for _, edit in edits do
		if edit.source ~= nil then
			if #edits > 1 then
				Dispatch.fail(
					"CONFLICTING_EDITS",
					string.format("%s gets a whole-script `source` edit plus %d other edit(s).", path, #edits - 1),
					"A `source` edit replaces the entire script, so any other edit to the "
						.. "same script would be discarded. Send it on its own."
				)
			end
			return edit.source :: string
		end
	end

	local lineEdits: { LineEdit } = {}
	local findEdits: { Edit } = {}
	for _, edit in edits do
		local start = edit.startLine
		if start ~= nil then
			table.insert(lineEdits, {
				startLine = start,
				endLine = tonumber(edit.endLine) or start,
				replacement = edit.replacement :: string,
			})
		else
			table.insert(findEdits, edit)
		end
	end

	local lines = TextEdit.toLines(source)

	if #lineEdits > 0 then
		table.sort(lineEdits, function(a, b)
			return a.startLine > b.startLine
		end)

		-- Every range is checked against the file as the agent read it, before any
		-- of them is applied. Validating inside the apply loop instead would test
		-- later edits against a file the earlier ones had already resized, which
		-- reports an invented line count and hides genuine overlaps behind a
		-- spurious BAD_RANGE.
		local lineCount = #lines
		for index, edit in lineEdits do
			if edit.startLine < 1 or edit.startLine > lineCount + 1 then
				Dispatch.fail(
					"BAD_RANGE",
					string.format("startLine %d is outside %s, which has %d lines.", edit.startLine, path, lineCount),
					"Call script_read on this script first. Line numbers shift after every edit."
				)
			end
			if edit.endLine < edit.startLine - 1 or edit.endLine > lineCount then
				Dispatch.fail(
					"BAD_RANGE",
					string.format(
						"endLine %d is invalid for %s (%d lines): it must be at least startLine - 1 and at most the line count.",
						edit.endLine,
						path,
						lineCount
					),
					"Set endLine one below startLine to insert without replacing anything."
				)
			end

			-- Sorted descending, so the previous entry is the next range up the
			-- file. Overlapping ranges would make the result depend on apply order.
			local previous = lineEdits[index - 1]
			if previous and edit.endLine >= previous.startLine then
				Dispatch.fail(
					"CONFLICTING_EDITS",
					string.format(
						"Two edits to %s cover overlapping lines (%d-%d and %d-%d).",
						path,
						edit.startLine,
						edit.endLine,
						previous.startLine,
						previous.endLine
					),
					"Merge them into one edit spanning the whole range."
				)
			end
		end

		for _, edit in lineEdits do
			local result: { string } = {}
			table.move(lines, 1, edit.startLine - 1, 1, result)
			for _, line in TextEdit.toLines(edit.replacement) do
				table.insert(result, line)
			end
			if edit.endLine < #lines then
				table.move(lines, edit.endLine + 1, #lines, #result + 1, result)
			end
			lines = result
		end
	end

	local text = table.concat(lines, "\n")

	for _, edit in findEdits do
		local needle = edit.find :: string
		local occurrences = TextEdit.countLiteral(text, needle)

		if occurrences == 0 then
			Dispatch.fail(
				"NO_MATCH",
				string.format("The `find` text does not appear in %s.", path),
				"Call script_read on the script and copy the text exactly, including "
					.. "indentation -- the match is literal and whitespace-sensitive."
			)
		end
		-- Refusing an ambiguous match is the point: silently taking the first of
		-- five identical lines is how an agent edits the wrong function.
		if occurrences > 1 and edit.replaceAll ~= true then
			Dispatch.fail(
				"AMBIGUOUS_EDIT",
				string.format("The `find` text appears %d times in %s.", occurrences, path),
				"Include surrounding lines so the text is unique, or set "
					.. "`replaceAll` to change every occurrence."
			)
		end

		text = TextEdit.replaceLiteral(text, needle, edit.replace :: string, edit.replaceAll == true)
	end

	return text
end

return TextEdit
