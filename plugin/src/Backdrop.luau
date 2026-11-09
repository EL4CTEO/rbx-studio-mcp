--!strict
--[[
	The panel's animated background, one effect per theme.

	Every effect draws inside one host frame behind the panel's content and is
	stepped at 30 frames a second. `pulse` is how activity reaches it: each
	finished call hands over the colour of its kind, and the effect answers in
	its own way -- a light along a line, a burst of sparks, a ripple.

	All of it stays faint: it sits under text that has to stay readable.
]]

local RunService = game:GetService("RunService")

local Backdrop = {}

local FRAME_TIME = 1 / 30

type Effect = {
	step: (dt: number, size: Vector2) -> (),
	pulse: (tint: Color3) -> (),
	-- A click on the empty background, in the layer's own coordinates.
	click: ((x: number, y: number, tint: Color3) -> ())?,
}

local host: Frame? = nil
local layer: Frame? = nil
local effect: Effect? = nil
local enabled = true
local connection: RBXScriptConnection? = nil
local random = Random.new()

local function frame(parent: Instance, size: Vector2, color: Color3, transparency: number): Frame
	local f = Instance.new("Frame")
	f.AnchorPoint = Vector2.new(0.5, 0.5)
	f.BorderSizePixel = 0
	f.Size = UDim2.fromOffset(size.X, size.Y)
	f.BackgroundColor3 = color
	f.BackgroundTransparency = transparency
	f.Parent = parent
	return f
end

local function round(f: GuiObject)
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(1, 0)
	corner.Parent = f
end

-- A line between two points, as a rotated 1px frame.
local function stretch(line: Frame, ax: number, ay: number, bx: number, by: number)
	local dx, dy = bx - ax, by - ay
	line.Position = UDim2.fromOffset((ax + bx) / 2, (ay + by) / 2)
	line.Size = UDim2.fromOffset(math.sqrt(dx * dx + dy * dy), 1)
	line.Rotation = math.deg(math.atan2(dy, dx))
end

-- Constellation: drifting stars joined by fading lines; calls run along them.
local function constellation(root: Frame, color: Color3): Effect
	local clock = 0
	local stars = {}
	for _ = 1, 70 do
		local star = frame(root, Vector2.new(1, 1), color, 0.6)
		star.Position = UDim2.fromScale(random:NextNumber(), random:NextNumber())
		table.insert(stars, { f = star, base = 0.55 + random:NextNumber() * 0.35, phase = random:NextNumber() * 6.28, speed = 0.6 + random:NextNumber() * 1.6 })
	end
	local lines: { Frame } = {}
	for _ = 1, 110 do
		local line = frame(root, Vector2.new(1, 1), color, 1)
		line.Visible = false
		table.insert(lines, line)
	end
	local points = {}
	for _ = 1, 44 do
		local bright = random:NextNumber() < 0.18
		local size = if bright then 4 else random:NextInteger(2, 3)
		local dot = frame(root, Vector2.new(size, size), color, 0.5)
		dot.Rotation = 45
		local glow: Frame? = nil
		if bright then
			local halo = frame(root, Vector2.new(14, 14), color, 0.9)
			round(halo)
			glow = halo
		end
		local angle = random:NextNumber() * math.pi * 2
		local speed = 9 * (0.3 + random:NextNumber() * 0.7)
		table.insert(points, {
			x = random:NextNumber() * 900, y = random:NextNumber() * 700,
			vx = math.cos(angle) * speed, vy = math.sin(angle) * speed,
			bvx = math.cos(angle) * speed, bvy = math.sin(angle) * speed,
			f = dot, glow = glow,
			base = if bright then 0.2 else 0.4 + random:NextNumber() * 0.3,
			twinkle = if bright then 0.25 else 0.15,
			phase = random:NextNumber() * 6.28, flash = 0,
		})
	end
	local ends = {}
	local pulses = {}

	return {
		step = function(dt, size)
			clock += dt
			for _, s in stars do
				s.f.BackgroundTransparency = s.base + 0.25 * (0.5 + 0.5 * math.sin(clock * s.speed + s.phase))
			end
			for _, p in points do
				p.vx += (p.bvx - p.vx) * math.min(1, dt * 0.9)
				p.vy += (p.bvy - p.vy) * math.min(1, dt * 0.9)
				p.x += p.vx * dt
				p.y += p.vy * dt
				if p.x < -10 then p.x = size.X + 10 elseif p.x > size.X + 10 then p.x = -10 end
				if p.y < -10 then p.y = size.Y + 10 elseif p.y > size.Y + 10 then p.y = -10 end
				p.flash = math.max(0, p.flash - dt * 1.8)
				local shimmer = p.twinkle * (0.5 + 0.5 * math.sin(clock * 1.7 + p.phase))
				p.f.Position = UDim2.fromOffset(p.x, p.y)
				p.f.BackgroundTransparency = math.clamp(p.base + shimmer - p.flash * 0.6, 0, 1)
				if p.glow then
					p.glow.Position = p.f.Position
					p.glow.BackgroundTransparency = math.clamp(0.9 + shimmer * 0.1 - p.flash * 0.5, 0, 1)
				end
			end
			local used = 0
			table.clear(ends)
			for i = 1, #points do
				local a = points[i]
				for j = i + 1, #points do
					if used >= #lines then
						break
					end
					local b = points[j]
					local dx, dy = b.x - a.x, b.y - a.y
					local d = math.sqrt(dx * dx + dy * dy)
					if d < 115 then
						used += 1
						local line = lines[used]
						line.Visible = true
						stretch(line, a.x, a.y, b.x, b.y)
						line.BackgroundTransparency = 0.72 + 0.26 * (d / 115)
						ends[used] = { a = a, b = b }
					end
				end
			end
			for k = used + 1, #lines do
				lines[k].Visible = false
			end
			for index = #pulses, 1, -1 do
				local pulse = pulses[index]
				pulse.t += dt * 1.4
				local pair = ends[pulse.line]
				if pulse.t >= 1 or pair == nil then
					if pair then
						(if pulse.flip then pair.a else pair.b).flash = 1
					end
					pulse.f:Destroy()
					table.remove(pulses, index)
				else
					local from, to = pair.a, pair.b
					if pulse.flip then
						from, to = to, from
					end
					pulse.f.Position = UDim2.fromOffset(from.x + (to.x - from.x) * pulse.t, from.y + (to.y - from.y) * pulse.t)
					pulse.f.BackgroundTransparency = 0.15 + 0.7 * math.abs(pulse.t - 0.5) * 2
				end
			end
		end,
		pulse = function(tint)
			if #ends == 0 or #pulses >= 8 then
				return
			end
			local dot = frame(root, Vector2.new(4, 4), tint, 0.2)
			dot.Rotation = 45
			dot.ZIndex = 2
			table.insert(pulses, { line = random:NextInteger(1, #ends), t = 0, f = dot, flip = random:NextNumber() < 0.5 })
		end,
		click = function(x, y, _tint)
			for _, p in points do
				local dx, dy = p.x - x, p.y - y
				local d = math.max(math.sqrt(dx * dx + dy * dy), 1)
				if d < 220 then
					local push = 160 * (1 - d / 220)
					p.vx += dx / d * push
					p.vy += dy / d * push
					p.flash = math.max(p.flash, 1 - d / 220)
				end
			end
		end,
	}
end

-- A vertical glow: a frame whose fill fades in from `from` to `to` transparency.
local function fadeY(f: GuiObject, from: number, mid: number, to: number)
	local g = Instance.new("UIGradient")
	g.Rotation = 90
	g.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, from),
		NumberSequenceKeypoint.new(0.5, mid),
		NumberSequenceKeypoint.new(1, to),
	})
	g.Parent = f
	return g
