--!strict
--[[
	Handler registry and the single error boundary around every command.

	Handlers raise failures with `Dispatch.fail(code, message, hint)`. The hint is
	forwarded verbatim to the agent, so it should say what to do next ("call find
	first to get a valid path"), not just what went wrong.
]]

local Dispatch = {}

export type Error = {
	code: string,
	message: string,
	hint: string?,
}

export type Handler = (params: { [string]: any }) -> any

local handlers: { [string]: Handler } = {}

function Dispatch.register(op: string, handler: Handler)
	handlers[op] = handler
end

--[[
	Registers every entry of `map` under the prefix, e.g. `registerAll("script",
	{ read = fn })` exposes "script.read".
]]
function Dispatch.registerAll(prefix: string, map: { [string]: Handler })
	for name, handler in map do
		handlers[prefix .. "." .. name] = handler
	end
end

--[[
	Raises a structured failure. Always call this rather than `error("...")` so
	the agent receives a code it can branch on and a hint it can act on.
]]
function Dispatch.fail(code: string, message: string, hint: string?): never
	error({ code = code, message = message, hint = hint }, 0)
end

export type Result = {
	id: string,
	ok: boolean,
	data: any?,
	error: Error?,
}

--[[
	Runs one command and returns the frame to POST back. Never throws: an
	unhandled error inside a handler becomes a HANDLER_ERROR result, because a
	crashed dispatch would leave the server's promise hanging until it times out.
]]
function Dispatch.invoke(id: string, op: string, params: { [string]: any }?): Result
	local handler = handlers[op]
	if not handler then
		return {
			id = id,
			ok = false,
			error = {
				code = "UNKNOWN_OP",
				message = string.format('This Studio plugin has no handler for "%s".', op),
				hint = "The plugin is older than the MCP server. Update the Studio MCP "
					.. "plugin to the version matching your server.",
			},
		}
	end

	local ok, result = pcall(handler, params or {})
	if ok then
		return { id = id, ok = true, data = result }
	end

	if typeof(result) == "table" and (result :: any).code then
		return { id = id, ok = false, error = result :: Error }
	end

	return {
		id = id,
		ok = false,
		error = {
			code = "HANDLER_ERROR",
			message = string.format('"%s" failed: %s', op, tostring(result)),
		},
	}
end

return Dispatch
