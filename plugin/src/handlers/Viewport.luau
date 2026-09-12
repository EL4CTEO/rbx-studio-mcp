--!strict
--[[
	The viewport and the selection -- what the user is pointing at, and what they
	have highlighted.

	Selection is the counterpart to `studio_status`, which reports it: this sets
	it. Selecting what a tool just built is the cheapest way to show someone the
	result of a change, and it puts the instance in reach of Studio's own move
	and scale handles.

	Raycasting answers "what is under this point in the 3D view", which is
	otherwise unanswerable: an agent can enumerate the data model but has no way
	to know what occupies a piece of space.
]]

local RunService = game:GetService("RunService")
local Selection = game:GetService("Selection")
local StarterGui = game:GetService("StarterGui")
local TextService = game:GetService("TextService")
local Workspace = game:GetService("Workspace")

local Dispatch = require(script.Parent.Parent.Dispatch)
local Emulation = require(script.Parent.Parent.Emulation)
local Paths = require(script.Parent.Parent.Paths)
local Serialize = require(script.Parent.Parent.Serialize)

local MAX_SELECTION = 200
local DEFAULT_RAY_LENGTH = 1000

local Viewport = {}

--[[
	Whether moving the camera in this session would change what anyone sees.

	A playtest server has a `CurrentCamera` and accepts every write to it, and
	renders nothing -- the picture on screen comes from the playtest's client. So
	framing a subject here succeeds, reports a plausible camera position, and
	moves no camera the user has. Measured: `focus` against a playtest server
	returned a full result for a shot nobody could ever see.
]]
local function rendersToScreen(): boolean
	return not (RunService:IsRunning() and RunService:IsServer())
end


local function toVector(value: any, label: string): Vector3
	local ok, parsed = Serialize.parse(value, "Vector3")
	if not ok or typeof(parsed) ~= "Vector3" then
		Dispatch.fail(
			"BAD_PARAMS",
			string.format('%s must be three numbers, e.g. "0, 50, 0".', label)
		)
	end
	return parsed :: Vector3
end

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

	if not ok or result == nil then
		return { hit = false, origin = Serialize.value(origin), direction = Serialize.value(direction.Unit) }
	end

	local cast = result :: RaycastResult
	return {
		hit = true,
		path = if cast.Instance then Paths.of(cast.Instance) else nil,
		className = if cast.Instance then cast.Instance.ClassName else nil,
		position = Serialize.value(cast.Position),
		normal = Serialize.value(cast.Normal),
		distance = math.floor(cast.Distance * 1000 + 0.5) / 1000,
		material = Serialize.value(cast.Material),
	}
end

