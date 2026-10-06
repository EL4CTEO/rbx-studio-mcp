--!strict
--[[
	The preset drawer: a tab on the panel's right edge that opens on hover.

	Kept out of the header on purpose. The header is where connection facts live
	and it is already carrying a status light, an address, a client badge and
	three buttons; a ninth control there would push something off the edge on a
	narrow dock. A theme is also not something anyone changes twice in a
	session, so it has no claim on permanent width -- an edge tab costs fourteen
	pixels and is invisible until you go looking for it.

	Hover rather than click to open, because the drawer is a preview as much as
	a menu: each row wears its own preset's background, text colour and cell
	miniature, so running the pointer down the list shows you the eight themes
	rather than eight names. Clicking picks; leaving closes.

	The grace period on close is the part that makes it usable. Without it, the
	pointer crossing the one-pixel gap between the tab and the drawer counts as
	leaving, and the menu shuts under the hand reaching for it.
]]

local TweenService = game:GetService("TweenService")

local Themes = require(script.Parent.Themes)

local ThemePicker = {}

local TAB_WIDTH = 14
local TAB_HEIGHT = 48
local DRAWER_WIDTH = 240
local ROW_HEIGHT = 40
local PADDING = 8
local HEADER_HEIGHT = 20

-- Presets draw their miniature in pixels, on a 40x24 canvas. Scaling that canvas
-- rather than asking eight painters for a bigger one keeps them unchanged.
local SWATCH_CANVAS = Vector2.new(40, 24)
local SWATCH_SCALE = 1.2

-- A row's outline at rest, hovered, and when it is the preset in use.
local STROKE_REST = 0.8
local STROKE_HOVER = 0.3
local STROKE_ACTIVE = 0

-- Long enough to cross the gap between tab and drawer without thinking about
-- it, short enough that a drawer left open behind the pointer still closes.
local GRACE = 0.4

--[[
	Explicit depths for every layer of the drawer.

	A plugin widget draws with ZIndexBehavior.Global, where a child does NOT
	inherit its parent's depth -- so the rows, built with the default ZIndex of
	1, rendered UNDER the drawer's own background at 30 and the menu opened
	empty. Nothing about that is visible in the code unless you already know the
	rule, so the depths are named rather than sprinkled as numbers.
]]
local Z_DRAWER = 30
local Z_LIST = 31
local Z_ROW = 32
local Z_ROW_CONTENT = 33
local Z_TAB = 36
local Z_VEIL = 50

--[[
	Stamps a depth on an Instance and everything inside it.

	Needed because a preset draws its own swatch and has no reason to know it is
	being drawn inside a menu. Rather than adding a ZIndex argument to the theme
	contract -- which would put a menu detail into eight renderers -- the swatch
	is drawn first and pushed to the right depth afterwards.
]]
local function stack(instance: Instance, depth: number)
	if instance:IsA("GuiObject") then
		instance.ZIndex = depth
	end
	for _, child in instance:GetDescendants() do
		if child:IsA("GuiObject") then
			child.ZIndex = depth
		end
	end
end

local OPEN = TweenInfo.new(0.22, Enum.EasingStyle.Quint, Enum.EasingDirection.Out)
local SHUT = TweenInfo.new(0.16, Enum.EasingStyle.Quint, Enum.EasingDirection.In)
local HOVER = TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

type Row = {
	frame: Frame,
	id: string,
	marker: TextLabel,
	stroke: UIStroke,
	accent: Frame,
	hovered: boolean,
}

type Runtime = {
	drawer: Frame?,
	heading: TextLabel?,
	tab: TextButton?,
	chevron: TextLabel?,
	rows: { Row },
	open: boolean,
	-- Bumped on every hover, so a grace timer from an earlier one cannot close
	-- a drawer the pointer has since come back to.
	generation: number,
	root: Frame?,
	onPicked: ((string) -> ())?,
}

local runtime: Runtime = {
	drawer = nil,
	heading = nil,
	tab = nil,
	chevron = nil,
	rows = {},
	open = false,
	generation = 0,
	root = nil,
	onPicked = nil,
}

