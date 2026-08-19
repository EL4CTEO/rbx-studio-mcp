--!strict
--[[
	Arbitrary Luau, run in the plugin's context.

	This is the escape hatch, not the default. Every dedicated tool validates its
	input, types values from the API dump, and wraps writes in an undo recording;
	code run here does none of that. It exists for the cases nothing else covers.

	`LogService:ExecuteScript` -- the API the command bar uses -- is
	RobloxScriptSecurity, so this compiles with `loadstring` instead. Output is
	captured while the chunk runs, because "what did it print" is almost always
	the reason for running it at all.
]]

local LogService = game:GetService("LogService")

local Dispatch = require(script.Parent.Parent.Dispatch)
local Serialize = require(script.Parent.Parent.Serialize)

-- A chunk that prints in a loop would otherwise return a response no context
-- window can hold.
local MAX_OUTPUT_LINES = 200
local MAX_RETURN_VALUES = 10

-- Returned tables are walked rather than counted, but not without limit: a
-- chunk that returns a whole config tree, or one with a cycle in it, must not be
-- able to produce a response nothing can read.
local MAX_TABLE_ENTRIES = 50
local MAX_TABLE_DEPTH = 4

local CHUNK_NAME = "StudioMCP.execute_luau"

local Exec = {}

--[[
	Describes a returned value.

	Tables used to come back as "<table with 5 entries>", which threw away the
	answer whenever the answer was a table -- and returning a table is the natural
	way to report several things at once, so this hit constantly. They are walked
	now, bounded by breadth and depth. Everything else goes through the same
	serializer the rest of the server uses, so a Vector3 reads the way it does
	everywhere else.
]]
local function describe(value: any, depth: number?): any
	local level = depth or 0
	local kind = typeof(value)

	if kind == "function" or kind == "thread" then
		return string.format("<%s>", kind)
	end
	if kind ~= "table" then
		return Serialize.value(value)
	end

	local source = value :: { [any]: any }
	-- Also the cycle guard: a self-referencing table stops here rather than
	-- recursing until the stack gives out.
	if level >= MAX_TABLE_DEPTH then
		return "<nested table>"
	end

	local count = 0
	for _ in source do
		count += 1
	end

	-- Arrays keep their shape so they read as lists on the other side; anything
	-- with non-sequential keys becomes a map with stringified keys.
	if count == #source then
		local list: { any } = {}
		for index, item in ipairs(source) do
			if index > MAX_TABLE_ENTRIES then
				table.insert(list, string.format("<%d more>", count - MAX_TABLE_ENTRIES))
				break
			end
			table.insert(list, describe(item, level + 1))
		end
		return list
	end

	local map: { [string]: any } = {}
	local shown = 0
	for key, item in source do
		shown += 1
		if shown > MAX_TABLE_ENTRIES then
			map["..."] = string.format("<%d more>", count - MAX_TABLE_ENTRIES)
			break
		end
		map[tostring(key)] = describe(item, level + 1)
	end
	return map
end

--[[
	Compiles the chunk by whichever route this session actually allows.

	`loadstring` is the direct one and the only one that keeps plugin identity,
	but the global exists and *throws* unless `ServerScriptService.LoadStringEnabled`
	is set -- which it is not by default. So every call against a running playtest
	server failed with "loadstring() is not available" while the identical code ran
	fine in the editor session, which is the worst shape a limitation can take.

	The fallback compiles through a ModuleScript: a plugin may set `.Source`, and
	requiring a fresh, unparented instance runs it without touching the place. The
	cost is real and gets reported back rather than hidden -- a required module
	runs at script identity, so plugin-only APIs are out of reach on that path.

	Returns the callable, a compile error, which route was taken, and any module
	to clean up once the chunk has finished with it.
]]
local function compile(
	source: string
): (((...any) -> ...any)?, string?, string, ModuleScript?)
	local ok, chunk, syntaxError = pcall(loadstring :: any, source, CHUNK_NAME)
	if ok then
		if typeof(chunk) == "function" then
			return chunk, nil, "loadstring", nil
		end
		return nil, tostring(syntaxError), "loadstring", nil
	end

	-- `chunk` carries the pcall failure when `ok` is false.
	local refusal = tostring(chunk)

	local module = Instance.new("ModuleScript")
	-- The wrapper opens on the same line the source starts on, so a syntax error
	-- still reports the line the caller wrote.
	local settable = pcall(function()
		module.Source = "return function(...) " .. source .. "\nend"
	end)
	if not settable then
		module:Destroy()
		return nil,
			string.format(
				"no route to compile is open in this session: loadstring refused (%s) "
					.. "and setting a script's source is not permitted either",
				refusal
			),
			"none",
			nil
	end

	local required, result = pcall(require, module)
	if not required then
		module:Destroy()
		return nil, tostring(result), "module", nil
	end
	if typeof(result) ~= "function" then
		module:Destroy()
		return nil, "the chunk compiled but produced nothing callable", "module", nil
	end
	return result :: any, nil, "module", module
