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

--[[
	Column the right-aligned detail is padded out to, in characters.

	Sized for the widget's default width rather than for the longest message: at
	12pt Code with a timestamp ahead of it, anything past this wraps, and a
	wrapped line breaks the very column the padding exists to produce. Messages
	are cut to fit instead.
]]
local DETAIL_COLUMN = 52

--[[
	How far past the column an inline detail may run before it is moved below the
	message instead. A latency fits; a sentence does not.
]]
local INLINE_DETAIL = 14

-- Continuation lines sit under the message text, clear of the timestamp and the
-- sigil, so a wrapped explanation reads as belonging to the line above it.
local DETAIL_INDENT = string.rep(" ", 11)

-- Characters per continuation line. Fixed rather than measured from the widget:
-- the console is monospaced, and a width that changes as the user drags the
-- panel would rewrap history every frame.
local DETAIL_WRAP = 74

--[[
	Breaks a long detail into lines at word boundaries.

	Roblox's own TextWrapped would do this, and would wrap to column 0 -- there
	is no hanging indent for a TextLabel -- which is the ragged shape this
	replaces. Wrapping here means every continuation line can carry the indent.
]]
local function wrapDetail(detail: string): { string }
	local lines: { string } = {}
	local current = ""
	for word in string.gmatch(detail, "%S+") do
		local candidate = if current == "" then word else current .. " " .. word
		if (utf8.len(candidate) or #candidate) > DETAIL_WRAP and current ~= "" then
			table.insert(lines, current)
			current = word
		else
			current = candidate
		end
	end
	if current ~= "" then
		table.insert(lines, current)
	end
	return lines
end

type State = {
	lines: { string },
	label: TextLabel?,
	scroller: ScrollingFrame?,
	statusDot: TextLabel?,
	statusText: TextLabel?,
	metaText: TextLabel?,
	countersText: TextLabel?,
	pinned: boolean,
	calls: number,
	errors: number,
	totalMs: number,
	-- The command in flight, shown in the footer while it runs. One value that
	-- is replaced, never a list that grows.
	running: string?,
}

local state: State = {
	lines = {},
	label = nil,
	scroller = nil,
	statusDot = nil,
	statusText = nil,
	metaText = nil,
	countersText = nil,
	pinned = true,
	calls = 0,
	errors = 0,
	totalMs = 0,
	running = nil,
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
	--[[
		The footer is for totals, and only totals.

		It briefly doubled as the in-flight readout, which meant a running
		command overwrote "4 calls 0 errors avg 84ms" with its own name -- the
		session statistics disappearing exactly when the session was busiest.
		Two live readouts on one small panel is one too many, and the band
		already has the better spot for it, right beside the solid.
	]]
	counters.TextColor3 = PALETTE.dim
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

	--[[
		Measured in characters, not bytes.

		`#body` counts bytes, and every sigil in this console is a 3-byte UTF-8
		glyph, so it over-counted each line by two and pushed the latency column
		two places left on exactly the lines that had a latency. The column was
		never straight, and the cause was invisible until two different sigils
		sat next to each other.
	]]
	--[[
		Only a detail that will actually sit in the column costs the message any
		of its width. Cutting the message to make room for a detail that then
		goes on its own line below would shorten it for nothing.
	]]
	local detailWidth = if detail then (utf8.len(detail) or #detail) else 0
	local inlineDetail = detail ~= nil
		and (utf8.len(message) or #message) + detailWidth + 3 <= DETAIL_COLUMN + INLINE_DETAIL

	local trimmed = message
	local budget = DETAIL_COLUMN - 3
	if inlineDetail and (utf8.len(trimmed) or #trimmed) > budget then
		-- Cut rather than wrap. A wrapped line destroys the alignment and
		-- carries the detail off the end of the visible width as well.
		local offset = utf8.offset(trimmed, budget) or budget
		trimmed = string.sub(trimmed, 1, offset - 1) .. utf8.char(0x2026)
	end

	local body = string.format("%s %s", spec.sigil, trimmed)
	local bodyWidth = utf8.len(body) or #body
	local line = span(PALETTE.dim, os.date("%H:%M:%S") :: string) .. " " .. span(spec.color, body)

	--[[
		Short details ride the right-hand column; long ones get their own lines.

		The column exists for latencies -- "12ms" stacking into something
		readable -- and it was applied to every detail regardless of length. A
		sentence of prose therefore started at column 52, ran off the widget, and
		wrapped back to column 0, so the explanation of a standby session came
		out as a ragged block that began in the middle of the screen and ended at
		the left edge. Anything that will not fit beside the message is better
		off beneath it.
	]]
	table.insert(state.lines, line)
	if detail then
		if inlineDetail then
			local padding = math.max(1, DETAIL_COLUMN - bodyWidth)
			state.lines[#state.lines] ..= span(PALETTE.dim, string.rep(" ", padding) .. detail)
		else
			for _, wrapped in wrapDetail(detail) do
				table.insert(state.lines, span(PALETTE.dim, DETAIL_INDENT .. wrapped))
			end
		end
	end
	while #state.lines > MAX_LINES do
		table.remove(state.lines, 1)
	end
	redraw()
end

--[[
	Announces a command as it starts -- everywhere except the log.

	This used to append a line, and then the reply appended a second one saying
	the same thing in a different colour. Every call cost two rows and read as
	duplicated output, which is exactly what it was: a cyan "Edit KillBrick"
	followed by a violet "Edit KillBrick".

	The log now takes one line per call, written when it finishes and carrying
	the latency it took. What is running *right now* belongs in a place that
	updates rather than accumulates, so it goes to the footer and the activity
	band -- both of which show a single current value and neither of which grows.
]]
--[[
	Colour and pace per kind of work, so the band reads as what is happening.

	Reads are cool and quick because they are constant and harmless; writes are
	violet and slower because they change the user's game; running code is green
	and heavier still. Urgency drives both the spin rate and how strongly the
	colour takes over, so the two never disagree.
]]
local KIND_LOOK: { [string]: { color: Color3, urgency: number } } = {
	read = { color = PALETTE.cyan, urgency = 0.3 },
	write = { color = PALETTE.violet, urgency = 0.7 },
	run = { color = PALETTE.green, urgency = 0.9 },
	debug = { color = PALETTE.amber, urgency = 0.5 },
}

function Console.beginCall(title: string, kind: string)
	state.running = title
	local look = KIND_LOOK[kind] or KIND_LOOK.read
	Visuals.setCaption(title)
	Visuals.setKind(look.color, look.urgency)
	refreshCounters()
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
	state.running = nil
	refreshCounters()
	-- The footer reports totals when idle, so the band shows what just ran
	-- instead of repeating the same word on the same screen.
	Visuals.setIdle()

	-- The band plots it: bar height is how long it took, colour is whether it
	-- worked, and a failure knocks the solid off its axis as well.
	Visuals.recordCall(milliseconds, ok)
end

--[[
	Pins a line of text beside the activity strip.

	Unlike the caption a running command sets, this survives until something
	else replaces it, which is what a session that will never run a command
	needs: the standby client view has nothing to report and no reason to say
	"waiting for a command" forever when it is not waiting for one.
]]
function Console.setCaption(message: string)
	Visuals.setCaption(message)
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

	--[[
		No cursor here.

		A blinking block after a prompt is the universal sign that something is
		waiting to be typed into, and nothing in this panel accepts input. It
		was there to prove the widget was live, which the activity band now does
		honestly, by moving only when there is something to move about.
	]]

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

	--[[
		The band sits above the log and pushes it down, rather than over it.

		The first version covered the log and was slightly transparent, so the
		thing you actually read was both hidden and softened. Decoration that
		costs legibility is a bad trade however good it looks, and this is a
		console before it is anything else.
	]]
	Visuals.mount(root, {
		background = PALETTE.background,
		surface = PALETTE.surface,
		text = PALETTE.text,
		dim = PALETTE.dim,
		violet = PALETTE.violet,
		red = PALETTE.red,
	})
	local band = root:FindFirstChild("ActivityBand") :: Frame
	band.Position = UDim2.new(0, 0, 0, 33)
	band.Size = UDim2.new(1, 0, 0, Visuals.BAND_HEIGHT)

	-- The log's top edge follows the band, so turning it on never hides a line.
	local function layoutLog()
		local top = 33 + (if Visuals.isVisible() then Visuals.BAND_HEIGHT else 0)
		scroller.Position = UDim2.new(0, 0, 0, top)
		scroller.Size = UDim2.new(1, 0, 1, -(top + 22))
	end

	-- On by default. It is the part that says the session is alive, and a signal
	-- nobody discovers is not a signal; anyone who wants the extra 44px back can
	-- turn it off in one click.
	Visuals.setVisible(true)
	visualsButton.Text = utf8.char(0x25C6) .. " visuals"
	Visuals.setIdle()
	layoutLog()

	visualsButton.MouseButton1Click:Connect(function()
		Visuals.setVisible(not Visuals.isVisible())
		layoutLog()
		-- The button reports the state it is in, not the state it would move to.
		-- A toggle that reads as an instruction is ambiguous the moment you look
		-- away and back.
		visualsButton.Text = if Visuals.isVisible() then "\u{25C6} visuals" else "visuals"
	end)

	-- Treat "scrolled away from the bottom" as the user reading history, and
	-- stop yanking the view down under them until they scroll back.
	scroller:GetPropertyChangedSignal("CanvasPosition"):Connect(function()
		local maxScroll = math.max(0, scroller.AbsoluteCanvasSize.Y - scroller.AbsoluteWindowSize.Y)
		state.pinned = maxScroll - scroller.CanvasPosition.Y < 24
	end)
end

return Console
