--!strict
-- One temporary client relay lifecycle for input and execution.
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Dispatch = require(script.Parent.Dispatch)
local ClientRelay = {}
function ClientRelay.playerFor(name: string?): Player
	if not RunService:IsRunning() then
		Dispatch.fail("NOT_RUNNING", "Client access needs a running playtest; this is an edit session.")
	end
	if not RunService:IsServer() then
		Dispatch.fail("WRONG_CONTEXT", "Address the playtest server's studioId for client access.")
	end
	local players = Players:GetPlayers()
	if #players == 0 then
		Dispatch.fail(
			"NO_PLAYER",
			"No player is in this session.",
			"Client access needs a running playtest. Use `playtest op=\"play\"`, "
				.. "then address this at the playtest's studioId."
		)
	end
	if name == nil or name == "" then
		if #players > 1 then
			Dispatch.fail(
				"AMBIGUOUS_PLAYER",
				string.format("%d players are in this session.", #players),
				"Name one with `player`."
			)
		end
		return players[1]
	end
	for _, player in players do
		if player.Name == name then
			return player
		end
	end
	Dispatch.fail("NO_PLAYER", string.format("No player named %q is in this session.", name))
	return players[1]
end


function ClientRelay.run(player: Player, name: string, source: string, attributes: { [string]: any }, timeout: number, prepare: ((LocalScript) -> ())?, ready: (() -> ())?): { [string]: any }
	local gui = player:FindFirstChildOfClass("PlayerGui")
	if not gui then Dispatch.fail("NO_PLAYER", player.Name .. " has no PlayerGui yet.") end
	local relay = Instance.new("LocalScript")
	local connection: RBXScriptConnection? = nil
	local answer: any = nil
	local ok, failure = pcall(function()
		relay.Name = name
		relay:SetAttribute("MCPClientRelay", true)
		relay.Source = source
		for key, value in attributes do relay:SetAttribute(key, value) end
		local remote = Instance.new("RemoteEvent")
		remote.Name = "Report"
		remote.Parent = relay
		if prepare then prepare(relay) end
		local started = false
		connection = remote.OnServerEvent:Connect(function(from, payload)
			if from ~= player or answer ~= nil or typeof(payload) ~= "table" then return end
			-- A capture can wait until its client relay is ready before starting
			-- the server window. Existing single-response relays are unchanged.
			if ready and payload.ready == true then
				if started then return end
				started = true
				local prepared, reason = pcall(ready)
				if not prepared then
					answer = { ok = false, reason = tostring(reason) }
					return
				end
				remote:FireClient(player, true)
			else
				answer = payload
			end
		end)
		relay.Parent = gui
		local deadline = os.clock() + timeout
		while answer == nil and os.clock() < deadline and player.Parent == Players do task.wait(0.05) end
	end)
	if connection then connection:Disconnect() end
	relay:Destroy()
	if not ok then Dispatch.fail("CLIENT_FAILED", tostring(failure)) end
	if answer == nil then
		Dispatch.fail("NO_ACK", string.format("The client did not respond within %gs (or disconnected).", timeout), "The temporary relay was removed; code may have made changes before timing out.")
	end
	return answer
end
return ClientRelay
