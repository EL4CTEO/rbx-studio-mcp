--!strict
--[[
	The preset registry: which themes exist, which is active, and who to tell
	when that changes.

	Deliberately dumb. It holds no drawing code and no Instances -- it maps ids
	to modules, remembers one id, and fires listeners. Everything visual lives
	in the preset modules and everything stateful lives in Visuals, so this file
	is the one place you can look to answer "what themes are there" without
	reading eight renderers.

	Persistence is not done here either. `plugin` is a script-level global that
	ModuleScripts do not get, so init.server.luau reads the stored id at startup
	and writes it back from `onChanged`. That keeps the only Studio-specific
	dependency in the one file that already has it.
]]

local Theme = require(script.Theme)

local Themes = {}

export type Theme = Theme.Theme
export type Palette = Theme.Palette
export type Context = Theme.Context
export type Slot = Theme.Slot

--[[
	Presentation order in the picker, which is not alphabetical.

	Lattice first because it is the default and the one people return to. Then
	the two dark presets closest to it, then the colourful ones, then the two
	that abandon the aesthetic entirely. A user scanning the drawer should be
	able to stop as soon as the list stops looking like what they came for.
]]
local ORDER: { Theme.Theme } = {
	require(script.Lattice),
	require(script.Observatory),
	require(script.Orbit),
	require(script.Void),
	require(script.Nebula),
	require(script.Aurora),
	require(script.Phosphor),
	require(script.Blueprint),
}

local byId: { [string]: Theme.Theme } = {}
for _, theme in ORDER do
	byId[theme.id] = theme
end

local DEFAULT = "lattice"
local activeId = DEFAULT
local listeners: { (Theme.Theme) -> () } = {}

function Themes.list(): { Theme.Theme }
	return ORDER
end

--[[
	Looks up a preset, falling back to the default rather than erroring.

	The id can come from a saved setting written by an older or newer build, so
	an unknown one is expected rather than exceptional -- and a console that
	refuses to start because a theme was renamed would be a bad trade for a
	cosmetic feature.
]]
function Themes.get(id: string?): Theme.Theme
	if id ~= nil then
		local found = byId[id]
		if found ~= nil then
			return found
		end
	end
	return byId[DEFAULT]
end

function Themes.active(): Theme.Theme
	return Themes.get(activeId)
end

function Themes.palette(): Theme.Palette
	return Themes.active().palette
end

function Themes.activeId(): string
	return activeId
end

--[[
	Switches presets and tells everyone who cares.

	Returns whether anything changed, so a caller re-selecting the current theme
	does not pay for a full remount and a repaint of the log.
]]
function Themes.use(id: string): boolean
	local theme = Themes.get(id)
	if theme.id == activeId then
		return false
	end
	activeId = theme.id
	for _, listener in listeners do
		listener(theme)
	end
	return true
end

--[[
	Registers a listener. There is no unsubscribe: every listener here lives as
	long as the plugin does, and an unsubscribe nobody calls is a function that
	rots rather than one that helps.
]]
function Themes.onChanged(listener: (Theme.Theme) -> ())
	table.insert(listeners, listener)
end

return Themes
