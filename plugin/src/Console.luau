--!strict
--[[
	Terminal-style status console for the plugin widget.

	This is the only feedback channel the plugin has. It deliberately never
	writes to Studio's Output window, because that log is also what the agent
	reads back through the console tool -- plugin chatter there would pollute the
	very thing it is reporting on.

	Rendering is one RichText label inside a ScrollingFrame rather than a label
	per line. Managing hundreds of Instances for a log that scrolls constantly is
	both slower and more code; one string with colour spans does the same job.
]]

local Console = {}

-- Ring buffer bound. Long enough to cover a working session, short enough that
-- re-rendering the whole string on every append stays cheap.
local MAX_LINES = 300

local PALETTE = {
	background = Color3.fromRGB(13, 14, 18),
	surface = Color3.fromRGB(20, 22, 28),
	text = Color3.fromRGB(202, 208, 219),
	dim = Color3.fromRGB(110, 117, 133),
	green = Color3.fromRGB(126, 211, 133),
	red = Color3.fromRGB(240, 113, 120),
	yellow = Color3.fromRGB(229, 192, 123),
	cyan = Color3.fromRGB(97, 175, 239),
	violet = Color3.fromRGB(180, 142, 235),
}

local LEVEL_COLOR = {
	ok = PALETTE.green,
	error = PALETTE.red,
	warn = PALETTE.yellow,
	info = PALETTE.text,
	dim = PALETTE.dim,
	call = PALETTE.cyan,
	reply = PALETTE.violet,
}

export type Level = "ok" | "error" | "warn" | "info" | "dim" | "call" | "reply"

type State = {
	lines: { string },
	label: TextLabel?,
	scroller: ScrollingFrame?,
	statusDot: TextLabel?,
	statusText: TextLabel?,
	metaText: TextLabel?,
	pinned: boolean,
}

local state: State = {
	lines = {},
	label = nil,
	scroller = nil,
	statusDot = nil,
	statusText = nil,
	metaText = nil,
	pinned = true,
}

local function hex(color: Color3): string
	return string.format(
		"#%02X%02X%02X",
		math.floor(color.R * 255 + 0.5),
		math.floor(color.G * 255 + 0.5),
		math.floor(color.B * 255 + 0.5)
	)
end

-- RichText is markup, so anything user- or engine-supplied has to be escaped or
-- a stray `<` in an error message silently eats the rest of the line.
local function escape(value: string): string
	local escaped = string.gsub(value, "&", "&amp;")
	escaped = string.gsub(escaped, "<", "&lt;")
	escaped = string.gsub(escaped, ">", "&gt;")
	return escaped
end

local function span(color: Color3, value: string): string
	return string.format('<font color="%s">%s</font>', hex(color), escape(value))
end

local function timestamp(): string
	return os.date("%H:%M:%S") :: string
end

local function redraw()
	local label = state.label
	if not label then
		return
	end
	label.Text = table.concat(state.lines, "\n")

	-- Only follow the tail when the user has not scrolled up to read history.
	local scroller = state.scroller
	if scroller and state.pinned then
		task.defer(function()
			if scroller.Parent then
				scroller.CanvasPosition = Vector2.new(0, math.max(0, scroller.AbsoluteCanvasSize.Y))
			end
		end)
	end
end

--[[
	Appends one line. `detail` is rendered dim after the message, for things like
	latencies that should be readable but not compete with the message itself.
]]
function Console.log(level: Level, message: string, detail: string?)
	local color = LEVEL_COLOR[level] or PALETTE.text
	local line = span(PALETTE.dim, timestamp()) .. " " .. span(color, message)
	if detail then
		line ..= " " .. span(PALETTE.dim, detail)
	end

	table.insert(state.lines, line)
	while #state.lines > MAX_LINES do
		table.remove(state.lines, 1)
	end
	redraw()
end

function Console.clear()
	table.clear(state.lines)
	redraw()
end

--[[
	Updates the header. Kept separate from the log so the current state is always
	visible without scrolling, however long the session has run.
]]
function Console.setStatus(status: string, meta: string)
	local dot = state.statusDot
	local text = state.statusText
	local metaLabel = state.metaText
	if not dot or not text or not metaLabel then
		return
	end

	local color = if status == "connected"
		then PALETTE.green
		elseif status == "connecting" then PALETTE.yellow
		else PALETTE.red

	dot.TextColor3 = color
	text.Text = status
	text.TextColor3 = color
	metaLabel.Text = meta
end

local function makeButton(parent: Instance, text: string, order: number): TextButton
	local button = Instance.new("TextButton")
	button.Name = text
	button.Text = text
	button.Font = Enum.Font.Code
	button.TextSize = 12
	button.TextColor3 = PALETTE.dim
	button.BackgroundColor3 = PALETTE.surface
	button.AutoButtonColor = false
	button.BorderSizePixel = 0
	button.Size = UDim2.new(0, 78, 1, -10)
	button.LayoutOrder = order
	button.Parent = parent

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 4)
	corner.Parent = button

	button.MouseEnter:Connect(function()
		button.TextColor3 = PALETTE.text
	end)
	button.MouseLeave:Connect(function()
		button.TextColor3 = PALETTE.dim
	end)

	return button
end

