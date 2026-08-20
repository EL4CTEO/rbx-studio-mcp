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

local function childNames(parent: Instance, limit: number): string
	local names: { string } = {}
	for _, child in parent:GetChildren() do
		table.insert(names, child.Name)
		if #names >= limit then
			table.insert(names, "...")
			break
		end
	end
	if #names == 0 then
		return "(no children)"
	end
	return table.concat(names, ", ")
end

--[[
	Resolves a path to an Instance, or raises a NOT_FOUND with the failing
	segment and its siblings. `FindFirstChild` is used rather than indexing so a
	missing child never throws a bare Luau error.
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

	local current: Instance = game
	for index, segment in segments do
		local name, ordinal = parseSegment(segment)
		local nextInstance: Instance? = nil

		if ordinal then
			-- Explicit disambiguation: take the nth child with this exact name.
			local list = childrenByName(current, nil)[name]
			nextInstance = if list then list[ordinal] else nil
		elseif index == 1 then
			-- Services must be fetched by class name, and are not always
			-- present as children until first accessed.
			local ok, service = pcall(function()
				return game:GetService(name :: any)
			end)
			nextInstance = if ok then service else current:FindFirstChild(name)
		else
			nextInstance = current:FindFirstChild(name)
		end

		if not nextInstance then
			local partial = table.concat(segments, ".", 1, index)
			-- `fail` never returns; returning its result keeps that visible to
			-- the type checker so `current` stays non-optional below.
			return Dispatch.fail(
				"NOT_FOUND",
				string.format('No instance at "%s".', partial),
				string.format(
					'"%s" has no child named "%s". It does have: %s',
					current:GetFullName(),
					segment,
					childNames(current, 25)
				)
			)
		end
		current = nextInstance
	end

	return current
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
