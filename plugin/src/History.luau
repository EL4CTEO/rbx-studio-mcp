--!strict
--[[
	The console log, carried across the boundaries that used to erase it.

	Pressing Play does not pause this plugin, it loads a second and a third copy
	of it into the playtest's DataModels, each with its own empty console. Studio
	then shows you the play view's panel, so the session you were watching
	appears to have been wiped; stopping the test shows the editor's again, and
	everything that happened during the test is missing from it instead. Nothing
	crashed and nothing was lost -- the log was simply written in a window that is
	no longer the one on screen.

	Two halves fix that, and they are deliberately different mechanisms because
	the two directions have different problems.

	Forwards (editor -> playtest) is a cold start: the playtest's copies begin
	with nothing and need what was already on screen. That is persistence, and it
	is what this file does -- the edit session writes its rows to plugin
	settings, and every copy reads them once at load.

	Backwards (playtest -> editor) is not persistence at all. The editor session
	is still running the whole time; it just is not the one being asked to do the
	work. So there is nothing to restore, only something to be told, and it is
	told over the bridge -- see `announceToPeers` in the server's rpc.ts.

	Only the EDIT session writes. It is the one that outlives every playtest and
	receives the peer announcements, so its log is the superset; letting the
	playtest copies write as well would store the same rows twice and replay both
	on the next load.
]]

local History = {}

local SETTING = "consoleHistory"

--[[
	Rows kept, well under the console's own 300.

	This is a settings file, rewritten in full on every save, and the value of an
	old row falls off quickly -- what you want back is the screenful you were
	looking at when the playtest started, not yesterday afternoon.
]]
local MAX_ROWS = 150

--[[
	Seconds between saves.

	A burst of commands writes several rows a second and every one of them would
	otherwise be a rewrite of the whole file. The loss window is the same two
	seconds, and the only way to lose that window is to close Studio inside it --
	which `flush` covers anyway.
]]
local SAVE_EVERY = 2

export type Row = {
	level: string,
	message: string,
	detail: string?,
	stamp: string,
}

local store: Plugin? = nil
local read: (() -> { Row })? = nil
local dirty = false
local running = false

--[[
	Which place this log belongs to.

	One settings file is shared by every Studio window on the machine, so without
	a key a second place's session would read back the first's history and show
	it as its own. An unsaved place has no id, so its name stands in -- imperfect
	between two unsaved places, and better than merging them.
]]
local function placeKey(): string
	if game.PlaceId ~= 0 then
		return tostring(game.PlaceId)
	end
	return "local:" .. game.Name
end

--[[
	Rows survive a round trip through JSON, so nothing that comes back is
	trusted: a settings file is a file on disk, and a field that is missing or
	the wrong type must skip the row rather than reach the renderer.
]]
local function sane(value: any): Row?
	if typeof(value) ~= "table" then
		return nil
	end
	local row = value :: { [string]: any }
	if typeof(row.level) ~= "string" or typeof(row.message) ~= "string" then
		return nil
	end
	if typeof(row.stamp) ~= "string" then
		return nil
	end
	return {
		level = row.level,
		message = row.message,
		detail = if typeof(row.detail) == "string" then row.detail else nil,
		stamp = row.stamp,
	}
end

--[[
	`snapshot` is a function rather than rows, because saving is throttled: what
	must be written is whatever the console holds when the timer fires, not what
	it held when the row that triggered it was logged.
]]
function History.attach(pluginObject: Plugin, snapshot: () -> { Row })
	store = pluginObject
	read = snapshot
end

function History.restore(): { Row }
	local pluginObject = store
	if pluginObject == nil then
		return {}
	end
	local saved = pluginObject:GetSetting(SETTING)
	if typeof(saved) ~= "table" then
		return {}
	end
	local record = saved :: { [string]: any }
	if record.place ~= placeKey() or typeof(record.rows) ~= "table" then
		return {}
	end
	local rows: { Row } = {}
	for _, entry in record.rows :: { any } do
		local row = sane(entry)
		if row ~= nil then
			table.insert(rows, row)
		end
	end
	return rows
end

--[[
	Writes now. Called from the save loop and from `plugin.Unloading`, where
	there is no next tick to wait for.
]]
function History.flush()
	local pluginObject, snapshot = store, read
	if pluginObject == nil or snapshot == nil then
		return
	end
	dirty = false
	local rows = snapshot()
	while #rows > MAX_ROWS do
		table.remove(rows, 1)
	end
	-- Guarded because a settings write is disk I/O: a full disk or a locked file
	-- must cost the console its history, not its session.
	pcall(function()
		pluginObject:SetSetting(SETTING, { place = placeKey(), rows = rows })
	end)
end

-- Marks the log as changed. Cheap on purpose: it runs on every logged row.
function History.touch()
	dirty = true
end

--[[
	Starts the save loop. Owned here rather than by the caller so the throttle
	and the thing it throttles cannot drift apart.
]]
function History.start()
	running = true
	task.spawn(function()
		while running do
			task.wait(SAVE_EVERY)
			if running and dirty then
				History.flush()
			end
		end
	end)
end

-- Stops the loop on unload. A reloaded plugin is a fresh module, so without
-- this every reload would leave another timer running against a dead session.
function History.stop()
	running = false
end

return History
