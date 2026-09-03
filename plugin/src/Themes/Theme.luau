--!strict
--[[
	The contract every preset satisfies.

	A theme owns two surfaces and nothing else. `cell` is the square at the left
	of the activity band -- the slot the wireframe prism occupies under the
	default theme, and which any other theme is free to fill with something that
	is not a prism at all. `slots` are the forty most recent calls, drawn as bars
	under the default theme and as anything else under the rest.

	What a theme deliberately does NOT own is the simulation. Energy, activity,
	flare, shake, the scale spring and the quiet timer are computed once in
	Visuals and handed to whichever preset is active. That is the whole reason
	eight presets do not mean eight animation systems: they are eight painters
	over one set of physics, so a preset is a few hundred lines of drawing and
	holds no state that could drift out of step with the session.
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

--[[
	The session, as numbers a painter can use.

	Everything here decays on its own, so a painter never has to schedule
	anything: read the value, draw that frame, and the motion follows.

	`energy` rises with each command and falls over about a second -- use it for
	anything that should react. `activity` is the slower average, over roughly
	ten seconds, and is what should drive how BUSY a scene looks rather than how
	startled. `flare` spikes to 1 the instant a reply lands and is gone in a
	third of a second, which is what makes a completed call read as an event.
	`shake` is the same but only for failures. `quiet` is seconds since anything
	ran; past `QUIET_AFTER` the session has stopped rather than paused, and a
	scene that keeps working at full pace after that is claiming an activity
	which is not happening.
]]
export type Context = {
	palette: Palette,
	-- Connection state blended toward the kind of work last done.
	tint: Color3,
	energy: number,
	activity: number,
	flare: number,
	shake: number,
	-- The scale spring: 1 at rest, overshoots past 1 on a reply, 0.82 when idle.
	scale: number,
	quiet: number,
	-- Accumulated rotation on three axes. Meaningful to anything that turns;
	-- ignorable by anything that does not.
	angle: Vector3,
	-- `os.clock()`, sampled once per frame so every painter agrees on the time.
	clock: number,
	-- The cell is square; this is its side in pixels.
	size: number,
	centre: Vector2,
}

--[[
	One finished call, as history rather than as an event.

	`age` is 0 for the newest and rises toward 1 for the oldest still on screen,
	which is what lets a preset fade its history out without tracking when
	anything happened. `frame` is pooled and reused as bars shift left, so a
	painter must set every property it cares about rather than assuming the
	frame arrives clean.
]]
export type Slot = {
	frame: Frame,
	milliseconds: number,
	ok: boolean,
	title: string,
	age: number,
	-- Duration against the "slow" reference, clamped to 1. Height, for a bar.
	weight: number,
}

export type Theme = {
	id: string,
	label: string,
	-- One line, shown under the label in the picker.
	blurb: string,
	palette: Palette,
	--[[
		Builds whatever the cell needs, once. Pooled Instances belong here:
		allocating inside `paint` is how a decorative strip becomes a performance
		complaint.
	]]
	mount: (cell: Frame) -> (),
	paint: (ctx: Context, delta: number) -> (),
	--[[
		Destroys what `mount` built. Called on every theme switch, so it must
		leave the cell empty enough for the next preset to start clean.
	]]
	unmount: () -> (),
	--[[
		Draws one call of history. Optional: a preset that wants ordinary bars
		omits it and Visuals draws them.
	]]
	paintSlot: ((slot: Slot, ctx: Context) -> ())?,
	--[[
		A still miniature for the picker, drawn into a 40x24 frame.

		Static on purpose. Eight live renderers running behind a hover menu is
		the one place the "only one preset runs at a time" argument breaks, and
		it breaks in a drawer the user looks at for two seconds.
	]]
	swatch: (frame: Frame, palette: Palette) -> (),
}

return {}
