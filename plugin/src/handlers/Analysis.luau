--!strict
--[[
	Feeds the server's Luau check into Studio's own Script Analysis.

	The server checks synced scripts with luau-lsp and sends what Studio would
	not show itself (type errors in scripts that are not --!strict, deprecated
	API). Each entry carries the text it was checked against: once the script
	is edited past that, the entry is stale and shows nothing until the next
	check, so a diagnostic never points at the wrong line.

	The callback is registered on first use only, and re-registered after each
	update: deregistering makes Studio rerun Script Analysis on open scripts.
]]

local ScriptEditorService = game:GetService("ScriptEditorService")

local Dispatch = require(script.Parent.Parent.Dispatch)
local Paths = require(script.Parent.Parent.Paths)

local Analysis = {}

local NAME = "rbx-studio-mcp"
local PRIORITY = 100

type Entry = { source: string, diagnostics: { any } }

local entries: { [Instance]: Entry } = setmetatable({}, { __mode = "k" }) :: any
local registered = false
local refreshQueued = false

local function normalise(text: string): string
	return (text:gsub("\r\n?", "\n"))
end

local function severityOf(name: any): Enum.Severity
	if name == "Error" then
		return Enum.Severity.Error
	elseif name == "Information" then
		return Enum.Severity.Information
	elseif name == "Hint" then
		return Enum.Severity.Hint
	end
	return Enum.Severity.Warning
end

local function respond(request: { [string]: any }?): { [string]: any }
	local target = request and request.script
	local entry = if target then entries[target] else nil
	if not entry then
		return { diagnostics = {} }
	end
	local ok, current = pcall(ScriptEditorService.GetEditorSource, ScriptEditorService, target)
	if not ok or normalise(current) ~= entry.source then
		return { diagnostics = {} }
	end
	return { diagnostics = entry.diagnostics }
end

local function register()
	if registered then
		pcall(ScriptEditorService.DeregisterScriptAnalysisCallback, ScriptEditorService, NAME)
		registered = false
	end
	if next(entries) == nil then
		return
	end
	registered = pcall(ScriptEditorService.RegisterScriptAnalysisCallback, ScriptEditorService, NAME, PRIORITY, respond)
end

-- Several publishes in a row cost one rerun.
local function refresh()
	if refreshQueued then
		return
	end
	refreshQueued = true
	task.defer(function()
		refreshQueued = false
		register()
	end)
end

local function convert(raw: { [string]: any }): { [string]: any }?
	local line = tonumber(raw.line)
	local col = tonumber(raw.col)
	if not line or not col then
		return nil
	end
	local endCol = tonumber(raw.endCol) or col
	-- Studio reads these 1-based, like its own entries "(3, 1)"; the end is exclusive.
	local diagnostic: { [string]: any } = {
		range = {
			start = { line = line, character = col },
			["end"] = { line = line, character = endCol + 1 },
		},
		code = if raw.code then "MCP " .. tostring(raw.code) else "MCP",
		message = tostring(raw.message or ""),
		severity = severityOf(raw.severity),
	}
	if typeof(raw.href) == "string" and raw.href:match("^https://create%.roblox%.com/") then
		diagnostic.codeDescription = { href = raw.href }
	end
	return diagnostic
end

function Analysis.publish(params: { [string]: any }): { [string]: any }
	local shown, missing = 0, {}
	for _, item in (if typeof(params.items) == "table" then params.items else {}) :: { any } do
		local ok, target = pcall(Paths.resolve, tostring(item.path))
		if not ok or not target:IsA("LuaSourceContainer") then
			table.insert(missing, item.path)
			continue
		end
		local diagnostics = {}
		for _, raw in (if typeof(item.diagnostics) == "table" then item.diagnostics else {}) :: { any } do
			local d = convert(raw)
			if d then
				table.insert(diagnostics, d)
			end
		end
		if #diagnostics == 0 then
			entries[target] = nil
		else
			entries[target] = { source = normalise(tostring(item.source or "")), diagnostics = diagnostics }
			shown += #diagnostics
		end
	end
	refresh()
	return { shown = shown, missing = missing }
end

function Analysis.clear(_params: { [string]: any }): { [string]: any }
	table.clear(entries)
	refresh()
	return { cleared = true }
end

function Analysis.stop()
	table.clear(entries)
	if registered then
		pcall(ScriptEditorService.DeregisterScriptAnalysisCallback, ScriptEditorService, NAME)
		registered = false
	end
end

function Analysis.register()
	Dispatch.registerAll("analysis", {
		publish = Analysis.publish,
		clear = Analysis.clear,
	})
end

return Analysis
