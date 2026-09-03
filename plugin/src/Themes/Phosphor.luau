--!strict
--[[
	Phosphor -- a CRT oscilloscope.

	A Lissajous figure traced by a moving beam, with the phosphor decaying
	behind it. The head is white-hot, the tail fades to green over about forty
	samples, and the whole cell sits under scanlines.

	It deliberately does NOT reuse the wireframe. Drawing Lattice's solid in
	green with a trail would be the obvious CRT gag and would leave two of the
	eight presets doing the same thing in different colours. A beam tracing a
	curve is what a scope actually does, and it gives the theme its own answer
	to "is this alive": the figure's shape changes with the session, because the
	frequency ratio is driven by activity. Idle it draws a lazy ellipse; busy it
	knots into a rose.

	The sample buffer is a ring rather than a growing list. The head advances,
	the sample under it is overwritten, and age is computed from the distance
	back to the head -- so nothing is allocated or shifted per frame.
]]

local Draw = require(script.Parent.Draw)
local Theme = require(script.Parent.Theme)

local SAMPLES = 46
-- Samples per second the beam advances. Fast enough that the figure is a curve
-- rather than a dotted line, slow enough that the decay is visible.
local RATE = 60

local Phosphor = {}

Phosphor.id = "phosphor"
Phosphor.label = "Phosphor"
Phosphor.blurb = "CRT scope beam"

Phosphor.palette = {
	background = Color3.fromRGB(4, 8, 5),
	surface = Color3.fromRGB(9, 16, 11),
	rule = Color3.fromRGB(86, 232, 122),
	text = Color3.fromRGB(178, 236, 190),
	dim = Color3.fromRGB(70, 112, 82),
	green = Color3.fromRGB(86, 240, 128),
	red = Color3.fromRGB(248, 118, 96),
	amber = Color3.fromRGB(240, 208, 106),
	cyan = Color3.fromRGB(122, 234, 208),
	violet = Color3.fromRGB(150, 226, 150),
}

local dots: { Frame } = {}
local scanlines: { Frame } = {}
local samples: { Vector2 } = {}
local head = 0
local accumulator = 0

function Phosphor.mount(cell: Frame)
	dots = Draw.pool(cell, SAMPLES, "Sample", true)

	scanlines = {}
	samples = {}
	head = 0
	accumulator = 0

	--[[
		Scanlines last, so they lie OVER the beam.

		Underneath they were invisible -- the beam is the brightest thing in the
		cell and simply covered them. A CRT's lines cross what it is drawing;
		that is what makes it read as a screen rather than as a dark background
		with stripes on it.
	]]
	for index = 1, 10 do
		local line = Instance.new("Frame")
		line.Name = string.format("Scan%02d", index)
		line.BorderSizePixel = 0
		line.BackgroundColor3 = Color3.new(0, 0, 0)
		line.BackgroundTransparency = 0.78
		line.Size = UDim2.new(1, 0, 0, 1)
		line.Position = UDim2.fromOffset(0, index * 4)
		line.ZIndex = 4
		line.Parent = cell
		scanlines[index] = line
	end
end

function Phosphor.unmount()
	dots = {}
	scanlines = {}
	samples = {}
end

function Phosphor.paint(ctx: Theme.Context, delta: number)
	local radius = ctx.size * 0.33 * ctx.scale

	--[[
		The figure's ratio, from activity.

		A Lissajous curve closes when its two frequencies are a simple ratio, so
		holding X at 2 and sliding Y between 3 and roughly 5 walks it from an
		open ellipse through a figure-eight into a knot. The session's load
		therefore changes the SHAPE, not just the speed -- which is the same
		trick Lattice plays with its solids, done continuously.
	]]
	local ratio = 3 + math.clamp(ctx.activity, 0, 1) * 2.1

	-- Fixed-step sampling. Advancing one sample per frame would make the trail's
	-- length depend on Studio's frame rate, so the beam would visibly speed up
	-- whenever the editor was idle.
	accumulator += math.min(delta, 1 / 15)
	local advance = math.floor(accumulator * RATE)
	if advance > 0 then
		accumulator -= advance / RATE
		for _ = 1, math.min(advance, SAMPLES) do
			head += 1
			local t = head / RATE
			samples[(head % SAMPLES) + 1] = Vector2.new(
				math.sin(t * 2) * radius,
				math.sin(t * ratio + ctx.clock * 0.15) * radius
			)
		end
	end

	for index = 1, SAMPLES do
		local frame = dots[index]
		local point = samples[index]
		if frame == nil then
			continue
		end
		if point == nil then
			frame.Visible = false
			continue
		end

		--[[
			How far back from the head this sample is, 0 (newest) to 1 (about to
			be overwritten). The modulo is what lets the ring buffer stand in for
			an ordered trail without moving anything.
		]]
		local back = (head - (index - 1)) % SAMPLES
		local age = back / SAMPLES

		-- Squared, so the head is a bright point with a long dim tail rather
		-- than an evenly grey worm. Phosphor decays fast at first.
		local glow = (1 - age) * (1 - age)

		Draw.dot(
			frame,
			ctx.centre + point,
			math.max(1, math.floor(1 + glow * 2 + ctx.flare * 1.5)),
			ctx.palette.green:Lerp(Color3.new(1, 1, 1), glow * 0.85),
			math.clamp(0.94 - glow * 0.9 - ctx.flare * 0.2, 0, 1)
		)
	end
end

--[[
	History as scope columns: hard-edged, one pixel wide, no rounding. The trace
	is the one part of a scope's screen that is supposed to look like a chart.
]]
function Phosphor.paintSlot(slot: Theme.Slot, ctx: Theme.Context)
	local frame = slot.frame
	local recency = 1 - slot.age
	local height = math.max(1, math.floor(1 + slot.weight * 22))

	frame.AnchorPoint = Vector2.new(0.5, 1)
	frame.Size = UDim2.fromOffset(2, height)
	frame.Position = UDim2.new(frame.Position.X.Scale, frame.Position.X.Offset, 1, 0)
	frame.BackgroundColor3 = if slot.ok
		then ctx.palette.green:Lerp(Color3.new(1, 1, 1), recency * 0.4)
		else ctx.palette.red
	frame.BackgroundTransparency = math.clamp(0.7 - recency * 0.65, 0, 1)
	frame.Rotation = 0
end

function Phosphor.swatch(frame: Frame, palette: Theme.Palette)
	local centre = Vector2.new(20, 12)
	local pool = Draw.pool(frame, 30, "Sample", true)
	for index = 1, 30 do
		local t = index / 6
		local glow = index / 30
		Draw.dot(
			pool[index],
			centre + Vector2.new(math.sin(t * 2) * 15, math.sin(t * 3) * 9),
			1 + math.floor(glow * 2),
			palette.green:Lerp(Color3.new(1, 1, 1), glow * 0.8),
			0.85 - glow * 0.8
		)
	end
	for index = 1, 6 do
		local line = Instance.new("Frame")
		line.BorderSizePixel = 0
		line.BackgroundColor3 = Color3.new(0, 0, 0)
		line.BackgroundTransparency = 0.75
		line.Size = UDim2.new(1, 0, 0, 1)
		line.Position = UDim2.fromOffset(0, index * 4)
		line.ZIndex = 4
		line.Parent = frame
	end
end

return Phosphor
