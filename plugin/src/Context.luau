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
