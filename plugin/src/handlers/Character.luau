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
local Workspace = game:GetService("Workspace")
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

--[[
	How close counts as reaching one waypoint along the way.

	Tighter than ARRIVAL_RADIUS, which judges the whole journey. Waypoints are
	four studs apart by default, so a six-stud tolerance would count the next one
	as already reached and the character would skip through the route without
	walking it.
]]
local WAYPOINT_RADIUS = 3

--[[
	Movement below this in a sample is not movement.

	A standing character still drifts a little -- physics settling, a humanoid
	shifting on a slope -- and treating that as progress would let a wedged
	character look busy forever.
]]
local STUD_EPSILON = 0.35

--[[
	Seconds of no progress before a walk is called stuck.

	Well under `MoveToFinished`'s own eight, which is the number this replaces.
	Two seconds is long enough to survive a pause at a corner and short enough
	that a blocked route reports in seconds rather than costing eight per
	waypoint for the rest of the path.
]]
local STUCK_SECONDS = 2

--[[
	How many times a stalled walk may ask for a fresh route.

	Three, because the cases this rescues -- a stale route, a door that shut, a
	prop that moved -- clear in one or two attempts, while a character truly
	wedged against geometry would loop on the spot until the deadline and report
	nothing useful about why it failed.
]]
local MAX_REPATHS = 3

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
--[[
	Agent settings, shared by the route check and the walk.

	Written once because a route that `path` calls walkable and `moveTo` then
	fails to walk would be worse than having neither: the whole value of testing
	a route before committing to it is that the test used the same agent.

	The defaults describe a standard Roblox character -- 2 studs across, 5 tall,
	able to jump. Overriding them is the point for anything else: an NPC with a
	wide model genuinely cannot fit through a gap a player can, and that is a
	level-design fact nobody can see by looking.
]]
local function agentOf(params: { [string]: any }): { [string]: any }
	return {
		AgentRadius = math.clamp(tonumber(params.agentRadius) or 2, 0.1, 50),
		AgentHeight = math.clamp(tonumber(params.agentHeight) or 5, 0.1, 100),
		AgentCanJump = params.canJump ~= false,
		AgentCanClimb = params.canClimb == true,
		--[[
			Waypoint spacing is exposed because it decides what the answer even
			means. Wide spacing gives a coarse route that says "roughly this
			way"; tight spacing follows the geometry and is what you want when
			the question is whether something fits through a doorway.
		]]
		WaypointSpacing = math.clamp(tonumber(params.spacing) or 4, 0.1, 100),
		Costs = if typeof(params.costs) == "table" then params.costs else nil,
	}
end

--[[
	Turns a start and a goal into two world points.

	Both ends accept either a position or the path of something in the place,
	because both are how the question actually arrives: "from the spawn to the
	cell door" names two instances, while "from here to there" names two
	vectors.
]]
local function endpointOf(params: { [string]: any }, pathKey: string, vectorKey: string, label: string): Vector3
	local named = params[pathKey]
	if typeof(named) == "string" and named ~= "" then
		local target = Paths.resolve(named)
		if target:IsA("BasePart") then
			return (target :: BasePart).Position
		elseif target:IsA("Model") then
			return (target :: Model):GetPivot().Position
		end
		Dispatch.fail("NOT_POSITIONED", string.format("%s has no position.", named))
	end
	return parseVector(params[vectorKey], label)
end

