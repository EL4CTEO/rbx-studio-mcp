# Changelog

What changed in each release, written for people using the server rather than for people reading the diff.

## 0.3.6

A rolled-back edit can no longer be redone, typing into a text box actually types, and the console keeps working while you playtest.

### Fixed
- **A rolled-back batch could be brought back with one Ctrl+Y.** `modify` said "nothing was changed" and meant it, but Studio filed the cancelled edit on the redo stack — so a single redo re-applied the half-finished state the rollback existed to prevent.
- **`input` reported typing text that never arrived.** A synthetic click does not give a TextBox focus, and `text` steps go to the focused box, so they did nothing and still returned success. The box under the click is focused now, and a step with nowhere to type says so.
- **`device` blamed the device id during a playtest.** A valid id came back as `NO_SUCH_DEVICE` with advice to check the spelling. Studio simply refuses device changes while a test runs; it now says that, and points at the edit session, which works.
- **The console came back on the saved theme's shape but the default's colours.** The palette was read before the saved preset was restored.
- **The Void preset strobed after every command.** Its orbit multiplied elapsed time by a speed that changes, so a change in speed jumped the disc instead of accelerating it — worse the longer Studio had been open. Aurora had the same fault when a session went quiet.
- **The activity cell snapped and stalled instead of bouncing.** A reply's impulse drove it into its own size limit while still carrying speed, and long frames dropped motion rather than catching up.
- **The panel vanished on every playtest.** Studio loads the plugin again into the playtest and its widget starts closed; it now opens the way you left it.

### Changed
- **The console keeps working during a playtest.** The view Studio shows you is the client half, which Roblox forbids from making HTTP requests, so it sat on a standby notice while the agent worked. It now mirrors the playtest's server session — the log fills and the activity strip reacts live. One `RemoteEvent` carries it, in the running game only, one-way, never saved with the place.
- `input` no longer suggests reusing a measured click offset: it holds under portrait emulation and with no device, but not in landscape.

### Known issues
- **A playtest opens the panel at the wrong size.** Studio does not restore plugin widget geometry in play mode — `HostWidgetWasRestored` reads false there — and a widget's size cannot be set from code. Studio → Settings → Test → "Load All Built-In Plugins in Test Mode" works around it. [Reported since 2023.](https://devforum.roblox.com/t/widgets-reset-when-playtesting-and-opening-a-new-studio/2946725)

## 0.3.5

Search results stop reshuffling between calls, values written as text land as the right type, and the console panel gets eight colour presets.

### Fixed
- **`find` and `tree` returned rows in a different order every call.** The engine does not order `GetDescendants` stably, and pages are cut by position — so page two came from a different ordering than page one, skipping some instances and repeating others with counts that still looked right. Results are now sorted.
- **A bad cursor silently returned the first page.** Indistinguishable from a genuine first page, so paging could never reach the end. It is an error now.
- **Numbers in a composite value were misread.** `Position: "1e3, 0, .5"` became `1, 3, 0` and reported success. Scalars and composites now read numbers the same way.
- **Anything but exactly `"true"` became `false`.** `Anchored: "True"` silently set the opposite. Near misses are accepted; anything else is refused instead of guessed.
- **Attributes could not hold a Vector3, Color3 or UDim2.** The same text that types a property was stored as a string. Pass `{ type, value }` for any non-scalar.
- **`find` disagreed with `modify` about enum notation.** `"Plastic"` and `"FALSE"` matched nothing while `modify` accepted both. Matching is case-insensitive and takes a bare enum name.
- **A self-referencing table printed as three nested copies.** `execute_luau` now says `<circular reference>`.
- **A backwards line range blamed the file.** `script_read` now names the argument.
- **`api` gave no suggestion for a mistyped class.** It now answers like `create` does.

### Changed
- **The console panel has eight colour presets** — Lattice, Observatory, Orbit, Void, Nebula, Aurora, Phosphor, Blueprint. Hover the tab on its right edge. Each replaces the activity cell's contents, not just its colours, and the choice persists across Studio restarts.
- `debug` now states what breakpoints actually do: they fire once per run rather than once per pass, and a log expression cannot see a loop's control variable.
- `console` no longer claims Studio's own messages never reach the log. Some do, some do not; a quiet log is not an all-clear.

## 0.3.1

Paths with dots in them resolve properly, `script_create` catches a script that would run twice, and the stale-plugin warning stops blaming the wrong side.

