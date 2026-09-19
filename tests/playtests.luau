local Playtest = ...
assert(Playtest.isAllowed(), "no setting defaults to ON")
setup(Playtest)
assert(Playtest.isAllowed() and writes == 0)
Playtest.control({op = "play"})
assert(launches[1] == "play")
Playtest.setAllowed(false)
Playtest.stopLocal()
assert(not running and ended == 1, "OFF stops a running MCP playtest")
for _, op in {"play", "run", "multiplayer"} do
 local ok, err = pcall(Playtest.control, {op = op})
 assert(not ok and err.code == "PLAYTEST_DISABLED", op .. " must be locked")
 assert(err.message == "Playtests are disabled by the user.")
 assert(err.hint == "Do not start or simulate a playtest. Continue using edit-mode tools and static inspection where possible.\nRun `playtests on` in the Studio MCP panel to re-enable playtesting.")
end
assert(#launches == 1)
assert(Playtest.control({op = "state"}).state.playtestsAllowed == false)
running, runMode = true, true
Playtest.control({op = "stop"})
assert(not running and stopped == 1, "stop remains allowed")

local restarted = loadModule()
setup(restarted)
assert(not restarted.isAllowed(), "saved OFF survives a fresh module")
restarted.setAllowed(true)
assert(#launches == 1, "ON never launches a test")
assert(Playtest.isAllowed(), "other contexts read the current saved setting")
for _, op in {"play", "run", "multiplayer"} do
 restarted.control({op = op})
 restarted.stopLocal()
end
assert(#launches == 4, "ON restores all three start modes")
local fresh = loadModule(); setup(fresh)
assert(fresh.isAllowed(), "saved ON survives restart")

-- A start queued before OFF must not reach Studio after OFF.
deferLaunch = true
fresh.control({op = "play"})
fresh.setAllowed(false)
queued[1]()
assert(#launches == 4 and string.find(fresh.control({op = "state"}).state.lastError, "PLAYTEST_DISABLED"))
-- No automatic state-change enforcement: a user's manual Play is not cancelled.
running = true
assert(fresh.control({op = "state"}).state.isRunning)
assert(running)
clientContext = true
fresh.stopLocal()
assert(left == 1 and not running, "client panel can stop without HTTP")
print("playtests: defaults, persistence, guards, stop and queued-start lock pass")
