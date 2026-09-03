--!strict
--[[
	Void -- an accretion disc, and the most literal of the eight.

	A dark core with matter spiralling into it. Orbital speed rises as radius
	falls, the way it actually does, so the inner ring visibly outruns the outer
	one and the disc shears instead of turning as a plate. That single detail is
	what separates it from a spinning ring of dots.

	The trace is where the metaphor pays for itself. A slow call is drawn
	stretched and shifted red, so latency is not a height you have to compare
	against its neighbours -- it is a thing visibly being pulled apart. A
	forty-bar chart makes you measure; this makes you look.

	It is also the least legible preset in the set, and that is a real trade
	rather than an oversight: the disc is dark, the motion is continuous, and
	there is no baseline to read heights against. It is here because someone
	will want it, not because it is the best instrument.
]]

local Draw = require(script.Parent.Draw)
local Theme = require(script.Parent.Theme)

local MOTES = 34
local RINGS = 4

--[[
	How far the disc reaches, and how flat it is seen.

	The reach was already near the cell's limit; the disc read as small because
	it was a HAIRLINE -- flattened to 0.3, four rings of it occupied about 10px
	of vertical space in a 40px cell, so a wide thin smear was doing the work of
	a picture. Opening the viewing angle to 0.48 nearly doubles the height for
	no extra width, which is the axis that actually had room spare.
]]
local DISC_SPREAD = 0.54
local FLATTEN = 0.48

-- The disc barely breathes: same reasoning as Orbit. A ring sized to fill the
-- cell at rest would be cut off by the clip at every overshoot, so the CORE
-- carries the spring and the matter around it holds its radius.
local DISC_BREATH = 0.1

local Void = {}

Void.id = "void"
Void.label = "Void"
Void.blurb = "Accretion disc"

Void.palette = {
	background = Color3.fromRGB(6, 5, 10),
	surface = Color3.fromRGB(13, 11, 20),
	rule = Color3.fromRGB(168, 108, 236),
	text = Color3.fromRGB(206, 200, 222),
	dim = Color3.fromRGB(84, 78, 102),
	green = Color3.fromRGB(120, 220, 176),
	red = Color3.fromRGB(252, 96, 118),
	amber = Color3.fromRGB(250, 174, 108),
	cyan = Color3.fromRGB(126, 202, 244),
	violet = Color3.fromRGB(178, 122, 246),
}

local motes: { Frame } = {}
local core: Frame? = nil
local shadow: Frame? = nil

--[[
	Accumulated orbital phase, in the disc's own time.

	This is the fix for the one thing that made this preset unwatchable, and it
	is worth stating plainly because the broken version looked reasonable.

	The angle used to be `ctx.clock * speed * (1 + ctx.energy)` -- absolute wall
	time multiplied by a rate that CHANGES. Multiplying a large clock by a moving
	rate does not speed the disc up; it teleports every mote. `os.clock()` is
	seconds since Studio started, so after an hour it is about 3600, and energy
	falls by `delta * 0.9` every frame after a command: at 60fps that is 0.015 of
	rate change per frame, which at ring one moved the phase by roughly 29
	radians -- almost five whole revolutions -- BETWEEN CONSECUTIVE FRAMES. For
	the second or two after every call the disc was not orbiting at all, it was
	strobing, and it got worse the longer Studio had been open, which is why it
	looked fine when it was written.

	Integrating the rate instead makes speed a speed. A change in energy now
	changes how fast the phase grows, and the phase itself stays continuous, so
	the disc accelerates rather than jumping.
]]
local phase = 0

--[[
	Which ring a mote belongs to, and where it sits on that ring.

	Distributed by index rather than randomly so every ring gets a similar share
	-- a random assignment leaves visible gaps at forty motes, and a gap in a
	disc reads as a rendering fault rather than as structure.
]]
local function ringOf(index: number): (number, number)
	local ring = 1 + (index - 1) % RINGS
	local along = Draw.hash(index, 41)
	return ring, along
end

function Void.mount(cell: Frame)
	local dark = Instance.new("Frame")
	dark.Name = "Shadow"
	dark.AnchorPoint = Vector2.new(0.5, 0.5)
	dark.BorderSizePixel = 0
	dark.Parent = cell
	local darkCorner = Instance.new("UICorner")
	darkCorner.CornerRadius = UDim.new(1, 0)
	darkCorner.Parent = dark
	shadow = dark

	motes = Draw.pool(cell, MOTES, "Mote", true)

	--[[
		The core is built LAST so it draws over the motes.

		That is the entire illusion: matter passing behind the core has to
		disappear behind something, and with the core underneath, motes crossed
		it and the disc read as a flat ring with a dot in the middle.
	]]
	local sphere = Instance.new("Frame")
	sphere.Name = "Core"
	sphere.AnchorPoint = Vector2.new(0.5, 0.5)
	sphere.BorderSizePixel = 0
	sphere.Parent = cell
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(1, 0)
	corner.Parent = sphere
	core = sphere
	phase = 0
