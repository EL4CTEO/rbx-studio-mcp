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
--[[
	The physical facts about a part, which no property panel shows.

	"Why does this fall over", "why does it sink", "why does the door fly off
	when you touch it" are all mass questions, and mass is not a property you can
	read in Studio -- it is computed from volume and material and appears
	nowhere. A 4-stud cube of Metal weighs nine times the same cube of Neon, and
	nothing on screen distinguishes them.

	`AssemblyRootPart` is the other half. Parts welded together move as one body
	with one combined mass, and which part leads that body decides how the whole
	thing behaves. Two parts that look joined but report different assembly roots
	are not joined at all, which is the usual answer to "why did half of it stay
	behind".
]]
local function physicsOf(target: Instance): { [string]: any }?
	if not target:IsA("BasePart") then
		return nil
	end
	local part = target :: BasePart

	local facts: { [string]: any } = {
		anchored = part.Anchored,
		canCollide = part.CanCollide,
		massless = part.Massless,
		material = tostring(part.Material):gsub("Enum%.Material%.", ""),
	}

	-- Every read is guarded separately: an anchored part has no assembly, and a
	-- part mid-destruction can refuse any of these without the others failing.
	pcall(function()
		facts.mass = math.round(part:GetMass() * 1000) / 1000
	end)
	--[[
		Infinity is a real answer here, and JSON cannot carry it.

		An anchored part has infinite assembly mass -- that is the engine saying
		"nothing will ever move this", which is exactly the fact someone asking
		about mass wants. Encoded raw it came back as
		`{"m":null,"t":"numeric","v":"inf"}`, which is the serialiser's honest
		attempt at a number JSON has no room for, and is unreadable to everybody.
		Said in words instead.
	]]
	pcall(function()
		local assembly = part.AssemblyMass
		if assembly == math.huge then
			facts.assemblyMass = "infinite -- anchored, so nothing moves it"
		else
			facts.assemblyMass = math.round(assembly * 1000) / 1000
		end
	end)
	pcall(function()
		local root = part.AssemblyRootPart
		if root == nil then
			--[[
				No assembly at all, which is not the same as being welded to
				something.

				Only parts inside Workspace are simulated; one sitting in
				StarterPack, ReplicatedStorage or ServerStorage has no assembly
				and `AssemblyRootPart` is nil. The first version read that nil as
				"the root is not me" and reported `movesAlone = false`, which says
				this part is attached to another -- about a part that is not in
				the physics world at all. A pistol in StarterPack read as welded
				to something.
			]]
			facts.simulated = false
			facts.note = "Not in Workspace, so it has no physics assembly. Mass and "
				.. "density are still real; anything about how it moves is not."
			return
		end
		facts.simulated = true
		facts.assemblyRoot = Paths.of(root)
		--[[
			Whether this part leads its own body. A part that is its own assembly
			root is moving alone; one whose root is elsewhere is welded to
			something, and the root names what.
		]]
		facts.movesAlone = root == part
	end)
	pcall(function()
		--[[
			Where the WHOLE body balances, in world coordinates.

			`CenterOfMass` is the part's own, in its own space, and for any
			ordinary part it is (0, 0, 0) -- it was reported for every part in
			the place and said nothing about any of them. The figure that
			answers a question is the assembly's: a plank at x = 0 on a fulcrum
			at x = 0, with a weight bolted near one end, balances at x = 7, and
			that number is the entire explanation of why it tips. Measured on
			exactly that see-saw.

			The local one is kept only when it is not the origin, which means
			somebody set it deliberately and it is worth seeing.
		]]
		facts.centerOfMass = Serialize.value(part.AssemblyCenterOfMass)
		local own = part.CenterOfMass
		if own.Magnitude > 0.001 then
			facts.centerOfMassOffset = Serialize.value(own)
		end
	end)
	pcall(function()
		local velocity = part.AssemblyLinearVelocity.Magnitude
		if velocity > 0.01 then
			facts.speed = math.round(velocity * 100) / 100
		end
	end)
	--[[
		Density from whichever source is actually in force.

		An earlier version read `PhysicalProperties.new(part.Material)` whenever
		custom properties existed, which reported the MATERIAL's density while the
		part was using the override -- the one number in this block that would
		have been confidently wrong. Measured: a Metal part reads 7.85 by
		material and weighs 75.36, and the same part with a custom density of 0.3
		weighs 2.88. Reporting 7.85 for the second one explains nothing about a
		part that floats.

		`CustomPhysicalProperties` is nil when unset, so its presence is the test
		for which source applies.
	]]
	pcall(function()
		local custom = part.CustomPhysicalProperties
		if custom ~= nil then
			facts.density = math.round(custom.Density * 1000) / 1000
			facts.densityFrom = "CustomPhysicalProperties"
		else
			facts.density = math.round(PhysicalProperties.new(part.Material).Density * 1000) / 1000
			facts.densityFrom = "material"
		end
	end)

	return facts
