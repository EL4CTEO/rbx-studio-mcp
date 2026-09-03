--!strict
--[[
	Nebula -- the pink one, and the only preset with no straight lines.

	Soft blobs advected by a slow flow field, magenta through cyan. Every other
	theme in the set draws edges, points or bars; this one draws nothing with a
	corner in it, which is what makes it read as a different instrument rather
	than as the same instrument recoloured.

	The flow is a pair of sines sampled at each blob's position -- cheap, and
	continuous, so neighbouring blobs drift in similar directions and the field
	holds together instead of scattering. Blobs that leave the cell wrap back to
	the far side rather than being respawned, so the field never thins out.

	A reply blooms rather than flashes: the blobs swell and brighten over the
	third of a second `flare` lasts. On a strip this small a hard flash reads as
	a rendering fault; a bloom reads as something arriving.
]]

local Draw = require(script.Parent.Draw)
local Theme = require(script.Parent.Theme)

local BLOBS = 20

local Nebula = {}

Nebula.id = "nebula"
Nebula.label = "Nebula"
Nebula.blurb = "Drifting dust"

Nebula.palette = {
	background = Color3.fromRGB(19, 11, 24),
	surface = Color3.fromRGB(30, 18, 38),
	rule = Color3.fromRGB(236, 122, 196),
	text = Color3.fromRGB(238, 214, 236),
	dim = Color3.fromRGB(122, 96, 128),
	green = Color3.fromRGB(142, 230, 196),
	red = Color3.fromRGB(255, 122, 148),
	amber = Color3.fromRGB(250, 190, 140),
	cyan = Color3.fromRGB(134, 226, 240),
	violet = Color3.fromRGB(226, 140, 236),
}

type Blob = {
	frame: Frame,
	position: Vector2,
	-- Fixed per blob: size, how much of the magenta-to-cyan range it sits at,
	-- and its own drift phase.
	scale: number,
	hue: number,
	phase: number,
}

local blobs: { Blob } = {}
local size = 40

--[[
	The flow field. Two sines crossed, which is enough structure to look like a
	current and cheap enough to sample forty times a frame.

	Time enters slowly. A field that changes as fast as the things moving
	through it reads as noise; at this rate the current itself visibly turns
	over about a minute, under blobs that take a few seconds to cross.
]]
local function flow(at: Vector2, clock: number): Vector2
	local x = math.sin(at.Y * 0.16 + clock * 0.21)
	local y = math.cos(at.X * 0.14 - clock * 0.17)
	return Vector2.new(x, y)
end

function Nebula.mount(cell: Frame)
	size = cell.AbsoluteSize.X
	if size < 8 then
		size = 40
	end
	local frames = Draw.pool(cell, BLOBS, "Blob", true)
	blobs = {}
	for index = 1, BLOBS do
		blobs[index] = {
			frame = frames[index],
			position = Vector2.new(Draw.hash(index, 21) * size, Draw.hash(index, 22) * size),
			scale = 0.4 + Draw.hash(index, 23) * 1.6,
			hue = Draw.hash(index, 24),
			phase = Draw.hash(index, 25) * math.pi * 2,
		}
	end
end

function Nebula.unmount()
	blobs = {}
end

function Nebula.paint(ctx: Theme.Context, delta: number)
	-- Clamped because Studio hands out long frames while it compiles, and an
	-- unclamped step teleports the whole field across the cell in one of them.
	local step = math.min(delta, 1 / 30)
	local drift = 6 + ctx.energy * 22

	for index = 1, #blobs do
		local blob = blobs[index]
		blob.position += flow(blob.position, ctx.clock + blob.phase) * drift * step

		-- Wrapped rather than respawned. A blob that reappears at a random point
		-- pops; one that comes back around the far edge is simply still moving.
		local margin = 6
		if blob.position.X < -margin then
			blob.position = Vector2.new(size + margin, blob.position.Y)
		elseif blob.position.X > size + margin then
			blob.position = Vector2.new(-margin, blob.position.Y)
		end
		if blob.position.Y < -margin then
			blob.position = Vector2.new(blob.position.X, size + margin)
		elseif blob.position.Y > size + margin then
			blob.position = Vector2.new(blob.position.X, -margin)
		end

		--[[
			Breathing on the blob's own phase, so the cloud is never uniform.
			The bloom on top of it is shared, which is what makes a reply read as
			one event happening to the whole field rather than as twenty
			independent flickers.
		]]
		local breathe = 0.85 + 0.15 * math.sin(ctx.clock * 0.8 + blob.phase)
		local diameter = math.max(
			2,
			math.floor(blob.scale * 5 * breathe * ctx.scale + ctx.flare * 4)
		)

		local colour = ctx.palette.violet:Lerp(ctx.palette.cyan, blob.hue)
		Draw.dot(
			blob.frame,
			blob.position,
			diameter,
			colour:Lerp(Color3.new(1, 1, 1), ctx.flare * 0.5),
			--[[
				Deliberately very transparent. Dust is only dust when the blobs
				overlap into something denser than any one of them, and at any
				less than this each blob reads as a discrete circle.
			]]
			math.clamp(0.82 - ctx.energy * 0.12 - ctx.flare * 0.25, 0, 1)
		)
	end
end

--[[
	History as columns of dust lit from below rather than as bars.

	Same data, same heights, but drawn with a rounded cap and no hard baseline,
	so the trace belongs to the same picture as the cell.
]]
function Nebula.paintSlot(slot: Theme.Slot, ctx: Theme.Context)
	local frame = slot.frame
	local recency = 1 - slot.age
	local height = math.max(2, math.floor(2 + slot.weight * 20))

	frame.AnchorPoint = Vector2.new(0.5, 1)
	frame.Size = UDim2.fromOffset(3, height)
	frame.Position = UDim2.new(frame.Position.X.Scale, frame.Position.X.Offset, 1, 0)
	frame.BackgroundColor3 = if slot.ok
		then ctx.palette.violet:Lerp(ctx.palette.cyan, slot.weight)
		else ctx.palette.red
	frame.BackgroundTransparency = math.clamp(0.72 - recency * 0.6, 0, 1)
	frame.Rotation = 0
end

function Nebula.swatch(frame: Frame, palette: Theme.Palette)
	local pool = Draw.pool(frame, 12, "Blob", true)
	for index = 1, 12 do
		local x = 4 + Draw.hash(index, 31) * 32
		local y = 3 + Draw.hash(index, 32) * 18
		local hue = Draw.hash(index, 33)
		Draw.dot(
			pool[index],
			Vector2.new(x, y),
			4 + math.floor(Draw.hash(index, 34) * 6),
			palette.violet:Lerp(palette.cyan, hue),
			0.7
		)
	end
end

return Nebula
