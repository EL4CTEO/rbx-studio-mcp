
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

-- One frame split over several reads: the case that timed out every big
-- script_create. Nothing may come out until the last piece lands, and then
-- exactly the one command.
local big = 'data: {"id":"big","op":"script.create","params":{"source":"' .. string.rep("x", 40000) .. '"}}\n\n'
local read = frameReader()
local got = {}
for at = 1, #big, 7000 do
	for _, frame in read(string.sub(big, at, at + 6999)) do
		table.insert(got, frame)
	end
end
assert(count(got) == 1, "split frame reassembled once, got " .. count(got))
assert(got[1].id == "big" and #got[1].params.source == 40000, "and intact")

-- The split landing between the two newlines of the terminator, then a second
-- frame riding on the same read as the tail of the first.
local r2 = frameReader()
assert(count(r2('data: {"id":"a","op":"x","params":{')) == 0, "partial yields nothing")
local rest = r2('}}\n')
local tailFirst = count(rest)
local rest2 = r2('\ndata: {"id":"b","op":"y","params":{}}\n\n')
assert(tailFirst + count(rest2) == 2, "both frames, once each, got " .. (tailFirst + count(rest2)))

-- A delivery that is one bare event with no framing at all still parses.
local r3 = frameReader()
local bare = r3('{"id":"c","op":"studio.ping","params":{}}')
assert(count(bare) == 1 and bare[1].op == "studio.ping", "unframed event")
assert(count(r3("\n\n")) == 0, "its late terminator adds nothing")

-- CRLF split across two reads.
local r4 = frameReader()
local crlf = count(r4('data: {"a":1}\r')) + count(r4('\n\r\n'))
assert(crlf == 1, "crlf split across reads, got " .. crlf)

-- A keepalive between halves of nothing, and each reader is its own.
local r5, r6 = frameReader(), frameReader()
assert(count(r5('data: {"id":"p",')) == 0, "partial held")
assert(count(r6(': ping\n\n')) == 0, "other reader unaffected")
assert(count(r5('"op":"q","params":{}}\n\n')) == 1, "first reader completes")

-- A multi-megabyte frame in many small reads stays linear: this re-scanned the
-- whole held buffer on every read and took seconds.
local huge = 'data: {"id":"h","op":"script.create","params":{"source":"' .. string.rep("y", 4 * 1024 * 1024) .. '"}}\n\n'
local r8 = frameReader()
local hugeGot = 0
local startedAt = os.clock()
for at = 1, #huge, 4096 do
	hugeGot += count(r8(string.sub(huge, at, at + 4095)))
end
assert(hugeGot == 1, "huge frame reassembled once, got " .. hugeGot)
assert(os.clock() - startedAt < 2, "huge frame took " .. (os.clock() - startedAt) .. "s")

-- A keepalive whose terminator straddles two reads, then a command.
local r9 = frameReader()
local n9 = count(r9(": ping\n")) + count(r9('\ndata: {"id":"k","op":"x","params":{}}\n\n'))
assert(n9 == 1, "straddled keepalive then command, got " .. n9)

print("all reader cases pass")
