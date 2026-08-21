--!strict
--[[
	Connection settings for the Studio MCP plugin.

	The port must match the one the Node server was started with (`--port`, or
	the ROBLOX_STUDIO_MCP_PORT environment variable). It is stored as a plugin
	setting so a user running on a non-default port only has to set it once.
]]

local Config = {}

Config.PLUGIN_VERSION = "0.1.1"

-- Fingerprint of plugin/src, stamped in by scripts/build-plugin.mjs. The server
-- computes the same hash from its own copy of the sources and compares, so a
-- plugin left running from an older build is reported rather than silently
-- answering with stale handlers. Stays "dev" when the tree is loaded unbuilt.
Config.BUILD_ID = "dev"
Config.PROTOCOL_VERSION = 1
Config.DEFAULT_PORT = 44755

-- Header the bridge requires on every request. A web page cannot set it
-- cross-origin without a preflight the bridge never answers, which is what
-- keeps a malicious site from driving Studio through the loopback port.
Config.CLIENT_HEADER = "x-roblox-studio-mcp"

-- How long to wait before retrying after the stream drops. Studio closes SSE
-- connections at the 30 minute mark, so reconnects are routine, not exceptional.
Config.RECONNECT_DELAY = 1
Config.MAX_RECONNECT_DELAY = 30

-- How long a healthy long-poll session runs before standing aside so streaming
-- can be tried again. Long enough that a Studio which genuinely cannot stream
-- is not reconnecting constantly, short enough that a session downgraded by one
-- unlucky attempt does not spend the rest of its life slower than it should be.
Config.RESTREAM_INTERVAL = 60

local port: number? = nil

function Config.setPort(value: number)
	port = value
end

function Config.getPort(): number
	return port or Config.DEFAULT_PORT
end

function Config.baseUrl(): string
	return string.format("http://127.0.0.1:%d", Config.getPort())
end

function Config.headers(): { [string]: string }
	return {
		[Config.CLIENT_HEADER] = tostring(Config.PROTOCOL_VERSION),
		["Content-Type"] = "application/json",
	}
end

return Config