end

function Void.unmount()
	motes = {}
	core = nil
	shadow = nil
	phase = 0
end

function Void.paint(ctx: Theme.Context, delta: number)
	--[[
		Advance the disc by this frame's worth of turning.

		`pace` matches the rest of the set: past the quiet threshold the session
		has stopped, and a disc still spiralling at working speed claims an
		activity that is not happening. Applied to the RATE, so crossing the
		threshold slows the disc instead of jumping it.
	]]
	local pace = if ctx.quiet > 20 then 0.25 else 1
	phase += delta * (1 + ctx.energy) * pace

	local breath = (1 - DISC_BREATH) + ctx.scale * DISC_BREATH
	local scale = ctx.size * DISC_SPREAD * breath
	-- Lensing: a failure warps the disc rather than shaking the panel, which on
	-- a strip this small would read as a glitch.
	local warp = 1 + ctx.shake * 0.28

	for index = 1, MOTES do
		local frame = motes[index]
		if frame == nil then
			continue
		end
		local ring, along = ringOf(index)
		local radius = (0.3 + ring * 0.14) * scale * warp

		--[[
			Keplerian, near enough: inner orbits are faster. Anything uniform
			turns the disc as a rigid plate, and the shear is what says the
			thing at the centre is pulling rather than spinning.
		]]
		local speed = 2.4 / (0.3 + ring * 0.14)
		local turn = along * math.pi * 2 + phase * speed * 0.1

		-- Flattened on Y: a disc seen nearly edge-on, not a set of circles.
		local x = math.cos(turn) * radius
		local y = math.sin(turn) * radius * FLATTEN
		-- Depth from the same angle, so a mote on the far side dims.
		local near = (math.sin(turn) + 1) / 2

		local heat = 1 - ring / RINGS
		Draw.dot(
			frame,
			ctx.centre + Vector2.new(x, y),
			math.max(2, math.floor(1.5 + heat * 2.5 + ctx.flare * 1.5)),
			ctx.palette.violet
				:Lerp(ctx.palette.amber, heat)
				:Lerp(Color3.new(1, 1, 1), ctx.flare * 0.4),
			math.clamp(0.82 - near * 0.45 - heat * 0.2 - ctx.flare * 0.25, 0, 1)
		)
	end

	local halo = shadow
	if halo ~= nil then
		Draw.dot(
			halo,
			ctx.centre,
			math.max(12, math.floor(16 * ctx.scale + ctx.energy * 5)),
			ctx.palette.violet,
			0.88
		)
	end

	local sphere = core
	if sphere ~= nil then
		-- The core does not brighten on a reply. Everything around it does, and
		-- the hole staying black through a flare is what sells it as a hole.
		Draw.dot(
			sphere,
			ctx.centre,
			math.max(6, math.floor(9 * ctx.scale)),
			ctx.palette.background,
			0
		)
	end
end

--[[
	History falling inward.

	A slow call is drawn taller AND redder AND further from the baseline, so
	three channels carry the same fact. That is redundant on purpose: the disc
	behind it is busy, and one channel would be lost in it.
]]
function Void.paintSlot(slot: Theme.Slot, ctx: Theme.Context)
	local frame = slot.frame
	local recency = 1 - slot.age
	local height = math.max(2, math.floor(2 + slot.weight * 18))

	frame.AnchorPoint = Vector2.new(0.5, 1)
	frame.Size = UDim2.fromOffset(2, height)
	-- Lifted off the baseline in proportion to how slow it was: the bar has
	-- started to fall in.
	frame.Position = UDim2.new(
		frame.Position.X.Scale,
		frame.Position.X.Offset,
		1,
		-math.floor(slot.weight * 4)
	)
	frame.BackgroundColor3 = if slot.ok
		then ctx.palette.amber:Lerp(ctx.palette.red, slot.weight)
		else ctx.palette.red
	frame.BackgroundTransparency = math.clamp(0.7 - recency * 0.6, 0, 1)
	frame.Rotation = 0
end

function Void.swatch(frame: Frame, palette: Theme.Palette)
	local centre = Vector2.new(20, 12)
	local pool = Draw.pool(frame, 26, "Mote", true)
	for index = 1, 24 do
		local ring = 1 + (index - 1) % 3
		local turn = Draw.hash(index, 43) * math.pi * 2
		local radius = 5 + ring * 3.4
		Draw.dot(
			pool[index],
			centre + Vector2.new(math.cos(turn) * radius, math.sin(turn) * radius * FLATTEN),
			1 + math.floor((3 - ring) * 0.7),
			palette.violet:Lerp(palette.amber, 1 - ring / 3),
			0.45
		)
	end
	Draw.dot(pool[25], centre, 9, palette.background, 0)
end

return Void
