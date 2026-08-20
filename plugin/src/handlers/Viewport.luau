--!strict
--[[
	The viewport and the selection -- what the user is pointing at, and what they
	have highlighted.

	Selection is the counterpart to `studio_status`, which reports it: this sets
	it. Selecting what a tool just built is the cheapest way to show someone the
	result of a change, and it puts the instance in reach of Studio's own move
	and scale handles.

	Raycasting answers "what is under this point in the 3D view", which is
	otherwise unanswerable: an agent can enumerate the data model but has no way
	to know what occupies a piece of space.
]]

local RunService = game:GetService("RunService")
local Selection = game:GetService("Selection")
local Workspace = game:GetService("Workspace")

local Dispatch = require(script.Parent.Parent.Dispatch)
local Paths = require(script.Parent.Parent.Paths)
local Serialize = require(script.Parent.Parent.Serialize)

local MAX_SELECTION = 200
local DEFAULT_RAY_LENGTH = 1000

local Viewport = {}

--[[
	Whether moving the camera in this session would change what anyone sees.

	A playtest server has a `CurrentCamera` and accepts every write to it, and
	renders nothing -- the picture on screen comes from the playtest's client. So
	framing a subject here succeeds, reports a plausible camera position, and
	moves no camera the user has. Measured: `focus` against a playtest server
	returned a full result for a shot nobody could ever see.
]]
local function rendersToScreen(): boolean
	return not (RunService:IsRunning() and RunService:IsServer())
end


local function toVector(value: any, label: string): Vector3
	local ok, parsed = Serialize.parse(value, "Vector3")
	if not ok or typeof(parsed) ~= "Vector3" then
		Dispatch.fail(
			"BAD_PARAMS",
			string.format('%s must be three numbers, e.g. "0, 50, 0".', label)
		)
	end
	return parsed :: Vector3
end

--[[
	Casts a ray through the world and reports the first thing it hits.

	`Workspace:Raycast`, not `StudioService:GizmoRaycast`. The latter reads like
	the Studio-aware choice and is not: measured against a place with parts under
	the ray, it returns nil every time. It picks Studio's own gizmos and
	adornments, not world geometry.
]]
function Viewport.raycast(params: { [string]: any }): { [string]: any }
	local origin = toVector(params.origin, "origin")
	local direction = toVector(params.direction, "direction")
	local length = tonumber(params.maxDistance) or DEFAULT_RAY_LENGTH

	local filter: { Instance } = {}
	for _, path in (params.ignore or {}) :: { string } do
		table.insert(filter, Paths.resolve(path))
	end

	local config = RaycastParams.new()
	config.FilterType = Enum.RaycastFilterType.Exclude
	config.FilterDescendantsInstances = filter

	local ok, result = pcall(function()
		return Workspace:Raycast(origin, direction.Unit * length, config)
	end)

	if not ok or result == nil then
		return { hit = false, origin = Serialize.value(origin), direction = Serialize.value(direction.Unit) }
	end

	local cast = result :: RaycastResult
	return {
		hit = true,
		path = if cast.Instance then Paths.of(cast.Instance) else nil,
		className = if cast.Instance then cast.Instance.ClassName else nil,
		position = Serialize.value(cast.Position),
		normal = Serialize.value(cast.Normal),
		distance = math.floor(cast.Distance * 1000 + 0.5) / 1000,
		material = Serialize.value(cast.Material),
	}
end

