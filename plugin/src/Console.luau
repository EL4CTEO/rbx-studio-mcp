--!strict
--[[
	The Studio MCP console.

	This is the only feedback channel the plugin has. It deliberately never
	writes to Studio's Output window, because that log is also what the agent
	reads back through the console tool -- plugin chatter there would pollute the
	very thing it is reporting on.

	Visual design is deliberate rather than default-dark: a sigil gutter that
	makes call/reply/error scannable without reading the text, right-aligned
	latencies that line up into a column you can eyeball for outliers, and a live
	status bar with session counters. Every glyph is drawn from a monospace-safe
	set so the columns stay true at any width.

	Rendering is one RichText label inside a ScrollingFrame rather than a label
	per line. A log that scrolls constantly should not churn hundreds of
	Instances, and colour spans do the same job in a fraction of the code.
]]

local Visuals = require(script.Parent.Visuals)

local Console = {}

-- Ring buffer bound. Long enough to cover a working session, short enough that
-- re-rendering the whole string on every append stays cheap.
local MAX_LINES = 300

-- Violet-tinted near-black. The cast is slight but it stops the panel reading
-- as the same grey as every other Studio dock.
local PALETTE = {
	background = Color3.fromRGB(11, 12, 20),
	surface = Color3.fromRGB(18, 20, 31),
	rule = Color3.fromRGB(167, 139, 250),
	text = Color3.fromRGB(206, 212, 226),
	dim = Color3.fromRGB(90, 97, 120),
	green = Color3.fromRGB(110, 231, 168),
	red = Color3.fromRGB(251, 113, 133),
	amber = Color3.fromRGB(251, 191, 36),
	cyan = Color3.fromRGB(103, 232, 249),
	violet = Color3.fromRGB(167, 139, 250),
}

-- Sigil plus colour per level. The sigil is what makes the log scannable at a
-- glance; colour alone fails for anyone who cannot separate red from green.
local LEVELS: { [string]: { sigil: string, color: Color3 } } = {
	ok = { sigil = "\u{25C6}", color = PALETTE.green },
	error = { sigil = "\u{2715}", color = PALETTE.red },
	warn = { sigil = "\u{25B2}", color = PALETTE.amber },
	info = { sigil = "\u{25C6}", color = PALETTE.violet },
	dim = { sigil = "\u{00B7}", color = PALETTE.dim },
	call = { sigil = "\u{25B8}", color = PALETTE.cyan },
	reply = { sigil = "\u{25C2}", color = PALETTE.violet },
}

export type Level = "ok" | "error" | "warn" | "info" | "dim" | "call" | "reply"

-- Column the right-aligned detail is padded out to, in characters. Latencies
-- landing in one column is what lets you spot a slow call without reading.
local DETAIL_COLUMN = 64

type State = {
	lines: { string },
	label: TextLabel?,
	scroller: ScrollingFrame?,
	statusDot: TextLabel?,
	statusText: TextLabel?,
	metaText: TextLabel?,
	cursor: TextLabel?,
	countersText: TextLabel?,
	pinned: boolean,
	calls: number,
	errors: number,
	totalMs: number,
}