end

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

		if params.physics == true then
			entry.physics = physicsOf(target)
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
--[[
	Runs a selector through the engine's own matcher.

	`QueryDescendants` is a CSS-like query built into Instance, and it is doing
	the same job the loop below does -- except in C++, over the whole subtree, in
	one call. Measured on a 3700-instance place: "Part" answered 189 matches
	without a single Luau iteration.

	What it understands, confirmed against a live session rather than guessed:

		Part                class name, superclasses included
		#Baseplate          exact name
		[Anchored=true]     property equality, on its own or after a class
		Part, Model         either
		Model > Part        direct children of a Model
		Model >> Part       descendants of a Model

	What it does not: substring names, and comparisons like `>` or `<` (it
	answers "'=' expected after property name"). That is why this is one
	candidate source among three rather than a replacement for the filters --
	`nameContains` still needs the loop, and composes with a selector.

	A malformed selector raises from inside the engine with a readable reason, so
	it is caught and re-raised as BAD_PARAMS with the reason kept: "Pseudo-class
	'first' filter is not supported" tells the caller exactly what to drop.
]]
local function query(root: Instance, selector: string): { Instance }
	local ok, result = pcall(function()
		return root:QueryDescendants(selector)
	end)
	if not ok then
		Dispatch.fail(
			"BAD_PARAMS",
			string.format("selector %q was rejected: %s", selector, tostring(result)),
			"Selectors support a class name, #Name, [Property=Value], `A, B`, "
				.. "`A > B` for direct children and `A >> B` for descendants. They do "
				.. "not support substring names or < > comparisons -- use "
				.. "`nameContains` and `propertyValue` for those."
		)
	end

	--[[
		Deduplicated, because a union can match the same instance twice.

		`Script, LocalScript` looks like two disjoint sets and is not: LocalScript
		inherits Script, so every LocalScript satisfies both halves and the engine
		returns it once per half. Measured -- a place with 7 scripts answered 14
		matches, every one of them listed twice, and the count was as wrong as the
		listing.

		The engine is not doing anything unreasonable here; a union is a union.
		But "how many are there" is the question a caller is usually asking, and
		an answer that doubles depending on how the class hierarchy happens to be
		shaped is not an answer.
	]]
	local matches = result :: { Instance }
	local seen: { [Instance]: boolean } = {}
	local unique: { Instance } = {}
	for _, instance in matches do
		if not seen[instance] then
			seen[instance] = true
			table.insert(unique, instance)
		end
	end
	return unique
end

--[[
	Which tags this place actually uses.

	`find` can filter by tag and could never tell you which tags exist, so using
	it meant guessing a name: a search for "Doors" that returns nothing is
	indistinguishable from a place whose doors are tagged "Door". On a place
	nobody has seen before that is the difference between reading how the game is
	organised in one call and not being able to ask the question at all -- tags
	like Enemy, Checkpoint or Interactable name a game's systems better than its
	folder layout does.

	Counted per tag, because an empty tag and a busy one mean different things: a
	tag with nothing on it is usually left over from something deleted, and worth
	saying so rather than listing beside the real ones.
]]

