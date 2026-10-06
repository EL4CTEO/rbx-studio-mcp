--!strict
--[[
	Sonar -- every call is a ping.

	A sweep turns around a hub, leaving a fading trail, and contacts light up as
	it passes over them and glow out behind it. A reply sends a ring outward from
	the hub, which is the same thing a ping is. Like Orbit, it reports something
	you can count: one contact is a quiet session, six is a burst, and the sweep
	itself turns faster the harder the session is working.

	A failure sends a red ring instead of a clear one, so the one event you want
	to notice is the one that is a different colour from everything else on the
	screen.

	The sweep angle is integrated rather than derived from the clock. A rate that
	changes multiplied by a clock in the thousands teleports the arm every time
	the rate moves; accumulating it makes a change in pace a change in speed.
]]

local Draw = require(script.Parent.Draw)
local Theme = require(script.Parent.Theme)

local CONTACTS = 6
local TRAIL = 7
local PINGS = 3
-- How long a ring takes to reach the edge of the scope.
local PING_SECONDS = 1.3
local TAU = math.pi * 2

local Sonar = {}

Sonar.id = "sonar"
Sonar.label = "Sonar"
Sonar.blurb = "Ping and sweep"

Sonar.palette = {
	-- Teal-black, the colour of a screen in a dark room.
	background = Color3.fromRGB(5, 15, 17),
	surface = Color3.fromRGB(10, 25, 28),
	rule = Color3.fromRGB(84, 214, 196),
	text = Color3.fromRGB(200, 236, 232),
	dim = Color3.fromRGB(98, 150, 150),
	green = Color3.fromRGB(120, 232, 128),
	red = Color3.fromRGB(255, 116, 120),
	amber = Color3.fromRGB(250, 200, 110),
	cyan = Color3.fromRGB(110, 200, 250),
	violet = Color3.fromRGB(84, 214, 196),
}

local rangeRings: { Frame } = {}
local rangeStrokes: { UIStroke } = {}
local trail: { Frame } = {}
local contacts: { Frame } = {}
local pings: { Frame } = {}
local pingStrokes: { UIStroke } = {}
local halo: Frame? = nil
local hub: Frame? = nil

local sweep = 0
-- When each ring was sent (seconds on the context clock), or -1 for "not
-- travelling", and whether it was sent for a failure.
local pingStart: { number } = { -1, -1, -1 }
local pingFailed: { boolean } = { false, false, false }
local nextPing = 1
-- Edge detection for `flare`, which stays high for a third of a second: a ring
-- is sent when it rises, not for every frame it is up.
local flareHigh = false

-- A circle drawn as a stroke on an invisible frame, so only the rim exists.
local function ring(parent: Instance, name: string): (Frame, UIStroke)
	local frame = Instance.new("Frame")
	frame.Name = name
	frame.AnchorPoint = Vector2.new(0.5, 0.5)
	frame.BackgroundTransparency = 1
	frame.BorderSizePixel = 0
	frame.Visible = false
	frame.Parent = parent

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(1, 0)
	corner.Parent = frame

	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 1
	stroke.Parent = frame
	return frame, stroke
end

function Sonar.mount(cell: Frame)
	rangeRings, rangeStrokes, pings, pingStrokes = {}, {}, {}, {}
	for index = 1, 3 do
		local frame, stroke = ring(cell, string.format("Range%02d", index))
		rangeRings[index] = frame
		rangeStrokes[index] = stroke
	end

	trail = Draw.pool(cell, TRAIL, "Sweep", false)
	contacts = Draw.pool(cell, CONTACTS, "Contact", true)

	for index = 1, PINGS do
		local frame, stroke = ring(cell, string.format("Ping%02d", index))
		pings[index] = frame
		pingStrokes[index] = stroke
	end

	-- Hub last, so a ring passing through the middle goes behind it.
	local glow = Draw.pool(cell, 2, "Hub", true)
	halo = glow[1]
	hub = glow[2]

	sweep = 0
	pingStart = { -1, -1, -1 }
	pingFailed = { false, false, false }
	nextPing = 1
	flareHigh = false
