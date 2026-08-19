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
local Net = require(script.Parent.Net)

local Transport = {}

export type Status = "disconnected" | "connecting" | "connected"

type Callbacks = {
	onCommand: (id: string, op: string, params: { [string]: any }?) -> (),
	onStatus: (status: Status, detail: string?) -> (),
}

local running = false
local studioId: string = ""
local activeStream: any = nil
local mode: "sse" | "poll" = "sse"

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
		transport = transport,
	}
end

--[[
	Parses one SSE payload. `MessageReceived` hands over the event data, but the
	exact framing is not contractual, so a stray `data:` prefix is tolerated and
	comment/keepalive lines are dropped.
]]
local function parseFrame(message: string): { [string]: any }?
	local text = (string.gsub(message, "^%s+", ""))
	if text == "" or string.sub(text, 1, 1) == ":" then
		return nil
	end
	if string.sub(text, 1, 5) == "data:" then
		text = (string.gsub(string.sub(text, 6), "^%s+", ""))
	end
	local decoded = Net.decode(text)
	if typeof(decoded) ~= "table" then
		return nil
	end
	return decoded
end

local function handleFrame(callbacks: Callbacks, frame: { [string]: any })
	local id = frame.id
	local op = frame.op
	if typeof(id) == "string" and typeof(op) == "string" then
		callbacks.onCommand(id, op, frame.params)
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
			local frame = parseFrame(message)
			if frame then
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
]]
local function runPolling(callbacks: Callbacks)
	mode = "poll"
	local handshake = Net.postJson("/connect", identity("poll"))
	if not handshake.ok then
		callbacks.onStatus("disconnected", handshake.error or "handshake failed")
		return
	end
	callbacks.onStatus("connected", "polling")

	while running do
		local response = Net.request("GET", "/poll?studioId=" .. studioId)
		if not running then
			return
		end

		if response.statusCode == 409 then
			-- The server restarted and no longer knows us; re-handshake.
			local retry = Net.postJson("/connect", identity("poll"))
			if not retry.ok then
				callbacks.onStatus("disconnected", retry.error or "reconnect failed")
				return
			end
		elseif not response.ok then
			callbacks.onStatus("disconnected", response.error or "poll failed")
			return
		else
			local payload = Net.decode(response.body)
			if typeof(payload) == "table" and typeof(payload.command) == "table" then
				handleFrame(callbacks, payload.command)
			end
		end
	end
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

			local streamed = supportsWebStream() and runStream(callbacks)
			if running and not streamed then
				runPolling(callbacks)
			end

			if not running then
				break
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
