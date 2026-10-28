--!strict
--[[
	Electro -- every call is a strike.

	A charged core inside a containment ring, with arcs of lightning jumping
	from it to the ring. The number of live arcs is the session's activity, and
	how often they re-strike is its energy: an idle panel holds one slow,
	wandering arc; a burst of calls fills the ring with fast crackle. A reply
	lands as a bright discharge that flashes the ring, and a failure turns the
	arcs red for as long as the shake lasts.

	The bolt shapes are seeded per strike, not per frame. Re-rolling every frame
	makes lightning boil into noise; holding a shape between strikes and adding
	only a small crackle on top is what makes each one read as a discharge.
]]

local Draw = require(script.Parent.Draw)
local Theme = require(script.Parent.Theme)

local BOLTS = 5
local SEGMENTS = 6
local TAU = math.pi * 2
-- Seconds between strikes for one arc, calm and flat out.
local STRIKE_SLOW = 0.42
local STRIKE_FAST = 0.07

local Electro = {}

Electro.id = "electro"
Electro.label = "Electro"
Electro.blurb = "Charged core, live arcs"

Electro.palette = {
	-- Deep indigo, the dark around a spark.
	background = Color3.fromRGB(7, 8, 22),
	surface = Color3.fromRGB(12, 14, 34),
	rule = Color3.fromRGB(92, 196, 255),
	text = Color3.fromRGB(216, 228, 255),
	dim = Color3.fromRGB(112, 126, 172),
	green = Color3.fromRGB(112, 240, 184),
	red = Color3.fromRGB(255, 98, 130),
	amber = Color3.fromRGB(255, 206, 96),
	cyan = Color3.fromRGB(124, 236, 255),
	violet = Color3.fromRGB(96, 186, 255),
}

local WHITE = Color3.new(1, 1, 1)

local segments: { { Frame } } = {}
local glows: { { Frame } } = {}
local ring: Frame? = nil
local ringStroke: UIStroke? = nil
local halo: Frame? = nil
local core: Frame? = nil

-- Per arc: the strike it is on, seconds until the next, its interval, and the
-- bearing it is drifting around the ring.
local seed: { number } = {}
local timer: { number } = {}
local interval: { number } = {}
local bearing: { number } = {}
-- The ring's flash, raised by a reply and decaying on its own.
local flash = 0
local flareHigh = false

local function circle(parent: Instance, name: string): (Frame, UIStroke)
	local frame = Instance.new("Frame")
	frame.Name = name
	frame.AnchorPoint = Vector2.new(0.5, 0.5)
	frame.BackgroundTransparency = 1
	frame.BorderSizePixel = 0
	frame.Parent = parent

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(1, 0)
	corner.Parent = frame

	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 1
	stroke.Parent = frame
	return frame, stroke
end

--[[
	The points of one arc, centre to ring.

	Offsets are perpendicular to the arc and shaped by a sine, so both ends stay
	pinned -- to the core and to the ring -- and the jag is widest mid-flight,
	which is the silhouette of a real discharge. `crackle` adds a small per-frame
	shimmer on top of the held shape.
]]
local function arcPoints(
	points: { Vector2 },
	centre: Vector2,
	angle: number,
	reach: number,
	strike: number,
	index: number,
	crackle: number
): { Vector2 }
	local direction = Vector2.new(math.cos(angle), math.sin(angle))
	local normal = Vector2.new(-direction.Y, direction.X)
	points[1] = centre
	for step = 1, SEGMENTS - 1 do
		local t = step / SEGMENTS
		local jag = (Draw.hash(strike * 13 + step, index * 7 + 3) - 0.5) * reach * 0.42
		local shimmer = math.sin(crackle * 37 + step * 2.3 + index) * reach * 0.04
		points[step + 1] = centre + direction * (reach * t) + normal * ((jag + shimmer) * math.sin(t * math.pi))
	end
	points[SEGMENTS + 1] = centre + direction * reach
	return points
end

-- Reused by every arc every frame, so painting allocates no tables.
local scratch: { Vector2 } = {}

function Electro.mount(cell: Frame)
	local frame, stroke = circle(cell, "Ring")
	ring, ringStroke = frame, stroke

	-- Glow under the bolts, so it is drawn first.
	segments, glows = {}, {}
	for index = 1, BOLTS do
		glows[index] = Draw.pool(cell, SEGMENTS, string.format("Glow%d", index), false)
	end
	for index = 1, BOLTS do
		segments[index] = Draw.pool(cell, SEGMENTS, string.format("Arc%d", index), false)
		seed[index] = index * 31
		timer[index] = Draw.hash(index, 5) * STRIKE_SLOW
		interval[index] = STRIKE_SLOW
		bearing[index] = Draw.hash(index, 9) * TAU
	end

	local dots = Draw.pool(cell, 2, "Core", true)
	halo, core = dots[1], dots[2]
	flash = 0
	flareHigh = false
end

function Electro.unmount()
	segments, glows = {}, {}
	ring, ringStroke, halo, core = nil, nil, nil, nil
	seed, timer, interval, bearing = {}, {}, {}, {}
	flash = 0
end

