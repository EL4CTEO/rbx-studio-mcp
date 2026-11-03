--!strict
--[[
	Hyperline -- every call is a light trail.

	A tunnel seen from the cab: a grid floor scrolling toward you, neon arches
	and light posts streaming past, a sky with a glowing vanishing point, and the
	session's traffic as streaks of light. A command leaves as a trail flying out
	toward the vanishing point; its reply rushes back past the camera; a failure
	comes back red. How fast everything moves is the session's activity, so an
	idle panel cruises and a burst of calls is a sprint.

	The one preset that is WIDE: it takes the whole band rather than the square
	cell, and the trace rides along its bottom edge as a rail. Visuals reads
	`wide` and lays the band out for it; the other presets are untouched.

	Geometry is clipped to the band before it is drawn. The floor starts exactly
	where it meets the band's bottom edge (`zBottom`), so the near grid lines --
	the brightest ones -- are on screen rather than projected below it, and
	nothing becomes a thousand-pixel Frame. Glow is real: the sky, the
	vanishing-point flare, the floor light and the vignette are Radial
	UIGradients (upgraded gradients, October 2026).

	Everything is pooled at mount; about 200 Frames are moved per frame and none
	are created.
]]

local Draw = require(script.Parent.Draw)
local Theme = require(script.Parent.Theme)

local Hyperline = {}

Hyperline.id = "hyperline"
Hyperline.label = "Hyperline"
Hyperline.blurb = "Transit tunnel, live trails"
Hyperline.wide = true
Hyperline.special = true

Hyperline.palette = {
	background = Color3.fromRGB(3, 4, 12),
	surface = Color3.fromRGB(8, 10, 26),
	rule = Color3.fromRGB(79, 195, 255),
	text = Color3.fromRGB(219, 230, 255),
	dim = Color3.fromRGB(111, 122, 163),
	green = Color3.fromRGB(47, 255, 193),
	red = Color3.fromRGB(255, 77, 109),
	amber = Color3.fromRGB(255, 200, 92),
	cyan = Color3.fromRGB(79, 224, 255),
	violet = Color3.fromRGB(155, 123, 255),
}

local WHITE = Color3.new(1, 1, 1)
local BLACK = Color3.new(0, 0, 0)

--[[
	Explicit depths. A plugin widget draws with ZIndexBehavior.Global, and
	siblings at one ZIndex do NOT reliably draw in creation order. Everything
	stays above the band itself (1) and below the trace, readout and HUD, which
	Visuals lifts to 7+ while a wide preset is active.
]]
local Z_SKY = 2
local Z_BACK = 3
local Z_GRID = 4
local Z_TRAIL = 5
local Z_FRONT = 6

local TRAILS = 40
local DUST = 14
local STARS = 18
local FLOOR_LINES = 16
local RAILS = 15
local ARCHES = 3
local POSTS = 7 -- per side
-- Depth of the visible tunnel, in track units.
local FAR = 700
-- Camera height above the floor. Low, so the floor fills the lower half.
local FLOOR_Y = -8
local FLOOR_STEP = 24
local RAIL_SPACING = 10
local ARCH_STEP = 240
local ARCH_HALF = 70
local ARCH_TOP = 28
local POST_STEP = 70
local POST_X = 82
local POST_TOP = 16
-- Where the horizon sits, as a share of the band's height.
local HORIZON = 0.4
-- Ambient trails per second at rest and flat out.
local AMBIENT_SLOW = 3.5
local AMBIENT_FAST = 10

type Trail = {
	live: boolean,
	x: number,
	y: number,
	z: number,
	v: number,
	len: number,
	width: number,
	out: boolean,
	ambient: boolean,
	color: Color3,
	glow: Frame,
	core: Frame,
}

type Mote = { x: number, y: number, z: number, frame: Frame }
type Arch = { glow: { Frame }, core: { Frame } }
type Post = { pole: Frame, lamp: Frame }