local function drawerHeight(): number
	return HEADER_HEIGHT + #Themes.list() * ROW_HEIGHT + PADDING * 2
end

local function setOpen(open: boolean)
	local drawer = runtime.drawer
	local chevron = runtime.chevron
	if drawer == nil then
		return
	end
	if runtime.open == open then
		return
	end
	runtime.open = open

	--[[
		Size and position tween together, with the drawer anchored to its own
		right edge at the tab's height. That is what makes it appear to grow out
		of the tab rather than slide in from off-screen: at width zero it is
		exactly where the pointer is.
	]]
	local height = drawerHeight()
	TweenService:Create(drawer, if open then OPEN else SHUT, {
		Size = UDim2.fromOffset(if open then DRAWER_WIDTH else 0, height),
	}):Play()

	if chevron then
		-- Points the way it will move: into the panel when it will open, back
		-- out at the edge when it will close.
		TweenService:Create(chevron, if open then OPEN else SHUT, {
			Rotation = if open then 180 else 0,
		}):Play()
	end
end

--[[
	Closes after the grace period, unless the pointer came back.
]]
local function scheduleClose()
	runtime.generation += 1
	local generation = runtime.generation
	task.delay(GRACE, function()
		if runtime.generation == generation then
			setOpen(false)
		end
	end)
end

local function hold()
	runtime.generation += 1
end

--[[
	Fades the panel through its own background while the palette changes.

	A theme switch repaints thirty Instances and re-renders three hundred log
	rows, and doing that in one frame reads as a flicker -- the eye catches the
	half-repainted state even though there is not one. A third of a second of
	the outgoing background over the top hides the seam and, more usefully, says
	that something deliberate just happened.
]]
local function crossfade(root: Frame, from: Color3, apply: () -> ())
	local veil = Instance.new("Frame")
	veil.Name = "ThemeFade"
	veil.Size = UDim2.fromScale(1, 1)
	veil.BackgroundColor3 = from
	veil.BackgroundTransparency = 0.15
	veil.BorderSizePixel = 0
	veil.ZIndex = Z_VEIL
	veil.Parent = root

	apply()

	local fade = TweenService:Create(
		veil,
		TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ BackgroundTransparency = 1 }
	)
	fade.Completed:Connect(function()
		veil:Destroy()
	end)
	fade:Play()
end

-- Where a row's outline sits when nothing is hovering it.
local function restingStroke(active: boolean): number
	return if active then STROKE_ACTIVE else STROKE_REST
end

--[[
	Marks the preset in use: a bright outline, an accent bar down the left edge
	and a tick. The old marker was one small diamond in a low-contrast colour,
	easy to miss in a list that is otherwise eight similar dark cards.
]]
local function markActive()
	local activeId = Themes.activeId()
	for _, row in runtime.rows do
		local active = row.id == activeId
		row.marker.Text = if active then "\u{2713}" else ""
		row.accent.Visible = active
		if not row.hovered then
			row.stroke.Transparency = restingStroke(active)
		end
	end
end

