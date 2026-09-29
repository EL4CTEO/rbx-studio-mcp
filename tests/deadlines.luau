local dispatch = ...
local writes = 0
dispatch.register("write", function()
 writes += 1
 local deadline = dispatch.deadline()
 now = 2000
 local callback = coroutine.create(function() dispatch.checkDeadline(deadline); writes += 1 end)
 local ok, err = coroutine.resume(callback)
 assert(not ok and err.code == "DEADLINE_EXPIRED", "carry deadline into engine callbacks")
 return true
end)
local expired = dispatch.invoke("one", "write", {}, 900)
assert(not expired.ok and expired.error.code == "DEADLINE_EXPIRED" and writes == 0)
local current = dispatch.invoke("two", "write", {}, 1500)
assert(current.ok and writes == 1)
assert(dispatch.deadline() == nil, "clear request-local deadline")
print("deadlines: expired requests and asynchronous callback guards pass")
