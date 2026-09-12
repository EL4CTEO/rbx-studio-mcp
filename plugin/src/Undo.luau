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
	One recording at a time, per session.

	`onCommand` runs every command on its own task so a slow handler cannot
	stall the stream, which is right -- and it means two agents pointed at the
	same edit session have their batches in flight at once. Nothing below this
	line is safe under that. `TryBeginRecording` returns nil while another
	recording is open, so the second batch would run with no recording of its
	own: its changes land inside the FIRST batch's undo step, one Ctrl+Z reverts
	both, and if the first batch fails its `Cancel` reverts the second agent's
	work as well -- work that was already reported as done.

	Today's handlers do not yield inside a recording, so Luau's cooperative
	scheduling hides all of that. That is an accident of how they happen to be
	written, not a property of the design: the first `*Async` call added inside
	a `record` body would open the window silently, and the symptom would be a
	rolled-back edit in someone else's session. So the guarantee is made
	structural here instead of being left to every handler to preserve.

	Mutations queue; reads never come through this file at all, so they stay
	parallel. Uncontended -- the normal case, one agent -- this costs one
	boolean test.
]]
local held = false
local owner: thread? = nil
local waiting: { thread } = {}

local function acquire()
	--[[
		A recording opened inside another recording is the same thread, and
		waiting for a lock it already holds would hang the session outright.
		Nesting is not used today; this makes adding it a coarser undo step
		rather than a deadlock.
	]]
	if held and owner == coroutine.running() then
		return false
	end

	if held then
		table.insert(waiting, coroutine.running())
		-- Resumed by `release`, which hands the lock over rather than dropping
		-- it, so there is nothing to re-check on the way out.
		coroutine.yield()
		return true
	end

	held = true
	owner = coroutine.running()
	return true
end

local function release(acquired: boolean)
	if not acquired then
		return
	end

	local nextThread = table.remove(waiting, 1)
	if nextThread == nil then
		held = false
		owner = nil
		return
	end

	-- `held` deliberately stays true: the lock passes straight to the waiter,
	-- so a command arriving in between cannot jump the queue.
	owner = nextThread
	task.spawn(nextThread)
end

--[[
	Drops the redo entry a cancelled recording leaves behind.

	`Cancel` reverts the values but Studio still files the recording on the REDO
	stack, so a batch this server reported as "nothing was changed, the whole
	batch was rolled back" was one Ctrl+Y away from coming back -- as exactly the
	half-applied state the cancel existed to prevent. Measured: a `modify` that
	set Material on two parts and then hit a bad Size left `GetCanRedo` true, and
	a single redo re-applied both Materials.

	There is no API to pop one redo entry, but an ordinary undo stack discards
	the redo branch as soon as a new action is committed -- and an EMPTY
	recording counts as that action while adding no undo step of its own
	(measured: after the empty commit, one undo still reached the change made
	before the cancelled batch). So the cheapest correct fix is to commit
	nothing.
]]
local function dropRedo()
	if not ChangeHistoryService:GetCanRedo() then
		return
	end
	local identifier = ChangeHistoryService:TryBeginRecording("MCPFlushRedo", "MCP")
	if identifier == nil then
		return
	end
	ChangeHistoryService:FinishRecording(identifier, Enum.FinishRecordingOperation.Commit)
end

--[[
	Runs `body` inside a named recording. Returns its result, and whether a
	recording was actually opened.

	`TryBeginRecording` returns nil when a recording is already open or when
	history is unavailable. Since the lock above, that can no longer be another
	MCP batch: it is Studio's own, the user mid-drag in the viewport. The work
	still runs in that case -- refusing to act would be worse than a slightly
	coarser undo stack -- it simply joins the surrounding recording, and the lock
	is still held throughout so the batch stays whole.

	That second return value is not decoration. Whether an operation is undoable
	is something tools tell the agent, and therefore the user, so it has to be
	observed rather than assumed: a claim of "one Ctrl+Z" that silently degrades
	to no undo entry at all is worse than no claim.
]]
function Undo.record<T>(name: string, displayName: string, body: () -> T): (T, boolean)
	local acquired = acquire()

	local identifier = ChangeHistoryService:TryBeginRecording(name, displayName)
	if not identifier then
		local ok, result = pcall(body)
		release(acquired)
		if not ok then
			error(result, 0)
		end
		return result, false
	end

	local ok, result = pcall(body)
	if ok then
		ChangeHistoryService:FinishRecording(identifier, Enum.FinishRecordingOperation.Commit)
		release(acquired)
		return result, true
	end

	ChangeHistoryService:FinishRecording(identifier, Enum.FinishRecordingOperation.Cancel)
	dropRedo()
	release(acquired)
	error(result, 0)
end

--[[
	Commits the recording even when `body` fails, for operations whose partial
	effects are still wanted. Used only by handlers that report per-item results
	and therefore tell the agent exactly what did and did not apply.
]]
function Undo.recordPartial<T>(name: string, displayName: string, body: () -> T): (T, boolean)
	local acquired = acquire()

	local identifier = ChangeHistoryService:TryBeginRecording(name, displayName)
	if not identifier then
		local ok, result = pcall(body)
		release(acquired)
		if not ok then
			error(result, 0)
		end
		return result, false
	end

	local ok, result = pcall(body)
	ChangeHistoryService:FinishRecording(identifier, Enum.FinishRecordingOperation.Commit)
	release(acquired)
	if not ok then
		error(result, 0)
	end
	return result, true
end

return Undo
