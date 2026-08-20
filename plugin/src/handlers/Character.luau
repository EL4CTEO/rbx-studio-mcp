--!strict
--[[
	Driving the player character during a playtest.

	This exists because the obvious approach is closed. `VirtualInputManager`
	wants the RobloxScript capability and `VirtualUser` wants LocalUser, and both
	refuse a plugin outright -- measured, not assumed:

		The current thread cannot call 'SendKeyEvent' (lacking capability RobloxScript)
		The current thread cannot call 'SetKeyDown' (lacking capability LocalUser)

	Roblox's own MCP server simulates input because it is first-party and runs
	with privileges a plugin is never granted. So this drives the Humanoid
	directly instead.

	That turns out to be the better instrument anyway. Synthetic keystrokes test
	the input stack; what anyone actually wants to know is whether the character
	can reach the door, whether the trap fires, whether the checkpoint saves --
	all of which are answered more precisely by asking the Humanoid to walk there
	and reporting whether it arrived.

	Pathfinding is what makes "go there" mean something. `Humanoid:MoveTo` walks
	in a straight line and stops dead against the first wall; a computed path
	routes around geometry, which is the difference between testing a route and
	testing a collision.

	Everything here needs a running playtest, and the character only exists in
	the playtest's data model, so these must be addressed to that session.
]]

