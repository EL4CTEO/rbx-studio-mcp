--!strict
--[[
	The audio graph: wiring AudioPlayers to whatever plays them.

	Roblox's modern audio API is not one instance with a Play method. It is a
	signal graph: an `AudioPlayer` holds the asset, an `AudioEmitter` puts sound
	in the world or an `AudioDeviceOutput` sends it straight to the player's
	speakers, effects sit in between, and NONE of them are connected until a
	`Wire` joins two named pins. A place can hold a perfectly configured
	AudioPlayer with the right asset, the right volume and `Playing` true, and be
	completely silent, because the one instance that carries sound between them
	was never made.

	`create` can already build each of those instances -- that is not the gap.
	The gap is that getting sound out requires knowing the pin names, knowing
	which of the eight-odd sink classes fits the case, and getting the wire's
	direction right, and a wrong guess produces silence rather than an error.
	So this file does not wrap the engine's audio API; it wraps the knowledge of
	how to assemble it.

	Old `Sound` instances still work and are still the shorter path for a plain
	one-off noise. Reach for this when the case needs what Sound cannot do:
	effects, per-listener mixing, or an emitter fed by several sources.
]]

local Dispatch = require(script.Parent.Parent.Dispatch)
local Paths = require(script.Parent.Parent.Paths)
local Serialize = require(script.Parent.Parent.Serialize)
local Undo = require(script.Parent.Parent.Undo)

local Audio = {}

-- Effects usable in the middle of a chain: exactly one Input and one Output, so
-- they can be spliced in without the caller naming pins.
local EFFECTS: { [string]: boolean } = {
	AudioFader = true,
	AudioEqualizer = true,
	AudioCompressor = true,
	AudioReverb = true,
	AudioEcho = true,
	AudioDistortion = true,
	AudioPitchShifter = true,
	AudioChorus = true,
	AudioFlanger = true,
	AudioLimiter = true,
}

local function pinsOf(instance: Instance): ({ string }, { string })
	local okIn, inputs = pcall(function()
		return (instance :: any):GetInputPins()
	end)
	local okOut, outputs = pcall(function()
		return (instance :: any):GetOutputPins()
	end)
	return (if okIn then inputs else {}), (if okOut then outputs else {})
end

local function isAudio(instance: Instance): boolean
	local inputs, outputs = pinsOf(instance)
	return #inputs > 0 or #outputs > 0
end

--[[
	Joins two pins with a Wire.

	The pin names are checked against the instances' own `GetInputPins` and
	`GetOutputPins` rather than against a table here, because that list comes
	from the running engine and this file would go stale. A wrong pin name is
	the failure worth catching: the engine accepts any string, the Wire reports
	`Connected = false`, and the only symptom is silence.

	The wire is parented to the TARGET. Nothing in the engine requires that, but
	a wire has to live somewhere and scattering them makes a graph unreadable in
	the Explorer; keeping each one with the thing it feeds means the chain reads
	backwards from the speaker, which is how anyone debugging silence walks it.
]]
local function connect(
	source: Instance,
	target: Instance,
	sourcePin: string?,
	targetPin: string?
): (Wire, string?)
	local _, sourceOutputs = pinsOf(source)
	local targetInputs, _ = pinsOf(target)

	if #sourceOutputs == 0 then
		Dispatch.fail(
			"BAD_PARAMS",
			string.format("%s has no output pins, so nothing can come out of it.", source.ClassName)
		)
	end
	if #targetInputs == 0 then
		Dispatch.fail(
			"BAD_PARAMS",
			string.format("%s has no input pins, so nothing can go into it.", target.ClassName)
		)
	end

	local fromPin = sourcePin or (if table.find(sourceOutputs, "Output") then "Output" else sourceOutputs[1])
	local toPin = targetPin or (if table.find(targetInputs, "Input") then "Input" else targetInputs[1])

	if not table.find(sourceOutputs, fromPin) then
		Dispatch.fail(
			"BAD_PARAMS",
			string.format('%s has no output pin named "%s".', source.ClassName, fromPin),
			string.format("It has: %s", table.concat(sourceOutputs, ", "))
		)
	end
	if not table.find(targetInputs, toPin) then
		Dispatch.fail(
			"BAD_PARAMS",
			string.format('%s has no input pin named "%s".', target.ClassName, toPin),
			string.format("It has: %s", table.concat(targetInputs, ", "))
		)
	end

	local wire = Instance.new("Wire")
	wire.SourceInstance = source
	wire.SourceName = fromPin
	wire.TargetInstance = target
	wire.TargetName = toPin
	wire.Parent = target

	--[[
		`Connected` is read back rather than assumed. It is the engine's own
		verdict on whether this wire carries anything, and it is the difference
		between "wired" and "wired correctly" -- the whole reason silence is so
		hard to debug by hand.
	]]
	local warning: string? = nil
	if not wire.Connected then
		warning = string.format(
			"The wire from %s.%s to %s.%s reports Connected = false.",
			source.ClassName,
			fromPin,
			target.ClassName,
			toPin
		)
	end
	return wire, warning
