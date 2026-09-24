--!strict
--[[
	Converts Roblox values into JSON-safe, token-cheap representations.

	Format mirrors what the Studio Properties panel shows -- Vector3 as
	"12, 0, 5", Enums as "Enum.Material.Plastic", instance references as their
	path. Two reasons: a Roblox developer reading the transcript sees what they
	would see in Studio, and a model has seen far more of that notation in
	training than any bespoke JSON envelope. It is also markedly cheaper than
	{"__type":"Vector3","x":12,"y":0,"z":5} on every property of every instance.

	`Serialize.parse` is the exact inverse, so a value read here can be written
	straight back without the agent reformatting it.
]]

local Paths = require(script.Parent.Paths)

local Serialize = {}

--[[
	Marks a failure that means "the instance is not there" rather than "this
	value is wrong".

	The create handler retries only these, once the whole batch is attached, so
	a reference to a sibling made in the same call resolves. Anything else is a
	real mistake and is reported straight away.
]]
local UNRESOLVED_PREFIX = "[unresolved] "
Serialize.UNRESOLVED_PREFIX = UNRESOLVED_PREFIX

-- Floats are rounded before display: Studio reports positions like
-- 12.000000476837158, which costs tokens and means nothing to the caller.
local PRECISION = 4

-- API-dump type names that accept a plain Luau number.
local NUMERIC_TYPES: { [string]: boolean } = {
	int = true,
	int64 = true,
	float = true,
	double = true,
	number = true,
}

local function num(value: number): string
	local rounded = math.round(value * 10 ^ PRECISION) / 10 ^ PRECISION
	if rounded == math.floor(rounded) and math.abs(rounded) < 1e15 then
		return string.format("%d", rounded)
	end
	return tostring(rounded)
end

