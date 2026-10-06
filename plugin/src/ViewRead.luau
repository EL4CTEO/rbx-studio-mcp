--!strict
-- Read-only viewport operations, also usable at ordinary client identity.
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local StarterGui = game:GetService("StarterGui")
local Players = game:GetService("Players")
local Dispatch = require(script.Parent.Dispatch)
local Paths = require(script.Parent.Paths)
local Serialize = require(script.Parent.Serialize)
local ScreenRegion = require(script.Parent.ScreenRegion)
local DEFAULT_RAY_LENGTH = 1000
local MIN_TEXT_PIXELS = 10
local Viewport = {}
local function toVector(value: any, label: string): Vector3
	if typeof(value) == "Vector3" then return value end
	local ok, parsed = Serialize.parse(value, "Vector3")
	if not ok or typeof(parsed) ~= "Vector3" then
		Dispatch.fail(
			"BAD_PARAMS",
			string.format('%s must be three numbers, e.g. "0, 50, 0".', label)
		)
	end
	return parsed :: Vector3
end
Viewport.toVector = toVector

--[[
	Casts a ray through the world and reports the first thing it hits.

	`Workspace:Raycast`, not `StudioService:GizmoRaycast`. The latter reads like
	the Studio-aware choice and is not: measured against a place with parts under
	the ray, it returns nil every time. It picks Studio's own gizmos and
	adornments, not world geometry.
]]
function Viewport.raycast(params: { [string]: any }): { [string]: any }
	local origin = toVector(params.origin, "origin")
	local direction = toVector(params.direction, "direction")
	local length = tonumber(params.maxDistance) or DEFAULT_RAY_LENGTH

	--[[
		A zero direction has no `Unit` -- it is NaN -- and a ray along NaN hits
		nothing, which the reply then reported as "nothing within 1000 studs". That
		is a confident answer about empty space to a question that was never asked,
		so the input is refused instead.
	]]
	if direction.Magnitude == 0 then
		Dispatch.fail(
			"BAD_PARAMS",
			"`direction` cannot be zero: a ray needs a way to point.",
			'Give a direction such as "0, -1, 0" for straight down.'
		)
	end

	local filter: { Instance } = {}
	for _, path in (params.ignore or {}) :: { string } do
		table.insert(filter, Paths.resolve(path))
	end

	local config = RaycastParams.new()
	config.FilterType = Enum.RaycastFilterType.Exclude
	config.FilterDescendantsInstances = filter

	local ok, result = pcall(function()
		return Workspace:Raycast(origin, direction.Unit * length, config)
	end)

	if not ok then Dispatch.fail("RAYCAST_FAILED", tostring(result)) end
	if result == nil then
		return { hit = false, origin = Serialize.value(origin), direction = Serialize.value(direction.Unit) }
	end

	local cast = result :: RaycastResult
	return {
		hit = true,
		path = if cast.Instance then Paths.of(cast.Instance) else nil,
		handle = if params.handles and cast.Instance then Paths.handle(cast.Instance) else nil,
		className = if cast.Instance then cast.Instance.ClassName else nil,
		position = Serialize.value(cast.Position),
		normal = Serialize.value(cast.Normal),
		distance = math.floor(cast.Distance * 1000 + 0.5) / 1000,
		material = cast.Material.Name,
	}
end

