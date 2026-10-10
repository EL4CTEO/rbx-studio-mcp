--!strict
-- Runs only in the real client VM. Modules are loaded lazily so an unavailable
-- capability in one reader cannot break unrelated client queries.
local ClientRead = {}

function ClientRead.call(op: string, params: { [string]: any }): any
	assert(game:GetService("RunService"):IsClient(), "Client VM required")
	if string.sub(op, 1, 9) == "discover." then
		local Discover = require(script.Parent.Handlers.Discover)
		local method = string.sub(op, 10)
		assert(method == "tree" or method == "inspect" or method == "find" or method == "tags", "Unknown discovery operation")
		return Discover[method](params)
	elseif op == "viewport.pick" or op == "viewport.ui" or op == "viewport.raycast" then
		local View = require(script.Parent.ViewRead)
		return View[string.sub(op, 10)](params)
	elseif op == "perf.snapshot" then
		return require(script.Parent.PerfSnapshot).snapshot()
	elseif op == "capture.region" then
		return { region = require(script.Parent.ScreenRegion).of(params) }
	elseif op == "debug.watch" then
		return require(script.Parent.Watch).capture(params, script.Parent)
	elseif op == "debug.collisions" then
		return require(script.Parent.Collisions).capture(params)
	elseif op == "exec.result" then
		return require(script.Parent.Results).read(params)
	end
	error("Unsupported client read: " .. op)
end

return ClientRead
