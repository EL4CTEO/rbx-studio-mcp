--[[
	A JSON decoder just strict enough for these tests: it must reject the exact
	malformed string the old parser produced, so a stub that shrugs at anything
	brace-shaped would prove nothing.
]]
local Net = {}

function Net.decode(text: string): any?
	local at = 1
	local function skip()
		while at <= #text and string.match(string.sub(text, at, at), "%s") do at += 1 end
	end
	local parseValue

	local function parseString(): string?
		if string.sub(text, at, at) ~= '"' then return nil end
		at += 1
		local start = at
		while at <= #text and string.sub(text, at, at) ~= '"' do at += 1 end
		if at > #text then return nil end
		local value = string.sub(text, start, at - 1)
		at += 1
		return value
	end

	local function parseObject(): any?
		if string.sub(text, at, at) ~= "{" then return nil end
		at += 1
		local result = {}
		skip()
		if string.sub(text, at, at) == "}" then at += 1 return result end
		while true do
			skip()
			local key = parseString()
			if key == nil then return nil end
			skip()
			if string.sub(text, at, at) ~= ":" then return nil end
			at += 1
			skip()
			local value = parseValue()
			if value == nil then return nil end
			result[key] = value
			skip()
			local char = string.sub(text, at, at)
			at += 1
			if char == "}" then return result end
			if char ~= "," then return nil end
		end
	end

	function parseValue(): any?
		skip()
		local char = string.sub(text, at, at)
		if char == "{" then return parseObject() end
		if char == '"' then return parseString() end
		local number = string.match(text, "^-?%d+%.?%d*", at)
		if number then at += #number return tonumber(number) end
		if string.sub(text, at, at + 3) == "true" then at += 4 return true end
		if string.sub(text, at, at + 4) == "false" then at += 5 return false end
		return nil
	end

	local ok, value = pcall(parseValue)
	if not ok or value == nil then return nil end
	-- Trailing junk means this was not one JSON document, which is exactly the
	-- shape two coalesced SSE frames used to produce.
	skip()
	if at <= #text then return nil end
	return value
end

return Net
