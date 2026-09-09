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

	History and completion are the two things that separate a prompt from a text
	box, so both are here. Keyboard input inside a plugin widget is delivered to
	the GuiObjects themselves rather than through UserInputService, which is why
	the arrows and Tab are read off the field's own InputBegan.
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

type Runtime = {
	row: Frame?,
	caret: TextLabel?,
	field: TextBox?,
	hint: TextLabel?,
	rule: Frame?,
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
	-- What was being typed before the arrows took the field over, so coming back
	-- down from the history returns it rather than an empty line.
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
	submit: ((string) -> ())?,
}

local runtime: Runtime = {
	row = nil,
	caret = nil,
	field = nil,
	hint = nil,
	rule = nil,
	history = {},
	offset = 0,
	draft = "",
	busy = false,
	selection = "",
	complete = nil,
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
	The greyed-out remainder of the command being typed.

	Drawn as a separate label positioned after the text rather than inside the
	field, because a TextBox that writes its own guess into itself has to undo
	that on every keystroke and gets it wrong the moment the user types fast.
	This only ever suggests; Tab is what accepts.
]]
local function showHint()
	local field = runtime.field
	local hint = runtime.hint
	local complete = runtime.complete
	if field == nil or hint == nil or complete == nil then
		return
	end

	--[[
		One slot, two things to say, and typing wins.

		The completion is about the keystroke happening right now; the selection
		is standing context. Giving them separate slots would put two competing
		readouts on one 30-pixel row, so they share it and the more urgent one
		takes it.
	]]
	local typed = field.Text
	-- Only the first word completes. Everything after it is an argument, and
	-- guessing at arguments is how a prompt starts fighting the person using it.
	if typed ~= "" and string.find(typed, "%s") == nil then
		local matches = complete(typed)
		if #matches == 1 and matches[1] ~= typed then
			hint.Text = string.format("%s   tab", matches[1])
			return
		elseif #matches > 1 then
			hint.Text = table.concat(matches, " ")
			return
		end
	end

	hint.Text = runtime.selection
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
	Accepts the suggestion, when there is exactly one.

	Several matches print themselves in the hint and do nothing, which is what
	every shell does: completing to a common prefix saves a keystroke and costs
	the user the list they were about to read.
]]
local function acceptHint()
	local field = runtime.field
	local complete = runtime.complete
	if field == nil or complete == nil or field.Text == "" then
		return
	end
	local matches = complete(field.Text)
	if #matches ~= 1 then
		return
	end
	field.Text = matches[1] .. " "
	field.CursorPosition = #field.Text + 1
	showHint()
end

--[[
	Builds the row. Called once from `Console.mount`, positioned by it.
]]
function Prompt.mount(parent: Instance, handlers: { submit: (string) -> (), complete: (string) -> { string } })
	local palette = Themes.palette()
	runtime.submit = handlers.submit
	runtime.complete = handlers.complete

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

	field:GetPropertyChangedSignal("Text"):Connect(function()
		-- Typing puts the user back on the live line. Without this, editing a
		-- recalled entry and pressing down would throw the edit away.
		if runtime.offset ~= 0 then
			runtime.offset = 0
			runtime.draft = ""
		end
		showHint()
	end)

	field.FocusLost:Connect(function(enterPressed)
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
		-- Re-focused on the next frame so a burst of commands can be typed
		-- without reaching for the mouse. Enter releases focus first, so this
		-- has to happen after Roblox is done taking it away.
		task.defer(function()
			if field.Parent ~= nil then
				field:CaptureFocus()
			end
		end)
	end)

	field.InputBegan:Connect(function(input)
		if input.UserInputType ~= Enum.UserInputType.Keyboard then
			return
		end
		if input.KeyCode == Enum.KeyCode.Up then
			recall(runtime.offset + 1)
		elseif input.KeyCode == Enum.KeyCode.Down then
			recall(runtime.offset - 1)
		elseif input.KeyCode == Enum.KeyCode.Tab then
			acceptHint()
		end
	end)
end

--[[
	Puts the cursor in the field, for the toolbar button and for `help`.

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
	Whether an agent started from this prompt is still working.

	Read by the console before it announces a silence. The flag lives here
	because the caret is what displays it, and one owner beats two that have to
	be kept in step.
]]
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
	paintCaret()
end

return Prompt
