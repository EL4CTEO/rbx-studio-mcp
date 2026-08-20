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
local FOCAL = 3.4

-- The strip's height, and the width reserved for the solid at its left end.
Visuals.BAND_HEIGHT = 46
local CELL = 46

-- How many calls the trace remembers. Forty is about a screen's width of bars
-- at two pixels each, and about as far back as anyone reads a trend.
local TRACE = 40

-- Bars are scaled against this, so a normal call is a low bar and a slow one is
-- obvious. Anything past it clamps to full height rather than flattening the
-- rest of the trace into invisibility.
local SLOW_MS = 400

type Bar = {
	frame: Frame,
	milliseconds: number,
	ok: boolean,
}

type Runtime = {
	band: Frame?,
	cell: Frame?,
	trace: Frame?,
	caption: TextLabel?,
	edges: { Frame },
	bars: { Bar },
	connection: RBXScriptConnection?,

	spin: Vector3,
	angle: Vector3,
	shapeIndex: number,

	energy: number,
	shake: number,
	tint: Color3,
	targetTint: Color3,
	activity: number,
	palette: { [string]: Color3 },
}

local runtime: Runtime = {
	band = nil,
	cell = nil,
	trace = nil,
	caption = nil,
	edges = {},
	bars = {},
	connection = nil,
	spin = Vector3.new(0.18, 0.27, 0.11),
	angle = Vector3.zero,
	shapeIndex = 1,
	energy = 0,
	shake = 0,
	tint = Color3.fromRGB(167, 139, 250),
	targetTint = Color3.fromRGB(167, 139, 250),
	activity = 0,
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
	runtime.activity = math.max(0, runtime.activity - delta * 0.35)
	runtime.tint = runtime.tint:Lerp(runtime.targetTint, math.min(1, delta * 4))

	-- Turning faster while busy makes the rate itself readable: a glance says
	-- whether anything is happening without reading a word.
	runtime.angle += runtime.spin * delta * (1 + runtime.energy * 2.2)

	local shape = SHAPES[runtime.shapeIndex]
	local centre = Vector2.new(CELL / 2, CELL / 2)
	local radius = CELL * (0.3 + runtime.energy * 0.04)

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
			math.max(1, math.floor(1 + depth * 1.6)),
			runtime.tint:Lerp(Color3.new(1, 1, 1), depth * 0.35),
			0.84 - depth * 0.74
		)
	end
end

--[[
	Records one finished call as a bar on the trace.

	Height is duration and colour is outcome, so a slow call and a failed one are
	distinguishable at a glance -- which is the pair of questions that actually
	get asked of a log this size.
]]
function Visuals.recordCall(milliseconds: number, ok: boolean)
	runtime.energy = math.min(1.6, runtime.energy + (if ok then 0.3 else 0.8))
	runtime.activity = math.min(1, runtime.activity + 0.25)
	runtime.shapeIndex = math.clamp(1 + math.floor(runtime.activity * (#SHAPES - 0.001)), 1, #SHAPES)
	if not ok then
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
	table.insert(runtime.bars, { frame = bar, milliseconds = milliseconds, ok = ok })

	while #runtime.bars > TRACE do
		runtime.bars[1].frame:Destroy()
		table.remove(runtime.bars, 1)
	end

	-- Laid out right to left so the newest bar is always at the same edge and
	-- the trace reads as scrolling rather than reshuffling.
	local total = #runtime.bars
	for index, entry in runtime.bars do
		local fromRight = total - index
		local height = math.clamp(entry.milliseconds / SLOW_MS, 0.06, 1)
		entry.frame.Position = UDim2.new(1, -(fromRight + 1) * 5, 1, 0)
		entry.frame.Size = UDim2.new(0, 3, height, 0)
		entry.frame.BackgroundColor3 = if entry.ok
			then runtime.palette.violet or runtime.tint
			else runtime.palette.red or Color3.fromRGB(251, 113, 133)
		entry.frame.BackgroundTransparency = 0.15 + (fromRight / TRACE) * 0.6
	end
end

function Visuals.setTint(color: Color3)
	runtime.targetTint = color
end

--[[
	What is running, in the same words the log uses. The motion says something is
	happening; this says what, and neither answers the other's question.
]]
function Visuals.setCaption(title: string)
	if runtime.caption then
		runtime.caption.Text = title
	end
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
	divider.Position = UDim2.fromOffset(CELL, 8)
	divider.Size = UDim2.new(0, 1, 1, -16)
	divider.BackgroundColor3 = palette.dim
	divider.BackgroundTransparency = 0.7
	divider.BorderSizePixel = 0
	divider.Parent = band

	local caption = Instance.new("TextLabel")
	caption.Position = UDim2.new(0, CELL + 12, 0, 5)
	caption.Size = UDim2.new(1, -CELL - 24, 0, 14)
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
	trace.Position = UDim2.new(0, CELL + 12, 0, 21)
	trace.Size = UDim2.new(1, -CELL - 24, 0, 20)
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
end

return Visuals
