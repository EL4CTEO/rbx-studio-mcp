--!strict
--[[
	The console's activity band: a turning wireframe beside a live latency trace.

	Watching an agent work is mostly waiting, and the log answers "what is it
	doing" precisely while answering "is it still alive" badly -- a stalled
	session and a thinking one produce the same still screen.

	This began as a full-panel overlay and that was wrong. It sat on top of the
	log, so the thing you actually read was covered and, being slightly
	transparent, softened underneath. Decoration that costs legibility is a bad
	trade however good it looks. So it is a band now: a fixed strip above the
	log, which keeps every line at full contrast and never moves under the
	reader. The log shrinks by the band's height and nothing overlaps.

	The strip earns its space twice over. The wireframe on the left says the
	session is live; the trace beside it is the last forty calls, each a bar as
	tall as it was slow and coloured by whether it worked. That turns "is it
	alive" and "is it healthy" into one glance, which is more than the log gives
	and more than an animation alone would.

	The solid is a real projection, not a canned loop: vertices rotate in three
	dimensions and pass through a perspective divide every frame, so near edges
	are brighter and thicker because they genuinely are nearer. Roblox has no
	line primitive, so each edge is a thin Frame turned about its midpoint, and
	the frames are pooled -- allocating Instances inside a per-frame loop is how
	a decorative strip becomes a performance complaint.
]]

local RunService = game:GetService("RunService")

local Visuals = {}

local PHI = (1 + math.sqrt(5)) / 2

type Shape = {
	name: string,
	vertices: { Vector3 },
	edges: { { number } },
}

--[[
	Ordered by how busy they look. The session climbs this list as it works, so
	the shape itself reports load: an idle plugin shows a tetrahedron, a busy one
	an icosahedron.
]]
local SHAPES: { Shape } = {
	{
		name = "tetrahedron",
		vertices = {
			Vector3.new(1, 1, 1),
			Vector3.new(1, -1, -1),
			Vector3.new(-1, 1, -1),
			Vector3.new(-1, -1, 1),
		},
		edges = { { 1, 2 }, { 1, 3 }, { 1, 4 }, { 2, 3 }, { 2, 4 }, { 3, 4 } },
	},
	{
		name = "octahedron",
		vertices = {
			Vector3.new(1, 0, 0),
			Vector3.new(-1, 0, 0),
			Vector3.new(0, 1, 0),
			Vector3.new(0, -1, 0),
			Vector3.new(0, 0, 1),
			Vector3.new(0, 0, -1),
		},
		edges = {
			{ 1, 3 }, { 1, 4 }, { 1, 5 }, { 1, 6 },
			{ 2, 3 }, { 2, 4 }, { 2, 5 }, { 2, 6 },
			{ 3, 5 }, { 5, 4 }, { 4, 6 }, { 6, 3 },
		},
	},
	{
		name = "cube",
		vertices = {
			Vector3.new(-1, -1, -1), Vector3.new(1, -1, -1),
			Vector3.new(1, 1, -1), Vector3.new(-1, 1, -1),
			Vector3.new(-1, -1, 1), Vector3.new(1, -1, 1),
			Vector3.new(1, 1, 1), Vector3.new(-1, 1, 1),
		},
		edges = {
			{ 1, 2 }, { 2, 3 }, { 3, 4 }, { 4, 1 },
			{ 5, 6 }, { 6, 7 }, { 7, 8 }, { 8, 5 },
			{ 1, 5 }, { 2, 6 }, { 3, 7 }, { 4, 8 },
		},
	},
	{
		name = "icosahedron",
		vertices = {
			Vector3.new(0, 1, PHI), Vector3.new(0, -1, PHI),
			Vector3.new(0, 1, -PHI), Vector3.new(0, -1, -PHI),
			Vector3.new(1, PHI, 0), Vector3.new(-1, PHI, 0),
			Vector3.new(1, -PHI, 0), Vector3.new(-1, -PHI, 0),
			Vector3.new(PHI, 0, 1), Vector3.new(PHI, 0, -1),
			Vector3.new(-PHI, 0, 1), Vector3.new(-PHI, 0, -1),
		},
		edges = {
			{ 1, 2 }, { 1, 5 }, { 1, 6 }, { 1, 9 }, { 1, 11 },
			{ 2, 7 }, { 2, 8 }, { 2, 9 }, { 2, 11 },
			{ 3, 4 }, { 3, 5 }, { 3, 6 }, { 3, 10 }, { 3, 12 },
			{ 4, 7 }, { 4, 8 }, { 4, 10 }, { 4, 12 },
			{ 5, 6 }, { 5, 9 }, { 5, 10 },
			{ 6, 11 }, { 6, 12 },
			{ 7, 8 }, { 7, 9 }, { 7, 10 },
			{ 8, 11 }, { 8, 12 },
			{ 9, 10 }, { 11, 12 },
		},
	},
}

