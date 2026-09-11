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

local Themes = require(script.Parent.Themes)

local Prompt = {}

-- Tall enough for a 12pt line with air around it, short enough that it does not
-- read as a second header. The log gives up exactly this much.
Prompt.HEIGHT = 30

-- Matches the log's own left inset, so the caret sits in the same column as the
-- sigils below it and the whole panel reads as one grid.
local INSET = 12
local CARET_WIDTH = 14

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
local MENU_ROW_HEIGHT = 20
local MENU_MAX_ROWS = 7
local MENU_PAD = 6
local MENU_CAPTION_HEIGHT = 16
local MENU_SCROLLBAR = 4
-- Gap between the menu's bottom edge and the top of the prompt row.
local MENU_LIFT = 2
-- Where the summary column starts, measured from the menu's left edge. Wide
-- enough for `agent [use <id>|new]`, the longest usage line there is.
local MENU_SUMMARY_X = 140

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

type MenuRow = {
	button: TextButton,
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
	local palette = Themes.palette()
	caret.TextColor3 = if runtime.busy then palette.amber else palette.violet
end

local function placeholder(): string
	return if runtime.busy
		then "running -- type stop to cancel"
		else "type a command, or ask for something"
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

	local palette = Themes.palette()

	for position, row in runtime.menuRows do
		local entry = runtime.matches[position]
		if entry == nil then
			row.button.Visible = false
			row.entry = ""
			continue
		end

		row.button.Visible = true
		row.button.LayoutOrder = position
		row.button.BackgroundColor3 = palette.surface
		row.button.BackgroundTransparency = if position == runtime.hovered then 0.25 else 1
		row.usage.Text = entry.usage
		row.usage.TextColor3 = if position == runtime.hovered then palette.violet else palette.text
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

	menu.BackgroundColor3 = palette.background
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

local function remember(line: string)
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
	local palette = Themes.palette()

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
		button.BackgroundColor3 = palette.surface
		button.BackgroundTransparency = 1
		button.BorderSizePixel = 0
		button.Visible = false
		button.Size = UDim2.new(1, -MENU_SCROLLBAR, 0, MENU_ROW_HEIGHT)
		button.ZIndex = Z_MENU_ROW
		button.Parent = scroll

		local usage = Instance.new("TextLabel")
		usage.Name = "Usage"
		usage.Font = Enum.Font.Code
		usage.TextSize = 12
		usage.TextColor3 = palette.text
		usage.TextXAlignment = Enum.TextXAlignment.Left
		usage.TextTruncate = Enum.TextTruncate.AtEnd
		usage.BackgroundTransparency = 1
		usage.Position = UDim2.fromOffset(MENU_PAD, 0)
		usage.Size = UDim2.new(0, MENU_SUMMARY_X - MENU_PAD * 2, 1, 0)
		usage.ZIndex = Z_MENU_TEXT
		usage.Parent = button

		local summary = Instance.new("TextLabel")
		summary.Name = "Summary"
		summary.Font = Enum.Font.Code
		summary.TextSize = 11
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
function Prompt.mount(
	parent: Instance,
	handlers: {
		submit: (string) -> (),
		complete: (string) -> { string },
		suggest: (string) -> { Suggestion },
	}
)
	local palette = Themes.palette()
	runtime.submit = handlers.submit
	runtime.complete = handlers.complete
	runtime.suggest = handlers.suggest

	local row = Instance.new("Frame")
	row.Name = "Prompt"
	row.BackgroundColor3 = palette.background
	row.BorderSizePixel = 0
	row.Parent = parent
	runtime.row = row

	local caret = Instance.new("TextLabel")
	caret.Name = "Caret"
	caret.Text = "\u{203A}"
	caret.Font = Enum.Font.Code
	caret.TextSize = 14
	caret.TextColor3 = palette.violet
	caret.TextXAlignment = Enum.TextXAlignment.Left
	caret.BackgroundTransparency = 1
	caret.Position = UDim2.fromOffset(INSET, 0)
	caret.Size = UDim2.new(0, CARET_WIDTH, 1, 0)
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
	hint.Font = Enum.Font.Code
	hint.TextSize = 11
	hint.TextColor3 = palette.dim
	hint.TextXAlignment = Enum.TextXAlignment.Right
	hint.TextTruncate = Enum.TextTruncate.AtEnd
	hint.BackgroundTransparency = 1
	hint.AnchorPoint = Vector2.new(1, 0)
	hint.Position = UDim2.new(1, -INSET, 0, 0)
	hint.Size = UDim2.new(0.5, 0, 1, 0)
	hint.Parent = row
	runtime.hint = hint

	local field = Instance.new("TextBox")
	field.Name = "Field"
	field.Text = ""
	field.PlaceholderText = placeholder()
	field.PlaceholderColor3 = palette.dim
	field.Font = Enum.Font.Code
	field.TextSize = 12
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
	rule.BackgroundTransparency = 0.4
	rule.BorderSizePixel = 0
	rule.Parent = row
	runtime.rule = rule

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
	menu.BackgroundColor3 = palette.background
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
	menuStroke.Transparency = 0.4
	menuStroke.Thickness = 1
	menuStroke.Parent = menu

	local menuCorner = Instance.new("UICorner")
	menuCorner.CornerRadius = UDim.new(0, 4)
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
	caption.Font = Enum.Font.Code
	caption.TextSize = 10
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
	paintCaret()
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

function Prompt.applyTheme()
	local palette = Themes.palette()
	local row = runtime.row
	if row then
		row.BackgroundColor3 = palette.background
	end
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
	local menu = runtime.menu
	if menu then
		menu.BackgroundColor3 = palette.background
		local stroke = menu:FindFirstChildOfClass("UIStroke")
		if stroke then
			stroke.Color = palette.rule
		end
	end
	-- Repainted through the renderer rather than field by field: the hover
	-- decides half of these colours, and only one function knows which row has
	-- it.
	if isMenuOpen() then
		renderMenu()
	end
	paintCaret()
end

return Prompt
