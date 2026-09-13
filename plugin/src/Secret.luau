--!strict
--[[
	Keeps a typed secret out of everything that remembers.

	The panel is built to remember what you type. The line is echoed into the log
	under "you", it goes into the up-arrow history, the log can be copied to the
	clipboard with `copy`, and the whole widget ends up in screenshots -- which
	this very server takes on request. Every one of those is correct behaviour
	for `theme dark` and a disaster for an API key: a credential that can publish
	assets under the user's name would sit in a scrollback that gets pasted into
	a bug report.

	So the one command that carries a secret is masked at every point where a
	line is kept, and that masking lives here rather than in `Commands` because
	two unrelated files -- the echo and the history -- both have to do it, and a
	secret protected in one of two places is not protected.

	Masking, not dropping. `cloud key ****` in the log still tells the user that
	the command ran; a line that vanished would read as the panel ignoring them,
	and the next thing a person does about that is type it again.
]]

local Secret = {}

--[[
	Commands whose arguments are secret, and from which word onwards.

	Keyed by "command subcommand" so `cloud key <secret>` is covered and `cloud
	test` -- which carries nothing -- is not masked into uselessness. The user id
	is masked too. It is not a credential and it is on a public profile URL, but
	it names the account the key belongs to, and a screenshot showing both is
	worth more to somebody than a screenshot showing either.
]]
--[[
	Commands whose arguments are secret, and from which word onwards.

	Keyed by "command subcommand" so `cloud key <secret>` is covered and `cloud
	test` -- which carries nothing -- is not masked into uselessness.

	ONLY the key. The user, group, universe and place ids were masked here too
	at first, which was theatre: they are public -- a user id is in the profile
	URL and a universe id is on the game's dashboard page -- and the reply that
	confirms each one prints it back in full anyway, so the dots hid a value
	from the same log line that then showed it. Masking something that is about
	to be displayed teaches a reader that the dots mean nothing, which is
	exactly the wrong lesson for the one line where they do.
]]
local SECRET_FROM: { [string]: number } = {
	["cloud key"] = 3,
}

--[[
	Returns the line as it is safe to display, and whether anything was hidden.

	The caller gets the flag because "this was masked" is worth saying once, next
	to the echoed line -- otherwise a user who sees dots where they typed a key
	cannot tell whether the panel hid it or mangled it.
]]
function Secret.mask(line: string): (string, boolean)
	local words: { string } = {}
	for word in string.gmatch(line, "%S+") do
		table.insert(words, word)
	end
	if #words < 2 then
		return line, false
	end

	local from = SECRET_FROM[string.lower(words[1]) .. " " .. string.lower(words[2])]
	if from == nil or #words < from then
		return line, false
	end

	--[[
		One fixed marker for everything from `from` on, not one per character
		and not one per word.

		Length is information: eight dots against thirty says which of two things
		was typed, and for a key it narrows a guess. Every masked value looks
		identical, whatever was actually there.
	]]
	local masked = table.move(words, 1, from - 1, 1, {} :: { string })
	table.insert(masked, "••••••••")
	return table.concat(masked, " "), true
end

return Secret