end

--[[
	Embers: a heat glow along the bottom, sparks of three warmths rising and
	swaying, a few big slow embers with halos, and flickering. A call throws a
	fan of sparks up from one point.
]]
local function embers(root: Frame, color: Color3): Effect
	local warm = { color, Color3.fromRGB(255, 196, 92), Color3.fromRGB(255, 92, 60) }
	local heat = Instance.new("Frame")
	heat.AnchorPoint = Vector2.new(0.5, 1)
	heat.Position = UDim2.fromScale(0.5, 1)
	heat.Size = UDim2.new(1, 0, 0.35, 0)
	heat.BorderSizePixel = 0
	heat.BackgroundColor3 = Color3.fromRGB(255, 90, 40)
	heat.Parent = root
	local heatFade = fadeY(heat, 1, 0.94, 0.8)

	local sparks = {}
	local last = Vector2.new(800, 600)
	local function spawn(size: Vector2, opts: { x: number?, y: number?, vx: number?, vy: number?, tint: Color3?, big: boolean?, burst: boolean? }?)
		local o = opts or {}
		local big = o.big == true
		local s = if big then 5 else random:NextInteger(1, 3)
		local tint = o.tint or warm[random:NextInteger(1, #warm)]
		local f = frame(root, Vector2.new(s, s), tint, 0.3)
		f.Rotation = 45
		local halo: Frame? = nil
		if big then
			halo = frame(root, Vector2.new(18, 18), tint, 0.88)
			round(halo :: Frame)
		end
		table.insert(sparks, {
			f = f, halo = halo,
			x = o.x or random:NextNumber() * size.X,
			y = o.y or size.Y + random:NextNumber() * size.Y,
			vx = o.vx or 0,
			vy = o.vy or -(if big then 8 + random:NextNumber() * 8 else 14 + random:NextNumber() * 30),
			sway = random:NextNumber() * 6.28,
			flicker = random:NextNumber() * 6.28,
			life = 0,
			burst = o.burst == true,
		})
	end
	for _ = 1, 70 do
		spawn(last)
	end
	for _ = 1, 6 do
		spawn(last, { big = true })
	end
	local clock = 0
	local energy = 0
	return {
		step = function(dt, size)
			last = size
			clock += dt
			energy = math.max(0, energy - dt * 0.6)
			-- The heat breathes, and flares with activity.
			local breathe = 0.5 + 0.5 * math.sin(clock * 0.8)
			heatFade.Transparency = NumberSequence.new({
				NumberSequenceKeypoint.new(0, 1),
				NumberSequenceKeypoint.new(0.5, 0.95 - breathe * 0.02 - energy * 0.05),
				NumberSequenceKeypoint.new(1, 0.78 - breathe * 0.06 - energy * 0.15),
			})
			for index = #sparks, 1, -1 do
				local s = sparks[index]
				s.life += dt
				s.vx *= (1 - dt * 1.5)
				s.x += (s.vx + math.sin(s.life * 1.6 + s.sway) * 10) * dt
				s.y += s.vy * dt
				local height = math.clamp(s.y / math.max(size.Y, 1), 0, 1)
				local flick = 0.15 * math.sin(clock * 9 + s.flicker)
				s.f.BackgroundTransparency = math.clamp(0.15 + (1 - height) * 0.85 + flick, 0, 1)
				s.f.Position = UDim2.fromOffset(s.x, s.y)
				if s.halo then
					s.halo.Position = s.f.Position
					s.halo.BackgroundTransparency = math.clamp(0.82 + (1 - height) * 0.18, 0, 1)
				end
				if s.y < -8 then
					if s.burst then
						s.f:Destroy()
						if s.halo then
							s.halo:Destroy()
						end
						table.remove(sparks, index)
					else
						s.y = size.Y + 6
						s.x = random:NextNumber() * size.X
					end
				end
			end
		end,
		pulse = function(tint)
			energy = math.min(1, energy + 0.4)
			local x = random:NextNumber() * last.X
			for _ = 1, 12 do
				local angle = math.rad(-90 + random:NextNumber() * 70 - 35)
				local speed = 70 + random:NextNumber() * 70
				spawn(last, {
					x = x, y = last.Y - 4,
					vx = math.cos(angle) * speed, vy = math.sin(angle) * speed,
					tint = tint, burst = true,
				})
			end
		end,
		click = function(x, y, tint)
			energy = math.min(1, energy + 0.5)
			for _ = 1, 22 do
				local angle = random:NextNumber() * math.pi * 2
				local speed = 50 + random:NextNumber() * 110
				spawn(last, {
					x = x, y = y,
					vx = math.cos(angle) * speed, vy = math.sin(angle) * speed - 40,
					tint = if random:NextNumber() < 0.5 then tint else nil, burst = true,
				})
			end
		end,
	}
end

-- A smooth Path2D through `points` (x, y pairs), redrawn each frame.
local function curve(path: Path2D, xs: { number }, ys: { number })
	local controls = {}
	for i = 1, #xs do
		local prev = math.max(1, i - 1)
		local nxt = math.min(#xs, i + 1)
		local tx, ty = (xs[nxt] - xs[prev]) / 6, (ys[nxt] - ys[prev]) / 6
		table.insert(controls, Path2DControlPoint.new(
			UDim2.fromOffset(xs[i], ys[i]),
			UDim2.fromOffset(-tx, -ty),
			UDim2.fromOffset(tx, ty)
		))
	end
	path:SetControlPoints(controls)
end

--[[
	Tide: eight layered waves with light glinting on their crests, bubbles
	rising through the water and faint caustic bands near the surface. A call
	sends a ripple out and a rush of bubbles.
]]
local function waves(root: Frame, color: Color3): Effect
	local bands = {}
	for index = 1, 3 do
		local band = Instance.new("Frame")
		band.AnchorPoint = Vector2.new(0.5, 0)
		band.BorderSizePixel = 0
		band.BackgroundColor3 = color
		band.Size = UDim2.new(1.4, 0, 0, 40)
		band.Parent = root
		local g = Instance.new("UIGradient")
		g.Rotation = 90
		g.Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 1),
			NumberSequenceKeypoint.new(0.5, 0.94),
			NumberSequenceKeypoint.new(1, 1),
		})
		g.Parent = band
		table.insert(bands, { f = band, phase = index * 1.7 })
	end
	local layers = {}
	for index = 1, 8 do
		local path = Instance.new("Path2D")
		path.Color3 = color
		path.Thickness = if index % 3 == 0 then 1.5 else 1
		path.Parent = root
		local glints = {}
		for _ = 1, 3 do
			local glint = frame(root, Vector2.new(3, 3), Color3.new(1, 1, 1), 0.5)
			glint.Rotation = 45
			table.insert(glints, { f = glint, at = random:NextInteger(1, 15), phase = random:NextNumber() * 6.28 })
		end
		table.insert(layers, { p = path, depth = index / 8, phase = random:NextNumber() * 6.28, glints = glints })
	end
	local bubbles = {}
	local last = Vector2.new(800, 600)
	local function bubble(size: Vector2, x: number?, y: number?, fast: boolean?)
		local d = random:NextInteger(3, 7)
		local b = frame(root, Vector2.new(d, d), color, 1)
		round(b)
		local stroke = Instance.new("UIStroke")
		stroke.Color = color
		stroke.Transparency = 0.55
		stroke.Parent = b
		table.insert(bubbles, {
			f = b, stroke = stroke,
			x = x or random:NextNumber() * size.X,
			y = y or size.Y + random:NextNumber() * size.Y,
			vy = -(if fast then 60 + random:NextNumber() * 40 else 10 + random:NextNumber() * 14),
			wobble = random:NextNumber() * 6.28,
			temp = fast == true,
		})
	end
	for _ = 1, 18 do
		bubble(last)
	end
	local clock = 0
	local ripples = {}
	return {
		step = function(dt, size)
			last = size
			clock += dt
			for index, b in bands do
				b.f.Position = UDim2.new(0.5, math.sin(clock * 0.25 + b.phase) * 80, 0, 10 + index * 34 + math.sin(clock * 0.4 + b.phase) * 8)
				b.f.Rotation = math.sin(clock * 0.2 + b.phase) * 3
			end
			for _, w in layers do
				local xs, ys = {}, {}
				local baseline = size.Y * (0.3 + w.depth * 0.65)
				local amp = 6 + w.depth * 14
				for i = 0, 15 do
					local x = size.X * i / 15
					table.insert(xs, x)
					table.insert(ys, baseline + math.sin(i * 0.6 + clock * (0.35 + w.depth * 0.35) + w.phase) * amp
						+ math.sin(i * 1.7 - clock * 0.6 + w.phase) * amp * 0.25)
				end
				curve(w.p, xs, ys)
				w.p.Color3 = color:Lerp(Color3.new(0, 0, 0), 0.6 - w.depth * 0.35)
				for _, g in w.glints do
					local i = g.at
					g.f.Position = UDim2.fromOffset(xs[i + 1], ys[i + 1] - 1)
					g.f.BackgroundTransparency = 0.35 + 0.6 * (0.5 + 0.5 * math.sin(clock * 2.3 + g.phase))
				end
			end
			for index = #bubbles, 1, -1 do
				local b = bubbles[index]
				b.y += b.vy * dt
				b.x += math.sin(clock * 2 + b.wobble) * 6 * dt
				b.f.Position = UDim2.fromOffset(b.x, b.y)
				b.stroke.Transparency = math.clamp(0.4 + (1 - b.y / math.max(size.Y, 1)) * 0.5, 0, 1)
				if b.y < -8 then
					if b.temp then
						b.f:Destroy()
						table.remove(bubbles, index)
					else
						b.y = size.Y + 8
						b.x = random:NextNumber() * size.X
					end
				end
			end
			for index = #ripples, 1, -1 do
				local r = ripples[index]
				r.t += dt / 1.8
				for k, ring in r.rings do
					local t = math.clamp(r.t - (k - 1) * 0.15, 0, 1)
					local d = 8 + t * 160
					ring.f.Size = UDim2.fromOffset(d, d * 0.45)
					ring.stroke.Transparency = if t <= 0 then 1 else 0.25 + t * 0.75
				end
				if r.t >= 1.3 then
					for _, ring in r.rings do
						ring.f:Destroy()
					end
					table.remove(ripples, index)
				end
			end
		end,
		click = function(x, y, tint)
			local rings = {}
			for _ = 1, 4 do
				local ring = frame(root, Vector2.new(8, 4), tint, 1)
				ring.Position = UDim2.fromOffset(x, y)
				round(ring)
				local stroke = Instance.new("UIStroke")
				stroke.Color = tint
				stroke.Transparency = 1
				stroke.Parent = ring
				table.insert(rings, { f = ring, stroke = stroke })
			end
			table.insert(ripples, { rings = rings, t = 0 })
			for _ = 1, 6 do
				bubble(last, x + random:NextNumber(-20, 20), y + random:NextNumber(0, 10), true)
			end
		end,
		pulse = function(tint)
			if #ripples < 4 then
				local x, y = random:NextNumber() * last.X, last.Y * (0.45 + random:NextNumber() * 0.45)
				local rings = {}
				for _ = 1, 3 do
					local ring = frame(root, Vector2.new(8, 4), tint, 1)
					ring.Position = UDim2.fromOffset(x, y)
					round(ring)
					local stroke = Instance.new("UIStroke")
					stroke.Color = tint
					stroke.Transparency = 1
					stroke.Parent = ring
					table.insert(rings, { f = ring, stroke = stroke })
				end
				table.insert(ripples, { rings = rings, t = 0 })
			end
			for _ = 1, 5 do
				bubble(last, random:NextNumber() * last.X, last.Y + 6, true)
			end
		end,
	}
