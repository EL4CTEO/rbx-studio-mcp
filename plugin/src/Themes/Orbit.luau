--!strict
--[[
	Orbit -- the only preset that reports something the others cannot.

	A body at the centre with satellites running elliptical paths around it. The
	number of satellites is the session's activity, so where Lattice climbs a
	ladder of shapes to say "busy", this says it in a way you can count: one
	moon is a quiet session, five is a burst.

	The ellipses are a projected circle rather than a drawn oval, so the whole
	system tilts as the angle turns and a satellite genuinely passes behind the
	body -- it dims and shrinks on the far side because it is further away. That
	is what stops it reading as a loading spinner with extra dots.

	Colour is warm here on purpose. Every other dark preset in the set leans
	blue or violet; a gold system against navy is the one that looks like an
	instrument rather than a screensaver.
]]

local Draw = require(script.Parent.Draw)
local Theme = require(script.Parent.Theme)

-- Satellites are pooled at the maximum and hidden when the session is calm, so
-- activity changes what is visible rather than what exists.
local MOONS = 6
local PATH_DOTS = 28
local FOCAL = 3.2

--[[
	How far the orbits reach, as a multiple of the body's radius.

	Chosen so the outermost satellite sits about 18px from a centre with 20px of
	room: filling the cell, with just enough margin that it never touches the
	clip. Two earlier values were both wrong for the same underlying reason --
	2.4 threw the sixth moon 26px out when busy, and 1.5 fixed the clipping by
	making the whole system too small to read.
]]
local ORBIT_SCALE = 1.95

--[[
	How much of the scale spring the ORBITS take. Almost none.

	The spring swings 0.82 to 1.20, and letting the satellites carry that meant
	the system had to rest small enough that its overshoot still fit -- so it
	was sized by its worst moment rather than by the one you spend all your time
	looking at. The body and the halo carry the spring instead: they sit at the
	centre with room to grow, and a struck object whose middle flexes reads the
	same as one that flexes all over.
]]
local ORBIT_BREATH = 0.08

local Orbit = {}

Orbit.id = "orbit"
Orbit.label = "Orbit"
Orbit.blurb = "Body and satellites"

Orbit.palette = {
	background = Color3.fromRGB(10, 13, 22),
	surface = Color3.fromRGB(17, 22, 36),
	rule = Color3.fromRGB(240, 186, 108),
	text = Color3.fromRGB(226, 222, 210),
	dim = Color3.fromRGB(96, 100, 116),
	green = Color3.fromRGB(134, 214, 158),
	red = Color3.fromRGB(240, 130, 116),
	amber = Color3.fromRGB(246, 190, 106),
	cyan = Color3.fromRGB(132, 196, 226),
	violet = Color3.fromRGB(196, 164, 226),
}

local body: Frame? = nil
local halo: Frame? = nil
local moons: { Frame } = {}
local path: { Frame } = {}

--[[
	Orbital parameters for satellite `index`.

	Fixed per index so a moon keeps its own path for the life of the session --
	re-rolling them would make the system reshuffle every frame. Radius rises
	with the index so the moons never share an orbit, and the inclination is
	what makes the paths cross rather than sit in one flat ring.
]]
local function orbitOf(index: number): (number, number, number)
	-- Tightened from `0.42 + index * 0.1`, which put the sixth moon at 1.02 and
	-- 26px from a centre with 20px of room -- so the satellite that only appears
	-- when the session is busiest was the one that flew off the edge.
	local radius = 0.34 + index * 0.055
	local speed = 1.5 / (radius * 2.4)
	local inclination = (Draw.hash(index, 5) - 0.5) * 1.6
	return radius, speed, inclination
end

function Orbit.mount(cell: Frame)
	path = Draw.pool(cell, PATH_DOTS, "Path", true)

	local disc = Instance.new("Frame")
	disc.Name = "Halo"
	disc.AnchorPoint = Vector2.new(0.5, 0.5)
	disc.BorderSizePixel = 0
	disc.Parent = cell
	local haloCorner = Instance.new("UICorner")
	haloCorner.CornerRadius = UDim.new(1, 0)
	haloCorner.Parent = disc
	halo = disc

	local core = Instance.new("Frame")
	core.Name = "Body"
	core.AnchorPoint = Vector2.new(0.5, 0.5)
	core.BorderSizePixel = 0
	core.Parent = cell
	local coreCorner = Instance.new("UICorner")
	coreCorner.CornerRadius = UDim.new(1, 0)
	coreCorner.Parent = core
	body = core

	-- Last, so a near satellite passes in front of the body it orbits.
	moons = Draw.pool(cell, MOONS, "Moon", true)
end

function Orbit.unmount()
	body = nil
	halo = nil
	moons = {}
	path = {}
end

