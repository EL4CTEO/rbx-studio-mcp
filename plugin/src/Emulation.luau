--!strict
--[[
	What device, if any, Studio's viewport is currently pretending to be.

	Three places need this and none of them can afford to disagree: the `device`
	tool reports it, `screenshot` captions it, and `studio_status` mentions it so
	an agent that never set a device still learns why the viewport is a strange
	shape. Emulation persists until it is switched off, which is exactly the kind
	of state that goes wrong quietly.

	`StudioDeviceSimulatorService` is undocumented on its return shapes, so what
	is here was read off a live session. Two things are worth knowing:

	* Every read THROWS while no device is active -- "no device is active, call
	  SetDeviceAsync() first" -- rather than returning a default, so each one is
	  guarded separately and costs only its own field.
	* `GetResolutionAsync` reports the panel's native size, which does not turn
	  when the device does. An iPhone 16 emulated in portrait still answers
	  852x393. See `orientedSize`.
]]

local StudioDeviceSimulatorService = game:GetService("StudioDeviceSimulatorService")

local Emulation = {}

--[[
	The resolution as it actually appears, rather than as the panel is specified.

	Reporting 852x393 for a screen that is 393 wide and 852 tall is worse than
	reporting nothing: getting the shape of the screen right is the entire reason
	device emulation exists, and a caller sizing a menu against those numbers
	would place it off the bottom of the display it was told it fits.

	Only swapped when the orientation names a direction. "Sensor" means the
	device decides, and guessing on its behalf would trade a knowable error for
	an unknowable one.
]]
local function orientedSize(size: Vector2, orientation: string?): (number, number)
	local width = math.floor(size.X)
	local height = math.floor(size.Y)

	local wantsPortrait: boolean? = nil
	if orientation ~= nil then
		if string.find(orientation, "Portrait") ~= nil then
			wantsPortrait = true
		elseif string.find(orientation, "Landscape") ~= nil then
			wantsPortrait = false
		end
	end

	-- `width > height` is the shape we have; `wantsPortrait` is the shape we
	-- want. Equal means they disagree, because portrait is the narrow one.
	if wantsPortrait ~= nil and wantsPortrait == (width > height) then
		return height, width
	end
	return width, height
end

--[[
	The active device id, or nil when the viewport is the ordinary editor.

	"default" is the simulator's own word for not emulating; it is turned into
	nil here so callers test one thing rather than two.
]]
function Emulation.deviceId(): string?
	local ok, id = pcall(function()
		return (StudioDeviceSimulatorService :: any):GetDeviceAsync()
	end)
	if not ok or id == nil or tostring(id) == "default" then
		return nil
	end
	return tostring(id)
end

--[[
	Orientation with the enum prefix removed: "Portrait", "LandscapeRight".
]]
function Emulation.orientation(): string?
	local ok, orientation = pcall(function()
		return (StudioDeviceSimulatorService :: any):GetOrientationAsync()
	end)
	if not ok then
		return nil
	end
	local name = tostring(orientation):gsub("Enum%.ScreenOrientation%.", "")
	return name
end

--[[
	"393x852", turned the way the screen is actually turned.
]]
function Emulation.resolution(orientation: string?): string?
	local ok, size = pcall(function()
		return (StudioDeviceSimulatorService :: any):GetResolutionAsync()
	end)
	if not ok or typeof(size) ~= "Vector2" then
		return nil
	end
	local width, height = orientedSize(size :: Vector2, orientation)
	return string.format("%dx%d", width, height)
end

--[[
	Everything the simulator will say, for the `device` tool.
]]
function Emulation.state(): { [string]: any }
	local id = Emulation.deviceId()
	local orientation = Emulation.orientation()

	local state: { [string]: any } = {
		device = id or "default",
		emulating = id ~= nil,
	}
	state.resolution = Emulation.resolution(orientation)
	state.orientation = orientation

	local okDensity, density = pcall(function()
		return (StudioDeviceSimulatorService :: any):GetPixelDensityAsync()
	end)
	if okDensity then
		state.pixelDensity = math.round((tonumber(density) :: number) * 100) / 100
	end

	local okScaling, scaling = pcall(function()
		return (StudioDeviceSimulatorService :: any):GetScalingModeAsync()
	end)
	if okScaling then
		state.scalingMode = tostring(scaling)
	end

	return state
end

--[[
	The short form carried by `studio_status`, or nil when nothing is emulated.
]]
function Emulation.summary(): { [string]: any }?
	local id = Emulation.deviceId()
	if id == nil then
		return nil
	end
	local orientation = Emulation.orientation()
	return {
		id = id,
		resolution = Emulation.resolution(orientation),
		orientation = orientation,
		note = 'The viewport is emulating this device. `device op="stop"` returns it to normal.',
	}
end

return Emulation
