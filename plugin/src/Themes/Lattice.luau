--!strict
--[[
	Lattice -- the default.

	A turning wireframe solid with a counter-rotating core, over a bar trace of
	the last forty calls. This is the console's original look, and it stays the
	default because it is the most legible of the eight: hard edges, one accent
	colour, nothing moving that is not reporting something.

	The solid is a real projection rather than a canned loop. Vertices rotate in
	three dimensions and pass through a perspective divide every frame, so near
	edges are brighter and thicker because they genuinely are nearer, and the
	shape climbs a ladder -- tetrahedron, octahedron, cube, icosahedron -- as the
	session gets busier. An idle plugin shows four vertices; a working one shows
	twelve. The shape itself is the load meter.
]]

local Draw = require(script.Parent.Draw)
local Theme = require(script.Parent.Theme)

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

-- The solid's resting radius as a fraction of the cell. At full overshoot the
-- perspective divide pushes a near vertex to roughly 15px, which still clears
-- the cell's half-width.
local BASE_RADIUS = 0.185

local Lattice = {}

Lattice.id = "lattice"
Lattice.label = "Lattice"
Lattice.blurb = "Wireframe solid"

Lattice.palette = {
	-- Violet-tinted near-black. The cast is slight but it stops the panel
	-- reading as the same grey as every other Studio dock.
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

local edges: { Frame } = {}
local innerEdges: { Frame } = {}
local dots: { Frame } = {}

function Lattice.mount(cell: Frame)
	edges = Draw.pool(cell, MAX_EDGES, "Edge", false)
	innerEdges = Draw.pool(cell, #SHAPES[INNER_SHAPE].edges, "Inner", false)
	-- Built after the edges so the lit corners sit over the strokes they join.
	dots = Draw.pool(cell, MAX_VERTICES, "Vertex", true)
end

function Lattice.unmount()
	edges = {}
	innerEdges = {}
	dots = {}
end

function Lattice.paint(ctx: Theme.Context, _delta: number)
	local shapeIndex = math.clamp(1 + math.floor(ctx.activity * (#SHAPES - 0.001)), 1, #SHAPES)
	local shape = SHAPES[shapeIndex]
	local radius = ctx.size * BASE_RADIUS * ctx.scale

	-- Wobble the axis rather than the panel: shaking the strip would read as a
	-- glitch, tilting the solid reads as it being knocked.
	local wobble = if ctx.shake > 0
		then Vector3.new(
			math.sin(ctx.clock * 37) * ctx.shake * 0.12,
			math.cos(ctx.clock * 29) * ctx.shake * 0.12,
			0
		)
		else Vector3.zero

	local projected: { Vector2 } = {}
	local depths: { number } = {}
	for index, vertex in shape.vertices do
		local point, depth = Draw.project(
			Draw.rotate(vertex, ctx.angle + wobble),
			FOCAL,
			radius,
			ctx.centre
		)
		projected[index] = point
		depths[index] = depth
	end

	for index = 1, MAX_EDGES do
		local frame = edges[index]
		if frame == nil then
			continue
		end
		local edge = shape.edges[index]
		if edge == nil then
			frame.Visible = false
			continue
		end
		local a, b = edge[1], edge[2]
		local depth = math.clamp(((depths[a] + depths[b]) / 2 + 2) / 4, 0, 1)
		Draw.edge(
			frame,
			projected[a],
			projected[b],
			math.max(1, math.floor(1 + depth * 1.6 + ctx.flare * 0.8)),
			ctx.tint:Lerp(Color3.new(1, 1, 1), depth * 0.35 + ctx.flare * 0.3),
			math.max(0, 0.84 - depth * 0.74 - ctx.flare * 0.3)
		)
	end

	--[[
		Vertices as points, brighter than the edges they join.

		Wireframes read as flat when every stroke is the same weight. Lighting
		the corners gives the eye something to track as the solid turns, which is
		what makes it read as rotating rather than merely flickering.
	]]
	for index = 1, MAX_VERTICES do
		local dot = dots[index]
		if dot == nil then
			continue
		end
		local point = projected[index]
		if point == nil then
			dot.Visible = false
			continue
		end
		local depth = math.clamp((depths[index] + 2) / 4, 0, 1)
		-- The corners carry the flare. A pulse of light travelling through the
		-- vertices is what makes a completed call land as an event rather than
		-- as a bar quietly appearing somewhere off to the right.
		Draw.dot(
			dot,
			point,
			math.max(2, math.floor(1.5 + depth * 2.5 + ctx.flare * 2.5)),
			ctx.tint:Lerp(Color3.new(1, 1, 1), 0.25 + depth * 0.5),
			math.max(0, 0.55 - depth * 0.5 - ctx.flare * 0.45)
		)
	end

	--[[
		A second solid inside the first, turning the other way.

		One rotating outline is a loading spinner. Two, at different rates and
		opposite directions, read as a mechanism -- and the counter-rotation
		makes the outer solid's direction obvious, which a lone wireframe hides
		whenever it passes through a symmetrical angle.
	]]
	local inner = SHAPES[INNER_SHAPE]
	local innerAngle = -ctx.angle * 1.6
	local innerProjected: { Vector2 } = {}
	local innerDepths: { number } = {}
	for index, vertex in inner.vertices do
		local point, depth = Draw.project(
			Draw.rotate(vertex, innerAngle),
			FOCAL,
			radius * INNER_SCALE,
			ctx.centre
		)
		innerProjected[index] = point
		innerDepths[index] = depth
	end
	for index, frame in innerEdges do
		local edge = inner.edges[index]
		if edge == nil then
			frame.Visible = false
			continue
		end
		local a, b = edge[1], edge[2]
		local depth = math.clamp(((innerDepths[a] + innerDepths[b]) / 2 + 2) / 4, 0, 1)
		Draw.edge(
			frame,
			innerProjected[a],
			innerProjected[b],
			1,
			ctx.tint:Lerp(Color3.new(1, 1, 1), 0.5),
			0.9 - depth * 0.35
		)
	end
end

--[[
	A still cube, which is the shape people recognise the console by, drawn at a
	three-quarter angle so all three dimensions are visible at once.
]]
function Lattice.swatch(frame: Frame, palette: Theme.Palette)
	local centre = Vector2.new(20, 12)
	local pool = Draw.pool(frame, 12, "Edge", false)
	local shape = SHAPES[3]
	local angle = Vector3.new(0.5, 0.7, 0)

	local projected: { Vector2 } = {}
	local depths: { number } = {}
	for index, vertex in shape.vertices do
		local point, depth = Draw.project(Draw.rotate(vertex, angle), FOCAL, 5.5, centre)
		projected[index] = point
		depths[index] = depth
	end
	for index, edge in shape.edges do
		local a, b = edge[1], edge[2]
		local depth = math.clamp(((depths[a] + depths[b]) / 2 + 2) / 4, 0, 1)
		Draw.edge(
			pool[index],
			projected[a],
			projected[b],
			1,
			palette.violet:Lerp(Color3.new(1, 1, 1), depth * 0.4),
			0.75 - depth * 0.6
		)
	end
end

return Lattice
