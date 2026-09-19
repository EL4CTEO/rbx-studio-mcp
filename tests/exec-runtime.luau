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