--[[
	Sets, extends or shrinks the Studio selection.
]]
function Viewport.select(params: { [string]: any }): { [string]: any }
	local paths = params.paths
	if typeof(paths) ~= "table" then
		Dispatch.fail("BAD_PARAMS", "select requires a `paths` array.")
	end
	if #paths > MAX_SELECTION then
		Dispatch.fail(
			"TOO_MANY",
			string.format("%d paths, over the %d selection limit.", #paths, MAX_SELECTION)
		)
	end

	local instances: { Instance } = {}
	for _, path in paths :: { string } do
		table.insert(instances, Paths.resolve(path))
	end

	local mode = params.mode or "set"
	if mode == "add" then
		Selection:Add(instances)
	elseif mode == "remove" then
		Selection:Remove(instances)
	else
		Selection:Set(instances)
	end

	local current: { { [string]: any } } = {}
	local memo: Paths.NameIndex = {}
	for index, instance in Selection:Get() do
		if index > MAX_SELECTION then
			break
		end
		table.insert(current, { path = Paths.of(instance, memo), className = instance.ClassName })
	end

	return { items = current, count = #Selection:Get() }
end

--[[
	The world-space box an instance occupies.

	A Model knows its own extents; a lone part has to be measured from its size
	and orientation. Anything else -- a Folder, a Script -- has no position at
	all, and saying so is better than framing the origin and returning a picture
	of empty ground.
]]
local function extentsOf(instance: Instance): (Vector3, Vector3)
	if instance:IsA("Model") then
		local cframe, size = (instance :: Model):GetBoundingBox()
		return cframe.Position, size
	end
	if instance:IsA("BasePart") then
		local part = instance :: BasePart
		return part.Position, part.Size
	end

	-- A container is worth framing if anything inside it has a position.
	local minimum: Vector3? = nil
	local maximum: Vector3? = nil
	for _, descendant in instance:GetDescendants() do
		if descendant:IsA("BasePart") then
			local part = descendant :: BasePart
			local half = part.Size / 2
			minimum = if minimum == nil then part.Position - half else (minimum :: Vector3):Min(part.Position - half)
			maximum = if maximum == nil then part.Position + half else (maximum :: Vector3):Max(part.Position + half)
		end
	end
	if minimum == nil or maximum == nil then
		Dispatch.fail(
			"NOT_POSITIONED",
			string.format("%s is a %s and occupies no space in the world.", instance:GetFullName(), instance.ClassName),
			"Frame something with geometry -- a part, a model, or a folder containing them."
		)
	end
	local low, high = minimum :: Vector3, maximum :: Vector3
	return (low + high) / 2, high - low
end

--[[
	Points the Studio camera at something, framed so all of it is on screen.

	This is what makes `screenshot` worth having. A picture of wherever the user
	last left their camera answers nothing; a picture of the thing just built
	answers "does it look right", which the data model cannot.

	The distance is computed from the subject's size and the camera's own field
	of view rather than guessed, so a doorway and a whole map both arrive filling
	a similar share of the frame.
]]
function Viewport.focus(params: { [string]: any }): { [string]: any }
	if not rendersToScreen() then
		Dispatch.fail(
			"NOT_RENDERED",
			"This is the playtest's server session, which draws nothing -- moving its "
				.. "camera would change no picture anybody sees.",
			"Address the editor session (see `list_studios`), or stop the playtest first."
		)
	end
	local camera = Workspace.CurrentCamera
	if camera == nil then
		Dispatch.fail("NO_CAMERA", "This session has no camera.")
	end

	local centre: Vector3
	local size: Vector3
	if typeof(params.path) == "string" and params.path ~= "" then
		centre, size = extentsOf(Paths.resolve(params.path))
	else
		centre = toVector(params.at, "`at`")
		size = Vector3.new(10, 10, 10)
	end

	--[[
		Half the diagonal, not half the width: a wall seen from an angle presents
		its diagonal, and framing to the width alone crops the corners off
		exactly the shapes most worth looking at.
	]]
	local radius = math.max(size.Magnitude / 2, 1)
	local fov = math.rad((camera :: Camera).FieldOfView)
	local distance = (radius / math.tan(fov / 2)) * (tonumber(params.padding) or 1.5)

	-- Down the -Z axis and slightly above by default, which is how a person
	-- would stand to look at something: face on, a little raised, never level
	-- with a flat surface where it would vanish to a line.
	local direction: Vector3
	if typeof(params.from) == "string" and params.from ~= "" then
		direction = toVector(params.from, "`from`").Unit
	else
		direction = Vector3.new(0.45, 0.35, 1).Unit
	end

	local eye = centre + direction * distance
	;(camera :: Camera).CFrame = CFrame.lookAt(eye, centre)
	--[[
		`Focus` is not optional here, and leaving it out is a silent failure.

		Studio's edit camera orbits around Focus and re-derives its heading from
		it every frame. Setting CFrame alone applies -- and is then thrown away
		about a fifth of a second later, keeping the new position and restoring
		the old rotation. Measured: the look vector read back correct
		immediately, and had reverted to the previous heading by the next check,
		so the camera moved to the right place and pointed the wrong way, and a
		screenshot came back showing empty ground.
	]]
	;(camera :: Camera).Focus = CFrame.new(centre)

	return {
		focused = if typeof(params.path) == "string" then params.path else tostring(centre),
		cameraPosition = tostring(eye),
		lookingAt = tostring(centre),
		distance = math.floor(distance * 10 + 0.5) / 10,
		subjectSize = tostring(size),
	}
end

--[[
	Reads or sets the camera directly, for the cases framing cannot express --
	standing inside a room, or matching a specific shot.
]]
function Viewport.camera(params: { [string]: any }): { [string]: any }
	if not rendersToScreen() then
		Dispatch.fail(
			"NOT_RENDERED",
			"This is the playtest's server session, which draws nothing -- moving its "
				.. "camera would change no picture anybody sees.",
			"Address the editor session (see `list_studios`), or stop the playtest first."
		)
	end
	local camera = Workspace.CurrentCamera
	if camera == nil then
		Dispatch.fail("NO_CAMERA", "This session has no camera.")
	end
	local view = camera :: Camera

	if params.position ~= nil then
		local eye = toVector(params.position, "`position`")
		local target = if params.lookAt ~= nil
			then toVector(params.lookAt, "`lookAt`")
			else eye + view.CFrame.LookVector
		view.CFrame = CFrame.lookAt(eye, target)
		-- Same reason as focus: without this the rotation survives a frame.
		view.Focus = CFrame.new(target)
	end
	if tonumber(params.fieldOfView) ~= nil then
		view.FieldOfView = math.clamp(tonumber(params.fieldOfView) :: number, 1, 120)
	end

	return {
		position = tostring(view.CFrame.Position),
		lookVector = tostring(view.CFrame.LookVector),
		fieldOfView = view.FieldOfView,
	}
end

--[[
	How big a piece of text actually renders.

	Every alternative to asking the engine is a guess. Character counts do not
	account for the font, font size does not give you a width, and "it looked
	fine on my screen" is not a measurement -- so a label that overflows is
	normally found by a human looking at it, which is exactly the loop an agent
	cannot close on its own.

	Pointed at an existing label (`path`) it reads that label's own text, font,
	size and width and answers whether the text fits inside it. Given the values
	directly it just measures. The first form is the useful one: it turns "will
	this fit" into a yes or no instead of two numbers the caller has to compare
	against the right box.
]]
function Viewport.textbounds(params: { [string]: any }): { [string]: any }
	local text = if typeof(params.text) == "string" then params.text else ""
	local size = tonumber(params.size) or 14
	local width = tonumber(params.width) or 0
	local richText = params.richText == true
	local fontFace: Font? = nil

	local subject: GuiObject? = nil
	if typeof(params.path) == "string" and params.path ~= "" then
		local instance = Paths.resolve(params.path)
		if not instance:IsA("TextLabel") and not instance:IsA("TextButton") and not instance:IsA("TextBox") then
			Dispatch.fail(
				"NOT_TEXT",
				string.format("%s is a %s, which has no text.", params.path, instance.ClassName),
				"Point at a TextLabel, TextButton or TextBox."
			)
		end
		local label = instance :: any
		subject = instance :: GuiObject
		if text == "" then
			text = label.Text
		end
		if params.size == nil then
			--[[
				`TextSize` is meaningless while `TextScaled` is on -- the engine
				picks a size per frame -- so the rendered height is read off
				`AbsoluteSize` instead of a property that is not being used.
			]]
			size = if label.TextScaled then (instance :: GuiObject).AbsoluteSize.Y else label.TextSize
		end
		if params.richText == nil then
			richText = label.RichText
		end
		if params.width == nil then
			width = (instance :: GuiObject).AbsoluteSize.X
		end
		fontFace = label.FontFace
	end

	if fontFace == nil then
		local name = tostring(params.font or "SourceSans")
		local chosen = (Enum.Font :: any)[name]
		if chosen == nil then
			Dispatch.fail(
				"BAD_PARAMS",
				string.format("unknown font %q", name),
				"Use an Enum.Font name, e.g. \"Gotham\", \"GothamMedium\", \"SourceSans\"."
			)
		end
		fontFace = Font.fromEnum(chosen)
	end

	if text == "" then
		Dispatch.fail("BAD_PARAMS", "textbounds needs `text`, or a `path` to something holding it.")
	end

	local request = Instance.new("GetTextBoundsParams")
	request.Text = text
	request.Size = size
	request.Font = fontFace :: Font
	request.RichText = richText
	-- Zero means "do not wrap", which is what the engine wants for an unbounded
	-- measurement; a negative width would be read as a very narrow column.
	request.Width = math.max(width, 0)

	local ok, bounds = pcall(function()
		return TextService:GetTextBoundsAsync(request)
	end)
	if not ok then
		Dispatch.fail("MEASURE_FAILED", string.format("GetTextBoundsAsync refused: %s", tostring(bounds)))
	end

	local measured = bounds :: Vector2
	local report: { [string]: any } = {
		width = math.ceil(measured.X),
		height = math.ceil(measured.Y),
		text = if #text > 120 then string.sub(text, 1, 117) .. "..." else text,
		size = size,
		-- `Family` is a content URI -- "rbxasset://fonts/families/GothamSSm.json"
		-- -- which is the path to the font and not the name of it. The stem is
		-- what a caller recognises and what they would type back.
		font = string.match(tostring((fontFace :: Font).Family), "([^/]+)%.json$")
			or tostring((fontFace :: Font).Family),
		wrappedAt = if width > 0 then math.floor(width) else nil,
	}

	if subject then
		local box = (subject :: GuiObject).AbsoluteSize
		report.box = string.format("%d x %d", math.floor(box.X), math.floor(box.Y))
		report.fits = measured.X <= box.X and measured.Y <= box.Y
		report.overflowX = math.max(math.ceil(measured.X - box.X), 0)
		report.overflowY = math.max(math.ceil(measured.Y - box.Y), 0)
	end

	return report
end

--[[
	Every interface fault that is invisible in the data model.

	`textbounds` already answers "does this text fit its label". This is the same
	question asked of the whole screen, and it exists because the data model
	cannot answer it at all: a button positioned off the side of a phone has a
	perfectly correct `Position`, a `Size` that is not zero, and a parent that is
	visible. Nothing about the instance is wrong. It is simply not where anyone
	can reach it, and the only ways to find that out today are to play the game
	or to look at a picture.

	Studio lays StarterGui out for real in edit mode -- measured:
	`AbsolutePosition` and `AbsoluteSize` carry live values with nothing running,
	and they move when a device is emulated. So the audit runs against whatever
	`device` is currently emulating, which is what makes it worth running twice:
	once on desktop, once on a phone.

	It reports rather than judges. Every finding names the element and the
	number, so a caller can decide whether a label four pixels off the edge is a
	bug or a deliberate bleed.
]]

--[[
	Text below this many pixels tall is not readable on a phone.

	Roblox's own UI guidance and every accessibility standard land in the same
	place: somewhere around 12 device-independent pixels is the floor for body
	text. 10 is used here because it is the point past which there is no
	argument -- a label under it is unreadable on any display, not merely small.
]]
local MIN_TEXT_PIXELS = 10

--[[
	Pairs compared for overlap before the check gives up.

	Overlap is quadratic in the number of siblings, and a scrolling list of two
	hundred rows is both a legitimate design and forty thousand comparisons of
	rectangles that are supposed to sit next to each other. Past this the check
	reports that it stopped rather than continuing to spend the user's frame on
	an answer nobody asked for.
]]
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
		else StarterGui

	local camera = Workspace.CurrentCamera
	if camera == nil then
		Dispatch.fail("NO_CAMERA", "This session has no camera, so there is no screen to measure against.")
	end
	local screen = (camera :: Camera).ViewportSize
	local screenWidth, screenHeight = math.floor(screen.X), math.floor(screen.Y)

	local elements: { GuiObject } = {}
	for _, descendant in root:GetDescendants() do
		if descendant:IsA("GuiObject") then
			table.insert(elements, descendant :: GuiObject)
		end
	end

	local findings: { { [string]: any } } = {}
	local checked = 0
	local hidden = 0

	local function report(element: GuiObject, issue: string, detail: string)
		if #findings >= 100 then
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
		local position = element.AbsolutePosition

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
		device = Emulation.deviceId(),
		root = Paths.of(root),
		checked = checked,
		hidden = hidden,
		findings = findings,
		findingCount = #findings,
		overlapStopped = stopped,
	}
end

function Viewport.register()
	Dispatch.registerAll("viewport", {
		ui = Viewport.ui,
		textbounds = Viewport.textbounds,
		raycast = Viewport.raycast,
		select = Viewport.select,
		focus = Viewport.focus,
		camera = Viewport.camera,
	})
end

return Viewport
