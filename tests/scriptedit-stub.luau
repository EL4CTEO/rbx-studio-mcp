local writes = 0
local onWait = nil
local onUpdate = nil
local opened = true
local task = {wait = function() if onWait then onWait() end end}
local editor = {
 GetEditorSource = function(_, target) return target.Source end,
 FindScriptDocument = function() return if opened then {} else nil end,
 UpdateSourceAsync = function(_, target, callback)
  writes += 1
  if onUpdate then onUpdate(target, callback) else target.Source = callback(target.Source) end
 end,
}
local game = {GetService = function() return editor end}
local target = {Source = "before", GetFullName = function() return "Test" end}