--[[
	Studio's own tags, which are in every place and belong to none of them.

	The tag registry is shared with Studio's interface, so an unfiltered listing
	is mostly `data-testid=--studio-foundation--stylesheet-wrapper` and its
	relatives -- measured, 7 tags in a place that uses 5. They are recognisable
	by prefix rather than by a list, since the set changes with Studio's own UI
	and hardcoding today's names would silently rot.
]]
local function studioOwned(tag: string): boolean
	return string.sub(tag, 1, 12) == "data-testid="
end

function Discover.tags(params: { [string]: any }): { [string]: any }
	local root = if typeof(params.path) == "string" and params.path ~= ""
		then Paths.resolve(params.path)
		else nil

	local rows: { { [string]: any } } = {}
	local hidden = 0

	for _, tag in CollectionService:GetAllTags() do
		if studioOwned(tag) then
			hidden += 1
			continue
		end

		local tagged = CollectionService:GetTagged(tag)
		local count = 0
		local sample: { string } = {}

		for _, instance in tagged do
			--[[
				Scoped the same way `find` scopes, when a path is given. A tag is
				global, so "which tags are used in Workspace.Map" is a different
				question from "which tags exist", and both get asked.
			]]
			if root ~= nil and not instance:IsDescendantOf(root) then
				continue
			end
			if Scope.isNoisy(instance) then
				continue
			end
			count += 1
			if #sample < 3 then
				table.insert(sample, Paths.of(instance))
			end
		end

		if root ~= nil and count == 0 then
			continue
		end

		table.insert(rows, {
			tag = tag,
			count = count,
			-- A few paths, not all of them: the point is to recognise what the tag
			-- is for, and three examples do that where two hundred would not.
			sample = sample,
		})
	end

	table.sort(rows, function(a, b)
		if a.count == b.count then
			return tostring(a.tag) < tostring(b.tag)
		end
		return (a.count :: number) > (b.count :: number)
	end)

	return {
		tags = rows,
		count = #rows,
		scope = if root ~= nil then Paths.of(root) else nil,
		studioTagsHidden = hidden,
	}
end

function Discover.find(params: { [string]: any }): { [string]: any }
	local root = if params.path then Paths.resolve(params.path) else game
	local limit = tonumber(params.limit) or 100
	local offset = tonumber(params.offset) or 0

	local nameFilter = if params.nameContains then string.lower(params.nameContains) else nil
	local classFilter = params.className
	local propertyName = params.propertyName
	local propertyValue = params.propertyValue
	local tagFilter = params.tag
	local selector = if typeof(params.selector) == "string" and params.selector ~= ""
		then params.selector
		else nil

	--[[
		Three ways to produce candidates, cheapest first.

		The filters below are the same in every case -- this only chooses where
		the list to filter comes from, which is the part that decides whether a
		search on a large place is fast or times out.

		* A tag query reads CollectionService's index instead of walking the
		  tree, which is orders of magnitude cheaper.
		* A selector hands the whole match to `QueryDescendants`, so the walk
		  happens in C++ and only survivors cross into Luau.
		* Otherwise the tree is walked here.
	]]
	local candidates: { Instance }
	if tagFilter then
		candidates = CollectionService:GetTagged(tagFilter)
	elseif selector then
		candidates = query(root, selector :: string)
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
			"Narrow it with `path` to search one service or model instead of the whole "
				.. "place, or pass a `selector` -- that filters inside the engine, so the "
				.. "count here is what survived rather than what was visited."
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
		-- Echoed so a caller can see the selector was understood. A typo in a
		-- selector is not an error -- it matches nothing -- and "0 results" reads
		-- the same either way without this.
		selector = selector,
	}
end

function Discover.register()
	Dispatch.registerAll("discover", {
		tags = Discover.tags,
		tree = Discover.tree,
		inspect = Discover.inspect,
		find = Discover.find,
	})
end

return Discover