--[[
	Serializes one value. Unknown userdata falls back to `tostring`, which is
	always better than dropping the property silently.
]]
function Serialize.value(value: any): any
	local kind = typeof(value)

	if kind == "string" or kind == "boolean" or kind == "nil" then
		return value
	end
	if kind == "number" then
		-- JSON has no inf or nan, and HttpService:JSONEncode turns them into a
		-- `{"m":null,"t":"numeric","v":"inf"}` object nobody asked for. Written as
		-- text instead, in the same words `modify` accepts back.
		if value ~= value then
			return "nan"
		elseif value == math.huge then
			return "inf"
		elseif value == -math.huge then
			return "-inf"
		end
		-- Kept numeric so the agent can do arithmetic without parsing.
		return math.round(value * 10 ^ PRECISION) / 10 ^ PRECISION
	end
	if kind == "Vector3" then
		return string.format("%s, %s, %s", num(value.X), num(value.Y), num(value.Z))
	end
	if kind == "Vector2" then
		return string.format("%s, %s", num(value.X), num(value.Y))
	end
	if kind == "CFrame" then
		local position = value.Position
		local rx, ry, rz = value:ToOrientation()
		return string.format(
			"pos %s, %s, %s | rot %s, %s, %s",
			num(position.X),
			num(position.Y),
			num(position.Z),
			num(math.deg(rx)),
			num(math.deg(ry)),
			num(math.deg(rz))
		)
	end
	if kind == "Color3" then
		return string.format("%s, %s, %s", num(value.R), num(value.G), num(value.B))
	end
	if kind == "BrickColor" then
		return value.Name
	end
	if kind == "UDim2" then
		return string.format(
			"{%s, %s}, {%s, %s}",
			num(value.X.Scale),
			num(value.X.Offset),
			num(value.Y.Scale),
			num(value.Y.Offset)
		)
	end
	if kind == "UDim" then
		return string.format("{%s, %s}", num(value.Scale), num(value.Offset))
	end
	if kind == "Font" then
		--[[
			Written so it can be read back, which `tostring` is not.

			A Font stringifies as `Font { Family = rbxasset://..., Weight = Bold,
			Style = Normal }`, which nothing here can parse. The family, weight
			and style are all there is to one, so they are written plainly and
			separated the way a composite value is elsewhere in this module.
		]]
		return string.format(
			"%s | %s | %s",
			value.Family,
			value.Weight.Name,
			value.Style.Name
		)
	end
	if kind == "EnumItem" then
		return string.format("Enum.%s.%s", tostring(value.EnumType), value.Name)
	end
	if kind == "Content" then
		--[[
			Written as the bare URI so it can be read back.

			`tostring` on a Content gives `Content{SourceType=Uri,
			Uri=rbxassetid://123}`, which `parse` cannot take. A Content that
			holds an Object or no source at all has no URI to give, so those are
			named rather than rendered as an empty string that would read as
			"cleared".
		]]
		if value.Uri then
			return value.Uri
		end
		if value.Object then
			return Paths.of(value.Object)
		end
		return ""
	end
	if kind == "Instance" then
		--[[
			Formatted as an address, not as a display name.

			`GetFullName` writes "StarterPack.Pistol.Handle" for both of two
			Tools named Pistol, so reading a Motor6D's Part1 and writing it back
			pointed at the wrong one -- silently, since both paths resolve.
			`Paths.of` adds the [n] that tells them apart, which is what makes a
			value read here safe to write straight back.
		]]
		return Paths.of(value)
	end
	if kind == "NumberRange" then
		return string.format("%s..%s", num(value.Min), num(value.Max))
	end
	if kind == "Rect" then
		return string.format(
			"%s, %s, %s, %s",
			num(value.Min.X),
			num(value.Min.Y),
			num(value.Max.X),
			num(value.Max.Y)
		)
	end
	if kind == "ColorSequence" then
		local parts: { string } = {}
		for _, keypoint in value.Keypoints do
			table.insert(
				parts,
				string.format("%s=%s", num(keypoint.Time), Serialize.value(keypoint.Value))
			)
		end
		return table.concat(parts, " ")
	end
	if kind == "NumberSequence" then
		local parts: { string } = {}
		for _, keypoint in value.Keypoints do
			table.insert(parts, string.format("%s=%s", num(keypoint.Time), num(keypoint.Value)))
		end
		return table.concat(parts, " ")
	end
	if kind == "table" then
		local copy: { [any]: any } = {}
		for key, item in value :: { [any]: any } do
			copy[key] = Serialize.value(item)
		end
		return copy
	end

	return tostring(value)
end

--[[
	Reads a property without throwing.

	Property access on an instance can error even when the API dump says the
	property exists -- some are context-gated (only readable during a playtest,
	or only on a loaded asset). Returning nil for those keeps one awkward
	property from failing an inspect of 50 instances.
]]
function Serialize.readProperty(instance: Instance, name: string): (boolean, any)
	local ok, value = pcall(function()
		return (instance :: any)[name]
	end)
	if not ok then
		return false, nil
	end
	return true, Serialize.value(value)
end

--[[
	Pulls the numbers out of a composite value written as text.

	This used to be a single `-?%d+%.?%d*` scan, which is not the grammar Luau
	numbers actually have: "1e3, 0, .5" came back as 1, 3 and 0, so a Position
	written in scientific notation was silently set to a different point in the
	world and reported as applied. Splitting on the separators and handing each
	token to `tonumber` means this agrees with the scalar path, which always
	used `tonumber` -- the two disagreeing about what counts as a number was the
	whole bug.

	Non-numeric tokens are dropped, so "Vector3.new(1, 2, 3)" and "{1, 2, 3}"
	still read as three numbers.
]]
local function scanTokens(text: string): { number }
	local numbers: { number } = {}
	for token in string.gmatch(text, "[^,%s%(%)%[%]{}<>]+") do
		local value = tonumber(token)
		if value then
			table.insert(numbers, value)
		end
	end
	return numbers
end

