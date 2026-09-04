--!strict
--[[
	Carries console activity from a playtest's SERVER view to its CLIENT view.

	Pressing Play gives this plugin three lives: the editor's, the playtest
	server's, and the playtest client's. Studio shows whichever belongs to the
	view you are looking at, and it defaults to the client -- which is the one
	life that can do nothing. Roblox forbids HTTP from a client session, so that
	panel has no way to see the bridge, and it sat on a standby notice while the
	agent worked a few feet away in a view the user was not looking at.

	The two DataModels share no memory, no globals and no services. The only
	channel between them is the game's own replication, so that is what this
	uses: the server plugin puts a RemoteEvent in ReplicatedStorage and fires
	each console event across it; the client plugin listens and replays them
	into its own console. The prism reacts, the log fills, and the view the user
	actually has open stops lying about what is happening.

	The cost is honest and worth stating: this plugin writes one instance into
	the running game. It is `Archivable = false` so it can never be saved with
	the place, it exists only while a playtest is running, and it goes when the
	playtest's DataModel does. Nothing reads it but the client half of this
	plugin, and nothing is sent up from the client -- the traffic is one-way, so
	a game's own scripts cannot use it to reach the editor.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

--[[
	Named to be recognised in the Explorer rather than to be hidden.

	Someone will see this appear in ReplicatedStorage mid-playtest and want to
	know what put it there; a cryptic name turns that into a hunt. The prefix is
	unlikely enough to collide with a real game's instances.
]]
local CHANNEL = "__rbxStudioMcpMirror"

local Mirror = {}

local remote: RemoteEvent? = nil

--[[
	Held shut until the server session has finished introducing itself.

	Both halves of a playtest log their own banner, place and status, so a
	channel that is open from the start delivers the server's copy of all of it
	to a client that has already written its own -- the panel comes up saying
	"rbx-studio v0.3.6" and "place: Game" twice, a line apart, which reads as a
	glitch because it is one.

	Opened on the server's "connected" row rather than after a fixed wait: that
	is the exact point where its startup ends and the session's real activity
	begins, and everything after it is news the client does not already have.
]]
local open = false

function Mirror.open()
	open = true
end

--[[
	True only in the half of a playtest that can reach the bridge.

	`IsRunning` separates a playtest from the editor, and `IsServer` separates
	the two halves of it. The editor session must not do any of this: it has no
	playtest to mirror and writing to its ReplicatedStorage would put the
	instance in the user's actual place.
]]
function Mirror.isPlaytestServer(): boolean
	return RunService:IsRunning() and RunService:IsServer()
end

function Mirror.isPlaytestClient(): boolean
	return RunService:IsRunning() and RunService:IsClient()
end

--[[
	Opens the channel from the playtest server.

	A leftover from an earlier test in the same DataModel is replaced rather
	than reused: reusing one whose connections are gone looks like a working
	channel that silently delivers nothing.
]]
function Mirror.startServer()
	if not Mirror.isPlaytestServer() then
		return
	end
	local existing = ReplicatedStorage:FindFirstChild(CHANNEL)
	if existing ~= nil then
		existing:Destroy()
	end
	local event = Instance.new("RemoteEvent")
	event.Name = CHANNEL
	-- Never saved with the place, whatever the user does while the test runs.
	event.Archivable = false
	event.Parent = ReplicatedStorage
	remote = event
end

--[[
	Sends one console event, and never fails loudly.

	This is decoration on top of the console. A replication error here must not
	take down the call it was reporting on, so every send is guarded and a dead
	channel simply stops mirroring.
]]
function Mirror.send(kind: string, arguments: { any })
	local event = remote
	if event == nil or not open then
		return
	end
	pcall(function()
		event:FireAllClients(kind, arguments)
	end)
end

--[[
	Listens on the playtest client.

	`WaitForChild` with a timeout rather than an indefinite wait: if the server
	half never opens the channel the client should go quiet, not hang a thread
	for the length of the playtest.
]]
function Mirror.startClient(onMessage: (string, { any }) -> ())
	if not Mirror.isPlaytestClient() then
		return
	end
	task.spawn(function()
		local event = ReplicatedStorage:WaitForChild(CHANNEL, 30)
		if event == nil or not event:IsA("RemoteEvent") then
			return
		end
		event.OnClientEvent:Connect(function(kind, arguments)
			-- Shape-checked because anything on the wire can be forged by a
			-- script in the place being tested. Nothing here is trusted enough
			-- to index without looking.
			if typeof(kind) == "string" and typeof(arguments) == "table" then
				onMessage(kind, arguments :: { any })
			end
		end)
	end)
end

return Mirror
