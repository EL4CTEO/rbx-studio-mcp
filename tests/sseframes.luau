
local function count(t) local n = 0 for _ in t do n += 1 end return n end

-- Sanity: the stub must reject the string the old parser fed to JSONDecode.
assert(Net.decode('{"event":"clients","count":1}\n\ndata: {"event":"agent"}') == nil,
	"stub must reject two documents in one string")
assert(Net.decode('{"event":"clients","count":1}') ~= nil, "stub accepts one document")

-- The exact chunk the sniffer captured on a departure.
local both = 'data: {"event":"clients","count":1}\n\ndata: {"event":"agent","state":"finished"}\n\n'
local f = parseFrames(both)
assert(count(f) == 2, "two coalesced events, got " .. count(f))
assert(f[1].event == "clients" and f[1].count == 1, "first is the count")
assert(f[2].event == "agent" and f[2].state == "finished", "second is the departure")

-- The connect greeting sharing a chunk with the first real frame.
local g = parseFrames(': connected 1\n\ndata: {"event":"clients","count":1}\n\n')
assert(count(g) == 1, "comment skipped, frame kept, got " .. count(g))
assert(g[1].count == 1, "and decoded")

-- A lone command: the case that must never regress.
local c = parseFrames('data: {"id":"abc","op":"studio.ping","params":{}}\n\n')
assert(count(c) == 1 and c[1].op == "studio.ping", "a lone command still parses")

-- A command sharing a chunk with a keepalive and an event. This is the one that
-- silently lost tool calls.
local m = parseFrames(': ping\n\ndata: {"id":"x","op":"exec.run","params":{}}\n\ndata: {"event":"clients","count":2}\n\n')
assert(count(m) == 2, "keepalive dropped, command and event kept, got " .. count(m))
assert(m[1].op == "exec.run", "the command survived")
assert(m[2].event == "clients", "and the event after it")

assert(count(parseFrames('data: {"a":1}\r\n\r\n')) == 1, "crlf framing")
assert(count(parseFrames(": ping\n\n")) == 0, "a lone keepalive yields nothing")
assert(count(parseFrames("")) == 0, "empty yields nothing")
assert(count(parseFrames("not json\n\n")) == 0, "garbage is dropped, not raised")

print("all parser cases pass")