--[[
	ColorSequence and NumberSequence.

	`Serialize.value` has always WRITTEN these -- "0=1, 0, 0 1=0, 0, 1" for a
	red-to-blue gradient -- and `parse` had no branch for either, so every one of
	them could be read and none could be written back. That is not a corner:
	ColorSequence and NumberSequence are what ParticleEmitter, Beam, Trail and
	UIGradient are made of, so recolouring any effect fell out of `modify`
	entirely and needed `execute_luau`. Found by auditing the round trip rather
	than by hitting it.

	Keypoints are split on the "<time>=" markers rather than on whitespace,
	because the VALUE of a ColorSequence keypoint contains both commas and
	spaces of its own and nothing else can tell the two apart.

	A bare value is also accepted and means a constant sequence: `Color3` text
	for a ColorSequence, one number for a NumberSequence. People write
	`Color = "1, 0, 0"` meaning solid red, and refusing that to insist on
	"0=1, 0, 0 1=1, 0, 0" would be pedantry.
]]
local function splitKeypoints(text: string): { { time: number, value: string } }
	local marks: { { at: number, finish: number, time: number } } = {}
	local index = 1
	while true do
		local at, finish, captured = string.find(text, "([%d%.]+)%s*=", index)
		if not at then
			break
		end
		local time = tonumber(captured)
		if time then
			table.insert(marks, { at = at, finish = finish, time = time })
		end
		index = finish + 1
	end

	local out: { { time: number, value: string } } = {}
	for position, mark in marks do
		local stop = if marks[position + 1] then marks[position + 1].at - 1 else #text
		local value = string.match(string.sub(text, mark.finish + 1, stop), "^%s*(.-)%s*$") or ""
		table.insert(out, { time = mark.time, value = value })
	end
	return out
end