local PathfindingService = game:GetService("PathfindingService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Dispatch = require(script.Parent.Parent.Dispatch)
local Paths = require(script.Parent.Parent.Paths)

local Character = {}

-- How long to wait for a walk before calling it stuck. Long enough to cross a
-- large room, short enough that a failed route does not hold the request open.
local MOVE_TIMEOUT = 30

-- How close counts as arrived. `MoveToFinished` fires on its own timeout as
-- well as on arrival, so distance is what actually decides success.
local ARRIVAL_RADIUS = 6

local function parseVector(value: any, what: string): Vector3
	if typeof(value) ~= "string" then
		Dispatch.fail("BAD_PARAMS", string.format("%s must be a string like \"10, 5, 0\".", what))
	end
	local x, y, z = string.match(value, "^%s*(-?[%d%.]+)%s*,%s*(-?[%d%.]+)%s*,%s*(-?[%d%.]+)%s*$")
	if x == nil then
		Dispatch.fail("BAD_PARAMS", string.format("%s must look like \"10, 5, 0\", got %q.", what, value))
	end
	return Vector3.new(tonumber(x) :: number, tonumber(y) :: number, tonumber(z) :: number)
end

--[[
	The character to drive, and the Humanoid inside it.

	Named lookup comes first so a multiplayer test can address one player; with
	one player the name is unnecessary and omitting it is the normal case.
]]
local function humanoidOf(params: { [string]: any }): (Model, Humanoid, Player)
	if RunService:IsEdit() then
		Dispatch.fail(
			"NOT_RUNNING",
			"There is no character in an edit session.",
			"Start a playtest with `playtest op=play`, then address this to the playtest's studioId."
		)
	end

	local player: Player? = nil
	if typeof(params.player) == "string" and params.player ~= "" then
		player = Players:FindFirstChild(params.player) :: Player?
		if player == nil then
			Dispatch.fail("NO_PLAYER", string.format("No player named %q is in this test.", params.player))
		end
	else
		player = Players:GetPlayers()[1]
		if player == nil then
			Dispatch.fail(
				"NO_PLAYER",
				"No players are in this test.",
				"Run mode has no player at all -- use `playtest op=play` for a character."
			)
		end
	end

	local model = (player :: Player).Character
	if model == nil then
		Dispatch.fail("NO_CHARACTER", "The player has no character right now (probably respawning).")
	end

	local humanoid = (model :: Model):FindFirstChildOfClass("Humanoid")
	if humanoid == nil then
		Dispatch.fail("NO_HUMANOID", "The character has no Humanoid.")
	end

	return model :: Model, humanoid :: Humanoid, player :: Player
end

local function positionOf(model: Model): Vector3
	local root = model:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		return root.Position
	end
	return model:GetPivot().Position
end

--[[
	Takes physics authority over the character so the server can actually move it.

	Without this the character does not move at all, and says nothing about why.
	A player's character is network-owned by their client, so a `MoveTo` issued
	from the server is overridden by the client's own controller on the next
	frame -- the humanoid accepts the request, `MoveToFinished` fires, waypoints
	are reported reached, and the character has not travelled a single stud.
	Measured: identical start and end positions across a three-waypoint path that
	reported Success.

	`SetNetworkOwner(nil)` hands authority to the server, after which the same
	call moved it 7.11 studs. This is what Studio's own "server-side character
	control" does, and it is the difference between driving the character and
	politely asking the client to.
]]
local function takeControl(model: Model): boolean
	local root = model:FindFirstChild("HumanoidRootPart")
	if root == nil or not root:IsA("BasePart") then
		return false
	end
	-- Guarded: an anchored root, or a session where the part is not
	-- network-owned at all, throws rather than returning false.
	local ok = pcall(function()
		(root :: BasePart):SetNetworkOwner(nil)
	end)
	return ok
end

--[[
	Walks to a point, following a computed path around obstacles.

	Reports where it ended up rather than only whether the call returned, because
	`MoveTo` succeeds at being asked and says nothing about arriving. A route
	blocked by a wall the agent did not know about looks identical to a
	successful walk unless the final distance is measured.
]]
function Character.moveTo(params: { [string]: any }): { [string]: any }
	local model, humanoid = humanoidOf(params)

	local goal: Vector3
	if typeof(params.path) == "string" and params.path ~= "" then
		local target = Paths.resolve(params.path)
		if target:IsA("BasePart") then
			goal = (target :: BasePart).Position
		elseif target:IsA("Model") then
			goal = (target :: Model):GetPivot().Position
		else
			Dispatch.fail("NOT_POSITIONED", string.format("%s has no position.", params.path))
		end
	else
		goal = parseVector(params.to, "`to`")
	end

	local start = positionOf(model)
	local controlled = takeControl(model)

	--[[
		Straight-line movement is available on request, because pathfinding
		deliberately refuses routes it considers unreachable -- and "walk at it
		anyway and tell me what happens" is a legitimate thing to test.
	]]
	local waypoints: { Vector3 } = {}
	local pathStatus = "direct"
	if params.direct ~= true then
		local path = PathfindingService:CreatePath({
			AgentRadius = 2,
			AgentHeight = 5,
			AgentCanJump = params.canJump ~= false,
		})
		local ok, err = pcall(function()
			path:ComputeAsync(start, goal)
		end)
		if not ok then
			Dispatch.fail("PATH_FAILED", string.format("Could not compute a path: %s", tostring(err)))
		end
		pathStatus = tostring(path.Status)
		if path.Status == Enum.PathStatus.Success then
			for _, waypoint in path:GetWaypoints() do
				table.insert(waypoints, waypoint.Position)
			end
		else
			return {
				arrived = false,
				pathStatus = pathStatus,
				from = tostring(start),
				goal = tostring(goal),
				note = "No route exists. Pass direct=true to walk straight at it regardless.",
			}
		end
	else
		waypoints = { goal }
	end

	local deadline = os.clock() + MOVE_TIMEOUT
	local reached = 0
	for index, waypoint in waypoints do
		if os.clock() > deadline then
			break
		end
		humanoid:MoveTo(waypoint)
		-- Jumping is per-waypoint: a path that crosses a gap marks the waypoint
		-- before it as a jump, and walking it without jumping falls short.
		if index > 1 and waypoint.Y - waypoints[index - 1].Y > 1.5 then
			humanoid.Jump = true
		end
		local finished = humanoid.MoveToFinished:Wait()
		reached += 1
		if not finished then
			-- MoveToFinished(false) means its own 8-second timeout elapsed, which
			-- in practice means something is in the way.
			break
		end
	end

	local final = positionOf(model)
	local distance = (final - goal).Magnitude

	return {
		arrived = distance <= ARRIVAL_RADIUS,
		serverControlled = controlled,
		distance = math.floor(distance * 10 + 0.5) / 10,
		waypoints = #waypoints,
		waypointsReached = reached,
		pathStatus = pathStatus,
		from = tostring(start),
		to = tostring(final),
		goal = tostring(goal),
	}
end

--[[
	One-shot character actions: jump, sit, respawn, and the state changes worth
	testing directly.
]]
function Character.act(params: { [string]: any }): { [string]: any }
	local model, humanoid, player = humanoidOf(params)
	local action = tostring(params.action or "jump")

	-- Jumping and sitting are driven from the server too, and are overridden by
	-- the owning client for exactly the same reason walking was.
	takeControl(model)

	if action == "jump" then
		humanoid.Jump = true
		return { action = action, at = tostring(positionOf(model)) }
	elseif action == "stop" then
		humanoid:MoveTo(positionOf(model))
		return { action = action, at = tostring(positionOf(model)) }
	elseif action == "sit" then
		humanoid.Sit = true
		return { action = action, sitting = humanoid.Sit }
	elseif action == "stand" then
		humanoid.Sit = false
		return { action = action, sitting = humanoid.Sit }
	elseif action == "respawn" then
		player:LoadCharacter()
		return { action = action, note = "The character was rebuilt; anything holding the old one is stale." }
	elseif action == "kill" then
		humanoid.Health = 0
		return { action = action, note = "Killed, so the death and respawn path runs." }
	elseif action == "equip" then
		--[[
			Tools are the other half of gameplay input, and the half that is
			actually reachable. Keys and clicks are closed to plugins, but a
			Tool's Activate is a plain server-side call, so "equip the sword and
			swing it" -- which is what most combat tests come down to -- works
			without simulating a single input event.
		]]
		local name = params.tool
		if typeof(name) ~= "string" or name == "" then
			Dispatch.fail("BAD_PARAMS", "equip needs a `tool` name.")
		end

		-- Backpack first, then StarterPack, because a tool the player already
		-- holds is what a caller usually means.
		local backpack = player:FindFirstChildOfClass("Backpack")
		local tool = if backpack then backpack:FindFirstChild(name) else nil
		if tool == nil then
			local starter = game:GetService("StarterPack"):FindFirstChild(name)
			if starter then
				tool = starter:Clone()
				;(tool :: Instance).Parent = backpack
			end
		end
		if tool == nil or not tool:IsA("Tool") then
			Dispatch.fail(
				"NO_TOOL",
				string.format("No Tool named %q in the player's Backpack or StarterPack.", name)
			)
		end

		humanoid:EquipTool(tool :: Tool)
		return { action = action, tool = name, equipped = (tool :: Tool).Parent == model }
	elseif action == "activate" then
		local equipped = model:FindFirstChildOfClass("Tool")
		if equipped == nil then
			Dispatch.fail(
				"NO_TOOL",
				"The character is not holding a tool.",
				'Equip one first with action "equip".'
			)
		end
		-- Activate is what a mouse click triggers, so this is the closest thing
		-- to "use it" that exists without input injection.
		equipped:Activate()
		return { action = action, tool = equipped.Name }
	elseif action == "unequip" then
		humanoid:UnequipTools()
		return { action = action, holding = model:FindFirstChildOfClass("Tool") == nil }
	elseif action == "teleport" then
		local target = parseVector(params.to, "`to`")
		model:PivotTo(CFrame.new(target))
		return { action = action, at = tostring(positionOf(model)), note = "Moved without walking -- collisions and triggers along the way did not fire." }
	end

	Dispatch.fail("BAD_PARAMS", string.format("unknown character action %q", action))
	return {}
end

--[[
	Where the character is and what state it is in. Cheap, and the thing to call
	before and after anything else here.
]]
function Character.state(params: { [string]: any }): { [string]: any }
	local model, humanoid, player = humanoidOf(params)
	return {
		player = player.Name,
		position = tostring(positionOf(model)),
		health = humanoid.Health,
		maxHealth = humanoid.MaxHealth,
		walkSpeed = humanoid.WalkSpeed,
		jumpPower = humanoid.JumpPower,
		state = tostring(humanoid:GetState()),
		sitting = humanoid.Sit,
		floor = if humanoid.FloorMaterial ~= Enum.Material.Air
			then tostring(humanoid.FloorMaterial)
			else nil,
	}
end

function Character.register()
	Dispatch.registerAll("character", {
		moveTo = Character.moveTo,
		act = Character.act,
		state = Character.state,
	})
end

return Character
