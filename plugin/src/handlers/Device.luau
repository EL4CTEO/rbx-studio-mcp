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

	The service is undocumented on return shapes, so what is reported below was
	read off a live session rather than from the reference. Notably
	`GetResolutionAsync` and its siblings THROW while no device is active,
	rather than returning a default, so every read here is guarded.
]]

local StudioDeviceSimulatorService = game:GetService("StudioDeviceSimulatorService")

local Dispatch = require(script.Parent.Parent.Dispatch)

local Device = {}

local function currentDeviceId(): string
	local ok, id = pcall(function()
		return (StudioDeviceSimulatorService :: any):GetDeviceAsync()
	end)
	return if ok then tostring(id) else "default"
end

--[[
	Everything the simulator will say about the current state.

	Each read is separately guarded: with no device active they raise
	"no device is active -- call SetDeviceAsync() first", and one of those
	should cost its own field rather than the whole reply.
]]
local function currentState(): { [string]: any }
	local state: { [string]: any } = { device = currentDeviceId() }

	local okRes, resolution = pcall(function()
		return (StudioDeviceSimulatorService :: any):GetResolutionAsync()
	end)
	if okRes and typeof(resolution) == "Vector2" then
		state.resolution = string.format("%dx%d", (resolution :: Vector2).X, (resolution :: Vector2).Y)
	end

	local okOrient, orientation = pcall(function()
		return (StudioDeviceSimulatorService :: any):GetOrientationAsync()
	end)
	if okOrient then
		state.orientation = tostring(orientation)
	end

	local okDensity, density = pcall(function()
		return (StudioDeviceSimulatorService :: any):GetPixelDensityAsync()
	end)
	if okDensity then
		state.pixelDensity = math.round(tonumber(density) :: number * 100) / 100
	end

	local okScaling, scaling = pcall(function()
		return (StudioDeviceSimulatorService :: any):GetScalingModeAsync()
	end)
	if okScaling then
		state.scalingMode = tostring(scaling)
	end

	state.emulating = state.device ~= "default"
	return state
end

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

	return { devices = devices, count = #devices, current = currentState() }
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
		Dispatch.fail(
			"NO_SUCH_DEVICE",
			string.format("Could not switch to %q: %s", id, tostring(err)),
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

	return currentState()
end

function Device.stop(_params: { [string]: any }): { [string]: any }
	local ok, err = pcall(function()
		(StudioDeviceSimulatorService :: any):StopSimulationAsync()
	end)
	if not ok then
		Dispatch.fail("DEVICE_UNAVAILABLE", string.format("Could not stop emulation: %s", tostring(err)))
	end
	return currentState()
end

function Device.state(_params: { [string]: any }): { [string]: any }
	return currentState()
end

function Device.register()
	Dispatch.registerAll("device", {
		list = Device.list,
		set = Device.set,
		stop = Device.stop,
		state = Device.state,
	})
end

return Device
