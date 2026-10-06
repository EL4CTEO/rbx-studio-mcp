-- A small JSON encoder for standalone tests. Live tests cover Roblox's encoder.
local function jsonEncode(value)
	local kind = type(value)
	if kind == "nil" then return "null" end
	if kind == "number" or kind == "boolean" then return tostring(value) end
	if kind == "string" then
		local text = value:gsub('[%z\1-\31\\"]', function(char)
			if char == '"' or char == '\\' then return '\\' .. char end
			return string.format("\\u%04x", string.byte(char))
		end)
		return '"' .. text .. '"'
	end
	assert(kind == "table", "unsupported JSON value")
	local count, array = 0, true
	for key in value do count += 1; if type(key) ~= "number" or key < 1 or key > #value then array = false end end
	array = array and count == #value
	local parts = {}
	if array then for _, item in value do table.insert(parts, jsonEncode(item)) end
	else for key, item in value do table.insert(parts, jsonEncode(tostring(key)) .. ":" .. jsonEncode(item)) end end
	return (if array then "[" else "{") .. table.concat(parts, ",") .. (if array then "]" else "}")
end
local guidNumber = 0
local HttpService = { JSONEncode = function(_, value) return jsonEncode(value) end,
	GenerateGUID = function() guidNumber += 1; return "test-guid-" .. guidNumber end }