--[[
	Sets, extends or shrinks the Studio selection.
]]
function Viewport.select(params: { [string]: any }): { [string]: any }
	local paths = params.paths
	if typeof(paths) ~= "table" then
		Dispatch.fail("BAD_PARAMS", "select requires a `paths` array.")
	end
	if #paths > MAX_SELECTION then
		Dispatch.fail(
			"TOO_MANY",
			string.format("%d paths, over the %d selection limit.", #paths, MAX_SELECTION)
		)
	end

	local instances: { Instance } = {}
	for _, path in paths :: { string } do
		table.insert(instances, Paths.resolve(path))
	end

	local mode = params.mode or "set"
	if mode == "add" then
		Selection:Add(instances)
	elseif mode == "remove" then
		Selection:Remove(instances)
	else
		Selection:Set(instances)
	end

	local current: { { [string]: any } } = {}
	local memo: Paths.NameIndex = {}
	for index, instance in Selection:Get() do
		if index > MAX_SELECTION then
			break
		end
		table.insert(current, { path = Paths.of(instance, memo), className = instance.ClassName })
	end

	return { items = current, count = #Selection:Get() }
end

--[[
	The world-space box an instance occupies.

	A Model knows its own extents; a lone part has to be measured from its size
	and orientation. Anything else -- a Folder, a Script -- has no position at
	all, and saying so is better than framing the origin and returning a picture
	of empty ground.
]]
local function extentsOf(instance: Instance): (Vector3, Vector3)
	if instance:IsA("Model") then
		local cframe, size = (instance :: Model):GetBoundingBox()
		return cframe.Position, size
	end
	if instance:IsA("BasePart") then
		local part = instance :: BasePart
		return part.Position, part.Size
	end

	-- A container is worth framing if anything inside it has a position.
	local minimum: Vector3? = nil
	local maximum: Vector3? = nil
	for _, descendant in instance:GetDescendants() do
		if descendant:IsA("BasePart") then
			local part = descendant :: BasePart
			local half = part.Size / 2
			minimum = if minimum == nil then part.Position - half else (minimum :: Vector3):Min(part.Position - half)
			maximum = if maximum == nil then part.Position + half else (maximum :: Vector3):Max(part.Position + half)
		end
	end
	if minimum == nil or maximum == nil then
		Dispatch.fail(
			"NOT_POSITIONED",
			string.format("%s is a %s and occupies no space in the world.", instance:GetFullName(), instance.ClassName),
			"Frame something with geometry -- a part, a model, or a folder containing them."
		)
	end
	local low, high = minimum :: Vector3, maximum :: Vector3
	return (low + high) / 2, high - low
end

--[[
	Points the Studio camera at something, framed so all of it is on screen.

	This is what makes `screenshot` worth having. A picture of wherever the user
	last left their camera answers nothing; a picture of the thing just built
	answers "does it look right", which the data model cannot.

	The distance is computed from the subject's size and the camera's own field
	of view rather than guessed, so a doorway and a whole map both arrive filling
	a similar share of the frame.
]]
function Viewport.focus(params: { [string]: any }): { [string]: any }
	if not rendersToScreen() then
		Dispatch.fail(
			"NOT_RENDERED",
			"This is the playtest's server session, which draws nothing -- moving its "
				.. "camera would change no picture anybody sees.",
			"Address the editor session (see `list_studios`), or stop the playtest first."
		)
	end
	local camera = Workspace.CurrentCamera
	if camera == nil then
		Dispatch.fail("NO_CAMERA", "This session has no camera.")
	end

	local centre: Vector3
	local size: Vector3
	if typeof(params.path) == "string" and params.path ~= "" then
		centre, size = extentsOf(Paths.resolve(params.path))
	else
		centre = toVector(params.at, "`at`")
		size = Vector3.new(10, 10, 10)
	end

	--[[
		Half the diagonal, not half the width: a wall seen from an angle presents
		its diagonal, and framing to the width alone crops the corners off
		exactly the shapes most worth looking at.
	]]
	local radius = math.max(size.Magnitude / 2, 1)
	local fov = math.rad((camera :: Camera).FieldOfView)
	local distance = (radius / math.tan(fov / 2)) * (tonumber(params.padding) or 1.5)

	-- Down the -Z axis and slightly above by default, which is how a person
	-- would stand to look at something: face on, a little raised, never level
	-- with a flat surface where it would vanish to a line.
	local direction: Vector3
	if typeof(params.from) == "string" and params.from ~= "" then
		direction = toVector(params.from, "`from`").Unit
	else
		direction = Vector3.new(0.45, 0.35, 1).Unit
	end

	local eye = centre + direction * distance
	;(camera :: Camera).CFrame = CFrame.lookAt(eye, centre)
	--[[
		`Focus` is not optional here, and leaving it out is a silent failure.

		Studio's edit camera orbits around Focus and re-derives its heading from
		it every frame. Setting CFrame alone applies -- and is then thrown away
		about a fifth of a second later, keeping the new position and restoring
		the old rotation. Measured: the look vector read back correct
		immediately, and had reverted to the previous heading by the next check,
		so the camera moved to the right place and pointed the wrong way, and a
		screenshot came back showing empty ground.
	]]
	;(camera :: Camera).Focus = CFrame.new(centre)

	return {
		focused = if typeof(params.path) == "string" then params.path else tostring(centre),
		cameraPosition = tostring(eye),
		lookingAt = tostring(centre),
		distance = math.floor(distance * 10 + 0.5) / 10,
		subjectSize = tostring(size),
	}
end

--[[
	Reads or sets the camera directly, for the cases framing cannot express --
	standing inside a room, or matching a specific shot.
]]
function Viewport.camera(params: { [string]: any }): { [string]: any }
	if not rendersToScreen() then
		Dispatch.fail(
			"NOT_RENDERED",
			"This is the playtest's server session, which draws nothing -- moving its "
				.. "camera would change no picture anybody sees.",
			"Address the editor session (see `list_studios`), or stop the playtest first."
		)
	end
	local camera = Workspace.CurrentCamera
	if camera == nil then
		Dispatch.fail("NO_CAMERA", "This session has no camera.")
	end
	local view = camera :: Camera

	if params.position ~= nil then
		local eye = toVector(params.position, "`position`")
		local target = if params.lookAt ~= nil
			then toVector(params.lookAt, "`lookAt`")
			else eye + view.CFrame.LookVector
		view.CFrame = CFrame.lookAt(eye, target)
		-- Same reason as focus: without this the rotation survives a frame.
		view.Focus = CFrame.new(target)
	end
	if tonumber(params.fieldOfView) ~= nil then
		view.FieldOfView = math.clamp(tonumber(params.fieldOfView) :: number, 1, 120)
	end

	return {
		position = tostring(view.CFrame.Position),
		lookVector = tostring(view.CFrame.LookVector),
		fieldOfView = view.FieldOfView,
	}
end

function Viewport.register()
	Dispatch.registerAll("viewport", {
		raycast = Viewport.raycast,
		select = Viewport.select,
		focus = Viewport.focus,
		camera = Viewport.camera,
	})
end

return Viewport
