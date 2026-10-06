local watch = ...
local result = watch.capture({path = "Workspace.Watched", properties = {"Value"}, attributes = {"Ready"}, children = false, seconds = 1})
assert(result.initial.Value == 1 and result.initial.attributes.Ready == false)
assert(result.items[1].kind == "property" and result.items[1].old == 1 and result.items[1].value == 2)
for _, connection in all do assert(not connection.active, "watch connections leak after completion") end
local before = #all
local ok = pcall(watch.capture, {path = "Workspace.Watched", properties = {"Value", "DoesNotExist"}, seconds = 1})
assert(not ok)
for index = before + 1, #all do assert(not all[index].active, "setup failure leaks an earlier listener") end
tick = function() for _ = 1, 200 do target.Value += 1; changed:fire() end end
result = watch.capture({path = "Workspace.Watched", properties = {"Value"}, attributes = {}, children = false, seconds = 1})
assert(#result.items <= 100 and result.dropped > 0 and #jsonEncode(result.items) <= 10000)
tick = function() end
target.Value = "X" .. string.rep("é", 400)
target.attributes = {}
for index = 1, 100 do target.attributes["Long" .. index] = "X" .. string.rep("🙂", 200) end
result = watch.capture({path = "Workspace.Watched", properties = {"Value"}, children = false, seconds = 1})
assert(utf8.len(result.initial.Value) ~= nil, "clipped watch value must remain valid UTF-8")
assert(result.initialDropped > 0 and #jsonEncode(result.initial) <= 5000, "baseline bypasses watch size budget")
target.Value = 1
tick = function() target.Destroying:fire() end
result = watch.capture({path = "Workspace.Watched", properties = {"Value"}, seconds = 15})
assert(result.seconds < 1 and result.items[1].kind == "destroyed")
for _, connection in all do assert(not connection.active) end
print("watch: temporal old/new values, bounds, setup failure and destruction cleanup pass")
