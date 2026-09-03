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
local Scope = require(script.Parent.Parent.Scope)
local Serialize = require(script.Parent.Parent.Serialize)

-- Ceiling on nodes visited in one call, independent of how many are returned.
-- Protects against a `find` over a whole place blocking Studio's main thread.
local MAX_VISITS = 200_000

local Discover = {}

-- Root-level noise filtering lives in Scope, which the script tools share.
local isNoisy = Scope.isNoisy

-- One memo per request keeps path formatting linear when many siblings share a
-- name; see Paths.of.
local function summarise(instance: Instance, memo: Paths.NameIndex): { [string]: any }
	return {
		path = Paths.of(instance, memo),
		className = instance.ClassName,
		childCount = #instance:GetChildren(),
	}
end

--[[
	Puts a result list into an order that does not change between calls.

	`GetChildren` and `GetDescendants` do NOT return a stable order. Measured on
	twelve parts named P01..P12 with nothing mutating between the two calls, the
	engine returned them in ascending order once and as P08, P06, P04, P03, P11,
	P02, P01, P12, P10, P07, P05, P09 the next time.

	Unsorted, that made paging incoherent rather than merely untidy: `offset` is
	a position in this list, so page two came from a different ordering than page
	one, which silently skips some instances and repeats others. Nothing about
	the response would have said so -- the counts stay right and every row is a
	real instance.

	Sorted by name, with the engine's per-instance debug id breaking ties so
	same-named siblings hold a fixed order too. Name first because it is also
	the order a reader expects: P01 before P02.
]]
local function stableOrder(list: { Instance })
	local ids: { [Instance]: string } = {}
	for _, instance in list do
		-- Cached: `GetDebugId` is a call per comparison otherwise, and a sort
		-- makes O(n log n) of them.
		local ok, id = pcall(function()
			return instance:GetDebugId()
		end)
		ids[instance] = if ok then id else tostring(instance)
	end
	table.sort(list, function(a: Instance, b: Instance): boolean
		if a.Name ~= b.Name then
			return a.Name < b.Name
		end
		return (ids[a] or "") < (ids[b] or "")
	end)
end

--[[
	Compares a property against the text a caller asked for.

	This was an exact `tostring` match, which made `find` disagree with `modify`
	about its own notation: `modify` documents an enum as either "Neon" or
	"Enum.Material.Neon", but only the qualified form matched here, and "False"
	matched nothing at all. Both came back as a confident zero rather than an
	error, which is the hardest kind of wrong answer to notice.

	The bare-name shortcut is allowed only for enums, so a part named
	"Map.Backup" is not matched by a search for "Backup".
]]
local function valueMatches(actual: any, wanted: string): boolean
	local text = tostring(actual)
	if text == wanted then
		return true
	end

	local lowered = string.lower(text)
	local target = string.lower(wanted)
	if lowered == target then
		return true
	end

	if string.sub(lowered, 1, 5) == "enum." then
		return string.match(lowered, "([^%.]+)$") == target
	end
	return false
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
	local hidden = 0
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
					if parent == game then
						hidden += 1
					end
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
		-- Sorted per level rather than at the end, so the breadth-first shape is
		-- kept -- shallow instances still come before deep ones -- while the
		-- siblings inside each level stop reshuffling between calls.
		stableOrder(nextFrontier)
		frontier = nextFrontier
		if #frontier == 0 or visits > MAX_VISITS then
			break
		end
	end

	stableOrder(matched)

	local items: { { [string]: any } } = {}
	local memo: Paths.NameIndex = {}
	for index = offset + 1, math.min(offset + limit, #matched) do
		table.insert(items, summarise(matched[index] :: Instance, memo))
	end

	return {
		root = Paths.of(root, memo),
		items = items,
		total = #matched,
		offset = offset,
		hiddenServices = hidden,
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
	local memo: Paths.NameIndex = {}

	for _, path in paths do
		local ok, instance = pcall(Paths.resolve, path)
		if not ok then
			local err = instance :: any
			-- The hint carries the sibling listing ("It does have: ..."), which is
			-- what lets the agent correct the path without another round trip.
			local reason = if typeof(err) == "table"
				then (if err.hint then err.message .. " " .. err.hint else err.message)
				else tostring(err)
			table.insert(failures, string.format("%s: %s", path, reason))
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

		local entry: { [string]: any } = {
			path = Paths.of(target, memo),
			-- Echoed back so a caller can correlate the answer with what it asked
			-- for. `path` is the canonical form and often differs: ask about
			-- "Workspace.Wall" and the answer comes back as "Workspace.Wall[1]".
			requested = path,
			className = target.ClassName,
			properties = properties,
			childCount = #target:GetChildren(),
		}

		-- Empty attribute and tag sets are omitted rather than sent as empty
		-- containers: most instances have neither, and Luau encodes an empty
		-- table as [] which reads as a list and confuses the shape.
		local attributes: { [string]: any } = {}
		local hasAttributes = false
		for name, value in target:GetAttributes() do
			attributes[name] = Serialize.value(value)
			hasAttributes = true
		end
		if hasAttributes then
			entry.attributes = attributes
		end

		local tags = CollectionService:GetTags(target)
		if #tags > 0 then
			entry.tags = tags
		end

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
			if propertyValue ~= nil and not valueMatches(value, tostring(propertyValue)) then
				continue
			end
		end
		table.insert(matched, instance)
	end

	stableOrder(matched)

	local items: { { [string]: any } } = {}
	local memo: Paths.NameIndex = {}
	for index = offset + 1, math.min(offset + limit, #matched) do
		table.insert(items, summarise(matched[index] :: Instance, memo))
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
