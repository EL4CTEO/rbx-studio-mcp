--!strict
--[[
	3D generation: prompt to model, and cutting a mesh into named parts.

	`GenerationService` is Roblox's Cube model. `GenerateModelAsync` is the one
	to use -- `GenerateMeshAsync`, the older single-mesh call, is marked for
	removal and is not exposed here.

	Two things about it are easy to get wrong from the outside:

	1. The **schema** is not decoration. It decides how the result is split. A
	   `Body1` generation is one MeshPart and cannot be articulated; `Car5`
	   returns a body and four wheels under known names, which is what makes a
	   retargetable driving script able to find the wheels. Asking for "a car"
	   under `Body1` gives a car-shaped rock.
	2. It is **slow and metered**. Tens of seconds is normal, and the service
	   rejects prompts on moderation and rate limits its own throughput. Those
	   arrive as thrown strings, so every call here is wrapped and the reason is
	   handed back as a hint rather than a stack trace.

	Generation happens *before* the undo recording opens. The call yields for a
	long time and a ChangeHistoryService recording held open across it would sit
	over the user's Studio for the whole wait; nothing is in the data model
	until the model is parented, so there is nothing to protect until then.
]]

local Dispatch = require(script.Parent.Parent.Dispatch)
local Paths = require(script.Parent.Parent.Paths)
local Undo = require(script.Parent.Parent.Undo)

local Generate = {}

-- Names the engine accepts for `PredefinedSchema`, lowercased for matching.
local PREDEFINED: { [string]: string } = {
	car5 = "Car5",
	body1 = "Body1",
}

--[[
	Turns whatever the service threw into something an agent can act on.

	The service reports content and quota problems as plain strings, and they are
	the two failures a caller can actually do something about -- reword, or wait.
	Everything else is passed through unchanged rather than guessed at.
]]
local function hintFor(reason: string): string?
	local lower = string.lower(reason)
	if string.find(lower, "moderat") then
		return "The prompt was rejected by moderation. Rewrite it and try again."
	elseif string.find(lower, "rate limit") or string.find(lower, "overload") then
		return "The service is rate limited or busy. Wait a moment and retry."
	elseif string.find(lower, "character limit") then
		return "The prompt is too long. Shorten it."
	elseif string.find(lower, "timeout") or string.find(lower, "timed out") then
		return "Generation took longer than the service allows. Try a simpler prompt."
	end
	return nil
end

--[[
	Appearance carried from a source MeshPart onto the pieces cut out of it.

	`TextureContent` is the one that matters and the reason this list exists:
	segmentation returns bare geometry, so a textured chest came back as a
	flat grey chest -- the right shape, visibly wrong, and the sort of thing a
	caller then has to notice and repair by hand. The mesh's UVs survive the
	cut, so re-pointing each piece at the original texture maps correctly.
]]
local CARRIED = {
	"TextureContent", "Color", "Material", "MaterialVariant", "Reflectance",
	"Transparency", "CastShadow", "DoubleSided", "CanCollide", "CanTouch",
	"CanQuery", "CollisionGroup",
}

--[[
	Guarded per property: the pieces and the source are both MeshParts today,
	but a property one of them loses in a future engine version should cost that
	property rather than the whole segmentation.
]]
local function carryLook(source: MeshPart, model: Model)
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("MeshPart") then
			for _, property in CARRIED do
				pcall(function()
					(descendant :: any)[property] = (source :: any)[property]
				end)
			end
		end
	end
end

local function parseVector(text: any): Vector3?
	if typeof(text) ~= "string" or text == "" then
		return nil
	end
	local x, y, z = string.match(text, "^%s*(-?[%d%.]+)%s*,%s*(-?[%d%.]+)%s*,%s*(-?[%d%.]+)%s*$")
	if x == nil then
		return nil
	end
	return Vector3.new(tonumber(x) :: number, tonumber(y) :: number, tonumber(z) :: number)
end

local function service(): any
	local ok, found = pcall(function()
		return game:GetService("GenerationService")
	end)
	if not ok or found == nil then
		Dispatch.fail(
			"NO_GENERATION",
			"This Studio build has no GenerationService.",
			"3D generation needs a current Studio. Update Studio and retry."
		)
	end
	return found
end