function Electro.paint(ctx: Theme.Context, delta: number)
	local reach = ctx.size * 0.44
	local quiet = ctx.quiet > 20
	local energy = math.clamp(ctx.energy, 0, 1)
	local failing = ctx.shake > 0.3

	-- A reply discharges: on the rising edge of the flare, every arc re-strikes
	-- at once and the ring flashes.
	if ctx.flare > 0.6 and not flareHigh then
		flareHigh = true
		flash = 1
		for index = 1, BOLTS do
			timer[index] = 0
		end
	elseif ctx.flare < 0.3 then
		flareHigh = false
	end
	flash = math.max(0, flash - delta * 3.2)

	local live = if quiet
		then 1
		else math.clamp(1 + math.floor(math.clamp(ctx.activity, 0, 1) * (BOLTS - 1) + energy * 1.5 + 0.5), 1, BOLTS)
	local pace = STRIKE_SLOW + (STRIKE_FAST - STRIKE_SLOW) * energy
	if quiet then
		pace *= 3
	end

	local electric = if failing then ctx.palette.red else ctx.palette.violet
	for index = 1, BOLTS do
		local arcs, glow = segments[index], glows[index]
		if arcs == nil or glow == nil then
			continue
		end
		if index > live then
			for _, frame in arcs do
				frame.Visible = false
			end
			for _, frame in glow do
				frame.Visible = false
			end
			continue
		end

		-- Each arc drifts around the ring between strikes, slowly, so a calm
		-- panel's single arc wanders rather than standing still.
		bearing[index] = (bearing[index] + delta * (0.35 + energy * 1.2) * (if index % 2 == 0 then -1 else 1)) % TAU
		timer[index] -= delta
		if timer[index] <= 0 then
			seed[index] += 1
			interval[index] = pace * (0.6 + Draw.hash(seed[index], index) * 0.8)
			timer[index] = interval[index]
			bearing[index] += (Draw.hash(seed[index], index + 40) - 0.5) * 1.6
		end

		-- Brightest the instant it strikes, fading until the next.
		local age = 1 - math.clamp(timer[index] / math.max(interval[index], 1e-3), 0, 1)
		local strength = (1 - age) ^ 1.6
		local points = arcPoints(scratch, ctx.centre, bearing[index], reach, seed[index], index, ctx.clock)
		local hot = electric:Lerp(WHITE, 0.35 + strength * 0.45 + flash * 0.2)
		local base = if quiet then 0.55 else 0.1

		for step = 1, SEGMENTS do
			local a, b = points[step], points[step + 1]
			Draw.edge(arcs[step], a, b, 1, hot, math.clamp(base + (1 - strength) * 0.7, 0, 0.95))
			Draw.edge(
				glow[step],
				a,
				b,
				3,
				electric,
				math.clamp(0.82 + (1 - strength) * 0.16 - flash * 0.25, 0, 1)
			)
		end
	end

	local frame, stroke = ring, ringStroke
	if frame ~= nil and stroke ~= nil then
		local diameter = reach * 2 + 2
		frame.Visible = true
		frame.Position = UDim2.fromOffset(ctx.centre.X, ctx.centre.Y)
		frame.Size = UDim2.fromOffset(diameter, diameter)
		stroke.Color = electric:Lerp(WHITE, flash * 0.5)
		stroke.Transparency = math.clamp(0.72 - flash * 0.55 - energy * 0.12, 0, 1)
	end

	-- The halo wears the connection's status colour, like every preset's does.
	local glowDot = halo
	if glowDot ~= nil then
		Draw.dot(
			glowDot,
			ctx.centre,
			math.max(8, math.floor(9 * ctx.scale + energy * 5 + flash * 6)),
			ctx.tint,
			math.clamp(0.82 - flash * 0.3, 0, 1)
		)
	end
	local coreDot = core
	if coreDot ~= nil then
		-- A flicker while failing: the core browning out.
		local flicker = if failing then 0.5 + 0.5 * math.sin(ctx.clock * 60) else 1
		Draw.dot(
			coreDot,
			ctx.centre,
			math.max(3, math.floor(4 * ctx.scale + flash * 2)),
			ctx.palette.cyan:Lerp(WHITE, 0.5 + flash * 0.5),
			math.clamp(1 - flicker, 0, 0.6)
		)
	end
end

--[[
	History as spikes: thin, white-hot when fresh and cooling to the arc colour
	with age. Failures are wider and red, and stay bright longer.
]]
function Electro.paintSlot(slot: Theme.Slot, ctx: Theme.Context)
	local frame = slot.frame
	local recency = 1 - slot.age
	frame.AnchorPoint = Vector2.new(0.5, 1)
	frame.Size = UDim2.new(0, if slot.ok then 2 else 3, math.max(slot.weight, 0.06), 0)
	frame.Position = UDim2.new(frame.Position.X.Scale, frame.Position.X.Offset, 1, 0)
	frame.BackgroundColor3 = if slot.ok
		then ctx.palette.violet:Lerp(WHITE, recency * recency * 0.6)
		else ctx.palette.red
	frame.BackgroundTransparency = math.clamp((if slot.ok then 0.25 else 0.05) + slot.age * 0.6, 0, 1)
	frame.Rotation = 0
end

return Electro