--[[
	One row: the preset's own background, its cell miniature, its name.

	Drawn in the preset's palette rather than the console's, which is the whole
	reason the drawer is worth opening. A list of eight words in the current
	theme's colours would tell you nothing you could not have guessed.
]]
local function buildRow(parent: Instance, theme: Themes.Theme, order: number)
	local palette = theme.palette
	local rest = palette.background
	local lifted = palette.background:Lerp(palette.surface, 0.7)

	local row = Instance.new("TextButton")
	row.Name = theme.id
	row.Text = ""
	row.AutoButtonColor = false
	row.BackgroundColor3 = rest
	row.BorderSizePixel = 0
	row.Size = UDim2.new(1, 0, 0, ROW_HEIGHT - 2)
	row.LayoutOrder = order
	row.ZIndex = Z_ROW
	row.Parent = parent

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 6)
	corner.Parent = row

	-- In the preset's own accent, so each outline previews the theme it opens.
	local stroke = Instance.new("UIStroke")
	stroke.Color = palette.violet
	stroke.Transparency = STROKE_REST
	stroke.Parent = row

	--[[
		The miniature. Clipped, because a preset draws to the edges of whatever
		it is given and a swatch that spills over the row would land on its
		neighbour. The preset draws on a fixed-size canvas inside, which is scaled
		up to fill the swatch.
	]]
	local swatchWidth = SWATCH_CANVAS.X * SWATCH_SCALE
	local swatchHeight = SWATCH_CANVAS.Y * SWATCH_SCALE
	local swatch = Instance.new("Frame")
	swatch.Name = "Swatch"
	swatch.AnchorPoint = Vector2.new(0, 0.5)
	swatch.Position = UDim2.new(0, 8, 0.5, 0)
	swatch.Size = UDim2.fromOffset(swatchWidth, swatchHeight)
	swatch.BackgroundColor3 = palette.surface
	swatch.BorderSizePixel = 0
	swatch.ClipsDescendants = true
	swatch.ZIndex = Z_ROW_CONTENT
	swatch.Parent = row

	local swatchCorner = Instance.new("UICorner")
	swatchCorner.CornerRadius = UDim.new(0, 4)
	swatchCorner.Parent = swatch

	local canvas = Instance.new("Frame")
	canvas.Name = "Canvas"
	canvas.AnchorPoint = Vector2.new(0.5, 0.5)
	canvas.Position = UDim2.fromScale(0.5, 0.5)
	canvas.Size = UDim2.fromOffset(SWATCH_CANVAS.X, SWATCH_CANVAS.Y)
	canvas.BackgroundTransparency = 1
	canvas.BorderSizePixel = 0
	canvas.ClipsDescendants = true
	canvas.ZIndex = Z_ROW_CONTENT
	canvas.Parent = swatch

	local canvasScale = Instance.new("UIScale")
	canvasScale.Scale = SWATCH_SCALE
	canvasScale.Parent = canvas

	-- A preset that cannot draw its own thumbnail must not take the menu with
	-- it; an empty swatch is a bad row, a broken drawer is a broken plugin.
	local ok, err = pcall(theme.swatch, canvas, palette)
	if not ok then
		warn(string.format("[rbx-studio] theme %q failed to draw a swatch: %s", theme.id, tostring(err)))
	end
	-- Whatever the preset just built is at depth 1 and would be invisible.
	stack(canvas, Z_ROW_CONTENT)

	local textX = 8 + swatchWidth + 10

	local label = Instance.new("TextLabel")
	label.Name = "Label"
	label.BackgroundTransparency = 1
	label.Position = UDim2.new(0, textX, 0, 5)
	label.Size = UDim2.new(1, -(textX + 28), 0, 15)
	label.Font = Enum.Font.Code
	label.TextSize = 13
	label.TextColor3 = palette.text
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.Text = theme.label
	label.ZIndex = Z_ROW_CONTENT
	label.Parent = row

	local blurb = Instance.new("TextLabel")
	blurb.Name = "Blurb"
	blurb.BackgroundTransparency = 1
	blurb.Position = UDim2.new(0, textX, 0, 21)
	blurb.Size = UDim2.new(1, -(textX + 28), 0, 12)
	blurb.Font = Enum.Font.Code
	blurb.TextSize = 10
	blurb.TextColor3 = palette.dim
	blurb.TextXAlignment = Enum.TextXAlignment.Left
	blurb.TextTruncate = Enum.TextTruncate.AtEnd
	blurb.Text = theme.blurb
	blurb.ZIndex = Z_ROW_CONTENT
	blurb.Parent = row

	-- The preset's own signature colour, shown only on the one in use.
	local accent = Instance.new("Frame")
	accent.Name = "Accent"
	accent.AnchorPoint = Vector2.new(0, 0.5)
	accent.Position = UDim2.new(0, 0, 0.5, 0)
	accent.Size = UDim2.new(0, 3, 1, -12)
	accent.BackgroundColor3 = palette.violet
	accent.BorderSizePixel = 0
	accent.Visible = false
	accent.ZIndex = Z_ROW_CONTENT
	accent.Parent = row

	local accentCorner = Instance.new("UICorner")
	accentCorner.CornerRadius = UDim.new(1, 0)
	accentCorner.Parent = accent

	local marker = Instance.new("TextLabel")
	marker.Name = "Marker"
	marker.AnchorPoint = Vector2.new(1, 0.5)
	marker.Position = UDim2.new(1, -10, 0.5, 0)
	marker.Size = UDim2.fromOffset(14, 14)
	marker.BackgroundTransparency = 1
	marker.Font = Enum.Font.Code
	marker.TextSize = 14
	marker.TextColor3 = palette.violet
	marker.Text = ""
	marker.ZIndex = Z_ROW_CONTENT
	marker.Parent = row

	local entry: Row = {
		frame = row,
		id = theme.id,
		marker = marker,
		stroke = stroke,
		accent = accent,
		hovered = false,
	}

	row.MouseEnter:Connect(function()
		hold()
		entry.hovered = true
		TweenService:Create(row, HOVER, { BackgroundColor3 = lifted }):Play()
		TweenService:Create(stroke, HOVER, { Transparency = STROKE_HOVER }):Play()
	end)
	row.MouseLeave:Connect(function()
		entry.hovered = false
		TweenService:Create(row, HOVER, { BackgroundColor3 = rest }):Play()
		TweenService:Create(stroke, HOVER, {
			Transparency = restingStroke(entry.id == Themes.activeId()),
		}):Play()
	end)

	row.MouseButton1Click:Connect(function()
		local root = runtime.root
		if root == nil then
			return
		end
		-- Re-picking the current theme is a no-op rather than a free repaint of
		-- three hundred log rows.
		if not Themes.use(theme.id) then
			setOpen(false)
			return
		end
		local previous = root.BackgroundColor3
		setOpen(false)
		crossfade(root, previous, function()
			local handler = runtime.onPicked
			if handler then
				handler(theme.id)
			end
		end)
		markActive()
	end)

	table.insert(runtime.rows, entry)
