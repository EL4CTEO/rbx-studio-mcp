local realTypeof = typeof
local typeof = function(value) return if type(value) == "table" and value.__instance then "Instance" else realTypeof(value) end
local game = {Name = "game", __instance = true, GetService = function(_, name)
	if name == "HttpService" then return HttpService end
	return nil
end}
local flip = false
local function instance(name, parent)
	local item = {Name = name, __instance = true, Parent = parent, children = {}}
	if parent then table.insert(parent.children, item) end
	function item:GetChildren()
		flip = not flip
		local out = table.clone(self.children)
		if flip then for a = 1, math.floor(#out / 2) do local b = #out - a + 1; out[a], out[b] = out[b], out[a] end end
		return out
	end
	function item:FindFirstChild(wanted)
		for _, child in self.children do if child.Name == wanted then return child end end
		return nil
	end
	function item:GetDebugId() error("PluginSecurity required") end
	function item:GetFullName() return if self.Parent and self.Parent ~= game then self.Parent:GetFullName() .. "." .. self.Name else self.Name end
	function item:IsDescendantOf(root)
		local node = self.Parent
		while node do if node == root then return true end; node = node.Parent end
		return false
	end
	return item
end
game.children = {}
game.GetChildren = function() return table.clone(game.children) end
game.FindFirstChild = function(_, name) for _, child in game.children do if child.Name == name then return child end end; return nil end
local workspace = instance("Workspace", game)
local first = instance("Part", workspace)
local second = instance("Part", workspace)
local dot = instance("Dr. Who", workspace)
local shadow = instance("Dr", workspace)
local head = instance("Head", dot)
