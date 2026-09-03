--!strict
--[[
	Blueprint -- the only preset with no perspective.

	An orthographic cube on a drafting grid, with tick marks on two edges. Every
	other theme leans on depth to make the cell interesting; this one refuses it
	on purpose, because a drawing that says "this is a measurement, not a
	picture" is a genuinely different thing to look at, and it is the one preset
	that reads as an engineering instrument rather than as an ornament.

	Orthographic here means the projection divide is simply skipped: the cube
	turns, but a far edge is exactly as long as a near one. That looks wrong for
	a second and then reads as a plan view, which is the effect.

	It is also the lightest preset -- pale lines on navy, no glow, no bloom. On
	a bright monitor in a bright room it is the only one of the eight that is
	comfortable to look at all day.
]]

local Draw = require(script.Parent.Draw)
local Theme = require(script.Parent.Theme)

local Blueprint = {}

Blueprint.id = "blueprint"
Blueprint.label = "Blueprint"
Blueprint.blurb = "Drafting grid"

Blueprint.palette = {
	background = Color3.fromRGB(12, 22, 42),
	surface = Color3.fromRGB(18, 32, 58),
	rule = Color3.fromRGB(126, 196, 240),
	text = Color3.fromRGB(206, 226, 246),
	dim = Color3.fromRGB(86, 122, 164),
	green = Color3.fromRGB(128, 226, 190),
	red = Color3.fromRGB(248, 138, 138),
	amber = Color3.fromRGB(244, 202, 130),
	cyan = Color3.fromRGB(140, 210, 246),
	violet = Color3.fromRGB(170, 176, 240),
}

local CUBE = {
	Vector3.new(-1, -1, -1), Vector3.new(1, -1, -1),
	Vector3.new(1, 1, -1), Vector3.new(-1, 1, -1),
	Vector3.new(-1, -1, 1), Vector3.new(1, -1, 1),
	Vector3.new(1, 1, 1), Vector3.new(-1, 1, 1),
}

local EDGES = {
	{ 1, 2 }, { 2, 3 }, { 3, 4 }, { 4, 1 },
	{ 5, 6 }, { 6, 7 }, { 7, 8 }, { 8, 5 },
	{ 1, 5 }, { 2, 6 }, { 3, 7 }, { 4, 8 },
}

local edges: { Frame } = {}
local corners: { Frame } = {}
local grid: { Frame } = {}
local ticks: { Frame } = {}

--[[
	Builds the grid the drawing sits on.

	Drawn once and never touched again -- it does not react to anything, which
	is the point of graph paper. Kept out of `paint` entirely so the per-frame
	loop stays proportional to the cube.
]]
local function drawGrid(cell: Frame, palette: Theme.Palette, size: number)
	local spacing = 8
	local lines: { Frame } = {}
	for offset = spacing, size - 1, spacing do
		local vertical = Instance.new("Frame")
		vertical.BorderSizePixel = 0
		vertical.BackgroundColor3 = palette.dim
		vertical.BackgroundTransparency = 0.86
		vertical.Size = UDim2.new(0, 1, 1, 0)
		vertical.Position = UDim2.fromOffset(offset, 0)
		vertical.Parent = cell
		table.insert(lines, vertical)

		local horizontal = Instance.new("Frame")
		horizontal.BorderSizePixel = 0
		horizontal.BackgroundColor3 = palette.dim
		horizontal.BackgroundTransparency = 0.86
		horizontal.Size = UDim2.new(1, 0, 0, 1)
		horizontal.Position = UDim2.fromOffset(0, offset)
		horizontal.Parent = cell
		table.insert(lines, horizontal)
	end
	return lines
end

