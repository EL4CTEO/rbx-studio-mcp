local now = 0
local os = { clock = function() return now end }
local timers = {}
local task = {
 delay = function(seconds, fn) local timer = {at = now + seconds, fn = fn}; table.insert(timers, timer); return timer end,
 cancel = function(timer) timer.cancelled = true end,
}
local function advance(seconds)
 now += seconds
 for _, timer in timers do
  if not timer.cancelled and timer.at <= now then timer.cancelled = true; timer.fn() end
 end
end
local function signal()
 local listeners = {}
 return {
  Connect = function(_, fn)
   local connection = {fn = fn, Connected = true}
   connection.Disconnect = function() connection.Connected = false end
   table.insert(listeners, connection)
   return connection
  end,
  Fire = function(_, ...)
   for _, connection in table.clone(listeners) do if connection.Connected then connection.fn(...) end end
  end,
  count = function() local n = 0; for _, c in listeners do if c.Connected then n += 1 end end; return n end,
 }
end
local function object(name, class, parent)
 local value = {Name = name, ClassName = class, Parent = parent, children = {}, attributes = {}, DescendantAdded = signal()}
 value.IsA = function(_, kind) return class == kind end
 value.GetAttribute = function(_, key) return value.attributes[key] end
 value.GetChildren = function() return value.children end
 value.IsDescendantOf = function(_, root)
  local current = value.Parent
  while current do if current == root then return true end; current = current.Parent end
  return false
 end
 if class == "RemoteEvent" then value.OnServerEvent = signal(); value.OnClientEvent = signal() end
 if parent then table.insert(parent.children, value) end
 return value
end
local game = object("game", "DataModel", nil)
local Paths = { of = function(remote) return remote.Name end }
local nativeTypeof = typeof
local typeof = function(value) return if type(value) == "table" and value.ClassName then "Instance" else nativeTypeof(value) end
local alice = {Name = "Alice"}
local bob = {Name = "Bob"}
