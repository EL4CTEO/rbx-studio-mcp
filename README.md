# Roblox Studio MCP

Free and open source (MIT). Connects Claude Code, Claude Desktop, Cursor, Codex, Gemini CLI — anything that speaks MCP — to a live Roblox Studio session.

29 tools covering the hierarchy, scripts, instances, geometry, playtests, input, debugging, performance and screenshots.

## Install

```bash
npx -y roblox-studio-mcp        # the server
```

Register it with your MCP client:

```bash
# Claude Code
claude mcp add roblox-studio -- npx -y roblox-studio-mcp
```

<details>
<summary>Claude Desktop / Cursor JSON</summary>

```json
{
  "mcpServers": {
    "roblox-studio": {
      "command": "npx",
      "args": ["-y", "roblox-studio-mcp"]
    }
  }
}
```
</details>

Then install the Studio plugin:

```bash
npx -y roblox-studio-mcp --install-plugin
```

That drops it into your Studio plugins folder, which Studio watches — so it also works as an upgrade while Studio is open. Or grab `StudioMCP.rbxmx` from [Releases](https://github.com/EL4CTEO/roblox-studio-mcp/releases) and copy it there yourself.

Open Studio. The plugin connects on its own; the **Studio MCP** toolbar button toggles the connection and shows status. The first request pops a Studio permission prompt for `127.0.0.1` — accept it.

Verify with `studio_status`.

### Ports

Server and plugin default to **44755**. Change it with `--port` (or `ROBLOX_STUDIO_MCP_PORT`) and set the same port in the plugin widget. The bridge binds loopback only.

---

## What makes it different

### It pushes instead of polling

Other community servers long-poll the plugin on a fixed interval, typically 500 ms, which adds up to half the poll period to every call. This one holds a Server-Sent Events stream, so commands arrive the moment they are issued and an idle connection costs nothing. Where web streams are unavailable it falls back to long-poll automatically — same protocol, nothing to configure.

50 sequential round trips on each transport, same machine, same place:

| | push (SSE) | long-poll |
|---|---|---|
| mean | **13.6 ms** | 25.8 ms |
| median | **12.8 ms** | 29.9 ms |
| p95 | **22.0 ms** | 30.9 ms |
| best | 6.9 ms | 12.9 ms |

Reproduce it against your own Studio — it times the transport in use, switches, times the other, and puts it back:

```bash
node scripts/latency.mjs --count 50 --compare
```

### It doesn't corrupt scripts you have open

Other servers assign `script.Source` directly. When that script is open in the editor, the editor holds its own buffer, and your unsaved edits are discarded or the write is silently reverted. Every write here goes through `ScriptEditorService:UpdateSourceAsync`, and every read through `GetEditorSource`, so the agent sees what you see.

Batched edits are all-or-nothing: a find that matches nothing — or matches twice — fails with the place untouched rather than half-edited.

Instance changes are wrapped in a `ChangeHistoryService` recording, so one agent action is **one Ctrl+Z**, named after the tool that did it.

### It stays cheap in context

Competing servers ship 43–51 thin wrappers around individual API calls. This one ships 29 workflow-shaped tools (~16k tokens of schema), each covering a job rather than a call — `find` alone replaces six competitor tools by taking name, class, property and tag filters together.

Every list is cursor-paged, every response is capped with an explicit marker when something was left out, and every list tool takes `detail: concise | standard | full`.

Property handling comes from the live Roblox API dump, refreshed daily, so new engine properties work the day they ship and a typo gets a suggestion (`Anchorred` → `Anchored`) instead of a dead end.

---

## Tools

**Discover**

| tool | |
|---|---|
| `studio_status` | Place, play mode, selection, open script tabs with cursor position |
| `tree` | Browse the hierarchy, depth- and class-filtered, cursor-paged |
| `inspect` | Properties, attributes, tags and children of one or many paths |
| `find` | One search over name, class, property value and tag |
| `api` | Properties, methods and events of any class, read from the running engine |

**Scripts**

| tool | |
|---|---|
| `script_read` | Read source by line range |
| `script_edit` | Batch line-range or find/replace edits across scripts, atomic |
| `script_grep` | Regex across all scripts with context lines |
| `script_create` | Create scripts |

**Instances** — all batched, all one undo step

| tool | |
|---|---|
| `create` | Create with properties, attributes and tags set at creation |
| `modify` | Set properties, attributes and tags; supports relative values |
| `delete` | Delete |
| `move` | Reparent, clone or duplicate |

**World**

| tool | |
|---|---|
| `geometry` | Solid modelling — `union`, `subtract`, `intersect`, `fragment` |
| `assets` | Creator Store search and insert |
| `collision` | Collision groups — `list`, `create`, `assign`, `collidable` |
| `undo` | `undo`, `redo`, `status` |

**Run and debug**

| tool | |
|---|---|
| `playtest` | `play`, `run`, `multiplayer`, `stop`, `state` |
| `execute_luau` | Arbitrary Luau, returning whatever it printed, returned or threw |
| `character` | `moveTo` with pathfinding, `act` (jump, sit, equip, activate, respawn, teleport), `state` |
| `input` | Real keyboard and mouse events sent to a running playtest |
| `console` | Filtered log tail |
| `debug` | Breakpoints and logpoints — `set`, `clear`, `snapshots`, `exceptions` |
| `performance` | `snapshot`, `profile`, `coverage`, `scene` |

**Look**

| tool | |
|---|---|
| `screenshot` | The viewport as an image |
| `viewport` | `select`, `raycast`, `focus`, `camera` |
| `device` | Emulate 42 real phones, tablets and consoles |

**Session**

| tool | |
|---|---|
| `list_studios` | Every connected Studio window |
| `set_active_studio` | Choose which one tools target |

### Notes on a few of them

`input` sends real key presses and mouse clicks to a running playtest — use it for anything bound to a control (does E open the door, does the sprint key work). Use `character` for going places, since it pathfinds around obstacles in one call.

`device` resizes the viewport to a real phone, tablet or console. Set a device, take a `screenshot`, look. Emulation persists until you call `device op="stop"`, so the screenshot caption and `studio_status` both tell you when one is active.

`screenshot` is unavailable while a playtest is running — Studio only lets a client session capture the screen, and forbids client sessions from making HTTP requests. Stop the playtest and screenshot in edit mode.

**`debug` needs a Studio beta feature.** In `File → Beta Features`, turn on **API debugger Luau**. Without it, setting a breakpoint fails with an error that names no cause. Note also that a breakpoint either stops or logs and cannot do both, and that a breakpoint on a `return` or an `end` may verify and then never fire — put it on a line that does something.

---

## Compared to what else exists

| | tools | transport | editor-safe writes | undo recording | live API dump | licence |
|---|---|---|---|---|---|---|
| **this** | 29 | **SSE push** | **yes** | **yes, cancel on failure** | **yes** | MIT |
| [Roblox built-in](https://create.roblox.com/docs/studio/mcp) | ~27 | stdio from Studio | partial | — | n/a | closed source |
| [Chrrxs](https://github.com/Chrrxs/robloxstudio-mcp) | ~40 | HTTP poll | no | partial | no | MIT |
| [drgost1](https://github.com/drgost1/robloxstudio-mcp) | 51 | HTTP poll 500 ms | no | yes | no | MIT |
| [boshyxd](https://github.com/boshyxd/robloxstudio-mcp) | 43 | HTTP long-poll | no | no | no | MIT (archived) |
| [Roblox/studio-rust-mcp-server](https://github.com/Roblox/studio-rust-mcp-server) | 2 | HTTP | no | no | no | MIT (superseded) |

**Not built here:** terrain, and AI mesh and material generation. If you need those, keep the built-in server alongside this one.

## Security

The bridge listens on `127.0.0.1` only, rejects any request carrying an `Origin` header, and requires a custom header that a browser cannot set cross-origin without a preflight it never answers. Together that closes the DNS-rebinding hole a plain localhost port would leave open.

Studio grants HTTP access per plugin and per URL through Plugin Management, so this never touches your experience's "Allow HTTP Requests" setting.

## Development

```bash
npm install
npm run build          # TypeScript -> dist/
npm run build:plugin   # plugin/src -> build/StudioMCP.rbxmx
npm run install:plugin # build + copy into the Studio plugins folder
npm test               # Luau unit tests
```

`build:plugin` compiles every Luau file before packing and refuses to pack if one fails. Put `luau`, `luau-compile` and `luau-analyze` from [the Luau releases](https://github.com/luau-lang/luau/releases) on `PATH` or in `tools/`.

`plugin/default.project.json` is there for Rojo users; the bundled builder means you do not need a Luau toolchain to produce an installable plugin.

### Evaluations

`evals/` holds ten questions that can only be answered by driving a real Studio session through these tools, plus the fixture that makes their answers stable. See [evals/README.md](evals/README.md).

## Licence

MIT.
