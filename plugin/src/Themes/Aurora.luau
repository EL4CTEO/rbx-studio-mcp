--!strict
--[[
	Aurora -- load as an amplitude.

	A curtain of vertical rays whose height follows a travelling wave. The wave
	is always there; what the session changes is how violent it is. Idle, it is
	a shallow ripple you have to look at to notice. Under load it becomes a
	curtain that fills the cell. Nothing here counts or ranks anything, which is
	the point: it answers "how hard is this working" continuously, where Lattice
	answers it in four steps and Orbit in six.

	Two waves at different rates are summed rather than one, because a single
	sine is a loading bar lying on its side -- the interference is what makes it
	read as something physical rather than as an animation on a loop.

	Colour runs green at the base to violet at the tips, which is the actual
	emission order of a real aurora and, more usefully here, means the height of
	a ray is legible from its colour alone at four pixels wide.
]]

local Draw = require(script.Parent.Draw)
local Theme = require(script.Parent.Theme)

local RAYS = 15

local Aurora = {}

Aurora.id = "aurora"
Aurora.label = "Aurora"
Aurora.blurb = "Rising curtain"

Aurora.palette = {
	background = Color3.fromRGB(9, 14, 28),
	surface = Color3.fromRGB(16, 23, 44),
	rule = Color3.fromRGB(108, 226, 178),
	text = Color3.fromRGB(206, 220, 238),
	dim = Color3.fromRGB(86, 100, 130),
	green = Color3.fromRGB(108, 232, 172),
	red = Color3.fromRGB(246, 126, 146),
	amber = Color3.fromRGB(244, 196, 128),
	cyan = Color3.fromRGB(114, 214, 236),
	violet = Color3.fromRGB(162, 146, 240),
}

local rays: { Frame } = {}

--[[
	Accumulated wave phase, rather than wall time times a rate.

	`ctx.clock * 1.6 * pace` looks harmless and is not: `pace` drops to 0.35 the
	moment the session goes quiet, and multiplying a clock in the thousands by a
	rate that changes RESHAPES the whole curtain in one frame -- the same class
	of fault as Void's disc, just rarer, because this rate only moves twice per
	idle cycle instead of every frame. Integrating it means going quiet slows the
	curtain, which is what was meant.
]]
local phase = 0

function Aurora.mount(cell: Frame)
	rays = {}
	for index = 1, RAYS do
		local ray = Instance.new("Frame")
		ray.Name = string.format("Ray%02d", index)
		-- Anchored at the bottom so height grows upward from a fixed baseline,
		-- which is what makes the curtain rise rather than expand about its
		-- middle.
		ray.AnchorPoint = Vector2.new(0.5, 1)
		ray.BorderSizePixel = 0
		ray.Parent = cell
		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(0, 1)
		corner.Parent = ray
		rays[index] = ray
	end
end

function Aurora.unmount()
	phase = 0
	rays = {}
end

function Aurora.paint(ctx: Theme.Context, delta: number)
	local width = ctx.size
	local spacing = width / (RAYS + 1)

	--[[
		The floor is what keeps an idle panel alive.

		Amplitude driven purely by activity would flatten the curtain to nothing
		between commands, and a flat line is indistinguishable from a plugin
		that has crashed. A tenth of the range is always moving.
	]]
	local amplitude = 0.1 + math.clamp(ctx.activity, 0, 1) * 0.62 + ctx.energy * 0.16
	local pace = if ctx.quiet > 20 then 0.35 else 1
	phase += delta * pace

	for index = 1, RAYS do
		local ray = rays[index]
		if ray == nil then
			continue
		end
		local across = index / RAYS

		-- Two travelling waves, incommensurate rates. Their beat is slow enough
		-- that the curtain visibly reshapes over several seconds instead of
		-- repeating on a cycle the eye can learn.
		local wave = math.sin(across * 5.2 - phase * 1.6)
			+ 0.6 * math.sin(across * 2.7 + phase * 0.9)
		local normalised = (wave + 1.6) / 3.2

		local height = math.max(2, math.floor(width * (0.12 + normalised * amplitude) * ctx.scale))
		local reach = math.clamp(height / width, 0, 1)

		ray.Size = UDim2.fromOffset(3, height)
		ray.Position = UDim2.fromOffset(spacing * index, width - 2)
		-- Green low, violet high: the ray's own height is readable from its
		-- colour, which a three-pixel column badly needs.
		ray.BackgroundColor3 = ctx.palette.green
			:Lerp(ctx.palette.violet, reach)
			:Lerp(Color3.new(1, 1, 1), ctx.flare * 0.45)
		ray.BackgroundTransparency = math.clamp(0.74 - reach * 0.45 - ctx.flare * 0.3, 0, 1)
	end
end

--[[
	The trace as a continuation of the curtain: same rays, same colour rule, but
	their heights are history rather than a wave.
]]
function Aurora.paintSlot(slot: Theme.Slot, ctx: Theme.Context)
	local frame = slot.frame
	local recency = 1 - slot.age
	local height = math.max(2, math.floor(2 + slot.weight * 21))

	frame.AnchorPoint = Vector2.new(0.5, 1)
	frame.Size = UDim2.fromOffset(3, height)
	frame.Position = UDim2.new(frame.Position.X.Scale, frame.Position.X.Offset, 1, 0)
	frame.BackgroundColor3 = if slot.ok
		then ctx.palette.green:Lerp(ctx.palette.violet, slot.weight)
		else ctx.palette.red
	frame.BackgroundTransparency = math.clamp(0.66 - recency * 0.56, 0, 1)
	frame.Rotation = 0
end

function Aurora.swatch(frame: Frame, palette: Theme.Palette)
	for index = 1, 12 do
		local ray = Instance.new("Frame")
		ray.AnchorPoint = Vector2.new(0.5, 1)
		ray.BorderSizePixel = 0
		local across = index / 12
		local wave = math.sin(across * 5.2) + 0.6 * math.sin(across * 2.7)
		local reach = (wave + 1.6) / 3.2
		local height = math.max(2, math.floor(4 + reach * 17))
		ray.Size = UDim2.fromOffset(2, height)
		ray.Position = UDim2.fromOffset(3 + index * 3, 23)
		ray.BackgroundColor3 = palette.green:Lerp(palette.violet, reach)
		ray.BackgroundTransparency = 0.35
		ray.Parent = frame
	end
end

return Aurora
