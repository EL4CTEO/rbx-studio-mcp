--!strict
--[[
	The console's activity band: a themed cell beside a live latency trace.

	Watching an agent work is mostly waiting, and the log answers "what is it
	doing" precisely while answering "is it still alive" badly -- a stalled
	session and a thinking one produce the same still screen.

	This began as a full-panel overlay and that was wrong. It sat on top of the
	log, so the thing you actually read was covered and, being slightly
	transparent, softened underneath. Decoration that costs legibility is a bad
	trade however good it looks. So it is a band now: a fixed strip above the
	log, which keeps every line at full contrast and never moves under the
	reader. The log shrinks by the band's height and nothing overlaps.

	The strip earns its space twice over. The cell on the left says the session
	is live; the trace beside it is the last forty calls, each drawn as tall as
	it was slow and coloured by whether it worked. That turns "is it alive" and
	"is it healthy" into one glance, which is more than the log gives and more
	than an animation alone would.

	WHAT THIS FILE OWNS, since it used to own everything: the strip's Instances,
	the pointer handling on the trace, and the simulation -- energy, activity,
	flare, shake, the scale spring, the quiet timer and the blended tint. What
	it does NOT own is any drawing inside the cell. That belongs to whichever
	preset is active (see Themes/), which is handed the simulation each frame
	and paints whatever it likes with it. Eight presets are therefore eight
	painters over one set of physics rather than eight animation systems, and
	only one of them is ever mounted.
]]

local RunService = game:GetService("RunService")

local Themes = require(script.Parent.Themes)

local Visuals = {}

-- How long the session must go without a command before the cell winds down.
-- Matches the console's idle notice, so the picture and the log agree.
local QUIET_AFTER = 20

--[[
	Spring constants for the scale. Stiff enough that a call reads as a snap
	rather than a swell, damped just under critical so a reply overshoots once
	and settles instead of ringing.
]]
local SPRING = 90
local DAMPING = 14

-- How many calls the trace remembers. Forty is about a screen's width of bars
-- at five pixels each, and about as far back as anyone reads a trend.
local TRACE = 40

-- Bars are scaled against this, so a normal call is a low bar and a slow one is
-- obvious. Anything past it clamps to full height rather than flattening the
-- rest of the trace into invisibility.
local SLOW_MS = 400

-- Pixels from one bar to the next. Also the width of a bar's hit target and of
-- the hover highlight, so pointing between two bars still selects one of them
-- rather than falling into a dead gap.
local BAR_STRIDE = 5

-- Height of the trace, and so of every bar's hit column. The taller band spends
-- its extra pixels here: a 19px column was a small thing to aim a pointer at.
local TRACE_HEIGHT = 26

--[[
	The strip's height, and the geometry around the cell.

	The cell was originally as tall as the band and read as looming; it crowded
	the caption and made the strip feel like a panel. It is an indicator, not the
	subject, so it sits small with air around it.

	INSET and GUTTER both grew after the cell stopped being a wireframe and
	started being eight different things. At six pixels from the panel edge the
	cell was pressed into the corner, which reads as cramped for a prism and
	simply wrong for a starfield -- a sky needs a horizon around it, not a
	border. The band grew with them so the extra margin comes out of empty space
	rather than out of the trace, whose bars are what people try to point at.
]]
Visuals.BAND_HEIGHT = 58
local CELL = 40
local INSET = 12
local GUTTER = 22

type Bar = {
	frame: Frame,
	--[[
		An invisible column over the bar, full height of the trace, wide enough to
		hit. The bar itself is three pixels wide and usually one pixel tall -- a
		fast call is a stub on the baseline -- so hovering the bar is not something
		a person can reliably do. The hit target is the whole column above it, so
		pointing anywhere near a bar selects it.
	]]
	hit: TextButton,
	milliseconds: number,
	ok: boolean,
	--[[
		What ran, in the same words the log uses.

		The trace plotted durations with nothing to attach them to, so a tall bar
		raised the question it could not answer: forty numbers and no way to tell
		which of them was the script edit. Carried per bar rather than looked up,
		because the bar outlives whatever produced it.
	]]
	title: string,
}