local state: State = {
	lines = {},
	label = nil,
	scroller = nil,
	statusDot = nil,
	statusText = nil,
	metaText = nil,
	cursor = nil,
	countersText = nil,
	pinned = true,
	calls = 0,
	errors = 0,
	totalMs = 0,
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

local function refreshCounters()
	local counters = state.countersText
	if not counters then
		return
	end
	if state.calls == 0 then
		counters.Text = "idle"
		return
	end
	counters.Text = string.format(
		"%d call%s  %d error%s  avg %.0fms",
		state.calls,
		if state.calls == 1 then "" else "s",
		state.errors,
		if state.errors == 1 then "" else "s",
		state.totalMs / state.calls
	)
end

--[[
	Appends one line. `detail` is padded to a fixed column and dimmed, so
	latencies stack into a readable column instead of trailing each message at a
	ragged offset.
]]
function Console.log(level: Level, message: string, detail: string?)
	local spec = LEVELS[level] or LEVELS.info

	local body = string.format("%s %s", spec.sigil, message)
	local line = span(PALETTE.dim, os.date("%H:%M:%S") :: string) .. " " .. span(spec.color, body)

	if detail then
		local padding = math.max(1, DETAIL_COLUMN - #body)
		line ..= span(PALETTE.dim, string.rep(" ", padding) .. detail)
	end

	table.insert(state.lines, line)
	while #state.lines > MAX_LINES do
		table.remove(state.lines, 1)
	end
	redraw()
end

--[[
	Announces a command as it starts, in words rather than in wire names.

	Both halves of the panel are told: the log keeps the permanent record, the
	visual canvas shows it as motion. They are fed from one call so the two can
	never disagree about what is running.
]]
function Console.beginCall(title: string, detail: string?)
	Console.log("call", title, detail)
	Visuals.setCaption(title, detail)
	Visuals.pulse(PALETTE.cyan, 0.35)
end

--[[
	Records one completed command for the session counters. Kept separate from
	`log` so callers can log freely without skewing the statistics.
]]
function Console.recordCall(ok: boolean, milliseconds: number)
	state.calls += 1
	state.totalMs += milliseconds
	if not ok then
		state.errors += 1
	end
	refreshCounters()

	-- A reply pulses back in its outcome's colour, and a failure also knocks the
	-- solid off its axis: the one motion in the panel that is meant to look
	-- wrong, so a failure registers even when nobody is reading the text.
	Visuals.pulse(if ok then PALETTE.violet else PALETTE.red, if ok then 0.3 else 0.8)
	if not ok then
		Visuals.jolt()
	end
end

function Console.clear()
	table.clear(state.lines)
	state.calls = 0
	state.errors = 0
	state.totalMs = 0
	refreshCounters()
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

	-- "standby" is a working state, not a fault: the client half of a playtest
	-- cannot use HTTP and is not meant to connect. Painting it red like a real
	-- disconnection made a correct setup look broken.
	local color = if status == "connected"
		then PALETTE.green
		elseif status == "connecting" then PALETTE.amber
		elseif status == "standby" then PALETTE.dim
		else PALETTE.red

	dot.TextColor3 = color
	text.Text = string.upper(status)
	text.TextColor3 = color
	metaLabel.Text = meta

	-- The wireframe takes the same colour as the status light, so the panel
	-- reads as disconnected at a glance even with the header off screen.
	Visuals.setTint(color)
	if status ~= "connected" then
		Visuals.setCaption(string.lower(status), meta)
	end
end

local function makeButton(parent: Instance, text: string, order: number): TextButton
	local button = Instance.new("TextButton")
	button.Name = text
	button.Text = text
	button.Font = Enum.Font.Code
	button.TextSize = 11
	button.TextColor3 = PALETTE.dim
	button.BackgroundColor3 = PALETTE.background
	button.AutoButtonColor = false
	button.BorderSizePixel = 0
	button.Size = UDim2.new(0, 76, 0, 20)
	button.LayoutOrder = order
	button.Parent = parent

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 3)
	corner.Parent = button

	local stroke = Instance.new("UIStroke")
	stroke.Color = PALETTE.dim
	stroke.Transparency = 0.6
	stroke.Parent = button

	button.MouseEnter:Connect(function()
		button.TextColor3 = PALETTE.violet
		stroke.Color = PALETTE.violet
		stroke.Transparency = 0.3
	end)
	button.MouseLeave:Connect(function()
		button.TextColor3 = PALETTE.dim
		stroke.Color = PALETTE.dim
		stroke.Transparency = 0.6
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
	header.Size = UDim2.new(1, 0, 0, 32)
	header.BackgroundColor3 = PALETTE.surface
	header.BorderSizePixel = 0
	header.Parent = root

	local headerPadding = Instance.new("UIPadding")
	headerPadding.PaddingLeft = UDim.new(0, 12)
	headerPadding.PaddingRight = UDim.new(0, 8)
	headerPadding.Parent = header

	local dot = Instance.new("TextLabel")
	dot.Text = "\u{25CF}"
	dot.Font = Enum.Font.Code
	dot.TextSize = 13
	dot.TextColor3 = PALETTE.red
	dot.BackgroundTransparency = 1
	dot.Size = UDim2.new(0, 12, 1, 0)
	dot.Parent = header
	state.statusDot = dot

	local status = Instance.new("TextLabel")
	status.Text = "DISCONNECTED"
	status.Font = Enum.Font.Code
	status.TextSize = 12
	status.TextColor3 = PALETTE.red
	status.TextXAlignment = Enum.TextXAlignment.Left
	status.BackgroundTransparency = 1
	status.Position = UDim2.new(0, 18, 0, 0)
	status.Size = UDim2.new(0, 110, 1, 0)
	status.Parent = header
	state.statusText = status

	local meta = Instance.new("TextLabel")
	meta.Text = ""
	meta.Font = Enum.Font.Code
	meta.TextSize = 11
	meta.TextColor3 = PALETTE.dim
	meta.TextXAlignment = Enum.TextXAlignment.Left
	meta.TextTruncate = Enum.TextTruncate.AtEnd
	meta.BackgroundTransparency = 1
	meta.Position = UDim2.new(0, 132, 0, 0)
	meta.Size = UDim2.new(1, -394, 1, 0)
	meta.Parent = header
	state.metaText = meta

	local buttons = Instance.new("Frame")
	buttons.AnchorPoint = Vector2.new(1, 0.5)
	buttons.Position = UDim2.new(1, 0, 0.5, 0)
	buttons.Size = UDim2.new(0, 244, 0, 20)
	buttons.BackgroundTransparency = 1
	buttons.Parent = header

	local buttonLayout = Instance.new("UIListLayout")
	buttonLayout.FillDirection = Enum.FillDirection.Horizontal
	buttonLayout.HorizontalAlignment = Enum.HorizontalAlignment.Right
	buttonLayout.VerticalAlignment = Enum.VerticalAlignment.Center
	buttonLayout.Padding = UDim.new(0, 6)
	buttonLayout.SortOrder = Enum.SortOrder.LayoutOrder
	buttonLayout.Parent = buttons

	local visualsButton = makeButton(buttons, "visuals", 1)
	makeButton(buttons, "reconnect", 2).MouseButton1Click:Connect(handlers.onReconnect)
	makeButton(buttons, "clear", 3).MouseButton1Click:Connect(handlers.onClear)

	-- Accent rule under the header. One hairline in the signature violet is what
	-- separates this from every other grey dock in Studio.
	local rule = Instance.new("Frame")
	rule.Position = UDim2.new(0, 0, 0, 32)
	rule.Size = UDim2.new(1, 0, 0, 1)
	rule.BackgroundColor3 = PALETTE.rule
	rule.BorderSizePixel = 0
	rule.Parent = root

	local ruleFade = Instance.new("UIGradient")
	ruleFade.Color = ColorSequence.new(PALETTE.rule)
	ruleFade.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.15),
		NumberSequenceKeypoint.new(1, 0.85),
	})
	ruleFade.Parent = rule

	-- Log ------------------------------------------------------------------
	local scroller = Instance.new("ScrollingFrame")
	scroller.Position = UDim2.new(0, 0, 0, 33)
	scroller.Size = UDim2.new(1, 0, 1, -55)
	scroller.BackgroundTransparency = 1
	scroller.BorderSizePixel = 0
	scroller.ScrollBarThickness = 5
	scroller.ScrollBarImageColor3 = PALETTE.violet
	scroller.ScrollBarImageTransparency = 0.5
	scroller.CanvasSize = UDim2.new()
	scroller.AutomaticCanvasSize = Enum.AutomaticSize.Y
	scroller.ScrollingDirection = Enum.ScrollingDirection.Y
	scroller.Parent = root
	state.scroller = scroller

	local logPadding = Instance.new("UIPadding")
	logPadding.PaddingTop = UDim.new(0, 8)
	logPadding.PaddingBottom = UDim.new(0, 8)
	logPadding.PaddingLeft = UDim.new(0, 12)
	logPadding.PaddingRight = UDim.new(0, 12)
	logPadding.Parent = scroller

	local label = Instance.new("TextLabel")
	label.Size = UDim2.new(1, 0, 0, 0)
	label.AutomaticSize = Enum.AutomaticSize.Y
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.Code
	label.TextSize = 12
	label.LineHeight = 1.25
	label.TextColor3 = PALETTE.text
	label.RichText = true
	label.TextWrapped = true
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.TextYAlignment = Enum.TextYAlignment.Top
	label.Text = ""
	label.Parent = scroller
	state.label = label

	-- Status bar ------------------------------------------------------------
	local footer = Instance.new("Frame")
	footer.AnchorPoint = Vector2.new(0, 1)
	footer.Position = UDim2.fromScale(0, 1)
	footer.Size = UDim2.new(1, 0, 0, 22)
	footer.BackgroundColor3 = PALETTE.surface
	footer.BorderSizePixel = 0
	footer.Parent = root

	local footerPadding = Instance.new("UIPadding")
	footerPadding.PaddingLeft = UDim.new(0, 12)
	footerPadding.PaddingRight = UDim.new(0, 12)
	footerPadding.Parent = footer

	local prompt = Instance.new("TextLabel")
	prompt.Text = "studio\u{00B7}mcp"
	prompt.Font = Enum.Font.Code
	prompt.TextSize = 11
	prompt.TextColor3 = PALETTE.violet
	prompt.TextXAlignment = Enum.TextXAlignment.Left
	prompt.BackgroundTransparency = 1
	prompt.Size = UDim2.new(0, 70, 1, 0)
	prompt.Parent = footer

	-- A blinking block cursor: the cheapest possible signal that the panel is
	-- live rather than a frozen screenshot of an old session.
	local cursor = Instance.new("TextLabel")
	cursor.Text = "\u{2588}"
	cursor.Font = Enum.Font.Code
	cursor.TextSize = 11
	cursor.TextColor3 = PALETTE.violet
	cursor.TextXAlignment = Enum.TextXAlignment.Left
	cursor.BackgroundTransparency = 1
	cursor.Position = UDim2.new(0, 72, 0, 0)
	cursor.Size = UDim2.new(0, 10, 1, 0)
	cursor.Parent = footer
	state.cursor = cursor

	local counters = Instance.new("TextLabel")
	counters.Text = "idle"
	counters.Font = Enum.Font.Code
	counters.TextSize = 11
	counters.TextColor3 = PALETTE.dim
	counters.TextXAlignment = Enum.TextXAlignment.Right
	counters.BackgroundTransparency = 1
	counters.AnchorPoint = Vector2.new(1, 0)
	counters.Position = UDim2.fromScale(1, 0)
	counters.Size = UDim2.new(1, -90, 1, 0)
	counters.Parent = footer
	state.countersText = counters

	task.spawn(function()
		while cursor.Parent do
			cursor.TextTransparency = if cursor.TextTransparency > 0.5 then 0 else 1
			task.wait(0.6)
		end
	end)

	--[[
		The visual panel sits over the log rather than beside it.

		Splitting the widget would give each half too little room in a dock this
		size, and the two are not read at once anyway: the log is for reading
		back what happened, the visuals for watching what is happening now.
	]]
	Visuals.mount(scroller.Parent :: Instance, {
		background = PALETTE.background,
		text = PALETTE.text,
		dim = PALETTE.dim,
	})
	local visualsCanvas = (scroller.Parent :: Instance):FindFirstChild("Visuals") :: Frame
	visualsCanvas.Position = UDim2.new(0, 0, 0, 33)
	visualsCanvas.Size = UDim2.new(1, 0, 1, -55)

	visualsButton.MouseButton1Click:Connect(function()
		local nowOn = not Visuals.isVisible()
		Visuals.setVisible(nowOn)
		-- The button reports the state it is in, not the state it would move to.
		-- A toggle that reads as an instruction is ambiguous the moment you look
		-- away and back.
		visualsButton.Text = if nowOn then "\u{25C6} visuals" else "visuals"
		if nowOn then
			Visuals.setCaption("watching", "waiting for the first command")
		end
	end)

	-- Treat "scrolled away from the bottom" as the user reading history, and
	-- stop yanking the view down under them until they scroll back.
	scroller:GetPropertyChangedSignal("CanvasPosition"):Connect(function()
		local maxScroll = math.max(0, scroller.AbsoluteCanvasSize.Y - scroller.AbsoluteWindowSize.Y)
		state.pinned = maxScroll - scroller.CanvasPosition.Y < 24
	end)
end

return Console
