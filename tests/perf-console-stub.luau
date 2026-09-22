local game = { GetService = function() return {} end }
local alice = { Name = "Alice" }
local bob = { Name = "Bob" }
local players = { Alice = alice, Bob = bob }
local ClientRelay = { playerFor = function(name)
	if not name then Dispatch.fail("AMBIGUOUS_PLAYER", "Name one with player") end
	if not players[name] then Dispatch.fail("NO_PLAYER", "Unknown player") end
	return players[name]
end }
local streams = {
	studio = { token = "studio-token", entries = {}, sequence = 0, dropped = 0 },
	Alice = { token = "alice-token", entries = {}, sequence = 0, dropped = 0 },
	Bob = { token = "bob-token", entries = {}, sequence = 0, dropped = 0 },
}
local LogBuffer = {
	stream = function(player)
		local stream = streams[if player then player.Name else "studio"]
		return stream.entries, stream.dropped, stream.token, stream.sequence, 10
	end,
	clientReady = function() return true end,
}