end

function Exec.run(params: { [string]: any }): { [string]: any }
	local source = params.source
	if typeof(source) ~= "string" or source == "" then
		Dispatch.fail(
			"BAD_PARAMS",
			"execute_luau requires `source`.",
			"Pass the Luau to run as a string."
		)
	end

	local chunk, compileError, route, module = compile(source)
	if chunk == nil then
		if route == "none" then
			Dispatch.fail(
				"NO_COMPILER",
				string.format("Cannot run code in this session: %s", tostring(compileError)),
				"Use the dedicated tools instead: create, modify, script_edit and find "
					.. "cover most of what execute_luau is reached for."
			)
		end
		Dispatch.fail(
			"COMPILE_ERROR",
			string.format("The code did not compile: %s", tostring(compileError)),
			"Fix the syntax and try again. The chunk is compiled as a whole, so a "
				.. "stray end or missing then reports here rather than at a line."
		)
	end

	-- Captured rather than inferred: a chunk's prints are usually the point, and
	-- reading them back from the log afterwards would also pick up whatever else
	-- the place logged in the meantime.
	local output: { { [string]: any } } = {}
	local connection = LogService.MessageOut:Connect(function(message, messageType)
		if #output < MAX_OUTPUT_LINES then
			table.insert(output, {
				message = message,
				level = if messageType == Enum.MessageType.MessageError
					then "error"
					elseif messageType == Enum.MessageType.MessageWarning then "warning"
					else "print",
			})
		end
	end)

	local started = os.clock()
	local results = table.pack(pcall(chunk :: () -> ...any))
	local elapsed = os.clock() - started

	--[[
		MessageOut is deferred: `print` returns before the event fires, so
		disconnecting straight after the chunk finished captured nothing at all.
		A short settle picks the lines up.

		It is bounded and stops as soon as the flow stops, rather than waiting a
		fixed period, so a chunk that logged nothing costs almost no time and one
		that logged plenty is not truncated.
	]]
	local settleDeadline = os.clock() + 0.5
	local seen = #output
	local quietFrames = 0
	while os.clock() < settleDeadline and quietFrames < 3 do
		task.wait()
		if #output == seen then
			quietFrames += 1
		else
			seen = #output
			quietFrames = 0
		end
	end

	connection:Disconnect()

	if module then
		module:Destroy()
	end

	-- Only mentioned when it constrains what the code could do. On the direct
	-- route there is nothing to say.
	local identity = if route == "module"
		then "Ran through a ModuleScript because loadstring is disabled in this "
			.. "session, so the code held script identity rather than plugin "
			.. "identity -- plugin-only APIs would have been unavailable to it."
		else nil

	if not results[1] then
		return {
			ok = false,
			error = tostring(results[2]),
			output = output,
			note = identity,
			milliseconds = math.floor(elapsed * 1000 + 0.5),
		}
	end

	local returned: { any } = {}
	for index = 2, math.min(results.n, MAX_RETURN_VALUES + 1) do
		table.insert(returned, describe(results[index]))
	end

	return {
		ok = true,
		returned = returned,
		output = output,
		note = identity,
		milliseconds = math.floor(elapsed * 1000 + 0.5),
	}
end

function Exec.register()
	Dispatch.registerAll("exec", {
		run = Exec.run,
	})
end

return Exec
