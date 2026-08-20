--!strict
--[[
	The console's visual mode: a wireframe solid, turning, that reacts to traffic.

	Watching an agent work is mostly waiting. The log answers "what is it doing"
	precisely and answers "is it still alive" badly -- a stalled session and a
	thinking one produce the same still screen. This gives the panel a pulse:
	something always moving, and moving *differently* when something happens.

	It is a real renderer, not a looping animation. Vertices are rotated in three
	dimensions and projected through a perspective divide every frame, so the
	depth is genuine -- near edges are brighter and thicker than far ones because
	they are actually nearer, and the solid reads as solid.

	Drawing uses one Frame per edge, rotated about its midpoint. Roblox has no
	line primitive and no immediate-mode canvas, so a segment is a thin rectangle
	turned to the right angle. Frames are pooled to the largest shape's edge
	count and reused across shape changes, because allocating Instances inside a
	per-frame loop is how a decorative panel becomes a performance complaint.

	Everything it does is driven by what the session is doing: the palette
	follows connection state, each command lands as a pulse, and an error throws
	the solid off its axis. Idle is calm and slow on purpose -- motion that never
	varies stops being information and becomes wallpaper.
]]

local RunService = game:GetService("RunService")

local Visuals = {}

-- Golden ratio, for the icosahedron's vertices.
local PHI = (1 + math.sqrt(5)) / 2

type Shape = {
	name: string,
	vertices: { Vector3 },
	edges: { { number } },
}