local trails: { Trail } = {}
local dust: { Mote } = {}
local stars: { Frame } = {}
local floor: { Frame } = {}
local rails: { Frame } = {}
local arches: { Arch } = {}
local posts: { Post } = {}
local sky: Frame? = nil
local flare: Frame? = nil
local floorLight: Frame? = nil
local horizonLine: Frame? = nil
local floorFill: Frame? = nil
local vignette: Frame? = nil
local travel = 0
local speed = 30
local ambientBank = 0
local nextTrail = 1
local flash = 0
local flareHigh = false
local palette: Theme.Palette = Hyperline.palette

-- Call lanes: just above the floor up to eye level, inside the arches.
local LANES = { -6, -3, 0, 3, 7, 11 }

local function layer(frames: { Frame }, z: number)
	for _, frame in frames do
		frame.ZIndex = z
	end
end

local function fadeTail(frame: Frame)
	local gradient = Instance.new("UIGradient")
	-- Draw.edge points the frame's +X from its first point to its second, and
	-- the head is always passed first, so the head is keypoint 0.
	gradient.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0),
		NumberSequenceKeypoint.new(0.25, 0.2),
		NumberSequenceKeypoint.new(1, 1),
	})
	gradient.Parent = frame
end

local function radial(frame: Frame, inner: number, outer: number)
	local gradient = Instance.new("UIGradient")
	pcall(function()
		(gradient :: any).Type = (Enum :: any).GradientType.Radial
	end)
	gradient.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, inner),
		NumberSequenceKeypoint.new(0.45, (inner + outer) / 2),
		NumberSequenceKeypoint.new(1, outer),
	})
	gradient.Parent = frame
end

local function plain(parent: Instance, name: string, z: number): Frame
	local frame = Instance.new("Frame")
	frame.Name = name
	frame.BorderSizePixel = 0
	frame.AnchorPoint = Vector2.new(0.5, 0.5)
	frame.ZIndex = z
	frame.Parent = parent
	return frame
end

local function colorFor(kind: string, out: boolean, ok: boolean): Color3
	if not ok then
		return palette.red
	end
	if kind == "write" then
		return palette.violet
	elseif kind == "run" then
		return palette.green
	elseif kind == "debug" then
		return palette.amber
	end
	-- A read goes out cyan and comes back green, so the pair reads as a round trip.
	return if out then palette.cyan else palette.green
end

