local listener
local disconnected = false
local game = { GetService = function(_, name) if name == "HttpService" then return HttpService end; return { MessageOut = { Connect = function(_, fn)
 listener = fn
 return { Disconnect = function() disconnected = true end }
end } } end }
local Serialize = { value = function(value) return value end }
local LogBuffer = { encodeContext = function(context) return if type(context) == "table" and next(context) ~= nil then "{ctx}" else nil end }
local Enum = { MessageType = { MessageError = "error", MessageWarning = "warning" } }
local now = 0
local os = { clock = function() return now end }
local cancelled = false
local task = {
 wait = function() now += 0.05 end,
 spawn = function(fn) local thread = coroutine.create(fn); assert(coroutine.resume(thread)); return thread end,
 cancel = function(thread) cancelled = true; coroutine.close(thread) end,
}
