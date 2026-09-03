--!strict
--[[
	Dot-notation instance paths, e.g. "Workspace.Map.Spawn".

	Paths are the address format for every tool, so resolution failures are the
	most common error an agent will hit. Each failure says which segment broke
	and what does exist at that level, which is usually enough for the model to
	fix the path itself instead of falling back to a blind tree dump.
]]

local Dispatch = require(script.Parent.Dispatch)

local Paths = {}

--[[
	Splits a path into segments. A leading "game." is optional and stripped, so
	both "game.Workspace.Part" and "Workspace.Part" resolve identically.
]]
function Paths.split(path: string): { string }
	local segments: { string } = {}
	for segment in string.gmatch(path, "[^%.]+") do
		table.insert(segments, segment)
	end
	if segments[1] == "game" then
		table.remove(segments, 1)
	end
	return segments
end

--[[
	Splits "Part[3]" into ("Part", 3), or ("Part", nil) when unindexed.

	Sibling names are not unique in Roblox -- a Workspace with 77 parts all named
	"Part" is completely ordinary -- so a bare dotted path is ambiguous and
	`FindFirstChild` would silently pick the first match. Every path this module
	emits therefore carries a 1-based index whenever the name is shared, and
	`resolve` honours it.
]]
local function parseSegment(segment: string): (string, number?)
	local name, index = string.match(segment, "^(.*)%[(%d+)%]$")
	if name and index then
		return name, tonumber(index)
	end
	return segment, nil
end

export type NameIndex = { [Instance]: { [string]: { Instance } } }

--[[
	Groups a parent's children by name, memoised across one request. Without the
	memo, formatting paths for N same-named siblings is O(N^2); a listing of a
	few thousand parts would stall Studio's main thread.
]]
local function childrenByName(parent: Instance, memo: NameIndex?): { [string]: { Instance } }
	local cached = if memo then memo[parent] else nil
	if cached then
		return cached
	end

	local byName: { [string]: { Instance } } = {}
	for _, child in parent:GetChildren() do
		local list = byName[child.Name]
		if not list then
			list = {}
			byName[child.Name] = list
		end
		table.insert(list, child)
	end

	if memo then
		memo[parent] = byName
	end
	return byName
end

--[[
	1-based position among identically named siblings, or nil when the name is
	already unique and no index is needed.
]]
local function siblingIndex(instance: Instance, memo: NameIndex?): number?
	local parent = instance.Parent
	if not parent then
		return nil
	end

	local list = childrenByName(parent, memo)[instance.Name]
	if not list or #list <= 1 then
		return nil
	end
	for index, child in list do
		if child == instance then
			return index
		end
	end
	return nil
end