-- Coordinates refer to the full, uncropped viewport: 0,0 is its top-left.
-- Screenshot captions give the crop and scale needed to map image pixels back.
function Viewport.pick(params: { [string]: any }): { [string]: any }
	if RunService:IsRunning() and RunService:IsServer() and not RunService:IsClient() then
		Dispatch.fail("NO_RENDERER", "The playtest server has no visible camera.", "Use target=client and the player's name.")
	end
	local camera = Workspace.CurrentCamera
	if not camera then Dispatch.fail("NO_CAMERA", "This session has no camera.") end
	local x, y = tonumber(params.x), tonumber(params.y)
	if not x or not y or x < 0 or x > 1 or y < 0 or y > 1 then
		Dispatch.fail("BAD_PARAMS", "pick requires normalized x/y between 0 and 1 in the full viewport.")
	end
	local size = (camera :: Camera).ViewportSize
	if size.X <= 0 or size.Y <= 0 then Dispatch.fail("NO_VIEWPORT", "The camera viewport has no size.") end
	local ray = (camera :: Camera):ViewportPointToRay(x * size.X, y * size.Y)
	local cast = Viewport.raycast({ origin = ray.Origin, direction = ray.Direction,
		maxDistance = params.maxDistance, ignore = params.ignore, handles = true })
	cast.viewport = string.format("%dx%d", size.X, size.Y)
	return cast
end

local MAX_OVERLAP_PAIRS = 2000

local function rectOf(element: GuiObject): (number, number, number, number)
	local position = element.AbsolutePosition
	local size = element.AbsoluteSize
	return position.X, position.Y, position.X + size.X, position.Y + size.Y
end

local function overlaps(a: GuiObject, b: GuiObject): boolean
	local ax1, ay1, ax2, ay2 = rectOf(a)
	local bx1, by1, bx2, by2 = rectOf(b)
	return ax1 < bx2 and bx1 < ax2 and ay1 < by2 and by1 < ay2
end

--[[
	Whether this element is actually on screen at all.

	Walks up rather than trusting `Visible`: an element with Visible true inside
	a frame with Visible false is not on screen, and reporting it as a fault
	would bury the real findings under every hidden menu in the place.
]]
local function shown(element: Instance): boolean
	local node: Instance? = element
	while node ~= nil and not node:IsA("LayerCollector") do
		if node:IsA("GuiObject") and not (node :: GuiObject).Visible then
			return false
		end
		node = node.Parent
	end
	if node ~= nil and node:IsA("ScreenGui") then
		return (node :: ScreenGui).Enabled
	end
	return node ~= nil
end

