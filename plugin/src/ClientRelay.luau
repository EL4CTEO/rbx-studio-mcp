--!strict
-- Shared client relay lifecycles for temporary calls and persistent diagnostics.
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Dispatch = require(script.Parent.Dispatch)
local LogBuffer = require(script.Parent.LogBuffer)
local ClientRelay = {}

-- Long-lived diagnostics use the same LocalScript/RemoteEvent replication path
-- as temporary client calls. The server owns the buffers and validates the
-- sender; the client never needs HTTP access.
local DIAGNOSTIC_SOURCE = [==[
local LogService = game:GetService("LogService")
local ScriptContext = game:GetService("ScriptContext")
local report = script:WaitForChild("Report", 10)
if not report then return end
local open = true
local connections = {}
local levels = {
	[Enum.MessageType.MessageOutput] = "print",
	[Enum.MessageType.MessageInfo] = "info",
	[Enum.MessageType.MessageWarning] = "warning",
	[Enum.MessageType.MessageError] = "error",
}
local function send(payload)
	if open and report.Parent then report:FireServer(payload) end
end
table.insert(connections, LogService.MessageOut:Connect(function(message, kind)
	send({level = levels[kind] or "print", message = string.sub(message, 1, 2000), timestamp = os.time()})
end))
pcall(function()
	table.insert(connections, ScriptContext.Error:Connect(function(message, stack, source)
		local path
		if typeof(source) == "Instance" then
			local ok, full = pcall(function() return source:GetFullName() end)
			path = if ok then full else source.Name
		end
		send({kind = "trace", message = string.sub(message, 1, 2000), stack = string.sub(stack, 1, 4000), source = path})
	end))
end)
script.Destroying:Connect(function()
	open = false
	for _, connection in connections do connection:Disconnect() end
end)
send({kind = "ready"})
]==]

local diagnosticsStarted = false
local diagnosticConnections: { [Player]: RBXScriptConnection } = {}
local diagnosticRelays: { [Player]: LocalScript } = {}
local diagnosticInstalling: { [Player]: boolean } = {}
local characterConnections: { [Player]: RBXScriptConnection } = {}
local playerAddedConnection: RBXScriptConnection? = nil
local playerRemovingConnection: RBXScriptConnection? = nil
local function installDiagnostics(player: Player)
	if diagnosticInstalling[player] or diagnosticConnections[player] then return end
	diagnosticInstalling[player] = true
	task.spawn(function()
		-- PlayerGui is server-visible (PlayerScripts is created on the client).
		local gui = player:FindFirstChildOfClass("PlayerGui") or player:WaitForChild("PlayerGui", 15)
		if not diagnosticsStarted or not gui or player.Parent ~= Players then diagnosticInstalling[player] = nil; return end
		local old = gui:FindFirstChild("MCPDiagnosticsRelay")
		if old then old:Destroy() end
		LogBuffer.startClient(player)
		local relay = Instance.new("LocalScript")
		local remote = Instance.new("RemoteEvent")
		local ok = pcall(function()
			relay.Name = "MCPDiagnosticsRelay"
			relay:SetAttribute("MCPClientRelay", true)
			relay.Source = DIAGNOSTIC_SOURCE
			remote.Name = "Report"
			remote.Parent = relay
			diagnosticConnections[player] = remote.OnServerEvent:Connect(function(from, payload)
				if from == player then LogBuffer.pushClient(player, payload) end
			end)
			relay.Parent = gui
			diagnosticRelays[player] = relay
		end)
		if not ok then
			if diagnosticConnections[player] then diagnosticConnections[player]:Disconnect() end
			diagnosticConnections[player] = nil
			relay:Destroy()
			LogBuffer.stopClient(player)
		end
		diagnosticInstalling[player] = nil
		if not characterConnections[player] then
			characterConnections[player] = player.CharacterAdded:Connect(function()
				task.delay(0.5, function()
					if not diagnosticsStarted or player.Parent ~= Players then return end
					local currentGui = player:FindFirstChildOfClass("PlayerGui")
					local current = diagnosticRelays[player]
					if current and current.Parent == currentGui then return end
					if diagnosticConnections[player] then diagnosticConnections[player]:Disconnect() end
					diagnosticConnections[player], diagnosticRelays[player] = nil, nil
					installDiagnostics(player)
				end)
			end)
		end
	end)
end

function ClientRelay.startDiagnostics()
	if diagnosticsStarted or not RunService:IsRunning() or not RunService:IsServer() then return end
	diagnosticsStarted = true
	playerAddedConnection = Players.PlayerAdded:Connect(installDiagnostics)
	playerRemovingConnection = Players.PlayerRemoving:Connect(function(player)
		if diagnosticConnections[player] then diagnosticConnections[player]:Disconnect() end
		diagnosticConnections[player] = nil
		if diagnosticRelays[player] then diagnosticRelays[player]:Destroy() end
		diagnosticRelays[player] = nil
		if characterConnections[player] then characterConnections[player]:Disconnect() end
		characterConnections[player] = nil
		LogBuffer.stopClient(player)
	end)
	for _, player in Players:GetPlayers() do installDiagnostics(player) end
end

function ClientRelay.stopDiagnostics()
	if not diagnosticsStarted then return end
	diagnosticsStarted = false
	if playerAddedConnection then playerAddedConnection:Disconnect() end
	if playerRemovingConnection then playerRemovingConnection:Disconnect() end
	playerAddedConnection, playerRemovingConnection = nil, nil
	for player, connection in diagnosticConnections do
		connection:Disconnect()
		if diagnosticRelays[player] then diagnosticRelays[player]:Destroy() end
		LogBuffer.stopClient(player)
	end
	for _, connection in characterConnections do connection:Disconnect() end
	table.clear(diagnosticConnections)
	table.clear(diagnosticRelays)
	table.clear(characterConnections)
end
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