--[[
	Four Platonic-ish solids, ordered by how busy they look. The session moves up
	this list as it does more work, so the panel's complexity tracks the
	session's -- an idle plugin shows a tetrahedron, a working one an
	icosahedron.
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
			Vector3.new(-1, -1, -1),
			Vector3.new(1, -1, -1),
			Vector3.new(1, 1, -1),
			Vector3.new(-1, 1, -1),
			Vector3.new(-1, -1, 1),
			Vector3.new(1, -1, 1),
			Vector3.new(1, 1, 1),
			Vector3.new(-1, 1, 1),
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

-- Perspective strength. Large enough that the far side stays legible, small
-- enough that turning reads as depth rather than as a flat spin.
local FOCAL = 3.4

type Pulse = {
	frame: Frame,
	age: number,
	life: number,
	color: Color3,
}

type Runtime = {
	canvas: Frame?,
	caption: TextLabel?,
	subcaption: TextLabel?,
	edges: { Frame },
	pulses: { Pulse },
	connection: RBXScriptConnection?,

	spin: Vector3,
	angle: Vector3,
	shapeIndex: number,
	morph: number,

	-- Eased toward on activity and decaying back, so a burst of calls swells the
	-- solid and it settles afterwards instead of snapping.
	energy: number,
	shake: number,
	tint: Color3,
	targetTint: Color3,
	activity: number,
}

local runtime: Runtime = {
	canvas = nil,
	caption = nil,
	subcaption = nil,
	edges = {},
	pulses = {},
	connection = nil,
	spin = Vector3.new(0.18, 0.27, 0.11),
	angle = Vector3.zero,
	shapeIndex = 1,
	morph = 1,
	energy = 0,
	shake = 0,
	tint = Color3.fromRGB(167, 139, 250),
	targetTint = Color3.fromRGB(167, 139, 250),
	activity = 0,
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
	Draws one edge as a rectangle turned about its midpoint.

	`Rotation` on a GuiObject pivots around its centre, which is exactly what a
	line segment needs: place the frame at the midpoint, make it as long as the
	distance, and turn it to the bearing.
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
	local canvas = runtime.canvas
	if canvas == nil or not canvas.Visible then
		return
	end

	local size = canvas.AbsoluteSize
	if size.X < 8 or size.Y < 8 then
		return
	end

	-- Decay first, so a burst that arrived this frame is still at full strength
	-- when it is drawn.
	runtime.energy = math.max(0, runtime.energy - delta * 0.9)
	runtime.shake = math.max(0, runtime.shake - delta * 2.4)
	runtime.activity = math.max(0, runtime.activity - delta * 0.35)
	runtime.tint = runtime.tint:Lerp(runtime.targetTint, math.min(1, delta * 4))

	-- Faster while busy: the rate itself carries information, so a glance says
	-- whether anything is happening without reading a word.
	local rate = 1 + runtime.energy * 2.2
	runtime.angle += runtime.spin * delta * rate

	local shape = SHAPES[runtime.shapeIndex]
	local centre = Vector2.new(size.X / 2, size.Y / 2)
	local radius = math.min(size.X, size.Y) * (0.3 + runtime.energy * 0.05)

	-- A wobble on the axis rather than on the whole panel. Shaking the canvas
	-- would read as a glitch; tilting the object reads as it being knocked.
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
		-- Depth runs about -1.9..1.9 for these solids; normalising it to 0..1
		-- gives the near/far weighting.
		local depth = math.clamp(((depths[a] + depths[b]) / 2 + 2) / 4, 0, 1)
		local thickness = math.max(1, math.floor(1 + depth * 2 + runtime.energy))
		local transparency = 0.82 - depth * 0.72

		local color = runtime.tint:Lerp(Color3.new(1, 1, 1), depth * 0.35)
		drawEdge(frame, projected[a], projected[b], thickness, color, transparency)
	end

	-- Pulses: rings that expand and fade, one per command.
	for index = #runtime.pulses, 1, -1 do
		local pulse = runtime.pulses[index]
		pulse.age += delta
		local progress = pulse.age / pulse.life
		if progress >= 1 then
			pulse.frame:Destroy()
			table.remove(runtime.pulses, index)
			continue
		end
		-- Eased out, so it leaves quickly and lingers wide rather than crawling
		-- outward at a constant rate.
		local eased = 1 - (1 - progress) * (1 - progress)
		local span = radius * (0.5 + eased * 2.6)
		pulse.frame.Size = UDim2.fromOffset(span * 2, span * 2)
		pulse.frame.Position = UDim2.fromOffset(centre.X, centre.Y)
		local stroke = pulse.frame:FindFirstChildWhichIsA("UIStroke")
		if stroke then
			stroke.Transparency = 0.25 + eased * 0.75
			stroke.Color = pulse.color
		end
	end
end

--[[
	A ring leaving the centre. Colour carries the outcome, so a failure is
	visible from across the room without reading the log.
]]
function Visuals.pulse(color: Color3, strength: number)
	local canvas = runtime.canvas
	if canvas == nil or not canvas.Visible then
		return
	end

	runtime.energy = math.min(1.6, runtime.energy + strength)
	runtime.activity = math.min(1, runtime.activity + 0.25)

	-- Complexity follows how much the session is doing.
	local target = 1 + math.floor(runtime.activity * (#SHAPES - 0.001))
	runtime.shapeIndex = math.clamp(target, 1, #SHAPES)

	local ring = Instance.new("Frame")
	ring.AnchorPoint = Vector2.new(0.5, 0.5)
	ring.BackgroundTransparency = 1
	ring.BorderSizePixel = 0
	ring.Size = UDim2.fromOffset(4, 4)
	ring.ZIndex = 0
	ring.Parent = canvas

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(1, 0)
	corner.Parent = ring

	local stroke = Instance.new("UIStroke")
	stroke.Color = color
	stroke.Thickness = 1
	stroke.Transparency = 0.25
	stroke.Parent = ring

	table.insert(runtime.pulses, { frame = ring, age = 0, life = 1.1, color = color })
end

--[[
	Knocks the solid off its axis. Reserved for failures: it is the one motion
	that looks wrong on purpose.
]]
function Visuals.jolt()
	runtime.shake = 1
end

function Visuals.setTint(color: Color3)
	runtime.targetTint = color
end

--[[
	What the panel is doing right now, in words, under the solid.

	The animation says something is happening; this says what. Together they
	cover the two questions someone watching actually has, and neither answers
	the other's.
]]
function Visuals.setCaption(title: string, detail: string?)
	if runtime.caption then
		runtime.caption.Text = title
	end
	if runtime.subcaption then
		runtime.subcaption.Text = detail or ""
	end
end

function Visuals.setVisible(visible: boolean)
	local canvas = runtime.canvas
	if canvas == nil then
		return
	end
	canvas.Visible = visible

	-- The render loop is only connected while the panel is on screen. A hidden
	-- widget that keeps projecting geometry every frame is a battery complaint
	-- waiting to happen.
	if visible and runtime.connection == nil then
		runtime.connection = RunService.Heartbeat:Connect(step)
	elseif not visible and runtime.connection ~= nil then
		runtime.connection:Disconnect()
		runtime.connection = nil
		for _, pulse in runtime.pulses do
			pulse.frame:Destroy()
		end
		table.clear(runtime.pulses)
	end
end

function Visuals.isVisible(): boolean
	local canvas = runtime.canvas
	return canvas ~= nil and canvas.Visible
end

--[[
	Builds the canvas. Edge frames are all created here and never again, which is
	what keeps the per-frame path free of allocation.
]]
function Visuals.mount(parent: Instance, palette: { [string]: Color3 })
	local canvas = Instance.new("Frame")
	canvas.Name = "Visuals"
	canvas.Size = UDim2.fromScale(1, 1)
	canvas.BackgroundColor3 = palette.background
	canvas.BackgroundTransparency = 0.08
	canvas.BorderSizePixel = 0
	canvas.Visible = false
	canvas.ClipsDescendants = true
	canvas.ZIndex = 5
	canvas.Parent = parent
	runtime.canvas = canvas

	for index = 1, MAX_EDGES do
		local edge = Instance.new("Frame")
		edge.Name = string.format("Edge%02d", index)
		edge.AnchorPoint = Vector2.new(0.5, 0.5)
		edge.BorderSizePixel = 0
		edge.Visible = false
		edge.ZIndex = 6
		edge.Parent = canvas
		runtime.edges[index] = edge
	end

	local caption = Instance.new("TextLabel")
	caption.AnchorPoint = Vector2.new(0.5, 1)
	caption.Position = UDim2.new(0.5, 0, 1, -26)
	caption.Size = UDim2.new(1, -24, 0, 16)
	caption.BackgroundTransparency = 1
	caption.Font = Enum.Font.Code
	caption.TextSize = 12
	caption.TextColor3 = palette.text
	caption.TextTruncate = Enum.TextTruncate.AtEnd
	caption.Text = "idle"
	caption.ZIndex = 7
	caption.Parent = canvas
	runtime.caption = caption

	local subcaption = Instance.new("TextLabel")
	subcaption.AnchorPoint = Vector2.new(0.5, 1)
	subcaption.Position = UDim2.new(0.5, 0, 1, -10)
	subcaption.Size = UDim2.new(1, -24, 0, 14)
	subcaption.BackgroundTransparency = 1
	subcaption.Font = Enum.Font.Code
	subcaption.TextSize = 11
	subcaption.TextColor3 = palette.dim
	subcaption.TextTruncate = Enum.TextTruncate.AtEnd
	subcaption.Text = ""
	subcaption.ZIndex = 7
	subcaption.Parent = canvas
	runtime.subcaption = subcaption
end

return Visuals