export type Handlers = {
	onReconnect: () -> (),
	onClear: () -> (),
}

--[[
	Builds the widget contents. Colours are fixed rather than theme-derived: this
	is a console, and a console that repaints itself light grey reads as a form.
]]
function Console.mount(parent: Instance, handlers: Handlers)
	local root = Instance.new("Frame")
	root.Size = UDim2.fromScale(1, 1)
	root.BackgroundColor3 = PALETTE.background
	root.BorderSizePixel = 0
	root.Parent = parent

	-- Header ---------------------------------------------------------------
	local header = Instance.new("Frame")
	header.Size = UDim2.new(1, 0, 0, 34)
	header.BackgroundColor3 = PALETTE.surface
	header.BorderSizePixel = 0
	header.Parent = root

	local headerPadding = Instance.new("UIPadding")
	headerPadding.PaddingLeft = UDim.new(0, 10)
	headerPadding.PaddingRight = UDim.new(0, 6)
	headerPadding.Parent = header

	local dot = Instance.new("TextLabel")
	dot.Text = "\u{25CF}"
	dot.Font = Enum.Font.Code
	dot.TextSize = 14
	dot.TextColor3 = PALETTE.red
	dot.BackgroundTransparency = 1
	dot.Size = UDim2.new(0, 12, 1, 0)
	dot.Parent = header
	state.statusDot = dot

	local status = Instance.new("TextLabel")
	status.Text = "disconnected"
	status.Font = Enum.Font.Code
	status.TextSize = 13
	status.TextColor3 = PALETTE.red
	status.TextXAlignment = Enum.TextXAlignment.Left
	status.BackgroundTransparency = 1
	status.Position = UDim2.new(0, 16, 0, 0)
	status.Size = UDim2.new(0, 100, 1, 0)
	status.Parent = header
	state.statusText = status

	local meta = Instance.new("TextLabel")
	meta.Text = ""
	meta.Font = Enum.Font.Code
	meta.TextSize = 12
	meta.TextColor3 = PALETTE.dim
	meta.TextXAlignment = Enum.TextXAlignment.Left
	meta.TextTruncate = Enum.TextTruncate.AtEnd
	meta.BackgroundTransparency = 1
	meta.Position = UDim2.new(0, 120, 0, 0)
	meta.Size = UDim2.new(1, -300, 1, 0)
	meta.Parent = header
	state.metaText = meta

	local buttons = Instance.new("Frame")
	buttons.AnchorPoint = Vector2.new(1, 0)
	buttons.Position = UDim2.fromScale(1, 0)
	buttons.Size = UDim2.new(0, 166, 1, 0)
	buttons.BackgroundTransparency = 1
	buttons.Parent = header

	local buttonLayout = Instance.new("UIListLayout")
	buttonLayout.FillDirection = Enum.FillDirection.Horizontal
	buttonLayout.HorizontalAlignment = Enum.HorizontalAlignment.Right
	buttonLayout.VerticalAlignment = Enum.VerticalAlignment.Center
	buttonLayout.Padding = UDim.new(0, 6)
	buttonLayout.SortOrder = Enum.SortOrder.LayoutOrder
	buttonLayout.Parent = buttons

	makeButton(buttons, "reconnect", 1).MouseButton1Click:Connect(handlers.onReconnect)
	makeButton(buttons, "clear", 2).MouseButton1Click:Connect(handlers.onClear)

	-- Log ------------------------------------------------------------------
	local scroller = Instance.new("ScrollingFrame")
	scroller.Position = UDim2.new(0, 0, 0, 34)
	scroller.Size = UDim2.new(1, 0, 1, -34)
	scroller.BackgroundTransparency = 1
	scroller.BorderSizePixel = 0
	scroller.ScrollBarThickness = 6
	scroller.ScrollBarImageColor3 = PALETTE.dim
	scroller.CanvasSize = UDim2.new()
	scroller.AutomaticCanvasSize = Enum.AutomaticSize.Y
	scroller.ScrollingDirection = Enum.ScrollingDirection.Y
	scroller.Parent = root
	state.scroller = scroller

	local logPadding = Instance.new("UIPadding")
	logPadding.PaddingTop = UDim.new(0, 8)
	logPadding.PaddingBottom = UDim.new(0, 8)
	logPadding.PaddingLeft = UDim.new(0, 10)
	logPadding.PaddingRight = UDim.new(0, 10)
	logPadding.Parent = scroller

	local label = Instance.new("TextLabel")
	label.Size = UDim2.new(1, 0, 0, 0)
	label.AutomaticSize = Enum.AutomaticSize.Y
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.Code
	label.TextSize = 12
	label.TextColor3 = PALETTE.text
	label.RichText = true
	label.TextWrapped = true
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.TextYAlignment = Enum.TextYAlignment.Top
	label.Text = ""
	label.Parent = scroller
	state.label = label

	-- Treat "scrolled away from the bottom" as the user reading history, and
	-- stop yanking the view down under them until they scroll back.
	scroller:GetPropertyChangedSignal("CanvasPosition"):Connect(function()
		local maxScroll = math.max(0, scroller.AbsoluteCanvasSize.Y - scroller.AbsoluteWindowSize.Y)
		state.pinned = maxScroll - scroller.CanvasPosition.Y < 24
	end)
end

return Console