--[[
	Builds the `schema` argument, which takes exactly one key.

	`groups` wins when both are given, because naming parts is the more specific
	request: a caller who lists group names has a structure in mind that no
	predefined schema is going to match.
]]
local function buildSchema(params: { [string]: any }): ({ [string]: any }, string)
	local groups = params.groups
	if typeof(groups) == "table" and #(groups :: { any }) > 0 then
		local names: { string } = {}
		for _, name in groups :: { any } do
			if typeof(name) == "string" and name ~= "" then
				table.insert(names, name)
			end
		end
		if #names == 0 then
			Dispatch.fail("BAD_PARAMS", "`groups` was given but held no usable names.")
		end
		return { SchemaDefinition = { Groups = names } }, string.format("%d custom group(s)", #names)
	end

	local asked = string.lower(tostring(params.schema or "Body1"))
	local predefined = PREDEFINED[asked]
	if predefined == nil then
		Dispatch.fail(
			"BAD_PARAMS",
			string.format("unknown schema %q", tostring(params.schema)),
			'Use "Body1", "Car5", or pass `groups` to name the parts yourself.'
		)
	end
	return { PredefinedSchema = predefined }, predefined
end

--[[
	Parents, names, scales and places a freshly generated model.

	Scaling happens before the pivot so the pivot lands where the caller asked
	rather than where the unscaled model's centre happened to be. Anchoring is
	on by default: the generated parts arrive unanchored and a multi-part result
	dropped into an edit-mode workspace otherwise sags apart the moment physics
	steps.
]]
local function place(model: Model, params: { [string]: any }): { [string]: any }
	local parent = if typeof(params.parent) == "string" and params.parent ~= ""
		then Paths.resolve(params.parent)
		else workspace

	local target = tonumber(params.scaleTo)
	local position = parseVector(params.position)
	local anchor = params.anchor ~= false

	local path = ""
	local parts: { string } = {}

	local _, undoable = Undo.record("MCPGenerate", "MCP generate", function()
		if typeof(params.name) == "string" and params.name ~= "" then
			model.Name = params.name
		end

		if target and target > 0 then
			local extents = model:GetExtentsSize()
			local largest = math.max(extents.X, extents.Y, extents.Z)
			if largest > 0 then
				model:ScaleTo(target / largest)
			end
		end

		for _, descendant in model:GetDescendants() do
			if descendant:IsA("BasePart") then
				if anchor then
					(descendant :: BasePart).Anchored = true
				end
				if #parts < 40 then
					table.insert(parts, descendant.Name)
				end
			end
		end

		model.Parent = parent

		if position then
			-- After parenting, so the pivot is settled.
			pcall(function()
				model:PivotTo(CFrame.new(position :: Vector3))
			end)
		end

		path = Paths.of(model)
	end)

	local extents = model:GetExtentsSize()
	return {
		path = path,
		parts = parts,
		size = string.format("%.1f, %.1f, %.1f", extents.X, extents.Y, extents.Z),
		anchored = anchor,
		undoable = undoable,
	}
end

--[[
	Prompt (and/or reference image) to a model.
]]
function Generate.model(params: { [string]: any }): { [string]: any }
	local prompt = if typeof(params.prompt) == "string" then params.prompt else ""
	local imageId = tonumber(params.imageAssetId)
	if prompt == "" and (imageId == nil or imageId <= 0) then
		Dispatch.fail("BAD_PARAMS", "generate needs a `prompt`, an `imageAssetId`, or both.")
	end

	local inputs: { [string]: any } = {}
	if prompt ~= "" then
		inputs.TextPrompt = prompt
	end
	if imageId and imageId > 0 then
		local okImage, content = pcall(function()
			return (Content :: any).fromAssetId(imageId)
		end)
		if not okImage then
			Dispatch.fail(
				"BAD_PARAMS",
				string.format("Could not reference image asset %d.", imageId),
				"Pass the numeric id of an image asset you own."
			)
		end
		inputs.Image = content
	end

	local size = parseVector(params.size)
	if size then
		inputs.Size = size
	end
	local triangles = tonumber(params.maxTriangles)
	if triangles and triangles > 0 then
		inputs.MaxTriangles = math.floor(triangles)
	end
	if params.textures == false then
		inputs.GenerateTextures = false
	end

	local schema, described = buildSchema(params)

	local ok, result, metadata = pcall(function()
		return service():GenerateModelAsync(inputs, schema)
	end)
	if not ok then
		local reason = tostring(result)
		Dispatch.fail("GENERATE_FAILED", string.format("Generation refused: %s", reason), hintFor(reason))
	end
	if typeof(result) ~= "Instance" or not (result :: Instance):IsA("Model") then
		Dispatch.fail(
			"GENERATE_FAILED",
			string.format("Generation returned a %s, not a Model.", typeof(result)),
			"Nothing was added to the place."
		)
	end

	local report = place(result :: Model, params)
	report.schema = described
	report.prompt = if prompt ~= "" then prompt else nil
	report.uuid = if typeof(metadata) == "table" then tostring((metadata :: any).UUID or "") else nil
	return report
end

--[[
	Cuts an existing MeshPart into the parts a schema names.

	This is the half of the service that has nothing to do with prompting: it
	takes geometry that already exists -- an imported mesh, or an earlier `Body1`
	generation -- and splits it. That is how a single-mesh car becomes a car with
	four wheels that can turn.

	Studio only. The engine refuses it at runtime, and refuses a published mesh
	the signed-in user has no edit permission for.
]]
function Generate.segment(params: { [string]: any }): { [string]: any }
	local path = tostring(params.path or "")
	if path == "" then
		Dispatch.fail("BAD_PARAMS", "segment needs a `path` to a MeshPart.")
	end
	local instance = Paths.resolve(path)
	if not instance:IsA("MeshPart") then
		Dispatch.fail(
			"NOT_A_MESH",
			string.format("%s is a %s, not a MeshPart.", path, instance.ClassName),
			"Only MeshParts can be segmented. Generate one first, or import a mesh."
		)
	end

	local schema, described = buildSchema(params)

	local ok, result, metadata = pcall(function()
		return service():SegmentMeshAsync(instance :: MeshPart, schema)
	end)
	if not ok then
		local reason = tostring(result)
		Dispatch.fail(
			"SEGMENT_FAILED",
			string.format("Segmentation refused: %s", reason),
			hintFor(reason)
				or "Segmenting needs edit permission on the mesh asset, and only works in Studio."
		)
	end
	if typeof(result) ~= "Instance" or not (result :: Instance):IsA("Model") then
		Dispatch.fail(
			"SEGMENT_FAILED",
			string.format("Segmentation returned a %s, not a Model.", typeof(result)),
			"The original mesh is untouched."
		)
	end

	local source = instance :: MeshPart
	carryLook(source, result :: Model)

	--[[
		Land where the original stood, and default to its parent, so a segmented
		mesh replaces the thing it came from instead of appearing at the origin.
		Read before anything is parented or destroyed, because both change what
		these answers would be.
	]]
	if params.parent == nil and source.Parent then
		params.parent = Paths.of(source.Parent)
	end
	if params.position == nil then
		local at = source.Position
		params.position = string.format("%f, %f, %f", at.X, at.Y, at.Z)
	end
	if params.name == nil then
		params.name = source.Name .. "_Segmented"
	end
	if params.scaleTo == nil then
		--[[
			Segmentation hands back the mesh at its own native scale, not at the
			size the MeshPart was displayed at. Measured: a crate shown as 6 x
			3.3 x 4.1 studs came back as 1.9 x 1.1 x 1.3 -- the same shape, a
			third the size, sitting where the original was. Since the point of
			this op is to replace a part with an articulated version of itself,
			the size it was on screen is the size to keep.
		]]
		local extents = source.Size
		params.scaleTo = math.max(extents.X, extents.Y, extents.Z)
	end

	local report = place(result :: Model, params)
	report.schema = described
	report.uuid = if typeof(metadata) == "table" then tostring((metadata :: any).UUID or "") else nil

	if params.keepOriginal ~= true then
		local removed = Paths.of(source)
		local _, dropped = Undo.record("MCPSegmentCleanup", "MCP segment cleanup", function()
			source:Destroy()
		end)
		report.removed = removed
		-- Two recordings, so two Ctrl+Z. Said plainly rather than claimed as one.
		report.undoable = report.undoable == true and dropped
		report.steps = 2
	end

	return report
end

function Generate.register()
	Dispatch.registerAll("generate", {
		model = Generate.model,
		segment = Generate.segment,
	})
end

return Generate
