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

	if valueType == "string" or valueType == "Content" or valueType == "ProtectedString" then
		return true, tostring(text), nil
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
	if valueType == "NumberRange" then
		if #numbers < 2 then
			return false, nil, 'expected "min..max"'
		end
		return true, NumberRange.new(numbers[1], numbers[2]), nil
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
	end

	return false, nil, string.format('no conversion known for type "%s"', valueType)
end

return Serialize
