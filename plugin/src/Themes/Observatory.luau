--!strict
--[[
	Observatory -- AMOLED, and a session you can read as a sky.

	The background is true #000000. On an OLED display those pixels are off, so
	the panel has no edges at all and the console appears to float in the Studio
	dock rather than sit in a box. That only works if the black is actually
	black: a near-black at RGB(11, 12, 20) lights every pixel and the illusion
	collapses, which is why this theme does not simply darken the default one.

	The cell holds a star sphere instead of a prism -- points on a shell, turned
	slowly and projected, twinkling on their own phases. It reads as depth
	without a single straight line, which is the whole point of the contrast
	with Lattice.

	The trace is the reason the theme exists. Each finished call is a star whose
	height is how slow it was and whose brightness fades as it ages, so forty
	calls of history read as a constellation rather than as a bar chart. A
	failure is a red giant: bigger, redder, and slower to fade, so the one thing
	you actually want to find in a session's history is the one thing the eye
	lands on first.
]]

local Draw = require(script.Parent.Draw)
local Theme = require(script.Parent.Theme)

-- Points on the shell. Enough to read as a field, few enough that every one of
-- them is a Frame the paint loop touches every frame.
local STARS = 26
local FOCAL = 3.2
local SHELL = 0.36

local Observatory = {}

Observatory.id = "observatory"
Observatory.label = "Observatory"
Observatory.blurb = "True black. Stars"

Observatory.palette = {
	-- Genuinely off, not merely dark. Every other colour here is chosen to hold
	-- contrast against zero rather than against a lifted black.
	background = Color3.fromRGB(0, 0, 0),
	surface = Color3.fromRGB(8, 9, 12),
	rule = Color3.fromRGB(148, 178, 214),
	text = Color3.fromRGB(214, 224, 238),
	dim = Color3.fromRGB(78, 88, 106),
	green = Color3.fromRGB(126, 226, 176),
	red = Color3.fromRGB(248, 122, 122),
	amber = Color3.fromRGB(240, 196, 118),
	cyan = Color3.fromRGB(150, 214, 240),
	violet = Color3.fromRGB(176, 172, 236),
}

local stars: { Frame } = {}
local meridian: { Frame } = {}

--[[
	A fixed point on the shell for star `index`.

	Derived from the index rather than stored, and derived the same way every
	frame -- a field that re-randomised itself per frame would boil rather than
	drift.

	Evenly spread rather than randomly placed. A hashed longitude and latitude
	is the obvious way to do this and it produced a visibly lopsided sky: the
	field bunched into one corner of the cell with an empty half beside it,
	which reads as a rendering fault rather than as stars. Twinkle supplies the
	irregularity instead, and it does it without leaving holes.
]]
local function starAt(index: number): Vector3
	return Draw.sphere(index, STARS)
end

function Observatory.mount(cell: Frame)
	-- The meridian sits under the stars so a bright point is never cut by the
	-- line it happens to cross.
	meridian = Draw.pool(cell, 24, "Meridian", true)
	stars = Draw.pool(cell, STARS, "Star", true)
end

function Observatory.unmount()
	stars = {}
	meridian = {}
end