### Fixed
- **A path with a dot in a name could not be read back.** 0.3.0 rejoined dotted names but never backtracked, so `Workspace.Dr. Who` failed whenever a sibling named `Dr` existed — a path the tools themselves emit. Resolution now backtracks; a short name that resolves the whole path still wins.
- **The server compared against the sources it started with.** Rebuilding the plugin mid-session left the freshly installed plugin reported as the stale one, with advice that could not help. The fingerprint is re-checked when a source file changes.
- **Two sessions of one Studio could run different plugin builds.** A playtest keeps the plugin it loaded when it started, so a rebuild part-way through splits the two. `list_studios` now says so, names each session's build, and tells you to restart the playtest.

### Changed
- **`script_create` warns about a script that would run twice.** A `Script` with a non-Legacy RunContext inside `StarterGui`, `StarterPack`, `StarterPlayerScripts` or `StarterCharacterScripts` runs once where it sits and again in every player's copy. Studio warns about this in its own Output, which `console` cannot read, so the warning now comes back in the response. Use `LocalScript` there.
- **Better `NOT_FOUND` messages.** An index past the end says how many siblings share the name instead of blaming the wrong segment, and repeated sibling names are counted — `Part (x73)` rather than "Part" 25 times.
- **`console` says what it cannot see.** Messages Studio itself emits, and anything printed on the client, never reach any session's log — a quiet log is not proof nothing was said.

## 0.3.0

`execute_luau` now warns when it is reading a copy of a module instead of the live one, instance names containing dots resolve, and `script_read` can take a different line range per script.

### Fixed
- **`execute_luau` could report a running system as doing nothing.** It runs in the plugin's own Luau VM, which keeps its own `require` cache, so `require(SomeModule)` against a running playtest returns a second, freshly-initialised copy of that module — its counters and caches read as their starting values while the real ones are fine. A zero read that way is indistinguishable from a genuine zero, and there is no API that would let a plugin reach the game's cache, so the result now says so: any call using `require` while the game is running comes back with a note explaining what it actually read and pointing at the DataModel, or the game's own prints via `console`, as the way to see live state. The tool description says it up front too.
- **Instance names containing dots could not be addressed.** Paths are dot-separated, so `Workspace.Dr. Simon.Head` split into a segment named `Dr` and failed. Segments are now rejoined greedily, longest first, when the plain lookup misses — a place holding both `Dr` and `Dr. Simon` still resolves the short name to itself.

### Changed
- **`script_read` takes a line range per script.** An entry may now be `{path, startLine, endLine}` instead of a bare path, so "line 40 of this one, line 300 of that one" is one call rather than one call each. A bare string still reads the whole file, and the top-level `startLine`/`endLine` remain the default for entries without their own.
- **`script_create` waits 60 seconds instead of 15.** A batch of full script sources is the largest payload any tool sends, and the default was timing out on around 12KB across three scripts — splitting the batch is the wrong answer when creating related scripts as one undo step is the point of the tool.

## 0.2.9

A property that exists is no longer reported as a typo, and the stale-plugin warning stops repeating itself.

### Fixed
- **Properties you cannot set were reported as properties that do not exist.** `Lighting.Technology` is real — it is gated behind the RobloxScript identity, which no plugin has — but the name check reads the API dump filtered to what a plugin can reach, so it was indistinguishable from a misspelling. `modify` and `create` now answer with `RESTRICTED_PROPERTY`: "Lighting.Technology exists but is restricted to RobloxScript identity, so no plugin can set it. Change it in Studio's Properties panel (or Game Settings) instead." True of every property at that security level, and of `NotScriptable` ones, not just this one. Real typos still get `UNKNOWN_PROPERTY` and the closest matching names.
- **`inspect` with detail `full` hid the same properties.** "Every readable property" quietly meant "every property a plugin is allowed to see", and the ones it skipped were absent exactly the way a nonexistent property would be. They are now listed by name at the end of the response, with the identity each one needs.
- **The stale-plugin warning repeated on every call, for the whole session.** Four sentences of instructions on every `studio_status`, and once per row in `list_studios` — the same paragraph twice in one response with two Studio windows open. It is now stated in full the first time a build is seen and reduced to a single line after that, and a plugin that genuinely reloads into a different build warns again.

## 0.2.8

Packaging only. No code changes from 0.2.7.

