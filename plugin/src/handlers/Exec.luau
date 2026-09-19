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

local RunService = game:GetService("RunService")

local Dispatch = require(script.Parent.Parent.Dispatch)
local Runtime = require(script.Parent.Parent.ExecRuntime)
local ClientRelay = require(script.Parent.Parent.ClientRelay)

local CHUNK_NAME = "StudioMCP.execute_luau"

local Exec = {}

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

--[[
	Warnings about what the code could and could not see, in the result.

	The module-cache one is the important one, and it cost a session before it
	existed. This chunk runs in the plugin's VM, which keeps its own `require`
	cache; the running game keeps its own. So `require(SomeModule)` here loads a
	*second copy* -- fresh upvalues, fresh state -- and reading a counter off it
	returns the zero it was initialised with while the real module, in the game's
	VM, is working perfectly. A zero that means "wrong copy" is indistinguishable
	from a zero that means "nothing happened", so the only defence is saying so
	every time it could be happening.

	Only raised while the game is actually running, since in an editor session
	there is no other copy for the answer to disagree with.
]]
local function notes(route: string, source: string): string?
	local lines: { string } = {}

	-- Only mentioned when it constrains what the code could do. On the direct
	-- route there is nothing to say.
	if route == "module" then
		table.insert(
			lines,
			"Ran through a ModuleScript because loadstring is disabled in this "
				.. "session, so the code held script identity rather than plugin "
				.. "identity -- plugin-only APIs would have been unavailable to it."
		)
	end

	if string.find(source, "require", 1, true) and RunService:IsRunning() then
		table.insert(
			lines,
			"This code called `require` while the game is running, and it does NOT "
				.. "share the running game's module cache -- it got its own fresh copy "
				.. "of each ModuleScript, with state reset to whatever the module "
				.. "initialises. Any counter, cache or table read that way reports its "
				.. "starting value, not the live one, and a zero here does not mean "
				.. "nothing happened. To read live state, read it off the DataModel "
				.. "(instances, attributes, properties) or have the running code print "
				.. "it and read that with `console`."
		)
	end

	if #lines == 0 then
		return nil
	end
	return table.concat(lines, "\n\n")
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

	if params.target == "client" then
		local player = ClientRelay.playerFor(params.player)
		local timeout = math.clamp(tonumber(params.timeoutSeconds) or 30, 1, 300)
		local result = ClientRelay.run(player, "MCPExecRelay", [==[
local report = script:WaitForChild("Report", 10)
if not report then return end
local ok, result = pcall(function()
	assert(game:GetService("RunService"):IsClient(), "Client VM required")
	local runtime = require(script:WaitForChild("ExecRuntime"))
	local compiled, chunk = pcall(require, script:WaitForChild("Chunk"))
	if not compiled then
		return { ok = false, error = tostring(chunk), output = {}, milliseconds = 0 }
	end
	return runtime.run(chunk, script:GetAttribute("Timeout"))
end)
report:FireServer(if ok then result else { ok = false, error = tostring(result), output = {}, milliseconds = 0 })
]==], { Timeout = timeout }, timeout + 5, function(relay)
			-- These modules are required ONLY by the LocalScript, sharing the game's client VM.
			for _, name in { "ExecRuntime", "Serialize", "Paths", "Dispatch" } do
				local copy = script.Parent.Parent[name]:Clone()
				copy.Parent = relay
			end
			local chunk = Instance.new("ModuleScript")
			chunk.Name = "Chunk"
			chunk.Parent = relay
			chunk.Source = "return function(...) " .. source .. "\nend"
		end)
		return result
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

	local result = Runtime.run(chunk :: any)
	if module then module:Destroy() end
	result.note = notes(route, source)
	return result
end

function Exec.register()
	Dispatch.registerAll("exec", {
		run = Exec.run,
	})
end

return Exec
