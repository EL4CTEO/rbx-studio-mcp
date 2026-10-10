local now = 0
local os = {clock = function() return now end}
local all = {}
local running = true
local game = {GetService = function() return {IsRunning = function() return running end} end}
local function vec(x, y, z) return {X = x, Y = y, Z = z, Magnitude = math.sqrt(x * x + y * y + z * z)} end
local typeof = function(value) if type(value) == "table" and value.isInstance then return "Instance" end return type(value) end
local function part(name, children)
	local self = {isInstance = true, Name = name, children = children or {}, binds = {}}
	function self:IsA(class) return class == "BasePart" end
	function self:GetDescendants() return self.children end
	function self:BindToCollisionSummaries(callback)
		local connection = {active = true, Disconnect = function(c) c.active = false end}
		table.insert(all, connection)
		self.binds[connection] = callback
		return connection
	end
	function self:fire(summaries)
		for connection, callback in self.binds do if connection.active then callback(summaries) end end
	end
	return self
end
local wall, floor = part("Wall"), part("Floor")
local ball = part("Ball", {part("Fin")})
local target = ball
local Paths = {resolve = function() return target end, of = function(instance) return "Workspace." .. instance.Name end}
local task = {wait = function() now += 0.05 end}
local tick = function() end
local original = task.wait
task.wait = function() original(); tick() end