end

function Sonar.unmount()
	rangeRings, rangeStrokes, trail, contacts, pings, pingStrokes = {}, {}, {}, {}, {}, {}
	halo = nil
	hub = nil
	sweep = 0
end

function Sonar.paint(ctx: Theme.Context, delta: number)
	local reach = ctx.size * 0.46
	-- Past the quiet threshold the session has stopped, and a sweep still
	-- turning at working speed claims an activity that is not happening.
	local pace = if ctx.quiet > 20 then 0.3 else 1
	sweep = (sweep + delta * (1.1 + ctx.activity * 2.2 + ctx.energy * 0.8) * pace) % TAU

	-- Range rings: fixed, faint, and the only fixed thing on the scope. They are
	-- what gives the sweep a size to be measured against.
	for index = 1, #rangeRings do
		local frame = rangeRings[index]
		local diameter = reach * 2 * (index / 3)
		frame.Visible = true
		frame.Position = UDim2.fromOffset(ctx.centre.X, ctx.centre.Y)
		frame.Size = UDim2.fromOffset(diameter, diameter)
		rangeStrokes[index].Color = ctx.palette.dim
		rangeStrokes[index].Transparency = if index == 3 then 0.6 else 0.82
	end

	-- The arm and its afterglow: each segment lags the one in front of it by a
	-- little more, and is a little fainter.
	for index = 1, #trail do
		local angle = sweep - (index - 1) * 0.17
		local tip = ctx.centre + Vector2.new(math.cos(angle), math.sin(angle)) * reach
		Draw.edge(
			trail[index],
			ctx.centre,
			tip,
			if index == 1 then 2 else 1,
			ctx.palette.violet:Lerp(Color3.new(1, 1, 1), if index == 1 then 0.25 + ctx.flare * 0.5 else 0),
			math.clamp(0.15 + (index - 1) / TRAIL * 0.8, 0, 1)
		)
	end

	--[[
		How many contacts are up. Activity runs 0..1 over about ten seconds, so
		this climbs through the pool as a burst lands and drops back as it
		unwinds -- the readout the theme exists for.
	]]
	local visible = 1 + math.floor(math.clamp(ctx.activity, 0, 1) * (CONTACTS - 1) + 0.5)
	for index = 1, CONTACTS do
		local frame = contacts[index]
		if index > visible then
			frame.Visible = false
			continue
		end
		local bearing = Draw.hash(index, 61) * TAU
		local range = reach * (0.3 + 0.62 * Draw.hash(index, 62))
		-- Radians since the arm passed over it: a contact is brightest the
		-- instant it is swept and fades over the next three quarters of a turn.
		local since = (sweep - bearing) % TAU
		local glow = math.clamp(1 - since / (math.pi * 1.5), 0, 1)
		glow *= glow
		Draw.dot(
			frame,
			ctx.centre + Vector2.new(math.cos(bearing), math.sin(bearing)) * range,
			math.max(2, math.floor(2 + glow * 2.5 + ctx.flare)),
			ctx.palette.green:Lerp(Color3.new(1, 1, 1), glow * 0.55),
			math.clamp(0.92 - glow * 0.82, 0, 1)
		)
	end

	-- Rings. Sent on the rising edge of a reply's flare.
	if ctx.flare > 0.6 and not flareHigh then
		flareHigh = true
		pingStart[nextPing] = ctx.clock
		pingFailed[nextPing] = ctx.shake > 0.3
		nextPing = nextPing % PINGS + 1
	elseif ctx.flare < 0.3 then
		flareHigh = false
	end

	for index = 1, PINGS do
		local frame = pings[index]
		local started = pingStart[index]
		local travelled = if started < 0 then 1 else (ctx.clock - started) / PING_SECONDS
		if travelled >= 1 then
			frame.Visible = false
			continue
		end
		-- Fast out of the hub and slowing toward the edge, the way a wavefront
		-- loses speed to the spreading of its own energy.
		local eased = 1 - (1 - travelled) * (1 - travelled)
		local diameter = 4 + reach * 2 * eased
		frame.Visible = true
		frame.Position = UDim2.fromOffset(ctx.centre.X, ctx.centre.Y)
		frame.Size = UDim2.fromOffset(diameter, diameter)
		pingStrokes[index].Color = if pingFailed[index]
			then ctx.palette.red
			else ctx.palette.violet:Lerp(Color3.new(1, 1, 1), 0.3)
		pingStrokes[index].Transparency = math.clamp(0.15 + travelled * 0.85, 0, 1)
	end

	-- The halo carries the connection's status colour, as Orbit's does: the
	-- scene keeps its own colours and the part that is allowed to change does.
	local glowFrame = halo
	if glowFrame ~= nil then
		Draw.dot(
			glowFrame,
			ctx.centre,
			math.max(8, math.floor(10 * ctx.scale + ctx.energy * 6 + ctx.flare * 5)),
			ctx.tint,
			math.clamp(0.88 - ctx.flare * 0.3, 0, 1)
		)
	end
	local core = hub
	if core ~= nil then
		Draw.dot(
			core,
			ctx.centre,
			math.max(3, math.floor(4 * ctx.scale + ctx.flare * 2)),
			ctx.palette.violet:Lerp(Color3.new(1, 1, 1), 0.35 + ctx.flare * 0.5),
			0
		)
	end