type Runtime = {
	band: Frame?,
	cell: Frame?,
	trace: Frame?,
	divider: Frame?,
	baseline: Frame?,
	highlight: Frame?,
	readout: TextLabel?,
	caption: TextLabel?,
	bars: { Bar },
	connection: RBXScriptConnection?,

	spin: Vector3,
	angle: Vector3,

	energy: number,
	shake: number,
	--[[
		The cell's size, as a spring rather than a value.

		Scale was previously a small function of energy -- a 24% range that
		nobody could see. Driving it as a spring means each event can push it and
		let physics do the rest: a dispatch pulls it in, a reply throws it out
		past its resting size, and it settles on its own.
	]]
	scale: number,
	scaleVelocity: number,
	-- Spikes to 1 the instant a reply lands, gone in a third of a second.
	flare: number,
	-- Seconds since anything last ran. Drives the wind-down.
	quiet: number,
	tint: Color3,
	targetTint: Color3,
	baseTint: Color3,
	activeTint: Color3,
	activity: number,
	lastTitle: string?,
	-- Whether the active preset has been given its Instances yet.
	mounted: boolean,
}

local runtime: Runtime = {
	band = nil,
	cell = nil,
	trace = nil,
	divider = nil,
	baseline = nil,
	highlight = nil,
	readout = nil,
	caption = nil,
	bars = {},
	connection = nil,
	spin = Vector3.new(0.18, 0.27, 0.11),
	angle = Vector3.zero,
	energy = 0,
	shake = 0,
	scale = 1,
	scaleVelocity = 0,
	flare = 0,
	quiet = 0,
	tint = Color3.fromRGB(167, 139, 250),
	targetTint = Color3.fromRGB(167, 139, 250),
	baseTint = Color3.fromRGB(167, 139, 250),
	activeTint = Color3.fromRGB(167, 139, 250),
	activity = 0,
	lastTitle = nil,
	mounted = false,
}

--[[
	The simulation, packaged for whichever preset is drawing it.

	Rebuilt every frame rather than mutated in place. A preset holding onto the
	table between frames would see values change under it, and the one rule that
	keeps eight renderers honest is that they read this and draw -- they do not
	own any of it.
]]
local function context(): Themes.Context
	return {
		palette = Themes.palette(),
		tint = runtime.tint,
		energy = runtime.energy,
		activity = runtime.activity,
		flare = runtime.flare,
		shake = runtime.shake,
		scale = runtime.scale,
		quiet = runtime.quiet,
		angle = runtime.angle,
		clock = os.clock(),
		size = CELL,
		centre = Vector2.new(CELL / 2, CELL / 2),
	}
end

