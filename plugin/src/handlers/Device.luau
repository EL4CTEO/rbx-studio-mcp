--!strict
--[[
	Device emulation: run Studio's viewport as a phone, tablet or console.

	Most Roblox players are on a phone, and most UI is authored on a desktop
	monitor. The gap between those two is where interfaces break -- a button
	inside the notch, a menu off the bottom of a 393-pixel-tall screen, text
	scaled for a display three times larger. Reading the data model cannot find
	any of it, because every one of those instances has correct properties.

	`StudioDeviceSimulatorService` resizes the viewport for real. Paired with
	`screenshot` it is the only way to answer "does this work on a phone"
	without owning one: set the device, take the picture, look.

	The same tool also shapes network traffic, which belongs here for the same
	reason the two sit together in Studio's own toolbar: "what a player on that
	device sees" is not only the shape of their screen. Most of the players this
	is aimed at are on a phone connection, and a menu that works at 0ms is not
	evidence that it works at 300 -- the loading spinner that never stops, the
	button that fires twice, the HUD that pops in after the round has started are
	all invisible until the network is slow enough to show them.

	Reading the current state is `Emulation`'s job, shared with `screenshot` and
	`studio_status` so the three cannot drift apart on what is being emulated.
]]

local StudioDeviceSimulatorService = game:GetService("StudioDeviceSimulatorService")

local Dispatch = require(script.Parent.Parent.Dispatch)
local Emulation = require(script.Parent.Parent.Emulation)

local Device = {}