end

--[[
	History as contacts held at their last range: a dot per call, high when slow.
	Failures are larger and red and fade more slowly, so one is still findable
	forty calls later.
]]
function Sonar.paintSlot(slot: Theme.Slot, ctx: Theme.Context)
	local frame = slot.frame
	local recency = 1 - slot.age

	frame.AnchorPoint = Vector2.new(0.5, 0.5)
	local size = if slot.ok
		then math.max(2, math.floor(2 + slot.weight * 2.5 + recency))
		else math.max(4, math.floor(4 + recency * 2))
	frame.Size = UDim2.fromOffset(size, size)
	frame.Position = UDim2.new(frame.Position.X.Scale, frame.Position.X.Offset, 0.88 - slot.weight * 0.74, 0)
	frame.BackgroundColor3 = if slot.ok then ctx.palette.violet else ctx.palette.red
	frame.BackgroundTransparency = math.clamp((if slot.ok then 0.7 else 0.35) - recency * 0.55, 0, 1)
	frame.Rotation = 0
end

function Sonar.swatch(frame: Frame, palette: Theme.Palette)
	local centre = Vector2.new(20, 12)
	for index = 1, 3 do
		local circle, stroke = ring(frame, "Range")
		local diameter = 6 + index * 7
		circle.Visible = true
		circle.Position = UDim2.fromOffset(centre.X, centre.Y)
		circle.Size = UDim2.fromOffset(diameter, diameter)
		stroke.Color = palette.dim
		stroke.Transparency = if index == 3 then 0.55 else 0.8
	end

	local arm = Draw.pool(frame, 5, "Sweep", false)
	for index = 1, 5 do
		local angle = -0.7 - (index - 1) * 0.2
		Draw.edge(
			arm[index],
			centre,
			centre + Vector2.new(math.cos(angle), math.sin(angle)) * 13,
			if index == 1 then 2 else 1,
			palette.violet,
			0.15 + (index - 1) * 0.18
		)
	end

	local dots = Draw.pool(frame, 4, "Contact", true)
	local places = { Vector2.new(9, -3), Vector2.new(-7, 4), Vector2.new(5, 5), Vector2.new(-11, -4) }
	for index = 1, 4 do
		Draw.dot(dots[index], centre + places[index], 2 + index % 2, palette.green, 0.25 + index * 0.1)
	end
	local core = Draw.pool(frame, 1, "Hub", true)
	Draw.dot(core[1], centre, 4, palette.violet:Lerp(Color3.new(1, 1, 1), 0.35), 0)
end

return Sonar
