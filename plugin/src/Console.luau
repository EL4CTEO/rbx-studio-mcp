--!strict
--[[
	The rbx-studio console.

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

local ThemePicker = require(script.Parent.ThemePicker)
local Themes = require(script.Parent.Themes)
local Visuals = require(script.Parent.Visuals)

local Console = {}

--[[
	Ring buffer bound, counted in logged rows rather than in rendered lines.

	It used to bound the rendered lines, which meant a burst of failures -- each
	writing a message plus two wrapped lines of explanation -- evicted three
	times as much history as a burst of successes. Bounding the records makes
	"the last three hundred things that happened" mean what it says.
]]
local MAX_RECORDS = 300

--[[
	The active preset's colours, rebound rather than re-read.

	Every use site in this file is a plain `PALETTE.dim`, and there are about
	forty of them. Turning each into a function call to satisfy theming would
	have been forty edits to working code for no gain: the palette changes only
	when the user picks a different preset, so it is simply reassigned there and
	the reads stay as they were.

	The catch is that anything which COPIES a colour out of here keeps the old
	one. Instances built in `mount` do exactly that, which is why `applyTheme`
	has to walk them by hand.
]]
local PALETTE: Themes.Palette = Themes.palette()

--[[
	An optional listener on everything this console is told.

	Exists for `Mirror`, which relays a playtest server's activity to the client
	view that cannot reach the bridge itself. Kept as one hook rather than as
	calls sprinkled through the file so there is a single place where "what the
	console was told" is defined, and so the client half -- which sets no
	observer -- cannot echo what it replays back into the channel.
]]
local observer: ((string, { any }) -> ())? = nil

function Console.setObserver(fn: ((string, { any }) -> ())?)
	observer = fn
end

local function notify(kind: string, arguments: { any })
	local listener = observer
	if listener ~= nil then
		task.spawn(listener, kind, arguments)
	end
end

--[[
	Set on the console that is REPLAYING someone else's events.

	A replayed call must not grow its own consequences. `recordCall` schedules
	the "agent idle" summary, so a mirrored session scheduled one of its own and
	then received the original over the channel too -- the same line twice, a
	few pixels apart, which is exactly the sort of thing that makes a panel look
	broken. The origin is the only session entitled to decide the burst ended.
]]
local mirroring = false

function Console.setMirroring(value: boolean)
	mirroring = value
end

-- Sigil plus colour per level. The sigil is what makes the log scannable at a
-- glance; colour alone fails for anyone who cannot separate red from green.
-- Named by palette key rather than by colour, because this table is built once
-- at load and a colour captured then belongs to whichever preset happened to
-- be active at the time.
local LEVELS: { [string]: { sigil: string, key: string } } = {
	ok = { sigil = "\u{25C6}", key = "green" },
	error = { sigil = "\u{2715}", key = "red" },
	warn = { sigil = "\u{25B2}", key = "amber" },
	info = { sigil = "\u{25C6}", key = "violet" },
	dim = { sigil = "\u{00B7}", key = "dim" },
	call = { sigil = "\u{25B8}", key = "cyan" },
	reply = { sigil = "\u{25C2}", key = "violet" },
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

--[[
	One logged row, before it is coloured.

	Holding the parts rather than the finished string is what lets a theme
	switch repaint history: see `renderRecord`.
]]
type Record = {
	level: Level,
	message: string,
	detail: string?,
	stamp: string,
}

type State = {
	records: { Record },
	-- The last status reported, replayed after a theme switch. Without it the
	-- header has no way to know what colour it should be wearing.
	status: string,
	statusMeta: string,
	-- The accent rule's gradient. A ColorSequence rather than a Color3, so it
	-- cannot ride the generic role list.
	ruleFade: UIGradient?,
	--[[
		Rows written, as opposed to lines rendered.

		`lines` also holds the indented continuations a long detail wraps onto,
		so counting it would report a number nobody wrote -- "cleared 41 logs"
		for twelve commands. This counts calls to `log`, which is what a person
		means by a log line.
	]]
	entries: number,
	label: TextLabel?,
	scroller: ScrollingFrame?,
	statusDot: TextLabel?,
	statusText: TextLabel?,
	metaText: TextLabel?,
	countersText: TextLabel?,
	clientsChip: TextLabel?,
	pinned: boolean,
	calls: number,
	errors: number,
	totalMs: number,
	-- The command in flight, shown in the footer while it runs. One value that
	-- is replaced, never a list that grows.
	running: string?,
	--[[
		Bumped by every call, so a pending idle timer can tell whether it is still
		the most recent one. Cheaper and less error-prone than cancelling timers:
		`task.delay` has no handle to cancel, and a stale closure that checks a
		counter simply does nothing.
	]]
	generation: number,
	-- How many MCP clients share this bridge. Only ever displayed above one.
	clients: number,
	-- Set while a repaint is already scheduled for the end of this frame.
	dirty: boolean,
}

local state: State = {
	records = {},
	ruleFade = nil,
	status = "disconnected",
	statusMeta = "",
	entries = 0,
	label = nil,
	scroller = nil,
	statusDot = nil,
	statusText = nil,
	metaText = nil,
	countersText = nil,
	clientsChip = nil,
	pinned = true,
	calls = 0,
	errors = 0,
	totalMs = 0,
	running = nil,
	generation = 0,
	clients = 1,
	dirty = false,
}

-- How long the session must be silent before the console says so. Long enough
-- that an agent pausing to think is not announced as having stopped.
local QUIET_SECONDS = 20

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

--[[
	Turns one record into the lines it occupies.

	Rendering is deferred to here rather than done when the row is logged, which
	is the change that made theming possible at all: a line that has already had
	`#A78BFA` baked into it cannot be recoloured, so switching preset used to
	leave the whole session's history in the previous theme's palette while new
	rows arrived in the new one. Now nothing is coloured until it is painted.
]]
local function renderRecord(record: Record): { string }
	local spec = LEVELS[record.level] or LEVELS.info
	local detail = record.detail

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
		and (utf8.len(record.message) or #record.message) + detailWidth + 3
			<= DETAIL_COLUMN + INLINE_DETAIL

	local trimmed = record.message
	local budget = DETAIL_COLUMN - 3
	if inlineDetail and (utf8.len(trimmed) or #trimmed) > budget then
		-- Cut rather than wrap. A wrapped line destroys the alignment and
		-- carries the detail off the end of the visible width as well.
		local offset = utf8.offset(trimmed, budget) or budget
		trimmed = string.sub(trimmed, 1, offset - 1) .. utf8.char(0x2026)
	end

	local body = string.format("%s %s", spec.sigil, trimmed)
	local bodyWidth = utf8.len(body) or #body
	local lines = { span(PALETTE.dim, record.stamp) .. " " .. span(PALETTE[spec.key], body) }

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
	if detail then
		if inlineDetail then
			local padding = math.max(1, DETAIL_COLUMN - bodyWidth)
			lines[1] ..= span(PALETTE.dim, string.rep(" ", padding) .. detail)
		else
			for _, wrapped in wrapDetail(detail) do
				table.insert(lines, span(PALETTE.dim, DETAIL_INDENT .. wrapped))
			end
		end
	end
	return lines
end

local function paint()
	state.dirty = false
	local label = state.label
	if not label then
		return
	end

	local lines: { string } = {}
	for _, record in state.records do
		for _, line in renderRecord(record) do
			table.insert(lines, line)
		end
	end
	label.Text = table.concat(lines, "\n")

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
	Asks for a repaint, at most one per frame.

	Painting is a concat of up to three hundred strings followed by a RichText
	relayout of the whole label, and it used to run once per appended row. A
	failed command writes three rows -- the failure, its message, sometimes a
	hint -- so a single unlucky call repainted the entire console three times,
	and all of that sat in front of the reply on its way back to the agent.
	Deferring collapses them into the one paint that was always sufficient.
]]
local function redraw()
	if state.dirty then
		return
	end
	state.dirty = true
	task.defer(paint)
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
	table.insert(state.records, {
		level = level,
		message = message,
		detail = detail,
		-- Stamped when the row happened, not when it is painted. A repaint after
		-- a theme switch re-renders every line, and re-reading the clock there
		-- would restamp the whole session to the moment the user changed colour.
		stamp = os.date("%H:%M:%S") :: string,
	})
	state.entries += 1
	while #state.records > MAX_RECORDS do
		table.remove(state.records, 1)
	end
	redraw()
	notify("log", { level, message, detail })
end

export type Row = {
	level: string,
	message: string,
	detail: string?,
	stamp: string,
}

--[[
	The rows this console is holding, oldest first.

	Handed out as copies of the table but not of the records themselves: nothing
	outside this file writes to a record, and deep-copying three hundred of them
	every two seconds to guard against a caller that does not exist is a cost for
	nobody. See `History`, which is the only caller.
]]
function Console.snapshot(): { Row }
	local rows: { Row } = {}
	for _, record in state.records do
		table.insert(rows, {
			level = record.level :: string,
			message = record.message,
			detail = record.detail,
			stamp = record.stamp,
		})
	end
	return rows
end

--[[
	Puts rows back, from before this copy of the plugin existed.

	Their own timestamps come with them rather than being restamped: a restored
	row happened when it happened, and stamping it "now" would make a log that is
	being carried across a playtest look like a log that is repeating itself.

	Refuses once anything has been logged. Restoring is a load-time act, and
	splicing history under a running session would put old rows below new ones --
	the one thing a chronological log may not do.
]]
function Console.restore(rows: { Row })
	if #state.records > 0 then
		return
	end
	for _, row in rows do
		-- A level from disk names a colour and a sigil; an unknown one would
		-- render as `info` silently, so it is normalised here instead.
		local level: Level = if LEVELS[row.level] ~= nil then (row.level :: any) else "dim"
		table.insert(state.records, {
			level = level,
			message = row.message,
			detail = row.detail,
			stamp = row.stamp,
		})
	end
	while #state.records > MAX_RECORDS do
		table.remove(state.records, 1)
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
local KIND_LOOK: { [string]: { key: string, urgency: number } } = {
	read = { key = "cyan", urgency = 0.3 },
	write = { key = "violet", urgency = 0.7 },
	run = { key = "green", urgency = 0.9 },
	debug = { key = "amber", urgency = 0.5 },
}

function Console.beginCall(title: string, kind: string)
	state.running = title
	state.generation += 1
	local look = KIND_LOOK[kind] or KIND_LOOK.read
	Visuals.setCaption(title)
	Visuals.setKind(PALETTE[look.key], look.urgency)
	refreshCounters()
	notify("beginCall", { title, kind })
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
	-- Read before it is cleared: the bar wants the same phrase the log row uses,
	-- and this is the only place that still has it.
	local title = state.running or "call"
	state.running = nil
	refreshCounters()
	-- The footer reports totals when idle, so the band shows what just ran
	-- instead of repeating the same word on the same screen.
	Visuals.setIdle()

	-- The band plots it: bar height is how long it took, colour is whether it
	-- worked, and a failure knocks the solid off its axis as well.
	Visuals.recordCall(milliseconds, ok, title)
	notify("recordCall", { ok, milliseconds, title })

	--[[
		Says so when the session goes quiet, once per burst.

		There is no "the agent has finished" message in MCP -- an agent that has
		stopped and one that is thinking are the same silence -- so this reports
		the silence rather than claiming to know what caused it: what ran, how
		much of it, and how fast. The generation check is what makes it once per
		burst: every later call bumps the counter, so all but the newest timer
		wake up, find they are stale, and do nothing.
	]]
	state.generation += 1
	local mine = state.generation
	if mirroring then
		return
	end
	task.delay(QUIET_SECONDS, function()
		if state.generation ~= mine or state.calls == 0 then
			return
		end
		Console.log(
			"dim",
			string.format(
				"agent idle -- %d call%s, avg %.0fms",
				state.calls,
				if state.calls == 1 then "" else "s",
				state.totalMs / state.calls
			)
		)
		Visuals.setQuiet()
	end)
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

--[[
	Announces that an MCP client disconnected.

	This is the one moment the bridge can be certain a session ended rather than
	paused -- the client's process is gone -- so it is the one place the console
	is allowed to state it outright. Everything else it knows about agent
	activity is inference, and is worded as inference.
]]
function Console.agentFinished()
	--[[
		Named for what happened, not for what it might have meant.

		This said "Agent finished task." and that was overclaiming: the bridge
		sees a client disconnect and nothing more. Quitting the editor, a crash
		and a restart all arrive here identically, and the first time one was
		watched live it announced a completed task for an agent that had simply
		been closed mid-idle.
	]]
	Console.log("ok", "Agent disconnected.", "client left")
	Visuals.setQuiet()
end

--[[
	How many MCP clients are sharing this bridge.

	Reported only above one. A single client is the ordinary case and needs no
	badge -- a permanent "1 client connected" is a label, not a signal, and the
	header has better uses for the width.
]]
function Console.setClients(count: number)
	local previous = state.clients
	state.clients = count

	local chip = state.clientsChip
	if chip then
		chip.Visible = count > 1
		-- Pluralised even though the badge hides at one. A string that is only
		-- ever correct because nobody can see it is a trap for whoever changes
		-- the visibility rule later.
		chip.Text = string.format(
			"\u{25C6} %d client%s",
			count,
			if count == 1 then "" else "s"
		)
	end

	local meta = state.metaText
	if meta then
		meta.Size = UDim2.new(1, if count > 1 then -486 else -394, 1, 0)
	end

	--[[
		Only the arrival is worth a row.

		The departure had one too, and seeing it live made the redundancy plain:
		"one MCP client connected" landed in the same second as "Agent finished
		task.", saying the same thing less well, while the badge disappearing
		said it a third time. The count going up is news because nothing else
		reports it; the count coming down is already covered twice over.
	]]
	if count > 1 and previous <= 1 then
		Console.log("info", string.format("%d MCP clients connected", count))
	end
end

function Console.clear()
	--[[
		Says what it did, with a timestamp, like everything else in here.

		A button that empties the screen and leaves no trace is indistinguishable
		from one that crashed the panel. The count is read before the clear and
		written after it, so the first row of the fresh log is the receipt for
		the one that went.
	]]
	local cleared = state.entries
	table.clear(state.records)
	state.entries = 0
	state.calls = 0
	state.errors = 0
	state.totalMs = 0
	refreshCounters()
	-- The bars belonged to the log that just went. Leaving forty timings from an
	-- erased session on screen while the footer reads "idle" is two answers to
	-- one question.
	Visuals.clearTrace()
	redraw()

	if cleared > 0 then
		Console.log(
			"dim",
			string.format("cleared %d log%s", cleared, if cleared == 1 then "" else "s")
		)
	end
end

--[[
	Updates the header. Kept separate from the log so the current state is always
	visible without scrolling, however long the session has run.
]]
function Console.setStatus(status: string, meta: string)
	state.status = status
	state.statusMeta = meta

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
		elseif status == "standby" or status == "mirroring" then PALETTE.dim
		else PALETTE.red

	dot.TextColor3 = color
	text.Text = string.upper(status)
	text.TextColor3 = color
	metaLabel.Text = meta

	-- The wireframe takes the same colour as the status light, so the panel
	-- reads as disconnected at a glance even with the header off screen.
	Visuals.setTint(color)
end

--[[
	Records which palette colour an Instance is wearing, and puts it on.

	The console builds about thirty Instances and copies a colour into each. A
	copy does not follow the palette when the user picks a different preset, so
	the panel would keep the old theme's header, rule, scrollbar and buttons
	while the log underneath repainted -- which looks less like a theme than
	like a half-finished render.

	Rather than keep thirty named references and re-set thirty properties by
	hand, each one declares the property and palette key it is wearing when it
	is built, and `Console.applyTheme` walks the list. Adding a widget therefore
	cannot forget to theme it: the same call that colours it registers it.
]]
type Role = { instance: Instance, property: string, key: string }
local roles: { Role } = {}

local function themed<T>(instance: T & Instance, property: string, key: string): T
	table.insert(roles, { instance = instance, property = property, key = key })
	;(instance :: any)[property] = PALETTE[key]
	return instance
end

local function makeButton(parent: Instance, text: string, order: number): TextButton
	local button = Instance.new("TextButton")
	button.Name = text
	button.Text = text
	button.Font = Enum.Font.Code
	button.TextSize = 11
	themed(button, "TextColor3", "dim")
	themed(button, "BackgroundColor3", "background")
	button.AutoButtonColor = false
	button.BorderSizePixel = 0
	button.Size = UDim2.new(0, 76, 0, 20)
	button.LayoutOrder = order
	button.Parent = parent

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 3)
	corner.Parent = button

	local stroke = Instance.new("UIStroke")
	themed(stroke, "Color", "dim")
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
	-- Called after a preset switch has already been applied, so the caller's
	-- only job is to remember it. Persistence lives there because
	-- `plugin:SetSetting` is not reachable from a ModuleScript.
	onTheme: (string) -> (),
}

--[[
	Builds the widget contents. Colours are fixed rather than theme-derived: this
	is a console, and a console that repaints itself light grey reads as a form.
]]
function Console.mount(parent: Instance, handlers: Handlers)
	local root = Instance.new("Frame")
	root.Size = UDim2.fromScale(1, 1)
	themed(root, "BackgroundColor3", "background")
	root.BorderSizePixel = 0
	root.Parent = parent

	-- Header ---------------------------------------------------------------
	local header = Instance.new("Frame")
	header.Size = UDim2.new(1, 0, 0, 32)
	themed(header, "BackgroundColor3", "surface")
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
	-- Deliberately NOT registered with `themed`. Red here is the value it
	-- STARTS at, not the colour it wears: what it should be is whatever
	-- `setStatus` last reported. Registering it meant every theme switch
	-- repainted a connected session red.
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
	themed(meta, "TextColor3", "dim")
	meta.TextXAlignment = Enum.TextXAlignment.Left
	meta.TextTruncate = Enum.TextTruncate.AtEnd
	meta.BackgroundTransparency = 1
	meta.Position = UDim2.new(0, 132, 0, 0)
	meta.Size = UDim2.new(1, -394, 1, 0)
	meta.Parent = header
	state.metaText = meta

	--[[
		The shared-bridge badge, hidden until there is something to share.

		Sits between the meta line and the buttons rather than in the activity
		band, because it is a fact about the connection and the header is where
		connection facts live. `meta` gives up the width when it appears; see
		`Console.setClients`.
	]]
	local clientsChip = Instance.new("TextLabel")
	clientsChip.Name = "Clients"
	clientsChip.AnchorPoint = Vector2.new(1, 0.5)
	clientsChip.Position = UDim2.new(1, -252, 0.5, 0)
	clientsChip.Size = UDim2.new(0, 84, 0, 18)
	themed(clientsChip, "BackgroundColor3", "background")
	clientsChip.BorderSizePixel = 0
	clientsChip.Font = Enum.Font.Code
	clientsChip.TextSize = 11
	themed(clientsChip, "TextColor3", "cyan")
	clientsChip.Text = ""
	clientsChip.Visible = false
	clientsChip.Parent = header
	state.clientsChip = clientsChip

	local chipCorner = Instance.new("UICorner")
	chipCorner.CornerRadius = UDim.new(0, 3)
	chipCorner.Parent = clientsChip

	local chipStroke = Instance.new("UIStroke")
	themed(chipStroke, "Color", "cyan")
	chipStroke.Transparency = 0.6
	chipStroke.Parent = clientsChip

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
	themed(rule, "BackgroundColor3", "rule")
	rule.BorderSizePixel = 0
	rule.Parent = root

	local ruleFade = Instance.new("UIGradient")
	ruleFade.Color = ColorSequence.new(PALETTE.rule)
	state.ruleFade = ruleFade
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
	themed(scroller, "ScrollBarImageColor3", "violet")
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
	themed(label, "TextColor3", "text")
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
	themed(footer, "BackgroundColor3", "surface")
	footer.BorderSizePixel = 0
	footer.Parent = root

	local footerPadding = Instance.new("UIPadding")
	footerPadding.PaddingLeft = UDim.new(0, 12)
	footerPadding.PaddingRight = UDim.new(0, 12)
	footerPadding.Parent = footer

	local prompt = Instance.new("TextLabel")
	prompt.Text = "rbx\u{00B7}studio"
	prompt.Font = Enum.Font.Code
	prompt.TextSize = 11
	themed(prompt, "TextColor3", "violet")
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
	themed(counters, "TextColor3", "dim")
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
	Visuals.mount(root)
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

	--[[
		The preset drawer, mounted last so its tab sits over everything.

		It has to be the last child of `root` as well as the highest ZIndex: the
		band, the log and the footer are all built before it and a drawer that
		opens behind the log is a drawer nobody can click.
	]]
	ThemePicker.mount(root, function(id)
		Console.applyTheme()
		ThemePicker.applyTheme()
		layoutLog()
		handlers.onTheme(id)
	end)

	-- Treat "scrolled away from the bottom" as the user reading history, and
	-- stop yanking the view down under them until they scroll back.
	scroller:GetPropertyChangedSignal("CanvasPosition"):Connect(function()
		local maxScroll = math.max(0, scroller.AbsoluteCanvasSize.Y - scroller.AbsoluteWindowSize.Y)
		state.pinned = maxScroll - scroller.CanvasPosition.Y < 24
	end)
end

--[[
	Switches the whole panel to the active preset.

	Three things have to move together or the switch looks broken: the palette
	this file reads, the Instances that copied a colour out of it, and the log,
	whose rows are re-rendered from records rather than recoloured in place. The
	band goes last because remounting a preset is the expensive part and there
	is no reason to make the text wait for it.
]]
function Console.applyTheme()
	PALETTE = Themes.palette()

	for _, role in roles do
		-- A widget can outlive its registration if the panel is rebuilt, and
		-- writing to a destroyed Instance throws.
		if role.instance.Parent ~= nil or role.instance:IsA("UIStroke") then
			pcall(function()
				(role.instance :: any)[role.property] = PALETTE[role.key]
			end)
		end
	end

	local ruleFade = state.ruleFade
	if ruleFade then
		ruleFade.Color = ColorSequence.new(PALETTE.rule)
	end

	refreshCounters()
	-- Replayed rather than recoloured: the status light's colour is a fact about
	-- the connection, and the only thing that knows it is `setStatus`.
	Console.setStatus(state.status, state.statusMeta)
	redraw()
	Visuals.applyTheme()
end

return Console