local function step(delta: number)
	local band = runtime.band
	local cell = runtime.cell
	if band == nil or cell == nil or not band.Visible then
		return
	end

	runtime.energy = math.max(0, runtime.energy - delta * 0.9)
	runtime.shake = math.max(0, runtime.shake - delta * 2.4)
	--[[
		Slower than it was. The cell is meant to climb as the session works, and
		at the old rates a call had to arrive every three seconds just to hold the
		middle of the range -- so the top of it was, in practice, unreachable. A
		burst of four calls now gets there, and it unwinds over about ten seconds
		afterwards.
	]]
	runtime.activity = math.max(0, runtime.activity - delta * 0.28)
	runtime.flare = math.max(0, runtime.flare - delta * 3)
	runtime.quiet += delta
	--[[
		Two colours, blended by how recently something happened.

		`baseTint` is the connection state, which is what the panel should read
		as when nothing is going on. `activeTint` is the kind of work last done
		-- reading, writing, running, debugging -- and it takes over while that
		work is fresh, then fades back. So the strip is not one fixed colour: it
		leans toward whatever the session is actually doing and returns to
		resting on its own.
	]]
	local blend = math.clamp(runtime.energy, 0, 1)
	runtime.targetTint = runtime.baseTint:Lerp(runtime.activeTint, blend)
	runtime.tint = runtime.tint:Lerp(runtime.targetTint, math.min(1, delta * 5))

	-- Turning faster while busy makes the rate itself readable: a glance says
	-- whether anything is happening without reading a word.
	--
	-- And nearly stopping once the session has gone quiet, for the same reason in
	-- reverse: a strip that keeps moving at its working rate hours after the
	-- last command claims an activity that is not happening.
	local pace = if runtime.quiet > QUIET_AFTER then 0.25 else 1
	runtime.angle += runtime.spin * delta * (1 + runtime.energy * 2.2) * pace

	--[[
		Where the cell wants to be, before the spring gets a say.

		Three things move it and they are deliberately ordered. Energy -- how
		recently work happened -- swells it while a session is busy. The breathe
		is a slow sine that only survives while energy is near zero, so an idle
		panel is visibly alive without a resting animation competing with the
		reaction to a real call. And past QUIET_AFTER seconds of nothing, it draws
		in and stays there: the picture of a session that has stopped.
	]]
	local calm = 1 - math.clamp(runtime.energy, 0, 1)
	local breathe = math.sin(os.clock() * 0.9) * 0.04 * calm
	local target = 1 + math.clamp(runtime.energy, 0, 1.6) * 0.18 + breathe
	if runtime.quiet > QUIET_AFTER then
		target = 0.82
	end

	--[[
		A damped spring rather than a lerp, because a lerp cannot overshoot and
		overshoot is the whole point: a reply that pushes the cell past its
		resting size and lets it fall back reads as a thing being struck, where
		easing toward a value reads as a slider being dragged.

		Integrated semi-implicitly -- velocity first, then position from the new
		velocity -- which stays stable at the frame times Studio actually hands us
		rather than only at small ones.
	]]
	--[[
		Substepped rather than truncated.

		`math.min(delta, 1/30)` kept the integration stable, but it also THREW
		AWAY the rest of a long frame: at 20fps a third of every frame's motion
		simply did not happen, so the spring ran slower in wall-clock time
		exactly when Studio was busiest -- which is during a tool call, which is
		when the spring is reacting to something. Stepping the leftover instead
		keeps the reaction the same length whatever the frame rate, and the cap
		on the number of steps stops a two-second hitch from paying it all back
		in one frame.
	]]
	local remaining = math.min(delta, 0.25)
	for _ = 1, 8 do
		if remaining <= 0 then
			break
		end
		local integration = math.min(remaining, 1 / 60)
		remaining -= integration

		runtime.scaleVelocity += (target - runtime.scale) * SPRING * integration
		runtime.scaleVelocity -= runtime.scaleVelocity * DAMPING * integration
		runtime.scale += runtime.scaleVelocity * integration

		--[[
			Clamping the position without killing the velocity is what made a
			reply read as a jolt rather than a bounce. The reply impulse is
			`scaleVelocity += 9`, which crosses the whole 0.55..1.7 range in
			about two frames, so the scale pinned itself against the ceiling
			while still carrying all that speed -- and then sat there, motionless
			but not at rest, until the spring had spent the stored velocity. The
			eye reads that as a snap, a stall, and a second snap.

			Zeroing the component pushing into the rail turns it into a stop.
		]]
		if runtime.scale <= 0.55 then
			runtime.scale = 0.55
			runtime.scaleVelocity = math.max(runtime.scaleVelocity, 0)
		elseif runtime.scale >= 1.7 then
			runtime.scale = 1.7
			runtime.scaleVelocity = math.min(runtime.scaleVelocity, 0)
		end
	end

	--[[
		Handed off. A preset that throws must not take the console's status
		display down with it, so a failure here disables the strip and says so
		once rather than erroring sixty times a second.
	]]
	local ok, err = pcall(Themes.active().paint, context(), delta)
	if not ok then
		band.Visible = false
		warn(string.format("[rbx-studio] theme %q failed to paint: %s", Themes.activeId(), tostring(err)))
	end
end

