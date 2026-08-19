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

local Exec = {}

--[[
	Describes a returned value compactly. Roblox types go through the same
	serializer the rest of the server uses, so a Vector3 reads the way it does
	everywhere else; tables are summarised rather than walked, since a returned
	DataModel subtree would be unbounded.
]]
local function describe(value: any): any
	local kind = typeof(value)
	if kind == "table" then
		local count = 0
		for _ in value :: { [any]: any } do
			count += 1
		end
		return string.format("<table with %d entries>", count)
	end
	if kind == "function" or kind == "thread" then
		return string.format("<%s>", kind)
	end
	return Serialize.value(value)
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

	local compiler = (loadstring :: any)
	if typeof(compiler) ~= "function" then
		Dispatch.fail(
			"NO_LOADSTRING",
			"This Studio build does not expose loadstring to plugins.",
			"Use the dedicated tools instead: create, modify, script_edit and find "
				.. "cover most of what execute_luau is reached for."
		)
	end

	local chunk, compileError = compiler(source, "StudioMCP.execute_luau")
	if typeof(chunk) ~= "function" then
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

	if not results[1] then
		return {
			ok = false,
			error = tostring(results[2]),
			output = output,
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
		milliseconds = math.floor(elapsed * 1000 + 0.5),
	}
end

function Exec.register()
	Dispatch.registerAll("exec", {
		run = Exec.run,
	})
end

return Exec