end

--[[
	Wires two existing instances together.
]]
function Audio.wire(params: { [string]: any }): { [string]: any }
	local fromPath, toPath = params.from, params.to
	if typeof(fromPath) ~= "string" or typeof(toPath) ~= "string" then
		Dispatch.fail("BAD_PARAMS", "`from` and `to` are both paths to audio instances.")
	end

	local source = Paths.resolve(fromPath)
	local target = Paths.resolve(toPath)

	local result, undoable = Undo.record("MCPAudioWire", "Wire audio", function()
		local wire, warning = connect(
			source,
			target,
			if typeof(params.fromPin) == "string" then params.fromPin else nil,
			if typeof(params.toPin) == "string" then params.toPin else nil
		)
		return {
			wire = Paths.of(wire),
			from = Paths.of(source),
			to = Paths.of(target),
			connected = wire.Connected,
			warning = warning,
		}
	end)

	result.undoable = undoable
	return result
end

--[[
	Builds a whole working chain in one step.

	`world` is a sound at a place: AudioPlayer -> [effects] -> AudioEmitter,
	parented to a part, heard from wherever it is. This is the common case and
	the one people get wrong, because it also needs an `AudioListener` somewhere
	-- without one on the camera or the character, a correctly wired emitter is
	still silent. Reported rather than created: where the listener belongs is a
	game design decision, not a default.

	`ui` is a sound with no position: AudioPlayer -> [effects] ->
	AudioDeviceOutput. Menu clicks, music.
]]
function Audio.graph(params: { [string]: any }): { [string]: any }
	local kind = tostring(params.kind or "world")
	if kind ~= "world" and kind ~= "ui" then
		Dispatch.fail("BAD_PARAMS", string.format("unknown kind %q", kind), 'Use "world" or "ui".')
	end

	local parentPath = params.parent
	if typeof(parentPath) ~= "string" or parentPath == "" then
		Dispatch.fail(
			"BAD_PARAMS",
			"`parent` says where the graph goes.",
			'For kind="world" that is the part the sound comes from.'
		)
	end
	local parent = Paths.resolve(parentPath)

	if kind == "world" and not parent:IsA("BasePart") and not parent:IsA("Attachment") then
		Dispatch.fail(
			"BAD_PARAMS",
			string.format("%s is a %s.", parentPath, parent.ClassName),
			"A world sound needs somewhere in the world to come from: parent it "
				.. 'to a BasePart or an Attachment, or use kind="ui" for a sound '
				.. "with no position."
		)
	end

	local asset = params.asset
	if asset ~= nil and typeof(asset) ~= "string" then
		Dispatch.fail("BAD_PARAMS", "`asset` is an id like \"rbxassetid://1234\".")
	end

	local effects: { string } = {}
	if params.effects ~= nil then
		if typeof(params.effects) ~= "table" then
			Dispatch.fail("BAD_PARAMS", "`effects` is a list of class names.")
		end
		for _, name in params.effects :: { any } do
			local class = tostring(name)
			if not EFFECTS[class] then
				local known: { string } = {}
				for effect in EFFECTS do
					table.insert(known, effect)
				end
				table.sort(known)
				Dispatch.fail(
					"BAD_PARAMS",
					string.format("%s is not an audio effect that can sit in a chain.", class),
					string.format("Use one of: %s", table.concat(known, ", "))
				)
			end
			table.insert(effects, class)
		end
	end

	local name = if typeof(params.name) == "string" and params.name ~= "" then params.name else "Audio"

	local result, undoable = Undo.record("MCPAudioGraph", "Build audio graph", function()
		local created: { string } = {}
		local warnings: { string } = {}

		local player = Instance.new("AudioPlayer")
		player.Name = name
		if asset then
			--[[
				`AudioContent` is the modern property and takes a Content, not a
				string -- assigning the id directly throws. `Asset` is the older
				ContentId spelling and still works; this uses the one the running
				engine actually has rather than picking a side.
			]]
			local okContent = pcall(function()
				player.AudioContent = Content.fromUri(asset :: string)
			end)
			if not okContent then
				pcall(function()
					(player :: any).Asset = asset
				end)
			end
		end
		player.Parent = parent
		table.insert(created, Paths.of(player))

		-- The chain is built front to back, each link wired to the one before.
		local previous: Instance = player
		for _, class in effects do
			local effect = Instance.new(class)
			effect.Name = class:gsub("^Audio", "")
			effect.Parent = parent
			local _, warning = connect(previous, effect)
			if warning then
				table.insert(warnings, warning)
			end
			table.insert(created, Paths.of(effect))
			previous = effect
		end

		local sink = Instance.new(if kind == "world" then "AudioEmitter" else "AudioDeviceOutput")
		sink.Name = if kind == "world" then "Emitter" else "Output"
		sink.Parent = parent
		local _, sinkWarning = connect(previous, sink)
		if sinkWarning then
			table.insert(warnings, sinkWarning)
		end
		table.insert(created, Paths.of(sink))

		local note: string? = nil
		if kind == "world" then
			--[[
				An emitter with no listener anywhere is the single most common
				way a correct graph stays silent, and it is invisible from the
				emitter's own properties. Checked and said plainly.
			]]
			local listeners = 0
			for _, descendant in game:GetDescendants() do
				if descendant:IsA("AudioListener") then
					listeners += 1
				end
			end
			if listeners == 0 then
				note = "Nothing in this place has an AudioListener, so no emitter can "
					.. "be heard. Put one on the camera or the character -- where it "
					.. "goes decides what the player hears, so it is not created here."
			end
		end

		return {
			kind = kind,
			player = Paths.of(player),
			sink = Paths.of(sink),
			created = created,
			warnings = warnings,
			note = note,
		}
	end)

	result.undoable = undoable
	return result
