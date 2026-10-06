--!strict
-- The same guarded Stats read in plugin and client VMs.
local Stats = game:GetService("Stats")
local RunService = game:GetService("RunService")
local Perf = {}
local function round(value: number, places: number): number
	local scale = 10 ^ places
	return math.floor(value * scale + 0.5) / scale
end

--[[
	Reads a Stats property without assuming it exists. The set has changed across
	engine versions, and one missing counter should not fail the whole snapshot.
]]
local function stat(name: string): number?
	local ok, value = pcall(function()
		return (Stats :: any)[name]
	end)
	if ok and typeof(value) == "number" then
		return value
	end
	return nil
end

local function millis(name: string): number?
	local seconds = stat(name)
	return if seconds then round(seconds * 1000, 3) else nil
end

local function flag(name: string): boolean?
	local ok, value = pcall(function()
		return (Stats :: any)[name]
	end)
	if ok and typeof(value) == "boolean" then
		return value
	end
	return nil
end

local function rounded(name: string, places: number): number?
	local value = stat(name)
	return if value then round(value, places) else nil
end

function Perf.snapshot(): { [string]: any }
	--[[
		Read one tag at a time, not with `GetMemoryUsageMbAllCategories`.

		The aggregate call is the obvious one and is closed to us: it now requires
		the InternalTest capability, so from a plugin it only ever raises "the
		current thread cannot call 'GetMemoryUsageMbAllCategories'". Measured, not
		assumed -- and the same refusal comes back in an editor session and in a
		playtest, so there is no context in which waiting for it pays off.

		`GetMemoryUsageMbForTag` carries no such restriction, and walking
		`Enum.DeveloperMemoryTag` reaches every category the Developer Console's
		Memory tab shows. Zero-valued tags are dropped so the list stays readable.
	]]
	local memory: { { [string]: any } } = {}
	local memoryProblem: string? = nil

	for _, tag in Enum.DeveloperMemoryTag:GetEnumItems() do
		local ok, value = pcall(function()
			return Stats:GetMemoryUsageMbForTag(tag)
		end)
		if not ok then
			-- One refusal means the whole route is shut, not that this tag is
			-- special; stop rather than repeat the same failure for every item.
			memoryProblem = string.format("Stats refused the call: %s", tostring(value))
			break
		end
		if typeof(value) == "number" and value > 0 then
			table.insert(memory, { category = tag.Name, megabytes = round(value, 2) })
		end
	end

	table.sort(memory, function(a, b)
		return a.megabytes > b.megabytes
	end)

	local okTotal, total = pcall(function()
		return Stats:GetTotalMemoryUsageMb()
	end)

	--[[
		A playtest server has no renderer, so every drawing counter reads zero --
		zero draw calls, zero triangles, no frame time. Left unexplained that is
		the most flattering possible misreading of a place's performance, so the
		snapshot says outright that those numbers are absent rather than good.
	]]
	local headless = RunService:IsRunning() and RunService:IsServer() and not RunService:IsClient()

	return {
		renderless = headless or nil,
		frame = {
			frameTimeMs = millis("FrameTime"),
			heartbeatTimeMs = millis("HeartbeatTime"),
			physicsStepTimeMs = millis("PhysicsStepTime"),
			renderCpuMs = millis("RenderCPUFrameTime"),
			renderGpuMs = millis("RenderGPUFrameTime"),
		},
		scene = {
			instances = stat("InstanceCount"),
			parts = stat("PrimitivesCount"),
			movingParts = stat("MovingPrimitivesCount"),
			contacts = stat("ContactsCount"),
			drawcalls = stat("SceneDrawcallCount"),
			triangles = stat("SceneTriangleCount"),
		},
		network = {
			receiveKbps = rounded("DataReceiveKbps", 1),
			sendKbps = rounded("DataSendKbps", 1),
		},
		memory = {
			totalMb = if okTotal and typeof(total) == "number" then round(total, 1) else nil,
			-- Studio only accumulates the per-category breakdown while this is on,
			-- so an empty list means "not measured" rather than "nothing used".
			trackingEnabled = flag("MemoryTrackingEnabled"),
			categories = memory,
			problem = if #memory == 0 then memoryProblem else nil,
		},
	}
end

return Perf
