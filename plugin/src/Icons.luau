--!strict
--[[
	The header's icons, drawn as vector paths and animated by re-posing them.

	Path2D draws real curves at any size. Each icon is a set of strokes in a
	16x16 box; a stroke is a list of points with optional Bezier handles. To
	animate, a stroke is re-posed -- rotated, lifted -- and its control points
	written again, which keeps the lines crisp where rotating a frame would not
	(a GuiObject's Rotation does not carry its descendants).
]]

local RunService = game:GetService("RunService")

local Icons = {}

type Pt = { x: number, y: number, ix: number?, iy: number?, ox: number?, oy: number? }
type Stroke = { points: { Pt }, closed: boolean?, group: string? }
type Pose = { angle: number, cx: number, cy: number, dx: number, dy: number }

export type Drawn = {
	kind: string,
	scale: number,
	strokes: { Stroke },
	paths: { Path2D },
	poses: { [string]: Pose },
}

local function rotate(x: number, y: number, pose: Pose): (number, number)
	local a = math.rad(pose.angle)
	local c, s = math.cos(a), math.sin(a)
	local rx, ry = x - pose.cx, y - pose.cy
	return pose.cx + rx * c - ry * s + pose.dx, pose.cy + rx * s + ry * c + pose.dy
end

local function turn(x: number, y: number, pose: Pose): (number, number)
	local a = math.rad(pose.angle)
	local c, s = math.cos(a), math.sin(a)
	return x * c - y * s, x * s + y * c
end

-- A clockwise arc of `sweep` degrees from `from` (screen angles, y down).
local function arc(cx: number, cy: number, r: number, from: number, sweep: number, pieces: number): { Pt }
	local step = math.rad(sweep / pieces)
	local handle = 4 / 3 * math.tan(step / 4) * r
	local points: { Pt } = {}
	for i = 0, pieces do
		local a = math.rad(from) + step * i
		local tx, ty = -math.sin(a), math.cos(a)
		table.insert(points, {
			x = cx + r * math.cos(a),
			y = cy + r * math.sin(a),
			ix = -tx * handle,
			iy = -ty * handle,
			ox = tx * handle,
			oy = ty * handle,
		})
	end
	return points
end

local function line(...: number): { Pt }
	local values = { ... }
	local points: { Pt } = {}
	for i = 1, #values, 2 do
		table.insert(points, { x = values[i], y = values[i + 1] })
	end
	return points
end

-- Reload geometry: an arc open at the upper right, a solid arrowhead on its end.
Icons.RELOAD = { from = -5, sweep = 275, r = 5.6, cx = 8, cy = 8.6 }

local function strokesFor(kind: string): { Stroke }
	if kind == "reconnect" then
		local g = Icons.RELOAD
		local strokes: { Stroke } = { { points = arc(g.cx, g.cy, g.r, g.from, g.sweep, 4), group = "all" } }
		local a = math.rad(g.from + g.sweep)
		local ex, ey = g.cx + g.r * math.cos(a), g.cy + g.r * math.sin(a)
		local tx, ty = -math.sin(a), math.cos(a)
		local nx, ny = -ty, tx
		-- Base centred on the arc's end, tip ahead along its direction.
		local wide, tip = 2.1, 2.4
		table.insert(strokes, {
			points = line(
				ex + nx * wide, ey + ny * wide,
				ex + tx * tip, ey + ty * tip,
				ex - nx * wide, ey - ny * wide
			),
			closed = true,
			group = "all",
		})
		return strokes
	end
	return {
		{ points = line(2.5, 4.5, 13.5, 4.5), group = "lid" },
		{ points = line(6, 4.5, 6, 2.5, 10, 2.5, 10, 4.5), group = "lid" },
		{ points = line(4, 4.5, 4.8, 13.5, 11.2, 13.5, 12, 4.5), group = "body" },
		{ points = line(6.8, 7, 6.8, 11), group = "body" },
		{ points = line(9.2, 7, 9.2, 11), group = "body" },
	}
end

local REST: Pose = { angle = 0, cx = 8, cy = 8, dx = 0, dy = 0 }

local function apply(drawn: Drawn)
	local s = drawn.scale
	for index, stroke in drawn.strokes do
		local pose = drawn.poses[stroke.group or "all"] or REST
		local points = {}
		for _, p in stroke.points do
			local x, y = rotate(p.x, p.y, pose)
			local ix, iy = turn(p.ix or 0, p.iy or 0, pose)
			local ox, oy = turn(p.ox or 0, p.oy or 0, pose)
			table.insert(
				points,
				Path2DControlPoint.new(
					UDim2.fromOffset(x * s, y * s),
					UDim2.fromOffset(ix * s, iy * s),
					UDim2.fromOffset(ox * s, oy * s)
				)
			)
		end
		drawn.paths[index]:SetControlPoints(points)
	end
end

function Icons.draw(parent: GuiObject, kind: string, color: Color3, scale: number?): Drawn
	local s = scale or 1
	local box = Instance.new("Frame")
	box.Name = "Icon"
	box.BackgroundTransparency = 1
	box.AnchorPoint = Vector2.new(0.5, 0.5)
	box.Position = UDim2.fromScale(0.5, 0.5)
	box.Size = UDim2.fromOffset(16 * s, 16 * s)
	box.Parent = parent

	local drawn: Drawn = { kind = kind, scale = s, strokes = strokesFor(kind), paths = {}, poses = {} }
	for _, stroke in drawn.strokes do
		local path = Instance.new("Path2D")
		path.Color3 = color
		path.Thickness = 1.5 * s
		path.Closed = stroke.closed == true
		path.Parent = box
		table.insert(drawn.paths, path)
	end
	apply(drawn)
	return drawn
end

function Icons.setColor(drawn: Drawn, color: Color3)
	for _, path in drawn.paths do
		path.Color3 = color
	end
end

--[[
	Runs `frame(t)` for `seconds`, t going 0 to 1, posing the icon each frame.
	A newer animation on the same icon cancels the one in flight.
]]
local function animate(drawn: Drawn, seconds: number, frame: (number) -> ())
	local token = {}
	;(drawn :: any).running = token
	local started = os.clock()
	local connection: RBXScriptConnection
	connection = RunService.Heartbeat:Connect(function()
		if (drawn :: any).running ~= token then
			connection:Disconnect()
			return
		end
		local t = math.min(1, (os.clock() - started) / seconds)
		frame(t)
		apply(drawn)
		if t >= 1 then
			connection:Disconnect()
		end
	end)
end

local function easeOut(t: number): number
	return 1 - (1 - t) ^ 3
end

local function centre(): Pose
	local g = Icons.RELOAD
	return { angle = 0, cx = g.cx, cy = g.cy, dx = 0, dy = 0 }
end

-- Hover: the reload arrow leans a quarter turn ahead, the bin's lid lifts.
function Icons.hover(drawn: Drawn, on: boolean)
	if drawn.kind == "reconnect" then
		local pose = drawn.poses.all or centre()
		drawn.poses.all = pose
		local from = pose.angle
		local to = if on then 40 else 0
		animate(drawn, 0.25, function(t)
			pose.angle = from + (to - from) * easeOut(t)
		end)
	else
		local lid = drawn.poses.lid or { angle = 0, cx = 2.5, cy = 4.5, dx = 0, dy = 0 }
		drawn.poses.lid = lid
		local fromA, fromY = lid.angle, lid.dy
		local toA, toY = if on then -12 else 0, if on then -1.2 else 0
		animate(drawn, 0.2, function(t)
			local e = easeOut(t)
			lid.angle = fromA + (toA - fromA) * e
			lid.dy = fromY + (toY - fromY) * e
		end)
	end
end

-- Click: the reload arrow spins a full turn; the bin flips its lid and shudders.
function Icons.press(drawn: Drawn)
	if drawn.kind == "reconnect" then
		local pose = drawn.poses.all or centre()
		drawn.poses.all = pose
		local from = pose.angle
		animate(drawn, 0.6, function(t)
			pose.angle = from + 360 * easeOut(t)
			if t >= 1 then
				pose.angle = from
			end
		end)
	else
		local lid = drawn.poses.lid or { angle = 0, cx = 2.5, cy = 4.5, dx = 0, dy = 0 }
		local body = drawn.poses.body or { angle = 0, cx = 8, cy = 13.5, dx = 0, dy = 0 }
		drawn.poses.lid, drawn.poses.body = lid, body
		animate(drawn, 0.45, function(t)
			-- Lid snaps open then drops shut; the body rocks twice.
			local open = math.sin(math.min(t * 2, 1) * math.pi)
			lid.angle = -28 * open
			lid.dy = -2 * open
			body.angle = 7 * math.sin(t * math.pi * 4) * (1 - t)
		end)
	end
end

return Icons
