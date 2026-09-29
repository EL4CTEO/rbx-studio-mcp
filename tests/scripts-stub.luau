local scripts = {}
local reads, writes = 0, 0
local beforeWrite = nil
local function container(path, source)
 local node = {Name = path, ClassName = "ModuleScript", Source = source}
 function node:GetFullName() return path end
 function node:IsA(class) return class == "LuaSourceContainer" or class == self.ClassName end
 function node:GetDescendants() return {} end
 scripts[path] = node; return node
end
local a = container("A", "local one = 1\nreturn one")
local b = container("B", "local two = 2\nreturn two")
local game = {GetDescendants = function() return {b, a} end, IsA = function() return false end}
local function encode(value)
 if type(value) == "table" then local parts = {}; for key, item in value do table.insert(parts, encode(key) .. ":" .. encode(item)) end return "{" .. table.concat(parts, ",") .. "}" end
 return string.format("%q", tostring(value))
end
function game:GetService() return {JSONEncode = function(_, value) return encode(value) end} end
local Paths = {resolve = function(path) return assert(scripts[path]) end, of = function(node) return node.Name end}
local Scope = {isNoisy = function() return false end}
local ScriptEdit = {
 read = function(node) reads += 1; return node.Source end,
 isScript = function(node) return node:IsA("LuaSourceContainer") end,
 write = function(node, transform)
  writes += 1
  if beforeWrite then beforeWrite(node, writes) end
  node.Source = transform(node.Source)
 end,
}
local Undo = {exclusive = function(fn) return fn() end}
