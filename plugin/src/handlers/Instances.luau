--!strict
--[[
	Creating, changing, moving and deleting instances.

	Every operation here is a batch wrapped in one ChangeHistoryService recording.
	Unlike script source -- where a recording turns out not to cover the change at
	all -- instance edits are genuinely captured, so a failed batch really does
	roll back and a successful one really is a single Ctrl+Z. The response says
	which of those happened rather than assuming.

	Property values arrive as text with the target type resolved from the live
	API dump on the server. That split matters: the plugin has no dump, and
	guessing a type from whatever the property currently holds fails on exactly
	the properties worth setting -- a nil PrimaryPart, an unset Color3.
]]

local CollectionService = game:GetService("CollectionService")

local Dispatch = require(script.Parent.Parent.Dispatch)
local Paths = require(script.Parent.Parent.Paths)
local Serialize = require(script.Parent.Parent.Serialize)
local Undo = require(script.Parent.Parent.Undo)

-- Guards a runaway batch from locking Studio's main thread.
local MAX_INSTANCES = 500

local Instances = {}

type PropertySpec = { value: any, type: string }

--[[
	Applies one property, returning a reason rather than raising so a batch can
	report exactly which of twenty properties was wrong.
]]
local function applyProperty(target: Instance, name: string, spec: PropertySpec): string?
	if typeof(spec) ~= "table" or spec.type == nil then
		return string.format("%s: no type was resolved for this property", name)
	end

	local ok, parsed, reason = Serialize.parse(spec.value, spec.type)
	if not ok then
		return string.format("%s: %s", name, reason or "could not be converted")
	end

	local assigned, err = pcall(function()
		(target :: any)[name] = parsed
	end)
	if not assigned then
		-- Read-only and context-gated properties fail here rather than at parse
		-- time; the engine message names which.
		return string.format("%s: %s", name, tostring(err))
	end
	return nil
end

local function applyAttributes(target: Instance, attributes: { [string]: any }): { string }
	local failures: { string } = {}
	for name, value in attributes do
		-- A JSON null means "remove this attribute", which SetAttribute spells
		-- as nil. There is no other way to express removal in the payload.
		local ok, err = pcall(function()
			target:SetAttribute(name, if value == "" then nil else value)
		end)
		if not ok then
			table.insert(failures, string.format("attribute %s: %s", name, tostring(err)))
		end
	end
	return failures
end

local function applyTags(target: Instance, tags: { [string]: any })
	for _, tag in (tags.add or {}) :: { string } do
		CollectionService:AddTag(target, tag)
	end
	for _, tag in (tags.remove or {}) :: { string } do
		CollectionService:RemoveTag(target, tag)
	end
end

