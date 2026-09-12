--!strict
--[[
	What device, if any, Studio's viewport is currently pretending to be.

	Three places need this and none of them can afford to disagree: the `device`
	tool reports it, `screenshot` captions it, and `studio_status` mentions it so
	an agent that never set a device still learns why the viewport is a strange
	shape. Emulation persists until it is switched off, which is exactly the kind
	of state that goes wrong quietly.

	The network conditions Studio is shaping traffic with live here too. They are
	the same kind of state for the same reason: set once, invisible on screen,
	and they stay until something turns them off. A place that "feels laggy" with
	a forgotten 400ms delay on it is exactly the bug this file exists to stop
	people chasing.

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

--[[
	`NetworkSettings` is not a `game` service; it hangs off `settings()`.

	`game:GetService("NetworkSettings")` throws outright, which is worth writing
	down because every other service in this codebase is reached that way. The
	traffic-shaping properties on it -- delay, jitter, loss, in each direction --
	are PluginSecurity, so they are readable and writable here and nowhere near a
	running game.

	Guarded: it is reached through a `pcall` at every use rather than captured
	once, because a Studio old enough to lack the properties should cost the
	network feature, not the whole `device` tool.
]]
local function networkSettings(): any?
	local ok, service = pcall(function()
		return (settings() :: any):GetService("NetworkSettings")
	end)
	if ok and service ~= nil then
		return service
	end
	return nil
end

local Emulation = {}

Emulation.networkSettings = networkSettings

--[[
	The six traffic-shaping properties, in the order a person reads them.

	Inbound is what the client receives and is what a laggy connection feels
	like; outbound is what it sends, which is what makes a player's own actions
	arrive late to everyone else. Both are shaped separately by Studio, so both
	are carried separately here.
]]
--[[
	The memory ceiling this session set, if any.

	Session-local by necessity: see the note in `Emulation.network`. A cap set by
	Studio's own toolbar before the plugin loaded is invisible to this, which is
	the honest failure -- reporting a cap that is not there was the alternative,
	and it was worse.
]]
local memoryCap: number? = nil

local NETWORK_FIELDS = {
	{ key = "inLatency", property = "InboundNetworkMinDelayMs", scale = 1 },
	{ key = "inJitter", property = "InboundNetworkJitterMs", scale = 1 },
	{ key = "inLoss", property = "InboundNetworkLossPercent", scale = 100 },
	{ key = "outLatency", property = "OutboundNetworkMinDelayMs", scale = 1 },
	{ key = "outJitter", property = "OutboundNetworkJitterMs", scale = 1 },
	{ key = "outLoss", property = "OutboundNetworkLossPercent", scale = 100 },
}

--[[
	What the engine will actually accept, measured rather than assumed.

	None of this is documented and all three of them bite. Writes outside these
	ranges SUCCEED and are silently clamped, so a preset asking for 2% loss was
	reporting 0.5 back and the only way to notice was to read the value again --
	which is how this was found.

	* Loss is a FRACTION, despite `LossPercent` in the name: it tops out at 0.5,
	  and 0.5 is half the packets, not half a percent. Everything above this
	  layer speaks in percent because that is what a person means by "2% loss",
	  so the conversion happens at the edges -- `scale` above on the way out, and
	  `LOSS_LIMIT` on the way in.
	* Delay and jitter both stop at 1000ms. A second of latency is already past
	  anything a real connection does, so this costs nothing but honesty.
]]
local LOSS_LIMIT = 0.5
local DELAY_LIMIT = 1000

Emulation.LOSS_LIMIT_PERCENT = LOSS_LIMIT * 100
Emulation.DELAY_LIMIT = DELAY_LIMIT

--[[
	What Studio is currently doing to network traffic.

	`shaping` is the field callers should branch on: every value being zero is
	the normal, un-emulated state, and reporting six zeroes without saying so
	makes "is anything on" a question the caller has to work out for itself.
]]
function Emulation.network(): { [string]: any }
	local service = networkSettings()
	if service == nil then
		return { available = false, shaping = false }
	end

	local state: { [string]: any } = { available = true }
	local shaping = false
	for _, field in NETWORK_FIELDS do
		local ok, value = pcall(function()
			return (service :: any)[field.property]
		end)
		local number = if ok then tonumber(value) or 0 else 0
		--[[
			Scaled into the caller's units, then rounded to two places. These are
			32-bit floats: 2% loss is stored as 0.02 and reads back as
			0.019999999552965164, and reporting that instead of 2 makes a
			perfectly applied setting look like a failed one.
		]]
		number *= field.scale
		state[field.key] = math.round(number * 100) / 100
		if number > 0 then
			shaping = true
		end
	end

	--[[
		Reported, but deliberately not counted as shaping.

		`EmulatedTotalMemoryInMB` does not read back 0 when nothing is emulated:
		it answers with the machine's real memory -- measured, 16159 on the
		session this was written against. Treating "greater than zero" as a cap
		therefore declared every untouched Studio to be emulating a low-memory
		device, and `studio_status` told the agent traffic was being degraded on
		a session where nothing had ever been set.

		There is no read that distinguishes a cap from the true figure, so the
		cap is remembered instead, by the one thing that sets it.
	]]
	local okMemory, memory = pcall(function()
		return (service :: any).EmulatedTotalMemoryInMB
	end)
	if okMemory then
		state.memoryMB = math.floor(tonumber(memory) or 0)
	end

	if memoryCap ~= nil and memoryCap > 0 then
		state.memoryCapMB = memoryCap
		shaping = true
	end

	state.shaping = shaping
	return state
end

--[[
	Records the memory ceiling this session asked for.

	Held here rather than in the handler because `network` writes it and
	`Emulation.network` reports it, and a value those two disagree about is worse
	than no value at all. nil or 0 means no cap.
]]
function Emulation.setMemoryCap(megabytes: number?)
	memoryCap = if megabytes ~= nil and megabytes > 0 then megabytes else nil
end

--[[
	The short form for `studio_status`, or nil when traffic is untouched.

	Separate from the device summary rather than folded into it: a session can be
	shaping traffic without emulating a device, and the device summary returns
	nil in exactly that case.
]]
function Emulation.networkSummary(): { [string]: any }?
	local state = Emulation.network()
	if state.shaping ~= true then
		return nil
	end
	state.note = 'Studio is degrading network traffic on purpose. `device op="network" '
		.. 'preset="clear"` restores it.'
	return state
end

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

	state.network = Emulation.network()

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