--[[
	Answers "can anything get from here to there" without moving anything.

	This is the half of pathfinding that was missing, and it is the more useful
	half. `moveTo` needs a character, needs a playtest, and changes the place
	while it runs. The navmesh does not: measured, `ComputeAsync` returns
	`Success` with real waypoints in an ordinary edit session, with nothing
	playing and nobody spawned.

	So a level can be checked before it is ever played. Is the spawn connected
	to the objective? Did that new wall seal off a corridor? Can a 4-stud-wide
	NPC use the door the 2-stud player walks through? Each of those is a route
	query, and every one of them previously required pressing Play and driving a
	character by hand.

	Reports the route rather than judging it. `NoPath` is an answer, not an
	error: it means the two points are not connected for an agent of this shape,
	which is usually the finding rather than the failure.
]]
function Character.path(params: { [string]: any }): { [string]: any }
	local start = endpointOf(params, "fromPath", "from", "`from`")
	local goal = endpointOf(params, "toPath", "to", "`to`")

	local path = PathfindingService:CreatePath(agentOf(params))
	local ok, err = pcall(function()
		path:ComputeAsync(start, goal)
	end)
	if not ok then
		Dispatch.fail(
			"PATH_FAILED",
			string.format("Could not compute a path: %s", tostring(err)),
			"Costs keys must be material or PathfindingModifier label names."
		)
	end

	local status = tostring(path.Status):gsub("Enum%.PathStatus%.", "")
	local straightLine = (goal - start).Magnitude

	if path.Status ~= Enum.PathStatus.Success then
		return {
			reachable = false,
			status = status,
			from = tostring(start),
			to = tostring(goal),
			straightLineDistance = math.round(straightLine * 10) / 10,
			hint = "Nothing walkable connects these points for an agent this size. "
				.. "A wall, a gap wider than a jump, or a drop too far. Try a smaller "
				.. "`agentRadius`, or `canJump`/`canClimb`.",
		}
	end

	local waypoints = path:GetWaypoints()
	local travelled = 0
	local jumps = 0
	local rows: { { [string]: any } } = {}

	for index, waypoint in waypoints do
		if index > 1 then
			travelled += (waypoint.Position - waypoints[index - 1].Position).Magnitude
		end
		local action = tostring(waypoint.Action):gsub("Enum%.PathWaypointAction%.", "")
		if action == "Jump" then
			jumps += 1
		end
		--[[
			Only jumps and the ends are listed individually. A hundred Walk
			waypoints down a corridor say nothing a total distance does not, and
			the jumps are the part of a route that breaks: a jump is where an NPC
			gets stuck and where a player without a jump cannot follow.
		]]
		if action ~= "Walk" or index == 1 or index == #waypoints then
			table.insert(rows, {
				index = index,
				action = action,
				position = tostring(waypoint.Position),
				label = if waypoint.Label ~= "" then waypoint.Label else nil,
			})
		end
	end

	return {
		reachable = true,
		status = status,
		from = tostring(start),
		to = tostring(goal),
		waypointCount = #waypoints,
		pathDistance = math.round(travelled * 10) / 10,
		straightLineDistance = math.round(straightLine * 10) / 10,
		--[[
			How far the route is beyond a straight line. A ratio near 1 is a
			clear run; a large one means the agent is going a long way around,
			which is the measurable form of "this level makes you backtrack".
		]]
		detour = if straightLine > 0 then math.round((travelled / straightLine) * 100) / 100 else 1,
		jumps = jumps,
		waypoints = rows,
	}
