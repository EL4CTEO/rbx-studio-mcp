--!strict
--[[
	The panel's themes: a colour set and the animated background that goes
	with it. One is active at a time; `Console.applyTheme` repaints the panel
	when it changes, and the choice is saved by init.server.
]]

export type Palette = {
	background: Color3,
	surface: Color3,
	rule: Color3,
	text: Color3,
	dim: Color3,
	green: Color3,
	red: Color3,
	amber: Color3,
	cyan: Color3,
	violet: Color3,
}

export type Theme = {
	id: string,
	label: string,
	-- One line for the picker.
	blurb: string,
	palette: Palette,
	-- The far end of the background gradient, and the input boxes' fill.
	deep: Color3,
	-- Which animated background it uses; see Backdrop.
	backdrop: string,
	-- The colour its dot in the header shows.
	accent: Color3,
}

local rgb = Color3.fromRGB

local function freeze(theme: Theme): Theme
	table.freeze(theme.palette)
	return table.freeze(theme) :: any
end

local THEMES: { Theme } = {
	freeze({
		id = "nebula",
		label = "Nebula",
		blurb = "navy, light-blue lines, a drifting constellation",
		backdrop = "constellation",
		accent = rgb(124, 196, 255),
		deep = rgb(6, 23, 51),
		palette = {
			background = rgb(18, 59, 122),
			surface = rgb(6, 23, 51),
			rule = rgb(120, 190, 255),
			text = rgb(232, 241, 255),
			dim = rgb(150, 176, 214),
			green = rgb(95, 227, 161),
			red = rgb(255, 125, 140),
			amber = rgb(251, 191, 36),
			cyan = rgb(124, 196, 255),
			violet = rgb(185, 162, 255),
		},
	}),
	freeze({
		id = "ember",
		label = "Ember",
		blurb = "charcoal and deep red, sparks rising",
		backdrop = "embers",
		accent = rgb(255, 140, 66),
		deep = rgb(14, 9, 9),
		palette = {
			background = rgb(58, 22, 18),
			surface = rgb(20, 12, 11),
			rule = rgb(255, 140, 66),
			text = rgb(250, 236, 228),
			dim = rgb(196, 160, 146),
			green = rgb(140, 220, 130),
			red = rgb(255, 98, 98),
			amber = rgb(255, 196, 92),
			cyan = rgb(255, 170, 110),
			violet = rgb(240, 150, 190),
		},
	}),
	freeze({
		id = "tide",
		label = "Tide",
		blurb = "deep teal, slow rolling waves",
		backdrop = "waves",
		accent = rgb(70, 220, 190),
		deep = rgb(3, 24, 28),
		palette = {
			background = rgb(10, 66, 72),
			surface = rgb(4, 28, 32),
			rule = rgb(90, 220, 200),
			text = rgb(226, 248, 244),
			dim = rgb(142, 190, 184),
			green = rgb(110, 236, 170),
			red = rgb(255, 128, 128),
			amber = rgb(250, 204, 92),
			cyan = rgb(110, 226, 236),
			violet = rgb(170, 176, 255),
		},
	}),
	freeze({
		id = "galaxy",
		label = "Galaxy",
		blurb = "deep indigo, a turning spiral under an analysis overlay",
		backdrop = "galaxy",
		accent = rgb(110, 200, 255),
		deep = rgb(4, 6, 20),
		palette = {
			background = rgb(18, 26, 70),
			surface = rgb(7, 10, 28),
			rule = rgb(110, 200, 255),
			text = rgb(230, 240, 255),
			dim = rgb(140, 160, 205),
			green = rgb(120, 240, 200),
			red = rgb(255, 110, 140),
			amber = rgb(255, 214, 130),
			cyan = rgb(110, 210, 255),
			violet = rgb(180, 160, 255),
		},
	}),
	freeze({
		id = "aurora",
		label = "Aurora",
		blurb = "midnight purple under a curtain of northern lights",
		backdrop = "aurora",
		accent = rgb(150, 255, 200),
		deep = rgb(9, 6, 24),
		palette = {
			background = rgb(34, 20, 72),
			surface = rgb(12, 8, 30),
			rule = rgb(170, 150, 255),
			text = rgb(240, 236, 255),
			dim = rgb(170, 160, 210),
			green = rgb(130, 250, 190),
			red = rgb(255, 120, 150),
			amber = rgb(255, 210, 120),
			cyan = rgb(120, 220, 255),
			violet = rgb(200, 160, 255),
		},
	}),
	freeze({
		id = "monolith",
		label = "Monolith",
		blurb = "greyscale slabs, drifting dust, a passing beam",
		backdrop = "sweep",
		accent = rgb(200, 200, 200),
		deep = rgb(10, 10, 11),
		palette = {
			background = rgb(34, 34, 36),
			surface = rgb(16, 16, 17),
			rule = rgb(190, 190, 194),
			text = rgb(238, 238, 240),
			dim = rgb(150, 150, 156),
			green = rgb(200, 200, 204),
			red = rgb(255, 120, 120),
			amber = rgb(220, 220, 220),
			cyan = rgb(210, 210, 214),
			violet = rgb(176, 176, 182),
		},
	}),
}

local byId: { [string]: Theme } = {}
for _, theme in THEMES do
	byId[theme.id] = theme
end
-- Galaxy replaced Circuit; a saved "circuit" lands on it.
byId.circuit = byId.galaxy

local active: Theme = THEMES[1]

local Palette = {}

-- Interface type; the log's timestamps and durations stay monospaced.
Palette.FONT = Enum.Font.BuilderSans
Palette.FONT_MEDIUM = Enum.Font.BuilderSansMedium
Palette.FONT_BOLD = Enum.Font.BuilderSansBold

function Palette.get(): Palette
	return active.palette
end

function Palette.deep(): Color3
	return active.deep
end

function Palette.theme(): Theme
	return active
end

function Palette.list(): { Theme }
	return THEMES
end

function Palette.find(id: string): Theme?
	return byId[string.lower(id)]
end

-- Makes `id` the active theme. False when it is unknown or already active.
function Palette.use(id: string): boolean
	local theme = byId[string.lower(id)]
	if theme == nil or theme == active then
		return false
	end
	active = theme
	return true
end

return Palette
