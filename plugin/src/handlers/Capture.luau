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
local RunService = game:GetService("RunService")

local Dispatch = require(script.Parent.Parent.Dispatch)
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

local Capture = {}

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

function Capture.screenshot(params: { [string]: any }): { [string]: any }
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
	local png = Png.encode(rgb, outWidth, outHeight)

	return {
		data = Png.base64(png),
		width = outWidth,
		height = outHeight,
		sourceWidth = sourceWidth,
		sourceHeight = sourceHeight,
		bytes = buffer.len(png),
		-- Which window this came from. A screenshot carries no indication of
		-- whether it shows the editor or a running game, and the two look alike.
		context = if RunService:IsEdit() then "edit" else "playtest",
	}
end

function Capture.register()
	Dispatch.registerAll("capture", {
		screenshot = Capture.screenshot,
	})
end

return Capture
