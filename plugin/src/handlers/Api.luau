--!strict
--[[
	What a class can do, answered by the engine that is running.

	The server already validates property names against Roblox's published API
	dump, fetched over HTTP from a community mirror. That works and has two
	weaknesses: it needs the network, and it describes whatever build the mirror
	last published rather than the Studio in front of you.

	`ReflectionService` is the same information, locally, from the binary that is
	actually executing -- 633 classes and 96 properties on Part, measured. It
	cannot go stale and it cannot fail to download.

	This answers a question an agent asks constantly and currently cannot:
	"what do I call on this thing?" Without it the only way to learn a class's
	surface is to find an instance of it and read every property, which needs one
	to exist and still never lists methods or events.
]]

local ReflectionService = game:GetService("ReflectionService")

local Dispatch = require(script.Parent.Parent.Dispatch)

local Api = {}

-- A class listing is for orientation, not for reading end to end; 633 classes
-- would be most of a context window.
local MAX_CLASSES = 150

local function nameOf(entry: any): string
	if typeof(entry) == "table" then
		return tostring((entry :: any).Name)
	end
	return tostring(entry)
end

--[[
	The script-facing name of a type, which is not always the engine's.

	Entries carry `{ EngineType, ScriptType }` and they differ where it matters:
	an int64 is a `number` to Luau, and a caller writing code wants the second.
]]
local function typeName(spec: any): string
	if typeof(spec) ~= "table" then
		return "?"
	end
	return tostring((spec :: any).ScriptType or (spec :: any).EngineType or "?")
end

--[[
	Renders a member as something that can be typed, not just recognised.

	A bare name says a method exists; a signature says how to call it, which is
	the actual question. `Humanoid.AddAccessory` is a guess until you know it
	takes one Instance.
]]
local function signature(entry: any): string
	local name = nameOf(entry)
	local parameters = (entry :: any).Parameters
	if typeof(parameters) ~= "table" then
		-- A property. Its type is the useful half.
		local kind = (entry :: any).Type
		return if kind ~= nil then string.format("%s: %s", name, typeName(kind)) else name
	end

	local rendered: { string } = {}
	for _, parameter in parameters :: { any } do
		table.insert(rendered, string.format("%s: %s", tostring(parameter.Name), typeName(parameter.Type)))
	end

	local returns = (entry :: any).ReturnType
	local suffix = if returns ~= nil and typeName(returns) ~= "Void"
		then " -> " .. typeName(returns)
		else ""
	return string.format("%s(%s)%s", name, table.concat(rendered, ", "), suffix)
end

--[[
	Splits a class's own members from the ones it inherits.

	Every entry names its `Owner`, and without using it the answer is unusable:
	ProximityPrompt has 2 methods of its own and 42 from Instance and Object, so
	a flat alphabetical list buries `InputHoldBegin` among `findFirstChild` and
	thirty other pieces of boilerplate the caller already knows about. The
	inherited ones are still counted, because "it has no such method" and "it has
	it, from Instance" are different answers.

	Sorted so two calls agree: an agent comparing a class across engine versions
	should see what changed, not a reshuffle.
]]
local function split(entries: { any }, className: string): ({ string }, number)
	local own: { string } = {}
	local inherited = 0
	for _, entry in entries do
		if typeof(entry) == "table" and tostring((entry :: any).Owner) ~= className then
			inherited += 1
		else
			table.insert(own, signature(entry))
		end
	end
	table.sort(own)
	return own, inherited
end

function Api.describe(params: { [string]: any }): { [string]: any }
	local className = params.className
	if typeof(className) ~= "string" or className == "" then
		Dispatch.fail("BAD_PARAMS", "describe needs a `className`, e.g. \"TweenService\".")
	end

	local okClass, class = pcall(function()
		return (ReflectionService :: any):GetClass(className, {})
	end)
	if not okClass or class == nil then
		Dispatch.fail(
			"NO_SUCH_CLASS",
			string.format("The engine has no class called %q.", className),
			"Class names are case-sensitive. Use `api op=\"classes\"` with a `contains` filter to find it."
		)
	end

	local result: { [string]: any } = {
		className = nameOf(class),
		superclass = if typeof(class) == "table" then tostring((class :: any).Superclass) else nil,
	}

	local wanted = params.include
	local include = if typeof(wanted) == "table" then wanted :: { string } else { "properties", "methods", "events" }
	local function asked(what: string): boolean
		for _, item in include do
			if item == what then
				return true
			end
		end
		return false
	end

	-- Asked for explicitly, because the filter argument these calls accept is
	-- ignored: passing Inherited = false, IncludeInherited = false and
	-- Deprecated = false each returned exactly the same 26 properties as {}.
	-- The Owner field is the only thing that actually separates them.
	local exact = tostring(result.className)
	local wantInherited = params.inherited == true

	local sources = {
		{ key = "properties", method = "GetPropertiesOfClass" },
		{ key = "methods", method = "GetMethodsOfClass" },
		{ key = "events", method = "GetEventsOfClass" },
	}
	for _, source in sources do
		if not asked(source.key) then
			continue
		end
		local ok, entries = pcall(function()
			return (ReflectionService :: any)[source.method](ReflectionService, className, {})
		end)
		if not ok then
			continue
		end
		local own, inherited = split(entries :: { any }, exact)
		if wantInherited then
			local everything: { string } = {}
			for _, entry in entries :: { any } do
				table.insert(everything, signature(entry))
			end
			table.sort(everything)
			result[source.key] = everything
		else
			result[source.key] = own
			if inherited > 0 then
				result[source.key .. "Inherited"] = inherited
			end
		end
	end

	return result
end

function Api.classes(params: { [string]: any }): { [string]: any }
	local ok, classes = pcall(function()
		return (ReflectionService :: any):GetClasses({})
	end)
	if not ok then
		Dispatch.fail("REFLECTION_FAILED", string.format("Could not list classes: %s", tostring(classes)))
	end

	local needle = if typeof(params.contains) == "string" then string.lower(params.contains) else nil
	local matched: { string } = {}
	local total = 0
	for _, entry in classes :: { any } do
		local name = nameOf(entry)
		if needle == nil or string.find(string.lower(name), needle, 1, true) ~= nil then
			total += 1
			if #matched < MAX_CLASSES then
				table.insert(matched, name)
			end
		end
	end
	table.sort(matched)

	return {
		classes = matched,
		matched = total,
		truncated = if total > #matched then total - #matched else nil,
	}
end

function Api.register()
	Dispatch.registerAll("api", {
		describe = Api.describe,
		classes = Api.classes,
	})
end

return Api