--[[
	Builds one instance and its descendants.

	Children are created before the parent is attached to the data model, so a
	model appears in the Explorer complete rather than assembling itself piece by
	piece in front of the user.
]]
local function build(spec: { [string]: any }, parent: Instance, created: { { [string]: any } })
	local ok, instance = pcall(Instance.new, spec.className)
	if not ok or typeof(instance) ~= "Instance" then
		Dispatch.fail(
			"BAD_CLASS",
			string.format('"%s" is not a creatable class.', tostring(spec.className)),
			"Check the spelling and capitalisation. Abstract classes like BasePart "
				.. "cannot be created -- use a concrete one such as Part."
		)
	end

	local target = instance :: Instance
	if typeof(spec.name) == "string" and spec.name ~= "" then
		target.Name = spec.name
	end

	local failures: { string } = {}
	for name, property in (spec.properties or {}) :: { [string]: PropertySpec } do
		local failure = applyProperty(target, name, property)
		if failure then
			table.insert(failures, failure)
		end
	end
	for _, failure in applyAttributes(target, (spec.attributes or {}) :: { [string]: any }) do
		table.insert(failures, failure)
	end
	if spec.tags then
		applyTags(target, spec.tags)
	end

	if #failures > 0 then
		target:Destroy()
		Dispatch.fail(
			"BAD_PROPERTY",
			string.format("Could not set %d value(s) on the new %s.", #failures, spec.className),
			table.concat(failures, "; ")
		)
	end

	for _, child in (spec.children or {}) :: { { [string]: any } } do
		build(child, target, created)
	end

	target.Parent = parent
	table.insert(created, { path = Paths.of(target), className = target.ClassName })
end

function Instances.create(params: { [string]: any }): { [string]: any }
	local specs = params.instances
	if typeof(specs) ~= "table" or #specs == 0 then
		Dispatch.fail(
			"BAD_PARAMS",
			"create requires a non-empty `instances` array.",
			"Each entry needs `parent` and `className`."
		)
	end
	if #specs > MAX_INSTANCES then
		Dispatch.fail(
			"TOO_MANY",
			string.format("%d instances in one call, over the %d limit.", #specs, MAX_INSTANCES),
			"Split the batch, or create one parent and nest the rest under `children`."
		)
	end

	local created, recorded = Undo.record("StudioMCP.Create", "MCP create", function()
		local built: { { [string]: any } } = {}
		for _, spec in specs do
			build(spec, Paths.resolve(spec.parent), built)
		end
		return built
	end)

	return {
		items = created,
		undoStep = if recorded then "MCP create" else nil,
	}
end

function Instances.modify(params: { [string]: any }): { [string]: any }
	local targets = params.targets
	if typeof(targets) ~= "table" or #targets == 0 then
		Dispatch.fail(
			"BAD_PARAMS",
			"modify requires a non-empty `targets` array.",
			"Each entry needs `paths` plus `properties`, `attributes` or `tags`."
		)
	end

	-- Resolve everything before opening a recording, so a typo in the last path
	-- costs nothing and leaves no undo entry behind.
	local resolved: { { instance: Instance, spec: { [string]: any } } } = {}
	for _, entry in targets do
		local paths = entry.paths
		if typeof(paths) ~= "table" or #paths == 0 then
			Dispatch.fail("BAD_PARAMS", "Every modify target needs a non-empty `paths` array.")
		end
		for _, path in paths :: { string } do
			table.insert(resolved, { instance = Paths.resolve(path), spec = entry })
		end
	end

	local changed, recorded = Undo.record("StudioMCP.Modify", "MCP modify", function()
		local items: { { [string]: any } } = {}
		local memo: Paths.NameIndex = {}

		for _, target in resolved do
			local failures: { string } = {}
			local applied = 0

			for name, property in (target.spec.properties or {}) :: { [string]: PropertySpec } do
				local failure = applyProperty(target.instance, name, property)
				if failure then
					table.insert(failures, failure)
				else
					applied += 1
				end
			end

			local attributes = (target.spec.attributes or {}) :: { [string]: any }
			for _, failure in applyAttributes(target.instance, attributes) do
				table.insert(failures, failure)
			end
			for _ in attributes do
				applied += 1
			end

			if target.spec.tags then
				applyTags(target.instance, target.spec.tags)
			end

			-- One bad property fails the whole batch: the recording is cancelled
			-- and every instance reverts, which is far easier to reason about
			-- than a place half-way between two states.
			if #failures > 0 then
				Dispatch.fail(
					"BAD_PROPERTY",
					string.format(
						"Could not set %d value(s) on %s.",
						#failures,
						target.instance:GetFullName()
					),
					table.concat(failures, "; ")
						.. " Nothing was changed: the whole batch was rolled back."
				)
			end

			table.insert(items, {
				path = Paths.of(target.instance, memo),
				className = target.instance.ClassName,
				changed = applied,
			})
		end
		return items
	end)

	return {
		items = changed,
		undoStep = if recorded then "MCP modify" else nil,
	}
end

function Instances.delete(params: { [string]: any }): { [string]: any }
	local paths = params.paths
	if typeof(paths) ~= "table" or #paths == 0 then
		Dispatch.fail("BAD_PARAMS", "delete requires a non-empty `paths` array.")
	end

	local doomed: { Instance } = {}
	for _, path in paths :: { string } do
		local target = Paths.resolve(path)
		-- Services cannot be destroyed and the attempt leaves Studio in a strange
		-- state, so this is refused rather than passed to the engine.
		if target == game or target.Parent == game then
			Dispatch.fail(
				"PROTECTED",
				string.format('"%s" is a service and cannot be deleted.', path),
				"Delete the contents instead, e.g. its children by path."
			)
		end
		table.insert(doomed, target)
	end

	-- Paths are captured before anything is destroyed: an instance that has been
	-- removed from the data model can no longer describe where it was.
	local removed: { { [string]: any } } = {}
	local memo: Paths.NameIndex = {}
	for _, target in doomed do
		table.insert(removed, {
			path = Paths.of(target, memo),
			className = target.ClassName,
			descendants = #target:GetDescendants(),
		})
	end

	local _, recorded = Undo.record("StudioMCP.Delete", "MCP delete", function()
		for _, target in doomed do
			target:Destroy()
		end
		return true
	end)

	return {
		items = removed,
		undoStep = if recorded then "MCP delete" else nil,
	}
end

function Instances.move(params: { [string]: any }): { [string]: any }
	local items = params.items
	if typeof(items) ~= "table" or #items == 0 then
		Dispatch.fail(
			"BAD_PARAMS",
			"move requires a non-empty `items` array.",
			"Each entry needs `path` and `to`."
		)
	end

	local planned: { { source: Instance, destination: Instance, spec: { [string]: any } } } = {}
	for _, item in items do
		local source = Paths.resolve(item.path)
		local destination = Paths.resolve(item.to)

		-- Reparenting something into itself detaches that whole branch from the
		-- data model with no error, and it is not recoverable by undo.
		if item.mode ~= "clone" and (destination == source or destination:IsDescendantOf(source)) then
			Dispatch.fail(
				"BAD_MOVE",
				string.format('Cannot move "%s" into itself or its own descendant.', item.path),
				"Pick a destination outside the branch being moved."
			)
		end
		table.insert(planned, { source = source, destination = destination, spec = item })
	end

	local moved, recorded = Undo.record("StudioMCP.Move", "MCP move", function()
		local results: { { [string]: any } } = {}
		for _, entry in planned do
			local target = entry.source
			if entry.spec.mode == "clone" then
				-- Clone is typed as returning an Instance but hands back nil when
				-- Archivable is false, which is how a locked or package-owned
				-- instance refuses to be copied.
				local copy = target:Clone()
				if typeof(copy) ~= "Instance" then
					Dispatch.fail(
						"NOT_COPYABLE",
						string.format('"%s" cannot be cloned.', target:GetFullName()),
						"Archivable is false on this instance, which excludes it from copies."
					)
				end
				target = copy
			end

			if typeof(entry.spec.name) == "string" and entry.spec.name ~= "" then
				target.Name = entry.spec.name
			end
			target.Parent = entry.destination

			table.insert(results, {
				path = Paths.of(target),
				className = target.ClassName,
				cloned = entry.spec.mode == "clone",
			})
		end
		return results
	end)

	return {
		items = moved,
		undoStep = if recorded then "MCP move" else nil,
	}
end

function Instances.register()
	Dispatch.registerAll("instances", {
		create = Instances.create,
		modify = Instances.modify,
		delete = Instances.delete,
		move = Instances.move,
	})
end

return Instances
