local undo = ...
local ran = false
available = false
local value, recorded = undo.record("test", "test", function() ran = true; return 7 end)
assert(ran and value == 7 and recorded == false, "no recording (a playtest) still runs, and says so")
available = true
assert(undo.record("test", "test", function() return 42 end) == 42)
assert(finishes[1] == "commit")
ok = pcall(function() undo.record("test", "test", function() error("body failed") end) end)
assert(not ok and finishes[2] == "cancel")
for _, failure in {"begin", "finish"} do
 beginThrows = failure == "begin"; finishThrows = failure == "finish"
 local recorded
 ok, _, recorded = pcall(function() return undo.record("test", "test", function() return 1 end) end)
 -- A recording that will not open is treated as none; one that will not close
 -- is an outcome the agent has to check.
 if failure == "begin" then assert(ok and recorded == false) else assert(not ok) end
 beginThrows = false; finishThrows = false
 assert(undo.exclusive(function() return 2 end) == 2, "failure must release the lock")
end
-- Hold a yielding edit while a second mutation queues; it must not interleave.
local order = {}
local first = coroutine.create(function() undo.exclusive(function() table.insert(order, "first"); coroutine.yield(); table.insert(order, "done") end) end)
local second = coroutine.create(function() undo.exclusive(function() table.insert(order, "second") end) end)
assert(coroutine.resume(first)); assert(coroutine.resume(second)); assert(#order == 1)
assert(coroutine.resume(first)); assert(table.concat(order, ",") == "first,done,second")
print("undo: unrecorded fallback, cleanup and yielding mutation serialization pass")