function Blueprint.mount(cell: Frame)
	local size = cell.AbsoluteSize.X
	if size < 8 then
		size = 40
	end
	grid = drawGrid(cell, Blueprint.palette, size)
	ticks = Draw.pool(cell, 8, "Tick", false)
	edges = Draw.pool(cell, #EDGES, "Edge", false)
	corners = Draw.pool(cell, #CUBE, "Corner", false)
end

function Blueprint.unmount()
	edges = {}
	corners = {}
	grid = {}
	ticks = {}
end

function Blueprint.paint(ctx: Theme.Context, _delta: number)
	local radius = ctx.size * 0.2 * ctx.scale
	-- Slower than Lattice and on two axes rather than three. A plan view that
	-- tumbles is not a plan view.
	local angle = Vector3.new(ctx.angle.X * 0.5, ctx.angle.Y * 0.5, 0)

	local projected: { Vector2 } = {}
	for index, vertex in CUBE do
		local turned = Draw.rotate(vertex, angle)
		-- No perspective divide. This is the whole theme.
		projected[index] = ctx.centre + Vector2.new(turned.X * radius, turned.Y * radius)
	end

	for index, edge in EDGES do
		local frame = edges[index]
		if frame == nil then
			continue
		end
		Draw.edge(
			frame,
			projected[edge[1]],
			projected[edge[2]],
			1,
			ctx.tint:Lerp(Color3.new(1, 1, 1), ctx.flare * 0.5),
			math.clamp(0.55 - ctx.flare * 0.35, 0, 1)
		)
	end

	--[[
		Corners as small open squares rather than filled dots -- a draughtsman's
		node. Uniform weight, because in an orthographic drawing no corner is
		nearer than another and shading one would be a lie the rest of the theme
		is built on refusing.
	]]
	for index = 1, #CUBE do
		local frame = corners[index]
		if frame == nil then
			continue
		end
		Draw.dot(frame, projected[index], 2, ctx.palette.cyan, 0.35)
	end

	--[[
		Dimension ticks along the bottom and left, marching with the rotation.

		They carry no data. They are there because a technical drawing has them,
		and their slow travel is what gives an idle Blueprint something moving
		to look at now that nothing is glowing or blooming.
	]]
	for index = 1, 8 do
		local frame = ticks[index]
		if frame == nil then
			continue
		end
		local along = ((index / 8) + ctx.angle.Y * 0.05) % 1
		if index <= 4 then
			local x = along * ctx.size
			Draw.edge(
				frame,
				Vector2.new(x, ctx.size - 4),
				Vector2.new(x, ctx.size - 1),
				1,
				ctx.palette.dim,
				0.5
			)
		else
			local y = along * ctx.size
			Draw.edge(frame, Vector2.new(1, y), Vector2.new(4, y), 1, ctx.palette.dim, 0.5)
		end
	end
end

--[[
	History as a section drawing: hairline columns with a tick at the top of
	each, so a bar's height is marked as well as drawn.
]]
function Blueprint.paintSlot(slot: Theme.Slot, ctx: Theme.Context)
	local frame = slot.frame
	local recency = 1 - slot.age
	local height = math.max(1, math.floor(1 + slot.weight * 21))

	frame.AnchorPoint = Vector2.new(0.5, 1)
	frame.Size = UDim2.fromOffset(1, height)
	frame.Position = UDim2.new(frame.Position.X.Scale, frame.Position.X.Offset, 1, 0)
	frame.BackgroundColor3 = if slot.ok then ctx.palette.cyan else ctx.palette.red
	frame.BackgroundTransparency = math.clamp(0.6 - recency * 0.5, 0, 1)
	frame.Rotation = 0
end

function Blueprint.swatch(frame: Frame, palette: Theme.Palette)
	drawGrid(frame, palette, 24)
	local centre = Vector2.new(20, 12)
	local pool = Draw.pool(frame, #EDGES, "Edge", false)
	local projected: { Vector2 } = {}
	for index, vertex in CUBE do
		local turned = Draw.rotate(vertex, Vector3.new(0.45, 0.6, 0))
		projected[index] = centre + Vector2.new(turned.X * 6, turned.Y * 6)
	end
	for index, edge in EDGES do
		Draw.edge(pool[index], projected[edge[1]], projected[edge[2]], 1, palette.cyan, 0.4)
	end
end

return Blueprint
