local perf = ...
local function add(stream, level, message)
	stream.sequence += 1
	table.insert(stream.entries, { sequence = stream.sequence, level = level, message = message, timestamp = 1 })
end
local studio = streams.studio
add(studio, "print", "one")
add(studio, "error", "two")
local first = perf.console({ limit = 1 })
assert(#first.items == 1 and first.items[1].message == "two" and first.dropped == 1)
assert(first.nextCursor == "studio-token:2")
add(studio, "print", "three")
local newer = perf.console({ since = first.nextCursor })
assert(#newer.items == 1 and newer.items[1].message == "three")
assert(newer.nextCursor == "studio-token:3")
local filtered = perf.console({ since = first.nextCursor, level = "error" })
assert(#filtered.items == 0 and filtered.nextCursor == "studio-token:3")
add(studio, "error", "four")
local afterFilter = perf.console({ since = filtered.nextCursor, level = "error" })
assert(#afterFilter.items == 1 and afterFilter.items[1].message == "four")
studio.entries = { studio.entries[4] }
studio.dropped = 3
local evicted = perf.console({ since = first.nextCursor })
assert(evicted.evicted == 1 and evicted.items[1].message == "four")
local ok, err = pcall(function() perf.console({ since = "other-session:3" }) end)
assert(not ok and err.code == "BAD_CURSOR")
add(streams.Alice, "warning", "alice only")
add(streams.Bob, "error", "bob only")
local alice = perf.console({ target = "client", player = "Alice" })
assert(#alice.items == 1 and alice.items[1].message == "alice only")
assert(alice.nextCursor == "alice-token:1" and alice.player == "Alice")
local bob = perf.console({ target = "client", player = "Bob" })
assert(#bob.items == 1 and bob.items[1].message == "bob only")
ok, err = pcall(function() perf.console({ target = "client", player = "Bob", since = alice.nextCursor }) end)
assert(not ok and err.code == "BAD_CURSOR")
ok, err = pcall(function() perf.console({ target = "client" }) end)
assert(not ok and err.code == "AMBIGUOUS_PLAYER")
print("perf console: ok")
studio.entries, studio.sequence = {}, 0
for i = 1, 7 do add(studio, if i % 2 == 0 then "error" else "print", tostring(i)) end
local drain = perf.console({mode = "drain", limit = 2})
assert(drain.items[1].message == "1" and drain.items[2].message == "2" and drain.nextCursor == "studio-token:2" and drain.hasMore)
local seen = 2
while drain.hasMore do
 drain = perf.console({mode = "drain", limit = 2, since = drain.nextCursor})
 for _, item in drain.items do seen += 1; assert(item.message == tostring(seen)) end
end
assert(seen == 7 and drain.nextCursor == "studio-token:7")
local filteredDrain = perf.console({mode = "drain", limit = 1, since = "studio-token:0", level = "error"})
assert(filteredDrain.items[1].message == "2" and filteredDrain.nextCursor == "studio-token:3")
studio.entries, studio.sequence = {}, 0
for i = 1, 10 do add(studio, "error", string.rep("x", 2000)) end
local sizeDrain = perf.console({mode = "drain", limit = 500})
assert(#sizeDrain.items < 10 and sizeDrain.hasMore)
assert(sizeDrain.nextCursor == "studio-token:" .. tostring(#sizeDrain.items))
local grouped = perf.console({mode = "drain", group = true, limit = 3})
assert(#grouped.items == 1 and grouped.items[1].count == 3 and grouped.nextCursor == "studio-token:3")
assert(grouped.items[1].firstTimestamp == 1 and grouped.items[1].lastTimestamp == 1)
print("console: ordered drain, filtering, budget continuation and grouping pass")
