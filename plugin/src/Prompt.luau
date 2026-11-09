--!strict
--[[
	The console's command line.

	The panel was read-only for its whole life, and the footer even carried a
	note explaining why it had no cursor: a blinking block promises that
	something accepts input, and nothing did. That is what this changes. One row
	under the header, always visible -- it does not ride the `visuals` toggle,
	because a control that disappears with a decoration is a control nobody
	trusts -- holding a caret and a field.

	Two kinds of thing go in it and the row does not distinguish them, on
	purpose. A word it knows is a command and runs here in milliseconds; anything
	else is a sentence, and sentences go to an agent. Making the user mark which
	is which would be asking them to know our implementation before they can
	type.

	Above the row sits a scrolling menu of the commands matching what is being
	typed -- all of them, while the field is empty. The placeholder used to say
	"type a command" and then leave the reader to work out which commands
	existed, which is a prompt keeping a secret. The list is the answer, and it
	is shown for the same reason a shell shows you its completions rather than
	describing them.

	WHY THE MENU IS DRIVEN BY THE MOUSE AND BY TYPING, AND NOT BY ARROW KEYS.

	Because Studio does not deliver keyboard input to plugin widgets at all.
	UserInputService and ContextActionService are documented as not working
	inside a PluginGui, and a GuiObject's own InputBegan never sees a key either
	-- the request asking Roblox for a way to read keys in a plugin window has
	been open since 2020 and was bumped again a month ago:

	  https://devforum.roblox.com/t/plugins-need-a-way-to-listen-to-app-input/479597
	  https://devforum.roblox.com/t/text-editor-make-editing-text-fields-much-easier/684771

	This was learned the expensive way: an arrow-key highlight was written, then
	rewritten against UserInputService, then wired to both at once, and all three
	were dead on arrival. Mouse input works -- that is what the theme drawer runs
	on -- and the TextBox reports its own text and its own Enter. Between them
	they are enough, so the menu offers exactly those and the caption promises
	nothing else. A key that a caption advertises and the platform cannot deliver
	is worse than no key at all.
]]

local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local Palette = require(script.Parent.Palette)

