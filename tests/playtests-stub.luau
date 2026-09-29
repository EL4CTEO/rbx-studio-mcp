local stored = nil
local writes, launches, stopped, left, ended, added = 0, {}, 0, 0, 0, 0
local running, runMode, clientContext = false, false, false
local queued = {}
local deferLaunch = false
local task = {
 spawn = function(fn) if deferLaunch then table.insert(queued, fn) else fn() end end,
 delay = function(_, fn) fn() end,
 wait = function() end,
}
local RunService = {
 IsEdit = function() return not running end,
 IsRunning = function() return running end,
 IsRunMode = function() return runMode end,
 IsClient = function() return clientContext end,
 IsServer = function() return not clientContext end,
 Stop = function() stopped += 1; running = false end,
}
local function launch(mode) table.insert(launches, mode); running = true; runMode = mode == "run" end
local StudioTestService = {
 EditModeActive = true,
 ExecutePlayModeAsync = function() launch("play") end,
 ExecuteRunModeAsync = function() launch("run") end,
 ExecuteMultiplayerTestAsync = function() launch("multiplayer") end,
 EndTest = function() ended += 1; running = false end,
 LeaveTest = function() left += 1; running = false end,
 AddPlayers = function(_, count) added += count end,
}
local game = { GetService = function(_, name)
 if name == "HttpService" then return {GenerateGUID = function() return "test-id" end} end
 if name == "RunService" then return RunService end
 if name == "StudioTestService" then return StudioTestService end
 if name == "Players" then return {GetPlayers = function() return {} end} end
 return {}
end }
local Context = {editorId = function() return "editor" end, testId = function() return nil end, beginTest = function() return function() end end}
local LogBuffer = {clientReady = function() return true end}
local function setup(module)
 module.setup(function() return stored end, function(value) stored = value; writes += 1 end)
end
local rows = {}
local requests = {}
local promptChat = nil
local Console = {
 log = function(level, message, detail) table.insert(rows, {level = level, message = message, detail = detail}) end,
 setPromptBusy = function() end,
 setPromptChat = function(enabled) promptChat = enabled end,
}
local Secret = {mask = function(line) return line, false end}
local Net = {
 postJson = function(_, request) table.insert(requests, request); return {ok = true, body = ""} end,
 decode = function() return {running = false, lines = {}} end,
}
