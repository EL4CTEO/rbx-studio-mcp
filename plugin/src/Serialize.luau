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
	if kind == "EnumItem" then
		return string.format("Enum.%s.%s", tostring(value.EnumType), value.Name)
	end
	if kind == "Instance" then
		return value:GetFullName()
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

	-- Enum values arrive as "Enum.Material.Plastic" or bare "Plastic".
	local enumType = (Enum :: any)[valueType]
	if enumType then
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

	return false, nil, string.format('no conversion known for type "%s"', valueType)
end

return Serialize