-- The caret swelling when typing starts, and settling when it stops.
local CARET_GROW = TweenInfo.new(0.16, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local Secret = require(script.Parent.Secret)

local Prompt = {}

-- Tall enough for a 12pt line with air around it, short enough that it does not
-- read as a second header. The log gives up exactly this much.
Prompt.HEIGHT = 46

-- Matches the log's own left inset, so the caret sits in the same column as the
-- sigils below it and the whole panel reads as one grid.
local INSET = 20
local CARET_WIDTH = 14

-- The stop button, shown at the right of the row only while an agent runs.
local STOP_WIDTH = 64
-- The SEND button, in the same slot the stop button takes while an agent runs.
local SEND_WIDTH = 56
local STOP_GAP = 8

--[[
	How many past lines are kept.

	A ring rather than a session log: this is for getting back to the thing you
	typed a moment ago, and anyone scrolling past fifty entries wanted the log,
	not the history.
]]
local MAX_HISTORY = 50

--[[
	The command menu's shape.

	Seven rows is about as tall as this can be before it stops being a hint over
	the log and starts being a page covering it. Everything past that is reached
	by scrolling, which is the mouse's job here rather than a key's.
]]
local MENU_ROW_HEIGHT = 24
local MENU_MAX_ROWS = 7
local MENU_PAD = 8
local MENU_CAPTION_HEIGHT = 16
local MENU_SCROLLBAR = 4
-- Gap between the menu's bottom edge and the top of the prompt row.
local MENU_LIFT = 2
-- Where the summary column starts, measured from the menu's left edge. Wide
-- enough for `agent [use <id>|new]`, the longest usage line there is.
local MENU_SUMMARY_X = 170

--[[
	Explicit depths, because a plugin widget draws with ZIndexBehavior.Global
	and a child does not inherit its parent's. Above the log and the CRT flourish
	that sit at 20-22; below the preset drawer at 30, which is modal and must
	stay clickable when it is open.
]]
local Z_MENU = 24
local Z_MENU_SCROLL = 25
local Z_MENU_ROW = 26
local Z_MENU_TEXT = 27

type Suggestion = {
	name: string,
	usage: string,
	summary: string,
}

local function escapeRich(text: string): string
	return (string.gsub(string.gsub(string.gsub(text, "&", "&amp;"), "<", "&lt;"), ">", "&gt;"))
end

type MenuRow = {
	button: TextButton,
	dot: Frame,
	usage: TextLabel,
	summary: TextLabel,
	--[[
		The command this row is currently showing, and whether its usage line
		mentions an argument.

		Held on the row rather than looked up when it is clicked. The lookup was
		a real bug: clicking takes focus off the field, the focus handler emptied
		the match list, and by the time the click arrived there was nothing left
		to resolve -- so every click did nothing at all.
	]]
	entry: string,
	takesArgument: boolean,
}

type Runtime = {
	row: Frame?,
	caret: TextLabel?,
	field: TextBox?,
	hint: TextLabel?,
	rule: Frame?,
	menu: Frame?,
	box: Frame?,
	menuScroll: ScrollingFrame?,
	menuCaption: TextLabel?,
	menuRows: { MenuRow },
	--[[
		What the menu is currently offering. Empty means it is closed; there is
		no separate flag, because two ways to ask whether a list is showing is
		one way too many.
	]]
	matches: { Suggestion },
	-- Which row the pointer is over, 1-based into `matches`; 0 for none.
	hovered: number,
	-- Whether the field currently holds the keyboard. The menu is a thing you
	-- type at, so it has no business being on screen when nobody is typing.
	focused: boolean,
	--[[
		Whether the pointer is over the menu.

		Checked before the menu is taken down on focus loss, and that ordering is
		the whole reason it exists: pressing the mouse on a row releases the
		field's focus BEFORE the click completes, so a menu that closes on focus
		loss deletes the button mid-press and the click never happens.
	]]
	hovering: boolean,
	--[[
		Newest last. The entry being edited is NOT in here -- it is in the field
		-- so the list holds only lines that were actually submitted.
	]]
	history: { string },
	--[[
		Where in the history the user is, counted from the end. Zero means "at
		the live line", which is the only state in which the field's contents
		belong to the user rather than to a recalled entry.
	]]
	offset: number,
	-- What was being typed before the history took the field over, so coming
	-- back returns it rather than an empty line.
	draft: string,
	busy: boolean,
	-- The cancel button, and whether it has been pressed and is waiting for the
	-- agent to actually go.
	stop: TextButton?,
	send: TextButton?,
	sendHover: boolean?,
	stopping: boolean,
	-- Whether a line that is not a command goes to an agent. Off until the user
	-- runs `chat on`; only used to word the placeholder, since `Commands` is what
	-- actually refuses the line.
	chat: boolean,
	--[[
		What is selected in Studio right now, already worded for display.

		Kept here because the prompt is where it earns its place: half of what
		anyone types into this box is deictic -- "make this bigger", "delete
		that" -- and the word only means something if you can see what it points
		at while you are writing it. Studio's own Explorer is often scrolled
		somewhere else, or behind the panel.
	]]
	selection: string,
	complete: ((string) -> { string })?,
	suggest: ((string) -> { Suggestion })?,
	submit: ((string) -> ())?,
}

local runtime: Runtime = {
	row = nil,
	caret = nil,
	field = nil,
	hint = nil,
	rule = nil,
	menu = nil,
	menuScroll = nil,
	menuCaption = nil,
	menuRows = {},
	matches = {},
	hovered = 0,
	focused = false,
	hovering = false,
	history = {},
	offset = 0,
	draft = "",
	busy = false,
	stop = nil,
	stopping = false,
	chat = false,
	selection = "",
	complete = nil,
	suggest = nil,
	submit = nil,
}

--[[
	The caret's colour, which is the row's only status light.

	Violet at rest is the project's accent and says "this is ours". Amber while
	an agent runs says something is happening without stealing the caption's
	line, which is already reporting what.
]]
local function paintCaret()
	local caret = runtime.caret
	if caret == nil then
		return
	end
	local palette = Palette.get()
	caret.TextColor3 = if runtime.busy then palette.amber else palette.cyan
end

local function placeholder(): string
	if runtime.busy then
		return "Working\u{2026} press Stop to cancel"
	end
	return if runtime.chat
		then "type a command, or ask for something"
		else "type a command -- `chat on` lets an agent answer"
end

--[[
	Makes room for the stop button while it is showing.

	The field and the hint share the row's right end with it, so both give up
	exactly its width rather than sitting underneath.
]]
local function layoutRow()
	local field = runtime.field
	local hint = runtime.hint
	if field == nil or hint == nil then
		return
	end
	local reserved = if runtime.busy then STOP_WIDTH + STOP_GAP else 0
	field.Size = UDim2.new(1, -(INSET + CARET_WIDTH + INSET + reserved), 1, 0)
	hint.Position = UDim2.new(1, -(INSET + reserved), 0, 0)
	local stop = runtime.stop
	if stop ~= nil then
		stop.Visible = runtime.busy
	end
	local send = runtime.send
	if send ~= nil then
		send.Visible = not runtime.busy and string.find(field.Text, "%S") ~= nil
		if send.Visible then
			hint.Position = UDim2.new(1, -(SEND_WIDTH + 8), 0, 0)
		end
	end
end

--[[
	Whether the command menu is on screen.

	Derived from the match list rather than from a flag of its own: the menu is
	the list, and a second source of truth for "is it showing" is a second thing
	that can be wrong.
]]
local function isMenuOpen(): boolean
	local menu = runtime.menu
	return menu ~= nil and menu.Visible and #runtime.matches > 0
end

--[[
	Draws the current matches into the pre-built rows.

	The rows exist from `mount` -- one per command, since that number only
	changes when the source does -- and are only ever shown, hidden and
	relabelled. Building them per keystroke would mean four `Instance.new` calls
	per visible command on every letter typed, and a menu that flickers as it is
	rebuilt is worse than no menu.
]]
local function renderMenu()
	local menu = runtime.menu
	local scroll = runtime.menuScroll
	local caption = runtime.menuCaption
	if menu == nil or scroll == nil or caption == nil then
		return
	end

	local total = #runtime.matches
	if total == 0 then
		menu.Visible = false
		return
	end

	local palette = Palette.get()

	for position, row in runtime.menuRows do
		local entry = runtime.matches[position]
		if entry == nil then
			row.button.Visible = false
			row.entry = ""
			continue
		end

		row.button.Visible = true
		row.button.LayoutOrder = position
		local hot = position == runtime.hovered
		row.button.BackgroundColor3 = palette.rule
		row.button.BackgroundTransparency = if hot then 0.8 else 1
		-- The name in full colour, its arguments dimmed and smaller beside it.
		local name, rest = string.match(entry.usage, "^(%S+)%s*(.*)$")
		local args = if rest ~= nil and rest ~= ""
			then string.format(' <font color="#%s" size="11">%s</font>', palette.dim:ToHex(), escapeRich(rest))
			else ""
		row.usage.Text = escapeRich(name or entry.usage) .. args
		row.usage.TextColor3 = palette.text
		row.dot.BackgroundColor3 = if hot then palette.text else palette.cyan
		row.dot.Size = if hot then UDim2.fromOffset(6, 6) else UDim2.fromOffset(4, 4)
		row.summary.Text = entry.summary
		row.summary.TextColor3 = palette.dim
		row.entry = entry.name
		-- A usage line that is more than the bare name -- `theme [name]`,
		-- `use <number|id>` -- is a command that wants an argument, and those
		-- are the only ones worth leaving a space after.
		row.takesArgument = entry.usage ~= entry.name
	end

	--[[
		Only as tall as it needs to be, up to seven rows. The rest is reached by
		scrolling, and the scrollbar appearing is what says there is more.
	]]
	local visible = math.min(total, MENU_MAX_ROWS)
	scroll.Size = UDim2.new(1, 0, 0, visible * MENU_ROW_HEIGHT)
	scroll.ScrollBarImageColor3 = palette.dim

	caption.Text = if total == 1
		then "1 command   click it, or press enter to run"
		else string.format("%d commands   click one, or keep typing", total)
	caption.TextColor3 = palette.dim
	-- Indented to the same column as the rows above it. This used to be flush
	-- against the frame's edge, which made it read as something that had fallen
	-- out of the menu rather than as part of it.
	caption.Position = UDim2.fromOffset(MENU_PAD, MENU_PAD + visible * MENU_ROW_HEIGHT)

	menu.BackgroundColor3 = Palette.deep()
	menu.Size =
		UDim2.new(1, -(INSET * 2), 0, MENU_PAD * 2 + visible * MENU_ROW_HEIGHT + MENU_CAPTION_HEIGHT)
	menu.Visible = true
end

local function closeMenu()
	runtime.matches = {}
	runtime.hovered = 0
	local menu = runtime.menu
	if menu then
		menu.Visible = false
	end
end

--[[
	The greyed-out remainder of the command being typed.

	Drawn as a separate label positioned after the text rather than inside the
	field, because a TextBox that writes its own guess into itself has to undo
	that on every keystroke and gets it wrong the moment the user types fast.
]]
local function showHint()
	local field = runtime.field
	local hint = runtime.hint
	local complete = runtime.complete
	if field == nil or hint == nil or complete == nil then
		return
	end

	--[[
		The menu says it better, when the menu is up.

		This row used to carry the whole match list crammed into half a line of
		11pt text. Now that the same matches are listed properly above the field,
		repeating them here would be noise competing with the thing it duplicates
		-- so the slot goes back to the selection, which has nowhere else to be.
	]]
	if isMenuOpen() then
		hint.Text = runtime.selection
		return
	end

	local typed = field.Text
	-- Only the first word completes. Everything after it is an argument, and
	-- guessing at arguments is how a prompt starts fighting the person using it.
	if typed ~= "" and string.find(typed, "%s") == nil then
		local matches = complete(typed)
		if #matches == 1 and matches[1] ~= typed then
			hint.Text = matches[1]
			return
		end
	end

	hint.Text = runtime.selection
end

--[[
	Recomputes what the menu offers, from what is in the field right now.

	One rule, and only one: the list is up whenever the bar has the cursor and
	holds at most one word. There used to be two more -- a "dismissed" flag and a
	"resuming" flag -- and between them they were the bug that would not die:
	clicking the empty bar after running a command showed nothing, because a flag
	set on the way out of the last command was still holding the list shut and
	only a keystroke cleared it. Flags that guess at intent are how that happens.
	State this small should be derivable from what is on screen, so now it is.

	The text is trimmed before it is judged, because whitespace is not content. A
	bar holding nothing but a space is an empty bar, and it was being treated as a
	line with an argument in it -- which closed the menu and left no way to tell
	why.
]]
local function refreshMenu()
	local field = runtime.field
	local suggest = runtime.suggest
	if field == nil or suggest == nil then
		return
	end

	local trimmed = string.match(field.Text, "^%s*(.-)%s*$") or ""

	-- A space INSIDE the line means the first word is settled and an argument is
	-- being written, which is the point at which a list of commands stops being
	-- what the person typing needs to see.
	if not runtime.focused or string.find(trimmed, "%s") ~= nil then
		closeMenu()
		showHint()
		return
	end

	runtime.matches = suggest(trimmed)
	-- Nothing is highlighted until the pointer picks something. A highlight that
	-- appears on its own is a selection the user did not make, and clicking is
	-- the only way to act on it anyway.
	runtime.hovered = 0

	--[[
		Back to the top, but only here.

		This used to live in `renderMenu`, which also runs on every hover -- so
		scrolling to the bottom of the list and then moving the mouse a pixel
		snapped it straight back to the first row. The scroll position is only
		meaningless when the list underneath it has changed, and that is exactly
		what this function is for.
	]]
	local scroll = runtime.menuScroll
	if scroll then
		scroll.CanvasPosition = Vector2.new(0, 0)
	end

	renderMenu()
	showHint()
end

--[[
	Puts a command in the field, without running it.

	A trailing space only where the command takes an argument. It used to be
	added unconditionally, which left `clear ` sitting in the bar with a space
	the user then had to notice and delete -- reported as exactly that. A command
	that takes nothing is complete the moment its name is there, and Enter runs
	it.
]]
local function fillWith(name: string, takesArgument: boolean)
	local field = runtime.field
	if field == nil or name == "" then
		return
	end
	closeMenu()
	field.Text = if takesArgument then name .. " " else name
	field.CursorPosition = #field.Text + 1
	showHint()
end

--[[
	Puts a past line back in the field.

	`offset` counts backwards from the newest entry, so 1 is the last thing
	typed. Zero is the live line, which is the draft rather than any entry.
]]
local function recall(offset: number)
	local field = runtime.field
	if field == nil then
		return
	end
	local total = #runtime.history
	local wanted = math.clamp(offset, 0, total)

	-- Stepping off the live line for the first time: keep what was there, or
	-- walking up and back down silently eats a half-typed command.
	if runtime.offset == 0 and wanted > 0 then
		runtime.draft = field.Text
	end

	runtime.offset = wanted
	field.Text = if wanted == 0 then runtime.draft else runtime.history[total - wanted + 1]
	field.CursorPosition = #field.Text + 1
	showHint()
end

local function remember(raw: string)
	-- Masked on the way in, so a key cannot be recalled with the up arrow by
	-- whoever is at the machine next. See `Secret`.
	local line = Secret.mask(raw)
	local history = runtime.history
	-- A line repeated back to back is one entry. Pressing up should walk through
	-- what was done, not through how many times it was retried.
	if history[#history] ~= line then
		table.insert(history, line)
	end
	while #history > MAX_HISTORY do
		table.remove(history, 1)
	end
	runtime.offset = 0
	runtime.draft = ""
end

--[[
	Builds the menu's rows, one per command.

	Sized from the full command list rather than from the seven that fit, so
	filtering is a matter of hiding rows instead of rebuilding them. A
	UIListLayout stacks whatever is left and `AutomaticCanvasSize` turns that
	into a scrollable canvas, which is what makes the eighth command reachable.
]]
local function buildRows(scroll: ScrollingFrame, count: number)
	local palette = Palette.get()

	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Vertical
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = scroll

	for slot = 1, count do
		--[[
			A TextButton rather than a Frame with a button over it. The mouse is
			the only way into this list, so the row IS the control, and one
			instance answering for the hover and the click beats two that can
			fall out of step.
		]]
		local button = Instance.new("TextButton")
		button.Name = string.format("Row%d", slot)
		button.Text = ""
		button.AutoButtonColor = false
		button.BackgroundColor3 = palette.rule
		button.BackgroundTransparency = 1
		button.BorderSizePixel = 0
		button.Visible = false
		-- The same left-bright wash a hovered log row gets.
		local wash = Instance.new("UIGradient")
		wash.Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0),
			NumberSequenceKeypoint.new(0.9, 0.85),
			NumberSequenceKeypoint.new(1, 1),
		})
		wash.Parent = button
		button.Size = UDim2.new(1, -MENU_SCROLLBAR, 0, MENU_ROW_HEIGHT)
		button.ZIndex = Z_MENU_ROW
		button.Parent = scroll

		local dot = Instance.new("Frame")
		dot.Name = "Dot"
		dot.BorderSizePixel = 0
		dot.Rotation = 45
		dot.AnchorPoint = Vector2.new(0.5, 0.5)
		dot.Position = UDim2.new(0, MENU_PAD + 3, 0.5, 0)
		dot.Size = UDim2.fromOffset(4, 4)
		dot.BackgroundColor3 = palette.cyan
		dot.ZIndex = Z_MENU_TEXT
		dot.Parent = button

		local usage = Instance.new("TextLabel")
		usage.Name = "Usage"
		usage.Font = Palette.FONT_MEDIUM
		usage.TextSize = 14
		usage.RichText = true
		usage.TextColor3 = palette.text
		usage.TextXAlignment = Enum.TextXAlignment.Left
		usage.TextTruncate = Enum.TextTruncate.AtEnd
		usage.BackgroundTransparency = 1
		usage.Position = UDim2.fromOffset(MENU_PAD + 14, 0)
		usage.Size = UDim2.new(0, MENU_SUMMARY_X - MENU_PAD * 2 - 14, 1, 0)
		usage.ZIndex = Z_MENU_TEXT
		usage.Parent = button

		local summary = Instance.new("TextLabel")
		summary.Name = "Summary"
		summary.Font = Palette.FONT
		summary.TextSize = 13
		summary.TextColor3 = palette.dim
		summary.TextXAlignment = Enum.TextXAlignment.Left
		summary.TextTruncate = Enum.TextTruncate.AtEnd
		summary.BackgroundTransparency = 1
		summary.Position = UDim2.fromOffset(MENU_SUMMARY_X, 0)
		summary.Size = UDim2.new(1, -(MENU_SUMMARY_X + MENU_PAD), 1, 0)
		summary.ZIndex = Z_MENU_TEXT
		summary.Parent = button

		local record: MenuRow = {
			button = button,
			dot = dot,
			usage = usage,
			summary = summary,
			entry = "",
			takesArgument = false,
		}
		table.insert(runtime.menuRows, record)

		-- The highlight follows the pointer. With no keyboard to drive a
		-- selection, hover IS the selection.
		button.MouseEnter:Connect(function()
			if runtime.hovered == slot then
				return
			end
			runtime.hovered = slot
			renderMenu()
		end)
		button.MouseLeave:Connect(function()
			if runtime.hovered ~= slot then
				return
			end
			runtime.hovered = 0
			renderMenu()
		end)

		--[[
			Fills the bar from what this row is showing, not from the match list,
			which the focus loss that comes with the click may already have
			emptied. The row knows its own command; that is enough.
		]]
		button.MouseButton1Click:Connect(function()
			fillWith(record.entry, record.takesArgument)
			Prompt.focus()
		end)
	end
