--!strict
--[[
	Pendulum -- a pendulum wave, and load as the height of the swing.

	Fourteen bobs swing on strings of slightly different length, so each is a
	little faster than the one beside it. They start together, drift apart into
	a travelling wave, then a standing one, then something close to chaos, and
	come back into line -- the same toy that sits on a desk. Nothing about the
	pattern is scripted; it is only fourteen sines with neighbouring frequencies.

	What the session changes is how hard they swing. Idle, a shallow ripple you
	have to look at to notice; busy, the whole row heaving across the cell. A
	reply brightens and swells the bobs for the third of a second `flare` lasts.

	Time is integrated, not read off the clock, for the reason Void and Aurora
	both learned: a rate that changes multiplied by a clock in the thousands
	reshapes the whole wave in a frame. Accumulating it means a busier session
	swings faster rather than jumping to a different pattern.
]]

local Draw = require(script.Parent.Draw)
local Theme = require(script.Parent.Theme)

local BOBS = 14
-- Seconds for the pattern to come back into line at rest. Bob `n` completes
-- `BASE + n` swings in this time, which is the whole trick.
local WAVE_SECONDS = 36
local BASE = 8
local TAU = math.pi * 2

local Pendulum = {}

Pendulum.id = "pendulum"
Pendulum.label = "Pendulum"
Pendulum.blurb = "Phase wave"

Pendulum.palette = {
	-- Plum-black: the one dark preset that leans toward red rather than blue.
	background = Color3.fromRGB(17, 10, 22),
	surface = Color3.fromRGB(29, 18, 38),
	rule = Color3.fromRGB(238, 108, 196),
	text = Color3.fromRGB(240, 220, 236),
	dim = Color3.fromRGB(156, 120, 160),
	green = Color3.fromRGB(128, 228, 170),
	red = Color3.fromRGB(255, 112, 100),
	amber = Color3.fromRGB(255, 196, 110),
	cyan = Color3.fromRGB(120, 208, 240),
	violet = Color3.fromRGB(238, 108, 196),
}

local bobs: { Frame } = {}
local echoes: { Frame } = {}
local axis: Frame? = nil
local time = 0

-- Magenta at one end of the row, gold at the other, so the order of the bobs is
-- visible in the wave: you can follow one across the pattern by its colour.
local function shade(palette: Theme.Palette, index: number): Color3
	return palette.violet:Lerp(palette.amber, (index - 1) / (BOBS - 1))
end

function Pendulum.mount(cell: Frame)
	local line = Instance.new("Frame")
	line.Name = "Axis"
	line.AnchorPoint = Vector2.new(0, 0.5)
	line.Position = UDim2.fromScale(0, 0.5)
	line.Size = UDim2.new(1, 0, 0, 1)
	line.BorderSizePixel = 0
	line.BackgroundTransparency = 0.88
	line.Parent = cell
	axis = line

	-- The after-image first, so a bob is never cut by its own trail.
	echoes = Draw.pool(cell, BOBS, "Echo", true)
	bobs = Draw.pool(cell, BOBS, "Bob", true)
	time = 0
end

function Pendulum.unmount()
	bobs = {}
	echoes = {}
	axis = nil
	time = 0
end

function Pendulum.paint(ctx: Theme.Context, delta: number)
	-- Past the quiet threshold the session has stopped, and a wave still
	-- heaving at working speed claims an activity that is not happening.
	local pace = if ctx.quiet > 20 then 0.3 else 1
	time += delta * (1 + ctx.energy * 1.2) * pace

	--[[
		The floor keeps an idle panel alive: amplitude driven only by activity
		would flatten the row to a line, and a line is indistinguishable from a
		plugin that has crashed.
	]]
	local amplitude = ctx.size * 0.4 * (0.22 + math.clamp(ctx.activity, 0, 1) * 0.7)
	amplitude *= 1 + (ctx.scale - 1) * 0.25

	local rail = axis
	if rail ~= nil then
		rail.BackgroundColor3 = ctx.palette.dim
	end

	for index = 1, BOBS do
		local phase = TAU * (BASE + index) * time / WAVE_SECONDS
		local swing = math.cos(phase)
		local x = ctx.size * (index / (BOBS + 1))

		-- Fastest through the middle of the swing, where it is brightest: the
		-- brightness is the speed, which is what the eye follows.
		local speed = 1 - math.abs(swing)
		local colour = shade(ctx.palette, index):Lerp(Color3.new(1, 1, 1), ctx.flare * 0.5)

		-- A little behind where it is, and fainter: enough of a smear to show
		-- which way it is going.
		local behind = math.cos(phase - 0.32)
		Draw.dot(
			echoes[index],
			Vector2.new(x, ctx.centre.Y + behind * amplitude),
			math.max(1, math.floor(1.5 + speed)),
			colour,
			math.clamp(0.88 - speed * 0.2, 0, 1)
		)

		Draw.dot(
			bobs[index],
			Vector2.new(x, ctx.centre.Y + swing * amplitude),
			math.max(2, math.floor(2 + speed * 1.5 + ctx.flare * 1.5)),
			colour,
			math.clamp(0.62 - speed * 0.5 - ctx.flare * 0.25, 0, 1)
		)
	end
end

--[[
	History as a run of bobs at the height of each call: a dot per call, high
	when slow. Bars would be a rectangle on a baseline with nothing to do with a
	swinging weight.
]]
function Pendulum.paintSlot(slot: Theme.Slot, ctx: Theme.Context)
	local frame = slot.frame
	local recency = 1 - slot.age

	frame.AnchorPoint = Vector2.new(0.5, 0.5)
	local size = if slot.ok
		then math.max(2, math.floor(2 + slot.weight * 2.5 + recency))
		else math.max(4, math.floor(4 + recency * 2))
	frame.Size = UDim2.fromOffset(size, size)
	frame.Position = UDim2.new(frame.Position.X.Scale, frame.Position.X.Offset, 0.88 - slot.weight * 0.74, 0)
	frame.BackgroundColor3 = if slot.ok
		then ctx.palette.violet:Lerp(ctx.palette.amber, slot.weight)
		else ctx.palette.red
	frame.BackgroundTransparency = math.clamp((if slot.ok then 0.7 else 0.35) - recency * 0.55, 0, 1)
	frame.Rotation = 0
end

function Pendulum.swatch(frame: Frame, palette: Theme.Palette)
	local rail = Instance.new("Frame")
	rail.AnchorPoint = Vector2.new(0, 0.5)
	rail.Position = UDim2.fromScale(0, 0.5)
	rail.Size = UDim2.new(1, 0, 0, 1)
	rail.BorderSizePixel = 0
	rail.BackgroundColor3 = palette.dim
	rail.BackgroundTransparency = 0.88
	rail.Parent = frame

	local pool = Draw.pool(frame, BOBS, "Bob", true)
	for index = 1, BOBS do
		-- A snapshot of the wave partway through its cycle.
		local swing = math.cos(TAU * (BASE + index) * 0.11)
		Draw.dot(
			pool[index],
			Vector2.new(40 * (index / (BOBS + 1)), 12 + swing * 8),
			3,
			shade(palette, index),
			0.2
		)
	end
end

return Pendulum
