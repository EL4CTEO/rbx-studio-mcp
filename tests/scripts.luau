local handler = ...
local result = handler.grep({patterns = {"local", "one"}, contextLines = 1})
assert(result.searched == 2 and result.total == 3 and reads == 2)
assert(result.items[1].path == "A" and result.items[1].revision and #result.items[1].needles == 2)
local single = handler.grep({path = "A", pattern = "one", literal = true})
assert(single.searched == 1 and single.total == 2, "include a script root")
local counts = handler.grep({patterns = {"one", "two"}, mode = "counts"})
assert(counts.counts[1] == 2 and counts.counts[2] == 2 and counts.matchedFiles == 2 and #counts.items == 0)
local files = handler.grep({pattern = "local", mode = "files", limit = 1, offset = 1})
assert(files.total == 2 and #files.items == 1 and files.items[1].path == "B" and files.items[1].matches == 1)
-- Changes that arrive after preparation must be checked in the write callback.
beforeWrite = function(node) node.Source = "newer"; beforeWrite = nil end
local ok, err = pcall(function() handler.edit({edits = {{path = "A", source = "replacement"}}}) end)
assert(not ok and err.code == "STALE_SCRIPT" and a.Source == "newer")
-- A later failed write compensates earlier successful writes.
a.Source, b.Source, writes = "a", "b", 0
beforeWrite = function(_, index) if index == 2 then beforeWrite = nil; error("write failed") end end
ok = pcall(function() handler.edit({edits = {{path = "A", source = "a2"}, {path = "B", source = "b2"}}}) end)
assert(not ok and a.Source == "a" and b.Source == "b")
-- Compensation must preserve a human edit that arrived after our first write.
a.Source, b.Source, writes = "a", "b", 0
beforeWrite = function(_, index) if index == 2 then a.Source = "human edit"; beforeWrite = nil; error("write failed") end end
ok, err = pcall(function() handler.edit({edits = {{path = "A", source = "a2"}, {path = "B", source = "b2"}}}) end)
assert(not ok and err.code == "PARTIAL_EDIT" and a.Source == "human edit" and string.find(err.hint, "A"))
print("scripts: batched grep, revisions, commit-time guards and conditional rollback pass")
a.Source = string.rep("x", 100000)
local long = handler.grep({path = "A", pattern = "x", literal = true})
assert(long.total == 1 and #long.items == 1 and long.items[1].truncated and #long.items[1].text == 256)
a.Source = string.rep(string.rep("x", 3000) .. "\n", 20)
local bounded = handler.grep({path = "A", pattern = "x", literal = true, limit = 500})
assert(bounded.total == 20 and #bounded.items > 0 and #bounded.items < 20)