The npm keywords were missing the terms people actually search for — `mcp-server`, `claude-code`, `cursor`, `ai-agent`, `roblox-development` — and keywords only take effect when a version is published, so they needed a release of their own to reach the registry.

## 0.2.7

Four tools that reported something untrue, and the one from 0.2.6 that replaced a wrong answer with another wrong answer.

### Fixed
- **`input` clicks land at an offset, and it now tells you what the offset is.** 0.2.6 said coordinates were out by the ratio between the emulated device's resolution and the screenshot's. Measured against a live playtest, it is a constant translation, never a scale — and it changes with the device and orientation, fitting no formula over resolution, viewport and GUI inset. So the relay now watches what the client actually receives and reports where the click was read against where it was aimed: `off by (-59, -58). Add (59, 58)`. Aim once, read the delta, correct. The offset is present with no device emulated at all, which the old explanation could not account for.
- **A click the client never registers is now called out as such**, instead of being reported as delivered. Phone emulation switches the client to touch input, which is why one that registered nowhere still looked like a success.
- **`perf coverage` diagnosed a failure on its own happy path.** Enabling coverage and reading straight back is expected to be empty — instrumentation only records while code runs — but 0.2.6 answered that with "these compiled before instrumentation was switched on". It now says what it actually knows, and where two causes are genuinely indistinguishable it names both instead of picking one.
- **Coverage reported scripts that had been destroyed**, for the rest of the session, under a bare name rather than a path.
- **`perf coverage` explained the "0 lines" flag with a cause that does not produce it.** An already-compiled script gets no record at all rather than an empty one; the replacement cause could not be reproduced either, so none is claimed now.
- `perf coverage` with an empty `enable` said nothing about having stopped, so a request to stop looked like a call that did nothing.
- `input` printed "emulated at undefined" when the device was known but its resolution was not.
- **A server whose MCP client was killed rather than closed never exited.** It kept the bridge port bound and re-registered itself every 30 seconds, so nothing ever swept it and the Studio console truthfully reported an agent that had left hours ago. It now shuts down when the process that spawned it goes away.

## 0.2.6

Four places where a tool told you something that wasn't true.

### Fixed
- **`input` clicks miss while a device is emulated.** Pointer coordinates are read in the emulated device's resolution, but `screenshot` returns the viewport's own pixels — 780x360 against 689x318 on a Galaxy S25 Ultra — so coordinates taken from a screenshot land short of the target. `input` now reports the emulation and says how to scale, or use `device op="stop"`. Keys were never affected, which is what made it look like a GUI fault.
- **`perf coverage` reported "no coverage recorded yet" for code that demonstrably ran.** A script already compiled when instrumentation was switched on gets no record at all, so it never reaches the results. The scripts the session was asked to instrument are now named, with the reason.
- **`list_studios` told the agent to ask the user which place they mean when only one place was open.** Two sessions on one placeId is an editor and its playtest, and the next call would have said so; the listing that comes first said the opposite. Both now give the same answer: pass `studioId` explicitly, edit session for anything that must outlive the playtest.
- **The console announced "Agent finished task." for an agent that had simply been closed.** The bridge sees a client disconnect and nothing more — quitting, a crash and a restart all arrive identically. It now says "Agent disconnected."

## 0.2.5

The console panel reacts to what the session is doing, reports how many agents share it, and says what a latency bar was.

### Added
- The activity band moves with the work: the solid draws in as a command goes out, springs past its size when the answer lands, snaps and wobbles on failure, breathes while idle, and winds down once the session goes quiet.
- Hovering a latency bar names the call — `Run luau: 2 ms`, not `2 ms`.
- A badge when more than one MCP client shares the bridge. Nothing shown for the usual single client.
- `Agent finished task.` when a client disconnects, and `agent idle — N calls, avg Xms` when work stops.
- **clear** logs `cleared N logs`, timestamped like every other row, and empties the latency trace with it.

### Changed
- The plugin is now called **rbx-studio** — window title, toolbar, and footer. Your panel's saved position and size are unaffected.