local MAX_EDGES = 30
local MAX_VERTICES = 12
local FOCAL = 3.4

-- The inner solid, counter-rotating inside the outer one. An octahedron
-- regardless of what is outside it: it reads as a core rather than as a second
-- object competing for attention, and its 12 edges are cheap.
local INNER_SHAPE = 2
local INNER_SCALE = 0.42

-- The strip's height, and the width reserved for the solid at its left end.
-- The solid was originally as tall as the band and read as looming: it crowded
-- the caption and made a 46px strip feel like a panel. It is an indicator, not
-- the subject, so it sits small with air around it.
--
-- Both grew when the solid learned to overshoot. `cell` clips its descendants,
-- so a shape that swells to 1.4x has to have somewhere to swell into, and the
-- extra band height goes to the trace, whose bars are what people try to point
-- at.
Visuals.BAND_HEIGHT = 52
local CELL = 40
local GUTTER = 16

--[[
	The solid's resting radius as a fraction of the cell.

	Tuned against the new cell so resting size is unchanged: 40 x 0.185 is 7.4px
	where 34 x 0.2 was 6.8px. At full overshoot the perspective divide pushes a
	near vertex to roughly 15px, which still clears the cell's 20px half-width.
]]
local BASE_RADIUS = 0.185

--[[
	Spring constants for the scale. Stiff enough that a call reads as a snap
	rather than a swell, damped just under critical so a reply overshoots once
	and settles instead of ringing.
]]
local SPRING = 90
local DAMPING = 14

-- How long the session must go without a command before the solid winds down.
-- Matches the console's idle notice, so the picture and the log agree.
local QUIET_AFTER = 20

-- How many calls the trace remembers. Forty is about a screen's width of bars
-- at two pixels each, and about as far back as anyone reads a trend.
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
	highlight: Frame?,
	readout: TextLabel?,
	caption: TextLabel?,
	edges: { Frame },
	innerEdges: { Frame },
	dots: { Frame },
	bars: { Bar },
	connection: RBXScriptConnection?,

	spin: Vector3,
	angle: Vector3,
	shapeIndex: number,

	energy: number,
	shake: number,
	--[[
		The solid's size, as a spring rather than a value.

		Scale was previously a small function of energy -- a 24% range that
		nobody could see. Driving it as a spring means each event can push it and
		let physics do the rest: a dispatch pulls it in, a reply throws it out
		past its resting size, and it settles on its own.
	]]
	scale: number,
	scaleVelocity: number,
	-- Brightens and fattens the vertices for a moment after a call lands.
	flare: number,
	-- Seconds since anything last ran. Drives the wind-down.
	quiet: number,
	tint: Color3,
	targetTint: Color3,
	baseTint: Color3,
	activeTint: Color3,
	activity: number,
	lastTitle: string?,
	palette: { [string]: Color3 },
}

local runtime: Runtime = {
	band = nil,
	cell = nil,
	trace = nil,
	highlight = nil,
	readout = nil,
	caption = nil,
	edges = {},
	innerEdges = {},
	dots = {},
	bars = {},
	connection = nil,
	spin = Vector3.new(0.18, 0.27, 0.11),
	angle = Vector3.zero,
	shapeIndex = 1,
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
	palette = {},
}

local function rotate(point: Vector3, angle: Vector3): Vector3
	local sinX, cosX = math.sin(angle.X), math.cos(angle.X)
	local sinY, cosY = math.sin(angle.Y), math.cos(angle.Y)
	local sinZ, cosZ = math.sin(angle.Z), math.cos(angle.Z)

	local y1 = point.Y * cosX - point.Z * sinX
	local z1 = point.Y * sinX + point.Z * cosX
	local x2 = point.X * cosY + z1 * sinY
	local z2 = -point.X * sinY + z1 * cosY
	local x3 = x2 * cosZ - y1 * sinZ
	local y3 = x2 * sinZ + y1 * cosZ

	return Vector3.new(x3, y3, z2)
end

