--!strict
--[[
	Screenshots, so an agent can look at the place instead of inferring it.

	Everything else this server exposes reads the data model: names, properties,
	numbers. None of that answers "does it look right", which for a 3D medium is
	most of the question. A part can sit at the correct position, anchored, the
	right size, and still be inside a wall.

	The path is four steps, none of them optional. `CaptureService` hands back a
	temporary content id rather than pixels; `AssetService` turns that id into an
	EditableImage; the image gives up raw RGBA; and PNG and base64 are written by
	hand because the engine has neither. See Png.luau.
]]

local AssetService = game:GetService("AssetService")
local CaptureService = game:GetService("CaptureService")
local EncodingService = game:GetService("EncodingService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Dispatch = require(script.Parent.Parent.Dispatch)
local Emulation = require(script.Parent.Parent.Emulation)
local Png = require(script.Parent.Parent.Png)

-- Wide enough to read a GUI label, small enough that the encode stays quick and
-- the reply does not dominate the conversation it is part of.
local DEFAULT_WIDTH = 800
local MAX_WIDTH = 1600
local MIN_WIDTH = 160

-- The callback has never taken close to this. It exists so a capture that never
-- calls back fails with something an agent can act on rather than hanging the
-- session until the request deadline.
local CAPTURE_TIMEOUT = 10

-- Zstd level. 3 is its default and already gets most of the win on screen
-- content; the higher levels cost Studio's main thread for a few percent.
local COMPRESSION_LEVEL = 3

local Capture = {}

-- The client is a different machine as far as this plugin is concerned, so the
-- picture has to survive a round trip through a RemoteEvent. Kept smaller than
-- the edit-mode default because that payload has a ceiling and a screenshot
-- nobody can send is worse than a slightly softer one.
local PLAYTEST_MAX_WIDTH = 1000
local PLAYTEST_DEFAULT_WIDTH = 720
local CLIENT_TIMEOUT = 25

--[[
	Screenshots during a playtest, taken by the client because only the client
	may take them.

	`CaptureService:CaptureScreenshot` refuses outright in the playtest's server
	session -- "can only be called on the client" -- and the edit session, which
	could call it, has stopped rendering its own data model and times out. Both
	sessions this plugin can reach are therefore the wrong one, and for a long
	time that was written down here as "screenshots are impossible mid-playtest".

	They are not. The client is reachable the same way `input` reaches it: parent
	a LocalScript into the player's PlayerGui and let it report back over a
	RemoteEvent. The client cannot make HTTP requests, but it does not need to --
	the server session it replicates to already holds an open bridge.

	Everything is done client-side before sending: capture, read, downscale,
	compress. Raw 1080p pixels are eight megabytes and would never fit through a
	remote; compressed and scaled they are tens of kilobytes.
]]
local CLIENT_SOURCE = [==[
local AssetService = game:GetService("AssetService")
local CaptureService = game:GetService("CaptureService")
local EncodingService = game:GetService("EncodingService")

local relay = script
local report = relay:WaitForChild("Report", 10)
if report == nil then
	return
end

local function fail(reason)
	report:FireServer({ ok = false, reason = tostring(reason) })
end

local targetWidth = relay:GetAttribute("Width") or 720

local contentId = nil
local okShot, shotErr = pcall(function()
	CaptureService:CaptureScreenshot(function(id)
		contentId = id
	end)
end)
if not okShot then
	fail(shotErr)
	return
end

local waited = 0
while contentId == nil and waited < 12 do
	task.wait(0.05)
	waited += 0.05
end
if contentId == nil then
	fail("the client did not produce a screenshot within 12s")
	return
end

local okImage, image = pcall(function()
	return AssetService:CreateEditableImageAsync(Content.fromUri(contentId))
end)
if not okImage then
	fail(image)
	return
end

local size = image.Size
local sourceWidth = math.floor(size.X)
local sourceHeight = math.floor(size.Y)

local okPixels, rgba = pcall(function()
	return image:ReadPixelsBuffer(Vector2.zero, size)
end)
if not okPixels then
	fail(rgba)
	return
end

-- Nearest-neighbour, matching Png.downscaleToRgb. Averaging would look better
-- and costs a multiple of the work on the player's own frame budget.
local scale = math.min(1, targetWidth / sourceWidth)
local outWidth = math.max(1, math.floor(sourceWidth * scale))
local outHeight = math.max(1, math.floor(sourceHeight * scale))
local rgb = buffer.create(outWidth * outHeight * 3)

for row = 0, outHeight - 1 do
	local sourceRow = math.min(sourceHeight - 1, math.floor(row / scale))
	local sourceRowBase = sourceRow * sourceWidth * 4
	local targetRowBase = row * outWidth * 3
	for column = 0, outWidth - 1 do
		local sourceColumn = math.min(sourceWidth - 1, math.floor(column / scale))
		local source = sourceRowBase + sourceColumn * 4
		local target = targetRowBase + column * 3
		buffer.writeu8(rgb, target, buffer.readu8(rgba, source))
		buffer.writeu8(rgb, target + 1, buffer.readu8(rgba, source + 1))
		buffer.writeu8(rgb, target + 2, buffer.readu8(rgba, source + 2))
	end
end

local okPacked, packed = pcall(function()
	local compressed = EncodingService:CompressBuffer(rgb, Enum.CompressionAlgorithm.Zstd, 3)
	return buffer.tostring(EncodingService:Base64Encode(compressed))
end)
if not okPacked then
	fail(packed)
	return
end

report:FireServer({
	ok = true,
	data = packed,
	width = outWidth,
	height = outHeight,
	sourceWidth = sourceWidth,
	sourceHeight = sourceHeight,
	rawBytes = buffer.len(rgb),
})
]==]

--[[
	Takes the shot and waits for the id.

	`CaptureService:CaptureScreenshot` answers through a callback rather than
	yielding, so this bridges the two: the handler is already running on its own
	task and is free to wait.
]]
local function takeScreenshot(): string
	local contentId: string? = nil
	local failed: string? = nil

	local ok, err = pcall(function()
		CaptureService:CaptureScreenshot(function(id: string)
			contentId = id
		end)
	end)
	if not ok then
		failed = tostring(err)
	end

	if failed ~= nil then
		Dispatch.fail(
			"CAPTURE_REFUSED",
			string.format("Studio refused to take a screenshot: %s", failed)
		)
	end

	local waited = 0
	while contentId == nil and waited < CAPTURE_TIMEOUT do
		task.wait(0.05)
		waited += 0.05
	end

	if contentId == nil then
		Dispatch.fail(
			"CAPTURE_TIMEOUT",
			string.format("Studio did not return a screenshot within %ds.", CAPTURE_TIMEOUT),
			"The viewport may be hidden or Studio may be busy; try again."
		)
	end

	return contentId :: any
end

--[[
	Runs the capture on the player's client and waits for the pixels to come back.
]]
local function captureViaClient(params: { [string]: any }): { [string]: any }
	local width = math.clamp(
		tonumber(params.width) or PLAYTEST_DEFAULT_WIDTH,
		MIN_WIDTH,
		PLAYTEST_MAX_WIDTH
	)

	local players = Players:GetPlayers()
	if #players == 0 then
		Dispatch.fail(
			"NO_PLAYER",
			"No player is in this session, so there is no client to capture from.",
			"Start a playtest with a character using `playtest op=\"play\"`."
		)
	end
	local player = players[1]
	local playerGui = player:FindFirstChildOfClass("PlayerGui")
	if playerGui == nil then
		Dispatch.fail("NO_PLAYER", string.format("%s has no PlayerGui yet.", player.Name))
	end

	local remote = Instance.new("RemoteEvent")
	remote.Name = "Report"

	local relay = Instance.new("LocalScript")
	relay.Name = "MCPCaptureRelay"
	relay.Source = CLIENT_SOURCE
	relay:SetAttribute("Width", width)
	remote.Parent = relay

	local answer: { [string]: any }? = nil
	local connection = remote.OnServerEvent:Connect(function(_from, payload)
		if typeof(payload) == "table" then
			answer = payload :: { [string]: any }
		end
	end)

	-- Parented last, for the same reason as the input relay: the script runs the
	-- instant it lands and immediately waits on the RemoteEvent.
	relay.Parent = playerGui

	local deadline = os.clock() + CLIENT_TIMEOUT
	while answer == nil and os.clock() < deadline do
		task.wait(0.05)
	end

	connection:Disconnect()
	relay:Destroy()

	if answer == nil then
		Dispatch.fail(
			"CAPTURE_TIMEOUT",
			string.format("The client did not return a screenshot within %ds.", CLIENT_TIMEOUT),
			"A large viewport takes a moment to read and compress; try a smaller `width`."
		)
	end

	local result = answer :: { [string]: any }
	if result.ok ~= true then
		Dispatch.fail("CAPTURE_REFUSED", string.format("The client could not capture: %s", tostring(result.reason)))
	end

	return {
		encoding = "zstd-rgb",
		data = result.data,
		width = result.width,
		height = result.height,
		sourceWidth = result.sourceWidth,
		sourceHeight = result.sourceHeight,
		rawBytes = result.rawBytes,
		bytes = #tostring(result.data),
		context = "playtest client",
		device = Emulation.deviceId(),
	}
end

function Capture.screenshot(params: { [string]: any }): { [string]: any }
	-- Only the client may capture during a playtest, so the work goes there.
	if RunService:IsRunning() and not RunService:IsEdit() then
		return captureViaClient(params)
	end

	local width = math.clamp(tonumber(params.width) or DEFAULT_WIDTH, MIN_WIDTH, MAX_WIDTH)

	local contentId = takeScreenshot()

	local okImage, image = pcall(function()
		return AssetService:CreateEditableImageAsync(Content.fromUri(contentId))
	end)
	if not okImage then
		Dispatch.fail(
			"CAPTURE_UNREADABLE",
			string.format("The screenshot could not be opened for reading: %s", tostring(image))
		)
	end

	local size = (image :: any).Size
	local sourceWidth = math.floor(size.X)
	local sourceHeight = math.floor(size.Y)

	--[[
		Both arguments are required. Called with none it reports "expects 2
		arguments" rather than defaulting to the whole image, which is worth
		stating because every other read on this object takes none.
	]]
	local okPixels, pixels = pcall(function()
		return (image :: any):ReadPixelsBuffer(Vector2.zero, size)
	end)
	if not okPixels then
		Dispatch.fail(
			"CAPTURE_UNREADABLE",
			string.format("The screenshot's pixels could not be read: %s", tostring(pixels))
		)
	end

	local rgb, outWidth, outHeight = Png.downscaleToRgb(pixels, sourceWidth, sourceHeight, width)

	--[[
		Raw pixels, compressed by the engine, assembled into a PNG by Node.

		The plugin used to write the whole PNG itself, and could only write a bad
		one: Studio has no deflate, so `Png.encode` emitted zlib *stored* blocks
		-- the format's "compression not applied" escape hatch -- and every
		screenshot travelled and landed at full uncompressed size. It was also
		base64-ing by hand, a table lookup per byte in Luau.

		`EncodingService` has both, natively. Zstd is the only algorithm the
		engine exposes and PNG cannot use it, so the split is: the plugin
		compresses the pixels for the wire, and Node -- which has real zlib --
		decompresses and writes a properly deflated PNG. The side with the
		compressor does the compressing.

		Guarded rather than assumed: EncodingService is recent, and a Studio
		without it should cost a bigger screenshot, not a failed one.
	]]
	local okPacked, packed = pcall(function()
		local compressed = (EncodingService :: any):CompressBuffer(
			rgb,
			(Enum :: any).CompressionAlgorithm.Zstd,
			COMPRESSION_LEVEL
		)
		return buffer.tostring((EncodingService :: any):Base64Encode(compressed))
	end)

	if okPacked then
		return {
			encoding = "zstd-rgb",
			data = packed,
			width = outWidth,
			height = outHeight,
			sourceWidth = sourceWidth,
			sourceHeight = sourceHeight,
			rawBytes = buffer.len(rgb),
			bytes = #(packed :: string),
			context = if RunService:IsEdit() then "edit" else "playtest",
			device = Emulation.deviceId(),
		}
	end

	local png = Png.encode(rgb, outWidth, outHeight)

	return {
		encoding = "png",
		data = Png.base64(png),
		width = outWidth,
		height = outHeight,
		sourceWidth = sourceWidth,
		sourceHeight = sourceHeight,
		bytes = buffer.len(png),
		-- Which window this came from. A screenshot carries no indication of
		-- whether it shows the editor or a running game, and the two look alike.
		context = if RunService:IsEdit() then "edit" else "playtest",
		device = Emulation.deviceId(),
	}
end

function Capture.register()
	Dispatch.registerAll("capture", {
		screenshot = Capture.screenshot,
	})
end

return Capture
