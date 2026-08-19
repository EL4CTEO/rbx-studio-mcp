--!strict
--[[
	Studio MCP -- plugin entry point.

	Owns the toolbar UI, the persistent Studio identity, and the command loop.
	Handlers do the actual work; this file only wires them to the transport.
]]

local HttpService = game:GetService("HttpService")

local Config = require(script.Config)
local Dispatch = require(script.Dispatch)
local Transport = require(script.Transport)
local Session = require(script.handlers.Session)

local SETTING_STUDIO_ID = "studioId"
local SETTING_PORT = "port"
local SETTING_AUTOCONNECT = "autoConnect"

--[[
	A stable id per Studio installation, so reconnects and restarts map back to
	the same session rather than piling up ghost entries in list_studios.
]]
local function studioId(): string
	local existing = plugin:GetSetting(SETTING_STUDIO_ID)
	if typeof(existing) == "string" and existing ~= "" then
		return existing
	end
	local generated = HttpService:GenerateGUID(false)
	plugin:SetSetting(SETTING_STUDIO_ID, generated)
	return generated
end

local storedPort = plugin:GetSetting(SETTING_PORT)
if typeof(storedPort) == "number" then
	Config.setPort(storedPort)
end

Session.register()

local toolbar = plugin:CreateToolbar("Studio MCP")
local button = toolbar:CreateButton(
	"Studio MCP",
	"Connect this place to the Studio MCP server",
	"rbxasset://textures/ui/common/robux.png"
)
button.ClickableWhenViewportHidden = true

local widget = plugin:CreateDockWidgetPluginGuiAsync(
	"StudioMCP_Status",
	DockWidgetPluginGuiInfo.new(Enum.InitialDockState.Float, false, true, 320, 120, 260, 100)
)
widget.Title = "Studio MCP"

local background = Instance.new("Frame")
background.Size = UDim2.fromScale(1, 1)
background.BorderSizePixel = 0
background.Parent = widget

local padding = Instance.new("UIPadding")
padding.PaddingTop = UDim.new(0, 8)
padding.PaddingLeft = UDim.new(0, 10)
padding.PaddingRight = UDim.new(0, 10)
padding.Parent = background

local label = Instance.new("TextLabel")
label.Size = UDim2.fromScale(1, 1)
label.BackgroundTransparency = 1
label.TextWrapped = true
label.TextXAlignment = Enum.TextXAlignment.Left
label.TextYAlignment = Enum.TextYAlignment.Top
label.Font = Enum.Font.Code
label.TextSize = 13
label.Text = ""
label.Parent = background

-- Studio themes are user-switchable at runtime, so colours are read from the
-- theme on every render rather than baked in once.
local studioSettings = settings():GetService("Studio")

local currentStatus: Transport.Status = "disconnected"

--[[
	The widget is the only feedback channel a user has -- the plugin deliberately
	prints nothing to the output window, since that log is also what the agent
	reads through the `console` tool and plugin chatter would pollute it.
]]
local function render(detail: string?)
	local theme = (studioSettings :: any).Theme
	label.TextColor3 = theme:GetColor(Enum.StudioStyleGuideColor.MainText)
	background.BackgroundColor3 = theme:GetColor(Enum.StudioStyleGuideColor.MainBackground)

	local lines = {
		string.format("Status: %s", currentStatus),
		string.format("Port:   %d (%s)", Config.getPort(), Transport.getMode()),
	}
	if detail then
		table.insert(lines, "")
		table.insert(lines, detail)
	end
	label.Text = table.concat(lines, "\n")
	button:SetActive(currentStatus == "connected")
end

local function onStatus(status: Transport.Status, detail: string?)
	currentStatus = status
	render(detail)
end

--[[
	Runs each command on its own task. Handlers may yield -- `UpdateSourceAsync`
	and any `*Async` call does -- and serialising them would let one slow edit
	stall every other request on the stream.
]]
local function onCommand(id: string, op: string, params: { [string]: any }?)
	task.spawn(function()
		Transport.sendResult(Dispatch.invoke(id, op, params))
	end)
end

local function connect()
	Transport.start(studioId(), { onCommand = onCommand, onStatus = onStatus })
	plugin:SetSetting(SETTING_AUTOCONNECT, true)
end

local function disconnect()
	Transport.stop()
	plugin:SetSetting(SETTING_AUTOCONNECT, false)
	onStatus("disconnected", "Disconnected. Click the toolbar button to reconnect.")
end

button.Click:Connect(function()
	if Transport.isRunning() then
		disconnect()
	else
		widget.Enabled = true
		connect()
	end
end)

widget:GetPropertyChangedSignal("Enabled"):Connect(function()
	if widget.Enabled then
		render()
	end
end)

plugin.Unloading:Connect(function()
	Transport.stop()
end)

render()

-- Reconnect automatically unless the user explicitly disconnected last session.
if plugin:GetSetting(SETTING_AUTOCONNECT) ~= false then
	connect()
end
