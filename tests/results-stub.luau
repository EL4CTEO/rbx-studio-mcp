local now = 0
local os = { clock = function() return now end }
local game = { GetService = function() return HttpService end }
local Serialize = { value = function(value) return value end }
