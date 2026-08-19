--!strict
--[[
	Wraps every mutation in a ChangeHistoryService recording.

	Two things fall out of this that competing servers do not give you:

	1. One agent action is one Ctrl+Z. A tool that creates 200 parts collapses to
	   a single undo step named after the tool, instead of 200 separate steps or
	   -- worse -- no undo entry at all.
	2. A batch that fails part way through is *cancelled*, not committed. Without
	   this, a `modify` call that sets 5 of 10 properties and then hits a bad
	   value leaves the place in a half-edited state the user has to unpick by
	   hand.

	`SetWaypoint` is deliberately not used; it has been superseded by recordings
	and cannot express the cancel case.
]]

local ChangeHistoryService = game:GetService("ChangeHistoryService")

local Undo = {}

--[[
	Runs `body` inside a named recording and returns its result.

	`TryBeginRecording` returns nil when another recording is already open (for
	example the user is mid-drag in the viewport) or when history is unavailable.
	The work still runs in that case -- refusing to act would be worse than a
	slightly coarser undo stack -- it simply joins the surrounding recording.
]]
function Undo.record<T>(name: string, displayName: string, body: () -> T): T
	local identifier = ChangeHistoryService:TryBeginRecording(name, displayName)
	if not identifier then
		return body()
	end

	local ok, result = pcall(body)
	if ok then
		ChangeHistoryService:FinishRecording(identifier, Enum.FinishRecordingOperation.Commit)
		return result
	end

	ChangeHistoryService:FinishRecording(identifier, Enum.FinishRecordingOperation.Cancel)
	error(result, 0)
end

--[[
	Commits the recording even when `body` fails, for operations whose partial
	effects are still wanted. Used only by handlers that report per-item results
	and therefore tell the agent exactly what did and did not apply.
]]
function Undo.recordPartial<T>(name: string, displayName: string, body: () -> T): T
	local identifier = ChangeHistoryService:TryBeginRecording(name, displayName)
	if not identifier then
		return body()
	end

	local ok, result = pcall(body)
	ChangeHistoryService:FinishRecording(identifier, Enum.FinishRecordingOperation.Commit)
	if not ok then
		error(result, 0)
	end
	return result
end

return Undo
