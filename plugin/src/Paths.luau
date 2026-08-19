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
		local nextInstance: Instance? = nil

		if index == 1 then
			-- Services must be fetched by class name, and are not always
			-- present as children until first accessed.
			local ok, service = pcall(function()
				return game:GetService(segment :: any)
			end)
			nextInstance = if ok then service else current:FindFirstChild(segment)
		else
			nextInstance = current:FindFirstChild(segment)
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
	Formats an instance back into a path the tools accept. `GetFullName` returns
	"Workspace.Map.Spawn" for descendants of services, which round-trips through
	`resolve` unchanged.
]]
function Paths.of(instance: Instance): string
	return instance:GetFullName()
end

return Paths
