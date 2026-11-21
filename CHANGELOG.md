# Changelog

What changed in each release, written for people using the server rather than for people reading the diff.

## 1.2.6

### Added

- `screenshot frames=N intervalMs=…`: a timed sequence of up to 12 shots as one contact sheet, to check motion. Works in playtests.
- Studio's "Copy as JSON" format: `inspect format="studio-json"` writes it, `create json=` and `modify json=` read it.

### Changed

- Releases before 1.0 moved to `docs/CHANGELOG-0.x.md`.
- `test-live-v090.mjs` is now `test-live-client.mjs`; `RBX_MCP_BINARY` points the live tests at another server build.

## 1.2.5

### Added

- `sync` checks Luau before pushing (luau-lsp with Roblox types). A file with a syntax error is held back; type errors are reported.
- Deprecated API warnings: classes, properties and functions, with the replacement. Typos get a "did you mean".
- Findings show in Studio's Script Analysis window and as underlines, without repeating what Studio already flags.
- `sync op="check"` checks the folder without syncing; `check: "strict" | "off"` sets how much is reported.

### Changed

- Dependencies updated; Rust 1.100.0.

## 1.2.2

### Fixed

- The toolbar icon loads.
- `npm publish` in the repository publishes the platform packages first.

## 1.2.1

### Added

- New panel design with six animated themes: Nebula, Ember, Tide, Galaxy, Aurora, Monolith. Pick one with the header dots or `theme <name>`; `background off` stops the animation.
- The background reacts to calls and clicks.
- Grouped rows: command output, agent steps, call bursts and reconnects fold under one row.
- Per-game Open Cloud permissions: only reading is on until you run `allow <group>` (`assets`, `data`, `edit`, `money`, `players`).
- `playpanel on|off|left|right|bottom|float`: show the panel during playtests, docked or floating.
- Refused calls show in the panel as a red row.
- New plugin icon.

### Changed

- **Breaking:** uploads, data store writes, publishing, products and bans now need `allow <group>` once per game.
- Server rewritten in Rust: one native binary per platform, installed through npm as before. Starts in ~25 ms (was 450 ms), uses ~14 MB (was 95 MB).
- The plugin is built into the server; `--install-plugin` no longer needs Node.
- Agent replies read as one block, tool calls as short phrases.
- Test Teleports: agents no longer ask which place to use, and calls to the old server name the new one.

### Fixed

- The playtest panel no longer undocks or shrinks on every test after the first.
- Stopping a playtest no longer fills the panel with "Wait for the playtest to stop" rows.
- Typed lines no longer replay their animation.
- Switching theme no longer cuts off running animations.
- Monolith clicks add a beam instead of restarting the running one.
- `api describe` finds plugin-only classes such as `DockWidgetPluginGui`.
- Command menu and hover fixes; the saved theme is fully applied after a Studio reload.

### Removed

- The previous themes, the `visuals` command and the activity band.

## 1.0.6

### Changed

- Shorter README. Install commands now register the server as `rbx-studio`, the name the rest of the project uses.

### Fixed

- Copilot CLI's allow flag used the wrong tool format. It now allows the server by name, as `rbx-studio` or `roblox-studio`.
- `doctor` suggested an install command without the package's `@el4cteo/` scope.
- `cloud` help described the key as for uploads only.

## 1.0.5

### Added

- Hyperline, this month's special theme: the band becomes a live tunnel where every call is a light trail. Pick it from the amber-ringed dot or with `theme hyperline`.
- `performance op="microprofile"`: captures MicroProfiler frames and ranks engine scopes on every thread, with frame times and what filled the worst frame. `export` saves a file for the MicroProfiler viewer. Uses Roblox's LibMP.
- `collision op="cast"`: `shape="part"`, `margin`, `sizeGradient` and `visualize`.
- A send button on the prompt.

### Changed

- Calls in a turn now show as stations on the thread, coloured by kind of work, and a finished turn ends with a cap. Latency bars match.
- The status dot pulses while connected.
- Writes refuse an ambiguous path with `AMBIGUOUS_PATH`, instead of changing the first of several same-named siblings. Reads still accept it.

### Removed

- Electro theme. A saved Electro or Sonar choice switches to Hyperline.

### Fixed

- `theme <unknown name>` switched to Lattice instead of reporting an error.
- Block and sphere casts reported distance to the contact point rather than how far the shape travelled.
- `execute_luau` with `resultFields` returned non-empty arrays as `[]`.
- `api` said a class didn't exist and then suggested the same name. It now says the class isn't enabled in this Studio.
- Union and other geometry results listed wrong paths for consumed same-named parts.
- `viewport op="focus"` returned unrounded numbers.

### Performance

- Resizing the panel no longer rewrites the settings file on every pixel.
- Live sync polls no longer pile up while Studio is busy.

## 1.0.0

### Added

- New panel design, Threadline. A line you type opens a thread, and every call and reply it causes hangs under it. Each call row shows a small latency bar. The activity band is one row, 18px shorter, and shows a live timer for the running call. The header uses icon buttons, and a row of theme dots replaces the theme drawer on the right edge.
- Electro theme, which replaces Sonar: a charged core with lightning arcs that strike faster as the session works. A saved Sonar choice switches to Electro.
- 18 more agents for `chat on`: Kimi Code, Cline, Kilo Code, Auggie, Qoder, Continue, Kiro, Mistral Vibe, Grok CLI, OpenHands, Hermes, OpenClaw, Warp Oz, Rovo Dev, Forge, pi, Letta Code and Trae Agent. That makes 31. The new adapters follow each vendor's documentation and haven't all been run yet, so please report any that misbehave.
- `terrain op="materials"` lists, sets and resets custom terrain material slots (Custom Terrain Materials, launched Oct 2026).
- `audio op="speech"` turns text into voice-line audio assets (Studio beta, Oct 2026).
- `universe op="logs"` shows server stack frames as script paths and line numbers that `script_read` can open, when Roblox provides them.

### Changed

- History bars slide in and grow in every theme, instead of jumping.
- The activity band stops redrawing while the panel is closed, and redraws at 15fps once the session has gone quiet.
- Dependencies updated (MCP SDK 1.32.2), with 4 security fixes in transitive dependencies.

### Fixed

- Long log lines no longer run past the panel's right edge, under the scrollbar.

Releases before 1.0 are in [docs/CHANGELOG-0.x.md](docs/CHANGELOG-0.x.md).