--[[
	Puts the highlight behind one bar and prints its timing.

	The trace is only legible if you already know what it plots, and nothing on
	screen said so. Hovering answers it directly: the column lights up, and the
	number that made that bar its height appears in words. One reading at a time,
	so a single highlight and a single label are moved around rather than one of
	each being built per bar.
]]
local function showReading(entry: Bar)
	local highlight = runtime.highlight
	local readout = runtime.readout
	if highlight == nil or readout == nil then
		return
	end

	--[[
		The Y here has to be 1, and was 0.

		The highlight is anchored to its own bottom edge, so a Y scale of 0 put
		that edge on the trace's top line and drew the whole 26px column above it
		-- outside a frame that clips its descendants. The hover was therefore
		never visible to anyone: the hit targets fired, the readout appeared, and
		the highlight they were meant to explain was off screen every time.
	]]
	highlight.Position = UDim2.new(entry.hit.Position.X.Scale, entry.hit.Position.X.Offset, 1, 0)
	highlight.Visible = true

	--[[
		Named, not just timed.

		A duration with nothing attached to it raises the question it cannot
		answer -- forty bars, one of them tall, and no way to tell whether that
		was a script edit or a screenshot. The title is the same phrase the log
		row uses, so pointing at a bar and reading the log agree with each other.
	]]
	local palette = Themes.palette()
	readout.Text = if entry.ok
		then string.format("%s: %d ms", entry.title, math.round(entry.milliseconds))
		else string.format("%s: failed after %d ms", entry.title, math.round(entry.milliseconds))
	readout.TextColor3 = if entry.ok then palette.text else palette.red
	readout.Visible = true
end

local function clearReading()
	if runtime.highlight then
		runtime.highlight.Visible = false
	end
	if runtime.readout then
		runtime.readout.Visible = false
	end
end

--[[
	Bars, for a preset that does not want to draw its own history.

	Height is duration and colour is outcome, so a slow call and a failed one are
	distinguishable at a glance -- which is the pair of questions that actually
	get asked of a log this size.
]]
local function defaultSlot(slot: Themes.Slot, ctx: Themes.Context)
	local frame = slot.frame
	frame.AnchorPoint = Vector2.new(0.5, 1)
	frame.Size = UDim2.new(0, 3, math.max(slot.weight, 0.06), 0)
	frame.Position = UDim2.new(frame.Position.X.Scale, frame.Position.X.Offset, 1, 0)
	frame.BackgroundColor3 = if slot.ok then ctx.palette.violet else ctx.palette.red
	frame.BackgroundTransparency = 0.15 + slot.age * 0.6
	frame.Rotation = 0
end

--[[
	Re-places every bar and hands each to the active preset to draw.

	Laid out right to left so the newest bar is always at the same edge and the
	trace reads as scrolling rather than reshuffling. The horizontal position is
	set here and the preset is expected to keep it -- everything else about the
	bar is the preset's to decide.
]]
local function relayout()
	local ctx = context()
	local painter = Themes.active().paintSlot or defaultSlot
	local total = #runtime.bars

	for index, item in runtime.bars do
		local fromRight = total - index
		local offset = -(fromRight + 1) * BAR_STRIDE + BAR_STRIDE / 2

		item.frame.Position = UDim2.new(1, offset, 1, 0)
		item.hit.Position = UDim2.new(1, offset, 1, 0)

		local slot: Themes.Slot = {
			frame = item.frame,
			milliseconds = item.milliseconds,
			ok = item.ok,
			title = item.title,
			-- 0 for the newest, rising toward 1 for the oldest still shown.
			age = if TRACE > 1 then fromRight / (TRACE - 1) else 0,
			weight = math.clamp(item.milliseconds / SLOW_MS, 0.06, 1),
		}
		local ok, err = pcall(painter, slot, ctx)
		if not ok then
			-- One bad slot must not leave the other thirty-nine unplaced.
			defaultSlot(slot, ctx)
			warn(string.format("[rbx-studio] theme %q failed on a slot: %s", Themes.activeId(), tostring(err)))
		end
	end
end

