local results = ...
local rows = {}; for index = 1, 90 do rows[index] = { label = "row" .. index, extra = index } end
local retained = results.capture({returned = {rows}, output = {}})
assert(not retained.retainedTruncated)
rows[1].label = "mutated after capture"
local first = results.read({resultId = retained.resultId, resultFields = {"label"}})
assert(#first.items == 25 and first.nextOffset == 25 and first.total == 90)
assert(first.items[1].value.label == "row1" and first.items[1].value.extra == nil)
local nextPage = results.read({resultId = retained.resultId, resultOffset = first.nextOffset, resultLimit = 100})
assert(nextPage.items[1].key == 26 and #nextPage.items == 65 and not nextPage.nextOffset)
local raw = string.rep('😀\0', 3000)
local text = results.capture({returned = {raw}})
local pieces, offset = {}, 0
repeat
	local page = results.read({resultId = text.resultId, resultOffset = offset})
	assert(#jsonEncode(page) <= 10000 and utf8.len(page.value))
	table.insert(pieces, page.value)
	offset = page.nextOffset
until not offset
assert(table.concat(pieces) == raw, "string pages must be complete UTF-8, including escaped control characters")
local mixed = results.capture({returned = {{[1] = "numeric", named = "field"}}})
assert(results.read({resultId = mixed.resultId, resultPath = {"returned", 1, "named"}}).value == "field")
assert(results.read({resultId = mixed.resultId, resultPath = {"returned", 1, 1}}).value == "numeric")
local huge = results.capture({returned = {string.rep("x", 200000)}})
assert(huge.retainedTruncated and #huge.omittedPaths > 0)
local cycle = {}; cycle.self = cycle
assert(results.capture({returned = {cycle}}).retainedTruncated)
local nested = results.capture({returned = {{data = string.rep("x", 20000)}}})
local shape = results.read({resultId = nested.resultId})
assert(shape.items[1].value.kind == "string" and shape.items[1].value.resultPath[3] == "data")
local longKeys = {}
for index = 1, 20 do longKeys[string.rep("k", 510) .. index] = index end
local keySnapshot = results.capture({returned = {{longKeys}}})
local keyPage = results.read({resultId = keySnapshot.resultId})
assert(#keyPage.items == 1 and not keyPage.nextOffset, "an oversized child summary must not stall paging")
for _ = 1, 10 do results.capture({returned = {1}}) end
local ok, failure = pcall(results.read, {resultId = retained.resultId})
assert(not ok and failure.code == "RESULT_EXPIRED")
local expires = results.capture({returned = {123}})
now += 121
ok, failure = pcall(results.read, {resultId = expires.resultId})
assert(not ok and failure.code == "RESULT_EXPIRED")
print("results: immutable snapshots, projection, continuation, UTF-8, caps and expiry pass")
