local paths = ...
local firstPath, secondPath = paths.of(first), paths.of(second)
for _ = 1, 10 do
	assert(paths.resolve(firstPath) == first and paths.resolve(secondPath) == second,
		"client duplicate ordering must survive shuffled GetChildren without GetDebugId")
end
assert(paths.resolve("Workspace.Part") == first or paths.resolve("Workspace.Part") == second, "bare duplicate paths remain accepted")
assert(paths.resolve("Workspace.Dr. Who.Head") == head and paths.resolve("game.Workspace.Dr. Who") == dot)
local handle = paths.handle(second)
second.Name = "Renamed"
second.Parent = dot
assert(paths.resolve(handle) == second)
second.Parent = nil
local ok, failure = pcall(paths.resolve, handle)
assert(not ok and failure.code == "STALE_HANDLE")
ok, failure = pcall(paths.resolve, "@mcp:another-session:1")
assert(not ok and failure.code == "STALE_HANDLE")
print("paths: client duplicate identity, bare paths, dotted names, handles and stale refusal pass")
