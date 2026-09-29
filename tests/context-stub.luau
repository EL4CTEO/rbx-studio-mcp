local edit = true
local attrs = {user = "preserved"}
local game = {
 GetService = function() return {IsEdit = function() return edit end} end,
 GetAttribute = function(_, name) return attrs[name] end,
 SetAttribute = function(_, name, value) attrs[name] = value end,
}
