local running = true
local players = {}
local added, removing
local Players = { GetPlayers = function() return players end,
 PlayerAdded = { Connect = function(_, fn) added = fn end },
 PlayerRemoving = { Connect = function(_, fn) removing = fn end },
}
local diagnosticStarted, diagnosticStopped, diagnosticPayloads = 0, 0, {}
local LogBuffer = {
 startClient = function() diagnosticStarted += 1 end,
 stopClient = function() diagnosticStopped += 1 end,
 pushClient = function(_, payload) table.insert(diagnosticPayloads, payload) end,
}
local game = { GetService = function(_, name)
 if name == "Players" then return Players end
 return { IsRunning = function() return running end, IsServer = function() return true end }
end }
local made = {}
local callback
local disconnected = false
local startSignals = 0
local Instance = { new = function(class)
 local object = { ClassName = class, SetAttribute = function() end }
 object.Destroy = function() object.destroyed = true end
 if class == "RemoteEvent" then
  object.FireClient = function(_, to, value) assert(to.Name == "Alice" and value == true); startSignals += 1 end
  object.OnServerEvent = { Connect = function(_, fn)
   callback = fn
   return { Disconnect = function() disconnected = true end }
  end }
 end
 table.insert(made, object)
 return object
end }
local playerGui = { FindFirstChild = function() return nil end }
local player = { Name = "Alice", Parent = Players, FindFirstChildOfClass = function(_, class)
 if class == "PlayerGui" then return playerGui end
 return {}
end, CharacterAdded = { Connect = function() return { Disconnect = function() end } end } }
local task = { spawn = function(fn) fn() end, wait = function()
 callback({}, { wrong = true })
 callback(player, { ok = true })
end }