function Orbit.paint(ctx: Theme.Context, _delta: number)
	local breath = (1 - ORBIT_BREATH) + ctx.scale * ORBIT_BREATH
	local radius = ctx.size * 0.34 * breath
	local core = body
	local glow = halo

	if core ~= nil then
		--[[
			Amber, not the status tint.

			Every other preset paints its cell in `ctx.tint` so the panel reads as
			disconnected at a glance. Orbit cannot: the tint is green while
			connected, so the body came out green while the drawer previewed it in
			gold, and the preview is a promise. The HALO carries the status colour
			instead -- same information, on the part of the scene that is supposed
			to change.
		]]
		local size = math.max(5, math.floor(7.5 * ctx.scale + ctx.flare * 3))
		Draw.dot(
			core,
			ctx.centre,
			size,
			ctx.palette.amber:Lerp(Color3.new(1, 1, 1), 0.3 + ctx.flare * 0.5),
			0
		)
	end
	if glow ~= nil then
		-- A halo that grows with energy rather than a body that does: the body
		-- staying put is what gives the satellites something fixed to orbit.
		local size = math.max(10, math.floor(13 * ctx.scale + ctx.energy * 8 + ctx.flare * 6))
		Draw.dot(glow, ctx.centre, size, ctx.tint, math.clamp(0.9 - ctx.flare * 0.35, 0, 1))
	end

	--[[
		The innermost path, drawn as points so it fades with depth.

		Only one path is drawn even though there are six orbits. Six rings turns
		the cell into a scribble at forty pixels across; one ring establishes
		that these things are orbiting and the rest is left to the motion.
	]]
	local pathRadius, _, pathTilt = orbitOf(1)
	for index = 1, PATH_DOTS do
		local frame = path[index]
		local turn = (index / PATH_DOTS) * math.pi * 2
		local local3 = Vector3.new(
			math.cos(turn) * pathRadius,
			math.sin(turn) * pathRadius * math.sin(pathTilt),
			math.sin(turn) * pathRadius * math.cos(pathTilt)
		)
		local point, depth = Draw.project(
			Draw.rotate(local3, ctx.angle * 0.5),
			FOCAL,
			radius * ORBIT_SCALE,
			ctx.centre
		)
		local near = math.clamp((depth + 1) / 2, 0, 1)
		Draw.dot(frame, point, 1, ctx.palette.dim, math.clamp(0.78 - near * 0.3, 0, 1))
	end

	--[[
		How many satellites are up. Activity runs 0..1 over about ten seconds,
		so this climbs through the pool as a burst lands and drops back as it
		unwinds -- which is the readout the theme exists for.
	]]
	local visible = 1 + math.floor(math.clamp(ctx.activity, 0, 1) * (MOONS - 1) + 0.5)

	for index = 1, MOONS do
		local frame = moons[index]
		if frame == nil then
			continue
		end
		if index > visible then
			frame.Visible = false
			continue
		end

		local orbitRadius, speed, tilt = orbitOf(index)
		-- Phase offset per moon so they do not launch from the same point and
		-- travel as a clump.
		local turn = ctx.clock * speed + Draw.hash(index, 6) * math.pi * 2
		local local3 = Vector3.new(
			math.cos(turn) * orbitRadius,
			math.sin(turn) * orbitRadius * math.sin(tilt),
			math.sin(turn) * orbitRadius * math.cos(tilt)
		)
		local point, depth = Draw.project(
			Draw.rotate(local3, ctx.angle * 0.5),
			FOCAL,
			radius * ORBIT_SCALE,
			ctx.centre
		)
		local near = math.clamp((depth + 1) / 2, 0, 1)
		Draw.dot(
			frame,
			point,
			math.max(2, math.floor(2.5 + near * 2.5 + ctx.flare * 1.5)),
			ctx.palette.amber:Lerp(Color3.new(1, 1, 1), near * 0.4 + ctx.flare * 0.3),
			math.clamp(0.35 - near * 0.32 - ctx.flare * 0.3, 0, 1)
		)
	end
end

--[[
	History as a run of moons at their apoapsis: a dot per call, high when slow.

	Bars would be the obvious choice and are wrong here -- a rectangle sitting
	on a baseline has nothing to do with the rest of the scene, and the trace
	and the cell would read as two unrelated instruments sharing a strip.
]]
function Orbit.paintSlot(slot: Theme.Slot, ctx: Theme.Context)
	local frame = slot.frame
	local recency = 1 - slot.age

	frame.AnchorPoint = Vector2.new(0.5, 0.5)
	local size = math.max(2, math.floor(2 + slot.weight * 3 + recency))
	frame.Size = UDim2.fromOffset(size, size)
	frame.Position = UDim2.new(frame.Position.X.Scale, frame.Position.X.Offset, 0.88 - slot.weight * 0.74, 0)
	frame.BackgroundColor3 = if slot.ok then ctx.palette.amber else ctx.palette.red
	frame.BackgroundTransparency = math.clamp((if slot.ok then 0.7 else 0.35) - recency * 0.55, 0, 1)
	frame.Rotation = 0
end

function Orbit.swatch(frame: Frame, palette: Theme.Palette)
	local centre = Vector2.new(20, 12)
	local ring = Draw.pool(frame, 20, "Path", true)
	for index = 1, 20 do
		local turn = (index / 20) * math.pi * 2
		Draw.dot(
			ring[index],
			centre + Vector2.new(math.cos(turn) * 13, math.sin(turn) * 5.5),
			1,
			palette.dim,
			0.6
		)
	end
	local pool = Draw.pool(frame, 2, "Body", true)
	Draw.dot(pool[1], centre, 7, palette.amber:Lerp(Color3.new(1, 1, 1), 0.3), 0)
	Draw.dot(pool[2], centre + Vector2.new(13, -1), 3, palette.amber, 0.1)
end

return Orbit
