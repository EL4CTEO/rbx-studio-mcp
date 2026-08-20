--!strict
--[[
	Builds the place the evaluation questions are asked about.

	Every other MCP server's eval suite can point at a fixed dataset -- a repo, a
	wiki, an API with stable records. This one drives whatever place the user
	happens to have open, so there is no stable dataset unless the suite brings
	its own. Hence a fixture: run this once and the answers in
	`roblox-studio.xml` are true, in any place, on any machine.

	It is idempotent. Running it again destroys what it built and rebuilds it,
	so a half-finished run or a place someone poked at by hand costs nothing.

	Everything lives under one folder in ReplicatedStorage, so removing it is a
	single delete and it never collides with the user's own work. Nothing here
	is meant to run: the scripts are disabled and exist to be read and searched.

	Run it with `execute_luau`, or paste it into the command bar.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")

local ROOT_NAME = "MCPEvalFixture"

local existing = ReplicatedStorage:FindFirstChild(ROOT_NAME)
if existing then
	existing:Destroy()
end

local root = Instance.new("Folder")
root.Name = ROOT_NAME
root:SetAttribute("FixtureVersion", 1)

--[[
	Hazards. Deliberately mixed: same class, same name stem, differing in the
	one property a question asks about, so answering means filtering rather than
	counting children. Three of the seven are unanchored.
]]
local hazards = Instance.new("Folder")
hazards.Name = "Hazards"
hazards.Parent = root

local HAZARDS = {
	{ name = "SpikeTrap", anchored = true, damage = 25, material = Enum.Material.Metal },
	{ name = "SpikeTrap", anchored = true, damage = 40, material = Enum.Material.Metal },
	{ name = "SpikeTrap", anchored = false, damage = 10, material = Enum.Material.Wood },
	{ name = "FirePit", anchored = true, damage = 55, material = Enum.Material.Neon },
	{ name = "FirePit", anchored = false, damage = 15, material = Enum.Material.Neon },
	{ name = "CrusherBlock", anchored = true, damage = 90, material = Enum.Material.Slate },
	{ name = "CrusherBlock", anchored = false, damage = 5, material = Enum.Material.Slate },
}

for index, spec in HAZARDS do
	local part = Instance.new("Part")
	part.Name = spec.name
	part.Anchored = spec.anchored
	part.Material = spec.material
	part.Size = Vector3.new(4, 1, 4)
	part.Position = Vector3.new(index * 8, 0, 0)
	part:SetAttribute("Damage", spec.damage)
	CollectionService:AddTag(part, "EvalHazard")
	part.Parent = hazards
end

--[[
	Rooms, nested two deep, so questions about structure need `tree` or a
	recursive `find` rather than one listing of children.
]]
local rooms = Instance.new("Folder")
rooms.Name = "Rooms"
rooms.Parent = root

local ROOMS = {
	{ name = "Atrium", lights = 4 },
	{ name = "Cellar", lights = 1 },
	{ name = "Gallery", lights = 6 },
}

for _, spec in ROOMS do
	local room = Instance.new("Model")
	room.Name = spec.name
	room.Parent = rooms

	local floor = Instance.new("Part")
	floor.Name = "Floor"
	floor.Anchored = true
	floor.Size = Vector3.new(20, 1, 20)
	floor.Parent = room

	for light = 1, spec.lights do
		local lamp = Instance.new("Part")
		lamp.Name = "Lamp"
		lamp.Anchored = true
		lamp.Material = Enum.Material.Neon
		lamp.Size = Vector3.new(1, 1, 1)
		lamp.Position = Vector3.new(light * 2, 5, 0)
		lamp.Parent = room
	end
end

--[[
	Code to read and search. Disabled, because a fixture that starts running
	game logic in someone's place is a fixture nobody installs twice.

	The numbers here are the answers to several questions, and they are
	deliberately not round, so a model that guesses plausibly still gets them
	wrong.
]]
local balance = Instance.new("ModuleScript")
balance.Name = "Balance"
balance.Source = table.concat({
	"--!strict",
	"-- Tuning values for the eval fixture. Read by EvalPatrol.",
	"local Balance = {}",
	"",
	"Balance.BASE_HEALTH = 137",
	"Balance.REGEN_PER_SECOND = 2.5",
	"Balance.SPRINT_MULTIPLIER = 1.65",
	"Balance.MAX_CARRY_WEIGHT = 84",
	"",
	"function Balance.effectiveHealth(level: number): number",
	"\treturn Balance.BASE_HEALTH + level * 9",
	"end",
	"",
	"function Balance.canCarry(weight: number): boolean",
	"\treturn weight <= Balance.MAX_CARRY_WEIGHT",
	"end",
	"",
	"return Balance",
}, "\n")
balance.Parent = root

local patrol = Instance.new("Script")
patrol.Name = "EvalPatrol"
patrol.Disabled = true
patrol.Source = table.concat({
	"--!strict",
	"-- Disabled on purpose: the fixture is read, not run.",
	'local Balance = require(script.Parent.Balance)',
	"",
	"local WAYPOINT_COUNT = 12",
	"local PAUSE_SECONDS = 0.75",
	"",
	"local function patrolRoute(index: number): number",
	"\treturn (index % WAYPOINT_COUNT) + 1",
	"end",
	"",
	"local function onDamaged(current: number, amount: number): number",
	"\tlocal remaining = current - amount",
	"\tif remaining <= 0 then",
	"\t\treturn 0",
	"\tend",
	"\treturn remaining",
	"end",
	"",
	"return {",
	"\tpatrolRoute = patrolRoute,",
	"\tonDamaged = onDamaged,",
	"\tstartingHealth = Balance.BASE_HEALTH,",
	"}",
}, "\n")
patrol.Parent = root

local ui = Instance.new("LocalScript")
ui.Name = "EvalHud"
ui.Disabled = true
ui.Source = table.concat({
	"--!strict",
	"-- Disabled on purpose: the fixture is read, not run.",
	"local REFRESH_HZ = 30",
	"local function format(value: number): string",
	'\treturn string.format("%d%%", math.floor(value))',
	"end",
	"return { REFRESH_HZ = REFRESH_HZ, format = format }",
}, "\n")
ui.Parent = root

root.Parent = ReplicatedStorage

return {
	root = root:GetFullName(),
	descendants = #root:GetDescendants(),
}