end

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
	--[[
		Waypoints carry their action, not just their position.

		The action is the half of a waypoint that says HOW to get there, and
		dropping it on the way in is what made the walk guess at jumps.
	]]
	type Step = { position: Vector3, action: Enum.PathWaypointAction }
	local waypoints: { Step } = {}
	local pathStatus = "direct"

	--[[
		A route from wherever the character is now.

		Written as a function because the walk needs it more than once. A path is
		computed against the world as it stood at the moment of asking, and a
		playtest is the one place where that stops being true while you are
		walking through it: a door closes, an NPC steps into the corridor, a
		platform moves. The first route is a plan, not a promise.
	]]
	local function routeFrom(origin: Vector3): (string, { Step })
		local path = PathfindingService:CreatePath(agentOf(params))
		local ok, err = pcall(function()
			path:ComputeAsync(origin, goal)
		end)
		if not ok then
			Dispatch.fail("PATH_FAILED", string.format("Could not compute a path: %s", tostring(err)))
		end
		local steps: { Step } = {}
		if path.Status == Enum.PathStatus.Success then
			for _, waypoint in path:GetWaypoints() do
				table.insert(steps, { position = waypoint.Position, action = waypoint.Action })
			end
		end
		return tostring(path.Status), steps
	end
	if params.direct ~= true then
		-- Same settings the `path` op uses, so a route reported walkable there is
		-- the route walked here.
		pathStatus, waypoints = routeFrom(start)
		if #waypoints == 0 then
			return {
				arrived = false,
				pathStatus = pathStatus,
				from = tostring(start),
				goal = tostring(goal),
				note = "No route exists. Pass direct=true to walk straight at it regardless.",
			}
		end
	else
		-- A direct walk has no pathfinder to ask, so it never jumps on purpose.
		waypoints = { { position = goal, action = Enum.PathWaypointAction.Walk } }
	end

	local deadline = os.clock() + MOVE_TIMEOUT
	local reached = 0
	local jumped = 0
	local repaths = 0
	local stuckAt: Vector3? = nil
	local blockedBy: string? = nil

	local index = 0
	while index < #waypoints do
		index += 1
		local step = waypoints[index]
		if os.clock() > deadline then
			break
		end

		--[[
			Jump when the ENGINE says to jump, not when the height changed.

			The old test was `waypoint.Y - previous.Y > 1.5`, and it was wrong in
			both directions. A gap in a flat floor is a jump with no height change
			at all, so the character walked calmly off the edge; a ramp is a
			height change with no jump needed, so it hopped its way up a slope for
			no reason. `PathWaypointAction.Jump` is the pathfinder telling you
			exactly which step needs it, and it was being ignored in favour of a
			guess about the geometry it had already solved.
		]]
		if step.action == Enum.PathWaypointAction.Jump then
			humanoid.Jump = true
			jumped += 1
		end

		humanoid:MoveTo(step.position)

		--[[
			Watched while it walks, rather than waited on.

			`MoveToFinished` fires on arrival or after its own eight seconds, and
			those two are indistinguishable from the signal alone -- so a
			character wedged against a doorframe costs eight seconds per waypoint
			and reports the same as one that walked. Polling the position tells
			the difference in a fraction of that: a character that has not moved
			STUD_EPSILON in STUCK_SECONDS is not walking, whatever the humanoid
			thinks it is doing.
		]]
		local lastPosition = positionOf(model)
		local lastProgress = os.clock()
		local arrivedHere = false

		while os.clock() < deadline do
			local now = positionOf(model)
			--[[
				Measured flat, ignoring height.

				`positionOf` is the root part -- the middle of the character,
				around three studs above its feet -- and a waypoint sits on the
				floor. Comparing them in 3D therefore never gets closer than the
				character is tall: standing exactly on a waypoint still measures
				three studs away, which is the whole tolerance, so arrival
				registered by luck or not at all. Measured: a walk stalled two
				waypoints in with the character standing on the spot it was
				walking to.

				Horizontal distance is the honest test of "am I there"; height is
				the pathfinder's business, not the arrival check's.
			]]
			local flat = Vector3.new(now.X - step.position.X, 0, now.Z - step.position.Z)
			if flat.Magnitude <= WAYPOINT_RADIUS then
				arrivedHere = true
				break
			end
			if (now - lastPosition).Magnitude > STUD_EPSILON then
				lastPosition = now
				lastProgress = os.clock()
			elseif os.clock() - lastProgress > STUCK_SECONDS then
				stuckAt = now
				break
			end
			task.wait(0.1)
		end

		if arrivedHere then
			reached += 1
			continue
		end

		--[[
			Stuck once is not stuck.

			Measured: a walk stopped seventeen waypoints in, and a path computed
			from that exact spot reached the goal in eighteen more over open
			ground -- nothing was blocking it, at chest height or at its feet. The
			route had simply gone stale, which is the normal condition of a route
			in a running game.

			So the first answer to being stuck is to ask again from where we now
			are, not to give up and report failure. Bounded, because a character
			genuinely wedged would otherwise recompute until the deadline and
			report nothing useful about why.
		]]
		if stuckAt ~= nil and repaths < MAX_REPATHS and os.clock() < deadline then
			local status, fresh = routeFrom(stuckAt :: Vector3)
			if #fresh > 0 then
				repaths += 1
				pathStatus = status
				waypoints = fresh
				index = 0
				stuckAt = nil
				continue
			end
		end

		if stuckAt ~= nil then
			--[[
				What it is stuck ON, not just that it is stuck.

				"Did not arrive" sends someone to look at the whole route. A ray
				from the character towards the step it could not reach names the
				thing in the way, which is usually the entire answer -- a door
				that is closed, a prop dropped into a corridor, a wall that was
				moved.
			]]
			--[[
				Cast flat, at chest height, or it finds the floor.

				The first version aimed from the root straight at the waypoint,
				and since a waypoint is on the ground that ray points slightly
				downwards -- so it hit whatever the character was standing on and
				reported the floor as the obstruction. Measured: "blocked by
				Workspace.SpawnLocation", which was the pad under its feet.

				A horizontal ray from chest height asks the question that was
				meant: what is in front of it.
			]]
			local eye = (stuckAt :: Vector3) + Vector3.new(0, 1, 0)
			local towards = Vector3.new(step.position.X - eye.X, 0, step.position.Z - eye.Z)
			if towards.Magnitude > 0.1 then
				local filter = RaycastParams.new()
				filter.FilterType = Enum.RaycastFilterType.Exclude
				filter.FilterDescendantsInstances = { model }
				local reach = towards.Unit * math.min(towards.Magnitude, 12)
				local hit = Workspace:Raycast(eye, reach, filter)
				if hit ~= nil then
					blockedBy = string.format("%s (%s)", Paths.of(hit.Instance), hit.Instance.ClassName)
				else
					--[[
						A second ray, low down, for the thing the first one misses.

						Chest height answers "is there a wall", and a great many
						stuck characters are not stopped by a wall: they are
						stopped by a step, a kerb or a ledge a stud high, which a
						ray at chest height sails straight over. Measured -- a walk
						stalled seventeen waypoints in with the character alive,
						Running, on a plastic floor, and nothing at all in front of
						its chest.

						Named differently too, because the fix is different. A wall
						means route around it; a step means the character needed to
						jump and the pathfinder did not think so.
					]]
					local low = Workspace:Raycast((stuckAt :: Vector3) - Vector3.new(0, 1.5, 0), reach, filter)
					if low ~= nil then
						blockedBy = string.format(
							"%s (%s) -- a low step or ledge, not a wall: nothing blocks it at "
								.. "chest height, so it needs a jump the route did not include",
							Paths.of(low.Instance),
							low.Instance.ClassName
						)
					end
				end
			end
			break
		end

		-- Ran out of time rather than getting stuck; the loop's own guard ends it.
		break
	end

	local final = positionOf(model)
	local distance = (final - goal).Magnitude
	local arrived = distance <= ARRIVAL_RADIUS

	local report: { [string]: any } = {
		arrived = arrived,
		serverControlled = controlled,
		distance = math.floor(distance * 10 + 0.5) / 10,
		waypoints = #waypoints,
		waypointsReached = reached,
		jumps = jumped,
		-- Reported because it is the difference between a clear run and a route
		-- the character had to be rescued along.
		repaths = repaths,
		pathStatus = pathStatus,
		from = tostring(start),
		to = tostring(final),
		goal = tostring(goal),
	}

	if not arrived then
		report.stuckAt = if stuckAt ~= nil then tostring(stuckAt) else nil
		report.blockedBy = blockedBy
		--[[
			Said plainly, because the numbers alone read as success to anything
			skimming: waypointsReached counts the ones it walked, and a route that
			stopped nine steps in still reports nine.
		]]
		report.note = if blockedBy ~= nil
			then string.format(
				"Stopped %.0f studs short at waypoint %d of %d, blocked by %s.",
				distance,
				reached + 1,
				#waypoints,
				blockedBy
			)
			else string.format(
				"Stopped %.0f studs short at waypoint %d of %d. Nothing was in the ray's "
					.. "way, so it is more likely a drop, a gap, or a route the character "
					.. "cannot physically follow.",
				distance,
				reached + 1,
				#waypoints
			)
	end

	return report
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

		--[[
			Every tool of that name, not the first one found.

			A place under development commonly has two: the weapon being rebuilt
			and the one it is replacing, both called "Pistol". `FindFirstChild`
			picks one of them silently, so "equip the pistol, fire it, nothing
			happened" is indistinguishable from a broken weapon -- measured, with
			the working copy sitting next to the one that got equipped.
		]]
		local backpack = player:FindFirstChildOfClass("Backpack")
		local candidates: { Tool } = {}
		if backpack then
			for _, child in backpack:GetChildren() do
				if child.Name == name and child:IsA("Tool") then
					table.insert(candidates, child)
				end
			end
		end

		local fromStarter = false
		if #candidates == 0 then
			for _, child in game:GetService("StarterPack"):GetChildren() do
				if child.Name == name and child:IsA("Tool") then
					local copy = child:Clone()
					copy.Parent = backpack
					table.insert(candidates, copy)
					fromStarter = true
				end
			end
		end

		if #candidates == 0 then
			Dispatch.fail(
				"NO_TOOL",
				string.format("No Tool named %q in the player's Backpack or StarterPack.", name)
			)
		end

		local tool = candidates[1]
		humanoid:EquipTool(tool)

		--[[
			Waited for, because equipping is not finished when the call returns.

			`EquipTool` reparents the tool and the scripts inside it start on
			their own threads afterwards, so an `activate` sent immediately after
			an `equip` reaches a tool whose code has not connected to `Activated`
			yet. That one does nothing, reports success, and looks exactly like a
			weapon that is broken. Measured: the first activate after an equip
			printed nothing, the second fired.
		]]
		local waited = 0
		while tool.Parent ~= model and waited < 2 do
			waited += task.wait()
		end
		task.wait()

		return {
			action = action,
			tool = Paths.of(tool),
			equipped = tool.Parent == model,
			fromStarterPack = fromStarter,
			-- Named only when it is a choice, so the ordinary case stays quiet.
			alsoNamed = if #candidates > 1 then #candidates - 1 else nil,
			note = if #candidates > 1
				then string.format(
					"%d tools are named %q; this equipped the first one in the Backpack. "
						.. "If it behaved wrongly, check that it is the one you meant.",
					#candidates,
					name
				)
				else nil,
		}
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
		-- A frame, so anything the tool prints in response is already in the log
		-- by the time the caller reads `console`.
		task.wait()
		return {
			action = action,
			tool = Paths.of(equipped),
			note = "Activated fired. Whether anything LISTENED for it is not visible "
				.. "from here -- read `console` for what the tool's scripts printed.",
		}
	elseif action == "unequip" then
		humanoid:UnequipTools()
		return { action = action, holding = model:FindFirstChildOfClass("Tool") ~= nil }
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
		path = Character.path,
		moveTo = Character.moveTo,
		act = Character.act,
		state = Character.state,
	})
end

return Character
