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

local TweenService = game:GetService("TweenService")

local Format = require(script.Parent.Format)
local Prompt = require(script.Parent.Prompt)
local Palette = require(script.Parent.Palette)
local Icons = require(script.Parent.Icons)
local Backdrop = require(script.Parent.Backdrop)

local Console = {}

--[[
	The clear wipe: an old CRT being switched off.

	A button that empties the screen and leaves no trace is indistinguishable
	from one that crashed the panel. The receipt row answers that in words; this
	answers it in the two hundred milliseconds before anyone has read the words.

	It is an OVERLAY and nothing else. The log is cleared for real at the same
	instant, underneath, so nothing about the console's state waits on an
	animation -- a line that arrives mid-wipe lands in the fresh log and is
	simply revealed when the overlay goes. What collapses is a still copy of the
	text that was on screen, which is the honest thing to animate: it is a
	picture of what was erased.

	Three phases, and the timings are the whole effect. The picture holds and
	then whips shut to a line; the line sits a moment; the line whips to a point
	and is gone. Easing into each collapse rather than out of it is what makes it
	read as a tube discharging rather than as a panel being resized.
]]
local CRT_COLLAPSE = 0.16
local CRT_HOLD = 0.07
local CRT_BLINK = 0.17
local CRT_SHUT = TweenInfo.new(CRT_COLLAPSE, Enum.EasingStyle.Quart, Enum.EasingDirection.In)
local CRT_SETTLE = TweenInfo.new(0.05, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local CRT_OUT = TweenInfo.new(CRT_BLINK, Enum.EasingStyle.Quart, Enum.EasingDirection.In)

--[[
	Explicit depths, because a plugin widget draws with ZIndexBehavior.Global
	and a child does not inherit its parent's. Above the log, the band and the
	hover readout; below the preset drawer, which must stay clickable.
]]
local Z_CRT = 20
local Z_CRT_TEXT = 21
local Z_CRT_LINE = 22

--[[
	Ring buffer bound, counted in logged rows rather than in rendered lines.

	It used to bound the rendered lines, which meant a burst of failures -- each
	writing a message plus two wrapped lines of explanation -- evicted three
	times as much history as a burst of successes. Bounding the records makes
	"the last three hundred things that happened" mean what it says.
]]
local MAX_RECORDS = 300

-- The status bar's height. Named because three things now measure against it:
-- the bar itself, the prompt row sitting on top of it, and the log above both.
local FOOTER_HEIGHT = 24
local HEADER_HEIGHT = 38

--[[
	Header controls, Threadline sizes.

	The three words that used to sit in the header cost 244px between them, more
	than a third of a docked panel, and said less than a glyph with its name on
	hover. Icons plus the theme swatches now fit in 196px, and the swatches give
	way first when the dock gets narrow.
]]
local ICON_BUTTON = 26
local BUTTONS_NARROW = 2 * ICON_BUTTON + 4
-- The theme dots, one per theme, left of the icons when there is room.
local SWATCH = 9
local SWATCH_GAP = 6
local SWATCH_COUNT = #Palette.list()
local SWATCHES_WIDTH = SWATCH_COUNT * SWATCH + (SWATCH_COUNT - 1) * SWATCH_GAP + 4
local BUTTONS_WIDE = BUTTONS_NARROW + 10 + SWATCHES_WIDTH
-- Below this width the swatches hide and the meta line goes with them.
local NARROW_HEADER = 520

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
local PALETTE: Palette.Palette = Palette.get()

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
	Breaks a long string into lines at word boundaries.

	Roblox's own TextWrapped would do this, and would wrap to column 0 -- there
	is no hanging indent for a TextLabel -- which is the ragged shape this
	replaces. Wrapping here means every continuation line can carry the indent.

	A single word longer than the width is cut rather than allowed to overhang.
	That case is not prose: it is a path, a URL or a base64 blob, and letting one
	of those push the line out re-creates the exact wrap this exists to prevent.
]]

--[[
	One logged row, before it is coloured.

	Holding the parts rather than the finished string is what lets a theme
	switch repaint history: see `renderRecord`.
]]
export type Child = { message: string, detail: string? }

type Record = {
	-- Which collector this row is: "agent", "burst" or "connect".
	groupKind: string?,
	-- An agent run in progress: its steps are being added under this row.
	live: boolean?,
	-- The run just finished: show the steps, then fold them.
	ended: boolean?,
	-- os.clock() of the last line merged into this record; see `Console.log`.
	at: number?,
	-- Set once lines have been merged in, so the rebuilt row does not replay
	-- its arrival animation for the whole block.
	grown: boolean?,
	-- Recolours the built row for the live palette, leaving its animations be.
	repaint: (() -> ())?,
	level: Level,
	message: string,
	detail: string?,
	stamp: string,
	-- Memo of `renderRecord`, valid only while `renderedWith` is the live
	-- palette. Records never change after they are logged, so the palette is
	-- the one thing that can make this stale.
	rendered: { string }?,
	renderedWith: Palette.Palette?,
	-- Its row in the log, while it has one. Rows are built when a record is
	-- first painted and destroyed when it is evicted, so an append costs one
	-- instance rather than a relayout of the whole log.
	widget: Frame?,
	-- Monotonic, never reused: the row's LayoutOrder, so a row built late (after
	-- a filter change) still lands where it belongs.
	order: number,
	--[[
		Threadline: what a row is to the turn around it.

		`turn` marks a line typed into the prompt -- the head of a thread.
		`threaded` marks everything logged while that turn was open, which hangs
		off the head under a thread line instead of carrying its own timestamp.
		`ms` is a tool call's duration, kept as a number so the row can draw its
		latency bar; prose and notices have none.
	]]
	turn: boolean?,
	threaded: boolean?,
	ms: number?,
	-- The work kind of the call this row reports (read, write, run, debug):
	-- the colour of its station on the line.
	kind: string?,
	-- Sub-items drawn under the row on a straight connector; see `logGroup`.
	children: { Child }?,
	-- The last row of a turn that has closed: its line ends in a cap.
	capped: boolean?,
}

--[[
	One MCP client sharing this bridge, as the server describes it.

	`name` is what the agent calls itself in the MCP handshake, so it is
	"claude-code" or "codex" rather than anything the bridge guessed. A client
	that never introduced itself arrives as "unknown", which is honest: it is
	connected, we just do not know what it is.
]]
export type Client = {
	name: string,
	version: string,
	pid: number,
	connectedAt: number,
}

type State = {
	-- Bumped per theme switch, so a slower recolour pass yields to a newer one.
	repaintGeneration: number?,
	-- The work kind of the last call that went out, for the line map's stations.
	lastKind: string?,
	-- The status dot's breathing while connected.
	statusPulse: Tween?,
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
	-- Holds one row per visible record. See `paint`.
	list: Frame?,
	scroller: ScrollingFrame?,
	-- Set when every row must be rebuilt: a theme or filter change, a clear.
	rebuild: boolean,
	nextOrder: number,
	-- Rows that arrived while the user was reading history, and the pill that
	-- offers the way back to the tail.
	unread: number,
	jumpPill: TextButton?,
	statusDot: TextLabel?,
	statusText: TextLabel?,
	metaText: TextLabel?,
	countersText: TextLabel?,
	clientsChip: TextButton?,
	-- The background gradient and the theme dots, repainted on a theme switch.
	fieldGradient: UIGradient?,
	swatchRow: Frame?,
	swatches: { [string]: GuiButton },
	-- True while the pointer has a log row opened up; pauses tail-following.
	hoverHold: boolean?,
	-- The group collecting rows right now: an agent run, a burst of calls, or
	-- a reconnect sequence. See `Console.log`.
	agentGroup: Record?,
	-- An agent run is under way (between "is starting" and "Done"), and the
	-- name it runs under. Steps after its prose open a fresh group below it.
	agentRunning: boolean?,
	agentLabel: string?,
	pinned: boolean,
	calls: number,
	errors: number,
	totalMs: number,
	durations: { number },
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
	--[[
		Whether the count above was learned from this connection or the last.

		The bridge sends the roster the moment a stream opens, so the first
		frame after every reconnect looks exactly like an agent arriving. It is
		not: the same agents were there a second ago, and the connect itself has
		already played its flourish. Cleared whenever the transport leaves
		"connected", so only a genuine arrival mid-session celebrates.
	]]
	clientsKnown: boolean,
	--[[
		Who those clients are, newest last, as the bridge last reported them.

		Kept even at one client, unlike the badge: the roster is what answers
		"is this extra one a problem?", and the moment it becomes worth asking
		is the moment a second appears -- too late to start recording.
	]]
	clientList: { Client },
	-- Set while a repaint is already scheduled for the end of this frame.
	dirty: boolean,

	--[[
		The clear wipe's overlay: an unclipped shell over the log region, the
		collapsing screen inside it, a fixed window holding the still copy of
		the text, and the bright line the picture discharges into.
	]]
	crt: Frame?,
	crtScreen: Frame?,
	crtWindow: Frame?,
	crtGhost: TextLabel?,
	crtLine: Frame?,
	--[[
		Bumped by every wipe, so the delayed halves of an earlier one know they
		have been superseded and do nothing. `task.delay` hands back no handle to
		cancel, and clearing twice inside four hundred milliseconds is a click
		away.
	]]
	crtGeneration: number,

	--[[
		Which levels the log is currently showing, or nil for all of them.

		A filter over the RECORDS rather than over what is appended: turning it
		off has to bring the hidden rows back, and a log that dropped them on the
		way in could only ever show what happened since. Records are kept whole
		and `paint` decides what to draw.
	]]
	filter: { [string]: boolean }?,

	--[[
		Re-runs the log's top and bottom edges after something above it moves.

		Defined inside `mount`, where the band and the scroller are both in
		scope, and kept here so `toggleVisuals` can reach it. A second copy of
		that arithmetic is how the log ends up overlapping the band.
	]]
	relayout: (() -> ())?,
	-- Whether rows logged now belong to the turn the last prompt opened.
	inTurn: boolean,
	headerButtons: Frame?,
}

local state: State = {
	records = {},
	ruleFade = nil,
	status = "disconnected",
	statusMeta = "",
	entries = 0,
	list = nil,
	scroller = nil,
	rebuild = false,
	nextOrder = 0,
	unread = 0,
	jumpPill = nil,
	statusDot = nil,
	statusText = nil,
	metaText = nil,
	countersText = nil,
	clientsChip = nil,
	fieldGradient = nil,
	swatchRow = nil,
	swatches = {},
	pinned = true,
	calls = 0,
	errors = 0,
	totalMs = 0,
	durations = {},
	running = nil,
	generation = 0,
	clients = 1,
	clientsKnown = false,
	clientList = {},
	dirty = false,
	crt = nil,
	crtScreen = nil,
	crtWindow = nil,
	crtGhost = nil,
	crtLine = nil,
	crtGeneration = 0,
	filter = nil,
	relayout = nil,
	inTurn = false,
	headerButtons = nil,
}

-- Declared ahead of its definition: `setClients` calls it and is written
-- above it, and a plain `function layoutHeader()` there would have quietly
-- become a global.
local layoutHeader: () -> ()

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


local function span(color: Color3, value: string): string
	return string.format('<font color="%s">%s</font>', hex(color), Format.escape(value))
end

--[[
	Turns an agent's markdown into the markup this label already speaks.

	Agents write for a terminal that renders markdown, so their replies arrive
	full of `**` and backticks. Printed raw they are worse than noise -- the
	asterisks land in the middle of a sentence and read as typos -- and stripping
	them would throw away the emphasis the agent chose. The label is RichText, so
	the third option is simply to honour it.

	Applied AFTER escaping, which is what makes it safe: `escape` has already
	turned every angle bracket in the agent's own text into an entity, so the
	only tags in the string afterwards are the ones put there here.

	Bold before italic, or the outer pair of a `**` run is eaten as two italics.
	Underscores are deliberately not italic markers: `execute_luau` and
	`mcp__rbx-studio__modify` are the vocabulary of this log, and they would
	spend most of their lives in italics for no reason.
]]

