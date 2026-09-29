local available, beginThrows, finishThrows = true, false, false
local open = false
local finishes = {}
local service = {
 TryBeginRecording = function()
  if beginThrows then error("begin failed") end
  if not available or open then return nil end
  open = true; return "recording"
 end,
 FinishRecording = function(_, _, operation)
  open = false
  if finishThrows then error("finish failed") end
  table.insert(finishes, operation)
 end,
 GetCanRedo = function() return false end,
}
local Enum = {FinishRecordingOperation = {Commit = "commit", Cancel = "cancel"}}
local task = {spawn = function(thread) assert(coroutine.resume(thread)) end}
local game = {GetService = function() return service end}
