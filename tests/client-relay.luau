local relay = ...
local function fails(code, fn)
 local ok, err = pcall(fn)
 assert(not ok and err.code == code, code)
end
running = false
fails("NOT_RUNNING", function() relay.playerFor(nil) end)
running = true
fails("NO_PLAYER", function() relay.playerFor(nil) end)
players = {player, {Name = "Bob"}}
fails("AMBIGUOUS_PLAYER", function() relay.playerFor(nil) end)
assert(relay.playerFor("Alice") == player)
fails("NO_PLAYER", function() relay.playerFor("Missing") end)
local result = relay.run(player, "Test", "", {}, 1)
assert(result.ok and not result.wrong and disconnected and made[1].destroyed)
fails("CLIENT_FAILED", function()
 relay.run(player, "Test", "", {}, 1, function() error("setup failed") end)
end)
assert(made[3].destroyed)
fails("NO_ACK", function() relay.run(player, "Test", "", {}, 0) end)
assert(made[5].destroyed)
print("client relay: ok")

local readyCalls = 0
task.wait = function()
 callback({}, {ready = true})
 callback(player, {ready = true})
 callback(player, {ready = true})
 callback(player, {ok = true})
end
local capture = relay.run(player, "Capture", "", {}, 1, nil, function() readyCalls += 1 end)
assert(capture.ok and readyCalls == 1 and startSignals == 1)
local failed = relay.run(player, "Capture", "", {}, 1, nil, function() error("ready failed") end)
assert(not failed.ok and string.find(failed.reason, "ready failed") and startSignals == 1)

-- Continuous relay is installed once per player and accepts only that client.
players = {player}
relay.startDiagnostics()
assert(diagnosticStarted == 1 and added and removing)
assert(made[#made - 1].Name == "MCPDiagnosticsRelay")
local count = #diagnosticPayloads
callback({Name = "Impostor"}, {level = "error", message = "wrong"})
assert(#diagnosticPayloads == count)
callback(player, {level = "warning", message = "outside execute_luau"})
assert(#diagnosticPayloads == count + 1)
removing(player)
assert(diagnosticStopped == 1)
added(player)
assert(diagnosticStarted == 2)
local persistent = made[#made - 1]
relay.stopDiagnostics()
assert(diagnosticStopped == 2 and persistent.destroyed)
