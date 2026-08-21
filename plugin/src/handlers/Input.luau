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

local CursorImage = require(script.Parent.Parent.CursorImage)
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

	It also draws the pointer. Synthetic mouse input moves nothing the eye can
	follow -- the click lands and the only evidence is whatever it changed -- so
	anyone watching a playtest being driven sees results with no cause. The
	cursor is a real ImageLabel tweened to each target before the click is sent,
	which makes the agent's aim visible and, when it misses, visibly wrong.
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

--[[
	The on-screen pointer.

	Pixels rather than an asset id: a LocalScript cannot decode a PNG, and
	uploading one would put a manual step between installing this and having a
	cursor. They arrive base64'd in a StringValue and become an EditableImage.
]]
local cursor = nil
local cursorGui = nil
local hotspot = Vector2.new(0.08, 0.06)

local function makeCursor()
	local holder = relay:FindFirstChild("CursorPixels")
	if holder == nil then
		return
	end

	local ok, image = pcall(function()
		local EncodingService = game:GetService("EncodingService")
		local AssetService = game:GetService("AssetService")
		local size = Vector2.new(48, 48)
		local pixels = EncodingService:Base64Decode(buffer.fromstring(holder.Value))
		local editable = AssetService:CreateEditableImage({ Size = size })
		editable:WritePixelsBuffer(Vector2.zero, size, pixels)
		return editable
	end)
	if not ok then
		return
	end

	local gui = Instance.new("ScreenGui")
	gui.Name = "MCPCursor"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = 2147483647
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling

	local label = Instance.new("ImageLabel")
	label.Name = "Pointer"
	label.BackgroundTransparency = 1
	label.Size = UDim2.fromOffset(30, 30)
	label.AnchorPoint = hotspot
	label.Position = UDim2.fromScale(0.5, 0.5)
	label.ImageContent = Content.fromObject(image)
	label.ZIndex = 100
	label.Parent = gui

	gui.Parent = relay.Parent
	cursorGui = gui
	cursor = label
end

-- Moves the pointer there and waits, so the click is seen to be aimed.
local function moveCursor(x, y, duration)
	if cursor == nil then
		return
	end
	local TweenService = game:GetService("TweenService")
	local goal = UDim2.fromOffset(x, y)
	local tween = TweenService:Create(
		cursor,
		TweenInfo.new(duration, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ Position = goal }
	)
	tween:Play()
	tween.Completed:Wait()
end

-- A ring that expands and fades where the click landed.
local function pulse()
	if cursor == nil then
		return
	end
	local TweenService = game:GetService("TweenService")
	local ring = Instance.new("Frame")
	ring.AnchorPoint = Vector2.new(0.5, 0.5)
	ring.Position = UDim2.new(cursor.Position.X.Scale, cursor.Position.X.Offset, cursor.Position.Y.Scale, cursor.Position.Y.Offset)
	ring.Size = UDim2.fromOffset(8, 8)
	ring.BackgroundColor3 = Color3.fromRGB(255, 162, 0)
	ring.BackgroundTransparency = 0.25
	ring.BorderSizePixel = 0
	ring.ZIndex = 99
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(1, 0)
	corner.Parent = ring
	ring.Parent = cursorGui

	local grow = TweenService:Create(
		ring,
		TweenInfo.new(0.35, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ Size = UDim2.fromOffset(52, 52), BackgroundTransparency = 1 }
	)
	grow:Play()
	grow.Completed:Connect(function()
		ring:Destroy()
	end)
end

makeCursor()

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
		moveCursor(step.x, step.y, 0.22)
		virtual:SendMousePosition(Vector2.new(step.x, step.y))
	elseif kind == "click" then
		local button = Enum.UserInputType[step.button or "MouseButton1"]
		local at = Vector2.new(step.x, step.y)
		-- Travel first, then click. Teleporting the pointer onto the target at
		-- the same instant it fires looks like nothing happened at all.
		moveCursor(step.x, step.y, 0.22)
		pulse()
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

-- Left up for a moment so the last action is still visible when the tool returns.
task.wait(0.25)
if cursorGui ~= nil then
	cursorGui:Destroy()
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

	--[[
		The pointer's pixels, as a child rather than an attribute.

		12KB of base64 is comfortably inside what an attribute holds today, but
		nothing about that limit is promised, and a cursor that silently stops
		appearing when the image grows is a bad way to find out.
	]]
	if params.cursor ~= false then
		local pixels = Instance.new("StringValue")
		pixels.Name = "CursorPixels"
		pixels.Value = CursorImage.base64
		pixels.Parent = relay
	end

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
