# Changelog

What changed in each release, written for people using the server rather than for people reading the diff.

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