--[[
	Names a parent's children for an error message, collapsing repeats.

	Same-named siblings are ordinary in Roblox, and listing them one by one spent
	the whole budget saying "Part, Part, Part" 25 times -- which tells a reader
	nothing and hides the names that would have helped. Repeats are counted
	instead, and the count is exactly what says an index is needed.
]]
local function childNames(parent: Instance, limit: number): string
	local order: { string } = {}
	local counts: { [string]: number } = {}
	for _, child in parent:GetChildren() do
		if counts[child.Name] == nil then
			counts[child.Name] = 0
			table.insert(order, child.Name)
		end
		counts[child.Name] += 1
	end

	if #order == 0 then
		return "(no children)"
	end

	local names: { string } = {}
	for _, name in order do
		if #names >= limit then
			table.insert(names, string.format("... %d more", #order - limit))
			break
		end
		local count = counts[name]
		table.insert(names, if count > 1 then string.format("%s (x%d)", name, count) else name)
	end
	return table.concat(names, ", ")
end

--[[
	Finds one child by a single segment, honouring "Name[2]" and, at the root,
	fetching services by class name -- they are not always present as children
	until first accessed.

	The second return is a diagnostic for the one miss a caller cannot work out
	from the sibling list: an index past the end of a name that does exist.
]]
local function childBySegment(
	parent: Instance,
	segment: string,
	atRoot: boolean
): (Instance?, string?)
	local name, ordinal = parseSegment(segment)

	if ordinal then
		local list = childrenByName(parent, nil)[name]
		if list == nil then
			return nil, nil
		end
		local child = list[ordinal]
		if child then
			return child, nil
		end
		return nil,
			string.format(
				'"%s" has %d child%s named "%s", so [%d] is past the end. Indexes are '
					.. "1-based and shift when siblings are added or removed -- read a "
					.. "fresh path from `find` or `tree`.",
				parent:GetFullName(),
				#list,
				if #list == 1 then "" else "ren",
				name,
				ordinal
			)
	end

	if atRoot then
		local ok, service = pcall(function()
			return game:GetService(name :: any)
		end)
		if ok and service then
			return service, nil
		end
	end
	return parent:FindFirstChild(name), nil
end

--[[
	Resolves a path to an Instance, or raises a NOT_FOUND with the failing
	segment and its siblings. `FindFirstChild` is used rather than indexing so a
	missing child never throws a bare Luau error.

	Instance names may contain dots -- "Dr. Simon" is an ordinary name, and so is
	"v1.2 backup" -- while the separator is a dot too, so such a name arrives
	here already split into pieces. Each step therefore tries consuming one
	segment first and rejoins further segments only if that leads nowhere, which
	means the search has to BACK TRACK: with both "Dr" and "Dr. Who" present,
	"Workspace.Dr. Who.Head" matches "Dr", fails to find " Who" under it, and
	must return to try "Dr. Who". A first pass without that backtracking left the
	tools emitting `Workspace.Dr. Who` as a path and then refusing to read it
	back, which is worse than either behaviour on its own.

	Shortest-first keeps the old precedence: where a short name resolves the
	whole remaining path, it still wins over a longer join.
]]
function Paths.resolve(path: string): Instance
	if typeof(path) ~= "string" or path == "" then
		Dispatch.fail(
			"BAD_PATH",
			"An instance path is required.",
			'Paths are dot-separated from the DataModel root, e.g. "Workspace.Map.Spawn". '
				.. "Use `find` or `tree` to discover valid paths."
		)
	end

	local segments = Paths.split(path)
	if #segments == 0 then
		return game
	end

	-- The deepest point any branch of the search reached, so a failure still
	-- reports the segment that actually broke rather than the first one tried.
	local deepest = 0
	local deepestParent: Instance = game
	local deepestNote: string? = nil
	-- The segment text the note is about: with a rejoined name it is not
	-- `segments[failedAt]`, and reporting that instead named "Mr" for a path
	-- that asked for "Mr. X[3]".
	local deepestSegment: string? = nil

	local function walk(current: Instance, index: number): Instance?
		if index > #segments then
			return current
		end
		if index - 1 > deepest then
			deepest = index - 1
			deepestParent = current
			deepestNote = nil
			deepestSegment = nil
		end

		for last = index, #segments do
			local joined = table.concat(segments, ".", index, last)
			local child, note = childBySegment(current, joined, index == 1)
			if note and index - 1 == deepest then
				deepestNote = note
				deepestSegment = joined
			end
			if child then
				local found = walk(child, last + 1)
				if found then
					return found
				end
			end
		end
		return nil
	end

	local resolved = walk(game, 1)
	if resolved then
		return resolved
	end

	local failedAt = deepest + 1
	local reached = if deepest > 0 then table.concat(segments, ".", 1, deepest) .. "." else ""
	local named = if deepestSegment
		then reached .. deepestSegment
		else table.concat(segments, ".", 1, failedAt)
	return Dispatch.fail(
		"NOT_FOUND",
		string.format('No instance at "%s".', named),
		if deepestNote
			then deepestNote
			else string.format(
				'"%s" has no child named "%s". It does have: %s',
				deepestParent:GetFullName(),
				segments[failedAt],
				childNames(deepestParent, 25)
			)
	)
end

--[[
	Resolves many paths at once, collecting failures instead of stopping at the
	first one. Batch tools report every bad path in a single response so the
	agent can fix them all in one retry rather than one call per mistake.
]]
function Paths.resolveMany(paths: { string }): ({ Instance }, { string })
	local resolved: { Instance } = {}
	local failures: { string } = {}
	for _, path in paths do
		local ok, result = pcall(Paths.resolve, path)
		if ok then
			table.insert(resolved, result :: Instance)
		else
			local err = result :: any
			table.insert(
				failures,
				string.format("%s: %s", path, if typeof(err) == "table" then err.message else tostring(err))
			)
		end
	end
	return resolved, failures
end

--[[
	Formats an instance into a path that resolves back to that exact instance.

	`GetFullName` is deliberately not used: it emits "Workspace.Part" for every
	one of 77 parts named "Part", so the paths it produces are not addresses at
	all. Here each segment gains a [n] suffix when its name is shared with a
	sibling.

	Pass a shared `memo` when formatting many instances in one request.

	The index is positional, so it shifts if same-named siblings are inserted or
	removed between calls. Read a fresh path after any structural change.
]]
function Paths.of(instance: Instance, memo: NameIndex?): string
	--[[
		Refuses anything that is not an Instance, rather than duck-typing it.

		This walks `.Name` and `.Parent`, which a plain table can also have -- so
		handed a table carrying those two fields it used to return a perfectly
		well-formed path for an object that exists nowhere in the data model.
		That happened: `GeometryService:FragmentAsync` returns `{Index, Instance}`
		wrappers, a handler assigned `.Name` and `.Parent` to the wrapper, and
		this function reported eight new parts by full path when none had been
		created. A fabricated path is worse than an error, because everything
		downstream treats it as real.
	]]
	if typeof(instance) ~= "Instance" then
		error(
			string.format(
				"Paths.of expects an Instance, got %s. This is a bug in the caller, "
					.. "not in the request.",
				typeof(instance)
			),
			2
		)
	end

	if instance == game then
		return "game"
	end

	local segments: { string } = {}
	local current: Instance? = instance

	while current ~= nil and current ~= game do
		local node = current :: Instance
		local ordinal = siblingIndex(node, memo)
		table.insert(
			segments,
			1,
			if ordinal then string.format("%s[%d]", node.Name, ordinal) else node.Name
		)
		current = node.Parent
	end

	return table.concat(segments, ".")
end

return Paths