--[[
	Records one finished call and re-draws the trace.
]]
function Visuals.recordCall(milliseconds: number, ok: boolean, title: string)
	runtime.energy = math.min(1.6, runtime.energy + (if ok then 0.3 else 0.8))
	runtime.activity = math.min(1, runtime.activity + 0.34)
	runtime.quiet = 0
	runtime.flare = 1

	--[[
		A shove rather than a new target.

		Setting the scale outright would snap; giving the spring velocity lets it
		carry past its resting size and fall back, which is the difference between
		a value changing and something being struck. A failure shoves the other
		way and knocks the axis with it.
	]]
	if ok then
		--[[
			Sized to peak just under the clamp rather than against it.

			At +9 the shove carried the scale into the 1.7 ceiling within about a
			tenth of a second, so what should have been an arc became a rise, a
			flat spot, and a drop -- and a burst of calls, each adding another 9
			to a velocity that was already railed, held it pinned there for as
			long as the burst lasted. +6 tops out around 1.55, which reads as the
			same strike and stays on the curve. The accumulated case is capped
			for the same reason: several calls at once should look busy, not
			stuck.
		]]
		runtime.scaleVelocity = math.min(runtime.scaleVelocity + 6, 8)
	else
		runtime.scale = 0.8
		runtime.scaleVelocity = -2
		runtime.shake = 1
	end

	local trace = runtime.trace
	if trace == nil then
		return
	end

	local bar = Instance.new("Frame")
	bar.AnchorPoint = Vector2.new(0.5, 1)
	bar.BorderSizePixel = 0
	bar.Parent = trace
	-- Presets draw points as well as bars, and a square point is not a point.
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 1)
	corner.Parent = bar

	-- A TextButton rather than a Frame: buttons take mouse events reliably in a
	-- plugin widget, and with no text and no background it is purely a target.
	local hit = Instance.new("TextButton")
	hit.AnchorPoint = Vector2.new(0.5, 1)
	hit.BackgroundTransparency = 1
	hit.Text = ""
	hit.AutoButtonColor = false
	hit.BorderSizePixel = 0
	hit.Size = UDim2.new(0, BAR_STRIDE, 1, 0)
	hit.Parent = trace

	local entry: Bar = {
		frame = bar,
		hit = hit,
		milliseconds = milliseconds,
		ok = ok,
		title = if title ~= "" then title else "call",
	}
	table.insert(runtime.bars, entry)

	hit.MouseEnter:Connect(function()
		showReading(entry)
	end)
	hit.MouseLeave:Connect(function()
		clearReading()
	end)

	while #runtime.bars > TRACE do
		local oldest = runtime.bars[1]
		oldest.frame:Destroy()
		oldest.hit:Destroy()
		table.remove(runtime.bars, 1)
	end

	relayout()

	-- The bars have all moved, so a reading still on screen now names the wrong
	-- one. Cheaper and more honest to drop it than to work out which bar the
	-- pointer has ended up over.
	clearReading()
end

--[[
	The resting colour, which is the connection state.
]]
function Visuals.setTint(color: Color3)
	runtime.baseTint = color
end

--[[
	The colour and pace of the work now running.

	Both are set from the same call because they describe the same thing: what
	kind of command this is. Reads are quick and cool, writes are slower and
	warm, so the strip's colour and its rate agree with each other instead of
	moving independently.
]]
function Visuals.setKind(color: Color3, urgency: number)
	runtime.activeTint = color
	runtime.energy = math.min(1.6, math.max(runtime.energy, urgency))
	runtime.quiet = 0
	--[[
		Drawn in as the command goes out, so the pair reads as one gesture: the
		cell contracts while the request is in flight and springs open when the
		answer arrives. On a fast call the two are almost one motion, which is
		itself the report -- a slow call visibly holds its breath.
	]]
	runtime.scale = math.min(runtime.scale, 0.85)
	runtime.scaleVelocity = math.min(runtime.scaleVelocity, 0)
	-- Re-aimed per kind so successive commands of different types visibly
	-- change the axis rather than continuing the same turn.
	runtime.spin = Vector3.new(
		0.12 + math.random() * 0.16,
		0.18 + math.random() * 0.22,
		0.06 + math.random() * 0.12
	)
end

--[[
	What is running, in the same words the log uses. The motion says something is
	happening; this says what, and neither answers the other's question.
]]
function Visuals.setCaption(title: string)
	runtime.lastTitle = title
	if runtime.caption then
		runtime.caption.Text = title
	end
end

--[[
	Falls back to the last thing that ran once a command finishes.

	The footer already reports totals, so repeating "idle" here would say the
	same word twice on one screen. What has just happened is more useful and is
	not shown anywhere else.
]]
function Visuals.setIdle()
	if runtime.caption == nil then
		return
	end
	runtime.caption.Text = if runtime.lastTitle ~= nil
		then "last: " .. runtime.lastTitle
		else "waiting for a command"
end

--[[
	Winds the cell down, because the session has stopped rather than paused.

	The strip already decays on its own, but decay bottoms out at "idle and
	moving", which looks the same after twenty seconds as after two hours. This
	is the console telling the picture what it has just told the log, so the two
	agree.
]]
function Visuals.setQuiet()
	runtime.quiet = QUIET_AFTER + 1
	runtime.activity = 0
