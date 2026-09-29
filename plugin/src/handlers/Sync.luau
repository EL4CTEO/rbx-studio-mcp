--!strict
--[[
	The Studio half of `sync`: scripts mirrored to files on disk, and instance
	trees exported to build files and rebuilt from them.

	Everything that decides WHAT to sync lives in the server, which can see the
	disk. This side answers four questions and carries out one kind of order:

	  scan     which scripts exist, where, and at what revision
	  read     their source
	  changes  what changed since the last time anyone asked (for `watch`)
	  export   an instance tree as the same spec `create` takes

	  apply    write, create, delete and move scripts, each item checked against
	           the revision the server last saw, so nothing the user changed in
	           the meantime is overwritten
	  build    replace an instance tree from a spec, keeping its scripts

	Revisions are `ScriptEdit.fingerprint`, the same `rev` script_read hands out,
	so a sync and an agent editing through the script tools agree on what
	"unchanged" means.
]]

local ScriptEditorService = game:GetService("ScriptEditorService")
local HttpService = game:GetService("HttpService")
local CollectionService = game:GetService("CollectionService")

local Dispatch = require(script.Parent.Parent.Dispatch)
local Paths = require(script.Parent.Parent.Paths)
local Scope = require(script.Parent.Parent.Scope)
local ScriptEdit = require(script.Parent.Parent.ScriptEdit)
local Serialize = require(script.Parent.Parent.Serialize)
local Undo = require(script.Parent.Parent.Undo)
local Instances = require(script.Parent.Instances)

local Sync = {}

-- Past this, a place is better synced a service at a time: every scan reads
-- and fingerprints every script's buffer on Studio's main thread.
local MAX_SCRIPTS = 5_000

-- Where scripts are looked for by default. `Players` is left out on purpose:
-- in edit it is empty, and in a playtest its scripts are copies the engine
-- made from StarterPlayer, which would sync back as duplicates.
local DEFAULT_ROOTS = {
	"Workspace",
	"ReplicatedFirst",
	"ReplicatedStorage",
	"ServerScriptService",
	"ServerStorage",
	"StarterGui",
	"StarterPack",
	"StarterPlayer",
	"SoundService",
	"Lighting",
	"Teams",
	"Chat",
	"TextChatService",
	"TestService",
}

-- The panel's own `copy` output. A log, not code, and it is rewritten on every
-- `copy`, so syncing it would only ever produce noise on disk.
local IGNORED_NAMES = {
	["rbx-studio log"] = true,
}

-- Same limit as `script_create`: past it `.Source` refuses and only the editor
-- path takes the text.
local SOURCE_PROPERTY_LIMIT = 200_000

export type Logger = (level: string, message: string, detail: string?) -> ()
local log: Logger = function() end

--[[
	Hands in the panel's logger. A handler requiring the console would pull the
	whole widget into every test harness that loads this file.
]]
function Sync.setup(logger: Logger)
	log = logger
end

local function isScript(instance: Instance): boolean
	return instance:IsA("LuaSourceContainer")
end

local function rootsOf(params: { [string]: any }): { Instance }
	local wanted = params.roots
	local roots: { Instance } = {}
	if typeof(wanted) == "table" and #wanted > 0 then
		for _, path in wanted do
			table.insert(roots, Paths.resolve(tostring(path)))
		end
		return roots
	end
	for _, name in DEFAULT_ROOTS do
		local service = game:FindFirstChild(name)
		if service ~= nil then
			table.insert(roots, service)
		end
	end
	return roots
end

--[[
	Whether Studio's own Script Sync already binds this script to a file.

	Two syncs writing the same script is a race neither can see, so such scripts
	are reported and left alone. Silent when the service is unavailable.
]]
local function fileSynced(target: Instance): boolean
	local service = game:FindService("InstanceFileSyncService")
	if service == nil then
		return false
	end
	local ok, status = pcall(function()
		return (service :: any):GetStatus(target)
	end)
	if not ok or status == nil then
		return false
	end
	local name = tostring(status)
	return not (string.find(name, "NotSynced") or string.find(name, "Unknown") or name == "nil")