local function spawn(out: boolean, color: Color3, heavy: boolean, ambient: boolean)
	local trail = trails[nextTrail]
	if trail == nil then
		return
	end
	nextTrail = nextTrail % TRAILS + 1
	trail.live = true
	trail.ambient = ambient
	trail.color = color
	if ambient then
		-- Ambient traffic fills the frame: the deck, eye level, and skyways up
		-- top and out past the posts, so no part of the scene is dead.
		local band = math.random()
		trail.x = (math.random() - 0.5) * 300
		trail.y = if band < 0.35 then FLOOR_Y + 0.6 + math.random() * 2 elseif band < 0.7 then -4 + math.random() * 14 else 14 + math.random() * 30
		trail.v = if math.random() < 0.5 then -(110 + math.random() * 150) else 150 + math.random() * 120
		trail.out = trail.v > 0
		trail.len = 30 + math.random() * 80
		trail.width = 0.5 + math.random() * 0.4
		trail.z = if trail.out then 30 + math.random() * 40 else FAR + math.random() * 100
		return
	end
	trail.out = out
	trail.x = (math.random() - 0.5) * ARCH_HALF * 1.6
	trail.y = LANES[math.random(1, #LANES)]
	trail.z = if out then 30 + math.random() * 30 else FAR + math.random() * 80
	trail.v = if out then 260 + math.random() * 200 else -(300 + math.random() * 260)
	trail.len = if heavy then 26 + math.random() * 24 else 55 + math.random() * 90
	trail.width = if heavy then 1.6 else 1 + math.random() * 0.5
end

function Hyperline.mount(cell: Frame)
	trails, dust, stars, floor, rails, arches, posts = {}, {}, {}, {}, {}, {}, {}
	travel, ambientBank, nextTrail, flash, flareHigh = 0, 0, 1, 0, false

	local skyFrame = plain(cell, "Sky", Z_SKY)
	radial(skyFrame, 0.15, 1)
	sky = skyFrame

	stars = Draw.pool(cell, STARS, "Star", true)
	layer(stars, Z_BACK)

	local fill = plain(cell, "FloorFill", Z_BACK)
	fill.AnchorPoint = Vector2.new(0, 0)
	local fillFade = Instance.new("UIGradient")
	fillFade.Rotation = 90
	fillFade.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.6),
		NumberSequenceKeypoint.new(1, 0.15),
	})
	fillFade.Parent = fill
	floorFill = fill

	-- A pool of light on the floor under the vanishing point.
	local pool = plain(cell, "FloorLight", Z_BACK)
	radial(pool, 0.55, 1)
	floorLight = pool

	local glowDot = plain(cell, "Flare", Z_BACK)
	radial(glowDot, 0.1, 1)
	flare = glowDot

	local line = plain(cell, "Horizon", Z_GRID)
	local lineFade = Instance.new("UIGradient")
	lineFade.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1),
		NumberSequenceKeypoint.new(0.5, 0),
		NumberSequenceKeypoint.new(1, 1),
	})
	lineFade.Parent = line
	horizonLine = line

	floor = Draw.pool(cell, FLOOR_LINES, "Floor", false)
	rails = Draw.pool(cell, RAILS, "Rail", false)
	layer(floor, Z_GRID)
	layer(rails, Z_GRID)

	for index = 1, POSTS * 2 do
		local pole = Draw.pool(cell, 1, string.format("Post%02d", index), false)[1]
		local lamp = Draw.pool(cell, 1, string.format("Lamp%02d", index), true)[1]
		pole.ZIndex = Z_GRID
		lamp.ZIndex = Z_TRAIL
		posts[index] = { pole = pole, lamp = lamp }
	end

	for index = 1, ARCHES do
		local glow = Draw.pool(cell, 3, string.format("ArchGlow%d", index), false)
		local core = Draw.pool(cell, 3, string.format("Arch%d", index), false)
		layer(glow, Z_GRID)
		layer(core, Z_GRID)
		arches[index] = { glow = glow, core = core }
	end

	-- Glows first, so every core draws over every glow.
	local glows = Draw.pool(cell, TRAILS, "TrailGlow", false)
	local cores = Draw.pool(cell, TRAILS, "Trail", false)
	layer(glows, Z_TRAIL)
	layer(cores, Z_TRAIL)
	for index = 1, TRAILS do
		fadeTail(glows[index])
		fadeTail(cores[index])
		trails[index] = {
			live = false,
			x = 0,
			y = 0,
			z = 0,
			v = 0,
			len = 0,
			width = 1,
			out = false,
			ambient = false,
			color = WHITE,
			glow = glows[index],
			core = cores[index],
		}
	end
	-- Seed the tunnel so it opens full rather than filling up over seconds.
	for _ = 1, 16 do
		spawn(false, Hyperline.palette.rule, false, true)
		local trail = trails[(nextTrail - 2) % TRAILS + 1]
		trail.z = 40 + math.random() * FAR
	end

	local motes = Draw.pool(cell, DUST, "Dust", false)
	layer(motes, Z_TRAIL)
	for index = 1, DUST do
		fadeTail(motes[index])
		dust[index] = {
			x = (math.random() - 0.5) * 200,
			y = FLOOR_Y + math.random() * 40,
			z = 20 + math.random() * 400,
			frame = motes[index],
		}
	end

	local edge = plain(cell, "Vignette", Z_FRONT)
	edge.Position = UDim2.fromScale(0.5, 0.5)
	edge.Size = UDim2.fromScale(1.5, 2.2)
	edge.BackgroundColor3 = BLACK
	local edgeGradient = Instance.new("UIGradient")
	pcall(function()
		(edgeGradient :: any).Type = (Enum :: any).GradientType.Radial
	end)
	edgeGradient.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1),
		NumberSequenceKeypoint.new(0.55, 1),
		NumberSequenceKeypoint.new(1, 0.3),
	})
	edgeGradient.Parent = edge
	vignette = edge
end

