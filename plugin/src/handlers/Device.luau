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

function Device.stop(_params: { [string]: any }): { [string]: any }
	local ok, err = pcall(function()
		(StudioDeviceSimulatorService :: any):StopSimulationAsync()
	end)
	if not ok then
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
		state = Device.state,
	})
end

return Device