end

--[[
	Reads an existing graph back.

	Walks whatever audio instances live under a path and reports every wire in
	and out of each, which is the view the Explorer will not give: a Wire shows
	as a child of one instance and names the other two only in its properties, so
	following a chain by hand means clicking through every node.
]]
function Audio.inspect(params: { [string]: any }): { [string]: any }
	local path = params.path
	local scope: Instance = if typeof(path) == "string" and path ~= ""
		then Paths.resolve(path)
		else game

	local nodes: { { [string]: any } } = {}
	local wires: { { [string]: any } } = {}
	local broken = 0

	local function visit(instance: Instance)
		if instance:IsA("Wire") then
			local source = instance.SourceInstance
			local target = instance.TargetInstance
			if not instance.Connected then
				broken += 1
			end
			table.insert(wires, {
				path = Paths.of(instance),
				from = if source then string.format("%s.%s", Paths.of(source), instance.SourceName) else "(nothing)",
				to = if target then string.format("%s.%s", Paths.of(target), instance.TargetName) else "(nothing)",
				connected = instance.Connected,
			})
		elseif isAudio(instance) then
			local entry: { [string]: any } = {
				path = Paths.of(instance),
				class = instance.ClassName,
			}
			-- Only the properties that decide whether a node is audible; the
			-- full set is what `inspect` is for.
			for _, property in { "Volume", "Playing", "IsPlaying", "Looping", "AudioInteractionGroup" } do
				local ok, value = pcall(function()
					return (instance :: any)[property]
				end)
				if ok and value ~= nil then
					entry[property] = Serialize.value(value)
				end
			end
			table.insert(nodes, entry)
		end
	end

	visit(scope)
	for _, descendant in scope:GetDescendants() do
		visit(descendant)
	end

	local note: string? = nil
	if #nodes > 0 and #wires == 0 then
		note = "There are audio instances here but no wires, so nothing carries sound "
			.. "between them. That is silence with no error anywhere."
	elseif broken > 0 then
		note = string.format(
			"%d wire(s) report Connected = false -- usually a pin name that does not "
				.. "exist on one end, or an instance that was deleted.",
			broken
		)
	end

	return {
		scope = Paths.of(scope),
		nodes = nodes,
		wires = wires,
		nodeCount = #nodes,
		wireCount = #wires,
		note = note,
	}
end

function Audio.register()
	Dispatch.registerAll("audio", {
		wire = Audio.wire,
		graph = Audio.graph,
		inspect = Audio.inspect,
	})
end

return Audio