--[[
	Collapses anything that would break the one-line-per-row contract.

	A row is a line. Every width here is measured in characters and every
	continuation is indented by hand, so a newline arriving inside a message or
	a detail lands in the middle of that arithmetic and comes out at column 0 --
	which is how a two-line Luau snippet in a tool argument left a bare "m"
	sitting under the log. Tabs go the same way, for the same reason.
]]

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
	local messageWidth = utf8.len(record.message) or #record.message
	local budget = DETAIL_COLUMN - 3
	--[[
		The message has to fit as it stands, not once it has been cut down.

		The rule used to be about the PAIR fitting, and then the message was
		truncated to make the pair true. That was written when every message was
		a tool name, where losing the tail of "Run Luau (7 lines)" costs nothing.
		A prompt echoed back is a message too, and it came out as the user's own
		sentence chopped at 49 characters with an ellipsis -- to make room for
		the word "you". A detail is worth less than the line it annotates, so
		when both cannot fit it is the detail that moves.
	]]
	local inlineDetail = detail ~= nil
		and messageWidth <= budget
		and messageWidth + detailWidth + 3 <= DETAIL_COLUMN + INLINE_DETAIL

	local trimmed = record.message

	--[[
		A message too long for the width is wrapped here, not by the label.

		Details have always been wrapped with a hanging indent; messages never
		were, because until now every message was a tool name. Agent output is
		prose -- whole paragraphs arriving as one row -- and a paragraph left to
		the TextLabel wraps back to column 0, under the timestamps, so the second
		line of a sentence reads as a new entry. The indent is what keeps a
		wrapped sentence visibly part of the row above it.

		Skipped when a detail is riding the right-hand column: the message has
		already been cut to fit beside it, and wrapping something that fits would
		only break the column the cut was made to protect.
	]]
	local continuation: { string } = {}
	if not inlineDetail and (utf8.len(trimmed) or #trimmed) > DETAIL_WRAP then
		local wrapped = Format.wrap(trimmed, DETAIL_WRAP)
		trimmed = table.remove(wrapped, 1) :: string
		continuation = wrapped
	end

	--[[
		Only an agent's own prose is read as markdown.

		`reply` is the level its sentences arrive on. Every other level carries
		names this console generated -- tool names, paths, glob patterns -- where
		an asterisk is a character rather than an instruction, and italicising
		half a path would be a worse bug than the one this fixes.
	]]
	local prose = record.level == "reply"

	--[[
		Threadline colours. A turn's head reads in the text colour behind a violet
		caret, because it is the user's own words; a finished tool call is a cyan
		mark beside a plain name, so the eye runs down the marks and reads the
		names. Everything else keeps its level's colour.
	]]
	local sigil = spec.sigil
	local sigilKey = spec.key
	local textKey = spec.key
	if record.turn then
		sigil, sigilKey, textKey = "\u{203A}", "violet", "text"
	elseif record.ms ~= nil and record.level == "reply" then
		sigil, sigilKey, textKey = "\u{25B8}", "cyan", "text"
	end

	local function line(text: string): string
		local escaped = Format.escape(text)
		if prose and record.ms == nil then
			escaped = Format.emphasise(escaped, hex(PALETTE.cyan))
		end
		return string.format('<font color="%s">%s</font>', hex(PALETTE[textKey]), escaped)
	end

	-- A threaded row gives its timestamp's columns to the thread line, so every
	-- column to its right stays exactly where an unthreaded row puts it.
	local stamp = if record.threaded then string.rep(" ", utf8.len(record.stamp) or #record.stamp) else record.stamp
	local body = string.format("%s %s", sigil, trimmed)
	local bodyWidth = utf8.len(body) or #body
	local lines = {
		span(PALETTE.dim, stamp) .. " " .. span(PALETTE[sigilKey], sigil) .. " " .. line(trimmed),
	}

	-- In the message's own colour, not the dim of a detail: these lines ARE the
	-- message, and greying them would read as an explanation of it.
	for _, extra in continuation do
		table.insert(lines, line(DETAIL_INDENT .. extra))
	end

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
			for _, wrapped in Format.wrap(detail, DETAIL_WRAP) do
				table.insert(lines, span(PALETTE.dim, DETAIL_INDENT .. wrapped))
			end
		end
	end
	return lines
end

--[[
	The rows a record occupies, coloured for the live palette.

	Memoised: records never change after they are logged, so the palette is the
	one thing that can make a render stale.
]]
local function renderedLines(record: Record): { string }
	local rendered = record.rendered
	if rendered == nil or record.renderedWith ~= PALETTE then
		rendered = renderRecord(record)
		record.rendered = rendered
		record.renderedWith = PALETTE
	end
	return rendered :: { string }
end

local function visible(record: Record): boolean
	local filter = state.filter
	return filter == nil or filter[record.level] == true
end

-- The same text the old single label held. The clear wipe copies it.
local function allText(): string
	local lines: { string } = {}
	for _, record in state.records do
		if visible(record) then
			for _, line in renderedLines(record) do
				table.insert(lines, line)
			end
		end
	end
	return table.concat(lines, "\n")
end

local KIND_LOOK: { [string]: { key: string, urgency: number } } = {
	read = { key = "cyan", urgency = 0.3 },
	write = { key = "violet", urgency = 0.7 },
	run = { key = "green", urgency = 0.9 },
	debug = { key = "amber", urgency = 0.5 },
}

--[[
	The log's columns, in pixels: time, a kind diamond, the message, and a
	right-hand column for a short detail such as a duration. Laid out by
	Instances rather than by padding monospaced text, so nothing depends on
	how wide Studio happens to draw a character.
]]
local TIME_WIDTH = 54
local DOT_SIZE = 5
local DOT_HOVER = 8
-- Extra room a hovered row takes above and below, pushing its neighbours away.
local HOVER_SPACE = 5
-- Sub-item rows under a grouped row, and how they open and fold.
local CHILD_HEIGHT = 20
local GROUP_HOLD = 6
local GROUP_OPEN = TweenInfo.new(0.22, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local GROUP_CLOSE = TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.InOut)
local FADE_QUICK = TweenInfo.new(0.15, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local POP = TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local SETTLE = TweenInfo.new(0.22, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local DOT_POP = 10
-- Rows built in the same frame arrive one after another, this far apart.
local STAGGER = 0.06
local FADE = TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.Out, 0, false, 0.12)
local HOVER_IN = TweenInfo.new(0.14, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local HOVER_OUT = TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local TEXT_X = 70
local RIGHT_WIDTH = 86
-- Longest detail that rides the right column; anything longer goes beneath.
local RIGHT_MAX = 14
local LINE = 18

--[[
	The end of a turn: a faint hairline under its last row, so one request
	reads as a block.
]]
local function addCap(_row: GuiObject)
	-- Deliberately draws nothing now: a hairline under a turn's last row read
	-- as a stray underline. The space above each typed command separates turns.
end

-- The diamond's colour: what kind of work, or how it went.
local function dotKey(record: Record): string
	if record.level == "error" then
		return "red"
	elseif record.level == "warn" then
		return "amber"
	elseif record.turn then
		return "violet"
	elseif record.ms ~= nil then
		local look = KIND_LOOK[record.kind or ""]
		return if look then look.key else "cyan"
	end
	return (LEVELS[record.level] or LEVELS.info).key
end

local function textKey(record: Record): string
	if record.level == "error" then
		return "red"
	elseif record.level == "warn" then
		return "amber"
	elseif record.level == "dim" then
		return "dim"
	end
	return "text"
end

local function label(font: Enum.Font, size: number, color: Color3): TextLabel
	local text = Instance.new("TextLabel")
	text.BackgroundTransparency = 1
	text.Font = font
	text.TextSize = size
	text.TextColor3 = color
	text.TextXAlignment = Enum.TextXAlignment.Left
	text.TextYAlignment = Enum.TextYAlignment.Center
	return text
end

local function buildRow(record: Record, list: Frame, animate: boolean?, delay: number?, previous: Record?): Frame
	--[[
		A reply arrives one line per row. Lines after the first are the same
		answer, so they drop the time and the diamond and sit tight under it.
		A time the row above already showed is not repeated either.
	]]
	local prose = record.level == "reply" and record.ms == nil and not record.turn
	local continues = prose
		and previous ~= nil
		and previous.level == "reply"
		and previous.ms == nil
		and not previous.turn
	local sameTime = previous ~= nil and previous.stamp == record.stamp

	--[[
		How each coloured part of this row is set, kept so a theme switch can
		recolour the row where it stands. Rebuilding every row instead cut off
		whatever was animating -- a reply typing itself out, an open group, a
		live run -- and replayed the live ones from the start.
	]]
	local paints: { () -> () } = {}
	local function paint(instance: GuiObject, property: string, key: string)
		(instance :: any)[property] = PALETTE[key]
		table.insert(paints, function()
			(instance :: any)[property] = PALETTE[key]
		end)
	end
	record.repaint = function()
		for _, apply in paints do
			apply()
		end
	end

	local row = Instance.new("TextButton")
	row.Name = "Row"
	row.Text = ""
	row.AutoButtonColor = false
	row.BorderSizePixel = 0
	paint(row, "BackgroundColor3", "rule")
	row.BackgroundTransparency = 1
	row.Size = UDim2.new(1, 0, 0, 0)
	row.AutomaticSize = Enum.AutomaticSize.Y
	row.LayoutOrder = record.order

	-- Hover wash: bright at the left, gone by the right edge.
	local wash = Instance.new("UIGradient")
	wash.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.8),
		NumberSequenceKeypoint.new(0.85, 1),
		NumberSequenceKeypoint.new(1, 1),
	})
	wash.Parent = row

	local padding = Instance.new("UIPadding")
	padding.PaddingTop = UDim.new(0, if record.turn then 12 elseif continues then 0 else 3)
	padding.PaddingBottom = UDim.new(0, 3)
	padding.PaddingLeft = UDim.new(0, 4)
	padding.PaddingRight = UDim.new(0, 4)
	padding.Parent = row

	local time = label(Enum.Font.Code, 11, PALETTE.dim)
	time.Name = "Time"
	time.Text = if sameTime or continues then "" else record.stamp
	time.Size = UDim2.fromOffset(TIME_WIDTH, LINE)
	time.Parent = row
	paint(time, "TextColor3", "dim")

	local dot = Instance.new("Frame")
	dot.Name = "Dot"
	dot.BorderSizePixel = 0
	dot.Rotation = 45
	dot.AnchorPoint = Vector2.new(0.5, 0.5)
	dot.Position = UDim2.fromOffset(TIME_WIDTH + 6, LINE / 2)
	dot.Size = UDim2.fromOffset(DOT_SIZE, DOT_SIZE)
	paint(dot, "BackgroundColor3", dotKey(record))
	dot.Visible = not continues
	dot.Parent = row

	-- What sits in the right column: a short detail, else the duration.
	local detail = record.detail
	local right: string? = nil
	local below: string? = nil
	if detail ~= nil and detail ~= "" then
		local width = utf8.len(detail) or #detail
		if width <= RIGHT_MAX and not string.find(detail, "\n", 1, true) then
			right = detail
		else
			below = detail
		end
	end
	if right == nil and record.ms ~= nil then
		right = Console.durationText(record.ms)
	end

	local content = Instance.new("Frame")
	content.Name = "Content"
	content.BackgroundTransparency = 1
	content.Position = UDim2.fromOffset(TEXT_X, 0)
	content.Size = UDim2.new(1, -(TEXT_X + (if right then RIGHT_WIDTH else 0)), 0, 0)
	content.AutomaticSize = Enum.AutomaticSize.Y
	content.Parent = row

	local stack = Instance.new("UIListLayout")
	stack.SortOrder = Enum.SortOrder.LayoutOrder
	stack.Padding = UDim.new(0, 1)
	stack.Parent = content

	local message = record.message
	-- Markdown list items read as bullets, not as a stray dash.
	if prose then
		local lines = string.split(message, "\n")
		for index, text in lines do
			local item = string.match(text, "^%s*[%-%*]%s+(.*)$")
			if item ~= nil then
				lines[index] = "\u{2022}  " .. item
			end
		end
		message = table.concat(lines, "\n")
	end
	local escaped = Format.escape(message)
	local emphasised = record.level == "reply" and record.ms == nil
	if emphasised then
		escaped = Format.emphasise(escaped, hex(PALETTE.cyan))
	end
	-- What the user typed stands out from what came back.
	local body = label(if record.turn then Palette.FONT_BOLD else Palette.FONT, 14, PALETTE[textKey(record)])
	paint(body, "TextColor3", textKey(record))
	if emphasised then
		-- The emphasis colour lives inside the RichText, so the text is redone.
		local plain = Format.escape(message)
		table.insert(paints, function()
			body.Text = Format.emphasise(plain, hex(PALETTE.cyan))
		end)
	end
	body.Name = "Body"
	body.RichText = true
	body.TextWrapped = true
	body.TextYAlignment = Enum.TextYAlignment.Top
	body.LineHeight = 1.1
	body.Size = UDim2.new(1, 0, 0, LINE)
	body.AutomaticSize = Enum.AutomaticSize.Y
	body.Text = escaped
	body.LayoutOrder = 1
	body.Parent = content

	if below then
		local note = label(Palette.FONT, 12, PALETTE.dim)
		note.Name = "Detail"
		note.TextWrapped = true
		note.TextYAlignment = Enum.TextYAlignment.Top
		note.Size = UDim2.new(1, 0, 0, 14)
		note.AutomaticSize = Enum.AutomaticSize.Y
		note.Text = below
		note.LayoutOrder = 2
		note.Parent = content
		paint(note, "TextColor3", "dim")
	end

	if right then
		local side = label(Enum.Font.Code, 11, if record.level == "error" then PALETTE.red else PALETTE.dim)
		side.Name = "Right"
		side.TextXAlignment = Enum.TextXAlignment.Right
		side.TextTruncate = Enum.TextTruncate.AtEnd
		side.AnchorPoint = Vector2.new(1, 0)
		side.Position = UDim2.new(1, 0, 0, 0)
		side.Size = UDim2.fromOffset(RIGHT_WIDTH - 6, LINE)
		side.Text = right
		side.Parent = row
		paint(side, "TextColor3", if record.level == "error" then "red" else "dim")
	end

	if record.capped then
		addCap(row)
	end

	--[[
		Sub-items on a straight connector: a vertical spine from under the
		message, a square elbow into each item. Open when the row arrives live,
		folded a few seconds later, and opened again while the row is hovered.
	]]
	local children = record.children
	local setOpen: ((boolean) -> ())? = nil
	local holdOpen = false
	if children ~= nil and #children > 0 then
		local count = #children
		local tree = Instance.new("Frame")
		tree.Name = "Children"
		tree.BackgroundTransparency = 1
		tree.ClipsDescendants = true
		tree.Size = UDim2.new(1, 0, 0, 0)
		tree.LayoutOrder = 3
		tree.Parent = content

		local spine = Instance.new("Frame")
		spine.Name = "Spine"
		spine.BorderSizePixel = 0
		paint(spine, "BackgroundColor3", "rule")
		spine.BackgroundTransparency = 0.45
		spine.Position = UDim2.fromOffset(4, 0)
		spine.Size = UDim2.fromOffset(1, (count - 1) * CHILD_HEIGHT + CHILD_HEIGHT / 2 + 1)
		spine.Parent = tree

		local labels: { TextLabel } = {}
		local newest: { TextLabel } = {}
		for index, child in children do
			local top = (index - 1) * CHILD_HEIGHT
			local elbow = Instance.new("Frame")
			elbow.Name = "Elbow"
			elbow.BorderSizePixel = 0
			paint(elbow, "BackgroundColor3", "rule")
			elbow.BackgroundTransparency = 0.45
			elbow.Position = UDim2.fromOffset(4, top + CHILD_HEIGHT / 2)
			elbow.Size = UDim2.fromOffset(9, 1)
			elbow.Parent = tree

			local name = label(Palette.FONT, 13, PALETTE.text)
			name.Name = "Item"
			name.TextTruncate = Enum.TextTruncate.AtEnd
			name.Position = UDim2.fromOffset(18, top)
			name.Size = UDim2.new(1, -(18 + (if child.detail then 110 else 0)), 0, CHILD_HEIGHT)
			name.Text = child.message
			name.Parent = tree
			paint(name, "TextColor3", "text")
			table.insert(labels, name)
			if index == count then
				table.insert(newest, name)
			end

			if child.detail then
				local side = label(Enum.Font.Code, 11, PALETTE.dim)
				side.Name = "ItemDetail"
				side.TextXAlignment = Enum.TextXAlignment.Right
				side.TextTruncate = Enum.TextTruncate.AtEnd
				side.AnchorPoint = Vector2.new(1, 0)
				side.Position = UDim2.new(1, -2, 0, top)
				side.Size = UDim2.fromOffset(106, CHILD_HEIGHT)
				side.Text = child.detail
				side.Parent = tree
				paint(side, "TextColor3", "dim")
				table.insert(labels, side)
				if index == count then
					table.insert(newest, side)
				end
			end
		end

		-- Shown in the right column while folded, so a folded row says it has more.
		local more: TextLabel? = nil
		if right == nil then
			local hint = label(Enum.Font.Code, 11, PALETTE.dim)
			hint.Name = "More"
			hint.TextXAlignment = Enum.TextXAlignment.Right
			hint.AnchorPoint = Vector2.new(1, 0)
			hint.Position = UDim2.new(1, 0, 0, 0)
			hint.Size = UDim2.fromOffset(RIGHT_WIDTH - 6, LINE)
			hint.Text = string.format("+%d", count)
			hint.Parent = row
			paint(hint, "TextColor3", "dim")
			more = hint
		end

		local open = false
		setOpen = function(wanted: boolean)
			if wanted == open then
				return
			end
			open = wanted
			TweenService:Create(tree, if wanted then GROUP_OPEN else GROUP_CLOSE, {
				Size = UDim2.new(1, 0, 0, if wanted then count * CHILD_HEIGHT + 2 else 0),
			}):Play()
			if more then
				TweenService:Create(more, FADE_QUICK, { TextTransparency = if wanted then 1 else 0 }):Play()
			end
			if wanted then
				-- Each item writes itself in, one after the other.
				for index, item in labels do
					local length = utf8.len(item.ContentText) or #item.ContentText
					item.MaxVisibleGraphemes = 0
					local typing = TweenService:Create(
						item,
						TweenInfo.new(math.clamp(length * 0.012, 0.15, 0.25), Enum.EasingStyle.Linear),
						{ MaxVisibleGraphemes = length }
					)
					typing.Completed:Connect(function()
						item.MaxVisibleGraphemes = -1
					end)
					task.delay(0.05 * index, function()
						typing:Play()
					end)
				end
			end
		end

		local function showNow()
			open = true
			tree.Size = UDim2.new(1, 0, 0, count * CHILD_HEIGHT + 2)
			if more then
				more.TextTransparency = 1
			end
		end
		if record.live then
			-- A run in progress stays open; only the step that just landed types in.
			showNow()
			holdOpen = true
			for _, item in newest do
				local length = utf8.len(item.ContentText) or #item.ContentText
				item.MaxVisibleGraphemes = 0
				local typing = TweenService:Create(
					item,
					TweenInfo.new(math.clamp(length * 0.012, 0.15, 0.25), Enum.EasingStyle.Linear),
					{ MaxVisibleGraphemes = length }
				)
				typing.Completed:Connect(function()
					item.MaxVisibleGraphemes = -1
				end)
				typing:Play()
			end
		elseif record.ended then
			-- Just finished: leave the steps up a moment, then fold them away.
			record.ended = nil
			showNow()
			holdOpen = true
			task.delay(GROUP_HOLD, function()
				holdOpen = false
				if setOpen and not state.hoverHold then
					setOpen(false)
				end
			end)
		elseif animate then
			holdOpen = true
			task.delay((delay or 0) + 0.4, function()
				if setOpen then
					setOpen(true)
				end
			end)
			task.delay((delay or 0) + GROUP_HOLD, function()
				holdOpen = false
				if setOpen and not state.hoverHold then
					setOpen(false)
				end
			end)
		end
	end

	--[[
		Arrival: the diamond pops in with a small overshoot, then the message
		types itself out left to right and the side text fades up behind it.
		Only for rows that arrive live; a rebuild or a restored session would
		otherwise replay a hundred of these at once.
	]]
	if animate and not record.grown then
		local wait = delay or 0
		-- Two beats: swell past full size, then settle back with a small bounce.
		dot.Size = UDim2.fromOffset(0, 0)
		local swell = TweenService:Create(dot, POP, { Size = UDim2.fromOffset(DOT_POP, DOT_POP) })
		swell.Completed:Connect(function()
			TweenService:Create(dot, SETTLE, { Size = UDim2.fromOffset(DOT_SIZE, DOT_SIZE) }):Play()
		end)
		task.delay(wait, function()
			swell:Play()
		end)
		--[[
			What the user typed is not typed out again: they just wrote it, and
			watching it spelled back letter by letter read as the line being
			sent twice. It lands whole; only what comes back types itself in.
		]]
		if not record.turn then
			local graphemes = utf8.len(body.ContentText) or #body.ContentText
			body.MaxVisibleGraphemes = 0
			local typing = TweenService:Create(
				body,
				TweenInfo.new(math.clamp(graphemes * 0.012, 0.2, 0.3), Enum.EasingStyle.Linear),
				{ MaxVisibleGraphemes = graphemes }
			)
			task.delay(wait + 0.1, function()
				typing:Play()
			end)
			typing.Completed:Connect(function()
				body.MaxVisibleGraphemes = -1
			end)
		end
		for _, child in row:GetDescendants() do
			if child:IsA("TextLabel") and child ~= body then
				local label = child :: TextLabel
				label.TextTransparency = 1
				TweenService:Create(label, FADE, { TextTransparency = 0 }):Play()
			end
		end
	end

	local restTop = padding.PaddingTop.Offset
	local function hover(on: boolean)
		-- While a row is opened up, the log must not chase the tail: the
		-- extra height would scroll it out from under the pointer.
		state.hoverHold = on
		row.BackgroundTransparency = if on then 0 else 1
		if setOpen then
			if on then
				setOpen(true)
			elseif not holdOpen then
				setOpen(false)
			end
		end
		local info = if on then HOVER_IN else HOVER_OUT
		TweenService:Create(padding, info, {
			PaddingTop = UDim.new(0, if on then restTop + HOVER_SPACE else restTop),
			PaddingBottom = UDim.new(0, if on then 3 + HOVER_SPACE else 3),
		}):Play()
		TweenService:Create(dot, info, {
			Size = UDim2.fromOffset(if on then DOT_HOVER else DOT_SIZE, if on then DOT_HOVER else DOT_SIZE),
		}):Play()
	end
	row.MouseEnter:Connect(function()
		-- Roblox sends hover to everything under the pointer, covered or not;
		-- a row under the open command menu must stay still.
		if Prompt.isMenuOpen() then
			return
		end
		hover(true)
	end)
	row.MouseLeave:Connect(function()
		hover(false)
	end)

	row.Parent = list
	return row
end

local function updateJumpPill()
	local pill = state.jumpPill
	if pill == nil then
		return
	end
	pill.Visible = not state.pinned
	pill.Text = if state.unread > 0
		then string.format("%d new \u{2193}", state.unread)
		else "latest \u{2193}"
end

--[[
	Brings the log up to date with the records, building only what is missing.

	One TextButton per record instead of one label holding all of them: the label
	re-laid-out every line of RichText on each append, a cost that grows with the
	log, where a row is a constant. A theme switch, a filter change and a clear
	are the only things that touch existing rows, and they say so with
	`state.rebuild`.
]]
local function paint()
	state.dirty = false
	local list = state.list
	if not list then
		return
	end

	local rebuilt = state.rebuild
	if state.rebuild then
		state.rebuild = false
		for _, child in list:GetChildren() do
			if child:IsA("GuiObject") then
				child:Destroy()
			end
		end
		for _, record in state.records do
			record.widget = nil
		end
	end

	-- Animate only a live trickle: a rebuild, a restore or a burst just appears.
	local pending = 0
	for _, record in state.records do
		if record.widget == nil and visible(record) then
			pending += 1
		end
	end
	local animate = not rebuilt and pending <= 4

	local built = 0
	local previous: Record? = nil
	for _, record in state.records do
		if visible(record) then
			if record.widget == nil then
				record.widget = buildRow(record, list, animate, built * STAGGER, previous)
				built += 1
			end
			previous = record
		end
	end

	-- Only follow the tail when the user has not scrolled up to read history.
	local scroller = state.scroller
	if scroller and state.pinned then
		task.defer(function()
			if scroller.Parent then
				scroller.CanvasPosition = Vector2.new(0, math.max(0, scroller.AbsoluteCanvasSize.Y))
			end
		end)
	elseif built > 0 then
		state.unread += built
		updateJumpPill()
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

--[[
	How many recent calls the typical-latency figure looks at.
]]
local TIMING_WINDOW = 50

--[[
	The typical call time, as a median rather than a mean.

	A mean is the wrong statistic for latency and the panel had it: nine calls,
	seven of them under 65ms and two of them deliberate 45-second waits, summed
	to "avg 5027ms". Nothing about the bridge was slow, and the one number on
	screen said everything was. One long call is normal -- a profile, a sleep, a
	Creator Store search -- so the summary has to survive one, and a median does
	while a mean cannot.
]]
local function typicalMs(): number
	local total = #state.durations
	if total == 0 then
		return 0
	end
	local sorted = table.clone(state.durations)
	table.sort(sorted)
	local middle = (total + 1) / 2
	if total % 2 == 1 then
		return sorted[middle]
	end
	return (sorted[middle - 0.5] + sorted[middle + 0.5]) / 2
end

--[[
	A duration as the panel shows it.

	Rounded to milliseconds, a handler that does its work in a fraction of one
	reads as "0ms", and nothing takes zero time -- it is the one figure on the
	panel that claims something impossible. Most handlers genuinely are under a
	millisecond, so this is the common case rather than an edge.

	Exported because the same number is written in two places -- the footer's
	typical, and the time beside every row -- and they were formatted
	separately. That showed: the footer said "typical <1ms" directly above a
	column of rows all claiming "0ms", which reads as a bug in whichever one you
	believe less.
]]
function Console.durationText(milliseconds: number): string
	if milliseconds < 1 then
		return "<1ms"
	end
	return string.format("%.0fms", milliseconds)
end

local function typicalText(): string
	return Console.durationText(typicalMs())
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
	-- RichText so the error count can wear red when there is one, the one
	-- number on this line that asks for attention.
	counters.RichText = true
	local errors = string.format("%d error%s", state.errors, if state.errors == 1 then "" else "s")
	counters.Text = string.format(
		"%d call%s \u{00B7} %s \u{00B7} typical %s",
		state.calls,
		if state.calls == 1 then "" else "s",
		if state.errors > 0 then span(PALETTE.red, errors) else Format.escape(errors),
		Format.escape(typicalText())
	)
end

--[[
	Appends one line. `detail` is padded to a fixed column and dimmed, so
	latencies stack into a readable column instead of trailing each message at a
	ragged offset.
]]
--[[
	Ends the group being collected: its row stops taking rows, shows them a
	moment longer, then folds them away.
]]
local function trimLeft(text: string): string
	return (string.gsub(text, "^%s+", ""))
end

-- Gap after which a call no longer joins the burst before it.
local BURST_GAP = 4

local function burstTitle(count: number): string
	return string.format("Agent activity \u{00B7} %d calls", count)
end

-- Lines that belong to a reconnect sequence.
local function connectionLine(message: string): boolean
	return string.sub(message, 1, 19) == "reconnect requested"
		or string.sub(message, 1, 12) == "disconnected"
		or string.sub(message, 1, 13) == "connecting to"
		or string.sub(message, 1, 12) == "connected to"
end

local endGroup: () -> ()

-- A burst closes itself once calls stop arriving.
local function scheduleBurstEnd(group: Record)
	local stamp = group.at
	task.delay(BURST_GAP, function()
		if state.agentGroup == group and group.at == stamp then
			endGroup()
		end
	end)
end

function endGroup()
	local group = state.agentGroup
	if group == nil then
		return
	end
	state.agentGroup = nil
	group.live = nil
	group.ended = true
	if group.groupKind == "agent" and group.children ~= nil then
		local label = string.match(group.message, "^(.-) is ") or state.agentLabel or "Agent"
		local count = #group.children
		group.message = string.format("%s \u{00B7} %d step%s", label, count, if count == 1 then "" else "s")
	end
	group.rendered = nil
	-- Rebuilt, not arrived: without this a typed line closed by "... is
	-- starting" popped in and typed itself out a second time.
	group.grown = true
	if group.widget ~= nil then
		group.widget:Destroy()
		group.widget = nil
	end
	redraw()
end

function Console.log(level: Level, message: string, detail: string?, ms: number?, children: { Child }?)
	--[[
		A line typed into the prompt opens a turn; it is echoed as a `call` whose
		detail says it was "you". Everything after it hangs off that head until
		the turn is closed -- see `Console.endTurn`.
	]]
	local relayed = detail
	local turn = level == "call" and (detail == "you" or detail == "you (hidden)")
	--[[
		Only a line typed while nothing is running opens a thread. One typed
		while a panel agent works joins that agent's thread instead of stealing
		the rest of its run. The playtest client mirror never opens one: the
		events that close a turn are not relayed to it, so a thread opened there
		would never end.
	]]
	local opens = turn and not mirroring and not Prompt.isBusy()
	if turn then
		-- "you" is what the caret already says. A masked line keeps its warning.
		detail = if detail == "you (hidden)" then "hidden" else nil
	end
	if opens then
		state.inTurn = true
	end

	--[[
		While an agent runs, its steps -- its own tool calls and the Studio calls
		they make -- hang under the run's row instead of filling the log. The
		answer itself, and anything that is not a step, stays a row of its own.
	]]
	local group = state.agentGroup
	local isCall = (level == "reply" or level == "error") and ms ~= nil

	-- The agent wrote something mid-run: the steps so far fold above it, and the
	-- ones after it start a new group below, where they actually happened.
	if group ~= nil and group.groupKind == "agent" and level == "reply" and ms == nil and not turn then
		endGroup()
		group = nil
	end
	if group == nil and state.agentRunning and children == nil and not turn and (level == "call" or isCall) then
		Console.log("dim", (state.agentLabel or "Agent") .. " is continuing\u{2026}")
		group = state.agentGroup
	end

	if group ~= nil and children == nil and not turn then
		local kind = group.groupKind
		local starting = string.find(message, " is starting", 1, true) ~= nil
			or string.find(message, " is continuing", 1, true) ~= nil
		local step = if kind == "agent"
			then level == "call" or isCall
			elseif kind == "burst" then isCall and os.clock() - (group.at or 0) < BURST_GAP
			elseif kind == "command" then not starting
			else connectionLine(message)
		if starting and kind == "command" then
			-- A prompt for an agent, not a command: the run gets its own row.
			endGroup()
		end
		if not step and kind == "burst" then
			-- Anything else between calls ends the burst; this row stands alone.
			endGroup()
		end
		if step then
			local steps = group.children or {}
			table.insert(steps, {
				message = Format.flatten(if level == "error" then "\u{2715} " .. message else message),
				detail = if detail ~= nil
					then Format.flatten(detail)
					elseif ms ~= nil then Console.durationText(ms)
					else nil,
			})
			group.children = steps
			group.grown = true
			group.rendered = nil
			group.at = os.clock()
			if kind == "burst" then
				group.message = burstTitle(#steps)
				scheduleBurstEnd(group)
			elseif kind == "connect" and string.sub(message, 1, 12) == "connected to" then
				-- The sequence resolves: the row says where it landed.
				group.message = Format.flatten(message)
				group.level = "ok"
				group.detail = nil
				endGroup()
			end
			if group.widget ~= nil then
				group.widget:Destroy()
				group.widget = nil
			end
			redraw()
			notify("log", { level, message, relayed, ms })
			return
		end
	end

	--[[
		A second call close behind the first, outside any agent run, turns the
		pair into one live "Agent activity" row that keeps counting.
	]]
	local previousRecord = state.records[#state.records]
	if state.agentGroup == nil and isCall and children == nil and not turn and not state.inTurn
		and previousRecord ~= nil and previousRecord.ms ~= nil and previousRecord.children == nil
		and (previousRecord.level == "reply" or previousRecord.level == "error")
		and os.clock() - (previousRecord.at or 0) < BURST_GAP
	then
		local first: Child = {
			message = (if previousRecord.level == "error" then "\u{2715} " else "") .. previousRecord.message,
			detail = previousRecord.detail or Console.durationText(previousRecord.ms :: number),
		}
		local second: Child = {
			message = Format.flatten(if level == "error" then "\u{2715} " .. message else message),
			detail = if detail ~= nil then Format.flatten(detail) else Console.durationText(ms :: number),
		}
		previousRecord.children = { first, second }
		previousRecord.message = burstTitle(2)
		previousRecord.level = "call"
		previousRecord.detail = nil
		previousRecord.ms = nil
		previousRecord.groupKind = "burst"
		previousRecord.live = true
		previousRecord.grown = true
		previousRecord.rendered = nil
		previousRecord.at = os.clock()
		if previousRecord.widget ~= nil then
			previousRecord.widget:Destroy()
			previousRecord.widget = nil
		end
		state.agentGroup = previousRecord
		scheduleBurstEnd(previousRecord)
		redraw()
		notify("log", { level, message, relayed, ms })
		return
	end

	--[[
		An agent's reply arrives one line at a time. Lines that follow straight
		on from a reply are the same answer, so they join that record and the
		whole answer is one row: one hover, one block, one time.
	]]
	local last = state.records[#state.records]
	if level == "reply" and ms == nil and not turn and children == nil
		and last ~= nil and last.level == "reply" and last.ms == nil and not last.turn
		and last.children == nil and os.clock() - (last.at or 0) < 3
	then
		last.message ..= "\n" .. Format.flatten(message)
		last.at = os.clock()
		last.grown = true
		last.rendered = nil
		if last.widget ~= nil then
			last.widget:Destroy()
			last.widget = nil
		end
		redraw()
		notify("log", { level, message, relayed, ms })
		return
	end

	state.nextOrder += 1
	table.insert(state.records, {
		at = os.clock(),
		order = state.nextOrder,
		level = level,
		message = Format.flatten(message),
		detail = if detail ~= nil then Format.flatten(detail) else nil,
		-- Stamped when the row happened, not when it is painted. A repaint after
		-- a theme switch re-renders every line, and re-reading the clock there
		-- would restamp the whole session to the moment the user changed colour.
		stamp = os.date("%H:%M:%S") :: string,
		turn = if turn then true else nil,
		threaded = if state.inTurn and not opens then true else nil,
		ms = ms,
		kind = if ms ~= nil then state.lastKind else nil,
		children = children,
	})
	state.entries += 1

	-- "Claude Code is starting..." opens a run that collects the steps after it.
	local added = state.records[#state.records]
	if level == "dim" and children == nil
		and (string.find(message, " is starting", 1, true) or string.find(message, " is continuing", 1, true))
	then
		endGroup()
		added.live = true
		added.groupKind = "agent"
		state.agentGroup = added
		state.agentRunning = true
		state.agentLabel = string.match(message, "^(.-) is ") or state.agentLabel
	elseif turn and children == nil then
		-- A typed command: what it prints hangs under it.
		endGroup()
		added.live = true
		added.groupKind = "command"
		state.agentGroup = added
	elseif state.agentGroup == nil and children == nil and connectionLine(message)
		and string.sub(message, 1, 12) ~= "connected to"
	then
		-- The start of a reconnect: the row becomes "Reconnecting" and gathers
		-- the steps until the connection lands.
		added.children = { { message = added.message, detail = added.detail } }
		added.message = "Reconnecting\u{2026}"
		added.detail = nil
		added.level = "dim"
		added.live = true
		added.groupKind = "connect"
		state.agentGroup = added
	elseif (level == "ok" or level == "error")
		and (string.sub(message, 1, 4) == "Done" or string.sub(message, 1, 6) == "Failed")
	then
		endGroup()
		state.agentRunning = false
	end

	while #state.records > MAX_RECORDS do
		local evicted = table.remove(state.records, 1) :: Record
		if evicted.widget ~= nil then
			evicted.widget:Destroy()
		end
	end
	redraw()
	notify("log", { level, message, relayed, ms })
end

--[[
	One row with sub-items: the row draws first, its items follow on a
	connector, and after a few seconds they fold away until the row is hovered.
]]
function Console.logGroup(level: Level, message: string, children: { Child }, detail: string?)
	local flat: { Child } = {}
	for _, child in children do
		table.insert(flat, {
			message = Format.flatten(child.message),
			detail = if child.detail ~= nil then Format.flatten(child.detail) else nil,
		})
	end
	Console.log(level, message, detail, nil, flat)
end

export type Row = {
	level: string,
	message: string,
	detail: string?,
	stamp: string,
	turn: boolean?,
	threaded: boolean?,
	ms: number?,
	kind: string?,
	capped: boolean?,
	children: { Child }?,
}

--[[
	Closes the open turn, so what is logged next stands on its own again.

	Called when a typed command has finished, when an agent the panel started
	exits, and before anything that reports on the session as a whole. Calls
	from an agent driven from a terminal never open a turn, so they are never
	mistaken for the answer to a command typed here.
]]
--[[
	Ends the open line on its last row with a cap, so a finished turn reads as
	a line that stops rather than one that was cut off by the next.
]]
local function capTurn()
	if not state.inTurn then
		return
	end
	local last = state.records[#state.records]
	if last == nil or not last.threaded or last.capped then
		return
	end
	last.capped = true
	local widget = last.widget
	if widget ~= nil then
		addCap(widget)
	end
end

function Console.endTurn()
	endGroup()
	state.agentRunning = false
	capTurn()
	state.inTurn = false
end

function Console.endTurnUnlessBusy()
	if not Prompt.isBusy() then
		capTurn()
		state.inTurn = false
	end
end

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
			turn = record.turn,
			threaded = record.threaded,
			ms = record.ms,
			kind = record.kind,
			capped = record.capped,
			children = record.children,
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
		state.nextOrder += 1
		table.insert(state.records, {
			order = state.nextOrder,
			level = level,
			message = row.message,
			detail = row.detail,
			stamp = row.stamp,
			turn = row.turn,
			threaded = row.threaded,
			ms = row.ms,
			kind = row.kind,
			capped = row.capped,
			children = row.children,
		})
	end
	while #state.records > MAX_RECORDS do
		table.remove(state.records, 1)
	end
	redraw()
end

--[[
	Colour and pace per kind of work, so the band reads as what is happening.

	Reads are cool and quick because they are constant and harmless; writes are
	violet and slower because they change the user's game; running code is green
	and heavier still. Urgency drives both the spin rate and how strongly the
	colour takes over, so the two never disagree.
]]

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
function Console.beginCall(title: string, kind: string)
	state.running = title
	state.generation += 1
	local look = KIND_LOOK[kind] or KIND_LOOK.read
	state.lastKind = if KIND_LOOK[kind] then kind else "read"
	refreshCounters()
	notify("beginCall", { title, kind })
end

--[[
	Records one completed command for the session counters. Kept separate from
	`log` so callers can log freely without skewing the statistics.
]]
function Console.recordCall(ok: boolean, milliseconds: number)
	-- A light runs across the background in the colour of the call's kind.
	local look = KIND_LOOK[state.lastKind or "read"] or KIND_LOOK.read
	Backdrop.pulse(if ok then PALETTE[look.key] else PALETTE.red)
	state.calls += 1
	state.totalMs += milliseconds
	--[[
		Kept for the median. The window is bounded because this grows for as long
		as the panel is open, and because a figure meant to say "how is it
		feeling now" should not be answering with this morning.
	]]
	table.insert(state.durations, milliseconds)
	if #state.durations > TIMING_WINDOW then
		table.remove(state.durations, 1)
	end
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

	-- The band plots it: bar height is how long it took, colour is whether it
	-- worked, and a failure knocks the solid off its axis as well.
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
		--[[
			Not while an agent this panel started is still working.

			This line reports a silence, and its whole justification was that MCP
			gives no way to tell a finished agent from a thinking one. For an
			agent we started ourselves that is no longer true -- we hold its
			process and know exactly when it exits -- so announcing it idle
			mid-run would be stating something we can see is false, in the middle
			of its own output.
		]]
		if Prompt.isBusy() then
			return
		end
		Console.endTurn()
		Console.log(
			"dim",
			string.format(
				"agent idle -- %d call%s, typical %s",
				state.calls,
				if state.calls == 1 then "" else "s",
				typicalText()
			)
		)
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
	Console.endTurn()
	Console.log("ok", "Agent disconnected.", "client left")
end

--[[
	How many MCP clients are sharing this bridge.

	Reported only above one. A single client is the ordinary case and needs no
	badge -- a permanent "1 client connected" is a label, not a signal, and the
	header has better uses for the width.
]]
function Console.setClients(count: number, list: { Client }?)
	local previous = state.clients
	local known = state.clientsKnown
	state.clients = count
	state.clientsKnown = true
	if list ~= nil then
		state.clientList = list
	end

	--[[
		An agent joining gets the same flourish as a session landing.

		It is the same kind of news -- something that can now drive this Studio
		has arrived -- and the trace is where this panel says so. Guarded on
		`known` because the bridge re-sends the roster on every reconnect, and
		replaying the arrival of agents that never left would fire it several
		times a session until it stopped meaning anything.
	]]
	if known and count > previous then
	end

	local chip = state.clientsChip
	if chip then
		-- Pluralised even though the badge hides at one. A string that is only
		-- ever correct because nobody can see it is a trap for whoever changes
		-- the visibility rule later.
		chip.Text = string.format(
			"%d agent%s",
			count,
			if count == 1 then "" else "s"
		)
	end

	layoutHeader()

	--[[
		Only the arrival is worth a row.

		The departure had one too, and seeing it live made the redundancy plain:
		"one MCP client connected" landed in the same second as "Agent finished
		task.", saying the same thing less well, while the badge disappearing
		said it a third time. The count going up is news because nothing else
		reports it; the count coming down is already covered twice over.
	]]
	if count > 1 and previous <= 1 then
		--[[
			Named, not just counted.

			"3 MCP clients connected" is the line people bring to us asking
			whether something is wrong, because a number cannot say whether the
			extra ones are agents they started or processes they forgot. The
			names can, so they are in the row that raises the question rather
			than only in a panel the reader has to know to hover.
		]]
		local items: { Child } = {}
		for _, client in state.clientList do
			local name = if client.name ~= "" then client.name else "unknown"
			table.insert(items, { message = name .. (if client.version ~= "" then " " .. client.version else "") })
		end
		if #items > 0 then
			Console.logGroup("info", string.format("%d MCP clients connected", count), items)
		else
			Console.log("info", string.format("%d MCP clients connected", count), Console.clientSummary())
		end
	end
end

--[[
	The roster on one line, for the caption and the arrival row.

	Names only, deduplicated by name with a count where it repeats: two Codex
	windows are "codex x2", not "codex, codex". The interesting fact is which
	tools are attached, and a list that repeats a name reads as a mistake.
]]
--[[
	Places the header's right-hand controls, and gives the meta line what is left.

	One function rather than each control minding its own position, because the
	clients badge comes and goes: it only appears above one client. With the
	positions written at each call site, the meta line's width had to encode
	every combination as a constant, and the two had to be kept in step by hand.

	Laid out right to left from the buttons, each control claiming its width
	plus a gap. The meta line then ends a fixed distance further left, which is
	the rule it always followed -- it just no longer has to be told the answer.
]]
local HEADER_GAP = 8
local CHIP_WIDTH = 84
local META_CLEARANCE = 150

layoutHeader = function()
	--[[
		Narrow docks drop the swatches first, then the meta line: the status word
		and the controls are the part of the header nobody can do without.
	]]
	local buttons = state.headerButtons
	local width = if buttons and buttons.Parent then (buttons.Parent :: GuiObject).AbsoluteSize.X else 1000
	local wide = width >= NARROW_HEADER
	local swatchRow = state.swatchRow
	if swatchRow then
		swatchRow.Visible = wide
	end
	local edge = if wide then BUTTONS_WIDE else BUTTONS_NARROW
	if buttons then
		buttons.Size = UDim2.new(0, edge, 0, ICON_BUTTON)
	end

	local chip = state.clientsChip
	if chip then
		chip.Visible = state.clients > 1
		if chip.Visible then
			edge += HEADER_GAP
			chip.Position = UDim2.new(1, -edge, 0.5, 0)
			edge += CHIP_WIDTH
		end
	end

	local meta = state.metaText
	if meta then
		meta.Size = UDim2.new(1, -(edge + META_CLEARANCE), 1, 0)
		meta.Visible = width - edge - META_CLEARANCE >= 60
	end
end




function Console.clientSummary(): string
	local list = state.clientList
	if #list == 0 then
		return ""
	end
	local order: { string } = {}
	local seen: { [string]: number } = {}
	for _, client in list do
		local name = if client.name ~= "" then client.name else "unknown"
		if seen[name] == nil then
			seen[name] = 0
			table.insert(order, name)
		end
		seen[name] += 1
	end
	local parts: { string } = {}
	for _, name in order do
		local total = seen[name]
		table.insert(parts, if total > 1 then string.format("%s x%d", name, total) else name)
	end
	return table.concat(parts, ", ")
end

--[[
	The roster in full, one row per client, written into the log.

	In the log rather than a hover panel because that is where this console puts
	facts it wants the user to be able to scroll back to -- and because a list
	that only exists while the pointer is on it cannot be read and acted on at
	the same time.
]]
function Console.reportClients()
	local list = state.clientList
	if #list == 0 then
		--[[
			An empty roster beside a count above one is not "nobody is here",
			it is a server too old to say who. Worth distinguishing: the first
			reading sends someone looking for a connection problem that does
			not exist, and the fix -- restart the MCP server -- is not one
			anybody guesses from "no client has introduced itself".
		]]
		if state.clients > 0 then
			Console.log(
				"dim",
				string.format("%d connected, but this bridge did not say which", state.clients),
				"restart the MCP server"
			)
		else
			Console.log("dim", "no MCP client is connected")
		end
		return
	end
	local now = os.time()
	local items: { Child } = {}
	for _, client in list do
		local name = if client.name ~= "" then client.name else "unknown"
		local version = if client.version ~= "" then " " .. client.version else ""
		-- Seconds since the epoch on both sides, so this is a real elapsed time
		-- and not a guess: the bridge and Studio are the same machine.
		local since = math.max(0, now - math.floor(client.connectedAt / 1000))
		table.insert(items, {
			message = name .. version,
			detail = string.format("pid %d \u{00B7} %s", client.pid, Console.humanDuration(since)),
		})
	end
	Console.logGroup("info", string.format("%d MCP client%s on this bridge", #list, if #list == 1 then "" else "s"), items)
end

--[[
	A duration a person reads at a glance, not a precise one.

	Rounded down deliberately: "2m" for anything in that minute is what someone
	scanning a list wants, and a ticking "2m 47s" invites the reader to watch it
	rather than to read past it.
]]
function Console.humanDuration(seconds: number): string
	if seconds < 60 then
		return string.format("%ds", seconds)
	end
	if seconds < 3600 then
		return string.format("%dm", math.floor(seconds / 60))
	end
	return string.format("%dh %dm", math.floor(seconds / 3600), math.floor(seconds % 3600 / 60))
end

--[[
	Plays the wipe over whatever is on screen right now.

	Must be called BEFORE the log is emptied: the still copy it collapses is
	read straight off the live label, scroll offset and all, so what discharges
	is exactly the text the user was looking at rather than a re-render of it.

	Silent when there is nothing to play it on -- a widget dragged down to a
	sliver has no room for a picture to collapse, and a flourish that plays in
	four pixels is a flicker, not an effect.
]]
local function crtWipe()
	local shell = state.crt
	local screen = state.crtScreen
	local window = state.crtWindow
	local ghost = state.crtGhost
	local line = state.crtLine
	local scroller = state.scroller
	local list = state.list
	if
		shell == nil
		or screen == nil
		or window == nil
		or ghost == nil
		or line == nil
		or scroller == nil
		or list == nil
	then
		return
	end

	local height = scroller.AbsoluteSize.Y
	if height < 24 then
		return
	end

	state.crtGeneration += 1
	local generation = state.crtGeneration

	-- Read at play time rather than tracked, so the overlay lands on the log
	-- wherever the band toggle and the widget's size have left it.
	shell.Position = scroller.Position
	shell.Size = scroller.Size

	--[[
		The still copy, offset by exactly as far as the log is scrolled.

		A TextLabel cannot scroll its own text, so the window is a fixed-height
		clip and the label inside it is pushed up by the canvas offset. That is
		what makes the copy line up with the real log to the pixel instead of
		snapping to the top of the buffer the moment the wipe starts.
	]]
	window.Size = UDim2.new(1, 0, 0, height)
	ghost.Position = UDim2.new(0, 12, 0, 8 - scroller.CanvasPosition.Y)
	ghost.Size = UDim2.new(1, -24, 0, 0)
	ghost.TextColor3 = PALETTE.text
	ghost.Text = allText()

	screen.BackgroundColor3 = PALETTE.background
	screen.Size = UDim2.new(1, 0, 1, 0)
	screen.Visible = true

	line.BackgroundColor3 = PALETTE.text
	line.Size = UDim2.new(1, 0, 0, 2)
	line.BackgroundTransparency = 1
	line.Visible = false

	shell.Visible = true

	-- The picture, whipping shut around its own middle.
	TweenService:Create(screen, CRT_SHUT, { Size = UDim2.new(1, 0, 0, 2) }):Play()

	task.delay(CRT_COLLAPSE, function()
		if state.crtGeneration ~= generation then
			return
		end

		--[[
			The handover. The screen goes and the line arrives in the same frame,
			a little over-thick, and settles -- which is the flash. Fading one
			into the other instead just looks like a crossfade of two rectangles.
		]]
		screen.Visible = false
		line.BackgroundTransparency = 0
		line.Size = UDim2.new(1, 0, 0, 3)
		line.Visible = true
		TweenService:Create(line, CRT_SETTLE, { Size = UDim2.new(1, 0, 0, 2) }):Play()

		task.delay(CRT_HOLD, function()
			if state.crtGeneration ~= generation then
				return
			end

			TweenService:Create(line, CRT_OUT, {
				Size = UDim2.new(0, 0, 0, 2),
				BackgroundTransparency = 0.35,
			}):Play()

			task.delay(CRT_BLINK, function()
				if state.crtGeneration ~= generation then
					return
				end
				shell.Visible = false
				line.Visible = false
				screen.Visible = true
			end)
		end)
	end)
end

function Console.clear()
	-- Before anything is emptied: the wipe collapses a copy of what is on
	-- screen, and a moment later there is nothing on screen to copy.
	crtWipe()

	--[[
		Says what it did, with a timestamp, like everything else in here.

		A button that empties the screen and leaves no trace is indistinguishable
		from one that crashed the panel. The count is read before the clear and
		written after it, so the first row of the fresh log is the receipt for
		the one that went.
	]]
	local cleared = state.entries
	state.inTurn = false
	table.clear(state.records)
	state.rebuild = true
	state.unread = 0
	state.entries = 0
	state.calls = 0
	state.errors = 0
	state.totalMs = 0
	table.clear(state.durations)
	refreshCounters()
	-- The bars belonged to the log that just went. Leaving forty timings from an
	-- erased session on screen while the footer reads "idle" is two answers to
	-- one question.
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
	-- Read before it is overwritten: the arrival flourish below is the one thing
	-- here that cares whether this is a change or a repeat.
	local previous = state.status
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
	--[[
		A live session breathes: the dot pulses while connected and holds still
		otherwise, so "connected but frozen" and "connected and alive" stop
		looking the same. One looping tween, replaced only when the state
		changes, so a theme repaint does not restart it.
	]]
	if status ~= previous or state.statusPulse == nil then
		if state.statusPulse then
			state.statusPulse:Cancel()
			state.statusPulse = nil
		end
		dot.TextTransparency = 0
		if status == "connected" then
			local pulse = TweenService:Create(
				dot,
				TweenInfo.new(1.1, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true),
				{ TextTransparency = 0.55 }
			)
			pulse:Play()
			state.statusPulse = pulse
		end
	end
	text.Text = string.upper(string.sub(status, 1, 1)) .. string.sub(status, 2)
	text.TextColor3 = if status == "connected" then PALETTE.text else color
	metaLabel.Text = meta

	-- The wireframe takes the same colour as the status light, so the panel
	-- reads as disconnected at a glance even with the header off screen.

	-- The trace has no calls to plot until a session exists, so it waves while
	-- the transport is reaching for one rather than sitting as a dead baseline
	-- at exactly the moment somebody is watching to see whether it is alive.

	--[[
		And it celebrates when the session finally lands.

		Only on the transition. `setStatus` is also how a theme switch and a
		port change repaint the header, and both replay the current status --
		which would fire the flourish again for an event that already happened,
		several times a session, until it read as noise rather than as news.
	]]
	if status == "connected" and previous ~= "connected" then
	end

	-- A roster learned on the old connection says nothing about this one.
	if status ~= "connected" then
		state.clientsKnown = false
	end
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


--[[
	The header's three controls, drawn rather than typed.

	Code renders the geometric shapes the log's sigils use and nothing much
	beyond them: the arrow and erase glyphs these started with came out as
	empty boxes. So visuals keeps its diamond, which renders, and reconnect and
	clear are built from Frames -- a ring with an arrowhead, a bin with a lid --
	which draw the same in every font Studio will ever ship.
]]
type Ink = { instance: Instance, property: string }

local function drawIcon(button: TextButton, kind: string): ({ Ink }, Icons.Drawn)
	local drawn = Icons.draw(button, kind, PALETTE.dim)
	local inks: { Ink } = {}
	for _, line in drawn.paths do
		table.insert(inks, { instance = line, property = "Color3" })
	end
	return inks, drawn
end

local function makeIconButton(parent: Instance, kind: string, tip: string, order: number): TextButton
	local button = Instance.new("TextButton")
	button.Name = kind
	button.Text = ""
	themed(button, "BackgroundColor3", "background")
	button.AutoButtonColor = false
	button.BorderSizePixel = 0
	button.Size = UDim2.fromOffset(ICON_BUTTON, ICON_BUTTON)
	button.BackgroundTransparency = 1
	button.LayoutOrder = order
	button.Parent = parent

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 3)
	corner.Parent = button

	local stroke = Instance.new("UIStroke")
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	stroke.Color = PALETTE.dim
	stroke.Transparency = 0.6
	stroke.Parent = button

	local inks, drawn = drawIcon(button, kind)
	local hovered = false
	button.Activated:Connect(function()
		Icons.press(drawn)
	end)
	local function paint()
		local key = button:GetAttribute("RestKey")
		local color = if hovered then PALETTE.text else PALETTE[if typeof(key) == "string" then key else "dim"]
		for _, entry in inks do
			(entry.instance :: any)[entry.property] = color
		end
		stroke.Color = PALETTE.rule
		stroke.Transparency = if hovered then 0.5 else 1
		button.BackgroundTransparency = if hovered then 0.85 else 1
	end

	button.MouseEnter:Connect(function()
		hovered = true
		paint()
		Icons.hover(drawn, true)
	end)
	button.MouseLeave:Connect(function()
		hovered = false
		paint()
		Icons.hover(drawn, false)
	end)
	-- `RestKey` says which state a toggle is in; `Repaint` is bumped by a theme
	-- switch, since the drawn parts are not on the themed role list.
	button:GetAttributeChangedSignal("RestKey"):Connect(paint)
	button:GetAttributeChangedSignal("Repaint"):Connect(paint)
	paint()
	return button
end

export type Handlers = {
	onReconnect: () -> (),
	onClear: () -> (),
	-- A theme dot was clicked; the theme is already active. Saves the choice.
	onTheme: (string) -> (),
	--[[
		A line the user typed into the prompt row.

		The console does not interpret it. Commands live in their own module
		because half of them are about things this file knows nothing about --
		the transport, the port setting, the bridge -- and a console that
		reached for all of that to answer `status` would be the whole plugin.
	]]
	onSubmit: (string) -> (),
	-- Command names starting with the given prefix, for Tab and the hint.
	onComplete: (string) -> { string },
	--[[
		The same commands, described, for the menu that opens above the prompt.

		Separate from `onComplete` because the two want different things: Tab
		wants names to compare against what is typed, and the menu wants a usage
		line and a summary to put on screen.
	]]
	onSuggest: (string) -> { { name: string, usage: string, summary: string } },
}

--[[
	Builds the widget contents. Colours are fixed rather than theme-derived: this
	is a console, and a console that repaints itself light grey reads as a form.
]]
function Console.mount(parent: Instance, handlers: Handlers)
	-- The saved theme is restored after this module loads, so the colours are
	-- read again here; the cached ones would be the default theme's.
	PALETTE = Palette.get()
	local root = Instance.new("Frame")
	root.Size = UDim2.fromScale(1, 1)
	themed(root, "BackgroundColor3", "background")
	root.BorderSizePixel = 0
	root.Parent = parent

	-- Navy field: lighter at the top left, deep at the bottom right.
	local field = Instance.new("UIGradient")
	field.Color = ColorSequence.new(PALETTE.background, Palette.deep())
	state.fieldGradient = field
	field.Rotation = 55
	field.Parent = root

	-- The drifting constellation, first so it draws under everything else.
	Backdrop.mount(root, Palette.theme().backdrop, PALETTE.rule)

	-- Header ---------------------------------------------------------------
	local header = Instance.new("Frame")
	header.Size = UDim2.new(1, 0, 0, HEADER_HEIGHT)
	header.BackgroundTransparency = 1
	header.BorderSizePixel = 0
	header.Parent = root

	local headerPadding = Instance.new("UIPadding")
	headerPadding.PaddingLeft = UDim.new(0, 12)
	headerPadding.PaddingRight = UDim.new(0, 8)
	headerPadding.Parent = header

	local dot = Instance.new("TextLabel")
	dot.Text = "\u{25C6}"
	dot.Font = Enum.Font.Code
	dot.TextSize = 11
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
	status.Text = "Disconnected"
	status.Font = Palette.FONT_BOLD
	status.TextSize = 14
	status.TextColor3 = PALETTE.red
	status.TextXAlignment = Enum.TextXAlignment.Left
	status.BackgroundTransparency = 1
	status.Position = UDim2.new(0, 16, 0, 0)
	status.Size = UDim2.new(0, 92, 1, 0)
	status.Parent = header
	state.statusText = status

	local meta = Instance.new("TextLabel")
	meta.Text = ""
	meta.Font = Palette.FONT
	meta.TextSize = 13
	themed(meta, "TextColor3", "dim")
	meta.TextXAlignment = Enum.TextXAlignment.Left
	meta.TextTruncate = Enum.TextTruncate.AtEnd
	meta.BackgroundTransparency = 1
	meta.Position = UDim2.new(0, 110, 0, 0)
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
	local clientsChip = Instance.new("TextButton")
	clientsChip.Name = "Clients"
	clientsChip.AnchorPoint = Vector2.new(1, 0.5)
	clientsChip.Position = UDim2.new(1, -252, 0.5, 0)
	clientsChip.Size = UDim2.new(0, 84, 0, 18)
	clientsChip.BackgroundColor3 = PALETTE.rule
	clientsChip.BackgroundTransparency = 1
	clientsChip.BorderSizePixel = 0
	clientsChip.Font = Palette.FONT
	clientsChip.TextSize = 13
	themed(clientsChip, "TextColor3", "dim")
	clientsChip.Text = ""
	clientsChip.AutoButtonColor = false
	clientsChip.Visible = false
	clientsChip.Parent = header
	state.clientsChip = clientsChip

	--[[
		A count raises a question the count cannot answer.

		"3 clients" is the exact thing users bring to us asking whether it is a
		problem, and it never is answerable from a number: three agents they
		started and three processes they forgot look identical. Hovering names
		them in the caption -- cheap, no click, no panel to dismiss -- and
		clicking writes the full roster into the log, where it can be scrolled
		back to and acted on.
	]]
	clientsChip.MouseEnter:Connect(function()
		clientsChip.TextColor3 = PALETTE.text
		clientsChip.BackgroundTransparency = 0.88
	end)
	clientsChip.MouseLeave:Connect(function()
		clientsChip.TextColor3 = PALETTE.dim
		clientsChip.BackgroundTransparency = 1
	end)
	clientsChip.Activated:Connect(function()
		Console.reportClients()
	end)


	local buttons = Instance.new("Frame")
	buttons.AnchorPoint = Vector2.new(1, 0.5)
	buttons.Position = UDim2.new(1, 0, 0.5, 0)
	buttons.Size = UDim2.new(0, BUTTONS_WIDE, 0, ICON_BUTTON)
	buttons.BackgroundTransparency = 1
	buttons.Parent = header
	state.headerButtons = buttons

	local buttonLayout = Instance.new("UIListLayout")
	buttonLayout.FillDirection = Enum.FillDirection.Horizontal
	buttonLayout.HorizontalAlignment = Enum.HorizontalAlignment.Right
	buttonLayout.VerticalAlignment = Enum.VerticalAlignment.Center
	buttonLayout.Padding = UDim.new(0, 4)
	buttonLayout.SortOrder = Enum.SortOrder.LayoutOrder
	buttonLayout.Parent = buttons

	--[[
		Theme dots: one diamond per theme in its own colour; the active one is
		ringed. Clicking switches the whole panel live.
	]]
	local swatchRow = Instance.new("Frame")
	swatchRow.Name = "Themes"
	swatchRow.BackgroundTransparency = 1
	swatchRow.Size = UDim2.fromOffset(SWATCHES_WIDTH, ICON_BUTTON)
	swatchRow.LayoutOrder = 0
	swatchRow.Parent = buttons
	state.swatchRow = swatchRow
	local swatchLayout = Instance.new("UIListLayout")
	swatchLayout.FillDirection = Enum.FillDirection.Horizontal
	swatchLayout.VerticalAlignment = Enum.VerticalAlignment.Center
	swatchLayout.Padding = UDim.new(0, SWATCH_GAP)
	swatchLayout.SortOrder = Enum.SortOrder.LayoutOrder
	swatchLayout.Parent = swatchRow
	for order, theme in Palette.list() do
		local swatch = Instance.new("TextButton")
		swatch.Name = theme.id
		swatch.Text = ""
		swatch.AutoButtonColor = false
		swatch.BorderSizePixel = 0
		swatch.Rotation = 45
		swatch.Size = UDim2.fromOffset(SWATCH - 2, SWATCH - 2)
		swatch.BackgroundColor3 = theme.accent
		swatch.LayoutOrder = order
		swatch.Parent = swatchRow
		local ring = Instance.new("UIStroke")
		ring.Name = "Ring"
		ring.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
		ring.Thickness = 1.5
		ring.Parent = swatch
		swatch.MouseEnter:Connect(function()
			swatch.Size = UDim2.fromOffset(SWATCH, SWATCH)
		end)
		swatch.MouseLeave:Connect(function()
			swatch.Size = UDim2.fromOffset(SWATCH - 2, SWATCH - 2)
		end)
		swatch.Activated:Connect(function()
			if Palette.use(theme.id) then
				Console.applyTheme()
				handlers.onTheme(theme.id)
			end
		end)
		state.swatches[theme.id] = swatch
	end
	Console.paintSwatches()

	makeIconButton(buttons, "reconnect", "reconnect to the bridge", 2).Activated:Connect(handlers.onReconnect)
	makeIconButton(buttons, "clear", "clear the log", 3).Activated:Connect(handlers.onClear)

	header:GetPropertyChangedSignal("AbsoluteSize"):Connect(layoutHeader)
	task.defer(function()
		layoutHeader()
	end)

	-- Accent rule under the header. One hairline in the signature violet is what
	-- separates this from every other grey dock in Studio.
	local rule = Instance.new("Frame")
	rule.Position = UDim2.new(0, 0, 0, HEADER_HEIGHT)
	rule.Size = UDim2.new(1, 0, 0, 1)
	themed(rule, "BackgroundColor3", "rule")
	rule.BorderSizePixel = 0
	rule.Parent = root

	local ruleFade = Instance.new("UIGradient")
	ruleFade.Color = ColorSequence.new(PALETTE.rule)
	state.ruleFade = ruleFade
	ruleFade.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.6),
		NumberSequenceKeypoint.new(1, 0.6),
	})
	ruleFade.Parent = rule

	-- Log ------------------------------------------------------------------
	local scroller = Instance.new("ScrollingFrame")
	scroller.Position = UDim2.new(0, 0, 0, 33)
	scroller.Size = UDim2.new(1, 0, 1, -55)
	scroller.BackgroundTransparency = 1
	scroller.BorderSizePixel = 0
	scroller.ScrollBarThickness = 5
	themed(scroller, "ScrollBarImageColor3", "rule")
	scroller.ScrollBarImageTransparency = 0.5
	scroller.CanvasSize = UDim2.new()
	scroller.AutomaticCanvasSize = Enum.AutomaticSize.Y
	scroller.ScrollingDirection = Enum.ScrollingDirection.Y
	scroller.Parent = root
	state.scroller = scroller

	local logPadding = Instance.new("UIPadding")
	logPadding.PaddingTop = UDim.new(0, 8)
	logPadding.PaddingBottom = UDim.new(0, 8)
	logPadding.PaddingLeft = UDim.new(0, 8)
	logPadding.PaddingRight = UDim.new(0, 8)
	logPadding.Parent = scroller

	-- One row per record lives in here; see `paint`.
	local list = Instance.new("Frame")
	list.Name = "Log"
	-- Narrowed by the scroller's side padding by hand: a scale width inside a
	-- ScrollingFrame measures against the canvas, which UIPadding does not
	-- shrink, so a full-width log ran 12px past the panel's right edge.
	list.Size = UDim2.new(1, -16, 0, 0)
	list.AutomaticSize = Enum.AutomaticSize.Y
	list.BackgroundTransparency = 1
	list.BorderSizePixel = 0
	list.Parent = scroller
	state.list = list

	local listLayout = Instance.new("UIListLayout")
	listLayout.SortOrder = Enum.SortOrder.LayoutOrder
	listLayout.Padding = UDim.new(0, 0)
	listLayout.Parent = list

	--[[
		The clear wipe's overlay, built once and hidden.

		Four nested pieces, and each one earns its place. `crt` is unclipped and
		covers the log region, so the line can stay full width while the screen
		inside it closes. `screen` is the clip that actually collapses, anchored
		to its own middle so it shuts toward the centre rather than rolling up
		from the top. `window` is a fixed-height clip that does not move with it,
		which is what holds the copied text still while the screen closes over
		it. `ghost` is the copy.
	]]
	local crt = Instance.new("Frame")
	crt.Name = "ClearWipe"
	crt.BackgroundTransparency = 1
	crt.BorderSizePixel = 0
	crt.Visible = false
	crt.ZIndex = Z_CRT
	crt.Parent = root
	state.crt = crt

	local crtScreen = Instance.new("Frame")
	crtScreen.Name = "Screen"
	crtScreen.AnchorPoint = Vector2.new(0.5, 0.5)
	crtScreen.Position = UDim2.fromScale(0.5, 0.5)
	crtScreen.Size = UDim2.new(1, 0, 1, 0)
	themed(crtScreen, "BackgroundColor3", "background")
	crtScreen.BorderSizePixel = 0
	crtScreen.ClipsDescendants = true
	crtScreen.ZIndex = Z_CRT
	crtScreen.Parent = crt
	state.crtScreen = crtScreen

	local crtWindow = Instance.new("Frame")
	crtWindow.Name = "Window"
	crtWindow.AnchorPoint = Vector2.new(0.5, 0.5)
	crtWindow.Position = UDim2.fromScale(0.5, 0.5)
	crtWindow.Size = UDim2.new(1, 0, 1, 0)
	crtWindow.BackgroundTransparency = 1
	crtWindow.BorderSizePixel = 0
	crtWindow.ClipsDescendants = true
	crtWindow.ZIndex = Z_CRT_TEXT
	crtWindow.Parent = crtScreen
	state.crtWindow = crtWindow

	-- Every text property the log's own label has, because the copy has to be
	-- indistinguishable from it for the frame before it starts moving.
	local crtGhost = Instance.new("TextLabel")
	crtGhost.Name = "Ghost"
	crtGhost.BackgroundTransparency = 1
	crtGhost.Font = Enum.Font.Code
	crtGhost.TextSize = 12
	crtGhost.LineHeight = 1.25
	themed(crtGhost, "TextColor3", "text")
	crtGhost.RichText = true
	crtGhost.TextWrapped = true
	crtGhost.AutomaticSize = Enum.AutomaticSize.Y
	crtGhost.Size = UDim2.new(1, -24, 0, 0)
	crtGhost.TextXAlignment = Enum.TextXAlignment.Left
	crtGhost.TextYAlignment = Enum.TextYAlignment.Top
	crtGhost.Text = ""
	crtGhost.ZIndex = Z_CRT_TEXT
	crtGhost.Parent = crtWindow
	state.crtGhost = crtGhost

	-- The line the picture discharges into. Outside `screen`, so it keeps its
	-- width while the screen closes to nothing behind it.
	local crtLine = Instance.new("Frame")
	crtLine.Name = "Line"
	crtLine.AnchorPoint = Vector2.new(0.5, 0.5)
	crtLine.Position = UDim2.fromScale(0.5, 0.5)
	crtLine.Size = UDim2.new(1, 0, 0, 2)
	themed(crtLine, "BackgroundColor3", "text")
	crtLine.BorderSizePixel = 0
	crtLine.Visible = false
	crtLine.ZIndex = Z_CRT_LINE
	crtLine.Parent = crt
	state.crtLine = crtLine

	-- Status bar ------------------------------------------------------------
	local footer = Instance.new("Frame")
	footer.AnchorPoint = Vector2.new(0, 1)
	footer.Position = UDim2.fromScale(0, 1)
	footer.Size = UDim2.new(1, 0, 0, FOOTER_HEIGHT)
	themed(footer, "BackgroundColor3", "surface")
	footer.BackgroundTransparency = 0.4
	footer.BorderSizePixel = 0
	footer.Parent = root

	local footerPadding = Instance.new("UIPadding")
	footerPadding.PaddingLeft = UDim.new(0, 12)
	footerPadding.PaddingRight = UDim.new(0, 12)
	footerPadding.Parent = footer

	local prompt = Instance.new("TextLabel")
	prompt.Text = "rbx-studio"
	prompt.Font = Palette.FONT
	prompt.TextSize = 12
	themed(prompt, "TextColor3", "dim")
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
	counters.Font = Palette.FONT
	counters.TextSize = 12
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
	--[[
		The prompt sits at the BOTTOM, above the status bar.

		It started under the header, which put it as far from the newest log line
		as the panel allows: you typed at the top, the answer arrived at the
		bottom, and reading your own session meant crossing the whole widget
		twice. Every terminal and every chat window puts the input against the
		tail of the output for that reason, and this is both of those things.

		It is not inside the activity band either, though the band's caption line
		reads like a prompt already. The band is toggleable, and hiding the only
		way to type into the panel behind a decoration switch is a trap.
	]]
	Prompt.mount(root, {
		submit = handlers.onSubmit,
		complete = handlers.onComplete,
		suggest = handlers.onSuggest,
	})
	local promptRow = root:FindFirstChild("Prompt") :: Frame
	promptRow.AnchorPoint = Vector2.new(0, 1)
	promptRow.Position = UDim2.new(0, 0, 1, -FOOTER_HEIGHT)
	promptRow.Size = UDim2.new(1, 0, 0, Prompt.HEIGHT)

	-- The log fills what the header, the prompt and the status bar leave.
	local function layoutLog()
		local top = HEADER_HEIGHT + 1
		scroller.Position = UDim2.new(0, 0, 0, top)
		scroller.Size = UDim2.new(1, 0, 1, -(top + FOOTER_HEIGHT + Prompt.HEIGHT))
	end
	state.relayout = layoutLog
	layoutLog()

	-- A click on the log's empty background wakes the theme's animation.
	-- Rows are buttons and take their own clicks, so only open space gets here.
	scroller.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 and not Prompt.isMenuOpen() then
			Backdrop.click(Vector2.new(input.Position.X, input.Position.Y), PALETTE.rule)
		end
	end)

	-- Treat "scrolled away from the bottom" as the user reading history, and
	-- stop yanking the view down under them until they scroll back.
	scroller:GetPropertyChangedSignal("CanvasPosition"):Connect(function()
		local maxScroll = math.max(0, scroller.AbsoluteCanvasSize.Y - scroller.AbsoluteWindowSize.Y)
		state.pinned = maxScroll - scroller.CanvasPosition.Y < 24
		if state.pinned then
			state.unread = 0
		end
		updateJumpPill()
	end)

	-- Rows size themselves a frame after they are added, so following the tail
	-- from `paint` alone lands one row short. Following the canvas itself does
	-- not.
	scroller:GetPropertyChangedSignal("AbsoluteCanvasSize"):Connect(function()
		if state.pinned and not state.hoverHold then
			local maxScroll = math.max(0, scroller.AbsoluteCanvasSize.Y - scroller.AbsoluteWindowSize.Y)
			scroller.CanvasPosition = Vector2.new(0, maxScroll)
		end
	end)

	-- Offers the way back to the tail once the user has scrolled away from it.
	local pill = Instance.new("TextButton")
	pill.Name = "JumpToLatest"
	pill.AnchorPoint = Vector2.new(1, 1)
	pill.Position = UDim2.new(1, -16, 1, -(FOOTER_HEIGHT + Prompt.HEIGHT + 8))
	pill.Size = UDim2.new(0, 76, 0, 22)
	pill.Font = Palette.FONT_MEDIUM
	pill.TextSize = 12
	pill.AutoButtonColor = false
	pill.BorderSizePixel = 0
	pill.ZIndex = 10
	pill.Visible = false
	pill.BackgroundColor3 = Palette.deep()
	pill.BackgroundTransparency = 0.2
	themed(pill, "TextColor3", "text")
	pill.Parent = root
	state.jumpPill = pill


	local pillCorner = Instance.new("UICorner")
	pillCorner.CornerRadius = UDim.new(1, 0)
	pillCorner.Parent = pill

	local pillStroke = Instance.new("UIStroke")
	-- Border, not Contextual: on a button the default outlines the text.
	pillStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	themed(pillStroke, "Color", "rule")
	pillStroke.Transparency = 0.45
	pill.MouseEnter:Connect(function()
		pillStroke.Transparency = 0.1
	end)
	pill.MouseLeave:Connect(function()
		pillStroke.Transparency = 0.45
	end)
	pillStroke.Parent = pill

	pill.Activated:Connect(function()
		state.pinned = true
		state.unread = 0
		scroller.CanvasPosition = Vector2.new(0, math.max(0, scroller.AbsoluteCanvasSize.Y))
		updateJumpPill()
	end)
	updateJumpPill()
end

--[[
	Narrows the log to one level, or opens it back up when given nothing.

	Nothing is discarded. The records are all still there and a repaint brings
	them back, which is the only behaviour that makes a filter safe to reach for
	mid-session: the alternative is a user hiding the very row they were about
	to read and having no way back to it.
]]
function Console.setFilter(levels: { string }?)
	if levels == nil or #levels == 0 then
		state.filter = nil
	else
		local wanted: { [string]: boolean } = {}
		for _, level in levels do
			wanted[level] = true
		end
		state.filter = wanted
	end
	state.rebuild = true
	redraw()
end

--[[
	The log as plain text, timestamps and all, with the markup taken back out.

	`copy` needs the words rather than the rendering, and rebuilding them from
	the records is the only honest source: the rendered label is RichText, and a
	stripped copy of it would carry whatever the escaping did to the user's own
	angle brackets.

	Every line is commented out, because the only place Studio will show this to
	you is a script editor -- and a log pasted in as code is a wall of red
	underlines with a syntax error on the first word. Commented, it opens as
	something you read, which is what it is.
]]
function Console.plainText(): string
	local lines: { string } = { "-- rbx-studio console log" }
	for _, record in state.records do
		local sigil = if record.turn then "\u{203A}" else (LEVELS[record.level] or LEVELS.info).sigil
		-- Typed lines say so, as they did before the thread replaced "you".
		local shown = if record.turn then (record.detail or "you") else record.detail
		local detail = if shown ~= nil then "    " .. shown else ""
		table.insert(
			lines,
			string.format("-- %s %s %s%s", record.stamp, sigil, record.message, detail)
		)
	end
	return table.concat(lines, "\n")
end

function Console.focusPrompt()
	Prompt.focus()
end

--[[
	Passes Studio's current selection to the prompt row.

	A pass-through, and worth having anyway: `init.server` owns the watcher and
	the console owns the widget, and letting the watcher reach into `Prompt`
	directly would give the panel two owners.
]]
function Console.setSelection(text: string)
	Prompt.setSelection(text)
end

--[[
	Reports that an agent started from the prompt is working.

	Two instruments, one fact. The caret says it to whoever is about to type;
	the cell says it to whoever is glancing at the panel from across the screen.
	Told in one place because they must never disagree -- a caret that has gone
	back to violet beside a cell still pulsing is a panel arguing with itself.
]]
function Console.setPromptBusy(busy: boolean)
	Prompt.setBusy(busy)
end

-- Whether the prompt row invites sentences. See `chat` in Commands.
function Console.setPromptChat(enabled: boolean)
	Prompt.setChat(enabled)
end

-- Rings the active theme's dot and dims the rest.
function Console.paintSwatches()
	local active = Palette.theme().id
	for id, dot in state.swatches do
		local ring = dot:FindFirstChild("Ring") :: UIStroke?
		if ring then
			ring.Color = PALETTE.text
			ring.Transparency = if id == active then 0 else 1
		end
		dot.BackgroundTransparency = if id == active then 0 else 0.35
	end
end

--[[
	Repaints the whole panel in the active theme: every registered colour, the
	background gradient and effect, the prompt, the header icons, and the log,
	whose rows are rebuilt so they pick up the new colours.
]]
function Console.applyTheme()
	PALETTE = Palette.get()
	for _, role in roles do
		if role.instance.Parent ~= nil or role.instance:IsA("UIStroke") then
			pcall(function()
				(role.instance :: any)[role.property] = PALETTE[role.key]
			end)
		end
	end
	local field = state.fieldGradient
	if field then
		field.Color = ColorSequence.new(PALETTE.background, Palette.deep())
	end
	local ruleFade = state.ruleFade
	if ruleFade then
		ruleFade.Color = ColorSequence.new(PALETTE.rule)
	end
	local pill = state.jumpPill
	if pill then
		pill.BackgroundColor3 = Palette.deep()
	end
	Backdrop.show(Palette.theme().backdrop, PALETTE.rule)
	Console.setStatus(state.status, state.statusMeta)
	refreshCounters()
	Prompt.applyTheme()
	local buttons = state.headerButtons
	if buttons then
		for _, child in buttons:GetChildren() do
			if child:IsA("TextButton") then
				child:SetAttribute("Repaint", ((child:GetAttribute("Repaint") or 0) :: number) + 1)
			end
		end
	end
	Console.paintSwatches()
	--[[
		Built rows are recoloured where they stand rather than rebuilt: with a
		full log a rebuild was hundreds of rows in one frame, and it cut off
		every animation in flight. Spread over a few frames so a full log does
		not hitch either.
	]]
	state.repaintGeneration = (state.repaintGeneration or 0) + 1
	local generation = state.repaintGeneration
	local pending: { Record } = {}
	for index = #state.records, 1, -1 do
		local record = state.records[index]
		if record.widget ~= nil and record.repaint ~= nil then
			table.insert(pending, record)
		end
	end
	task.spawn(function()
		-- Newest first, since that is the end of the log on screen.
		for index, record in pending do
			if state.repaintGeneration ~= generation then
				return
			end
			if record.widget ~= nil and record.repaint ~= nil then
				record.repaint()
			end
			if index % 60 == 0 then
				task.wait()
			end
		end
	end)
	redraw()
end

return Console
