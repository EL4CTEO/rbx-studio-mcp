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
local Emulation = require(script.Parent.Parent.Emulation)

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
	Where the client actually read the last pointer event, against where it was
	aimed.

	Measured, because it cannot be derived. A click sent at (300,300) with a
	Galaxy S25 Ultra emulated is read at (253,242); the same click with an
	iPhone 16 in portrait is read at (300,183). Constant per configuration, and
	fitting no formula over device resolution, viewport size and GUI inset that
	holds for both -- the horizontal term matches (device - viewport) / 2 and
	the vertical term does not.

	So it is reported rather than predicted. The caller aims once, sees where it
	landed, and corrects; that works on every device, in both orientations, and
	with no device emulated at all, which no formula here has managed.

	`InputBegan` rather than `GetMouseLocation`: the latter is frozen at the
	last real click under touch emulation -- twenty samples across two sent
	moves never changed it -- and is offset from `InputBegan.Position` by the
	GUI inset besides. Phone emulation also turns MouseEnabled off and delivers
	these as Touch, so both types are watched.
]]
local landed = nil
local aimed = nil
UserInputService.InputBegan:Connect(function(input)
	local kind = input.UserInputType
	if aimed ~= nil and (kind == Enum.UserInputType.MouseButton1 or kind == Enum.UserInputType.Touch) then
		landed = { sent = aimed, seen = { x = input.Position.X, y = input.Position.Y } }
	end
end)

--[[
	The on-screen pointer.

	Roblox's own arrow texture, not one of ours. Shipping the pixels was tried
	first -- base64 in a StringValue, decoded into an EditableImage -- and it
	cannot work: writing to an EditableImage is gated on an experience-level
	security setting that is off by default, so every place would have to opt in
	before the cursor appeared. `WritePixelsBuffer` says so outright ("go to the
	Security Tab in Experience Settings to enable this API") and the failure was
	invisible, because a cursor that fails to build just does not show up.

	An image id needs neither. The primary is a public Creator Store pointer;
	`rbxasset://` content, which ships inside the client itself and can never
	fail to resolve, is the fallback for the day that asset is moderated or
	pulled. Both are tinted and given a halo -- the point is to show what the
	agent is aiming at, and a pointer indistinguishable from the player's own
	would show nothing.
]]
local ARROW = "rbxassetid://15718988485"
local ARROW_FALLBACK = "rbxasset://textures/Cursors/KeyboardMouse/ArrowCursor.png"
local ACCENT = Color3.fromRGB(255, 162, 0)

--[[
	Where each arrow's tip sits inside its own image, as a fraction of it.

	Both measured rather than guessed, and they are nothing alike -- the store
	image is padded and the built-in one puts its tip at the exact centre of a
	64x64 square -- so the anchor has to change with the image. Getting this
	wrong is the quiet kind of wrong: the pointer still glides to the right
	area and still ripples, it just lies about which pixel it hit.

	The tint only works on a filled arrow. An outline-only cursor multiplies to
	black and looks like the image failed to load.
]]
local HOTSPOT = Vector2.new(0.36, 0.32)
local HOTSPOT_FALLBACK = Vector2.new(0.484, 0.5)

local cursor = nil
local cursorGui = nil

local function makeCursor()
	if relay:GetAttribute("Cursor") ~= true then
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
	label.Size = UDim2.fromOffset(52, 52)
	label.AnchorPoint = HOTSPOT
	label.Position = UDim2.fromScale(0.5, 0.5)
	label.Image = ARROW
	label.ImageColor3 = ACCENT
	label.ZIndex = 100
	label.Parent = gui

	-- Centred on the tip rather than on the image, and behind the arrow, so the
	-- pointer stays findable against a busy scene without hiding what it targets.
	local halo = Instance.new("Frame")
	halo.Name = "Halo"
	halo.AnchorPoint = Vector2.new(0.5, 0.5)
	halo.Position = UDim2.fromScale(HOTSPOT.X, HOTSPOT.Y)
	halo.Size = UDim2.fromOffset(32, 32)
	halo.BackgroundColor3 = ACCENT
	halo.BackgroundTransparency = 0.45
	halo.BorderSizePixel = 0
	halo.ZIndex = 99
	local round = Instance.new("UICorner")
	round.CornerRadius = UDim.new(1, 0)
	round.Parent = halo
	halo.Parent = label

	gui.Parent = relay.Parent
	cursorGui = gui
	cursor = label

	-- Swapped only if the store image really did not arrive. Checked after the
	-- GUI is live so the pointer is on screen either way, and never blocks.
	task.spawn(function()
		local waited = 0
		while not label.IsLoaded and waited < 3 do
			task.wait(0.1)
			waited += 0.1
		end
		if not label.IsLoaded then
			label.Image = ARROW_FALLBACK
			-- The tip moves with the image, so the anchor and the halo move too.
			label.AnchorPoint = HOTSPOT_FALLBACK
			halo.Position = UDim2.fromScale(HOTSPOT_FALLBACK.X, HOTSPOT_FALLBACK.Y)
		end
	end)
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
	ring.BackgroundColor3 = ACCENT
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
		moveCursor(step.x, step.y, 0.3)
		virtual:SendMousePosition(Vector2.new(step.x, step.y))
	elseif kind == "click" then
		local button = Enum.UserInputType[step.button or "MouseButton1"]
		local at = Vector2.new(step.x, step.y)
		aimed = { x = step.x, y = step.y }
		-- Travel first, then click. Teleporting the pointer onto the target at
		-- the same instant it fires looks like nothing happened at all.
		moveCursor(step.x, step.y, 0.3)
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

report:FireServer({ ok = true, performed = performed, landed = landed })
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
	relay:SetAttribute("Cursor", params.cursor ~= false)
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
		--[[
			Named so the caller can tell why a click that was delivered still hit
			nothing. `landed` carries the arithmetic; this says what to turn off.
		]]
		emulation = Emulation.summary(),
		-- Where the client read the last click, against where it was aimed. See
		-- the note in RELAY_SOURCE for why this is measured and not computed.
		landed = result.landed,
	}
end

function Input.register()
	Dispatch.registerAll("input", {
		send = Input.send,
	})
end

return Input
