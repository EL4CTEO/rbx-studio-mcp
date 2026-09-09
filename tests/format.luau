--!nolint
--[[
	Unit tests for the console's text shaping.

	Run with `npm test`, which bundles plugin/src/Format.luau and executes it
	outside Studio. Assertions raise on failure, so the interpreter's exit code
	is the result.

	Every case here is a bug that shipped. The console is the only feedback
	channel this plugin has, and each of these broke it in a way that looked
	like the panel was malfunctioning rather than like text being formatted
	wrongly -- which is why they were all found in screenshots instead of here.
]]

local Format = ...

local function widest(lines)
	local most = 0
	for _, line in lines do
		most = math.max(most, utf8.len(line) or #line)
	end
	return most
end

-- wrap ---------------------------------------------------------------------

-- The shipped bug: an agent's paragraph was one row, so the TextLabel wrapped
-- it back to column 0 under the timestamps and the second half of a sentence
-- read as a new log entry.
do
	local prose = string.rep("word ", 40)
	local lines = Format.wrap(prose, 74)
	assert(#lines > 1, "a long paragraph must be split")
	assert(widest(lines) <= 74, "no line may exceed the width")
	-- Nothing may be lost or duplicated on the way through.
	local rejoined = table.concat(lines, " ")
	assert(rejoined == (string.gsub(prose, "%s+$", "")), "wrapping must preserve the words")
end

-- A path or a base64 blob is one "word" and would otherwise push a line out to
-- its full length, re-creating the wrap this exists to prevent.
do
	local lines = Format.wrap("aaaa" .. string.rep("z", 200) .. " tail", 74)
	assert(widest(lines) <= 74, "an overlong word is cut, not allowed to overhang")
	-- On the last line rather than being it: the word's remainder is 56
	-- characters, so "tail" still fits beside it and packing it there is
	-- correct. Asserting equality here was the test being wrong, not the code.
	assert(
		string.sub(lines[#lines], -5) == " tail",
		"text after an overlong word survives, packed onto the remainder"
	)
end

do
	assert(#Format.wrap("", 74) == 0, "empty text produces no lines")
	assert(#Format.wrap("short", 74) == 1, "text that fits is left alone")
	-- Counted in characters, not bytes: every sigil in this console is a 3-byte
	-- glyph, and counting bytes cut lines a third early.
	local wide = Format.wrap(string.rep("\u{25C6}", 100), 74)
	assert(widest(wide) <= 74, "width is measured in characters, not bytes")
end

-- escape -------------------------------------------------------------------

do
	assert(Format.escape("a < b & c > d") == "a &lt; b &amp; c &gt; d", "markup is escaped")
	-- Ampersand first, or the entities produced by the other two get escaped
	-- again into &amp;lt; and the user sees the entity text.
	assert(Format.escape("<b>") == "&lt;b&gt;", "a tag cannot survive escaping")
end

-- emphasise ----------------------------------------------------------------

local CODE = "#22D3EE"

do
	assert(
		Format.emphasise("Doing **well**.", CODE) == "Doing <b>well</b>.",
		"bold becomes a tag"
	)
	assert(
		Format.emphasise("an *emphasised* word", CODE) == "an <i>emphasised</i> word",
		"italic becomes a tag"
	)
	assert(
		Format.emphasise("via `console`", CODE)
			== 'via <font color="#22D3EE">console</font>',
		"code spans take the palette's colour"
	)
end

-- Bold must be consumed before italic, or the outer pair of a ** run is eaten
-- as two separate italics and the text comes out doubly wrapped.
do
	local out = Format.emphasise("**bold**", CODE)
	assert(out == "<b>bold</b>", "bold is not read as two italics, got: " .. out)
end

-- The log's own vocabulary must survive untouched. These are the names this
-- console prints all day, and italicising half of one is worse than the raw
-- asterisks this feature exists to remove.
do
	local names = "execute_luau and mcp__rbx-studio__modify"
	assert(Format.emphasise(names, CODE) == names, "underscores are never italic markers")
	assert(Format.emphasise("5 * 3 alone", CODE) == "5 * 3 alone", "a lone asterisk is text")
end

-- An unclosed marker is left as written rather than opening a tag that never
-- closes, which would swallow the rest of the line's colour.
do
	local out = Format.emphasise("**unclosed and `also", CODE)
	assert(not string.find(out, "<b>"), "an unclosed ** opens no tag")
	assert(not string.find(out, "<font"), "an unclosed backtick opens no tag")
end

-- Escaping happens first, so emphasise must never see a real angle bracket and
-- must never undo one.
do
	local escaped = Format.escape("a <script> tag with **bold**")
	local out = Format.emphasise(escaped, CODE)
	assert(string.find(out, "&lt;script&gt;", 1, true), "escaped markup stays escaped")
	assert(string.find(out, "<b>bold</b>", 1, true), "emphasis still applies around it")
end

-- flatten ------------------------------------------------------------------

-- The shipped bug: a two-line Luau snippet in a tool argument put a bare "m"
-- at column 0 under the log, because every width here assumes one row is one
-- line.
do
	assert(
		Format.flatten("local m = workspace.House\nm.Parent = nil") ==
			"local m = workspace.House m.Parent = nil",
		"a newline inside a row is collapsed"
	)
	assert(Format.flatten("a\t\tb") == "a b", "tabs go the same way")
	assert(Format.flatten("a   b") == "a b", "runs of space collapse to one")
	assert(Format.flatten("plain") == "plain", "ordinary text is untouched")
end

print("format: all cases pass")
