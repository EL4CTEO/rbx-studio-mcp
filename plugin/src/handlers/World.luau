--!strict
--[[
	Undo/redo, and collision groups.

	Two small things that share a file because neither is big enough to deserve
	its own and both are about the state of the place rather than its contents.

	Undo matters more than it looks. Every write this server makes is already
	wrapped in a ChangeHistoryService recording, so the user can revert any of it
	by hand -- but the agent that made the mess could not clean it up, which made
	"undo that" a request only a human could carry out. Now it can.

	Collision groups are the engine's answer to "these parts should pass through
	each other". Without them the alternative is toggling CanCollide, which turns
	collision off against everything rather than against one class of thing.
]]

local ChangeHistoryService = game:GetService("ChangeHistoryService")

--[[
	Collision groups are read and written through a WorldRoot, not PhysicsService.

	Roblox moved collision group management onto WorldRoot in September 2026 and
	deprecated the PhysicsService methods in the same announcement. Both still
	work today -- checked against Studio 0.738 -- so this is a migration ahead of
	a removal rather than a fix.

	The move is not only a rename. A `WorldModel` is a WorldRoot too, and it now
	keeps its OWN registry: a group named "Doors" inside a viewport's WorldModel
	is a different group from the Workspace's "Doors", with its own collidability
	matrix. Going through `PhysicsService` -- or hard-coding `workspace` here --
	can only ever reach one of them, which would quietly make this tool lie about
	a place that uses both. So the root is chosen per call; see `root`.
]]
local Workspace = game:GetService("Workspace")

local Dispatch = require(script.Parent.Parent.Dispatch)
local Paths = require(script.Parent.Parent.Paths)
local Undo = require(script.Parent.Parent.Undo)

local World = {}

--[[
	Which world the call is about.

	Defaults to the Workspace, which is what nearly every caller means. Naming a
	`worldModel` path targets that model's private registry instead -- the
	viewport-preview case -- and anything that is not a WorldRoot is refused by
	name rather than left to fail later inside `RegisterCollisionGroup` with a
	message about a method that does not exist.
]]
local function root(params: { [string]: any }): Instance
	local path = params.worldModel
	if typeof(path) ~= "string" or path == "" then
		return Workspace
	end

	local instance = Paths.resolve(path)
	if not instance:IsA("WorldRoot") then
		Dispatch.fail(
			"BAD_PARAMS",
			string.format("%s is a %s, not a WorldModel.", path, instance.ClassName),
			"Collision groups live on a WorldRoot: the Workspace, or a WorldModel "
				.. "inside a ViewportFrame. Omit `worldModel` for the Workspace."
		)
	end
	return instance
end

--[[
	Steps the undo stack.

	Reports what the stack looks like afterwards, because "undo" that quietly did
	nothing -- an empty stack, or history disabled -- is indistinguishable from
	one that worked unless the caller is told.
]]
function World.history(params: { [string]: any }): { [string]: any }
	local action = tostring(params.action or "status")
	local steps = math.clamp(tonumber(params.steps) or 1, 1, 25)

	if action == "status" then
		return {
			canUndo = ChangeHistoryService:GetCanUndo(),
			canRedo = ChangeHistoryService:GetCanRedo(),
		}
	end

	if action ~= "undo" and action ~= "redo" then
		Dispatch.fail("BAD_PARAMS", string.format("unknown history action %q", action))
	end

	local applied = 0
	for _ = 1, steps do
		local can = if action == "undo"
			then ChangeHistoryService:GetCanUndo()
			else ChangeHistoryService:GetCanRedo()
		if not can then
			break
		end
		local ok = pcall(function()
			if action == "undo" then
				ChangeHistoryService:Undo()
			else
				ChangeHistoryService:Redo()
			end
		end)
		if not ok then
			break
		end
		applied += 1
	end

	return {
		action = action,
		requested = steps,
		applied = applied,
		canUndo = ChangeHistoryService:GetCanUndo(),
		canRedo = ChangeHistoryService:GetCanRedo(),
		-- Said plainly rather than left to be inferred from applied == 0, which
		-- is the case someone is most likely to misread as success.
		note = if applied == 0
			then string.format("Nothing to %s -- the history stack is empty in that direction.", action)
			elseif applied < steps then string.format("Only %d of %d steps were available.", applied, steps)
			else nil,
	}
end

