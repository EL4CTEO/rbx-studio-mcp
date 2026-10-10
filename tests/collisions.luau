local collisions = ...
local function summary(a, b, speed, extra)
	local s = {Part0 = a, Part1 = b, RelativeVelocity = vec(0, speed, 0), Point = vec(1, 2, 3), Normal = vec(0, 1, 0), Area = 0.5, Time = 1}
	for k, v in extra or {} do s[k] = v end
	return s
end
local fin = ball.children[1]

tick = function()
	ball:fire({summary(ball, floor, 40), summary(ball, floor, 80), summary(ball, wall, 5)})
	fin:fire({summary(fin, floor, 10)})
end
local result = collisions.capture({path = "Workspace.Ball", seconds = 1})
assert(result.observed == 2 and result.summaries >= 60)
assert(#result.pairs == 3, "one row per pair")
assert(result.pairs[1].other == "Workspace.Floor" and result.pairs[1].part == "Workspace.Ball" and result.pairs[1].maxSpeed == 80)
assert(result.pairs[1].frames >= 20 and result.pairs[1].point == "1.00, 2.00, 3.00" and result.pairs[1].normal == "0.00, 1.00, 0.00")
assert(result.pairs[3].maxSpeed == 5)
for _, connection in all do assert(not connection.active, "collision connections leak after completion") end

-- minSpeed drops resting contact.
result = collisions.capture({path = "Workspace.Ball", seconds = 1, minSpeed = 20})
assert(#result.pairs == 1 and result.pairs[1].maxSpeed == 80)

-- Both observed parts report the same contact; only one side is kept.
local both = ball.children[1]
tick = function()
	ball:fire({summary(ball, both, 30)})
	both:fire({summary(both, ball, 30)})
end
result = collisions.capture({path = "Workspace.Ball", seconds = 1})
assert(#result.pairs == 1, "mutual contact deduplicated")

-- A part with nothing to observe fails clearly.
target = part("Folderish")
target.IsA = function() return false end
local ok, failure = pcall(collisions.capture, {path = "Workspace.Folderish"})
assert(not ok and failure.code == "NO_PARTS")

-- Not simulating (edit mode) is stated.
target = ball
running = false
tick = function() end
result = collisions.capture({path = "Workspace.Ball", seconds = 1})
assert(#result.pairs == 0 and string.find(result.note, "not simulating", 1, true))
print("collisions: pairs, strongest impact, minSpeed, dedupe, cleanup and edit-mode note pass")