function Observatory.paint(ctx: Theme.Context, _delta: number)
	local radius = ctx.size * SHELL * ctx.scale
	-- A third of Lattice's rate. Stars that turn at a wireframe's pace read as
	-- a spinning object; at this speed they read as a sky the panel is looking
	-- out at, which is the difference the theme is trading on.
	local angle = ctx.angle * 0.34

	for index = 1, STARS do
		local frame = stars[index]
		if frame == nil then
			continue
		end
		local point, depth = Draw.project(
			Draw.rotate(starAt(index), angle),
			FOCAL,
			radius,
			ctx.centre
		)
		local near = math.clamp((depth + 1) / 2, 0, 1)

		--[[
			Each star on its own phase and rate, so the field never pulses as one.

			A shared clock would make the whole sphere breathe together, which
			reads as the panel flickering rather than as stars twinkling. The
			rates are deliberately irrational relative to each other.
		]]
		local twinkle = 0.5 + 0.5 * math.sin(ctx.clock * (0.7 + Draw.hash(index, 3) * 1.9)
			+ Draw.hash(index, 4) * 9)

		local brightness = near * 0.7 + twinkle * 0.3
		Draw.dot(
			frame,
			point,
			math.max(1, math.floor(1 + near * 2 + ctx.flare * 2)),
			ctx.tint:Lerp(Color3.new(1, 1, 1), 0.3 + brightness * 0.6),
			math.clamp(0.9 - brightness * 0.8 - ctx.flare * 0.4, 0, 1)
		)
	end

	--[[
		A great circle through the sphere: the horizon an observatory is aimed
		along. Drawn as points rather than segments so it fades in and out with
		depth like the stars do, instead of reading as a hard hoop drawn on top
		of them.
	]]
	-- 1.05 rather than the 1.18 this started at: at full overshoot the wider
	-- ring reached 21.5px from a centre with 20px of room, so the horizon was
	-- sliced off by the cell's own clipping exactly when the session was busiest.
	for index = 1, #meridian do
		local frame = meridian[index]
		local turn = (index / #meridian) * math.pi * 2
		local point, depth = Draw.project(
			Draw.rotate(Vector3.new(math.cos(turn), 0, math.sin(turn)), angle),
			FOCAL,
			radius * 1.05,
			ctx.centre
		)
		local near = math.clamp((depth + 1) / 2, 0, 1)
		Draw.dot(frame, point, 1, ctx.tint, math.clamp(0.94 - near * 0.35, 0, 1))
	end
end

--[[
	One call as a star rather than as a bar.

	Height is duration, so a slow call sits high and the eye reads the skyline
	as a latency profile without being told to. Brightness is recency, so the
	newest calls are the ones that stand out and old history recedes on its own
	rather than needing to be scrolled away.
]]
function Observatory.paintSlot(slot: Theme.Slot, ctx: Theme.Context)
	local frame = slot.frame
	local recency = 1 - slot.age

	-- Failures ignore the height rule. A red giant is large because it failed,
	-- not because it was slow, and conflating the two would hide a fast error
	-- among fast successes at the bottom of the trace.
	local size = if slot.ok
		then math.max(2, math.floor(1.5 + slot.weight * 2.5 + recency * 1.5))
		else math.max(4, math.floor(4 + recency * 2))

	frame.AnchorPoint = Vector2.new(0.5, 0.5)
	frame.Size = UDim2.fromOffset(size, size)
	-- 0.12 keeps the newest star clear of the trace's top edge, and the 0.82
	-- span leaves the baseline visible under the lowest one.
	frame.Position = UDim2.new(frame.Position.X.Scale, frame.Position.X.Offset, 0.9 - slot.weight * 0.78, 0)
	frame.BackgroundColor3 = if slot.ok
		then ctx.palette.cyan:Lerp(Color3.new(1, 1, 1), 0.25 + recency * 0.4)
		else ctx.palette.red
	frame.BackgroundTransparency = if slot.ok
		then math.clamp(0.72 - recency * 0.62, 0, 1)
		-- Slower to fade than a success, so the failure in a session's history
		-- is still legible forty calls later.
		else math.clamp(0.45 - recency * 0.4, 0, 1)
	frame.Rotation = 0
end

function Observatory.swatch(frame: Frame, palette: Theme.Palette)
	local pool = Draw.pool(frame, 14, "Star", true)
	for index = 1, 14 do
		local x = 3 + Draw.hash(index, 11) * 34
		local y = 3 + Draw.hash(index, 12) * 18
		local bright = Draw.hash(index, 13)
		Draw.dot(
			pool[index],
			Vector2.new(x, y),
			if bright > 0.85 then 3 else 1 + math.floor(bright * 2),
			palette.cyan:Lerp(Color3.new(1, 1, 1), bright * 0.7),
			0.85 - bright * 0.7
		)
	end
end

return Observatory
