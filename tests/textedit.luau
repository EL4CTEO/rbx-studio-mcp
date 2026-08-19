--!nolint
--[[
	Unit tests for the edit engine.

	Run with `npm test`, which bundles plugin/src/TextEdit.luau with a stub
	Dispatch and executes it outside Studio. Assertions raise on failure, so the
	interpreter's exit code is the result.

	The cases worth having here are the silent ones: an off-by-one line splice or
	a find/replace that hits the wrong occurrence produces working-looking code
	in the user's game with no error anywhere.
]]

local TextEdit = ...

local SOURCE = table.concat({
	"local Players = game:GetService(\"Players\")",
	"",
	"local function onPlayerAdded(player)",
	"\tprint(player.Name)",
	"end",
	"",
	"Players.PlayerAdded:Connect(onPlayerAdded)",
}, "\n")

local function fails(code: string, body: () -> ())
	local ok, err = pcall(body)
	assert(not ok, "expected " .. code .. " but the call succeeded")
	assert(typeof(err) == "table", "expected a structured error, got " .. tostring(err))
	assert(err.code == code, "expected " .. code .. ", got " .. tostring(err.code))
	-- Every failure has to tell the agent what to do next, not just what broke.
	assert(err.message ~= nil and err.message ~= "", code .. " has no message")
end

local function apply(edits)
	return TextEdit.apply("Test.Script", SOURCE, edits)
end

-- toLines round trips.
assert(#TextEdit.toLines(SOURCE) == 7, "expected 7 lines")
assert(table.concat(TextEdit.toLines(SOURCE), "\n") == SOURCE, "toLines is not lossless")
assert(#TextEdit.toLines("") == 0, "empty source should have no lines")
assert(#TextEdit.toLines("a\n") == 1, "a trailing newline should not add a line")
assert(#TextEdit.toLines("a\n\n") == 2, "a blank final line should be kept")

-- Literal replace does not treat % as a pattern escape, in needle or replacement.
assert(TextEdit.replaceLiteral("a%db", "%d", "N", false) == "aNb", "needle % was interpreted")
assert(TextEdit.replaceLiteral("ab", "b", "%1", false) == "a%1", "replacement % was interpreted")
assert(TextEdit.replaceLiteral("aaa", "a", "b", true) == "bbb", "replaceAll missed occurrences")
assert(TextEdit.replaceLiteral("aaa", "a", "b", false) == "baa", "single replace changed too much")
assert(TextEdit.countLiteral("aaa", "aa") == 1, "counting should not overlap matches")

-- find/replace.
assert(
	apply({ { path = "x", find = "print(player.Name)", replace = "warn(player.Name)" } })
		== (string.gsub(SOURCE, "print", "warn")),
	"find/replace did not apply"
)
assert(
	apply({ { path = "x", find = "onPlayerAdded", replace = "onJoin", replaceAll = true } })
		== (string.gsub(SOURCE, "onPlayerAdded", "onJoin")),
	"replaceAll did not apply everywhere"
)

-- A non-unique `find` is refused rather than silently taking the first hit.
fails("AMBIGUOUS_EDIT", function()
	apply({ { path = "x", find = "onPlayerAdded", replace = "onJoin" } })
end)
fails("NO_MATCH", function()
	apply({ { path = "x", find = "does not exist", replace = "" } })
end)

-- Line ranges are 1-based and inclusive.
assert(
	apply({ { path = "x", startLine = 4, endLine = 4, replacement = "\twarn(player.Name)" } })
		== (string.gsub(SOURCE, "print", "warn")),
	"single-line replace hit the wrong line"
)
assert(
	apply({ { path = "x", startLine = 1, replacement = "-- header" } })
		== "-- header\n" .. string.sub(SOURCE, #"local Players = game:GetService(\"Players\")" + 2),
	"endLine should default to startLine"
)

-- Deleting lines.
local deleted = TextEdit.toLines(apply({ { path = "x", startLine = 3, endLine = 5, replacement = "" } }))
assert(#deleted == 4, "expected 3 lines removed, got " .. #deleted)
assert(deleted[3] == "", "wrong lines were removed")

-- endLine one below startLine inserts without replacing.
local inserted = TextEdit.toLines(apply({ { path = "x", startLine = 3, endLine = 2, replacement = "-- note" } }))
assert(#inserted == 8, "insert should add exactly one line")
assert(inserted[3] == "-- note", "insert landed on the wrong line")
assert(inserted[4] == "local function onPlayerAdded(player)", "insert overwrote a line")

-- Several line edits refer to the file as it was read, not as it shifts. Given
-- in ascending order, the second would land two lines off if applied naively.
local multi = TextEdit.toLines(apply({
	{ path = "x", startLine = 1, replacement = "-- one\n-- two\n-- three" },
	{ path = "x", startLine = 7, replacement = "-- tail" },
}))
assert(multi[1] == "-- one", "first line edit did not apply")
assert(multi[#multi] == "-- tail", "second line edit drifted after the first resized the file")
assert(#multi == 9, "expected 7 + 2 lines, got " .. #multi)

-- Overlapping ranges are refused: the result would depend on apply order.
fails("CONFLICTING_EDITS", function()
	apply({
		{ path = "x", startLine = 2, endLine = 5, replacement = "a" },
		{ path = "x", startLine = 4, endLine = 6, replacement = "b" },
	})
end)

-- Out-of-range lines.
fails("BAD_RANGE", function()
	apply({ { path = "x", startLine = 99, replacement = "" } })
end)
fails("BAD_RANGE", function()
	apply({ { path = "x", startLine = 1, endLine = 99, replacement = "" } })
end)

-- Whole-script replacement wins outright, and refuses to share a script.
assert(apply({ { path = "x", source = "-- new" } }) == "-- new", "source edit did not apply")
fails("CONFLICTING_EDITS", function()
	apply({
		{ path = "x", source = "-- new" },
		{ path = "x", find = "print", replace = "warn" },
	})
end)

-- Line edits are resolved before find/replace, so a find can target inserted text.
assert(
	apply({
		{ path = "x", startLine = 1, replacement = "-- MARKER" },
		{ path = "x", find = "-- MARKER", replace = "-- done" },
	}) == "-- done" .. string.sub(SOURCE, #"local Players = game:GetService(\"Players\")" + 1),
	"find/replace did not see the result of the line edit"
)

-- Validation rejects malformed edits before any script is touched.
fails("BAD_PARAMS", function()
	TextEdit.validate({ path = "x" }, 1)
end)
fails("BAD_PARAMS", function()
	TextEdit.validate({ path = "x", find = "a", replace = "b", startLine = 1, replacement = "c" }, 1)
end)
fails("BAD_PARAMS", function()
	TextEdit.validate({ path = "x", find = "", replace = "b" }, 1)
end)
fails("BAD_PARAMS", function()
	TextEdit.validate({ path = "x", find = "a" }, 1)
end)
fails("BAD_PARAMS", function()
	TextEdit.validate({ path = "x", startLine = 1 }, 1)
end)
fails("BAD_PARAMS", function()
	TextEdit.validate({ path = "", source = "a" }, 1)
end)

TextEdit.validate({ path = "x", find = "a", replace = "" }, 1)
TextEdit.validate({ path = "x", startLine = 1, replacement = "" }, 1)
TextEdit.validate({ path = "x", source = "" }, 1)
