local edit = ...
edit.write(target, function() return "after" end)
assert(target.Source == "after" and writes == 1)
onWait = function() target.Source = "user typed newer text" end
local ok, err = pcall(function() edit.write(target, function() return "second" end) end)
assert(not ok and err.code == "VERIFY_FAILED")
assert(target.Source == "user typed newer text" and writes == 2, "verification must never rewrite")
onWait = nil
onUpdate = function(node, callback) node.Source = "concurrent"; node.Source = callback(node.Source) end
ok, err = pcall(function() edit.write(target, function(current)
 if current ~= "before" then Dispatch.fail("STALE_SCRIPT", "changed") end
 return "after"
end) end)
assert(not ok and err.code == "STALE_SCRIPT" and target.Source == "concurrent")
print("script editor: observation and callback failures preserve newer source")

onUpdate = nil
target.Source = "before"
local reverted = false
onWait = function() if not reverted then reverted = true; target.Source = "before" end end
edit.write(target, function() return "after" end)
assert(target.Source == "after", "a load that put the old text back is rewritten")
print("script editor: a reverted write is repaired")
