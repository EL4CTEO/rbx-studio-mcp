local Commands = ...
local chatOn = false -- what init.server reads back from a fresh install: no setting
local saved = {}
Commands.setup({
 reconnect = function() end,
 savePort = function() end,
 saveTheme = function() end,
 autoOpen = function() return true end,
 saveAutoOpen = function() end,
 chat = function() return chatOn end,
 saveChat = function(value) chatOn = value; table.insert(saved, value) end,
 status = function() return "" end,
 studioId = function() return "studio" end,
})

local function lastMessage() return rows[#rows].message end
local function sentToAgent(line)
 for _, request in requests do
  if request.command == "prompt" and request.line == line then return true end
 end
 return false
end

-- Off: a sentence is refused before it reaches the bridge, and says how to turn it on.
Commands.run("make the door open")
assert(#requests == 0, "a sentence must not reach the bridge while chat is off")
assert(string.find(lastMessage(), "chat is off", 1, true), lastMessage())
assert(string.find(rows[#rows].detail, "chat on", 1, true))
Commands.run("hello")
assert(#requests == 0, "a single unrelated word is a sentence too")

-- A near-miss is still worth a hint, on or off.
Commands.run("doctorr")
assert(string.find(lastMessage(), "did you mean doctor", 1, true), lastMessage())
assert(#requests == 0)

-- Commands are untouched.
Commands.run("doctor")
assert(#requests == 1 and requests[1].command == "doctor", "commands run with chat off")

Commands.run("chat")
assert(string.find(lastMessage(), "chat off", 1, true), lastMessage())
assert(#saved == 0, "asking does not change the setting")

-- On: persisted, the prompt row told, and a sentence goes through.
Commands.run("chat on")
assert(chatOn == true and #saved == 1 and saved[1] == true)
assert(promptChat == true, "the prompt row must be told")
Commands.run("chat on")
assert(#saved == 1 and string.find(lastMessage(), "already chat on", 1, true), lastMessage())
local before = #requests
Commands.run("make the door open")
assert(#requests == before + 1 and sentToAgent("make the door open"), "a sentence goes to the agent when chat is on")
Commands.run("chat")
assert(string.find(lastMessage(), "chat on", 1, true), lastMessage())

-- Bad arguments change nothing.
Commands.run("chat banana")
Commands.run("chat on off")
assert(chatOn == true and #saved == 1, "bad arguments cannot change the setting")
assert(string.find(lastMessage(), "usage: chat", 1, true), lastMessage())

-- Off again: persisted, and sentences stop.
Commands.run("chat off")
assert(chatOn == false and #saved == 2 and saved[2] == false and promptChat == false)
before = #requests
Commands.run("turn the lights off")
assert(#requests == before, "a sentence is refused again once chat is off")

assert(Commands.complete("ch")[1] == "chat", "chat is completable")
Commands.run("help")
local listed = false
for _, row in rows do
 if row.message == "   chat [on|off]" then listed = true end
end
assert(listed, "help lists chat")
print("chat command: off by default, on/off, persistence, refusal and completion pass")