end

--[[
	Builds the row. Called once from `Console.mount`, positioned by it.
]]
--[[
	Shows SEND while there is something to send and nothing running (the stop
	button owns that slot while an agent works), and moves the hint out of its way.
]]
local function syncSend()
	local send, field, hint = runtime.send, runtime.field, runtime.hint
	if send == nil or field == nil then
		return
	end
	local wanted = not runtime.busy and string.find(field.Text, "%S") ~= nil
	send.Visible = wanted
	-- While busy the stop button owns the slot and the busy layout owns the hint.
	if hint ~= nil and not runtime.busy then
		hint.Position = UDim2.new(1, if wanted then -(SEND_WIDTH + 8) else -INSET, 0, 0)
	end
	--[[
		The field stops short of SEND. It used to run underneath it, so a click
		on SEND was also a click on the field: it took focus back and opened the
		whole command list the moment the line had been sent.
	]]
	if not runtime.busy then
		local reserved = if wanted then SEND_WIDTH - INSET + 4 else 0
		field.Size = UDim2.new(1, -(INSET + CARET_WIDTH + INSET + reserved), 1, 0)
	end
end

--[[
	Submits whatever is in the field. Shared by Enter and by SEND.
]]
local function submitField()
	local field = runtime.field
	if field == nil then
		return
	end
	local line = string.match(field.Text, "^%s*(.-)%s*$") or ""
	field.Text = ""
	if runtime.hint then
		(runtime.hint :: TextLabel).Text = ""
	end
	if line == "" then
		return
	end
	remember(line)
	local run = runtime.submit
	if run ~= nil then
		-- Spawned so a slow command -- one that waits on the bridge -- cannot
		-- hold the field unresponsive while it runs.
		task.spawn(run, line)
	end
