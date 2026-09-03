--!strict
--[[
	Drawing primitives shared by the presets.

	Roblox has no line primitive and no point primitive, so both are Frames --
	a segment is a thin rectangle turned about its midpoint, a point is a small
	square with a full corner radius. Every preset that draws either would
	otherwise carry its own copy, and they did not stay identical: the pooling
	rule (build once in `mount`, never allocate in `paint`) is easy to state and
	easy to forget, so it lives here where forgetting it is not an option.
]]

local Draw = {}

--[[
	Turns a point about all three axes.

	Applied X, then Y, then Z. The order is arbitrary but must not change: the
	presets were tuned against this one, and swapping it silently re-aims every
	spin axis in the project.
]]
function Draw.rotate(point: Vector3, angle: Vector3): Vector3
	local sinX, cosX = math.sin(angle.X), math.cos(angle.X)
	local sinY, cosY = math.sin(angle.Y), math.cos(angle.Y)
	local sinZ, cosZ = math.sin(angle.Z), math.cos(angle.Z)

	local y1 = point.Y * cosX - point.Z * sinX
	local z1 = point.Y * sinX + point.Z * cosX
	local x2 = point.X * cosY + z1 * sinY
	local z2 = -point.X * sinY + z1 * cosY
	local x3 = x2 * cosZ - y1 * sinZ
	local y3 = x2 * sinZ + y1 * cosZ

	return Vector3.new(x3, y3, z2)
end

--[[
	A perspective divide. Returns the screen point and the depth it came from,
	because depth is what makes a wireframe read as solid -- near edges are
	brighter and thicker because they genuinely are nearer.
]]
function Draw.project(
	turned: Vector3,
	focal: number,
	radius: number,
	centre: Vector2
): (Vector2, number)
	local scale = focal / (focal - turned.Z)
	return centre + Vector2.new(turned.X * scale * radius, turned.Y * scale * radius), turned.Z
end

--[[
	One segment as a rectangle turned about its midpoint. `Rotation` pivots a
	GuiObject around its centre, which is exactly what a segment needs.
]]
function Draw.edge(
	frame: Frame,
	a: Vector2,
	b: Vector2,
	thickness: number,
	color: Color3,
	transparency: number
)
	local delta = b - a
	local length = delta.Magnitude
	if length < 0.5 then
		frame.Visible = false
		return
	end
	frame.Visible = true
	frame.Position = UDim2.fromOffset((a.X + b.X) / 2, (a.Y + b.Y) / 2)
	frame.Size = UDim2.fromOffset(math.ceil(length), thickness)
	frame.Rotation = math.deg(math.atan2(delta.Y, delta.X))
	frame.BackgroundColor3 = color
	frame.BackgroundTransparency = transparency
end

--[[
	A point. Square frames with a full corner radius, so `size` is a diameter.
]]
function Draw.dot(frame: Frame, at: Vector2, size: number, color: Color3, transparency: number)
	frame.Visible = true
	frame.Position = UDim2.fromOffset(at.X, at.Y)
	frame.Size = UDim2.fromOffset(size, size)
	frame.BackgroundColor3 = color
	frame.BackgroundTransparency = transparency
	frame.Rotation = 0
end

--[[
	Builds a pool of centred frames. `round` gives them a full corner radius,
	which is the difference between a point and a tiny square.
]]
function Draw.pool(parent: Instance, count: number, name: string, round: boolean): { Frame }
	local frames: { Frame } = {}
	for index = 1, count do
		local frame = Instance.new("Frame")
		frame.Name = string.format("%s%02d", name, index)
		frame.AnchorPoint = Vector2.new(0.5, 0.5)
		frame.BorderSizePixel = 0
		frame.Visible = false
		frame.Parent = parent
		if round then
			local corner = Instance.new("UICorner")
			corner.CornerRadius = UDim.new(1, 0)
			corner.Parent = frame
		end
		frames[index] = frame
	end
	return frames
end

--[[
	Empties a cell between presets.

	Themes are singletons -- only one is ever mounted -- so `unmount` could just
	destroy the frames it made. It goes through the cell instead so a preset
	that returns early on an error still leaves nothing behind for the next one
	to draw on top of.
]]
function Draw.clear(cell: Frame)
	for _, child in cell:GetChildren() do
		child:Destroy()
	end
end

local function fract(value: number): number
	return value - math.floor(value)
end

--[[
	Deterministic noise for a given index.

	Presets that scatter things -- stars, dust, motes -- must scatter them the
	same way every frame, and `math.random` in a paint loop would make the scene
	boil. Seeding per element and reading a fixed sequence gives a stable
	arrangement that still looks unplanned.

	This was `fract(sin(index * 12.9898 + salt * 78.233) * 43758.5453)`, the
	usual shader one-liner, and it is wrong for the way it is used here. The
	salt only shifts the PHASE of a single sequence, so two draws for the same
	index -- a longitude and a latitude, say -- stay correlated: the points fall
	near a curve instead of filling the space, and at twenty-odd samples two of
	them land almost exactly on top of each other. Measured over 26 points, the
	closest pair sat 0.017 apart on a unit sphere where an even spread gives
	0.6.

	Hoskins' hash mixes the two inputs through each other instead of adding
	them, which decorrelates the draws.
]]
function Draw.hash(index: number, salt: number): number
	local x = fract(index * 0.1031)
	local y = fract(salt * 0.1031)
	local z = fract(index * 0.0973)
	local mixed = x * (y + 33.33) + y * (z + 33.33) + z * (x + 33.33)
	return fract((x + mixed + y + mixed) * (z + mixed))
end

--[[
	The `index`-th of `count` points spread evenly over a unit sphere.

	For a starfield, "unplanned" is not the requirement -- "no visible clumps
	and no visible gaps" is, and no hash gives that. The Fibonacci lattice does:
	walking the golden angle while stepping evenly down the z axis puts the
	points at a measured centroid offset of 0.004 from the origin, against 0.23
	for the hash it replaced, which is the difference between a sky and a smear
	in one corner.
]]
function Draw.sphere(index: number, count: number): Vector3
	local z = 1 - (2 * index - 1) / count
	local radius = math.sqrt(math.max(0, 1 - z * z))
	-- The golden angle. Any other turn per step lines the points up into arms.
	local turn = (index - 1) * math.pi * (3 - math.sqrt(5))
	return Vector3.new(radius * math.cos(turn), radius * math.sin(turn), z)
end

return Draw
