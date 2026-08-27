--!strict
--[[
	Command channel between the bridge and this Studio instance.

	Preferred path is a single Server-Sent Events stream opened with
	`HttpService:CreateWebStreamClient`, which pushes commands the moment they are
	issued. Every other Roblox Studio MCP server long-polls on a fixed interval,
	which adds half the poll period to every single call and keeps a request in
	flight forever; a stream costs nothing while idle.

	Studio allows only 4 concurrent web stream connections and closes them after
	30 minutes, so exactly one stream is held and reconnects are treated as
	routine. Where web streams are unavailable (older Studio builds, or the 4
	slots being taken by other plugins) the same command loop runs over long-poll
	instead, and neither the server nor the handlers can tell the difference.
]]

local HttpService = game:GetService("HttpService")

local Config = require(script.Parent.Config)
local Context = require(script.Parent.Context)
local Net = require(script.Parent.Net)

local Transport = {}

export type Status = "disconnected" | "connecting" | "connected"

type Callbacks = {
	onCommand: (id: string, op: string, params: { [string]: any }?) -> (),
	onStatus: (status: Status, detail: string?) -> (),
	--[[
		Anything the bridge wants to tell this plugin that is not a command.

		The stream was one-way in practice -- commands down, results back over a
		separate POST -- and there was no way for the server to say something the
		plugin should merely know, like how many agents are now sharing it. A
		frame carrying `event` instead of `id`/`op` is that channel.

		No protocol bump: a plugin older than this drops any frame without an id
		and an op, which is exactly the right behaviour for a frame it does not
		understand.
	]]
	onEvent: (event: { [string]: any }) -> (),
}

local running = false
local studioId: string = ""
local activeStream: any = nil
local mode: "sse" | "poll" = "sse"

--[[
	Forces the long-poll path even where streaming is available.

	Two reasons it is worth being able to ask for the slower transport. Studio
	caps SSE at four concurrent connections for the whole process, shared with
	every other plugin the user has installed, so a session can find itself
	unable to open a stream through no fault of its own -- and being able to say
	"just poll" beats discovering that as an intermittent failure to connect.

	The other is honesty: this project's headline claim is that pushing beats
	polling, and a claim like that should be checkable by whoever doubts it, on
	their own machine, without patching the source to see the other number.
]]
local forcePoll = false

--[[
	True when this Studio build exposes web streams. Guarded rather than assumed:
	the API shipped in August 2025 and users on older builds must still work.
]]
local function supportsWebStream(): boolean
	if typeof((HttpService :: any).CreateWebStreamClient) ~= "function" then
		return false
	end
	local ok, enumItem = pcall(function()
		return (Enum :: any).WebStreamClientType.SSE
	end)
	return ok and enumItem ~= nil
end

local function identity(transport: string): { [string]: any }
	return {
		studioId = studioId,
		placeName = if game.Name ~= "" then game.Name else "Untitled place",
		placeId = game.PlaceId,
		pluginVersion = Config.PLUGIN_VERSION,
		buildId = Config.BUILD_ID,
		-- Alongside buildId rather than instead of it: buildId catches a plugin
		-- left running an older *behaviour*, this catches the wire *shape*
		-- changing under it. Compared server-side the same way buildId is, so a
		-- mismatch surfaces through studio_status instead of failing silently
		-- the next time PROTOCOL_VERSION actually moves.
		protocolVersion = Config.PROTOCOL_VERSION,
		transport = transport,
		-- Announced at the handshake rather than left for a later status call.
		-- The ambiguity error that forces someone to choose between two rows
		-- with the same place name is raised before any such call could have
		-- run, so without this it lists them with nothing to choose between.
		context = Context.of(),
	}
end

