--!strict
--[[
	Text shaping for the console log.

	Four pure functions, pulled out of `Console` so they can be tested. That is
	the whole reason this file exists, and it is a good one: every function here
	has already shipped a visible bug -- a paragraph that wrapped back to column
	0 under the timestamps, a stray "m" on its own line, raw `**` in the middle
	of a sentence -- and each of those was found by looking at a screenshot
	rather than by a test, because `Console` requires half of Studio and cannot
	be bundled outside it.

	Nothing in here requires anything, touches an Instance, or reads a palette.
	Colour arrives as a hex string the caller has already resolved, so the
	module never needs Color3 and the same code runs under the standalone Luau
	interpreter that `npm test` drives.
]]

local Format = {}

--[[
	Breaks a long string into lines at word boundaries.

	Roblox's own TextWrapped would do this, and would wrap to column 0 -- there
	is no hanging indent for a TextLabel -- which is the ragged shape this
	replaces. Wrapping here means every continuation line can carry the indent.

	A single word longer than the width is cut rather than allowed to overhang.
	That case is not prose: it is a path, a URL or a base64 blob, and letting one
	of those push the line out re-creates the exact wrap this exists to prevent.
]]
function Format.wrap(text: string, width: number): { string }
	local lines: { string } = {}
	local current = ""

	local function flush()
		if current ~= "" then
			table.insert(lines, current)
			current = ""
		end
	end

	for word in string.gmatch(text, "%S+") do
		while (utf8.len(word) or #word) > width do
			flush()
			local cut = utf8.offset(word, width + 1) or (width + 1)
			table.insert(lines, string.sub(word, 1, cut - 1))
			word = string.sub(word, cut)
		end
		local candidate = if current == "" then word else current .. " " .. word
		if (utf8.len(candidate) or #candidate) > width and current ~= "" then
			flush()
			current = word
		else
			current = candidate
		end
	end
	flush()
	return lines
end

-- RichText is markup, so anything user- or engine-supplied has to be escaped or
-- a stray `<` in an error message silently eats the rest of the line.
function Format.escape(value: string): string
	local escaped = string.gsub(value, "&", "&amp;")
	escaped = string.gsub(escaped, "<", "&lt;")
	escaped = string.gsub(escaped, ">", "&gt;")
	return escaped
end

--[[
	Turns an agent's markdown into the markup this label already speaks.

	Agents write for a terminal that renders markdown, so their replies arrive
	full of `**` and backticks. Printed raw they are worse than noise -- the
	asterisks land in the middle of a sentence and read as typos -- and stripping
	them would throw away the emphasis the agent chose. The label is RichText, so
	the third option is simply to honour it.

	Must be applied AFTER `escape`, which is what makes it safe: escaping has
	already turned every angle bracket in the agent's own text into an entity, so
	the only tags in the string afterwards are the ones put there here.

	Bold before italic, or the outer pair of a `**` run is eaten as two italics.
	Underscores are deliberately not italic markers: `execute_luau` and
	`mcp__rbx-studio__modify` are the vocabulary of this log, and they would
	spend most of their lives in italics for no reason.

	`code` is a "#RRGGBB" string rather than a Color3 so this module stays free
	of the engine; the caller has a palette and this does not.
]]
function Format.emphasise(escaped: string, code: string): string
	local marked = string.gsub(escaped, "%*%*(.-)%*%*", "<b>%1</b>")
	marked = string.gsub(marked, "`([^`]+)`", function(inner: string): string
		return string.format('<font color="%s">%s</font>', code, inner)
	end)
	marked = string.gsub(marked, "%*([^%*]+)%*", "<i>%1</i>")
	return marked
end

--[[
	Collapses anything that would break the one-line-per-row contract.

	A row is a line. Every width in the console is measured in characters and
	every continuation is indented by hand, so a newline arriving inside a
	message or a detail lands in the middle of that arithmetic and comes out at
	column 0 -- which is how a two-line Luau snippet in a tool argument left a
	bare "m" sitting under the log. Tabs go the same way, for the same reason.
]]
function Format.flatten(text: string): string
	return (string.gsub(text, "%s+", " "))
end

return Format