end

--[[
	Builds the tab and the drawer.

	`onPicked` is called with the new id AFTER `Themes.use` has switched, so the
	caller repaints and persists rather than this module knowing how either is
	done -- `plugin:SetSetting` is not reachable from a ModuleScript anyway.
]]
function ThemePicker.mount(root: Frame, onPicked: (string) -> ())
	runtime.root = root
	runtime.onPicked = onPicked
	runtime.rows = {}

	local palette = Themes.palette()

	local drawer = Instance.new("Frame")
	drawer.Name = "ThemeDrawer"
	-- Anchored to its own right edge at the tab's height: at width zero it is a
	-- line where the tab is, which is what it grows out of.
	drawer.AnchorPoint = Vector2.new(1, 0.5)
	drawer.Position = UDim2.new(1, -TAB_WIDTH, 0.5, 0)
	drawer.Size = UDim2.fromOffset(0, drawerHeight())
	drawer.BackgroundColor3 = palette.surface
	drawer.BorderSizePixel = 0
	drawer.ClipsDescendants = true
	drawer.ZIndex = Z_DRAWER
	drawer.Parent = root
	runtime.drawer = drawer

	local drawerCorner = Instance.new("UICorner")
	drawerCorner.CornerRadius = UDim.new(0, 8)
	drawerCorner.Parent = drawer

	local drawerStroke = Instance.new("UIStroke")
	drawerStroke.Color = palette.rule
	drawerStroke.Transparency = 0.6
	drawerStroke.Parent = drawer

	local heading = Instance.new("TextLabel")
	heading.Name = "Heading"
	heading.BackgroundTransparency = 1
	heading.Position = UDim2.fromOffset(PADDING + 2, PADDING - 2)
	heading.Size = UDim2.fromOffset(DRAWER_WIDTH - PADDING * 2, HEADER_HEIGHT)
	heading.Font = Enum.Font.Code
	heading.TextSize = 10
	heading.TextColor3 = palette.dim
	heading.TextXAlignment = Enum.TextXAlignment.Left
	heading.Text = "THEME"
	heading.ZIndex = Z_LIST
	heading.Parent = drawer
	runtime.heading = heading

	local list = Instance.new("Frame")
	list.Name = "Rows"
	list.Position = UDim2.fromOffset(PADDING, PADDING + HEADER_HEIGHT)
	-- Sized to the open width rather than to the parent, so the rows do not
	-- squash and reflow through every frame of the tween.
	list.Size = UDim2.fromOffset(
		DRAWER_WIDTH - PADDING * 2,
		drawerHeight() - PADDING * 2 - HEADER_HEIGHT
	)
	list.BackgroundTransparency = 1
	list.ZIndex = Z_LIST
	list.Parent = drawer

	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Vertical
	layout.Padding = UDim.new(0, 2)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = list

	for order, theme in Themes.list() do
		buildRow(list, theme, order)
	end
	markActive()

	local tab = Instance.new("TextButton")
	tab.Name = "ThemeTab"
	tab.Text = ""
	tab.AutoButtonColor = false
	tab.AnchorPoint = Vector2.new(1, 0.5)
	tab.Position = UDim2.new(1, 0, 0.5, 0)
	tab.Size = UDim2.fromOffset(TAB_WIDTH, TAB_HEIGHT)
	tab.BackgroundColor3 = palette.surface
	tab.BorderSizePixel = 0
	tab.ZIndex = Z_TAB
	tab.Parent = root
	runtime.tab = tab

	local tabCorner = Instance.new("UICorner")
	tabCorner.CornerRadius = UDim.new(0, 4)
	tabCorner.Parent = tab

	local chevron = Instance.new("TextLabel")
	chevron.Name = "Chevron"
	chevron.AnchorPoint = Vector2.new(0.5, 0.5)
	chevron.Position = UDim2.fromScale(0.5, 0.5)
	chevron.Size = UDim2.fromOffset(TAB_WIDTH, TAB_WIDTH)
	chevron.BackgroundTransparency = 1
	chevron.Font = Enum.Font.Code
	chevron.TextSize = 12
	chevron.TextColor3 = palette.rule
	chevron.Text = "\u{25C0}"
	chevron.ZIndex = Z_TAB + 1
	chevron.Parent = tab
	runtime.chevron = chevron

	tab.MouseEnter:Connect(function()
		hold()
		setOpen(true)
	end)
	tab.MouseLeave:Connect(scheduleClose)
	drawer.MouseEnter:Connect(hold)
	drawer.MouseLeave:Connect(scheduleClose)

	-- Clicking works too. Hover is the affordance, but a tab that only responds
	-- to hover is unreachable to anyone driving Studio from the keyboard or a
	-- tablet, and this costs one line.
	tab.MouseButton1Click:Connect(function()
		hold()
		setOpen(not runtime.open)
	end)
end

--[[
	Recolours the tab and drawer chrome after a switch.

	The ROWS are deliberately left alone: each one wears its own preset's
	palette and always did, which is what makes the drawer a preview rather
	than a list.
]]
function ThemePicker.applyTheme()
	local palette = Themes.palette()
	local drawer = runtime.drawer
	local tab = runtime.tab
	local chevron = runtime.chevron
	local heading = runtime.heading

	if drawer then
		drawer.BackgroundColor3 = palette.surface
		local stroke = drawer:FindFirstChildOfClass("UIStroke")
		if stroke then
			stroke.Color = palette.rule
		end
	end
	if tab then
		tab.BackgroundColor3 = palette.surface
	end
	if chevron then
		chevron.TextColor3 = palette.rule
	end
	if heading then
		heading.TextColor3 = palette.dim
	end
	markActive()
end

return ThemePicker