--[[
	Parses one delivery from the stream, which may hold more than one event.

	This used to assume one event per `MessageReceived` and decode the whole
	payload as a single JSON object. That held only because the bridge had never
	written two frames in the same tick -- and the moment it did, both were lost:
	the two writes arrived in one chunk, so the decode saw
	`{...}<blank>data: {...}` and returned nil for the pair. The visible symptom
	was a client-count badge that went up and never came back down. The invisible
	one is why this is written properly rather than patched around: nothing stops
	a *command* from sharing a chunk with anything else, and a dropped command is
	a tool call that disappears with no error on either side.

	So the payload is split into events on blank lines, and each event's `data:`
	lines are concatenated the way the SSE spec says they should be. Comments --
	the `: connected` greeting and the `: ping` keepalives -- are skipped rather
	than being allowed to poison the block they arrive with.
]]
local function parseFrames(message: string): { { [string]: any } }
	local frames: { { [string]: any } } = {}

	-- Normalised so one split handles either line ending.
	local normalised = (string.gsub(message, "\r\n", "\n"))

	-- The appended separator gives every event, the last one included, a
	-- trailing blank line, so a single pattern finds them all.
	for block in string.gmatch(normalised .. "\n\n", "(.-)\n\n") do
		local payload: string? = nil
		for line in string.gmatch(block, "[^\n]+") do
			if string.sub(line, 1, 1) ~= ":" then
				local value = line
				if string.sub(value, 1, 5) == "data:" then
					value = (string.gsub(string.sub(value, 6), "^%s+", ""))
				end
				-- Several data lines in one event concatenate, per the spec.
				payload = if payload == nil then value else payload .. "\n" .. value
			end
		end

		if payload ~= nil and payload ~= "" then
			local decoded = Net.decode(payload)
			if typeof(decoded) == "table" then
				table.insert(frames, decoded)
			end
		end
	end

	return frames
end

local function handleFrame(callbacks: Callbacks, frame: { [string]: any })
	local id = frame.id
	local op = frame.op
	if typeof(id) == "string" and typeof(op) == "string" then
		callbacks.onCommand(id, op, frame.params)
		return
	end
	if typeof(frame.event) == "string" then
		callbacks.onEvent(frame)
	end
end

--[[
	Opens the stream and blocks until it closes. Returns false when the stream
	could not be opened at all, which is the signal to fall back to long-poll.
]]
local function runStream(callbacks: Callbacks): boolean
	local opened = false

	local ok, client = pcall(function()
		return (HttpService :: any):CreateWebStreamClient((Enum :: any).WebStreamClientType.SSE, {
			Url = Config.baseUrl() .. "/events",
			Method = "POST",
			Headers = Config.headers(),
			Body = HttpService:JSONEncode(identity("sse")),
		})
	end)

	if not ok or client == nil then
		return false
	end

	activeStream = client
	local connections: { RBXScriptConnection } = {}

	table.insert(
		connections,
		client.Opened:Connect(function(statusCode: number)
			if statusCode == 200 then
				opened = true
				mode = "sse"
				callbacks.onStatus("connected", "streaming")
			end
		end)
	)

	table.insert(
		connections,
		client.MessageReceived:Connect(function(message: string)
			for _, frame in parseFrames(message) do
				handleFrame(callbacks, frame)
			end
		end)
	)

	local streamError: string? = nil
	table.insert(
		connections,
		client.Error:Connect(function(statusCode: number, errorMessage: string)
			streamError = string.format("stream error %d: %s", statusCode, tostring(errorMessage))
		end)
	)

	client.Closed:Wait()
	for _, connection in connections do
		connection:Disconnect()
	end
	activeStream = nil

	if not opened then
		callbacks.onStatus("disconnected", streamError or Net.explain("could not connect"))
		return false
	end
	callbacks.onStatus("disconnected", "stream closed")
	return true
end

