--!strict
--[[
	Which of Studio's sessions this plugin copy is running in.

	Pressing play adds a second connection for the playtest's server, on the same
	place with the same name and the same id, so a listing shows two rows that
	look identical. Choosing wrongly is not a small mistake: instances created or
	changed in a play session are discarded the moment the user stops, so the work
	appears to succeed and then vanishes.

	Kept in its own module because two callers need it at different times. The
	status handler reports it on request, and the transport announces it in the
	handshake -- and the handshake matters more than it sounds, because the
	ambiguity error that forces the choice is raised before any status call could
	have filled it in.
]]

local RunService = game:GetService("RunService")

local Context = {}
local localId: string? = nil
local EDITOR_ATTRIBUTE = "_MCPTestEditor"
local TEST_ATTRIBUTE = "_MCPTestId"
local activeRestore: (() -> ())? = nil

function Context.cleanup()
	if activeRestore then pcall(activeRestore); activeRestore = nil end
end

function Context.setup(id: string)
	localId = id
end

function Context.editorId(): string?
	if RunService:IsEdit() then return localId end
	local value = game:GetAttribute(EDITOR_ATTRIBUTE)
	return if typeof(value) == "string" then value else nil
end

function Context.testId(): string?
	local value = game:GetAttribute(TEST_ATTRIBUTE)
	return if typeof(value) == "string" then value else nil
end

-- These attributes are copied into the test DataModel. They are temporary and
-- restored when Execute* returns, without changing the user's test arguments.
function Context.beginTest(id: string): () -> ()
	local beforeEditor, beforeTest = game:GetAttribute(EDITOR_ATTRIBUTE), game:GetAttribute(TEST_ATTRIBUTE)
	local ok, err = pcall(function()
		game:SetAttribute(EDITOR_ATTRIBUTE, localId)
		game:SetAttribute(TEST_ATTRIBUTE, id)
	end)
	if not ok then
		pcall(function() game:SetAttribute(EDITOR_ATTRIBUTE, beforeEditor); game:SetAttribute(TEST_ATTRIBUTE, beforeTest) end)
		error(err, 0)
	end
	local restore = function()
		if game:GetAttribute(TEST_ATTRIBUTE) == id then
			game:SetAttribute(EDITOR_ATTRIBUTE, beforeEditor)
			game:SetAttribute(TEST_ATTRIBUTE, beforeTest)
		end
	end
	activeRestore = restore
	return restore
end

function Context.of(): string
	if RunService:IsEdit() then
		return "edit"
	end
	if not RunService:IsRunning() then
		return "unknown"
	end
	if RunService:IsServer() and RunService:IsClient() then
		return "playtest (solo)"
	end
	return if RunService:IsServer() then "playtest server" else "playtest client"
end

return Context
