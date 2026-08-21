--!strict
--[[
	Thin HttpService wrapper.

	Plugins reach 127.0.0.1 through a per-plugin permission grant rather than the
	experience-wide "Allow HTTP Requests" setting, so the first request after
	install pops a permission dialog. That failure mode is turned into a message
	the user can act on instead of a raw Luau error.
]]

local HttpService = game:GetService("HttpService")

local Config = require(script.Parent.Config)

local Net = {}

export type Response = {
	ok: boolean,
	statusCode: number,
	body: string,
	error: string?,
}

--[[
	Performs a request and never throws. Callers branch on `ok`; `error` carries
	a user-facing explanation when the request could not be made at all.
]]
function Net.request(method: string, path: string, body: string?): Response
	local ok, result = pcall(function()
		return HttpService:RequestAsync({
			Url = Config.baseUrl() .. path,
			Method = method,
			Headers = Config.headers(),
			Body = body,
		})
	end)

	if not ok then
		return {
			ok = false,
			statusCode = 0,
			body = "",
			error = Net.explain(tostring(result)),
		}
	end

	local response = result :: any
	if response.Success then
		return {
			ok = true,
			statusCode = response.StatusCode,
			body = response.Body,
		}
	end

	--[[
		The request reached the bridge and it refused -- every `send()` on that
		side answers with `{ error: "..." }`, and that string is the actual reason
		(missing header, protocol mismatch, no Studio connected). Falling back to
		a bare status code discarded it and showed "handshake failed" instead,
		which is accurate about nothing. Decoded defensively: a body that is not
		JSON, or JSON without an `error` field, still gets a readable fallback.
	]]
	local decoded = Net.decode(response.Body)
	local reason = if typeof(decoded) == "table" and typeof((decoded :: any).error) == "string"
		then (decoded :: any).error
		else string.format("server responded %d", response.StatusCode)

	return {
		ok = false,
		statusCode = response.StatusCode,
		body = response.Body,
		error = reason,
	}
end

function Net.postJson(path: string, value: any): Response
	return Net.request("POST", path, HttpService:JSONEncode(value))
end

--[[
	Turns HttpService's terse errors into something the user can act on. These
	strings surface in the plugin widget, so they are written for a person, not
	for the agent.
]]
function Net.explain(message: string): string
	local lowered = string.lower(message)

	if string.find(lowered, "not enabled") or string.find(lowered, "permission") then
		return "Studio blocked the request. Open Plugins -> Manage Plugins, find "
			.. "Studio MCP, and allow it to reach 127.0.0.1."
	end
	if
		string.find(lowered, "connectfail")
		or string.find(lowered, "curl")
		or string.find(lowered, "could not connect")
		or string.find(lowered, "connection refused")
	then
		return string.format(
			"Nothing is listening on port %d. Start the server with "
				.. "`npx -y roblox-studio-mcp` (or check --port if you changed it).",
			Config.getPort()
		)
	end
	if string.find(lowered, "timedout") or string.find(lowered, "timeout") then
		return "The server stopped responding. It may have been restarted; "
			.. "the plugin will keep retrying."
	end
	return message
end

--[[
	Decodes a JSON body, returning nil rather than throwing on malformed input.
	A truncated frame is a transport hiccup, not a reason to kill the plugin.
]]
function Net.decode(body: string): any?
	local ok, value = pcall(HttpService.JSONDecode, HttpService, body)
	if not ok then
		return nil
	end
	return value
end

return Net
