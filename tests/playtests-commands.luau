local Commands = ...
setup(Playtest)
Commands.run("playtests")
assert(rows[#rows].message == "Playtests: ON" and writes == 0)
Playtest.control({op = "run"})
Commands.run("playtests off")
assert(rows[#rows].message == "Playtests: OFF" and stored == false)
assert(not running and stopped == 1)
assert(requests[1].command == "playtests" and requests[1].args[1] == "off")
Commands.run("playtests")
assert(rows[#rows].message == "Playtests: OFF")
local count = #launches
Commands.run("playtests on")
assert(rows[#rows].message == "Playtests: ON" and stored == true and #launches == count)
assert(#requests == 1, "ON must not send any bridge command")
Commands.run("playtests banana")
Commands.run("playtests off extra")
assert(stored == true and writes == 2, "bad arguments cannot change the setting")
assert(Commands.complete("playt")[1] == "playtests")
clientContext, running, runMode = true, true, false
Commands.run("playtests off")
assert(left == 1 and #requests == 1, "client-side OFF stops locally without HTTP")
print("playtests panel: reporting, changes, validation and client stop pass")

running = true -- user manually starts a test while the lock is already OFF
Commands.run("playtests off")
assert(left == 2 and not running, "repeating OFF also stops a detected manual test")
