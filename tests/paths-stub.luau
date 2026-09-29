local nativeTypeof = typeof
local typeof = function(value) return if type(value) == "table" and value.instance then "Instance" else nativeTypeof(value) end
local function instance(name, parent, id)
 local node = {instance = true, Name = name, Parent = parent, id = id or name, children = {}}
 function node:GetChildren() return table.clone(self.children) end
 function node:GetFullName() return self.Name end
 function node:GetDebugId() return self.id end
 function node:FindFirstChild(name) for _, child in self.children do if child.Name == name then return child end end return nil end
 if parent then table.insert(parent.children, node) end
 return node
end
local game = instance("game")
local workspace = instance("Workspace", game)
function game:GetService(name) if name == "Workspace" then return workspace end error("not a service") end