function Hyperline.unmount()
	trails, dust, stars, floor, rails, arches, posts = {}, {}, {}, {}, {}, {}, {}
	sky, flare, floorLight, horizonLine, floorFill, vignette = nil, nil, nil, nil, nil, nil
end

--[[
	A call going out or coming back. Visuals calls this from the console's own
	begin/record events, so a bright trail is a real call, never decoration.
]]
function Hyperline.onCall(event: Theme.CallEvent)
	local heavy = event.kind == "write" or event.kind == "run"
	local color = colorFor(event.kind, event.phase == "out", event.ok)
	local count = if event.phase == "out" then 3 else 4
	if not event.ok then
		count = 6
	end
	for _ = 1, count do
		spawn(event.phase == "out", color, heavy, false)
	end
end

function Hyperline.paint(ctx: Theme.Context, delta: number)
	palette = ctx.palette
	local width, height = ctx.width, ctx.height
	if width < 4 or height < 4 then
		return
	end

	if ctx.flare > 0.6 and not flareHigh then
		flareHigh = true
		flash = 1
	elseif ctx.flare < 0.3 then
		flareHigh = false
	end
	flash = math.max(0, flash - delta * 2.2)

	local quiet = ctx.quiet > 20
	local energy = math.clamp(ctx.energy, 0, 1)
	local activity = math.clamp(ctx.activity, 0, 1)
	local target = if quiet then 12 else 28 + activity * 130 + energy * 90
	speed += (target - speed) * math.min(1, delta * 1.4)
	travel += speed * delta

	-- A failure shakes the camera sideways while the shake lasts.
	local sway = if ctx.shake > 0.05 then (math.random() - 0.5) * ctx.shake * 8 else 0
	local cx, horizonY = width / 2 + sway, height * HORIZON
	local focal = height * 1.2
	-- The depth at which the floor meets the band's bottom edge. Nothing on the
	-- floor is drawn nearer than this, because nearer is off screen.
	local zBottom = -FLOOR_Y * focal / (height - horizonY)
	local function project(x: number, y: number, z: number): Vector2
		local scale = focal / math.max(z, 1)
		return Vector2.new(cx + x * scale, horizonY - y * scale)
	end

	local skyFrame = sky
	if skyFrame ~= nil then
		skyFrame.Position = UDim2.fromOffset(cx, horizonY)
		skyFrame.Size = UDim2.fromOffset(width * 1.3, height * 1.7)
		skyFrame.BackgroundColor3 = palette.violet:Lerp(palette.cyan, energy * 0.35)
		skyFrame.BackgroundTransparency = math.clamp(0.25 - flash * 0.15, 0, 1)
	end

	for index, star in stars do
		local sx = Draw.hash(index, 3) * width
		local sy = Draw.hash(index, 7) * horizonY * 0.85
		local twinkle = 0.5 + 0.5 * math.sin(ctx.clock * (0.8 + Draw.hash(index, 11) * 1.6) + index)
		Draw.dot(star, Vector2.new(sx, sy), if Draw.hash(index, 13) > 0.8 then 2 else 1, WHITE, 0.35 + (1 - twinkle) * 0.5)
	end

	local fill = floorFill
	if fill ~= nil then
		fill.Position = UDim2.fromOffset(0, horizonY)
		fill.Size = UDim2.fromOffset(width, height - horizonY)
		fill.BackgroundColor3 = palette.background
	end
	local pool = floorLight
	if pool ~= nil then
		pool.Position = UDim2.fromOffset(cx, horizonY + (height - horizonY) * 0.35)
		pool.Size = UDim2.fromOffset(width * 0.9, (height - horizonY) * 1.3)
		pool.BackgroundColor3 = palette.cyan:Lerp(palette.violet, 0.4)
		pool.BackgroundTransparency = math.clamp(0.55 - energy * 0.15 - flash * 0.15, 0, 1)
	end
	local glowDot = flare
	if glowDot ~= nil then
		local size = height * (0.8 + energy * 0.4 + flash * 0.5)
		glowDot.Position = UDim2.fromOffset(cx, horizonY)
		glowDot.Size = UDim2.fromOffset(size * 1.7, size)
		glowDot.BackgroundColor3 = palette.cyan:Lerp(WHITE, 0.3 + flash * 0.4)
		glowDot.BackgroundTransparency = math.clamp(0.4 - flash * 0.25 - energy * 0.1, 0, 1)
	end
	local line = horizonLine
	if line ~= nil then
		line.Position = UDim2.fromOffset(cx, horizonY)
		line.Size = UDim2.fromOffset(width, 1)
		line.BackgroundColor3 = palette.cyan:Lerp(WHITE, 0.4 + flash * 0.4)
		line.BackgroundTransparency = 0.05
	end

	-- Floor cross lines, from the bottom edge to the horizon, brightest nearest.
	local reach = FLOOR_LINES * FLOOR_STEP
	local offset = travel % FLOOR_STEP
	local halfWidth = width / 2 + 40
	for index, frame in floor do
		local z = zBottom + (index - 1) * FLOOR_STEP - offset
		if z < zBottom then
			z += reach
		end
		local y = project(0, FLOOR_Y, z).Y
		local nearness = math.clamp(1 - (z - zBottom) / reach, 0, 1)
		Draw.edge(
			frame,
			Vector2.new(cx - halfWidth, y),
			Vector2.new(cx + halfWidth, y),
			if nearness > 0.8 then 2 else 1,
			palette.rule,
			1 - nearness * nearness * 0.8
		)
	end
	-- Rails converge on the vanishing point, starting at the bottom edge.
	local half = (RAILS - 1) / 2
	for index, frame in rails do
		local lane = index - 1 - half
		local a = project(lane * RAIL_SPACING, FLOOR_Y, zBottom)
		local b = project(lane * RAIL_SPACING, FLOOR_Y, FAR)
		local alpha = math.max(0.12, 0.65 - math.abs(lane) * 0.06)
		Draw.edge(frame, a, b, if lane == 0 then 2 else 1, if lane == 0 then palette.cyan else palette.rule, 1 - alpha)
	end

	-- Light posts on both sides, streaming past.
	local postOffset = travel % POST_STEP
	for index, post in posts do
		local side = if index <= POSTS then -1 else 1
		local slot = (index - 1) % POSTS
		local z = zBottom * 1.4 + slot * POST_STEP - postOffset
		if z < zBottom * 1.4 then
			z += POSTS * POST_STEP
		end
		local base = project(side * POST_X, FLOOR_Y, z)
		local top = project(side * POST_X, POST_TOP, z)
		local nearness = math.clamp(1 - z / (POSTS * POST_STEP), 0, 1)
		Draw.edge(post.pole, base, top, if nearness > 0.7 then 2 else 1, palette.violet, 1 - nearness * 0.8)
		Draw.dot(post.lamp, top, 2 + nearness * 5, palette.cyan:Lerp(WHITE, 0.4), 1 - nearness * 0.95)
	end

	-- Arches: two posts and a beam, flaring when a reply lands.
	local archOffset = travel % ARCH_STEP
	for index, arch in arches do
		local z = zBottom * 1.6 + (index - 1) * ARCH_STEP - archOffset
		if z < zBottom * 1.6 then
			z += ARCHES * ARCH_STEP
		end
		local leftBase = project(-ARCH_HALF, FLOOR_Y, z)
		local leftTop = project(-ARCH_HALF, ARCH_TOP, z)
		local rightBase = project(ARCH_HALF, FLOOR_Y, z)
		local rightTop = project(ARCH_HALF, ARCH_TOP, z)
		local nearness = math.clamp(1 - z / (ARCHES * ARCH_STEP), 0, 1)
		local tube = palette.violet:Lerp(WHITE, flash * 0.5)
		local coreAlpha = math.clamp(nearness * 0.95 + flash * 0.2, 0, 1)
		local glowAlpha = math.clamp(nearness * 0.4 + flash * 0.25, 0, 1)
		local glowWidth = math.floor(3 + nearness * 5)
		local coreWidth = if nearness > 0.6 then 2 else 1
		local segments = { { leftBase, leftTop }, { leftTop, rightTop }, { rightTop, rightBase } }
		for part, ends in segments do
			Draw.edge(arch.glow[part], ends[1], ends[2], glowWidth, palette.violet, 1 - glowAlpha)
			Draw.edge(arch.core[part], ends[1], ends[2], coreWidth, tube, 1 - coreAlpha)
		end
	end

	-- Ambient traffic keeps the tunnel alive between calls.
	ambientBank += delta * (AMBIENT_SLOW + (AMBIENT_FAST - AMBIENT_SLOW) * activity)
	if quiet then
		ambientBank = math.min(ambientBank, 0.6)
	end
	while ambientBank >= 1 do
		ambientBank -= 1
		local pick = math.random()
		local tint = if pick < 0.5 then palette.rule elseif pick < 0.8 then palette.violet else palette.cyan
		spawn(false, tint, false, true)
	end

	-- Trails fade out before they reach the camera instead of ballooning.
	local fadeNear = zBottom * 1.3
	for _, trail in trails do
		if not trail.live then
			trail.glow.Visible = false
			trail.core.Visible = false
			continue
		end
		local drift = if trail.out then speed * 0.25 else speed
		trail.z += (trail.v - drift) * delta
		if trail.z > FAR + 140 or trail.z < fadeNear * 0.6 then
			trail.live = false
			trail.glow.Visible = false
			trail.core.Visible = false
			continue
		end
		local direction = if trail.out then -1 else 1
		local headZ = math.max(trail.z, fadeNear * 0.6)
		local head = project(trail.x, trail.y, headZ)
		local tail = project(trail.x, trail.y, headZ + direction * trail.len)
		local scale = focal / headZ
		local visibility = math.clamp((FAR + 120 - trail.z) / 220, 0, 1) * math.clamp((trail.z - fadeNear * 0.6) / fadeNear, 0, 1)
		local strength = if trail.ambient then 0.65 else 1
		local glowWidth = math.clamp(trail.width * scale * 0.9, 2, 7)
		local coreWidth = math.clamp(trail.width * scale * 0.25, 1, 2)
		Draw.edge(trail.glow, head, tail, math.floor(glowWidth), trail.color, 1 - visibility * strength * 0.45)
		Draw.edge(
			trail.core,
			head,
			tail,
			math.floor(coreWidth),
			trail.color:Lerp(WHITE, if trail.ambient then 0.15 else 0.45),
			1 - visibility * strength
		)
	end

	-- Speed dust: world-fixed motes stretched by our own speed.
	local stretch = 2 + speed * 0.06
	for _, mote in dust do
		mote.z -= speed * delta
		if mote.z < fadeNear then
			mote.z = 300 + math.random() * 120
			mote.x = (math.random() - 0.5) * 200
			mote.y = FLOOR_Y + math.random() * 40
		end
		local head = project(mote.x, mote.y, mote.z)
		local tail = project(mote.x, mote.y, mote.z + stretch)
		local nearness = math.clamp(1 - mote.z / 420, 0, 1)
		Draw.edge(mote.frame, head, tail, 1, palette.text, 1 - nearness * 0.7)
	end

	local edge = vignette
	if edge ~= nil then
		edge.Visible = true
	end
end

--[[
	The rail along the bottom: thin glowing ticks, cyan when fine, amber when
	slow, red when failed, dimming with age.
]]
function Hyperline.paintSlot(slot: Theme.Slot, ctx: Theme.Context)
	local frame = slot.frame
	frame.AnchorPoint = Vector2.new(0.5, 1)
	frame.Size = UDim2.new(0, if slot.ok then 2 else 3, math.max(slot.weight, 0.08), 0)
	frame.Position = UDim2.new(frame.Position.X.Scale, frame.Position.X.Offset, 1, 0)
	local color = if not slot.ok then ctx.palette.red elseif slot.weight > 0.6 then ctx.palette.amber else ctx.palette.cyan
	frame.BackgroundColor3 = color:Lerp(WHITE, (1 - slot.age) ^ 3 * 0.4)
	frame.BackgroundTransparency = math.clamp((if slot.ok then 0.15 else 0) + slot.age * 0.55, 0, 1)
	frame.Rotation = 0
	frame.ZIndex = 8
end

return Hyperline
