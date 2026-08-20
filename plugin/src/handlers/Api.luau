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
	Sorts members by name so two calls agree, which matters more than it sounds:
	an agent comparing a class before and after an engine update should see a
	diff of what changed, not a reshuffle.
]]
local function sortedNames(entries: { any }): { string }
	local names: { string } = {}
	for _, entry in entries do
		table.insert(names, nameOf(entry))
	end
	table.sort(names)
	return names
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

	if asked("properties") then
		local ok, properties = pcall(function()
			return (ReflectionService :: any):GetPropertiesOfClass(className, {})
		end)
		result.properties = if ok then sortedNames(properties) else nil
	end
	if asked("methods") then
		local ok, methods = pcall(function()
			return (ReflectionService :: any):GetMethodsOfClass(className, {})
		end)
		result.methods = if ok then sortedNames(methods) else nil
	end
	if asked("events") then
		local ok, events = pcall(function()
			return (ReflectionService :: any):GetEventsOfClass(className, {})
		end)
		result.events = if ok then sortedNames(events) else nil
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
