local guid = 0
local listeners = {}
local LogService = {
	GetLogHistory = function() return {} end,
	MessageOut = { Connect = function(_, fn) listeners.message = fn end },
}
local ScriptContext = { Error = { Connect = function(_, fn) listeners.error = fn end } }
local HttpService = { JSONEncode = function(_, value)
	local parts = {}
	for key, item in value do
		if type(item) == "userdata" then error("cannot encode") end
		table.insert(parts, string.format("%q:%q", tostring(key), tostring(item)))
	end
	table.sort(parts)
	return "{" .. table.concat(parts, ",") .. "}"
end, GenerateGUID = function()
	guid += 1
	return "token-" .. tostring(guid)
end }
local game = { GetService = function(_, name)
	return ({ LogService = LogService, ScriptContext = ScriptContext, HttpService = HttpService })[name]
end }
local Enum = { MessageType = {
	MessageOutput = { Value = 1 }, MessageInfo = { Value = 2 },
	MessageWarning = { Value = 3 }, MessageError = { Value = 4 },
} }