--[[
	Long-poll fallback. The bridge parks each request for ~25s and answers with a
	command or an idle marker, so this is a blocking wait rather than a busy loop.

	Returns true when it is giving way so streaming can be tried again.

	That return exists because this loop used to have no exit while it was
	succeeding, which quietly made the fallback permanent: streaming is only
	attempted when a connection is being established, so a single failed attempt
	-- Studio's four-stream cap being momentarily full, or the bridge restarting
	at the wrong instant -- dropped the session onto long-poll for as long as it
	stayed connected. Nothing reported it, because polling works; it is just
	slower, which is precisely the thing this project claims to fix. Both windows
	of this session were found sitting on poll with no error anywhere.
]]
local function runPolling(callbacks: Callbacks): boolean
	mode = "poll"
	local handshake = Net.postJson("/connect", identity("poll"))
	if not handshake.ok then
		callbacks.onStatus("disconnected", handshake.error or "handshake failed")
		return false
	end
	callbacks.onStatus("connected", "polling")

	local retryStreamAt = os.clock() + Config.RESTREAM_INTERVAL

	while running do
		local response = Net.request("GET", "/poll?studioId=" .. studioId)
		if not running then
			return false
		end

		if response.statusCode == 409 then
			-- The server restarted and no longer knows us; re-handshake.
			local retry = Net.postJson("/connect", identity("poll"))
			if not retry.ok then
				callbacks.onStatus("disconnected", retry.error or "reconnect failed")
				return false
			end
		elseif not response.ok then
			callbacks.onStatus("disconnected", response.error or "poll failed")
			return false
		else
			local payload = Net.decode(response.body)
			if typeof(payload) == "table" then
				if typeof(payload.command) == "table" then
					handleFrame(callbacks, payload.command)
				end
				--[[
					Poll sessions get the same news, riding on the answer they were
					already waiting for. The bridge has nowhere to push to here, so
					every poll response carries the current value rather than only
					the moments it changed -- the console filters out the repeats,
					and a poll session that missed a change while it was handling a
					command would otherwise never hear about it.
				]]
				if typeof(payload.clients) == "number" then
					callbacks.onEvent({ event = "clients", count = payload.clients })
				end
			end
		end

		-- Checked after handling rather than before waiting, so the handover
		-- happens between commands instead of while one is outstanding.
		if os.clock() >= retryStreamAt then
			return true
		end
	end
	return false
end

--[[
	Posts a command result. Fire-and-forget: if it fails the server's own timeout
	will surface an actionable error to the agent, and retrying here would risk
	answering a request that has already been abandoned.
]]
function Transport.sendResult(result: { [string]: any })
	task.spawn(function()
		Net.postJson("/result?studioId=" .. studioId, result)
	end)
end

function Transport.getMode(): string
	return mode
end

function Transport.getForcePoll(): boolean
	return forcePoll
end

--[[
	Takes effect on the next connection, not this one: the change has to happen
	between commands, and tearing the stream down from inside a handler would
	strand the reply to the very call that asked for it.
]]
function Transport.setForcePoll(value: boolean)
	forcePoll = value
end

function Transport.isRunning(): boolean
	return running
end

--[[
	Connects and keeps reconnecting until `stop` is called. Backs off on repeated
	failure so a server that is simply not running does not spin the CPU.
]]
function Transport.start(id: string, callbacks: Callbacks)
	if running then
		return
	end
	running = true
	studioId = id

	task.spawn(function()
		local delay = Config.RECONNECT_DELAY
		while running do
			callbacks.onStatus("connecting")

			local streamed = not forcePoll and supportsWebStream() and runStream(callbacks)
			local upgrading = false
			if running and not streamed then
				upgrading = runPolling(callbacks)
			end

			if not running then
				break
			end

			-- Polling was healthy and stood aside to let streaming be retried.
			-- The backoff exists to slow down repeated failures, and this is not
			-- one, so go straight back round.
			if upgrading then
				delay = Config.RECONNECT_DELAY
				continue
			end

			task.wait(delay)
			delay = math.min(delay * 2, Config.MAX_RECONNECT_DELAY)
			-- A connection that lasted long enough to do real work resets the
			-- backoff; only repeated fast failures should slow retries down.
			if activeStream ~= nil then
				delay = Config.RECONNECT_DELAY
			end
		end
	end)
end

function Transport.stop()
	if not running then
		return
	end
	running = false
	pcall(function()
		Net.postJson("/bye?studioId=" .. studioId, {})
	end)
	if activeStream then
		pcall(function()
			activeStream:Close()
		end)
		activeStream = nil
	end
end

return Transport
