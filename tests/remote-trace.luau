local Trace = ...
local root = object("Root", "Folder", game)
local remote = object("Shop", "RemoteEvent", root)
local calls = 0
local existing = remote.OnServerEvent:Connect(function() calls += 1 end)
local stop = Trace.start(root, alice, false, 5, nil)
remote.OnServerEvent:Fire(alice, "buy", nil, 5)
remote.OnServerEvent:Fire(alice, "buy", nil, 5)
remote.OnServerEvent:Fire(bob, "other")
advance(2)
local summary = stop()
assert(summary.events == 2 and summary.items[1].count == 2)
assert(summary.items[1].callsPerSecond == 1 and summary.items[1].direction == "client -> server")
assert(summary.items[1].player == "Alice" and #summary.items[1].samples == 1)
assert(string.find(summary.items[1].samples[1], "nil:nil", 1, true))
assert(calls == 3 and existing.Connected and remote.OnServerEvent.count() == 1)
remote.OnServerEvent:Fire(alice, "after")
assert(calls == 4 and stop().events == 2 and root.DescendantAdded.count() == 0)

local received = 0
local clientHandler = remote.OnClientEvent:Connect(function() received += 1 end)
local clientStop = Trace.start(root, alice, true, 1, nil)
remote.OnClientEvent:Fire(true, 42)
advance(1)
assert(clientStop().items[1].direction == "server -> client" and received == 1)
assert(clientHandler.Connected and remote.OnClientEvent.count() == 1)

local capped = Trace.start(root, alice, false, 5, nil)
for i = 1, 1005 do remote.OnServerEvent:Fire(alice, i) end
assert(capped().events == 1000 and capped().eventLimitReached)
assert(#capped().items[1].samples == 2 and remote.OnServerEvent.count() == 1)
assert(calls == 1009) -- the game's own listener still receives EVERY call

local dynamic = Trace.start(root, alice, true, 5, nil)
local added = object("New", "RemoteEvent", root)
root.DescendantAdded:Fire(added)
added.OnClientEvent:Fire("new")
assert(dynamic().items[1].path == "New" and added.OnClientEvent.count() == 0)

local relay = object("Relay", "LocalScript", root); relay.attributes.MCPClientRelay = true
local report = object("Report", "RemoteEvent", relay)
local remoteFunction = object("Function", "RemoteFunction", root)
local invoke = function() return "unchanged" end
remoteFunction.OnServerInvoke = invoke
local clean = Trace.start(root, alice, false, 1, nil)
assert(report.OnServerEvent.count() == 0 and remoteFunction.OnServerInvoke == invoke)
clean()

local huge = {}; for i = 1, 100 do huge[i] = string.rep("x", 10000) end
local cycle = {}; cycle.self = cycle
assert(#Trace.arguments(huge, cycle, string.rep("x", 10000), nil, 1, 2, 3) <= 195)
assert(string.find(Trace.arguments(cycle), "table{...}", 1, true))

local many = object("Many", "Folder", game)
for i = 1, 130 do object("R" .. i, "RemoteEvent", many) end
local limited = Trace.start(many, alice, false, 1, nil)
for _, r in many.children do r.OnServerEvent:Fire(alice, "hello") end
local limits = limited()
assert(limits.watched == 128 and limits.scanLimitReached and #limits.items == 20 and limits.rowsOmitted)
for _, r in many.children do assert(r.OnServerEvent.count() == 0) end

local bad = object("Bad", "Folder", game)
bad.GetChildren = function() error("discovery failure") end
local inaccessible = Trace.start(bad, alice, false, 1, nil)
assert(inaccessible().skipped == 1 and bad.DescendantAdded.count() == 0)
local broken = object("Broken", "RemoteEvent", bad)
bad.GetChildren = function() return {broken} end
broken.OnServerEvent.Connect = function() error("connection failed") end
local ok = pcall(Trace.start, bad, alice, false, 1, nil)
assert(not ok and bad.DescendantAdded.count() == 0)
print("remote trace: limits, directions, passive listeners and cleanup pass")

local relocated = object("Relocated", "RemoteEvent", root)
local scoped = Trace.start(root, alice, false, 1, nil)
relocated.Parent = game
relocated.OnServerEvent:Fire(alice, "outside scope")
assert(scoped().events == 0)
local unicode = object(string.rep("é", 200), "RemoteEvent", root)
local unicodeStop = Trace.start(root, alice, true, 1, nil)
unicode.OnClientEvent:Fire("unicode")
local path = unicodeStop().items[1].path
assert(utf8.len(path) ~= nil and #path <= 259)
