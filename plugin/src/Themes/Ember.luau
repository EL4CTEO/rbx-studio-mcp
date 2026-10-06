--!strict
--[[
	Ember -- a fire that burns as hard as the session works.

	Sparks rise off a bed of coals, wobbling as they go, cooling from white-gold
	through orange to dull red and fading out at the top. The number of sparks in
	the air is the session's activity: a quiet session is a few embers drifting
	up, a burst is a shower. Like Orbit, it is a count you can read rather than
	a pace you have to judge.

	A reply is a gust: the sparks swell and brighten for the third of a second
	`flare` lasts. Past the quiet threshold the fire banks down to a few coals,
	which is the honest picture of a session that has stopped.

	Time is integrated, not read off the clock. A spark's place in its life is
	`time / period`, and a rate that changes multiplied by a clock in the
	thousands would throw every spark to a new place the moment it moved; an
	accumulated time makes a faster fire a faster fire.
]]

local Draw = require(script.Parent.Draw)
local Theme = require(script.Parent.Theme)

local SPARKS = 22
local COALS = 7

local Ember = {}

Ember.id = "ember"
Ember.label = "Ember"
Ember.blurb = "Rising sparks"

Ember.palette = {
	-- Charcoal with a red cast, so the panel looks lit from below.
	background = Color3.fromRGB(16, 9, 8),
	surface = Color3.fromRGB(28, 16, 13),
	rule = Color3.fromRGB(255, 138, 70),
	text = Color3.fromRGB(242, 224, 212),
	dim = Color3.fromRGB(160, 118, 104),
	green = Color3.fromRGB(140, 225, 130),
	red = Color3.fromRGB(255, 92, 104),
	amber = Color3.fromRGB(255, 200, 92),
	cyan = Color3.fromRGB(112, 208, 236),
	violet = Color3.fromRGB(255, 138, 70),
}

local sparks: { Frame } = {}
local coals: { Frame } = {}
local bed: Frame? = nil
local time = 0

-- White-gold at birth, the accent in the middle of its life, dull red at death.
local function heat(palette: Theme.Palette, life: number): Color3
	local warm = palette.amber:Lerp(palette.violet, math.clamp(life / 0.5, 0, 1))
	return warm:Lerp(palette.red, math.clamp((life - 0.5) / 0.5, 0, 1))
end

function Ember.mount(cell: Frame)
	-- The glow under everything: a band at the foot of the cell that fades out
	-- upward, which is what makes the coals look like they are lighting the air.
	local glow = Instance.new("Frame")
	glow.Name = "Bed"
	glow.AnchorPoint = Vector2.new(0.5, 1)
	glow.Position = UDim2.fromScale(0.5, 1)
	glow.Size = UDim2.new(1, 0, 0, 12)
	glow.BorderSizePixel = 0
	glow.Parent = cell
	local fade = Instance.new("UIGradient")
	fade.Rotation = 90
	fade.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1),
		NumberSequenceKeypoint.new(1, 0.3),
	})
	fade.Parent = glow
	bed = glow

	coals = Draw.pool(cell, COALS, "Coal", true)
	sparks = Draw.pool(cell, SPARKS, "Spark", true)
	time = 0
end

function Ember.unmount()
	sparks = {}
	coals = {}
	bed = nil
	time = 0
end

