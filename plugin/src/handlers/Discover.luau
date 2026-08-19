--!strict
--[[
	Hierarchy exploration: tree, inspect and find.

	These three replace roughly a dozen tools in competing servers
	(get_file_tree, get_project_structure, get_instance_children, search_objects,
	search_by_property, get_attributes, get_tags, get_tagged, get_class_info...).
	Fewer, wider tools mean less schema in the agent's context and fewer chances
	to pick the wrong one.

	Traversal is bounded everywhere. A production place can hold hundreds of
	thousands of instances, and an unbounded walk would either time out or return
	something no context window can hold.
]]

local CollectionService = game:GetService("CollectionService")

local Dispatch = require(script.Parent.Parent.Dispatch)
local Paths = require(script.Parent.Parent.Paths)
local Serialize = require(script.Parent.Parent.Serialize)

-- Ceiling on nodes visited in one call, independent of how many are returned.
-- Protects against a `find` over a whole place blocking Studio's main thread.
local MAX_VISITS = 200_000

-- Services that are large, generated, or irrelevant to authoring. Skipped when
-- walking from the DataModel root unless the caller asks for them by path.
local NOISY_SERVICES = {
	CoreGui = true,
	CorePackages = true,
	Chat = true,
	JointsService = true,
	TextChatService = false,
}

local Discover = {}

local function isNoisy(instance: Instance): boolean
	return instance.Parent == game and NOISY_SERVICES[instance.Name] == true
end

local function summarise(instance: Instance): { [string]: any }
	return {
		path = Paths.of(instance),
		className = instance.ClassName,
		childCount = #instance:GetChildren(),
	}
end

--[[
	Breadth-first walk to `depth`, newest level last, so a truncated result is
	still a coherent picture of the top of the tree rather than one deep spur.
]]
function Discover.tree(params: { [string]: any }): { [string]: any }
	local root = if params.path then Paths.resolve(params.path) else game
	local depth = tonumber(params.depth) or 2
	local limit = tonumber(params.limit) or 100
	local offset = tonumber(params.offset) or 0
	local classFilter = params.className
	local nameFilter = if params.nameContains then string.lower(params.nameContains) else nil

	local matched: { Instance } = {}
	local visits = 0
	local frontier: { Instance } = { root }

	for level = 1, depth do
		local nextFrontier: { Instance } = {}
		for _, parent in frontier do
			for _, child in parent:GetChildren() do
				visits += 1
				if visits > MAX_VISITS then
					break
				end
				if isNoisy(child) then
					continue
				end

				local keep = true
				if classFilter and not child:IsA(classFilter) then
					keep = false
				end
				if keep and nameFilter and not string.find(string.lower(child.Name), nameFilter, 1, true) then
					keep = false
				end
				if keep then
					table.insert(matched, child)
				end
				if level < depth then
					table.insert(nextFrontier, child)
				end
			end
		end
		frontier = nextFrontier
		if #frontier == 0 or visits > MAX_VISITS then
			break
		end
	end

	local items: { { [string]: any } } = {}
	for index = offset + 1, math.min(offset + limit, #matched) do
		table.insert(items, summarise(matched[index] :: Instance))
	end

	return {
		root = Paths.of(root),
		items = items,
		total = #matched,
		offset = offset,
	}
end

--[[
	Detailed read of specific instances. `properties` is chosen server-side from
	the live API dump, so this handler never needs its own class table.
]]
function Discover.inspect(params: { [string]: any }): { [string]: any }
	local paths = params.paths
	if typeof(paths) ~= "table" or #paths == 0 then
		Dispatch.fail(
			"BAD_PARAMS",
			"inspect requires a non-empty `paths` array.",
			'Pass paths like ["Workspace.Model.Part"]. Use `find` or `tree` to discover them.'
		)
	end

	local requested: { string }? = params.properties
	local includeChildren = params.includeChildren ~= false
	local childLimit = tonumber(params.childLimit) or 25

	local results: { { [string]: any } } = {}
	local failures: { string } = {}

	for _, path in paths do
		local ok, instance = pcall(Paths.resolve, path)
		if not ok then
			local err = instance :: any
			table.insert(
				failures,
				string.format("%s: %s", path, if typeof(err) == "table" then err.message else tostring(err))
			)
			continue
		end

		local target = instance :: Instance
		local properties: { [string]: any } = {}
		if requested then
			for _, name in requested do
				local readOk, value = Serialize.readProperty(target, name)
				if readOk then
					properties[name] = value
				end
			end
		end

		local attributes: { [string]: any } = {}
		for name, value in target:GetAttributes() do
			attributes[name] = Serialize.value(value)
		end

		local entry: { [string]: any } = {
			path = Paths.of(target),
			className = target.ClassName,
			properties = properties,
			attributes = attributes,
			tags = CollectionService:GetTags(target),
			childCount = #target:GetChildren(),
		}

		if includeChildren then
			local children: { { [string]: any } } = {}
			for index, child in target:GetChildren() do
				if index > childLimit then
					break
				end
				table.insert(children, { name = child.Name, className = child.ClassName })
			end
			entry.children = children
		end

		table.insert(results, entry)
	end

	return { items = results, failures = failures }
end

--[[
	One search over name, class, property value and tag.

	Every filter supplied must match (AND), which is what lets a single tool
	answer "every anchored Part under Workspace whose name contains 'door'"
	without the agent chaining three calls and intersecting the results itself.
]]
function Discover.find(params: { [string]: any }): { [string]: any }
	local root = if params.path then Paths.resolve(params.path) else game
	local limit = tonumber(params.limit) or 100
	local offset = tonumber(params.offset) or 0

	local nameFilter = if params.nameContains then string.lower(params.nameContains) else nil
	local classFilter = params.className
	local propertyName = params.propertyName
	local propertyValue = params.propertyValue
	local tagFilter = params.tag

	-- A tag query is answered from CollectionService's index rather than by
	-- walking the tree, which is orders of magnitude cheaper on a big place.
	local candidates: { Instance }
	if tagFilter then
		candidates = CollectionService:GetTagged(tagFilter)
	else
		candidates = root:GetDescendants()
	end

	if #candidates > MAX_VISITS then
		Dispatch.fail(
			"TOO_BROAD",
			string.format(
				"That search would visit %d instances, over the %d limit.",
				#candidates,
				MAX_VISITS
			),
			"Narrow it with `path` to search one service or model instead of the whole place."
		)
	end

	local matched: { Instance } = {}
	for _, instance in candidates do
		if tagFilter and root ~= game and not instance:IsDescendantOf(root) then
			continue
		end
		if isNoisy(instance) then
			continue
		end
		if classFilter and not instance:IsA(classFilter) then
			continue
		end
		if nameFilter and not string.find(string.lower(instance.Name), nameFilter, 1, true) then
			continue
		end
		if propertyName then
			local readOk, value = Serialize.readProperty(instance, propertyName)
			if not readOk then
				continue
			end
			if propertyValue ~= nil and tostring(value) ~= tostring(propertyValue) then
				continue
			end
		end
		table.insert(matched, instance)
	end

	local items: { { [string]: any } } = {}
	for index = offset + 1, math.min(offset + limit, #matched) do
		table.insert(items, summarise(matched[index] :: Instance))
	end

	return {
		items = items,
		total = #matched,
		offset = offset,
		searched = #candidates,
	}
end

function Discover.register()
	Dispatch.registerAll("discover", {
		tree = Discover.tree,
		inspect = Discover.inspect,
		find = Discover.find,
	})
end

return Discover