### Fixed
- **Two SSE frames sent in the same tick were both dropped.** They arrive as one chunk, and the parser decoded the whole chunk as a single JSON document. Visible as a client badge that went up and never came down; the real risk was a command sharing a chunk with a keepalive and vanishing — a lost tool call with no error at either end.
- An MCP client disconnecting was never noticed: `StdioServerTransport` listens only for `data` and `error` on stdin, so EOF never closes it and `onclose` never fires. Taken from stdin's `end` event instead.
- The bridge swept away the process it runs inside. The owner registered once and nothing refreshed it, so the reaper dropped it after 90s while it was serving — the client count read short and the drop was reported as an agent finishing.
- The latency bars' hover highlight had never once been visible: anchored to its bottom edge but positioned at the top of a frame that clips, so it drew entirely off screen.
- A departing client left its chosen Studio in the bridge forever.
- Shutdown aborted on Windows (`UV_HANDLE_CLOSING`) by calling `process.exit` mid-teardown.
- `check-plugin` filtered the Luau analyser to `LocalShadow` only, so a field used on a `--!strict` table that does not declare it shipped and crashed the plugin on load. It now also reports missing table keys.

### Faster
- The reply goes back to the agent before the console draws it. Repainting the log sat in front of every result on its way out.
- Repaints coalesced to one per frame, so a failure writing three rows no longer redraws the console three times.
- `TCP_NODELAY` on the bridge sockets.

## 0.2.0

A pass on console accuracy and a few real bugs found while doing it.

### Fixed
- `geometry` (union/subtract/intersect) could return a path that didn't exist.
- `inspect` and `modify` logged an internal probe call as a bare, misleading "Inspect X".
- `debug clear` with just a `path` (no `line`) always failed instead of clearing that script.
- The console described ~10 ops (`input`, `device.*`, `api.*`, `perf.scene`, `studio.transport`, capture internals) by raw wire name only.
- `playtest stop`'s teardown poll logged as "Check the playtest" with no "stop" line anywhere.
- The plugin's protocol version was sent but never checked; a rejected handshake showed a generic error instead of the real reason.

### Added
- `collision` can now `remove` a group — previously created-only, permanent for the place.
- `create`, `modify`, `move` describe what actually changed (class, properties, rename), not just that something did.

## 0.1.8

Found by actually watching the console during a live QA pass, immediately after 0.1.7 shipped: `playtest op="stop"` polls the surviving session every 400ms while the test tears down, and every one of those polls logged as "Check the playtest" — indistinguishable from an agent asking again for no reason, with no "stop" line anywhere to explain it (the real stop went to the session that is by then gone, and its console went with it).

### Fixed
- The teardown poll now logs as "Wait for the playtest to stop", not "Check the playtest".

## 0.1.7

The Studio console is the only feedback channel the plugin has — this is about making it tell the truth.

### Fixed
- **The console showed the raw wire name for ten operations instead of a description.** `input.send` — the one that fires on every keypress and click during a live playtest — read as "Input send" instead of "Press E" or "Click (320, 480)". Also fixed: `device.*`, `api.*`, `perf.scene`, `capture.playtestId`/`decode`, `studio.transport`.
- **A rejected handshake showed a generic "handshake failed" instead of the server's actual reason.** The bridge already sends a real message on every refusal (`missing header`, `no Studio connected`, etc.); the plugin was discarding it and showing a fallback string for any HTTP response that wasn't a plain success.

### Added
- **The plugin now announces its wire-protocol version, and a mismatch is reported the same way a stale build already is** — through `studio_status` and `list_studios`, not a silent failure. Existing plugins are unaffected: the version has never moved, so nothing changes until it does.

## 0.1.6

Documentation and error-message corrections. No behaviour change.

### Fixed
- `NO_STUDIO` and `list_studios` errors pointed agents at a nonexistent "Plugins tab -> Studio MCP -> Connect" command. The plugin connects automatically on load; the messages now say so and point at the reconnect button in the console.
- README called the beta "API debugger Luau" in one place; its real name is "Debugger Luau API".

### Changed
- README and package description rewritten shorter. The tagline no longer implies every write is undoable — `execute_luau` writes are not recorded.

## 0.1.5

Corrects two things 0.1.4 got wrong about the Debugger Luau API beta.

### Fixed
- **`debug` no longer refuses breakpoints with a message naming nothing.** The engine says only `Failed to execute AddBreakpoint request`. When every breakpoint in a call is refused, the error now points at the beta as the usual cause — it is off by default and needs a Studio restart — and at the other likely cause, a line that never runs, such as a `return` or an `end`.

