--!strict
--[[
	Synthetic keyboard and mouse input, delivered to a running playtest.

	This was written off twice before it was found. `VirtualInputManager` needs
	the RobloxScript capability and `VirtualUser` needs LocalUser -- both closed
	to plugins, both the obvious place to look, and both dead ends. The third
	door is `UserInputService:CreateVirtualInput()`, which is Security None and
	hands back a `VirtualInput` with SendKey, SendMouseButton, SendMousePosition,
	SendMouseDelta, SendTextInput and SendPointerAction. Measured: a synthetic W
	walked the character 25.6 studs.

	The catch is where it has to happen. Input belongs to the DataModel that
	creates the VirtualInput, and the character is driven by the *client*. Called
	from the playtest's server session -- the one this plugin can reach -- every
	send succeeds and nothing moves. That is the worst possible failure: a green
	result for an action that did nothing, which is the exact class of bug this
	project keeps finding in other people's tools.

	So the server does not send the input. It parents a LocalScript into the
	player's PlayerGui, which runs on their client, and that script does the
	sending and reports back over a RemoteEvent. Nothing here reports success
	until the client says it happened.
]]

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Dispatch = require(script.Parent.Parent.Dispatch)

local Input = {}

-- Long enough for a slow client to start the script and work through a batch,
-- short enough that a client which never reports fails inside a tool call.
local ACK_TIMEOUT = 20
local MAX_STEPS = 40
local MAX_HOLD = 10

--[[
	The relay, fixed rather than generated.

	Building Luau from the request would mean pasting caller-supplied names into
	source, so a key called `A) print("owned") --` would run. The plan travels as
	JSON on an attribute instead, and this script only ever indexes enums by name
	and checks the result.
]]
local RELAY_SOURCE = [==[
local UserInputService = game:GetService("UserInputService")
local HttpService = game:GetService("HttpService")

local relay = script
local report = relay:WaitForChild("Report", 10)
if report == nil then
	return
end

local ok, plan = pcall(function()
	return HttpService:JSONDecode(relay:GetAttribute("Plan"))
end)
if not ok or typeof(plan) ~= "table" then
	report:FireServer({ ok = false, reason = "the plan did not decode on the client" })
	return
end

local virtual = UserInputService:CreateVirtualInput()
local performed = {}

for _, step in plan do
	local kind = step.kind
	if kind == "key" then
		local code = Enum.KeyCode[step.key]
		if step.action == "release" then
			virtual:SendKey(false, code, false)
		else
			virtual:SendKey(true, code, false)
			if step.action ~= "press" then
				task.wait(step.hold or 0.08)
				virtual:SendKey(false, code, false)
			end
		end
	elseif kind == "move" then
		virtual:SendMousePosition(Vector2.new(step.x, step.y))
	elseif kind == "click" then
		local button = Enum.UserInputType[step.button or "MouseButton1"]
		local at = Vector2.new(step.x, step.y)
		virtual:SendMousePosition(at)
		virtual:SendMouseButton(at, button, true, 0)
		if step.action ~= "press" then
			task.wait(step.hold or 0.05)
			virtual:SendMouseButton(at, button, false, 0)
		end
	elseif kind == "text" then
		virtual:SendTextInput(step.text)
	end
	table.insert(performed, kind)
	if step.after ~= nil and step.after > 0 then
		task.wait(step.after)
	end
end

report:FireServer({ ok = true, performed = performed })
]==]

