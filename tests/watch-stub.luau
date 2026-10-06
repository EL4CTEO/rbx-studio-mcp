local now = 0
local os = {clock = function() return now end}
local all = {}
local function signal()
	local listeners = {}
	local event = {Connect = function(_, callback)
		local connection = {active = true, Disconnect = function(self) self.active = false end}
		listeners[connection] = callback
		table.insert(all, connection)
		return connection
	end}
	function event:fire(...)
		for connection, callback in listeners do if connection.active then callback(...) end end
	end
	return event
end
local changed = signal()
local target = {Name = "Watched", Value = 1, attributes = {Ready = false},
	AttributeChanged = signal(), ChildAdded = signal(), ChildRemoved = signal(), Destroying = signal()}
function target:GetPropertyChangedSignal(name) assert(name == "Value"); return changed end
function target:GetAttributes() return table.clone(self.attributes) end
function target:GetAttribute(name) return self.attributes[name] end
function target:GetChildren() return {} end
local Paths = {resolve = function() return target end, of = function() return "Workspace.Watched" end, handle = function() return "@handle" end}
local Serialize = {value = function(value) return value end}
local game = {GetService = function() return HttpService end}
local tick = function()
	target.Value += 1
	changed:fire()
	target.attributes.Ready = true
	target.AttributeChanged:fire("Ready")
end
local task = {wait = function() now += 0.05; tick() end}
