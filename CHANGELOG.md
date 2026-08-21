# Changelog

What changed in each release, written for people using the server rather than for people reading the diff.

## Unreleased

### Fixed
- **`geometry` (union/subtract/intersect) could report a path that did not exist.** The result's path was read while the source part it was built from — same name, not yet destroyed — was still its sibling, so it came back disambiguated as `Foo[2]`; the source was then destroyed, leaving the real result addressable as plain `Foo`. The tool's own reply pointed at a path that no longer resolved. Found live: `delete` on a path this same tool call had just returned failed with `NOT_FOUND`.
- **`debug clear` with just a `path` (no `line`) always failed, asking for a `line` regardless** — the documented "clear every breakpoint in this script" case was entirely unimplemented; only "one exact line" and "everything, session-wide" worked. The plugin now tracks which lines it has set per script and removes all of them for that one, without touching breakpoints anyone else set.

### Changed
- **`instances.create`, `instances.modify` and `instances.move` describe what actually happened, not just that something did.** Create now names the class ("Create ScreenGui" instead of whatever the caller happened to name it); modify names the properties or attributes that changed ("Set Color on Sword"); move/clone says the destination name when a rename happened in the same call, since the old text described an instance that was never created under that name.

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
