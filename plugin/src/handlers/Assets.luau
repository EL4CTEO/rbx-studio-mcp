--!strict
--[[
	Inserting Creator Store assets into the place.

	The search half of this lives on the server, not here: Node already has
	internet access and Roblox's toolbox endpoints answer unauthenticated, while
	a plugin making outbound HTTP needs the user to grant permission per domain.
	Doing it server-side means search works the moment the server starts, and the
	plugin only ever talks to the one host it already talks to.

	So this file does the half only Studio can do: turn an asset id into real
	instances in the data model, under a recording so one insert is one Ctrl+Z.
]]

local AssetService = game:GetService("AssetService")

local Dispatch = require(script.Parent.Parent.Dispatch)
local Paths = require(script.Parent.Parent.Paths)
local Undo = require(script.Parent.Parent.Undo)

local Assets = {}

--[[
	Counts scripts anywhere inside what was inserted.

	Free models carrying scripts are the oldest hazard on the platform, and the
	agent inserting one has no other way to know. This is reported on every
	insert rather than only when asked, because the caller who most needs to see
	it is the one who did not think to look.
]]
local function countScripts(root: Instance): (number, { string })
	local total = 0
	local names: { string } = {}
	for _, descendant in root:GetDescendants() do
		if descendant:IsA("LuaSourceContainer") then
			total += 1
			if #names < 10 then
				table.insert(names, string.format("%s (%s)", descendant.Name, descendant.ClassName))
			end
		end
	end
	return total, names
end

function Assets.insert(params: { [string]: any }): { [string]: any }
	local assetId = tonumber(params.assetId)
	if assetId == nil or assetId <= 0 then
		Dispatch.fail("BAD_PARAMS", "insert needs a numeric `assetId`.")
	end

	local parent = if typeof(params.parent) == "string" and params.parent ~= ""
		then Paths.resolve(params.parent)
		else workspace

	--[[
		`game:GetObjects`, not `InsertService:LoadAsset`.

		LoadAsset is the documented route and it refuses everything here: every
		public model tried, from several creators, came back "User is not
		authorized to access Asset". It enforces ownership, which makes it useful
		for a game loading its own assets and useless for inserting from the
		Creator Store -- the entire point of this tool.

		GetObjects is the plugin-security path Studio's own toolbox uses, and it
		loaded the same ids without complaint. It returns an array of top-level
		instances rather than a wrapper model, so there is nothing to unwrap.
	]]
	local ok, loaded = pcall(function()
		return game:GetObjects("rbxassetid://" .. assetId)
	end)
	if not ok then
		Dispatch.fail(
			"INSERT_FAILED",
			string.format("Could not load asset %d: %s", assetId, tostring(loaded)),
			"The asset may be private, deleted, or not a model."
		)
	end

	local children = loaded :: { Instance }
	if #children == 0 then
		Dispatch.fail("EMPTY_ASSET", string.format("Asset %d contained nothing.", assetId))
	end

	-- Counted across every root, since an asset can arrive as several instances
	-- and a script hiding in the second one counts exactly as much.
	local scriptCount = 0
	local scriptNames: { string } = {}
	for _, child in children do
		local count, names = countScripts(child)
		scriptCount += count
		for _, name in names do
			if #scriptNames < 10 then
				table.insert(scriptNames, name)
			end
		end
		if child:IsA("LuaSourceContainer") then
			scriptCount += 1
			if #scriptNames < 10 then
				table.insert(scriptNames, string.format("%s (%s)", child.Name, child.ClassName))
			end
		end
	end

	local inserted: { string } = {}
	local _, undoable = Undo.record("MCPInsertAsset", "MCP insert asset", function()
		for _, child in children do
			if typeof(params.name) == "string" and params.name ~= "" and #children == 1 then
				child.Name = params.name
			end
			child.Parent = parent
			table.insert(inserted, Paths.of(child))
		end

		-- Position after parenting, so PrimaryPart and pivot are settled.
		if typeof(params.position) == "string" and params.position ~= "" then
			local x, y, z = string.match(params.position, "^%s*(-?[%d%.]+)%s*,%s*(-?[%d%.]+)%s*,%s*(-?[%d%.]+)%s*$")
			if x then
				local target = CFrame.new(tonumber(x) :: number, tonumber(y) :: number, tonumber(z) :: number)
				for _, child in children do
					pcall(function()
						if child:IsA("Model") then
							(child :: Model):PivotTo(target)
						elseif child:IsA("BasePart") then
							(child :: BasePart).CFrame = target
						end
					end)
				end
			end
		end
	end)

	return {
		inserted = inserted,
		assetId = assetId,
		scriptCount = scriptCount,
		scripts = if scriptCount > 0 then scriptNames else nil,
		undoable = undoable,
	}
end