end

--[[
	Aurora: a curtain of light. Dozens of thin vertical rays hang from a wavy
	line near the top, fading down into the dark, their heights and brightness
	rippling along the curtain; the colours run green to violet across it.
	Faint stars sit behind. Activity makes the curtain flare.
]]
local function aurora(root: Frame, _color: Color3): Effect
	local stars = {}
	for _ = 1, 50 do
		local s = frame(root, Vector2.new(1, 1), Color3.new(1, 1, 1), 0.6)
		s.Position = UDim2.fromScale(random:NextNumber(), random:NextNumber())
		table.insert(stars, { f = s, phase = random:NextNumber() * 6.28 })
	end
	local palette = {
		ColorSequence.new(Color3.fromRGB(120, 255, 190), Color3.fromRGB(80, 200, 255)),
		ColorSequence.new(Color3.fromRGB(90, 230, 210), Color3.fromRGB(160, 120, 255)),
		ColorSequence.new(Color3.fromRGB(150, 130, 255), Color3.fromRGB(255, 120, 210)),
	}
	local rays = {}
	local COUNT = 64
	for i = 1, COUNT do
		local ray = Instance.new("Frame")
		ray.AnchorPoint = Vector2.new(0.5, 0)
		ray.BorderSizePixel = 0
		ray.BackgroundColor3 = Color3.new(1, 1, 1)
		ray.Parent = root
		local g = Instance.new("UIGradient")
		g.Rotation = 90
		-- Bright at the foot of the ray, fading up into the sky.
		g.Color = palette[1 + (math.floor(i / (COUNT / #palette)) % #palette)]
		g.Parent = ray
		table.insert(rays, { f = ray, g = g, u = (i - 0.5) / COUNT, phase = random:NextNumber() * 6.28 })
	end
	local clock = 0
	local energy = 0
	local focus, focusAge = 0.5, 99
	local width = 800
	return {
		click = function(x, _y, _tint)
			focus = x / math.max(width, 1)
			focusAge = 0
		end,
		step = function(dt, size)
			clock += dt
			width = size.X
			focusAge += dt
			energy = math.max(0, energy - dt * 0.4)
			for _, s in stars do
				s.f.BackgroundTransparency = 0.55 + 0.3 * (0.5 + 0.5 * math.sin(clock * 1.3 + s.phase))
			end
			local width = size.X / COUNT
			for _, r in rays do
				local u = r.u
				-- The curtain's foot waves; rays stand on it.
				local foot = size.Y * 0.32
					+ math.sin(u * 7 + clock * 0.35) * 26
					+ math.sin(u * 17 - clock * 0.6) * 8
				local height = 70 + 60 * (0.5 + 0.5 * math.sin(u * 11 + clock * 0.8 + r.phase * 0.3))
				local x = u * size.X + math.sin(clock * 0.2 + u * 4) * 20
				r.f.Position = UDim2.fromOffset(x, foot - height)
				r.f.Size = UDim2.fromOffset(width * 1.6, height)
				local glow = 0.5 + 0.5 * math.sin(u * 9 - clock * 1.1 + r.phase)
				-- A flare that spreads out from a click and fades as it goes.
				local front = math.abs(u - focus) - focusAge * 0.35
				local flare = if focusAge < 3 then math.exp(-(front * front) * 300) * (1 - focusAge / 3) else 0
				local peak = math.clamp(0.9 - glow * 0.22 - energy * 0.25 - flare * 0.45, 0.25, 1)
				r.g.Transparency = NumberSequence.new({
					NumberSequenceKeypoint.new(0, 1),
					NumberSequenceKeypoint.new(0.75, peak),
					NumberSequenceKeypoint.new(0.92, math.max(peak - 0.08, 0.3)),
					NumberSequenceKeypoint.new(1, 1),
				})
			end
		end,
		pulse = function(_tint)
			energy = math.min(1, energy + 0.35)
		end,
	}
end

--[[
	Monolith: greyscale architecture. Two tall slabs stand at the edges, fine
	vertical hairlines run behind them, and dust drifts slowly through. A soft
	beam crosses now and then, catching the slabs' edges and the lines as it
	passes. Activity sends the beam through sooner.
]]
local function sweep(root: Frame, color: Color3): Effect
	local columns = {}
	local built = Vector2.zero
	local slabs = {}
	local function build(size: Vector2)
		for _, c in columns do
			c.f:Destroy()
		end
		table.clear(columns)
		for _, s in slabs do
			s.f:Destroy()
		end
		table.clear(slabs)
		built = size
		for x = 18, size.X, 36 do
			local line = frame(root, Vector2.new(1, size.Y), color, 0.96)
			line.Position = UDim2.fromOffset(x, size.Y / 2)
			table.insert(columns, { f = line, x = x })
		end
		for _, spec in { { 0.1, 0.6 }, { 0.86, 0.75 } } do
			local w, h = 46, size.Y * spec[2]
			local slab = frame(root, Vector2.new(w, h), color, 0.95)
			slab.AnchorPoint = Vector2.new(0.5, 1)
			slab.Position = UDim2.fromOffset(size.X * spec[1], size.Y + 2)
			local edge = Instance.new("UIStroke")
			edge.Color = color
			edge.Transparency = 0.8
			edge.Parent = slab
			fadeY(slab, 0.6, 0.85, 1)
			table.insert(slabs, { f = slab, edge = edge, x = size.X * spec[1] })
		end
	end
	local dust = {}
	for _ = 1, 30 do
		local d = frame(root, Vector2.new(1, 1), color, 0.6)
		table.insert(dust, { f = d, x = random:NextNumber() * 900, y = random:NextNumber() * 700, vx = (random:NextNumber() - 0.5) * 6, vy = -2 - random:NextNumber() * 4 })
	end
	local function makeBeam(tint: Color3, peak: number): (Frame, UIGradient)
		local beam = Instance.new("Frame")
		beam.AnchorPoint = Vector2.new(0.5, 0.5)
		beam.BorderSizePixel = 0
		beam.BackgroundColor3 = tint
		beam.Size = UDim2.new(0, 220, 3, 0)
		beam.Rotation = 16
		beam.Parent = root
		local fade = Instance.new("UIGradient")
		fade.Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 1),
			NumberSequenceKeypoint.new(0.5, peak),
			NumberSequenceKeypoint.new(1, 1),
		})
		fade.Parent = beam
		return beam, fade
	end
	local beam = makeBeam(color, 0.9)
	--[[
		Beams a click sets off. Each starts under the pointer and carries on
		across on its own, so the steady beam is never pulled back and a second
		click never restarts the first -- they overlap and each runs out.
	]]
	local extra: { { f: Frame, g: UIGradient, x: number, life: number } } = {}
	local travel = 0
	local boost = 0
	local span = 1
	local SPEED = 1 / 11 -- of the span, per second
	return {
		step = function(dt, size)
			if (size - built).Magnitude > 40 then
				build(size)
			end
			boost = math.max(0, boost - dt * 0.8)
			travel += dt * (1 + boost * 3)
			span = size.X + 520
			local t = (travel % 11) / 11
			local beamX = -260 + t * span
			beam.Position = UDim2.fromOffset(beamX, size.Y / 2)
			local xs = { beamX }
			for index = #extra, 1, -1 do
				local b = extra[index]
				b.life += dt
				b.x += span * SPEED * (1 + boost * 3) * dt
				if b.x > size.X + 260 then
					b.f:Destroy()
					table.remove(extra, index)
				else
					b.f.Position = UDim2.fromOffset(b.x, size.Y / 2)
					-- Swells in over the first moment instead of appearing.
					local grow = math.clamp(b.life / 0.35, 0, 1)
					local peak = 1 - grow * 0.14
					b.g.Transparency = NumberSequence.new({
						NumberSequenceKeypoint.new(0, 1),
						NumberSequenceKeypoint.new(0.5, peak),
						NumberSequenceKeypoint.new(1, 1),
					})
					table.insert(xs, b.x)
				end
			end
			local function nearest(x: number, reach: number): number
				local best = 0
				for _, bx in xs do
					best = math.max(best, 1 - math.abs(x - bx) / reach)
				end
				return math.clamp(best, 0, 1)
			end
			-- What a beam passes over catches its light.
			for _, c in columns do
				c.f.BackgroundTransparency = 0.96 - nearest(c.x, 140) * 0.2
			end
			for _, s in slabs do
				s.edge.Transparency = 0.8 - nearest(s.x, 160) * 0.55
			end
			for _, d in dust do
				d.x += d.vx * dt
				d.y += d.vy * dt
				if d.y < -4 then
					d.y = size.Y + 4
					d.x = random:NextNumber() * size.X
				end
				d.f.Position = UDim2.fromOffset(d.x, d.y)
				d.f.BackgroundTransparency = 0.75 - nearest(d.x, 120) * 0.5
			end
		end,
		pulse = function(_tint)
			boost = 1
		end,
		click = function(x, _y, _tint)
			if #extra >= 6 then
				local oldest = table.remove(extra, 1)
				if oldest then
					oldest.f:Destroy()
				end
			end
			local f, g = makeBeam(color, 1)
			f.Position = UDim2.fromOffset(x, (root.AbsoluteSize.Y) / 2)
			table.insert(extra, { f = f, g = g, x = x, life = 0 })
		end,
	}
end

--[[
	Galaxy: a two-armed spiral seen at a tilt, turning slowly around a bright
	core. Arms are dense ribbons of stars with soft haze along them, a bulge of
	warm stars sits at the centre, and a faint disc fills the space between.

	Over it, an analysis overlay: a graduated dial on a true ellipse turning
	the other way, an inner orbit, and a scan line sweeping round with a marker
	riding the dial, brightening the stars it crosses. A call launches a comet
	out along an arm; a click drops a lock-on reticle that closes onto the
	point and lights the stars around it.
]]
local function galaxy(root: Frame, color: Color3): Effect
	local TILT = 0.46
	local PHI = math.rad(-16) -- the disc's angle on screen
	local WIND = 1.9 -- how tightly the arms wind
	local cosP, sinP = math.cos(PHI), math.sin(PHI)
	local warm = Color3.fromRGB(255, 226, 182)
	local violet = Color3.fromRGB(176, 146, 255)
	local white = Color3.fromRGB(255, 250, 240)

	local function gauss(): number
		local a = math.max(random:NextNumber(), 1e-6)
		return math.sqrt(-2 * math.log(a)) * math.cos(2 * math.pi * random:NextNumber())
	end

	-- Disc coordinates (radius, angle) to the screen.
	local cx, cy, R = 450, 300, 260
	local function place(r: number, a: number): (number, number)
		local x, y = r * math.cos(a), r * math.sin(a) * TILT
		return cx + x * cosP - y * sinP, cy + x * sinP + y * cosP
	end

	local field = {}
	for _ = 1, 70 do
		local s = frame(root, Vector2.new(1, 1), Color3.new(1, 1, 1), 0.7)
		s.Position = UDim2.fromScale(random:NextNumber(), random:NextNumber())
		table.insert(field, { f = s, phase = random:NextNumber() * 6.28, speed = 0.4 + random:NextNumber() })
	end

	-- Soft haze along the arms, under the stars.
	local haze = {}
	for i = 1, 40 do
		local arm = i % 2
		local u = 0.12 + random:NextNumber() * 0.85
		local tint = if u > 0.6 then color:Lerp(violet, 0.5) else color
		local blob = frame(root, Vector2.new(10, 10), tint, 0.95)
		round(blob)
		table.insert(haze, {
			f = blob,
			u = u,
			a = arm * math.pi + math.log(u) * WIND + gauss() * 0.06,
			scale = 0.05 + random:NextNumber() * 0.06,
			base = 0.955 + random:NextNumber() * 0.025,
		})
	end

	-- The core: soft concentric glows, cool outside and warm within.
	local core = {}
	for _, spec in {
		{ 0.5, color, 0.975 },
		{ 0.28, color:Lerp(warm, 0.4), 0.95 },
		{ 0.13, warm, 0.85 },
		{ 0.07, warm:Lerp(white, 0.5), 0.5 },
		{ 0.025, white, 0.05 },
	} do
		local glow = frame(root, Vector2.new(10, 10), spec[2], spec[3])
		round(glow)
		table.insert(core, { f = glow, scale = spec[1], base = spec[3] })
	end

	local stars = {}
	local function addStar(u: number, a: number, tint: Color3, base: number, size: number)
		local f = frame(root, Vector2.new(size, size), tint, base)
		if size >= 3 then
			f.Rotation = 45
		end
		table.insert(stars, {
			f = f, u = u, a = a, base = base,
			phase = random:NextNumber() * 6.28,
			flash = 0, x = 0, y = 0,
		})
	end
	-- The arms: dense near their spine, thinning out to the sides.
	for i = 1, 320 do
		local arm = i % 2
		local u = 0.1 + 0.9 * random:NextNumber() ^ 0.85
		local a = arm * math.pi + math.log(u) * WIND + gauss() * 0.13 * (1 - u * 0.3)
		local tint = if u < 0.35 then warm:Lerp(color, (u - 0.1) / 0.25) elseif u > 0.7 then color:Lerp(violet, (u - 0.7) / 0.3) else color
		local roll = random:NextNumber()
		local size = if roll < 0.06 then 3 elseif roll < 0.3 then 2 else 1
		addStar(u * (1 + gauss() * 0.03), a, tint, 0.12 + random:NextNumber() * 0.35, size)
	end
	-- The bulge: warm and crowded round the centre.
	for _ = 1, 45 do
		addStar(math.abs(gauss()) * 0.09, random:NextNumber() * math.pi * 2, warm, 0.2 + random:NextNumber() * 0.4, random:NextInteger(1, 2))
	end
	-- The disc between the arms: sparse and faint.
	for _ = 1, 40 do
		addStar(0.15 + random:NextNumber() * 0.85, random:NextNumber() * math.pi * 2, color, 0.55 + random:NextNumber() * 0.25, 1)
	end

	-- The overlay: true ellipses, drawn as paths and redrawn only on resize.
	local function ring(thickness: number, shade: number): Path2D
		local path = Instance.new("Path2D")
		path.Thickness = thickness
		path.Color3 = color:Lerp(Color3.new(0, 0, 0), shade)
		path.Parent = root
		return path
	end
	local dial = ring(1, 0.55)
	local orbit = ring(1, 0.7)
	local OUTER, INNER = 1.06, 0.58
	local drawnAt = Vector3.zero
	local function drawRings()
		for _, spec in { { dial, OUTER }, { orbit, INNER } } do
			local xs, ys = {}, {}
			for i = 0, 72 do
				local x, y = place(R * spec[2], i / 72 * math.pi * 2)
				table.insert(xs, x)
				table.insert(ys, y)
			end
			curve(spec[1], xs, ys)
		end
	end

	-- Graduations standing across the dial.
	local ticks = {}
	for i = 1, 72 do
		local long = i % 6 == 0
		local t = frame(root, Vector2.new(1, if long then 9 else 4), color, if long then 0.45 else 0.7)
		table.insert(ticks, { f = t, a = (i - 1) / 72 * math.pi * 2 })
	end

	local scan = frame(root, Vector2.new(1, 1), color, 0)
	local scanFade = Instance.new("UIGradient")
	scanFade.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.85),
		NumberSequenceKeypoint.new(1, 0.45),
	})
	scanFade.Parent = scan
	local marker = frame(root, Vector2.new(6, 6), color, 0.1)
	marker.Rotation = 45
	marker.ZIndex = 2
	local markerHalo = frame(root, Vector2.new(18, 18), color, 0.85)
	round(markerHalo)

	local comets = {}
	local locks = {}
	local clock, spin, energy = 0, 0, 0

	return {
		step = function(dt, size)
			clock += dt
			energy = math.max(0, energy - dt * 0.5)
			spin += dt * (0.04 + energy * 0.08)
			cx, cy = size.X * 0.5, size.Y * 0.5
			R = math.min(size.X * 0.4, size.Y * 0.85)

			local at = Vector3.new(cx, cy, R)
			if (at - drawnAt).Magnitude > 1 then
				drawnAt = at
				drawRings()
			end

			for _, s in field do
				s.f.BackgroundTransparency = 0.45 + 0.45 * (0.5 + 0.5 * math.sin(clock * s.speed + s.phase))
			end

			local breathe = 0.5 + 0.5 * math.sin(clock * 0.7)
			for _, c in core do
				local d = R * c.scale * (1 + breathe * 0.04 + energy * 0.1)
				c.f.Size = UDim2.fromOffset(d, d)
				c.f.Position = UDim2.fromOffset(cx, cy)
				c.f.BackgroundTransparency = math.clamp(c.base - energy * 0.04, 0, 1)
			end

			for _, h in haze do
				local x, y = place(h.u * R, h.a + spin)
				local d = R * h.scale
				h.f.Size = UDim2.fromOffset(d, d)
				h.f.Position = UDim2.fromOffset(x, y)
				h.f.BackgroundTransparency = h.base - energy * 0.02
			end

			local scanA = clock * 0.45
			local sx, sy = place(R * OUTER, scanA)
			stretch(scan, cx, cy, sx, sy)
			marker.Position = UDim2.fromOffset(sx, sy)
			markerHalo.Position = marker.Position
			markerHalo.BackgroundTransparency = 0.8 + 0.1 * math.sin(clock * 4)

			for _, s in stars do
				local a = s.a + spin
				local x, y = place(s.u * R, a)
				s.x, s.y = x, y
				s.flash = math.max(0, s.flash - dt * 1.4)
				-- Lit for a moment as the scan line passes over.
				local behind = (scanA - a) % (math.pi * 2)
				local swept = if behind < 0.6 then 1 - behind / 0.6 else 0
				local twinkle = 0.1 * math.sin(clock * 1.5 + s.phase)
				s.f.Position = UDim2.fromOffset(x, y)
				s.f.BackgroundTransparency = math.clamp(s.base + twinkle - swept * 0.35 - s.flash * 0.6, 0, 1)
			end

			for _, t in ticks do
				local a = t.a - spin * 1.5
				local x, y = place(R * OUTER, a)
				local x2, y2 = place(R * OUTER, a + 0.01)
				t.f.Position = UDim2.fromOffset(x, y)
				-- Across the dial: a tall frame turned to the tangent's angle.
				t.f.Rotation = math.deg(math.atan2(y2 - y, x2 - x))
				-- Brighter where the scan marker is.
				local gap = math.abs(((a - scanA + math.pi) % (math.pi * 2)) - math.pi)
				t.f.BackgroundTransparency = math.clamp(0.7 - math.max(0, 1 - gap / 0.5) * 0.5, 0, 1)
			end

			for index = #comets, 1, -1 do
				local c = comets[index]
				c.u += dt * 0.42
				if c.u >= 1.05 then
					for _, d in c.tail do
						d:Destroy()
					end
					table.remove(comets, index)
					continue
				end
				local x, y = place(c.u * R, c.a + spin + math.log(math.max(c.u, 0.05)) * WIND)
				table.insert(c.history, 1, Vector2.new(x, y))
				if #c.history > 12 then
					table.remove(c.history)
				end
				for k, d in c.tail do
					local p = c.history[1 + (k - 1) * 2] or c.history[#c.history]
					d.Position = UDim2.fromOffset(p.X, p.Y)
					d.BackgroundTransparency = math.clamp(0.05 + k * 0.14 + math.max(0, c.u - 0.85) * 4, 0, 1)
				end
			end

			for index = #locks, 1, -1 do
				local l = locks[index]
				l.t += dt
				-- Close in over the first 0.35s, hold, then fade by 1.4s.
				local close = 1 - (1 - math.clamp(l.t / 0.35, 0, 1)) ^ 3
				local half = 46 - close * 32
				local fade = math.clamp((l.t - 0.8) / 0.6, 0, 1)
				if fade >= 1 then
					for _, part in l.parts do
						part:Destroy()
					end
					table.remove(locks, index)
					continue
				end
				for _, corner in l.corners do
					local sxk, syk = corner[1], corner[2]
					local px, py = l.x + sxk * half, l.y + syk * half
					corner[3].Position = UDim2.fromOffset(px - sxk * 4, py)
					corner[4].Position = UDim2.fromOffset(px, py - syk * 4)
					corner[3].BackgroundTransparency = 0.15 + fade * 0.85
					corner[4].BackgroundTransparency = 0.15 + fade * 0.85
				end
				l.ring.Rotation += dt * 120
				l.stroke.Transparency = 0.4 + fade * 0.6
			end
		end,
		pulse = function(tint)
			energy = math.min(1, energy + 0.3)
			if #comets >= 6 then
				return
			end
			local tail = {}
			for k = 1, 5 do
				local d = frame(root, Vector2.new(6 - k, 6 - k), tint, 0.2)
				d.Rotation = 45
				d.ZIndex = 2
				table.insert(tail, d)
			end
			table.insert(comets, { u = 0.06, a = random:NextInteger(0, 1) * math.pi, tail = tail, history = {} })
		end,
		click = function(x, y, tint)
			energy = math.min(1, energy + 0.4)
			for _, s in stars do
				local d = math.sqrt((s.x - x) ^ 2 + (s.y - y) ^ 2)
				if d < 130 then
					s.flash = math.max(s.flash, 1 - d / 130)
				end
			end
			if #locks >= 6 then
				local oldest = table.remove(locks, 1)
				if oldest then
					for _, part in oldest.parts do
						part:Destroy()
					end
				end
			end
			local parts, corners = {}, {}
			for _, sign in { { -1, -1 }, { 1, -1 }, { -1, 1 }, { 1, 1 } } do
				local across = frame(root, Vector2.new(9, 1), tint, 0.15)
				local down = frame(root, Vector2.new(1, 9), tint, 0.15)
				across.ZIndex, down.ZIndex = 3, 3
				table.insert(parts, across)
				table.insert(parts, down)
				table.insert(corners, { sign[1], sign[2], across, down })
			end
			local diamond = frame(root, Vector2.new(14, 14), tint, 1)
			diamond.Position = UDim2.fromOffset(x, y)
			diamond.ZIndex = 3
			local stroke = Instance.new("UIStroke")
			stroke.Color = tint
			stroke.Transparency = 0.4
			stroke.Parent = diamond
			table.insert(parts, diamond)
			table.insert(locks, { x = x, y = y, t = 0, parts = parts, corners = corners, ring = diamond, stroke = stroke })
		end,
	}
end

local EFFECTS: { [string]: (Frame, Color3) -> Effect } = {
	constellation = constellation,
	embers = embers,
	waves = waves,
	galaxy = galaxy,
	aurora = aurora,
	sweep = sweep,
}

local function run()
	if connection ~= nil then
		return
	end
	local acc = 0
	connection = RunService.Heartbeat:Connect(function(dt)
		acc += dt
		if acc < FRAME_TIME then
			return
		end
		local current, root = effect, layer
		if current ~= nil and root ~= nil then
			local size = root.AbsoluteSize
			if size.X > 20 and size.Y > 20 then
				current.step(acc, size)
			end
		end
		acc = 0
	end)
end

local function halt()
	if connection ~= nil then
		connection:Disconnect()
		connection = nil
	end
end

--[[
	Shows effect `kind` in `color`, replacing whatever was there. Called at
	mount and again on every theme switch.
]]
function Backdrop.show(kind: string, color: Color3)
	local parent = host
	if parent == nil then
		return
	end
	if layer ~= nil then
		layer:Destroy()
	end
	local root = Instance.new("Frame")
	root.Name = "Backdrop"
	root.BackgroundTransparency = 1
	root.BorderSizePixel = 0
	root.ClipsDescendants = true
	root.Size = UDim2.fromScale(1, 1)
	root.Visible = enabled
	root.Parent = parent
	layer = root
	local make = EFFECTS[kind] or EFFECTS.constellation
	effect = make(root, color)
	if enabled then
		run()
	end
end

function Backdrop.mount(parent: GuiObject, kind: string, color: Color3)
	local holder = Instance.new("Frame")
	holder.Name = "BackdropHost"
	holder.BackgroundTransparency = 1
	holder.BorderSizePixel = 0
	holder.Size = UDim2.fromScale(1, 1)
	holder.Parent = parent
	host = holder
	Backdrop.show(kind, color)
end

--[[
	A click on the empty background, in screen coordinates. Every theme gets a
	small expanding ring where it landed, then answers in its own way.
]]
function Backdrop.click(position: Vector2, tint: Color3)
	local root, current = layer, effect
	if root == nil or current == nil or not enabled then
		return
	end
	local x = position.X - root.AbsolutePosition.X
	local y = position.Y - root.AbsolutePosition.Y
	local ring = frame(root, Vector2.new(6, 6), tint, 1)
	ring.Position = UDim2.fromOffset(x, y)
	ring.ZIndex = 3
	round(ring)
	local stroke = Instance.new("UIStroke")
	stroke.Color = tint
	stroke.Thickness = 1.5
	stroke.Parent = ring
	local started = os.clock()
	local touch: RBXScriptConnection
	touch = RunService.Heartbeat:Connect(function()
		local t = (os.clock() - started) / 0.6
		if t >= 1 or ring.Parent == nil then
			touch:Disconnect()
			ring:Destroy()
			return
		end
		local d = 6 + (1 - (1 - t) ^ 3) * 70
		ring.Size = UDim2.fromOffset(d, d)
		stroke.Transparency = t
	end)
	if current.click then
		current.click(x, y, tint)
	end
end

function Backdrop.pulse(tint: Color3)
	local current = effect
	if current ~= nil and enabled then
		current.pulse(tint)
	end
end

function Backdrop.setEnabled(value: boolean)
	enabled = value
	if layer ~= nil then
		layer.Visible = value
	end
	if value then
		run()
	else
		halt()
	end
end

function Backdrop.isEnabled(): boolean
	return enabled
end

return Backdrop