local function playerFor(name: string?): Player
	local players = Players:GetPlayers()
	if #players == 0 then
		Dispatch.fail(
			"NO_PLAYER",
			"No player is in this session.",
			"Input needs a running playtest with a character. Use `playtest op=\"play\"`, "
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

--[[
	Turns the request into steps the relay understands, validating names here
	rather than on the client where a bad one would silently do nothing.
]]
local function planFrom(params: { [string]: any }): { { [string]: any } }
	local steps = params.steps
	if typeof(steps) ~= "table" or #(steps :: { any }) == 0 then
		Dispatch.fail("BAD_PARAMS", "input needs a `steps` array.")
	end
	if #(steps :: { any }) > MAX_STEPS then
		Dispatch.fail(
			"TOO_MANY",
			string.format("%d steps, over the limit of %d.", #(steps :: { any }), MAX_STEPS)
		)
	end

	local plan: { { [string]: any } } = {}
	for index, raw in steps :: { { [string]: any } } do
		local kind = tostring(raw.kind or "key")
		local step: { [string]: any } = { kind = kind }

		if raw.after ~= nil then
			step.after = math.clamp(tonumber(raw.after) or 0, 0, MAX_HOLD)
		end
		if raw.hold ~= nil then
			step.hold = math.clamp(tonumber(raw.hold) or 0, 0, MAX_HOLD)
		end

		if kind == "key" then
			local key = tostring(raw.key or "")
			local okKey = pcall(function()
				return (Enum.KeyCode :: any)[key]
			end)
			if not okKey or key == "" then
				Dispatch.fail(
					"BAD_KEY",
					string.format("Step %d: %q is not a KeyCode.", index, key),
					'Use names from Enum.KeyCode, e.g. "W", "Space", "LeftShift", "E".'
				)
			end
			step.key = key
			step.action = tostring(raw.action or "tap")
		elseif kind == "click" or kind == "move" then
			step.x = tonumber(raw.x) or 0
			step.y = tonumber(raw.y) or 0
			if kind == "click" then
				local button = tostring(raw.button or "MouseButton1")
				local okButton = pcall(function()
					return (Enum.UserInputType :: any)[button]
				end)
				if not okButton then
					Dispatch.fail(
						"BAD_PARAMS",
						string.format("Step %d: %q is not a UserInputType.", index, button),
						'Use "MouseButton1", "MouseButton2" or "MouseButton3".'
					)
				end
				step.button = button
				step.action = tostring(raw.action or "tap")
			end
		elseif kind == "text" then
			step.text = tostring(raw.text or "")
		else
			Dispatch.fail(
				"BAD_PARAMS",
				string.format("Step %d: unknown kind %q.", index, kind),
				'Use "key", "click", "move" or "text".'
			)
		end

		table.insert(plan, step)
	end
	return plan
end

function Input.send(params: { [string]: any }): { [string]: any }
	--[[
		Refused rather than attempted. In an edit session VirtualInput does work,
		but it delivers into the editor's own DataModel where there is no game
		and no character -- so it would look like it ran and change nothing.
	]]
	if not RunService:IsRunning() then
		Dispatch.fail(
			"NOT_RUNNING",
			"Input needs a running playtest; this is an edit session.",
			"Start one with `playtest op=\"play\"`, then address this at the playtest's studioId."
		)
	end

	local plan = planFrom(params)
	local player = playerFor(if typeof(params.player) == "string" then params.player else nil)
	local playerGui = player:FindFirstChildOfClass("PlayerGui")
	if playerGui == nil then
		Dispatch.fail("NO_PLAYER", string.format("%s has no PlayerGui yet.", player.Name))
	end

	local remote = Instance.new("RemoteEvent")
	remote.Name = "Report"

	local relay = Instance.new("LocalScript")
	relay.Name = "MCPInputRelay"
	relay.Source = RELAY_SOURCE
	relay:SetAttribute("Plan", HttpService:JSONEncode(plan))
	remote.Parent = relay

	local answer: { [string]: any }? = nil
	local connection = remote.OnServerEvent:Connect(function(_from, payload)
		if typeof(payload) == "table" then
			answer = payload :: { [string]: any }
		end
	end)

	-- Parenting last: the script starts the moment it lands, and it waits for
	-- the RemoteEvent, so both must already be in place.
	relay.Parent = playerGui

	local deadline = os.clock() + ACK_TIMEOUT
	while answer == nil and os.clock() < deadline do
		task.wait(0.05)
	end

	connection:Disconnect()
	relay:Destroy()

	if answer == nil then
		Dispatch.fail(
			"NO_ACK",
			string.format("The client did not confirm the input within %ds.", ACK_TIMEOUT),
			"Nothing here can tell whether some of it was delivered. Read `character op=\"state\"` "
				.. "to see where things actually are."
		)
	end

	local result = answer :: { [string]: any }
	if result.ok ~= true then
		Dispatch.fail("INPUT_FAILED", tostring(result.reason or "the client refused the plan"))
	end

	return {
		delivered = true,
		steps = #plan,
		player = player.Name,
		performed = result.performed,
	}
end

function Input.register()
	Dispatch.registerAll("input", {
		send = Input.send,
	})
end

return Input