--[[
	Collision groups: create them, set which collide with which, assign parts.

	One call does all three, because they are never useful separately -- a group
	nothing is assigned to has no effect, and an assignment to a group that does
	not exist is an error.
]]
function World.collision(params: { [string]: any }): { [string]: any }
	local action = tostring(params.action or "list")
	local world = root(params) :: any

	if action == "list" then
		local groups: { { [string]: any } } = {}
		local ok, registered = pcall(function()
			return world:GetRegisteredCollisionGroups()
		end)
		if ok and typeof(registered) == "table" then
			--[[
				Named pairs, not the raw mask.

				`mask` is the engine's bitfield, and it is not readable: a group
				that passes through only itself reports -3, which says nothing to
				anyone without a calculator and the group ordering to hand. The
				whole reason a collision group exists is "these two do not
				collide", so that is what is listed -- by name, both ways round,
				which is the answer the caller came for.

				The mask is kept beside it, because a caller comparing against
				something they stored earlier still needs the number.
			]]
			for _, group in registered :: { any } do
				local passesThrough: { string } = {}
				for _, other in registered :: { any } do
					local okPair, collides = pcall(function()
						return world:CollisionGroupsAreCollidable(group.name, other.name)
					end)
					if okPair and collides == false then
						table.insert(passesThrough, other.name)
					end
				end
				table.sort(passesThrough)
				table.insert(groups, {
					name = group.name,
					mask = group.mask,
					passesThrough = if #passesThrough > 0 then table.concat(passesThrough, ", ") else "nothing",
				})
			end
		end
		--[[
			The ceiling is reported alongside the groups because it is low --
			32 in practice -- and a caller building groups programmatically has
			no other way to learn it before the registration that fails.
		]]
		local limit: number? = nil
		local okLimit, maximum = pcall(function()
			return world:GetMaxCollisionGroups()
		end)
		if okLimit then
			limit = tonumber(maximum)
		end

		return { groups = groups, world = Paths.of(world), count = #groups, max = limit }
	end

	local name = params.group
	if typeof(name) ~= "string" or name == "" then
		Dispatch.fail("BAD_PARAMS", "collision needs a `group` name.")
	end

	if action == "create" then
		local ok, err = pcall(function()
			world:RegisterCollisionGroup(name)
		end)
		if not ok then
			-- Already existing is the common case and is not a failure worth
			-- refusing over: the caller wanted the group to exist, and it does.
			if not string.find(tostring(err), "already", 1, true) then
				Dispatch.fail("COLLISION_FAILED", string.format("Could not create %q: %s", name, tostring(err)))
			end
		end
		return { group = name, created = ok, existed = not ok, world = Paths.of(world) }
	end

	if action == "assign" then
		local paths = params.paths
		if typeof(paths) ~= "table" or #(paths :: { any }) == 0 then
			Dispatch.fail("BAD_PARAMS", "assign needs a `paths` array.")
		end
		local assigned: { string } = {}
		local _, undoable = Undo.record("MCPCollision", "MCP collision group", function()
			for _, path in paths :: { string } do
				local instance = Paths.resolve(path)
				-- A model is what a caller usually means; assigning its parts is
				-- what they want, and refusing would just make them enumerate.
				local targets = if instance:IsA("BasePart") then { instance } else instance:GetDescendants()
				for _, target in targets do
					if target:IsA("BasePart") then
						(target :: BasePart).CollisionGroup = name
						table.insert(assigned, Paths.of(target))
					end
				end
			end
		end)
		return { group = name, assigned = #assigned, parts = assigned, undoable = undoable, world = Paths.of(world) }
	end

	if action == "remove" then
		--[[
			Registering a group is one line and nothing here undid it: create,
			assign and collidable all had a way back through the ordinary undo
			stack, and this did not, because nothing called it at all. Over a
			session that experiments -- try a group, decide against it -- that
			leaves the place permanently carrying a group nobody wants, with no
			way to remove it short of `execute_luau`. `UnregisterCollisionGroup`
			has existed the whole time; it was just never wired up.
		]]
		local ok, err = pcall(function()
			world:UnregisterCollisionGroup(name)
		end)
		if not ok then
			Dispatch.fail("COLLISION_FAILED", string.format("Could not remove %q: %s", name, tostring(err)))
		end
		return { group = name, removed = true, world = Paths.of(world) }
	end

	if action == "collidable" then
		local other = params.with
		if typeof(other) ~= "string" or other == "" then
			Dispatch.fail("BAD_PARAMS", "collidable needs `with`, the other group's name.")
		end
		local collidable = params.collidable ~= false
		local ok, err = pcall(function()
			world:CollisionGroupSetCollidable(name, other, collidable)
		end)
		if not ok then
			Dispatch.fail("COLLISION_FAILED", string.format("Could not set collidability: %s", tostring(err)))
		end
		return { group = name, with = other, collidable = collidable, world = Paths.of(world) }
	end

	Dispatch.fail("BAD_PARAMS", string.format("unknown collision action %q", action))
	return {}
end

function World.register()
	Dispatch.registerAll("world", {
		history = World.history,
		collision = World.collision,
	})
end

return World