### Removed
- **`studio_status` no longer reports `debuggerBeta`.** 0.1.4 added it and it never worked. Two probes were tried and measured, and neither varies with the beta: with it OFF, `GetService("ScriptDebuggerService")`, `FindService`, assigning `OnStopped` and `Enum.DebuggerResumeType` all still succeed; with it ON, `ReflectionService` still does not list the class. The only reliable test is `AddBreakpoint` itself, which cannot be run speculatively on someone's script to answer a status question. A field that always reads "fine" is worse than no field, so it is gone rather than guessed at a third time.

### Changed
- Corrected a claim in the 0.1.4 notes. They said the plugin could fail to load entirely when the beta was off, assuming `GetService` throws for an unregistered service. It does not — that was written without being checked. The guard added in 0.1.4 stays as insurance on a call that runs before any tool is invoked, but it fixed no observed crash.

## 0.1.4

Makes the Debugger Luau API beta impossible to miss, and stops it from being able to break anything else.

### Fixed
- **The plugin could fail to load entirely when the Debugger beta was off.** `ScriptDebuggerService` is only registered when that beta is on, and the handler asked for it at plugin start with no guard. If `GetService` threw there, every tool went down with it, not just `debug` — and silently, since a plugin that never loads never connects. The lookup is now guarded and a missing service is just a missing feature.

### Added
- `studio_status` reports `debuggerBeta: "off"` when the beta is disabled, so an agent finds out before calling `debug` rather than by failing. Absent when it is on, so the usual answer costs nothing.
- `CHANGELOG.md`, and the release workflow now builds each release body from it. A tag whose version has no section fails the workflow instead of publishing an empty release.

## 0.1.3

Documentation only — no code changes from 0.1.2.

The 0.1.2 package was published before the multi-agent notes landed, so the npm page was missing the two things you need before wiring several agents to one Studio:

- how per-client targeting works, and that `studioId` can still be passed per call
- that **subagents share their parent's connection and its target**, so they need an explicit `studioId`

If you are already on 0.1.2 the behaviour is identical; upgrade only for the docs.

## 0.1.2

Fixes a multi-agent bug that could send your edits to the wrong place.

### Fixed
- **Each agent now keeps its own active Studio.** Agents sharing one bridge also shared one target, so an agent calling `set_active_studio` silently retargeted every other agent's next un-addressed call. Nothing errored — edits simply landed in a place nobody asked for, and if that place was a playtest they were discarded when it stopped. The target is now per client, verified across two real MCP processes.
- Disconnecting a chosen Studio no longer promotes whichever session happens to remain. The choice is dropped, so a remaining pair asks again rather than pointing somewhere nobody picked.

### Notes
- Isolation is per MCP connection. **Subagents share their parent's connection**, so give those an explicit `studioId` per call rather than relying on the default.
- The built-in Studio MCP server solves the same problem by making `studio_id` mandatory everywhere and removing `set_active_studio`. This keeps the default instead, so a single open Studio still needs no id at all.

## 0.1.1

Multi-agent support, playtest screenshots, and a visible pointer.

### Added
- **Several agents can share one Studio.** Register the server in as many MCP clients as you like — two Claude sessions, Claude plus Cursor. The first server to start owns the port and the rest proxy through it automatically. No second connection to Studio, nothing to configure.
- **`screenshot` now works during a playtest.** Address it at the playtest's studioId and you get the player's own view — the only way to check a GUI in front of a running game. The shot is taken on the client and read back through the editor session, so keep the editor window connected.
- **`input` draws an on-screen pointer** that travels to each target before the click and ripples where it lands, so you can see what the agent is aiming at. Turn it off with `cursor: false`.

### Fixed
- `execute_luau` and other calls no longer time out with a bare "it timed out". Timeouts now report whether the command ever reached Studio, how long the plugin has been silent, what else was in flight, and which transport was used.
- A playtest is no longer mistaken for a second place. Editor plus playtest used to trigger AMBIGUOUS_STUDIO, which has no sensible answer — there is one place in two states. It now says so and explains which to target.
- `api describe` no longer lists deprecated members as if they were usable. `Instance` had eight, including `clone` and `getChildren`. They are counted, not listed.
- Device emulation reported portrait resolutions backwards (852x393 for a 393x852 viewport).
- `character`'s description claimed synthetic input was impossible. It has not been since `input` shipped.

### Notes
- `debug` needs the **Debugger Luau API** beta enabled in File → Beta Features, then a Studio restart. The error now says so.

## 0.1.0

First public release. 29 tools over a push-based SSE bridge, editor-safe script editing through `ScriptEditorService:UpdateSourceAsync`, and every write batched into a single undo step.