end


-- Scripts under the roots, in a fixed order (see `stableOrder` in Discover).
local function collect(roots: { Instance }): { LuaSourceContainer }
	local found: { LuaSourceContainer } = {}
	local seen: { [Instance]: boolean } = {}
	local function consider(instance: Instance)
		if seen[instance] or not isScript(instance) or IGNORED_NAMES[instance.Name] then
			return
		end
		if Scope.isNoisy(instance) then
			return
		end
		seen[instance] = true
		table.insert(found, instance :: LuaSourceContainer)
	end
	for _, root in roots do
		consider(root)
		for _, descendant in root:GetDescendants() do
			consider(descendant)
		end
	end
	if #found > MAX_SCRIPTS then
		Dispatch.fail(
			"TOO_BROAD",
			string.format("%d scripts, over the %d a sync handles at once.", #found, MAX_SCRIPTS),
			"Pass `roots` to sync a few services or folders at a time."
		)
	end
	local keys: { [Instance]: string } = {}
	for _, target in found do
		local ok, id = pcall(function()
			return target:GetDebugId()
		end)
		keys[target] = target:GetFullName() .. "\0" .. (if ok then id else "")
	end
	table.sort(found, function(a: Instance, b: Instance): boolean
		return keys[a] < keys[b]
	end)
	return found
end

--[[
	Every script under the roots: where it is, what it is, and -- unless the
	caller only wants the shape -- its revision.

	The server lays files out by the chain of instances above each script, and
	needs to know which links are scripts themselves (a script with scripts
	inside becomes a folder with an `init` file). That chain is shared by every
	script in a folder, so it comes back once, as `nodes`: each instance on any
	chain, with its parent's position in the same list (0 for the DataModel)
	and its sibling ordinal when its name is not unique. Scripts point into it.
]]
function Sync.scan(params: { [string]: any }): { [string]: any }
	local withRevisions = params.revisions ~= false
	local memo: Paths.NameIndex = {}
	local nodes: { { [string]: any } } = {}
	local indexOf: { [Instance]: number } = {}

	local function nodeOf(instance: Instance): number
		if instance == game then
			return 0
		end
		local known = indexOf[instance]
		if known ~= nil then
			return known
		end
		local parent = nodeOf(instance.Parent :: Instance)
		table.insert(nodes, {
			path = Paths.of(instance, memo),
			name = instance.Name,
			className = instance.ClassName,
			parent = parent,
			ordinal = Paths.ordinal(instance, memo),
		})
		indexOf[instance] = #nodes
		return #nodes
	end

	local items: { { [string]: any } } = {}
	for _, target in collect(rootsOf(params)) do
		table.insert(items, {
			node = nodeOf(target),
			revision = if withRevisions then ScriptEdit.revisionOf(target) else nil,
			fileSynced = if fileSynced(target) then true else nil,
		})
	end
	local roots: { string } = {}
	for _, root in rootsOf(params) do
		table.insert(roots, Paths.of(root, memo))
	end
	return { nodes = nodes, items = items, roots = roots }
end

--[[
	Every synced script's path, one string. `watch` compares it every few
	seconds to notice what no event reports -- a folder renamed moves every
	script inside it -- without reading or fingerprinting a single script.
]]
function Sync.shape(params: { [string]: any }): { [string]: any }
	local memo: Paths.NameIndex = {}
	local paths: { string } = {}
	for _, target in collect(rootsOf(params)) do
		table.insert(paths, Paths.of(target, memo))
	end
	return { shape = table.concat(paths, "\n") }
end

-- Declared ahead of `revisions`, which needs it.
local scriptAt: (path: string) -> LuaSourceContainer

--[[
	Revisions only, for `watch` to tell a real Studio edit from the echo of a
	write it made itself -- without shipping any source back.
]]
function Sync.revisions(params: { [string]: any }): { [string]: any }
	local items: { { [string]: any } } = {}
	for _, path in (if typeof(params.paths) == "table" then params.paths else {}) :: { any } do
		local ok, revision = pcall(function()
			return ScriptEdit.revisionOf(scriptAt(tostring(path)))
		end)
		table.insert(items, if ok then { path = path, revision = revision } else { path = path, missing = true })
	end
	return { items = items }
end

-- Resolves a path and insists it is a script, or explains why not.
function scriptAt(path: string): LuaSourceContainer
	local instance = Paths.resolve(path)
	if not isScript(instance) then
		Dispatch.fail("NOT_A_SCRIPT", string.format("%s is a %s, not a script.", path, instance.ClassName))
	end
	return instance :: LuaSourceContainer
end

local function reasonOf(err: any): (string, string)
	if typeof(err) == "table" then
		return tostring(err.code or "FAILED"), tostring(err.message)
	end
	return "FAILED", tostring(err)
end

-- Source and revision of each path. Per path, so one missing script does not
-- sink a read of three hundred.
function Sync.read(params: { [string]: any }): { [string]: any }
	local paths = params.paths
	if typeof(paths) ~= "table" then
		Dispatch.fail("BAD_PARAMS", "sync.read requires `paths`.")
	end
	local items: { { [string]: any } } = {}
	for _, path in paths do
		local ok, result = pcall(function()
			local target = scriptAt(tostring(path))
			local source = ScriptEdit.read(target)
			return { path = path, source = source, revision = ScriptEdit.revisionOf(target, source), className = target.ClassName }
		end)
		if ok then
			table.insert(items, result)
		else
			local code, message = reasonOf(result)
			table.insert(items, { path = path, code = code, message = message })
		end
	end
	return { items = items }
end

--[[
	Walks a chain of names from the DataModel, creating what is missing.

	By name rather than through `Paths.resolve`: the chain comes from a folder
	on disk, which knows names and nothing about sibling indexes. Missing links
	become the class the chain asks for -- a Folder, unless the file says the
	link is a script -- and a missing SERVICE is refused, since that is a
	misspelled top-level folder, not something to invent.
]]
local function ensureChain(start: any, chain: { { [string]: any } }, create: boolean): Instance?
	local current: Instance = if typeof(start) == "string" and start ~= "" then Paths.resolve(start) else game
	for index, link in chain do
		local name = tostring(link.name)
		local child = current:FindFirstChild(name)
		if child == nil then
			if current == game then
				local ok, service = pcall(function()
					return game:GetService(name)
				end)
				if ok and service ~= nil then
					child = service
				else
					Dispatch.fail(
						"UNKNOWN_SERVICE",
						string.format('"%s" is not a service.', name),
						"Top-level folders in the sync folder are service names, e.g. ServerScriptService."
					)
				end
			elseif not create then
				return nil
			else
				local className = if typeof(link.className) == "string" then link.className else "Folder"
				local made = Instance.new(className)
				made.Name = name
				made.Parent = current
				child = made
			end
		end
		current = child :: Instance
	end
	return current
end

-- Refuses unless `target` is still at the revision the server last saw.
local function assertRevision(target: LuaSourceContainer, revision: any)
	if typeof(revision) ~= "string" then
		return
	end
	local live = ScriptEdit.revisionOf(target)
	if live ~= revision then
		Dispatch.fail("STALE_SCRIPT", string.format("changed in Studio since the last sync (now %s)", live))
	end
end

--[[
	Carries out one batch of the server's decisions.

	Structural changes -- creates, deletes, moves -- share one undo step, "MCP
	sync", so a sync that put files where they should not be is one Ctrl+Z.
	Source writes go through the script editor after that, with its own
	per-script undo, exactly like `script_edit`.

	Every item is checked against the revision the server based its decision
	on, and fails alone: a sync is many independent files, and one the user
	touched a second ago must not hold the other forty back. Each item reports
	what happened, and the new revision where there is one.
]]
function Sync.apply(params: { [string]: any }): { [string]: any }
	local writes = if typeof(params.writes) == "table" then params.writes else {}
	local creates = if typeof(params.creates) == "table" then params.creates else {}
	local deletes = if typeof(params.deletes) == "table" then params.deletes else {}
	local moves = if typeof(params.moves) == "table" then params.moves else {}

	local results = { writes = {}, creates = {}, deletes = {}, moves = {} }
	type Late = { target: LuaSourceContainer, source: string, result: { [string]: any } }
	local late: { Late } = {}

	local structural = #creates + #deletes + #moves > 0
	local recorded = false
	if structural then
		local _, didRecord = Undo.recordPartial("StudioMCP.Sync", "MCP sync", function()
			for _, item in creates do
				local ok, err = pcall(function()
					local parent = ensureChain(item.parentPath, item.parents or {}, true) :: Instance
					local name = tostring(item.name)
					local existing = parent:FindFirstChild(name)
					if existing ~= nil and isScript(existing) then
						Dispatch.fail("EXISTS", string.format("%s already has a script named %s", parent:GetFullName(), name))
					end
					local made = Instance.new(item.className) :: LuaSourceContainer
					made.Name = name
					local source = if typeof(item.source) == "string" then item.source else ""
					local result: { [string]: any } = { ok = true }
					if #source < SOURCE_PROPERTY_LIMIT then
						(made :: ScriptEdit.SourceContainer).Source = source
					else
						table.insert(late, { target = made, source = source, result = result })
					end
					made.Parent = parent
					result.path = Paths.of(made)
					result.revision = ScriptEdit.revisionOf(made, if #source < SOURCE_PROPERTY_LIMIT then source else "")
					return result
				end)
				if ok then
					table.insert(results.creates, err)
				else
					local code, message = reasonOf(err)
					table.insert(results.creates, { ok = false, code = code, message = message })
				end
			end

			for _, item in deletes do
				local ok, err = pcall(function()
					local target = scriptAt(tostring(item.path))
					assertRevision(target, item.revision)
					target:Destroy()
				end)
				if ok then
					table.insert(results.deletes, { ok = true, path = item.path })
				else
					local code, message = reasonOf(err)
					table.insert(results.deletes, { ok = false, path = item.path, code = code, message = message })
				end
			end

			for _, item in moves do
				local ok, err = pcall(function()
					local target = scriptAt(tostring(item.path))
					assertRevision(target, item.revision)
					local parent = ensureChain(item.parentPath, item.parents or {}, true) :: Instance
					target.Name = tostring(item.name)
					target.Parent = parent
					return Paths.of(target)
				end)
				if ok then
					table.insert(results.moves, { ok = true, from = item.path, path = err })
				else
					local code, message = reasonOf(err)
					table.insert(results.moves, { ok = false, from = item.path, code = code, message = message })
				end
			end
			return true
		end)
		recorded = didRecord
	end

	-- Sources too long for `.Source`, written now that the scripts exist.
	for _, entry in late do
		local ok, err = pcall(function()
			Undo.exclusive(function()
				ScriptEdit.write(entry.target, function(current)
					if current ~= "" then
						Dispatch.fail("STALE_SCRIPT", "edited before its source could be written; that text was kept")
					end
					return entry.source
				end)
			end)
		end)
		if ok then
			entry.result.revision = ScriptEdit.revisionOf(entry.target)
		else
			local code, message = reasonOf(err)
			entry.result.ok = false
			entry.result.code = code
			entry.result.message = "created, but the source was not written: " .. message
		end
	end

	if #writes > 0 then
		Undo.exclusive(function()
			for _, item in writes do
				local ok, err = pcall(function()
					local target = scriptAt(tostring(item.path))
					local source = tostring(item.source)
					-- Checked inside the editor's callback: the text the write
					-- replaces is the text the check saw.
					ScriptEdit.write(target, function(current)
						if typeof(item.revision) == "string" and ScriptEdit.revisionOf(target, current) ~= item.revision then
							Dispatch.fail("STALE_SCRIPT", "changed in Studio since the last sync; that text was kept")
						end
						return source
					end)
					return ScriptEdit.revisionOf(target)
				end)
				if ok then
					table.insert(results.writes, { ok = true, path = item.path, revision = err })
				else
					local code, message = reasonOf(err)
					table.insert(results.writes, { ok = false, path = item.path, code = code, message = message })
				end
			end
			return true
		end)
	end

	local counts = {}
	for _, kind in { "writes", "creates", "deletes", "moves" } do
		local done = 0
		for _, result in (results :: any)[kind] do
			if result.ok then
				done += 1
			end
		end
		if done > 0 then
			table.insert(counts, string.format("%d %s", done, kind))
		end
	end
	if #counts > 0 then
		log("ok", "sync from files: " .. table.concat(counts, ", "), if recorded then "one undo step" else nil)
	end

	return {
		writes = results.writes,
		creates = results.creates,
		deletes = results.deletes,
		moves = results.moves,
		undoStep = if recorded then "MCP sync" else nil,
	}
end

-- Change tracking, for `watch` ----------------------------------------------

--[[
	What changed since the server last asked, so `watch` does not fingerprint
	every script in the place twice a second.

	Edits in the script editor arrive through `TextDocumentDidChange`, and every
	other write to `Source` through the property signal. Scripts appearing,
	disappearing or being renamed mark the whole shape as changed, and the
	server rescans. Renaming a FOLDER changes script paths with no event on the
	scripts at all, which is why the server also rescans the shape on a slow
	timer rather than trusting this alone.

	Only runs while someone is asking: tracking starts on the first `changes`
	call and stops by itself once nobody has asked for a minute, so a watch
	that ended with its process leaves nothing connected behind.
]]
type Tracker = {
	token: string,
	dirty: { [Instance]: boolean },
	structural: boolean,
	connections: { RBXScriptConnection },
	watched: { [Instance]: boolean },
	lastPolled: number,
}
local tracker: Tracker? = nil
local IDLE_STOP = 60

local function stopTracking()
	local current = tracker
	if current == nil then
		return
	end
	for _, connection in current.connections do
		connection:Disconnect()
	end
	tracker = nil
end

local function watchScript(current: Tracker, instance: Instance)
	if current.watched[instance] or not isScript(instance) then
		return
	end
	current.watched[instance] = true
	table.insert(current.connections, instance:GetPropertyChangedSignal("Source"):Connect(function()
		current.dirty[instance] = true
	end))
	table.insert(current.connections, instance:GetPropertyChangedSignal("Name"):Connect(function()
		current.structural = true
	end))
end

local function startTracking(): Tracker
	local current: Tracker = {
		token = HttpService:GenerateGUID(false),
		dirty = setmetatable({}, { __mode = "k" }) :: any,
		structural = false,
		connections = {},
		watched = setmetatable({}, { __mode = "k" }) :: any,
		lastPolled = os.clock(),
	}
	for _, root in rootsOf({}) do
		for _, descendant in root:GetDescendants() do
			watchScript(current, descendant)
		end
	end
	table.insert(current.connections, game.DescendantAdded:Connect(function(instance)
		if isScript(instance) then
			current.structural = true
			watchScript(current, instance)
		end
	end))
	table.insert(current.connections, game.DescendantRemoving:Connect(function(instance)
		if isScript(instance) then
			current.structural = true
		end
	end))
	pcall(function()
		table.insert(current.connections, ScriptEditorService.TextDocumentDidChange:Connect(function(document)
			local ok, target = pcall(function()
				return document:GetScript()
			end)
			if ok and target ~= nil then
				current.dirty[target] = true
			end
		end))
	end)
	tracker = current

	task.spawn(function()
		while tracker == current do
			task.wait(IDLE_STOP / 2)
			if tracker == current and os.clock() - current.lastPolled > IDLE_STOP then
				stopTracking()
			end
		end
	end)
	return current
end

--[[
	Returns what changed since the previous call, and forgets it.

	`token` names the tracking session. A token the server does not recognise
	-- the first call, or the plugin reloaded in between and lost everything it
	had noted -- comes back with `reset`, meaning "assume anything changed".
]]
function Sync.changes(params: { [string]: any }): { [string]: any }
	local current = tracker
	if current == nil or params.token ~= current.token then
		current = current or startTracking()
		current.lastPolled = os.clock()
		current.dirty = setmetatable({}, { __mode = "k" }) :: any
		current.structural = false
		return { token = current.token, reset = true, dirty = {}, structural = true }
	end
	current.lastPolled = os.clock()

	local dirty: { string } = {}
	local memo: Paths.NameIndex = {}
	for instance in current.dirty do
		if instance.Parent ~= nil and not Scope.isNoisy(instance) then
			table.insert(dirty, Paths.of(instance, memo))
		end
	end
	local structural = current.structural
	current.dirty = setmetatable({}, { __mode = "k" }) :: any
	current.structural = false
	return { token = current.token, reset = false, dirty = dirty, structural = structural }
end

function Sync.stop(_params: { [string]: any }): { [string]: any }
	stopTracking()
	return { stopped = true }
end

-- A line in the panel for work the server did that Studio cannot see, like
-- files written to disk. Quiet: logging the call as well would say it twice.
function Sync.log(params: { [string]: any }): { [string]: any }
	local lines = params.lines
	if typeof(lines) == "table" then
		for _, line in lines do
			if typeof(line) == "table" and typeof(line.message) == "string" then
				log(
					if typeof(line.level) == "string" then line.level else "dim",
					line.message,
					if typeof(line.detail) == "string" then line.detail else nil
				)
			end
		end
	end
	return { logged = true }
end

-- Build files ---------------------------------------------------------------

-- Attribute types `create` can write back; the list its schema accepts.
local ATTRIBUTE_TYPES: { [string]: boolean } = {
	BrickColor = true,
	CFrame = true,
	Color3 = true,
	ColorSequence = true,
	Font = true,
	NumberRange = true,
	NumberSequence = true,
	Rect = true,
	UDim = true,
	UDim2 = true,
	Vector2 = true,
	Vector3 = true,
}

-- Classes in a subtree other than scripts, so the server can say which of their
-- properties are worth exporting.
function Sync.classes(params: { [string]: any }): { [string]: any }
	local root = Paths.resolve(tostring(params.path))
	if isScript(root) then
		Dispatch.fail("IS_A_SCRIPT", "Scripts sync as files; export the instance tree that holds them.")
	end
	local seen: { [string]: boolean } = { [root.ClassName] = true }
	for _, descendant in root:GetDescendants() do
		if not isScript(descendant) then
			seen[descendant.ClassName] = true
		end
	end
	local classes: { string } = {}
	for name in seen do
		table.insert(classes, name)
	end
	table.sort(classes)
	-- The chain above the root, so the server can place the build file beside
	-- the synced scripts of the same tree.
	local chain: { { [string]: any } } = {}
	local link: Instance? = root
	while link ~= nil and link ~= game do
		table.insert(chain, 1, {
			name = (link :: Instance).Name,
			className = (link :: Instance).ClassName,
			path = Paths.of(link :: Instance),
			ordinal = Paths.ordinal(link :: Instance),
		})
		link = (link :: Instance).Parent
	end
	return { path = Paths.of(root), classes = classes, chain = chain }
end

--[[
	An instance tree as the spec `create` takes: class, name, and every
	property that differs from a fresh instance of the class.

	Differs, because a build file is read and edited by people and agents:
	three hundred default values per frame would bury the eight that make it
	that frame. Each exported value is also parsed back before it is kept, so
	a build file never contains something the build could not apply --
	anything that does not survive is listed in `skipped` instead.

	Scripts are not exported. They live in the sync folder as files, and a
	rebuild carries the existing ones over (see `build`).
]]
function Sync.export(params: { [string]: any }): { [string]: any }
	local root = Paths.resolve(tostring(params.path))
	local propertyLists = if typeof(params.properties) == "table" then params.properties else {}
	local defaults: { [string]: Instance | false } = {}
	local skipped: { string } = {}
	local scripts = 0
	local count = 0

	local function defaultOf(className: string): Instance?
		local cached = defaults[className]
		if cached == nil then
			local ok, made = pcall(Instance.new, className)
			cached = if ok then made else false
			defaults[className] = cached
		end
		return if cached then cached :: Instance else nil
	end

	local function describe(instance: Instance, depth: number): { [string]: any }?
		if isScript(instance) then
			scripts += 1
			return nil
		end
		count += 1
		local spec: { [string]: any } = { className = instance.ClassName, name = instance.Name }
		local default = defaultOf(instance.ClassName)
		local properties: { [string]: any } = {}
		local any = false
		for _, entry in (propertyLists[instance.ClassName] or {}) :: { any } do
			local name = tostring(entry.name)
			local okRead, value = pcall(function()
				return (instance :: any)[name]
			end)
			if not okRead then
				continue
			end
			if default ~= nil then
				local okDefault, fallback = pcall(function()
					return (default :: any)[name]
				end)
				if okDefault and fallback == value then
					continue
				end
			end
			local text = Serialize.value(value)
			if typeof(text) == "table" or text == nil then
				table.insert(skipped, string.format("%s.%s", instance:GetFullName(), name))
				continue
			end
			local parsed = Serialize.parse(text, tostring(entry.type))
			if not parsed then
				table.insert(skipped, string.format("%s.%s", instance:GetFullName(), name))
				continue
			end
			properties[name] = text
			any = true
		end
		if any then
			spec.properties = properties
		end

		local attributes = instance:GetAttributes()
		if next(attributes) ~= nil then
			local exported: { [string]: any } = {}
			local anyAttribute = false
			for name, value in attributes do
				local kind = typeof(value)
				if kind == "string" or kind == "number" or kind == "boolean" then
					exported[name] = value
					anyAttribute = true
				elseif ATTRIBUTE_TYPES[kind] then
					exported[name] = { type = kind, value = Serialize.value(value) }
					anyAttribute = true
				else
					-- `create` cannot type it, and one unreadable value would
					-- stop the whole file from building.
					table.insert(skipped, string.format("%s@%s (%s)", instance:GetFullName(), name, kind))
				end
			end
			if anyAttribute then
				spec.attributes = exported
			end
		end

		local tags = CollectionService:GetTags(instance)
		if #tags > 0 then
			table.sort(tags)
			spec.tags = { add = tags }
		end

		local children: { { [string]: any } } = {}
		for _, child in instance:GetChildren() do
			local described = describe(child, depth + 1)
			if described ~= nil then
				table.insert(children, described)
			end
		end
		if #children > 0 then
			-- By name, then class: a stable file, so an export of an unchanged
			-- tree is byte-identical and shows up as nothing changed.
			table.sort(children, function(a, b)
				if a.name ~= b.name then
					return a.name < b.name
				end
				return a.className < b.className
			end)
			spec.children = children
		end
		return spec
	end

	local spec = describe(root, 0)
	for _, default in defaults do
		if default then
			(default :: Instance):Destroy()
		end
	end
	if spec == nil then
		Dispatch.fail("IS_A_SCRIPT", "Scripts sync as files; export the instance tree that holds them.")
	end
	return { path = Paths.of(root), spec = spec, instances = count, scripts = scripts, skipped = skipped }
end

--[[
	Replaces an instance tree with a freshly built one, as one undo step.

	The old tree is renamed out of the way, the new one created in its place,
	and then the scripts are carried across: a build file holds no scripts
	(they sync as files), so rebuilding a ScreenGui must not delete the
	LocalScript that drives it. Each script goes back under the same chain of
	names it sat under, or under the new root when that chain no longer exists
	-- which is reported, since the script may now be looking in the wrong place.
]]
function Sync.build(params: { [string]: any }): { [string]: any }
	local spec = params.spec
	if typeof(spec) ~= "table" then
		Dispatch.fail("BAD_PARAMS", "sync.build requires a `spec`.")
	end
	local parent = Paths.resolve(tostring(params.parent))
	local name = tostring(spec.name or spec.className)

	local carried: { { [string]: any } } = {}
	local builtPath: string? = nil
	local _, recorded = Undo.record("StudioMCP.Build", "MCP build", function()
		-- The tree this file built last time, when its name changed in the file:
		-- renaming it there must replace that tree, not add a second one.
		local old: Instance? = nil
		if typeof(params.replaces) == "string" then
			local found, previous = pcall(Paths.resolve, params.replaces)
			if found and previous.Parent == parent then
				old = previous
			end
		end
		old = old or parent:FindFirstChild(name)
		if old ~= nil and isScript(old) then
			Dispatch.fail("IS_A_SCRIPT", string.format("%s is a script; build files hold instance trees.", old:GetFullName()))
		end
		if old ~= nil then
			old.Name = "__mcp_build_old"
		end

		local top = table.clone(spec) :: any
		top.parent = Paths.of(parent)
		local created = Instances.create({ instances = { top } })
		local fresh = parent:FindFirstChild(name)
		if fresh == nil then
			Dispatch.fail("BUILD_FAILED", "The new tree was not created.")
		end
		builtPath = (created.items[1] or {}).path

		if old ~= nil then
			local previous = old :: Instance
			for _, item in previous:GetDescendants() do
				local descendant = item :: Instance
				if not isScript(descendant) then
					continue
				end
				-- Only the outermost scripts: a script's own children move with it.
				local outer = true
				local above = descendant.Parent
				while above ~= nil and above ~= previous do
					if isScript(above) then
						outer = false
						break
					end
					above = above.Parent
				end
				if not outer then
					continue
				end

				local chain: { string } = {}
				local link = descendant.Parent
				while link ~= nil and link ~= previous do
					table.insert(chain, 1, link.Name)
					link = link.Parent
				end
				local destination: Instance = fresh :: Instance
				local exact = true
				for _, step in chain do
					local next = destination:FindFirstChild(step)
					if next == nil then
						exact = false
						break
					end
					destination = next
				end
				if not exact then
					destination = fresh :: Instance
				end
				descendant.Parent = destination
				table.insert(carried, { path = Paths.of(descendant), exact = exact })
			end
			previous:Destroy()
		end
		return true
	end)

	log("ok", string.format("built %s from a build file", builtPath or name), if recorded then "one undo step" else nil)
	return { path = builtPath, carried = carried, undoStep = if recorded then "MCP build" else nil }
end

function Sync.register()
	Dispatch.registerAll("sync", {
		scan = Sync.scan,
		shape = Sync.shape,
		revisions = Sync.revisions,
		read = Sync.read,
		apply = Sync.apply,
		changes = Sync.changes,
		stop = Sync.stop,
		log = Sync.log,
		classes = Sync.classes,
		export = Sync.export,
		build = Sync.build,
	})
end

return Sync