--[[
	One edge as a rectangle turned about its midpoint. `Rotation` pivots a
	GuiObject around its centre, which is exactly what a segment needs.
]]
local function drawEdge(frame: Frame, a: Vector2, b: Vector2, thickness: number, color: Color3, transparency: number)
	local delta = b - a
	local length = delta.Magnitude
	if length < 0.5 then
		frame.Visible = false
		return
	end
	frame.Visible = true
	frame.Position = UDim2.fromOffset((a.X + b.X) / 2, (a.Y + b.Y) / 2)
	frame.Size = UDim2.fromOffset(math.ceil(length), thickness)
	frame.Rotation = math.deg(math.atan2(delta.Y, delta.X))
	frame.BackgroundColor3 = color
	frame.BackgroundTransparency = transparency
end

local function step(delta: number)
	local band = runtime.band
	if band == nil or not band.Visible then
		return
	end

	runtime.energy = math.max(0, runtime.energy - delta * 0.9)
	runtime.shake = math.max(0, runtime.shake - delta * 2.4)
	--[[
		Slower than it was. The shape is meant to climb as the session works, and
		at the old rates a call had to arrive every three seconds just to hold the
		octahedron -- so the icosahedron at the top of the list was, in practice,
		unreachable. A burst of four calls now gets there, and it unwinds over
		about ten seconds afterwards.
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
	-- reverse: a strip that keeps spinning at its working rate hours after the
	-- last command claims an activity that is not happening.
	local pace = if runtime.quiet > QUIET_AFTER then 0.25 else 1
	runtime.angle += runtime.spin * delta * (1 + runtime.energy * 2.2) * pace

	--[[
		Where the solid wants to be, before the spring gets a say.

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
		overshoot is the whole point: a reply that pushes the solid past its
		resting size and lets it fall back reads as a thing being struck, where
		easing toward a value reads as a slider being dragged.

		Integrated semi-implicitly -- velocity first, then position from the new
		velocity -- which stays stable at the frame times Studio actually hands us
		rather than only at small ones.
	]]
	local step = math.min(delta, 1 / 30)
	runtime.scaleVelocity += (target - runtime.scale) * SPRING * step
	runtime.scaleVelocity -= runtime.scaleVelocity * DAMPING * step
	runtime.scale += runtime.scaleVelocity * step
	runtime.scale = math.clamp(runtime.scale, 0.55, 1.7)

	local shape = SHAPES[runtime.shapeIndex]
	local centre = Vector2.new(CELL / 2, CELL / 2)
	-- Kept clear of the cell's edge. The perspective divide pushes a near vertex
	-- outward, so sizing to the full half-width clipped the solid against its own
	-- container whenever a corner swung toward the viewer.
	local radius = CELL * BASE_RADIUS * runtime.scale

	-- Wobble the axis rather than the panel: shaking the strip would read as a
	-- glitch, tilting the solid reads as it being knocked.
	local wobble = if runtime.shake > 0
		then Vector3.new(
			math.sin(os.clock() * 37) * runtime.shake * 0.12,
			math.cos(os.clock() * 29) * runtime.shake * 0.12,
			0
		)
		else Vector3.zero

	local projected: { Vector2 } = {}
	local depths: { number } = {}
	for index, vertex in shape.vertices do
		local turned = rotate(vertex, runtime.angle + wobble)
		local scale = FOCAL / (FOCAL - turned.Z)
		projected[index] = centre + Vector2.new(turned.X * scale * radius, turned.Y * scale * radius)
		depths[index] = turned.Z
	end

	for index = 1, MAX_EDGES do
		local frame = runtime.edges[index]
		local edge = shape.edges[index]
		if edge == nil then
			frame.Visible = false
			continue
		end
		local a, b = edge[1], edge[2]
		local depth = math.clamp(((depths[a] + depths[b]) / 2 + 2) / 4, 0, 1)
		drawEdge(
			frame,
			projected[a],
			projected[b],
			math.max(1, math.floor(1 + depth * 1.6 + runtime.flare * 0.8)),
			runtime.tint:Lerp(Color3.new(1, 1, 1), depth * 0.35 + runtime.flare * 0.3),
			math.max(0, 0.84 - depth * 0.74 - runtime.flare * 0.3)
		)
	end

	--[[
		Vertices as points, brighter than the edges they join.

		Wireframes read as flat when every stroke is the same weight. Lighting
		the corners gives the eye something to track as the solid turns, which is
		what makes it read as rotating rather than merely flickering.
	]]
	for index = 1, MAX_VERTICES do
		local dot = runtime.dots[index]
		local point = projected[index]
		if point == nil then
			dot.Visible = false
			continue
		end
		local depth = math.clamp((depths[index] + 2) / 4, 0, 1)
		-- The corners carry the flare. A pulse of light travelling through the
		-- vertices is what makes a completed call land as an event rather than as
		-- a bar quietly appearing somewhere off to the right.
		local size = math.max(2, math.floor(1.5 + depth * 2.5 + runtime.flare * 2.5))
		dot.Visible = true
		dot.Position = UDim2.fromOffset(point.X, point.Y)
		dot.Size = UDim2.fromOffset(size, size)
		dot.BackgroundColor3 = runtime.tint:Lerp(Color3.new(1, 1, 1), 0.25 + depth * 0.5)
		dot.BackgroundTransparency = math.max(0, 0.55 - depth * 0.5 - runtime.flare * 0.45)
	end

	--[[
		A second solid inside the first, turning the other way.

		One rotating outline is a loading spinner. Two, at different rates and
		opposite directions, read as a mechanism -- and the counter-rotation
		makes the outer solid's direction obvious, which a lone wireframe hides
		whenever it passes through a symmetrical angle.
	]]
	local inner = SHAPES[INNER_SHAPE]
	local innerAngle = -runtime.angle * 1.6
	local innerProjected: { Vector2 } = {}
	local innerDepths: { number } = {}
	for index, vertex in inner.vertices do
		local turned = rotate(vertex, innerAngle)
		local scale = FOCAL / (FOCAL - turned.Z)
		innerProjected[index] = centre
			+ Vector2.new(turned.X * scale * radius * INNER_SCALE, turned.Y * scale * radius * INNER_SCALE)
		innerDepths[index] = turned.Z
	end
	for index, frame in runtime.innerEdges do
		local edge = inner.edges[index]
		if edge == nil then
			frame.Visible = false
			continue
		end
		local a, b = edge[1], edge[2]
		local depth = math.clamp(((innerDepths[a] + innerDepths[b]) / 2 + 2) / 4, 0, 1)
		drawEdge(
			frame,
			innerProjected[a],
			innerProjected[b],
			1,
			runtime.tint:Lerp(Color3.new(1, 1, 1), 0.5),
			0.9 - depth * 0.35
		)
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
		-- outside a frame that clips its descendants. The hover has therefore
		never been visible to anyone: the hit targets fired, the readout appeared,
		and the highlight they were meant to explain was off screen every time.
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
	readout.Text = if entry.ok
		then string.format("%s: %d ms", entry.title, math.round(entry.milliseconds))
		else string.format("%s: failed after %d ms", entry.title, math.round(entry.milliseconds))
	readout.TextColor3 = if entry.ok
		then runtime.palette.text or Color3.fromRGB(226, 232, 240)
		else runtime.palette.red or Color3.fromRGB(251, 113, 133)
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
	Records one finished call as a bar on the trace.

	Height is duration and colour is outcome, so a slow call and a failed one are
	distinguishable at a glance -- which is the pair of questions that actually
	get asked of a log this size.
]]
function Visuals.recordCall(milliseconds: number, ok: boolean, title: string)
	runtime.energy = math.min(1.6, runtime.energy + (if ok then 0.3 else 0.8))
	runtime.activity = math.min(1, runtime.activity + 0.34)
	runtime.shapeIndex = math.clamp(1 + math.floor(runtime.activity * (#SHAPES - 0.001)), 1, #SHAPES)
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
		runtime.scaleVelocity += 9
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
	bar.AnchorPoint = Vector2.new(0, 1)
	bar.BorderSizePixel = 0
	bar.Parent = trace

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

	-- Laid out right to left so the newest bar is always at the same edge and
	-- the trace reads as scrolling rather than reshuffling.
	local total = #runtime.bars
	for index, item in runtime.bars do
		local fromRight = total - index
		local height = math.clamp(item.milliseconds / SLOW_MS, 0.06, 1)
		local offset = -(fromRight + 1) * BAR_STRIDE
		item.frame.Position = UDim2.new(1, offset, 1, 0)
		item.frame.Size = UDim2.new(0, 3, height, 0)
		item.frame.BackgroundColor3 = if item.ok
			then runtime.palette.violet or runtime.tint
			else runtime.palette.red or Color3.fromRGB(251, 113, 133)
		item.frame.BackgroundTransparency = 0.15 + (fromRight / TRACE) * 0.6
		-- Centred on the bar, so the column a person points at is the one they get.
		item.hit.Position = UDim2.new(1, offset + 1, 1, 0)
	end

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
		solid contracts while the request is in flight and springs open when the
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
	Winds the solid down, because the session has stopped rather than paused.

	The strip already decays on its own, but decay bottoms out at "idle and
	turning", which looks the same after twenty seconds as after two hours. This
	is the console telling the picture what it has just told the log, so the two
	agree: the shape falls back to a tetrahedron, the spin drops to a quarter
	pace, and the solid draws in.
]]
function Visuals.setQuiet()
	runtime.quiet = QUIET_AFTER + 1
	runtime.activity = 0
	runtime.shapeIndex = 1
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
	Builds the strip. Every edge frame is created here and never again, which is
	what keeps the per-frame path allocation-free.
]]
function Visuals.mount(parent: Instance, palette: { [string]: Color3 })
	runtime.palette = palette

	local band = Instance.new("Frame")
	band.Name = "ActivityBand"
	band.BackgroundColor3 = palette.surface
	band.BorderSizePixel = 0
	band.Visible = false
	band.ClipsDescendants = true
	band.Parent = parent
	runtime.band = band

	local cell = Instance.new("Frame")
	cell.Name = "Solid"
	cell.Position = UDim2.fromOffset(6, (Visuals.BAND_HEIGHT - CELL) / 2)
	cell.Size = UDim2.fromOffset(CELL, CELL)
	cell.BackgroundTransparency = 1
	cell.ClipsDescendants = true
	cell.Parent = band
	runtime.cell = cell

	for index = 1, MAX_EDGES do
		local edge = Instance.new("Frame")
		edge.Name = string.format("Edge%02d", index)
		edge.AnchorPoint = Vector2.new(0.5, 0.5)
		edge.BorderSizePixel = 0
		edge.Visible = false
		edge.Parent = cell
		runtime.edges[index] = edge
	end

	-- A hairline between the solid and the trace, so the strip reads as two
	-- instruments rather than one busy rectangle.
	local divider = Instance.new("Frame")
	divider.Position = UDim2.fromOffset(CELL + GUTTER / 2, 8)
	divider.Size = UDim2.new(0, 1, 1, -16)
	divider.BackgroundColor3 = palette.dim
	divider.BackgroundTransparency = 0.7
	divider.BorderSizePixel = 0
	divider.Parent = band

	for index = 1, MAX_VERTICES do
		local dot = Instance.new("Frame")
		dot.Name = string.format("Vertex%02d", index)
		dot.AnchorPoint = Vector2.new(0.5, 0.5)
		dot.BorderSizePixel = 0
		dot.Visible = false
		dot.Parent = cell
		local round = Instance.new("UICorner")
		round.CornerRadius = UDim.new(1, 0)
		round.Parent = dot
		runtime.dots[index] = dot
	end

	for index = 1, #SHAPES[INNER_SHAPE].edges do
		local edge = Instance.new("Frame")
		edge.Name = string.format("Inner%02d", index)
		edge.AnchorPoint = Vector2.new(0.5, 0.5)
		edge.BorderSizePixel = 0
		edge.Visible = false
		edge.Parent = cell
		runtime.innerEdges[index] = edge
	end

	local caption = Instance.new("TextLabel")
	caption.Position = UDim2.new(0, CELL + GUTTER, 0, 4)
	caption.Size = UDim2.new(1, -CELL - GUTTER - 12, 0, 14)
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
	trace.Position = UDim2.new(0, CELL + GUTTER, 0, 21)
	trace.Size = UDim2.new(1, -CELL - GUTTER - 12, 0, TRACE_HEIGHT)
	trace.BackgroundTransparency = 1
	trace.ClipsDescendants = true
	trace.Parent = band
	runtime.trace = trace

	-- A baseline under the bars, so an empty trace still reads as an instrument
	-- waiting for data rather than as a blank gap.
	local baseline = Instance.new("Frame")
	baseline.AnchorPoint = Vector2.new(0, 1)
	baseline.Position = UDim2.fromScale(0, 1)
	baseline.Size = UDim2.new(1, 0, 0, 1)
	baseline.BackgroundColor3 = palette.dim
	baseline.BackgroundTransparency = 0.75
	baseline.BorderSizePixel = 0
	baseline.Parent = trace

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
	highlight.BackgroundColor3 = palette.text or Color3.fromRGB(226, 232, 240)
	-- Faint enough not to hide the bar it sits behind, solid enough to be seen
	-- at all. The previous value was chosen for a highlight that never rendered,
	-- so it had never been looked at.
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
	readout.BackgroundColor3 = palette.background or Color3.fromRGB(11, 12, 20)
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
end

return Visuals
