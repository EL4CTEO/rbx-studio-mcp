local runtime = ...
local result = runtime.run(function()
 for i = 1, 205 do listener(tostring(i), "warning") end
 return 1, nil, 3, nil, 5, 6, 7, 8, 9, 10, 11
end)
assert(result.ok and #result.returned == 10)
assert(result.returned[2] == "nil" and result.returned[4] == "nil")
assert(#result.output == 200 and result.output[1].level == "warning")
assert(disconnected)
local cycle = {}; cycle.self = cycle
assert(runtime.describe(cycle).self == "<circular reference>")
local deep = { a = { b = { c = { d = {} } } } }
assert(runtime.describe(deep).a.b.c.d == "<nested table>")
local wide = {}; for i = 1, 60 do wide[i] = i end
assert(#runtime.describe(wide) == 51)
local failed = runtime.run(function() error("intentional") end)
assert(not failed.ok and string.find(failed.error, "intentional"))
print("exec runtime: ok")

local timeout = runtime.run(function()
 listener("before timeout", "warning")
 coroutine.yield()
end, 1)
assert(not timeout.ok and string.find(timeout.error, "CLIENT_TIMEOUT"))
assert(timeout.output[1].message == "before timeout" and cancelled and disconnected)
local fast = runtime.run(function() return 42 end, 1)
assert(fast.ok and fast.returned[1] == 42)
local tree = {}
for i = 1, 50 do tree[i] = {}; for j = 1, 50 do tree[i][j] = string.rep("x", 10000) end end
local bounded = runtime.run(function() return tree, tree, tree end)
local function cost(value)
 if type(value) == "string" then return #value end
 if type(value) ~= "table" then return 10 end
 local size = 0; for _, item in value do size += cost(item) end; return size
end
assert(cost(bounded.returned) < 10000, "one budget across nested tables and multiple returns")
assert(result.outputDropped == 5 and result.returnsDropped == 1)
assert(utf8.len(runtime.describe(string.rep("é", 1500))), "return preview splits a UTF-8 character")
local hugeLog = runtime.run(function() listener(string.rep("x", 140000), "warning") end)
assert(hugeLog.ok and hugeLog.resultId and hugeLog.outputNotRetained == 1,
 "an oversized first log line must report retention loss even without outputDropped")
print("execution: global result budget and omission metadata pass")