end

function Prompt.mount(
	parent: Instance,
	handlers: {
		submit: (string) -> (),
		complete: (string) -> { string },
		suggest: (string) -> { Suggestion },
	}
)
	local palette = Palette.get()
	runtime.submit = handlers.submit
	runtime.complete = handlers.complete
	runtime.suggest = handlers.suggest

	local row = Instance.new("Frame")
	row.Name = "Prompt"
	row.BackgroundColor3 = palette.background
	row.BackgroundTransparency = 1
	row.BorderSizePixel = 0
	row.Parent = parent
	runtime.row = row

	-- The input box: a dark inset with a hairline, the row's only visible frame.
	local box = Instance.new("Frame")
	box.Name = "Box"
	box.AnchorPoint = Vector2.new(0.5, 0.5)
	box.Position = UDim2.fromScale(0.5, 0.5)
	box.Size = UDim2.new(1, -20, 0, 32)
	box.BackgroundColor3 = Palette.deep()
	box.BackgroundTransparency = 0.35
	box.BorderSizePixel = 0
	box.ZIndex = 1
	box.Parent = row
	runtime.box = box
	local boxStroke = Instance.new("UIStroke")
	boxStroke.Color = palette.rule
	boxStroke.Transparency = 0.45
	boxStroke.Parent = box

	local caret = Instance.new("TextLabel")
	caret.Name = "Caret"
	caret.Text = "\u{203A}"
	caret.Font = Enum.Font.Code
	caret.TextSize = 14
	caret.TextColor3 = palette.cyan
	caret.TextXAlignment = Enum.TextXAlignment.Left
	caret.BackgroundTransparency = 1
	caret.Position = UDim2.fromOffset(INSET, 0)
	caret.Size = UDim2.new(0, CARET_WIDTH, 1, 0)
	caret.ZIndex = 2
	caret.Parent = row
	runtime.caret = caret

	local left = INSET + CARET_WIDTH

	--[[
		The hint sits at the right end rather than immediately after the text.

		Following the cursor means measuring the text every keystroke, and a
		suggestion that jitters horizontally while you type is worse than one
		parked somewhere predictable.
	]]
	local hint = Instance.new("TextLabel")
	hint.Name = "Hint"
	hint.Text = ""
	hint.Font = Palette.FONT
	hint.TextSize = 12
	hint.TextColor3 = palette.dim
	hint.TextXAlignment = Enum.TextXAlignment.Right
	hint.TextTruncate = Enum.TextTruncate.AtEnd
	hint.BackgroundTransparency = 1
	hint.AnchorPoint = Vector2.new(1, 0)
	hint.Position = UDim2.new(1, -INSET, 0, 0)
	hint.Size = UDim2.new(0.5, 0, 1, 0)
	hint.ZIndex = 2
	hint.Parent = row
	runtime.hint = hint

	local field = Instance.new("TextBox")
	field.Name = "Field"
	field.Text = ""
	field.PlaceholderText = placeholder()
	field.PlaceholderColor3 = palette.dim
	field.Font = Palette.FONT
	field.TextSize = 14
	field.TextColor3 = palette.text
	field.TextXAlignment = Enum.TextXAlignment.Left
	field.BackgroundTransparency = 1
	field.BorderSizePixel = 0
	-- Cleared on submit, not on focus: clicking away to read a line above and
	-- clicking back must not cost what was typed.
	field.ClearTextOnFocus = false
	field.ClipsDescendants = true
	field.Position = UDim2.fromOffset(left, 0)
	field.Size = UDim2.new(1, -(left + INSET), 1, 0)
	field.ZIndex = 2
	field.Parent = row
	runtime.field = field

	-- A hairline ABOVE the row, because the row sits at the foot of the panel:
	-- the edge worth drawing is the one between the log and the input, and a
	-- second line just above the status bar would only crowd it.
	local rule = Instance.new("Frame")
	rule.Name = "Rule"
	rule.AnchorPoint = Vector2.new(0, 0)
	rule.Position = UDim2.fromScale(0, 0)
	rule.Size = UDim2.new(1, 0, 0, 1)
	rule.BackgroundColor3 = palette.rule
	rule.BackgroundTransparency = 0.65
	rule.BorderSizePixel = 0
	rule.Parent = row
	runtime.rule = rule

	--[[
		The cancel button. A command that cancels the one thing running is a
		control, not a thing to remember the name of, so it lives where the
		agent's state is already shown: at the end of the row whose caret is
		amber. It sends the same `stop` line the command would, so there is one
		code path to cancel.
	]]
	local stop = Instance.new("TextButton")
	stop.Name = "Stop"
	stop.Text = "Stop"
	stop.Font = Palette.FONT_MEDIUM
	stop.TextSize = 13
	stop.AutoButtonColor = false
	stop.BorderSizePixel = 0
	stop.AnchorPoint = Vector2.new(1, 0.5)
	-- Same slot and shape as SEND: square, inside the box's right edge.
	stop.Position = UDim2.new(1, -11, 0.5, 0)
	stop.Size = UDim2.fromOffset(STOP_WIDTH, 30)
	stop.BackgroundColor3 = palette.red
	stop.BackgroundTransparency = 0.82
	stop.TextColor3 = palette.text
	stop.Visible = false
	stop.ZIndex = 2
	stop.Parent = row
	runtime.stop = stop


	local stopStroke = Instance.new("UIStroke")
	stopStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	stopStroke.Color = palette.red
	stopStroke.Transparency = 0.55
	stopStroke.Parent = stop

	stop.MouseEnter:Connect(function()
		if not runtime.stopping then
			local now = Palette.get()
			stopStroke.Transparency = 0.15
			stop.BackgroundTransparency = 0.6
		end
	end)
	stop.MouseLeave:Connect(function()
		stopStroke.Transparency = 0.55
		stop.BackgroundTransparency = 0.82
	end)
	stop.MouseButton1Click:Connect(function()
		if runtime.stopping or not runtime.busy then
			return
		end
		runtime.stopping = true
		stop.Text = "Stopping\u{2026}"
		local run = runtime.submit
		if run ~= nil then
			task.spawn(run, "stop")
		end
		-- If the agent is still listed as running a while later, the cancel did
		-- not land; give the button back rather than leave it dead.
		task.delay(6, function()
			if runtime.stopping and runtime.busy then
				runtime.stopping = false
				stop.Text = "Stop"
			end
		end)
	end)

	--[[
		SEND: the same as pressing Enter, for a mouse.

		Studio hands a plugin TextBox its own Enter and nothing else, so until
		now the only way to submit was the keyboard. Clicking SEND releases the
		field's focus first (FocusLost without Enter, which submits nothing),
		then fires here with the text still in the field.
	]]
	local send = Instance.new("TextButton")
	send.Name = "Send"
	send.Text = "Send"
	send.Font = Palette.FONT_MEDIUM
	send.TextSize = 13
	send.AutoButtonColor = false
	send.BorderSizePixel = 0
	-- Flush with the panel's right edge, full row height: a docked button,
	-- not a floating pill with a gap beside it.
	send.AnchorPoint = Vector2.new(1, 0.5)
	send.Position = UDim2.new(1, -11, 0.5, 0)
	send.Size = UDim2.new(0, SEND_WIDTH, 0, 30)
	send.BackgroundColor3 = palette.cyan
	send.BackgroundTransparency = 0.75
	send.TextColor3 = palette.text
	send.Visible = false
	send.ZIndex = 2
	send.Parent = row
	runtime.send = send


	send.MouseEnter:Connect(function()
		runtime.sendHover = true
		send.BackgroundTransparency = 0.45
	end)
	send.MouseLeave:Connect(function()
		runtime.sendHover = false
		send.BackgroundTransparency = 0.75
	end)
	send.MouseButton1Click:Connect(function()
		submitField()
		-- After the submit, so the empty field's text change cannot re-open it.
		runtime.focused = false
		closeMenu()
		showHint()
	end)

	field:GetPropertyChangedSignal("Text"):Connect(syncSend)

	--[[
		Typing feedback: the caret swells and sways side to side while keys
		are coming in, and settles 0.6s after the last one.
	]]
	local typingUntil = 0
	local swaying: RBXScriptConnection? = nil
	field:GetPropertyChangedSignal("Text"):Connect(function()
		if field.Text == "" then
			typingUntil = 0
			return
		end
		typingUntil = os.clock() + 0.6
		if swaying ~= nil then
			return
		end
		TweenService:Create(caret, CARET_GROW, { TextSize = 19 }):Play()
		local started = os.clock()
		swaying = RunService.Heartbeat:Connect(function()
			local now = os.clock()
			if now >= typingUntil then
				if swaying then
					swaying:Disconnect()
					swaying = nil
				end
				TweenService:Create(caret, CARET_GROW, { TextSize = 14, Position = UDim2.fromOffset(INSET, 0) }):Play()
				return
			end
			caret.Position = UDim2.fromOffset(INSET + math.sin((now - started) * 14) * 2.5, 0)
		end)
	end)

	--[[
		The menu, parented to the row rather than to the panel.

		Anchored to its own bottom edge with a negative Y offset, so it grows
		upward out of a row that is already sitting on the status bar. The row
		does not clip, so drawing outside it is allowed; the explicit ZIndex is
		what puts it over the log, since a plugin widget draws with
		ZIndexBehavior.Global and a child does not inherit its parent's depth.
	]]
	local menu = Instance.new("Frame")
	menu.Name = "Menu"
	menu.BackgroundColor3 = Palette.deep()
	menu.BackgroundTransparency = 0.04
	menu.BorderSizePixel = 0
	menu.Visible = false
	menu.AnchorPoint = Vector2.new(0, 1)
	menu.Position = UDim2.new(0, INSET, 0, -MENU_LIFT)
	menu.Size = UDim2.new(1, -(INSET * 2), 0, 0)
	menu.ZIndex = Z_MENU
	menu.Parent = row
	runtime.menu = menu

	--[[
		Whether the pointer is inside. Read by FocusLost, which must not take the
		menu down while someone is in the middle of clicking a row.
	]]
	menu.MouseEnter:Connect(function()
		runtime.hovering = true
	end)
	menu.MouseLeave:Connect(function()
		runtime.hovering = false
		-- Leaving the menu with the field no longer focused means the click that
		-- was coming never came, so there is nothing left holding it open.
		if not runtime.focused then
			closeMenu()
		end
	end)

	local menuStroke = Instance.new("UIStroke")
	menuStroke.Color = palette.rule
	menuStroke.Transparency = 0.5
	menuStroke.Thickness = 1
	menuStroke.Parent = menu

	local menuCorner = Instance.new("UICorner")
	menuCorner.CornerRadius = UDim.new(0, 0)
	menuCorner.Parent = menu

	--[[
		The scrolling part. Seventeen commands do not fit above a 30px row and
		there is no key that could page through them here, so the wheel is how
		the rest is reached -- and the scrollbar is what says there IS a rest.
	]]
	local scroll = Instance.new("ScrollingFrame")
	scroll.Name = "Rows"
	scroll.BackgroundTransparency = 1
	scroll.BorderSizePixel = 0
	scroll.Position = UDim2.fromOffset(0, MENU_PAD)
	scroll.Size = UDim2.new(1, 0, 0, MENU_MAX_ROWS * MENU_ROW_HEIGHT)
	scroll.CanvasSize = UDim2.new()
	scroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
	scroll.ScrollingDirection = Enum.ScrollingDirection.Y
	scroll.ScrollBarThickness = MENU_SCROLLBAR
	scroll.ScrollBarImageColor3 = palette.dim
	scroll.ZIndex = Z_MENU_SCROLL
	scroll.Parent = menu
	runtime.menuScroll = scroll

	-- One row per command, asked of the same function that will later filter
	-- them, so the pool can never be smaller than the list it has to show.
	runtime.menuRows = {}
	buildRows(scroll, #handlers.suggest(""))

	local caption = Instance.new("TextLabel")
	caption.Name = "Caption"
	caption.Font = Palette.FONT
	caption.TextSize = 12
	caption.TextColor3 = palette.dim
	caption.TextXAlignment = Enum.TextXAlignment.Left
	caption.TextTruncate = Enum.TextTruncate.AtEnd
	caption.BackgroundTransparency = 1
	caption.Position = UDim2.fromOffset(MENU_PAD, 0)
	caption.Size = UDim2.new(1, -(MENU_PAD * 2), 0, MENU_CAPTION_HEIGHT)
	caption.ZIndex = Z_MENU_TEXT
	caption.Parent = menu
	runtime.menuCaption = caption

	field.Focused:Connect(function()
		runtime.focused = true
		refreshMenu()
	end)

	--[[
		A click on the bar asks for the list, even when the bar already has the
		cursor.

		Belt and braces next to `Focused`, which is what normally opens the menu.
		This covers the case where the field never lost focus in the first place,
		and `Focused` therefore has nothing to fire about. Mouse input is the one
		kind a plugin widget does deliver, which is why this can be read at all.
	]]
	field.InputBegan:Connect(function(input)
		if input.UserInputType ~= Enum.UserInputType.MouseButton1 then
			return
		end
		-- A press on SEND is not a click on the bar, even where they touch.
		if runtime.sendHover then
			return
		end
		runtime.focused = true
		refreshMenu()
	end)

	field:GetPropertyChangedSignal("Text"):Connect(function()
		-- Typing puts the user back on the live line. Without this, editing a
		-- recalled entry and pressing down would throw the edit away.
		if runtime.offset ~= 0 then
			runtime.offset = 0
			runtime.draft = ""
		end
		--[[
			Tab never belongs in this field.

			Studio delivers no key events to a plugin widget, so Tab cannot be
			intercepted -- but the TextBox still inserts one, and an invisible
			character on the end of `help` stops it matching anything. There is
			no refusing the keystroke, so it is taken back out here.
		]]
		if string.find(field.Text, "\t") ~= nil then
			local cleaned = (string.gsub(field.Text, "\t", ""))
			field.Text = cleaned
			field.CursorPosition = #cleaned + 1
			-- The assignment re-enters this handler with the clean text, which
			-- does the rest of the work.
			return
		end
		--[[
			Text arriving means the field has the cursor, whatever our flag says.
			Clicking a menu row takes focus away and hands it back through
			CaptureFocus, which does not always fire `Focused` in a plugin
			widget -- so the flag stayed false and the menu never came back
			after the filled command was deleted and retyped.
		]]
		if field:IsFocused() then
			runtime.focused = true
		end
		-- Refreshes the hint itself, so there is no second call here.
		refreshMenu()
	end)

	field.FocusLost:Connect(function(enterPressed)
		runtime.focused = false

		--[[
			The menu stays up while the pointer is on it.

			Focus is released on mouse-DOWN and the click only completes on
			mouse-up. Closing here regardless deleted the row being clicked in
			between the two, which is why clicking a command used to do nothing.
		]]
		-- Enter always takes it down, hover or not: the line has been submitted,
		-- so a list still standing over the reply is a leftover.
		if enterPressed or not runtime.hovering then
			closeMenu()
		end
		showHint()

		if not enterPressed then
			return
		end

		submitField()
		--[[
			The cursor is NOT taken back.

			It used to be, on the next frame, so a burst of commands could be
			typed without reaching for the mouse. Two things were wrong with
			that. The answer to the command arrives at the bottom of the log,
			exactly where a re-opened menu would sit, so the panel covered the
			thing it had just been asked for -- and suppressing the menu to avoid
			that is what made clicking the bar afterwards do nothing, since a
			field that never lost focus cannot be focused again.

			Letting go costs one click before the next command and buys a log you
			can actually read, and a bar that behaves the same way every time it
			is clicked.
		]]
	end)
end

--[[
	Puts the cursor in the field, for the toolbar button, for `help`, and for a
	click on the menu.

	Guarded: the widget can be closed while a command is still finishing, and
	capturing focus on a field whose window is gone throws.
]]
function Prompt.focus()
	local field = runtime.field
	if field ~= nil and field.Parent ~= nil then
		pcall(function()
			field:CaptureFocus()
		end)
		-- Don't wait on `Focused`, which a plugin widget may not fire here.
		if field:IsFocused() then
			runtime.focused = true
		end
	end
end

--[[
	Steps through the history, for whatever can reach a key.

	Kept because the ring is still recorded and still worth having the moment
	there is a way to drive it; nothing in a plugin widget can today. See the
	note at the top of this file.
]]
function Prompt.step(direction: number)
	recall(runtime.offset + direction)
end

--[[
	Reports that an agent is running, in the one place the user is looking.

	The log says what the agent is doing and the band says how long it is
	taking; this says only that the line they are about to type will queue behind
	something. That is a fact about the input, so it belongs to the input.
]]
function Prompt.setBusy(busy: boolean)
	runtime.busy = busy
	local stop = runtime.stop
	if not busy then
		runtime.stopping = false
		if stop ~= nil then
			stop.Text = "Stop"
		end
	end
	layoutRow()
	paintCaret()
	local field = runtime.field
	if field ~= nil then
		field.PlaceholderText = placeholder()
	end
end

--[[
	Reports whether sentences are answered, so the placeholder does not invite
	a request the console is about to decline.
]]
function Prompt.setChat(enabled: boolean)
	runtime.chat = enabled
	local field = runtime.field
	if field ~= nil then
		field.PlaceholderText = placeholder()
	end
end

--[[
	Reports what Studio has selected, as a phrase rather than a list.

	Called from the selection watcher, which has already debounced and worded
	it. This only decides whether it is on screen, which is `showHint`'s job
	anyway -- so the value is stored and the one renderer is asked to run again.
]]
function Prompt.setSelection(text: string)
	runtime.selection = text
	showHint()
end

--[[
	Whether an agent started from this prompt is still working.

	Read by the console before it announces a silence. The flag lives here
	because the caret is what displays it, and one owner beats two that have to
	be kept in step.
]]
function Prompt.isBusy(): boolean
	return runtime.busy
end

-- Whether the command menu is on screen, covering the log.
function Prompt.isMenuOpen(): boolean
	local menu = runtime.menu
	return menu ~= nil and menu.Visible
end

function Prompt.applyTheme()
	local palette = Palette.get()
	local field = runtime.field
	if field then
		field.TextColor3 = palette.text
		field.PlaceholderColor3 = palette.dim
	end
	local hint = runtime.hint
	if hint then
		hint.TextColor3 = palette.dim
	end
	local rule = runtime.rule
	if rule then
		rule.BackgroundColor3 = palette.rule
	end
	local box = runtime.box
	if box then
		box.BackgroundColor3 = Palette.deep()
		local stroke = box:FindFirstChildOfClass("UIStroke")
		if stroke then
			stroke.Color = palette.rule
		end
	end
	local send = runtime.send
	if send then
		send.BackgroundColor3 = palette.cyan
		send.TextColor3 = palette.text
	end
	local stop = runtime.stop
	if stop then
		stop.BackgroundColor3 = palette.red
		stop.TextColor3 = palette.text
		local stroke = stop:FindFirstChildOfClass("UIStroke")
		if stroke then
			stroke.Color = palette.red
		end
	end
	local menu = runtime.menu
	if menu then
		menu.BackgroundColor3 = Palette.deep()
		local stroke = menu:FindFirstChildOfClass("UIStroke")
		if stroke then
			stroke.Color = palette.rule
		end
	end
	if isMenuOpen() then
		renderMenu()
	end
	paintCaret()
end

return Prompt
