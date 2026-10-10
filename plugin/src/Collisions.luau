--!strict
-- A bounded window over BasePart:BindToCollisionSummaries: what hit what, how
-- hard, where and at which angle. Listeners are additive and removed on exit.
-- Summaries come from the physics step of the VM that runs this, so a server
-- read sees what the server simulates and a client read what the client does.
local RunService = game:GetService("RunService")
local Dispatch = require(script.Parent.Dispatch)
local Paths = require(script.Parent.Paths)

local Collisions = {}
local MAX_PARTS = 64
local MAX_ROWS = 40

local function vector(v: Vector3): string
	return string.format("%.2f, %.2f, %.2f", v.X, v.Y, v.Z)
end

local function nameOf(part: Instance, names: { [Instance]: string }): string
	local known = names[part]
	if known then return known end
	local ok, path = pcall(Paths.of, part)
	local name = if ok then path else part.Name
	names[part] = name
	return name
end

function Collisions.capture(params: { [string]: any }): { [string]: any }
	local target = Paths.resolve(params.path)
	local seconds = math.clamp(tonumber(params.seconds) or 5, 1, 15)
	local minSpeed = math.max(tonumber(params.minSpeed) or 0, 0)

	local parts: { BasePart } = {}
	local bound: { [Instance]: boolean } = {}
	local skipped = 0
	local function consider(instance: Instance)
		if not instance:IsA("BasePart") then return end
		if #parts >= MAX_PARTS then skipped += 1; return end
		table.insert(parts, instance)
		bound[instance] = true
	end
	consider(target)
	for _, descendant in target:GetDescendants() do consider(descendant) end
	if #parts == 0 then
		Dispatch.fail("NO_PARTS", Paths.of(target) .. " holds no BaseParts to observe.",
			"Pass a part, or a model/folder that contains parts.")
	end

	local names: { [Instance]: string } = {}
	local rows: { [string]: { [string]: any } } = {}
	local rowCount, overflow, total = 0, 0, 0
	local started = os.clock()
	local connections: { RBXScriptConnection } = {}
	local stopped = false
	local function stop()
		if stopped then return end
		stopped = true
		for _, connection in connections do connection:Disconnect() end
	end

	local function record(summary: any)
		local part0, part1 = summary.Part0, summary.Part1
		if typeof(part0) ~= "Instance" or typeof(part1) ~= "Instance" then return end
		local velocity: Vector3 = summary.RelativeVelocity
		local speed = velocity.Magnitude
		if speed < minSpeed then return end
		local a, b = nameOf(part0, names), nameOf(part1, names)
		-- Two observed parts each report the same contact; keep one side.
		if bound[part1] and a > b then return end
		total += 1
		local key = a .. "\0" .. b
		local row = rows[key]
		if not row then
			if rowCount >= MAX_ROWS then overflow += 1; return end
			rowCount += 1
			row = { part = a, other = b, frames = 0, firstMs = math.round((os.clock() - started) * 1000), maxSpeed = -1 }
			rows[key] = row
		end
		row.frames += 1
		row.lastMs = math.round((os.clock() - started) * 1000)
		if speed > row.maxSpeed then
			row.maxSpeed = speed
			row.point = vector(summary.Point)
			row.normal = vector(summary.Normal)
			row.velocity = vector(velocity)
			row.area = summary.Area
		end
	end

	local ok, failure = pcall(function()
		for _, part in parts do
			local attached, connection = pcall(function()
				return part:BindToCollisionSummaries(function(summaries: { any })
					if stopped then return end
					for _, summary in summaries do pcall(record, summary) end
				end)
			end)
			if not attached then
				Dispatch.fail("COLLISION_SUMMARIES_UNAVAILABLE",
					"BasePart:BindToCollisionSummaries is not available in this Studio.",
					"Update Studio; the API shipped in release 742. Details: " .. tostring(connection))
			end
			table.insert(connections, connection :: RBXScriptConnection)
		end
		local deadline = os.clock() + seconds
		while not stopped and os.clock() < deadline do
			Dispatch.checkDeadline()
			task.wait(0.05)
		end
	end)
	stop()
	if not ok then error(failure, 0) end

	local list = {}
	for _, row in rows do
		row.maxSpeed = math.round(row.maxSpeed * 100) / 100
		table.insert(list, row)
	end
	table.sort(list, function(x, y)
		if x.maxSpeed ~= y.maxSpeed then return x.maxSpeed > y.maxSpeed end
		return x.part .. x.other < y.part .. y.other
	end)

	return {
		path = Paths.of(target),
		observed = #parts,
		partsSkipped = if skipped > 0 then skipped else nil,
		pairs = list,
		summaries = total,
		pairsDropped = if overflow > 0 then overflow else nil,
		seconds = math.round((os.clock() - started) * 1000) / 1000,
		simulating = RunService:IsRunning() or nil,
		note = (if RunService:IsRunning() then "" else "Physics is not simulating in this session (edit mode), so nothing can collide; start a playtest. ")
			.. "One row per part/other pair, strongest impact first. `part` is the observed part; speeds are relative studs/s; "
			.. "point, normal, velocity and area are from the strongest frame. Resting contact reports every frame, so use minSpeed to keep only impacts. "
			.. "Parts at rest sleep and stop reporting until woken. Local simulation only; at most 64 parts and 40 pairs.",
	}
end

return Collisions