end

--[[
	Empties the trace.

	Paired with the console's clear button. The bars used to survive it while the
	footer counters reset, so "clear" wiped the log, wiped the statistics, and
	left forty timings from the session it had just erased sitting on screen.
]]
function Visuals.clearTrace()
	for _, entry in runtime.bars do
		entry.frame:Destroy()
		entry.hit:Destroy()
	end
	table.clear(runtime.bars)
	clearReading()
end

function Visuals.setVisible(visible: boolean)
	local band = runtime.band
	if band == nil then
		return
	end
	band.Visible = visible

	-- Connected only while on screen: a hidden strip that keeps projecting
	-- geometry every frame is a battery complaint waiting to happen.
	if visible and runtime.connection == nil then
		runtime.connection = RunService.Heartbeat:Connect(step)
	elseif not visible and runtime.connection ~= nil then
		runtime.connection:Disconnect()
		runtime.connection = nil
	end
end

function Visuals.isVisible(): boolean
	local band = runtime.band
	return band ~= nil and band.Visible
end

--[[
	Swaps the cell's contents and recolours the strip's own chrome.

	The order matters. The outgoing preset is unmounted before the cell is
	emptied, so a preset that keeps references cannot be handed destroyed
	Instances; the cell is then cleared outright rather than trusted to be
	clean, because a preset that errored midway through `mount` will have left
	something behind.
]]
function Visuals.applyTheme()
	local cell = runtime.cell
	local band = runtime.band
	if cell == nil or band == nil then
		return
	end

	if runtime.mounted then
		pcall(function()
			Themes.active().unmount()
		end)
	end
	for _, child in cell:GetChildren() do
		child:Destroy()
	end

	local palette = Themes.palette()
	band.BackgroundColor3 = palette.surface
	if runtime.divider then
		(runtime.divider :: Frame).BackgroundColor3 = palette.dim
	end
	if runtime.baseline then
		(runtime.baseline :: Frame).BackgroundColor3 = palette.dim
	end
	if runtime.highlight then
		(runtime.highlight :: Frame).BackgroundColor3 = palette.text
	end
	if runtime.caption then
		(runtime.caption :: TextLabel).TextColor3 = palette.text
	end
	if runtime.readout then
		(runtime.readout :: TextLabel).BackgroundColor3 = palette.background
	end

	local ok, err = pcall(function()
		Themes.active().mount(cell)
	end)
	runtime.mounted = ok
	if not ok then
		warn(string.format("[rbx-studio] theme %q failed to mount: %s", Themes.activeId(), tostring(err)))
	end

	relayout()
	-- A preset that failed to paint disabled the band; a new one deserves the
	-- chance to prove it works.
	band.Visible = true
end