function Viewport.ui(params: { [string]: any }): { [string]: any }
	local root: Instance = if typeof(params.path) == "string" and params.path ~= ""
		then Paths.resolve(params.path)
		else (if RunService:IsClient() and RunService:IsRunning() then Players.LocalPlayer:FindFirstChildOfClass("PlayerGui") else StarterGui)
	if root == nil then Dispatch.fail("NO_PLAYER_GUI", "The player's GUI has not loaded yet.") end

	local camera = Workspace.CurrentCamera
	if camera == nil then
		Dispatch.fail("NO_CAMERA", "This session has no camera, so there is no screen to measure against.")
	end
	local screen = (camera :: Camera).ViewportSize
	local screenWidth, screenHeight = math.floor(screen.X), math.floor(screen.Y)

	local elements: { GuiObject } = {}
	if root:IsA("GuiObject") then table.insert(elements, root :: GuiObject) end
	for _, descendant in root:GetDescendants() do
		if descendant:IsA("GuiObject") then
			table.insert(elements, descendant :: GuiObject)
		end
	end

	local findings: { { [string]: any } } = {}
	local omitted = 0
	local checked = 0
	local hidden = 0

	local function report(element: GuiObject, issue: string, detail: string)
		if #findings >= 100 then
			omitted += 1
			return
		end
		table.insert(findings, {
			path = Paths.of(element),
			name = element.Name,
			className = element.ClassName,
			issue = issue,
			detail = detail,
		})
	end

	local visible: { GuiObject } = {}

	for _, element in elements do
		if not shown(element) then
			hidden += 1
			continue
		end
		checked += 1
		table.insert(visible, element)

		local size = element.AbsoluteSize
		local position = ScreenRegion.position(element)

		if size.X <= 0 or size.Y <= 0 then
			report(element, "zero size", string.format("%.0f x %.0f -- nothing is drawn", size.X, size.Y))
			continue
		end

		--[[
			Off screen, and by how much.

			Reported as a measurement rather than a yes/no, because the two cases
			it covers are different bugs: an element wholly outside the screen was
			positioned for a display that is not this one, and one clipped at an
			edge is usually a layout that does not fit. The numbers tell them
			apart; a boolean would not.
		]]
		local right = position.X + size.X
		local bottom = position.Y + size.Y
		if right <= 0 or bottom <= 0 or position.X >= screenWidth or position.Y >= screenHeight then
			report(
				element,
				"off screen",
				string.format(
					"at %.0f,%.0f on a %dx%d screen -- entirely outside it",
					position.X,
					position.Y,
					screenWidth,
					screenHeight
				)
			)
		elseif position.X < 0 or position.Y < 0 or right > screenWidth or bottom > screenHeight then
			report(
				element,
				"clipped",
				string.format(
					"%.0f,%.0f to %.0f,%.0f runs past the %dx%d screen",
					position.X,
					position.Y,
					right,
					bottom,
					screenWidth,
					screenHeight
				)
			)
		end

		if element:IsA("TextLabel") or element:IsA("TextButton") or element:IsA("TextBox") then
			local text = element :: any
			--[[
				The size the text is actually drawn at, which is not TextSize when
				TextScaled is on: the engine then fits the string to the box and
				`TextBounds` is the only honest report of the result.
			]]
			local drawn = if text.TextScaled then text.TextBounds.Y else text.TextSize
			if drawn > 0 and drawn < MIN_TEXT_PIXELS and text.Text ~= "" then
				report(
					element,
					"text too small",
					string.format("%.0fpx -- under %dpx is unreadable on a phone", drawn, MIN_TEXT_PIXELS)
				)
			end
			if text.TextTruncate == Enum.TextTruncate.None and not text.TextScaled and not text.TextWrapped then
				if text.TextBounds.X > size.X + 1 then
					report(
						element,
						"text overflows",
						string.format("needs %.0fpx, has %.0fpx", text.TextBounds.X, size.X)
					)
				end
			end
		end
	end

	--[[
		Overlap between siblings only.

		A child sitting on top of its parent is the normal way UI is built, and
		reporting it would make the check useless. Two buttons in the same frame
		covering each other is the fault worth naming.
	]]
	--[[
		Whether an element is something a user reads or presses.

		Overlap between decoration is not a fault, it is how UI is built: a drop
		shadow sits under a panel, a bevel sits under a label, a playhead sits
		over a timeline. Measured on a real HUD, the first version of this check
		reported four overlaps and all four were of that kind -- a Frame named
		Shadow behind the three things it was drawn to sit behind.

		Two pieces of TEXT on top of each other, or two images, is the fault
		worth naming. So a plain coloured Frame is not counted; something
		carrying text or an image is.
	]]
	local function carriesContent(element: GuiObject): boolean
		if element:IsA("TextLabel") or element:IsA("TextButton") or element:IsA("TextBox") then
			return (element :: any).Text ~= ""
		end
		if element:IsA("ImageLabel") or element:IsA("ImageButton") then
			return (element :: any).Image ~= ""
		end
		return false
	end

	local pairs = 0
	local stopped = false
	for index = 1, #visible do
		for other = index + 1, #visible do
			if pairs >= MAX_OVERLAP_PAIRS then
				stopped = true
				break
			end
			local a, b = visible[index], visible[other]
			if a.Parent == b.Parent then
				pairs += 1
				if
					overlaps(a, b)
					and a.AbsoluteSize.X > 0
					and b.AbsoluteSize.X > 0
					and carriesContent(a)
					and carriesContent(b)
				then
					report(a, "overlaps", string.format("covers or is covered by %s", b.Name))
				end
			end
		end
		if stopped then
			break
		end
	end

	return {
		screen = string.format("%dx%d", screenWidth, screenHeight),

		root = Paths.of(root),
		checked = checked,
		hidden = hidden,
		findings = findings,
		findingCount = #findings,
		omitted = if omitted > 0 then omitted else nil,
		overlapStopped = stopped,
	}
end

return Viewport
