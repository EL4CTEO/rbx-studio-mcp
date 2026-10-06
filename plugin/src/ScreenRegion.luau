--!strict
-- Screen bounds shared by editor captures and actual-client captures.
local Dispatch = require(script.Parent.Dispatch)
local Paths = require(script.Parent.Paths)
local REGION_PADDING = 0.08
local ScreenRegion = {}
-- ScreenGui AbsolutePosition uses CoreUISafeInsets even when IgnoreGuiInset
-- is true. Translate its origin to full viewport pixels in both cases.
function ScreenRegion.position(target: GuiObject): Vector2
	local screen = target:FindFirstAncestorWhichIsA("ScreenGui")
	local inset = if screen
		then game:GetService("GuiService"):GetGuiInset() else Vector2.zero
	return target.AbsolutePosition + inset
end
local function boundsOf(target: Instance): (Vector2, Vector2)
	if target:IsA("GuiObject") then
		local position = ScreenRegion.position(target)
		return position, position + target.AbsoluteSize
	end

	local cframe: CFrame, size: Vector3
	if target:IsA("BasePart") then
		cframe, size = target.CFrame, target.Size
	elseif target:IsA("Model") then
		cframe, size = target:GetBoundingBox()
	else
		local low, high = Vector3.one * math.huge, -Vector3.one * math.huge
		local counted = 0
		for _, descendant in target:GetDescendants() do
			if descendant:IsA("BasePart") then
				local half = descendant.Size / 2
				for _, corner in { Vector3.new(-1, -1, -1), Vector3.new(1, 1, 1), Vector3.new(-1, 1, -1), Vector3.new(1, -1, 1) } do
					local point = descendant.CFrame:PointToWorldSpace(half * corner)
					low, high = low:Min(point), high:Max(point)
				end
				counted += 1
				if counted >= 2000 then
					break
				end
			end
		end
		if counted == 0 then
			Dispatch.fail(
				"NOT_VISUAL",
				string.format("%s has no GUI or parts to zoom to.", target:GetFullName()),
				"Zoom to a GuiObject, a BasePart, a Model, or a folder containing parts."
			)
		end
		cframe, size = CFrame.new((low + high) / 2), high - low
	end

	local camera = workspace.CurrentCamera
	local low, high = Vector2.one * math.huge, -Vector2.one * math.huge
	for _, sx in { -1, 1 } do
		for _, sy in { -1, 1 } do
			for _, sz in { -1, 1 } do
				local point, _ = camera:WorldToViewportPoint(cframe:PointToWorldSpace(size / 2 * Vector3.new(sx, sy, sz)))
				if point.Z <= 0 then
					Dispatch.fail(
						"REGION_OFFSCREEN",
						string.format("%s is partly behind the camera.", target:GetFullName()),
						"Aim the camera at it first with `viewport op=\"focus\"`, then take the screenshot."
					)
				end
				local flat = Vector2.new(point.X, point.Y)
				low, high = low:Min(flat), high:Max(flat)
			end
		end
	end
	return low, high
end

--[[
	The part of the capture to keep, in capture pixels.

	`path` zooms to an instance; `rect` is "x, y, width, height" in the pixels of
	the full-resolution capture, which every screenshot caption states. A path
	is resolved before the capture, so a bad one fails without taking it.
]]
local function regionFor(params: { [string]: any }): { [string]: any }?
	if typeof(params.rect) == "string" and params.rect ~= "" then
		local numbers = {}
		for token in string.gmatch(params.rect, "-?[%d%.]+") do
			table.insert(numbers, tonumber(token))
		end
		if #numbers ~= 4 or numbers[3] <= 0 or numbers[4] <= 0 then
			Dispatch.fail("BAD_PARAMS", 'rect must be "x, y, width, height", e.g. "400, 200, 320, 180".')
		end
		return { x = numbers[1], y = numbers[2], width = numbers[3], height = numbers[4] }
	end

	if typeof(params.path) ~= "string" or params.path == "" then
		return nil
	end
	local target = Paths.resolve(params.path)
	local low, high = boundsOf(target)
	local extent = high - low
	local pad = Vector2.new(math.max(8, extent.X * REGION_PADDING), math.max(8, extent.Y * REGION_PADDING))
	low, high = low - pad, high + pad
	return {
		x = low.X,
		y = low.Y,
		width = high.X - low.X,
		height = high.Y - low.Y,
		viewportWidth = workspace.CurrentCamera.ViewportSize.X,
	}
end

ScreenRegion.of = regionFor
ScreenRegion.bounds = boundsOf
return ScreenRegion