--[[
	Builds the strip. Everything except the cell's contents is created here and
	never again, which is what keeps the per-frame path allocation-free.
]]
function Visuals.mount(parent: Instance)
	local palette = Themes.palette()

	local band = Instance.new("Frame")
	band.Name = "ActivityBand"
	band.BackgroundColor3 = palette.surface
	band.BorderSizePixel = 0
	band.Visible = false
	band.ClipsDescendants = true
	band.Parent = parent
	runtime.band = band

	local cell = Instance.new("Frame")
	cell.Name = "Cell"
	cell.Position = UDim2.fromOffset(INSET, (Visuals.BAND_HEIGHT - CELL) / 2)
	cell.Size = UDim2.fromOffset(CELL, CELL)
	cell.BackgroundTransparency = 1
	cell.ClipsDescendants = true
	cell.Parent = band
	runtime.cell = cell

	-- A hairline between the cell and the trace, so the strip reads as two
	-- instruments rather than one busy rectangle. Centred in the gutter, which
	-- is what keeps the extra margin as air on both sides rather than as a gap
	-- on one.
	local divider = Instance.new("Frame")
	divider.Name = "Divider"
	divider.Position = UDim2.fromOffset(INSET + CELL + GUTTER / 2, 10)
	divider.Size = UDim2.new(0, 1, 1, -20)
	divider.BackgroundColor3 = palette.dim
	divider.BackgroundTransparency = 0.78
	divider.BorderSizePixel = 0
	divider.Parent = band
	runtime.divider = divider

	local right = INSET + CELL + GUTTER

	local caption = Instance.new("TextLabel")
	caption.Name = "Caption"
	caption.Position = UDim2.new(0, right, 0, 6)
	caption.Size = UDim2.new(1, -right - 12, 0, 14)
	caption.BackgroundTransparency = 1
	caption.Font = Enum.Font.Code
	caption.TextSize = 11
	caption.TextColor3 = palette.text
	caption.TextXAlignment = Enum.TextXAlignment.Left
	caption.TextTruncate = Enum.TextTruncate.AtEnd
	caption.Text = "idle"
	caption.Parent = band
	runtime.caption = caption

	local trace = Instance.new("Frame")
	trace.Name = "Trace"
	trace.Position = UDim2.new(0, right, 0, 24)
	trace.Size = UDim2.new(1, -right - 12, 0, TRACE_HEIGHT)
	trace.BackgroundTransparency = 1
	trace.ClipsDescendants = true
	trace.Parent = band
	runtime.trace = trace

	-- A baseline under the bars, so an empty trace still reads as an instrument
	-- waiting for data rather than as a blank gap.
	local baseline = Instance.new("Frame")
	baseline.Name = "Baseline"
	baseline.AnchorPoint = Vector2.new(0, 1)
	baseline.Position = UDim2.fromScale(0, 1)
	baseline.Size = UDim2.new(1, 0, 0, 1)
	baseline.BackgroundColor3 = palette.dim
	baseline.BackgroundTransparency = 0.75
	baseline.BorderSizePixel = 0
	baseline.Parent = trace
	runtime.baseline = baseline

	--[[
		Built once and moved, and created BEFORE the bars exist so it sits under
		them in draw order -- a highlight drawn over a one-pixel bar would hide the
		very thing it is pointing at.
	]]
	local highlight = Instance.new("Frame")
	highlight.Name = "Highlight"
	highlight.AnchorPoint = Vector2.new(0.5, 1)
	highlight.Position = UDim2.new(1, 0, 1, 0)
	highlight.Size = UDim2.new(0, BAR_STRIDE, 1, 0)
	highlight.BackgroundColor3 = palette.text
	-- Faint enough not to hide the bar it sits behind, solid enough to be seen
	-- at all.
	highlight.BackgroundTransparency = 0.7
	highlight.BorderSizePixel = 0
	highlight.Visible = false
	highlight.Parent = trace
	runtime.highlight = highlight

	--[[
		The reading sits at the left end of the trace rather than beside the bar it
		describes. Following the pointer would put it off the right edge for the
		newest bars, which are the ones most often asked about, and the left end is
		empty until forty calls have accumulated.
	]]
	local readout = Instance.new("TextLabel")
	readout.Name = "Readout"
	readout.AnchorPoint = Vector2.new(0, 0.5)
	readout.Position = UDim2.new(0, 0, 0.5, 0)
	-- Sized by its text now that it carries a name as well as a number. A fixed
	-- 110px was enough for "18 ms" and truncates anything with a phrase in front
	-- of it, which is the half worth reading.
	readout.AutomaticSize = Enum.AutomaticSize.X
	readout.Size = UDim2.new(0, 0, 0, 14)
	readout.BackgroundColor3 = palette.background
	readout.BackgroundTransparency = 0.15
	readout.BorderSizePixel = 0
	readout.Font = Enum.Font.Code
	readout.TextSize = 11
	readout.TextXAlignment = Enum.TextXAlignment.Left
	readout.Text = ""
	readout.Visible = false
	readout.ZIndex = 3
	readout.Parent = trace
	runtime.readout = readout

	local readoutPadding = Instance.new("UIPadding")
	readoutPadding.PaddingLeft = UDim.new(0, 4)
	readoutPadding.PaddingRight = UDim.new(0, 4)
	readoutPadding.Parent = readout

	local ok, err = pcall(function()
		Themes.active().mount(cell)
	end)
	runtime.mounted = ok
	if not ok then
		warn(string.format("[rbx-studio] theme %q failed to mount: %s", Themes.activeId(), tostring(err)))
	end
end

return Visuals