--[[
	Turns editable mesh and image data into content that replicates.

	Anything built in memory -- a generated mesh, a procedurally written image --
	is backed by an editable object, and editable objects do not replicate. In
	edit mode nothing shows this: the part looks correct and reads correct. Press
	Play and the server has it while every client renders a cyan-and-magenta
	checkerboard, which is the engine's placeholder for content it could not
	send.

	`CreateDataModelContentAsync` is the fix. It bakes the data into static
	content that lives in this DataModel session and replicates normally. It does
	not upload anything and does not touch the user's account -- the result is
	local to the place, and still has to be saved with it.

	Reported per part rather than failing as a batch: one mesh the service
	refuses should not cost the twenty that converted, and a part that needed
	nothing doing should say so rather than look like a failure.
]]
function Assets.bake(params: { [string]: any }): { [string]: any }
	local paths = params.paths
	if typeof(paths) ~= "table" or #(paths :: { any }) == 0 then
		Dispatch.fail("BAD_PARAMS", "bake needs a `paths` list.")
	end

	local targets: { MeshPart } = {}
	for _, path in paths :: { string } do
		local instance = Paths.resolve(path)
		if instance:IsA("MeshPart") then
			table.insert(targets, instance :: MeshPart)
		else
			-- A model is the natural thing to point at after a generation, so
			-- it is walked rather than refused.
			for _, descendant in instance:GetDescendants() do
				if descendant:IsA("MeshPart") then
					table.insert(targets, descendant :: MeshPart)
				end
			end
		end
	end

	if #targets == 0 then
		Dispatch.fail(
			"NOTHING_TO_BAKE",
			"None of those paths held a MeshPart.",
			"Point at a MeshPart, or at a model containing some."
		)
	end

	--[[
		What kind of content this is, which decides whether baking applies.

		`Object` is an EditableMesh or EditableImage and is the only thing the
		service takes. `Uri` is a published asset and already replicates. `None`
		is nothing at all.

		`Opaque` is the interesting one, and the reason this is a three-way
		answer rather than a boolean. It reads like "in memory, so bake it" and
		the service refuses it: "The input content type is not supported by
		AssetService::CreateDataModelContentAsync yet!". Generated meshes are
		Opaque, so pointing this at a generation used to produce that engine
		message once per property per part -- four identical lines for one
		chest, none of which said what to do instead. Reported as its own case
		now, once, with the actual answer.
	]]
	local function kindOf(content: any): string
		local ok, source = pcall(function()
			return tostring((content :: any).SourceType)
		end)
		if not ok then
			return "none"
		end
		if string.find(source, "Object") then
			return "editable"
		elseif string.find(source, "Opaque") then
			return "opaque"
		end
		return "none"
	end

	local converted: { string } = {}
	local skipped: { string } = {}
	local failed: { string } = {}
	local opaque = 0

	--[[
		Bakes one content value, or says why it could not.

		`CreateDataModelContentAsync` returns a TUPLE -- a
		`Enum.CreateContentResult` and then the content -- not the content
		alone. Reading the first value as the result is the mistake this
		function exists to stop repeating: it produced
		`Enum.CreateContentResult.Success` where a Content was wanted, and
		assigning an EnumItem to a content property fails, quietly, inside the
		pcall that was meant to guard the property not existing.
	]]
	local function bakeContent(current: any): (any, string?)
		local ok, status, content = pcall(function()
			return AssetService:CreateDataModelContentAsync(current)
		end)
		if not ok then
			return nil, tostring(status)
		end
		if status ~= Enum.CreateContentResult.Success then
			return nil, tostring(status)
		end
		return content, nil
	end

	local _, undoable = Undo.record("MCPBake", "MCP bake content", function()
		for _, part in targets do
			local did = false
			local sawOpaque = false
			local path = Paths.of(part)

			--[[
				The mesh goes on through `ApplyMesh`, not by assignment.

				`MeshContent` cannot be written from a plugin thread at all --
				"The current thread cannot write 'MeshContent' (lacking
				capability NotAccessible)". Measured. The supported route is to
				build a MeshPart around the baked content and apply it, which
				the engine allows.

				`ApplyMesh` takes the donor's size with it, so the part would
				silently resize on what is meant to be an invisible conversion.
				The size is put back.
			]]
			local mesh = (part :: any).MeshContent
			local meshKind = if mesh == nil then "none" else kindOf(mesh)
			if meshKind == "editable" then
				local baked, why = bakeContent(mesh)
				if baked == nil then
					table.insert(failed, string.format("%s (mesh: %s)", path, tostring(why)))
				else
					local okNew, fresh = pcall(function()
						return AssetService:CreateMeshPartAsync(baked, {
							CollisionFidelity = part.CollisionFidelity,
						})
					end)
					if not okNew then
						table.insert(failed, string.format("%s (mesh: %s)", path, tostring(fresh)))
					else
						local size = part.Size
						local okApply, applyError = pcall(function()
							part:ApplyMesh(fresh :: MeshPart)
						end)
						if okApply then
							part.Size = size
							did = true
						else
							table.insert(failed, string.format("%s (mesh: %s)", path, tostring(applyError)))
						end
					end
				end
			elseif meshKind == "opaque" then
				sawOpaque = true
			end

			-- The texture is an ordinary property write, which this thread may do.
			local texture = (part :: any).TextureContent
			local textureKind = if texture == nil then "none" else kindOf(texture)
			if textureKind == "editable" then
				local baked, why = bakeContent(texture)
				if baked == nil then
					table.insert(failed, string.format("%s (texture: %s)", path, tostring(why)))
				else
					local okSet, setError = pcall(function()
						(part :: any).TextureContent = baked
					end)
					if okSet then
						did = true
					else
						-- Reported, not swallowed. A failed write used to leave
						-- `did` false and fall through to "skipped", so a part
						-- this tool had failed to convert was announced as one
						-- that needed nothing doing.
						table.insert(failed, string.format("%s (texture: %s)", path, tostring(setError)))
					end
				end
			elseif textureKind == "opaque" then
				sawOpaque = true
			end

			if did then
				table.insert(converted, path)
			elseif sawOpaque then
				opaque += 1
			else
				table.insert(skipped, path)
			end
		end
	end)

	return {
		converted = converted,
		skipped = skipped,
		failed = failed,
		opaque = opaque,
		examined = #targets,
		undoable = undoable,
	}
end

function Assets.register()
	Dispatch.registerAll("assets", {
		insert = Assets.insert,
		bake = Assets.bake,
	})
end

return Assets
