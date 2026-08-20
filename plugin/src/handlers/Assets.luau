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

function Assets.register()
	Dispatch.registerAll("assets", {
		insert = Assets.insert,
	})
end

return Assets