function Ember.paint(ctx: Theme.Context, delta: number)
	local pace = if ctx.quiet > 20 then 0.35 else 1
	time += delta * (1 + ctx.energy * 0.9) * pace

	local glow = bed
	if glow ~= nil then
		glow.BackgroundColor3 = ctx.palette.violet:Lerp(ctx.palette.amber, ctx.flare * 0.5)
		glow.Size = UDim2.new(1, 0, 0, math.floor(9 + ctx.activity * 8 + ctx.flare * 4))
		glow.BackgroundTransparency = math.clamp(0.25 - ctx.activity * 0.1 - ctx.flare * 0.15, 0, 1)
	end

	-- The coals pulse on their own phases, so the bed shimmers instead of
	-- breathing as one.
	for index = 1, COALS do
		local frame = coals[index]
		local pulse = 0.5 + 0.5 * math.sin(time * 1.7 + Draw.hash(index, 81) * 6.3)
		Draw.dot(
			frame,
			Vector2.new(ctx.size * (index / (COALS + 1)), ctx.size - 3),
			3 + math.floor(pulse * 1.5 + ctx.flare),
			ctx.palette.red:Lerp(ctx.palette.violet, pulse * 0.8):Lerp(Color3.new(1, 1, 1), ctx.flare * 0.4),
			math.clamp(0.45 - pulse * 0.3 - ctx.flare * 0.2, 0, 1)
		)
	end

	--[[
		How many sparks are in the air. Activity runs 0..1 over about ten
		seconds, so the shower thickens as a burst lands and thins as it
		unwinds; a stopped session keeps three.
	]]
	local aloft = if ctx.quiet > 20
		then 3
		else math.min(SPARKS, 5 + math.floor(math.clamp(ctx.activity, 0, 1) * (SPARKS - 5) + ctx.energy * 3))

	for index = 1, SPARKS do
		local frame = sparks[index]
		if index > aloft then
			frame.Visible = false
			continue
		end

		local period = 1.8 + 1.8 * Draw.hash(index, 71)
		local life = (time / period + Draw.hash(index, 72)) % 1
		local anchor = ctx.size * (0.08 + 0.84 * Draw.hash(index, 73))
		local wobble = math.sin(life * 7 + Draw.hash(index, 72) * 9) * (2 + 2 * Draw.hash(index, 74))

		Draw.dot(
			frame,
			Vector2.new(anchor + wobble, ctx.size - 5 - life * ctx.size * 0.82),
			math.max(1, math.floor(1 + (1 - life) * 2.4 + ctx.flare * 1.2)),
			heat(ctx.palette, life):Lerp(Color3.new(1, 1, 1), ctx.flare * 0.4),
			math.clamp(0.1 + life * 0.85 - ctx.flare * 0.2, 0, 1)
		)
	end
end

--[[
	History as flames: a column per call, taller and hotter the slower it was.
	A failure is a red one, which is the colour the fire is nearest to going out.
]]
function Ember.paintSlot(slot: Theme.Slot, ctx: Theme.Context)
	local frame = slot.frame
	local recency = 1 - slot.age
	local height = math.max(2, math.floor(2 + slot.weight * 20))

	frame.AnchorPoint = Vector2.new(0.5, 1)
	frame.Size = UDim2.fromOffset(3, height)
	frame.Position = UDim2.new(frame.Position.X.Scale, frame.Position.X.Offset, 1, 0)
	frame.BackgroundColor3 = if slot.ok
		then ctx.palette.amber:Lerp(ctx.palette.violet, slot.weight)
		else ctx.palette.red
	frame.BackgroundTransparency = math.clamp(0.68 - recency * 0.58, 0, 1)
	frame.Rotation = 0
end

function Ember.swatch(frame: Frame, palette: Theme.Palette)
	local glow = Instance.new("Frame")
	glow.AnchorPoint = Vector2.new(0.5, 1)
	glow.Position = UDim2.fromScale(0.5, 1)
	glow.Size = UDim2.new(1, 0, 0, 10)
	glow.BorderSizePixel = 0
	glow.BackgroundColor3 = palette.violet
	glow.Parent = frame
	local fade = Instance.new("UIGradient")
	fade.Rotation = 90
	fade.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1),
		NumberSequenceKeypoint.new(1, 0.3),
	})
	fade.Parent = glow

	local pool = Draw.pool(frame, 16, "Spark", true)
	for index = 1, 16 do
		local life = Draw.hash(index, 83)
		Draw.dot(
			pool[index],
			Vector2.new(5 + Draw.hash(index, 84) * 30 + math.sin(life * 7) * 2, 20 - life * 17),
			math.max(1, math.floor(1 + (1 - life) * 2.4)),
			heat(palette, life),
			0.1 + life * 0.8
		)
	end
end

return Ember
