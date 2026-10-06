--!strict
-- A bounded observation window, like debug.remotes. Listeners are additive:
-- no callbacks are replaced and no game state is changed. An input call may
-- run concurrently while this waits; the response is the observed timeline.
local HttpService = game:GetService("HttpService")
local Dispatch = require(script.Parent.Dispatch)
local Paths = require(script.Parent.Paths)
local Serialize = require(script.Parent.Serialize)

local Watch = {}
local MAX_EVENTS = 100
local MAX_BYTES = 10000
local MAX_INITIAL_BYTES = 5000

function Watch.capture(params: { [string]: any }, owner: Instance?): { [string]: any }
	local target = Paths.resolve(params.path)
	local seconds = math.clamp(tonumber(params.seconds) or 5, 1, 15)
	local connections: { RBXScriptConnection } = {}
	local items: { { [string]: any } } = {}
	local initial: { [string]: any } = {}
	local dropped, bytes, initialDropped = 0, 0, 0
	local started = os.clock()
	local stopped = false
	local function stop()
		if stopped then return end
		stopped = true
		for _, connection in connections do connection:Disconnect() end
	end
	local function value(raw: any): any
		local encoded = Serialize.value(raw)
		if typeof(encoded) ~= "string" or #encoded <= 512 then return encoded end
		-- Stop at a character boundary so clipping cannot break JSON encoding.
		local last = 512
		while last > 0 do
			local byte = string.byte(encoded, last + 1)
			if byte < 128 or byte >= 192 then break end
			last -= 1
		end
		return string.sub(encoded, 1, last) .. "<truncated>"
	end
	local initialBytes = 32
	local function baseline(into: { [string]: any }, name: string, raw: any)
		local encoded = value(raw)
		local cost = #HttpService:JSONEncode({ [name] = encoded }) + 1
		if initialBytes + cost > MAX_INITIAL_BYTES then
			initialDropped += 1
			return
		end
		initialBytes += cost
		into[name] = encoded
	end
	local function emit(item: { [string]: any })
		if stopped then return end
		if #items >= MAX_EVENTS then dropped += 1; return end
		item.ms = math.round((os.clock() - started) * 1000)
		local length = #HttpService:JSONEncode(item)
		if #items >= MAX_EVENTS or bytes + length > MAX_BYTES then
			dropped += 1
			return
		end
		bytes += length
		table.insert(items, item)
	end
	local ok, failure = pcall(function()
		for _, name in (params.properties or {}) do
			local previous = (target :: any)[name]
			baseline(initial, name, previous)
			table.insert(connections, target:GetPropertyChangedSignal(name):Connect(function()
				local readable, current = pcall(function() return (target :: any)[name] end)
				if readable then
					emit({ kind = "property", name = name, old = value(previous), value = value(current) })
					previous = current
				end
			end))
		end
		local previous = target:GetAttributes()
		local selected: { [string]: boolean }? = nil
		if params.attributes then
			selected = {}
			for _, name in params.attributes do (selected :: { [string]: boolean })[name] = true end
		end
		local attributes: { [string]: any } = {}
		local names = {}
		for name in previous do
			if not selected or selected[name] then table.insert(names, name) end
		end
		table.sort(names)
		for _, name in names do baseline(attributes, name, previous[name]) end
		initial.attributes = attributes
		table.insert(connections, target.AttributeChanged:Connect(function(name)
			if selected and not selected[name] then return end
			local current = target:GetAttribute(name)
			emit({ kind = "attribute", name = name, old = value(previous[name]), value = value(current), removed = current == nil or nil })
			previous[name] = current
		end))
		if params.children ~= false then
			initial.childCount = #target:GetChildren()
			for _, event in { "ChildAdded", "ChildRemoved" } do
				table.insert(connections, (target :: any)[event]:Connect(function(child: Instance)
					emit({ kind = event, name = child.Name, className = child.ClassName,
						path = Paths.of(child), handle = if child.Parent then Paths.handle(child) else nil })
				end))
			end
		end
		table.insert(connections, target.Destroying:Connect(function()
			emit({ kind = "destroyed" })
			stop()
		end))
		if owner then table.insert(connections, owner.Destroying:Connect(stop)) end
		-- Initial values count against the same reply budget as events.
		bytes += #HttpService:JSONEncode(initial)
		local deadline = os.clock() + seconds
		while not stopped and os.clock() < deadline do
			Dispatch.checkDeadline()
			task.wait(0.05)
		end
	end)
	stop()
	if not ok then error(failure, 0) end
	return { path = Paths.of(target), initial = initial, items = items, dropped = dropped,
		initialDropped = if initialDropped > 0 then initialDropped else nil,
		seconds = math.round((os.clock() - started) * 1000) / 1000,
			note = "Observed signal notifications, not writer attribution or physics motion. Deferred signals may coalesce rapid writes. Values capped at 512 bytes; 100 events/10KB including initial values per window." }
end

return Watch