--[[
	Parses a serialized string back into a Roblox value, given the target type
	from the API dump. Returns ok=false with a reason the agent can act on
	rather than raising, so batch writes can report per-property failures.
]]
function Serialize.parse(text: any, valueType: string): (boolean, any, string?)
	local kind = typeof(text)

	-- Values already of the right primitive shape pass straight through. The
	-- number case is matched against the target type rather than excluded from
	-- one: a bare 5 is a valid `float`, but not a valid Vector3, Enum or Color3.
	if kind == "boolean" then
		return true, text, nil
	end
	if kind == "number" and NUMERIC_TYPES[valueType] then
		return true, text, nil
	end

	if valueType == "string" or valueType == "ProtectedString" then
		return true, tostring(text), nil
	end

	--[[
		Asset references come in two shapes with almost the same name.

		`ContentId` is the old one and is still just a string: `MeshPart.MeshId`,
		`Decal.Texture`, `SurfaceAppearance.ColorMap`. It had no branch here at
		all, so every one of them failed with `no conversion known for type
		"ContentId"` -- which is how a SurfaceAppearance could be created but
		never given a texture.

		`Content` is the new datatype and is NOT a string. Assigning
		`"rbxassetid://123"` to `AudioPlayer.AudioContent` or
		`ImageLabel.ImageContent` throws; it wants `Content.fromUri`. This branch
		used to lump it in with `string` above, so those writes reported a parse
		success and then failed at assignment with a message about a type the
		caller never mentioned.

		An empty string means "nothing", the same as it does for an instance
		reference: `Content.none` is the engine's own name for that.
	]]
	if valueType == "ContentId" then
		return true, tostring(text), nil
	end
	if valueType == "Content" then
		if typeof(text) == "Content" then
			return true, text, nil
		end
		local uri = tostring(text)
		if uri == "" then
			return true, Content.none, nil
		end
		local okContent, content = pcall(function()
			return Content.fromUri(uri)
		end)
		if okContent then
			return true, content, nil
		end
		return false, nil, string.format('"%s" is not a content URI', uri)
	end
	if valueType == "bool" then
		if kind == "boolean" then
			return true, text, nil
		end
		if kind == "number" then
			return true, text ~= 0, nil
		end
		-- This used to be `text == "true"`, which quietly turned "True", "TRUE"
		-- and "1" into false and reported the write as applied. A bool that is
		-- silently the opposite of what was asked is the worst failure this
		-- module can produce, so near misses are accepted and anything else is
		-- refused rather than guessed at.
		local lowered = string.lower(tostring(text))
		if lowered == "true" or lowered == "1" or lowered == "yes" then
			return true, true, nil
		end
		if lowered == "false" or lowered == "0" or lowered == "no" then
			return true, false, nil
		end
		return false, nil, string.format('expected true or false, got "%s"', tostring(text))
	end
	if NUMERIC_TYPES[valueType] then
		local parsed = tonumber(text)
		if not parsed then
			return false, nil, string.format('expected a number, got "%s"', tostring(text))
		end
		return true, parsed, nil
	end

	local numbers: { number } = {}
	if kind == "string" then
		for _, token in scanTokens(text) do
			table.insert(numbers, token)
		end
	elseif kind == "table" then
		for _, item in text :: { any } do
			local parsed = tonumber(item)
			if parsed then
				table.insert(numbers, parsed)
			end
		end
	end

	if valueType == "Vector3" then
		if #numbers < 3 then
			return false, nil, 'expected three numbers, e.g. "12, 0, 5"'
		end
		return true, Vector3.new(numbers[1], numbers[2], numbers[3]), nil
	end
	if valueType == "Vector2" then
		if #numbers < 2 then
			return false, nil, 'expected two numbers, e.g. "12, 5"'
		end
		return true, Vector2.new(numbers[1], numbers[2]), nil
	end
	if valueType == "Color3" then
		-- "#FF8800", the way colours are usually written everywhere else.
		local hex = if kind == "string" then string.match(text, "^%s*#(%x%x%x%x%x%x)%s*$") else nil
		if hex then
			return true, Color3.fromHex(hex), nil
		end
		if #numbers < 3 then
			return false, nil, 'expected three 0-1 components, e.g. "1, 0.5, 0"'
		end
		-- 0-255 is a common mistake and unambiguous to detect, so accept it.
		local scale = if numbers[1] > 1 or numbers[2] > 1 or numbers[3] > 1 then 255 else 1
		return true, Color3.new(numbers[1] / scale, numbers[2] / scale, numbers[3] / scale), nil
	end
	if valueType == "BrickColor" then
		-- Cast because the API definitions type this overload as a literal union
		-- of every BrickColor name. At runtime it takes any string and throws on
		-- an unknown one, which is exactly what the pcall is here to catch.
		local ok, color = pcall(function()
			return BrickColor.new(tostring(text) :: any)
		end)
		if not ok then
			return false, nil, string.format('"%s" is not a BrickColor name', tostring(text))
		end
		return true, color, nil
	end
	if valueType == "UDim2" then
		if #numbers < 4 then
			return false, nil, 'expected four numbers, e.g. "{0.5, 10}, {0.5, 20}"'
		end
		return true, UDim2.new(numbers[1], numbers[2], numbers[3], numbers[4]), nil
	end
	if valueType == "UDim" then
		if #numbers < 2 then
			return false, nil, 'expected two numbers, e.g. "{0.5, 10}"'
		end
		return true, UDim.new(numbers[1], numbers[2]), nil
	end
	if valueType == "CFrame" then
		-- Twelve numbers are a full matrix -- what `tostring(cframe)` prints. Read
		-- as "position | rotation" they gave a silently wrong orientation.
		if #numbers == 12 then
			return true,
				CFrame.new(
					numbers[1], numbers[2], numbers[3],
					numbers[4], numbers[5], numbers[6],
					numbers[7], numbers[8], numbers[9],
					numbers[10], numbers[11], numbers[12]
				),
				nil
		end
		if #numbers >= 6 then
			return true,
				CFrame.new(numbers[1], numbers[2], numbers[3])
					* CFrame.fromOrientation(
						math.rad(numbers[4]),
						math.rad(numbers[5]),
						math.rad(numbers[6])
					),
				nil
		end
		if #numbers >= 3 then
			return true, CFrame.new(numbers[1], numbers[2], numbers[3]), nil
		end
		return false, nil, 'expected "pos x, y, z" or "pos x, y, z | rot rx, ry, rz"'
	end
	--[[
		NumberRange, which the shared tokenizer cannot see.

		`Serialize.value` writes one as "1..3", but `scanTokens` splits on
		commas, whitespace and brackets -- never on "..", so "1..3" arrives as a
		single token, `tonumber` returns nil, and the parse failed with `expected
		"min..max"` while being handed exactly that. A value this module printed
		could not be fed back to it, which is the one promise the whole file
		makes. Caught in QA on ParticleEmitter.Lifetime.

		Parsed here directly. A single number is accepted too, because
		`NumberRange.new(2)` is a real range and people write it that way.
	]]
	if valueType == "ColorSequence" then
		if kind ~= "string" then
			return false, nil, "expected text like \"0=1, 0, 0 1=0, 0, 1\""
		end
		local points = splitKeypoints(text)
		if #points == 0 then
			-- A bare colour: a sequence that is that colour the whole way.
			local okColour, colour = Serialize.parse(text, "Color3")
			if okColour and typeof(colour) == "Color3" then
				return true, ColorSequence.new(colour :: Color3), nil
			end
			return false, nil, "expected \"0=1, 0, 0 1=0, 0, 1\", or one colour for a solid sequence"
		end

		local keypoints: { ColorSequenceKeypoint } = {}
		for _, point in points do
			local okColour, colour = Serialize.parse(point.value, "Color3")
			if not okColour or typeof(colour) ~= "Color3" then
				return false, nil, string.format("keypoint at %s is not a colour: %q", tostring(point.time), point.value)
			end
			table.insert(keypoints, ColorSequenceKeypoint.new(point.time, colour :: Color3))
		end
		-- Roblox requires the first keypoint at 0 and the last at 1, in order, and
		-- throws an unhelpful error otherwise.
		table.sort(keypoints, function(a, b)
			return a.Time < b.Time
		end)
		if keypoints[1].Time ~= 0 or keypoints[#keypoints].Time ~= 1 then
			return false,
				nil,
				"a ColorSequence must start at time 0 and end at time 1"
		end
		local okBuild, built = pcall(ColorSequence.new, keypoints)
		if not okBuild then
			return false, nil, tostring(built)
		end
		return true, built, nil
	end

	if valueType == "NumberSequence" then
		if kind == "number" then
			return true, NumberSequence.new(text), nil
		end
		if kind ~= "string" then
			return false, nil, "expected text like \"0=0 1=1\""
		end
		local points = splitKeypoints(text)
		if #points == 0 then
			local single = tonumber(text)
			if single then
				return true, NumberSequence.new(single), nil
			end
			return false, nil, "expected \"0=0 1=1\", or one number for a flat sequence"
		end

		local keypoints: { NumberSequenceKeypoint } = {}
		for _, point in points do
			local value = tonumber(point.value)
			if not value then
				return false, nil, string.format("keypoint at %s is not a number: %q", tostring(point.time), point.value)
			end
			table.insert(keypoints, NumberSequenceKeypoint.new(point.time, value))
		end
		table.sort(keypoints, function(a, b)
			return a.Time < b.Time
		end)
		if keypoints[1].Time ~= 0 or keypoints[#keypoints].Time ~= 1 then
			return false, nil, "a NumberSequence must start at time 0 and end at time 1"
		end
		local okBuild, built = pcall(NumberSequence.new, keypoints)
		if not okBuild then
			return false, nil, tostring(built)
		end
		return true, built, nil
	end

	--[[
		Rect, which `Serialize.value` writes and `parse` did not read.

		The last of the write-but-cannot-read set, after NumberRange and the two
		sequences. Offered in the attribute type list too, so `rect` attributes
		were advertised and refused in the same breath. Four numbers, in the
		order the writer emits them: min X, min Y, max X, max Y.
	]]
	if valueType == "Rect" then
		if #numbers < 4 then
			return false, nil, 'expected "minX, minY, maxX, maxY"'
		end
		return true, Rect.new(numbers[1], numbers[2], numbers[3], numbers[4]), nil
	end

	if valueType == "NumberRange" then
		if kind == "string" then
			local low, high = string.match(text, "^%s*(-?[%d%.]+)%s*%.%.%s*(-?[%d%.]+)%s*$")
			if low and high and tonumber(low) and tonumber(high) then
				return true, NumberRange.new(tonumber(low) :: number, tonumber(high) :: number), nil
			end
		end
		if #numbers >= 2 then
			return true, NumberRange.new(numbers[1], numbers[2]), nil
		end
		if #numbers == 1 then
			return true, NumberRange.new(numbers[1]), nil
		end
		return false, nil, 'expected "min..max", e.g. "1..3"'
	end

	--[[
		PhysicalProperties, which is neither a vector nor an enum.

		Written as the Properties panel writes it: density, friction,
		elasticity, and optionally the two weights. Handled here because it is a
		real property on every BasePart and the fall-through below cannot take
		it -- see the note on the Enum lookup.
	]]
	if valueType == "PhysicalProperties" then
		if #numbers >= 5 then
			return true, PhysicalProperties.new(numbers[1], numbers[2], numbers[3], numbers[4], numbers[5]), nil
		end
		if #numbers >= 3 then
			return true, PhysicalProperties.new(numbers[1], numbers[2], numbers[3]), nil
		end
		return false, nil, 'expected "density, friction, elasticity" and optionally two weights'
	end

	--[[
		Fonts, which look like an enum and are not one.

		`TextLabel.FontFace` holds a `Font`, while `Enum.Font` is a separate
		thing that happens to share its names. The fall-through below found
		`Enum.Font` first and returned an EnumItem, so every attempt to set
		FontFace failed with "Font expected, got EnumItem" -- measured while
		building an ordinary shop panel, where it stopped the whole batch. This
		has to come first for that reason.

		Three spellings are accepted, because all three are what someone
		actually has to hand: the familiar enum name ("GothamBold"), a family
		asset id, and a family with a weight and style after it -- the form this
		module writes when it reads a Font back.
	]]
	if valueType == "Font" then
		local written = tostring(text)
		local pieces: { string } = {}
		for piece in string.gmatch(written, "[^|]+") do
			table.insert(pieces, (string.gsub(piece, "^%s*(.-)%s*$", "%1")))
		end

		local family = if #pieces > 0 then pieces[1] else written
		local weight = Enum.FontWeight.Regular
		local style = Enum.FontStyle.Normal
		if #pieces >= 2 then
			local okWeight, found = pcall(function()
				return (Enum.FontWeight :: any)[pieces[2]]
			end)
			if okWeight and found then
				weight = found
			end
		end
		if #pieces >= 3 and pieces[3] == "Italic" then
			style = Enum.FontStyle.Italic
		end

		-- The enum spelling first: "GothamBold" carries its weight in the name,
		-- and `fromEnum` knows the pairing better than any table here would.
		if #pieces == 1 then
			local name = family:match("([^%.]+)$") or family
			for _, item in Enum.Font:GetEnumItems() do
				if item.Name == name and item ~= Enum.Font.Unknown then
					local okEnumFont, font = pcall(function()
						return Font.fromEnum(item)
					end)
					if okEnumFont then
						return true, font, nil
					end
				end
			end
		end

		if string.sub(family, 1, 9) == "rbxasset:" or string.sub(family, 1, 12) == "rbxassetid:" then
			return true, Font.new(family, weight, style), nil
		end

		local okName, font = pcall(function()
			return Font.fromName(family, weight, style)
		end)
		if okName and font then
			return true, font, nil
		end

		return false,
			nil,
			string.format(
				'"%s" is not a font. Use an Enum.Font name like "GothamBold", a family '
					.. 'name like "Gotham", or "family | Weight | Style".',
				written
			)
	end

	--[[
		Enum values arrive as "Enum.Material.Plastic" or bare "Plastic".

		Indexed inside a pcall, because `Enum` throws on an unknown name rather
		than returning nil. Every value type this function does not handle ends
		up here, so an unguarded lookup turned "no conversion known for type X"
		-- a clear message naming the property -- into a raw HANDLER_ERROR
		reading "PhysicalProperties is not a valid member of Enum", which names
		the wrong thing entirely. Measured on a `modify` setting
		CustomPhysicalProperties.
	]]
	local okEnum, enumType = pcall(function()
		return (Enum :: any)[valueType]
	end)
	if okEnum and enumType then
		local name = tostring(text):match("([^%.]+)$") or tostring(text)
		for _, item in enumType:GetEnumItems() do
			if item.Name == name then
				return true, item, nil
			end
		end
		return false,
			nil,
			string.format('"%s" is not a member of Enum.%s', tostring(text), valueType)
	end

	--[[
		Instance references, written as the path of the thing pointed at.

		Motor6D.Part0, WeldConstraint.Part1, ObjectValue.Value, Beam.Attachment0,
		Model.PrimaryPart, BillboardGui.Adornee -- every one of these holds
		another instance, and none of them could be set at all before this. That
		is not a corner: a Motor6D with no Part0 joins nothing, so building a rig
		or welding a gun to a hand fell out of `create` entirely and had to go
		through `execute_luau`. Measured on a six-joint R6 rig, which failed with
		"no conversion known for type BasePart".

		Written the same way every reference is READ -- `Serialize.value` returns
		`GetFullName()` for an instance -- so a value read here can be written
		straight back, which is the promise the rest of this module makes.

		The class is checked against the property's own type, because the engine
		accepts the assignment and then quietly does nothing useful with a Part0
		pointing at a Folder. An empty string clears the reference, which is the
		only way to say "nothing" in a field that otherwise takes a path.
	]]
	if kind == "string" then
		local wanted = tostring(text)
		if wanted == "" then
			return true, nil, nil
		end
		local okPath, resolved = pcall(Paths.resolve, wanted)
		if okPath and typeof(resolved) == "Instance" then
			local instance = resolved :: Instance
			if instance:IsA(valueType) then
				return true, instance, nil
			end
			return false,
				nil,
				string.format(
					"%s is a %s, but this property holds a %s",
					wanted,
					instance.ClassName,
					valueType
				)
		end

		--[[
			The path did not resolve, and saying so is the whole point.

			This used to fall through to the "no conversion known for type X"
			line below, which blames the TYPE for what is really a missing
			instance: setting `HingeConstraint.Attachment0` to a path that did
			not exist yet reported `no conversion known for type "Attachment"`,
			sending the reader to look for a serializer that was never the
			problem. Measured while building a hinge in one `create` call.
		]]
		--[[
			Only text that actually looks like a path is reported as a missing
			instance -- and only that text is worth retrying later.

			Without this check every unparseable string took this branch: a
			ColorSequence written as "0=1, 0, 0" came back as `nothing at
			"0=1, 0, 0"`, which names the wrong problem entirely and sends the
			create handler off to retry something no amount of waiting will fix.

			The test is whether the first segment names something real at the
			root of the data model. "Workspace.Nowhere" passes it -- Workspace
			exists, the rest does not, which is exactly the retryable case --
			while "0.5" and "0=1, 0, 0" do not.
		]]
		local head = string.match(wanted, "^([%a_][%w_]*)%.") or string.match(wanted, "^([%a_][%w_]*)$")
		local looksLikePath = head ~= nil and pcall(function()
			return game:FindFirstChild(head :: string) ~= nil or game:GetService(head :: any) ~= nil
		end)
		if looksLikePath then
			return false,
				nil,
				string.format('%snothing at "%s" (this property holds a %s)', UNRESOLVED_PREFIX, wanted, valueType)
		end
	end

	return false, nil, string.format('no conversion known for type "%s"', valueType)
end

return Serialize