function Device.list(_params: { [string]: any }): { [string]: any }
	local ok, list = pcall(function()
		return (StudioDeviceSimulatorService :: any):GetDeviceListAsync()
	end)
	if not ok then
		Dispatch.fail("DEVICE_UNAVAILABLE", string.format("Could not list devices: %s", tostring(list)))
	end

	--[[
		The list is ids, not descriptions, and an id alone does not say whether
		"generic_handheld_720" is a phone or a handheld console. The details come
		from a second call per device, which is worth the round trip once because
		the caller otherwise has to guess which id to ask for.
	]]
	local devices: { { [string]: any } } = {}
	for _, id in list :: { string } do
		local okInfo, info = pcall(function()
			return (StudioDeviceSimulatorService :: any):GetDeviceInfoAsync(id)
		end)
		if okInfo and typeof(info) == "table" then
			local entry = info :: { [string]: any }
			table.insert(devices, {
				id = tostring(id),
				name = tostring(entry.Name),
				form = tostring(entry.DeviceForm):gsub("Enum%.DeviceForm%.", ""),
				resolution = string.format("%dx%d", entry.Width or 0, entry.Height or 0),
			})
		else
			table.insert(devices, { id = tostring(id) })
		end
	end

	return { devices = devices, count = #devices, current = Emulation.state() }
end

function Device.set(params: { [string]: any }): { [string]: any }
	local id = params.device
	if typeof(id) ~= "string" or id == "" then
		Dispatch.fail("BAD_PARAMS", "set needs a `device` id. Call `list` to see them.")
	end

	local ok, err = pcall(function()
		(StudioDeviceSimulatorService :: any):SetDeviceAsync(id)
	end)
	if not ok then
		--[[
			Two different failures, and calling both NO_SUCH_DEVICE sends the
			caller to check a spelling that was never wrong.

			The simulator refuses outright while a playtest is running -- "cannot
			change device in current game state" -- and this handler is reachable
			from the playtest session, which is exactly where someone testing a
			phone HUD would call it. The device is settable from the EDIT session
			meanwhile, playtest or no playtest, so the fix is a sentence, not a
			spelling check.
		]]
		local reason = tostring(err)
		if string.find(reason, "game state", 1, true) ~= nil then
			Dispatch.fail(
				"DEVICE_LOCKED",
				string.format("Studio will not switch to %q while a playtest is running.", id),
				"Send this to the EDIT session's studioId instead -- it changes the viewport for "
					.. "the running playtest too -- or set the device before pressing play."
			)
		end
		Dispatch.fail(
			"NO_SUCH_DEVICE",
			string.format("Could not switch to %q: %s", id, reason),
			"Device ids look like \"iphone_16\" or \"ipad_a16\"; call `list` for the full set."
		)
	end

	if typeof(params.orientation) == "string" and params.orientation ~= "" then
		local okOrient, orientErr = pcall(function()
			(StudioDeviceSimulatorService :: any):SetOrientationAsync(
				(Enum :: any).ScreenOrientation[params.orientation]
			)
		end)
		if not okOrient then
			Dispatch.fail(
				"BAD_PARAMS",
				string.format("Could not set orientation %q: %s", params.orientation, tostring(orientErr)),
				'Use "LandscapeLeft", "LandscapeRight", "Portrait" or "Sensor".'
			)
		end
	end

	return Emulation.state()
end

--[[
	Named connections, so a caller does not have to invent milliseconds.

	Round numbers off real-world measurements rather than anything
	authoritative: the point is a plausible bad connection to test against, and
	an argument about whether 3G is 150ms or 180ms does not change what breaks.
	`poor` is deliberately harsh -- crowded stadium wifi, a phone on one bar --
	because the failures worth finding only appear at the far end.

	Loss is the percentage of packets thrown away, and it is the field that finds
	the interesting bugs: latency makes a game feel slow, loss makes it behave
	wrongly.
]]
local PRESETS: { [string]: { latency: number, jitter: number, loss: number } } = {
	clear = { latency = 0, jitter = 0, loss = 0 },
	wifi = { latency = 15, jitter = 5, loss = 0 },
	["4g"] = { latency = 60, jitter = 15, loss = 0.5 },
	["3g"] = { latency = 150, jitter = 40, loss = 2 },
	poor = { latency = 400, jitter = 120, loss = 8 },
}

--[[
	Percent in, fraction out.

	`InboundNetworkLossPercent` does not take a percentage: it takes a fraction
	and clamps at 0.5. Writing 2 for "2% loss" succeeds, lands at 0.5, and
	degrades half the traffic -- a hundred times what was asked for, with no
	error anywhere. Every caller of this file speaks percent, so the conversion
	is here and only here.
]]
local function lossFraction(percent: number): number
	return math.clamp(percent, 0, Emulation.LOSS_LIMIT_PERCENT) / 100
end

local function presetNames(): string
	local names: { string } = {}
	for name in PRESETS do
		table.insert(names, name)
	end
	table.sort(names)
	return table.concat(names, ", ")
end

--[[
	Writes one shaping property, and says so if it could not.

	Collected rather than raised: a Studio missing one of these six should apply
	the five it has and report the gap, because the alternative is a `network`
	call that fails outright having already shaped traffic halfway.
]]
local function apply(service: any, property: string, value: number, refused: { string })
	local ok = pcall(function()
		service[property] = value
	end)
	if not ok then
		table.insert(refused, property)
	end
end

--[[
	Degrades the connection on purpose.

	Everything is optional and everything is absolute: a call naming only `loss`
	leaves the delays where they were, which is what makes it possible to add one
	variable at a time and see which one breaks the thing. `preset` sets all
	three at once and named fields override it, so `preset="3g" loss=10` reads as
	"3G, on a bad day".

	Direction defaults to both. Inbound alone is the player with a bad
	connection; outbound alone is everyone else seeing that player late.
]]
function Device.network(params: { [string]: any }): { [string]: any }
	local service = Emulation.networkSettings()
	if service == nil then
		Dispatch.fail(
			"NETWORK_UNAVAILABLE",
			"This Studio has no NetworkSettings service to shape traffic with.",
			"Update Studio; the simulation properties landed in September 2026."
		)
	end

	local direction = string.lower(tostring(params.direction or "both"))
	if direction ~= "in" and direction ~= "out" and direction ~= "both" then
		Dispatch.fail("BAD_PARAMS", 'direction must be "in", "out" or "both".')
	end

	local latency: number? = nil
	local jitter: number? = nil
	local loss: number? = nil

	if params.preset ~= nil then
		local name = string.lower(tostring(params.preset))
		local preset = PRESETS[name]
		if preset == nil then
			Dispatch.fail(
				"BAD_PARAMS",
				string.format("unknown preset %q", tostring(params.preset)),
				string.format("Presets are: %s.", presetNames())
			)
		end
		latency, jitter, loss = preset.latency, preset.jitter, preset.loss
		-- "clear" is a whole-connection word, so it takes the memory cap with
		-- it. Any other preset says nothing about memory and leaves it alone.
		if name == "clear" then
			apply(service, "EmulatedTotalMemoryInMB", 0, {})
			Emulation.setMemoryCap(nil)
		end
	end

	-- Named fields win over the preset, so one value can be pushed past it
	-- without respelling the other two.
	if params.latency ~= nil then
		latency = tonumber(params.latency) or 0
	end
	if params.jitter ~= nil then
		jitter = tonumber(params.jitter) or 0
	end
	if params.loss ~= nil then
		loss = tonumber(params.loss) or 0
	end

	--[[
		Clamped here, where it can be reported, rather than left to the engine,
		which clamps silently. `capped` goes back in the reply so a caller asking
		for 5 seconds of latency learns it got one, instead of reading 1000 in
		the state and assuming it typed the number wrong.
	]]
	local capped: { string } = {}
	if latency ~= nil and latency > Emulation.DELAY_LIMIT then
		table.insert(capped, string.format("latency %g -> %d", latency, Emulation.DELAY_LIMIT))
		latency = Emulation.DELAY_LIMIT
	end
	if jitter ~= nil and jitter > Emulation.DELAY_LIMIT then
		table.insert(capped, string.format("jitter %g -> %d", jitter, Emulation.DELAY_LIMIT))
		jitter = Emulation.DELAY_LIMIT
	end
	if loss ~= nil and loss > Emulation.LOSS_LIMIT_PERCENT then
		table.insert(capped, string.format("loss %g%% -> %g%%", loss, Emulation.LOSS_LIMIT_PERCENT))
		loss = Emulation.LOSS_LIMIT_PERCENT
	end
	if latency ~= nil then
		latency = math.max(latency, 0)
	end
	if jitter ~= nil then
		jitter = math.max(jitter, 0)
	end

	local memory: number? = nil
	if params.memory ~= nil then
		--[[
			A memory ceiling in megabytes, because the device half of this tool
			is only half the truth about a cheap phone: it has a small screen AND
			little memory, and the second is what makes a place unload textures
			or fail to join at all. 0 turns the cap off.
		]]
		memory = math.clamp(math.floor(tonumber(params.memory) or 0), 0, 65536)
	end

	if latency == nil and jitter == nil and loss == nil and memory == nil then
		Dispatch.fail(
			"BAD_PARAMS",
			"network needs something to set.",
			string.format(
				"Pass a `preset` (%s), or any of `latency`, `jitter`, `loss` and `memory`.",
				presetNames()
			)
		)
	end

	local refused: { string } = {}
	local inbound = direction == "in" or direction == "both"
	local outbound = direction == "out" or direction == "both"

	if latency ~= nil then
		if inbound then
			apply(service, "InboundNetworkMinDelayMs", latency, refused)
		end
		if outbound then
			apply(service, "OutboundNetworkMinDelayMs", latency, refused)
		end
	end
	if jitter ~= nil then
		if inbound then
			apply(service, "InboundNetworkJitterMs", jitter, refused)
		end
		if outbound then
			apply(service, "OutboundNetworkJitterMs", jitter, refused)
		end
	end
	if loss ~= nil then
		local fraction = lossFraction(loss)
		if inbound then
			apply(service, "InboundNetworkLossPercent", fraction, refused)
		end
		if outbound then
			apply(service, "OutboundNetworkLossPercent", fraction, refused)
		end
	end
	if memory ~= nil then
		apply(service, "EmulatedTotalMemoryInMB", memory, refused)
		Emulation.setMemoryCap(memory)
	end

	local state = Emulation.network()
	state.direction = direction
	if #refused > 0 then
		state.refused = refused
	end
	if #capped > 0 then
		state.capped = capped
	end
	return state
end

--[[
	Stops emulating: the viewport AND the connection.

	Both, because "stop" is one idea to the person asking and two APIs
	underneath. Leaving shaped traffic behind after a stop is the exact failure
	this tool warns about everywhere else -- invisible state outliving the
	session that set it -- and it would be worse here, because the caller
	believes they just turned emulation off.
]]
function Device.stop(_params: { [string]: any }): { [string]: any }
	local ok, err = pcall(function()
		(StudioDeviceSimulatorService :: any):StopSimulationAsync()
	end)

	local service = Emulation.networkSettings()
	if service ~= nil then
		local ignored: { string } = {}
		apply(service, "InboundNetworkMinDelayMs", 0, ignored)
		apply(service, "InboundNetworkJitterMs", 0, ignored)
		apply(service, "InboundNetworkLossPercent", 0, ignored)
		apply(service, "OutboundNetworkMinDelayMs", 0, ignored)
		apply(service, "OutboundNetworkJitterMs", 0, ignored)
		apply(service, "OutboundNetworkLossPercent", 0, ignored)
		apply(service, "EmulatedTotalMemoryInMB", 0, ignored)
		Emulation.setMemoryCap(nil)
	end

	--[[
		Raised after the network is cleared, not before.

		`StopSimulationAsync` throws when no device was ever set, which is a
		perfectly ordinary way to reach this function -- someone shaping traffic
		without emulating a phone. Failing first would have left their connection
		degraded by the call that was meant to restore it.
	]]
	if not ok and Emulation.deviceId() ~= nil then
		Dispatch.fail("DEVICE_UNAVAILABLE", string.format("Could not stop emulation: %s", tostring(err)))
	end

	return Emulation.state()
end

function Device.state(_params: { [string]: any }): { [string]: any }
	return Emulation.state()
end

function Device.register()
	Dispatch.registerAll("device", {
		list = Device.list,
		set = Device.set,
		stop = Device.stop,
		network = Device.network,
		state = Device.state,
	})
end

return Device
