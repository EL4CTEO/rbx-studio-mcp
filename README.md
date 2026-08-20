# Roblox Studio MCP

Connects Claude Code, Claude Desktop, Cursor, Codex, Gemini CLI — anything that speaks MCP — to a live Roblox Studio session. 29 tools. Free, MIT.

## Install

```bash
claude mcp add roblox-studio -- npx -y roblox-studio-mcp   # Claude Code
npx -y roblox-studio-mcp --install-plugin                  # the Studio plugin
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

Open Studio, accept the `127.0.0.1` permission prompt, and check the **Studio MCP** toolbar button. Verify with `studio_status`.

Server and plugin default to port **44755** — change with `--port` or `ROBLOX_STUDIO_MCP_PORT`, and match it in the plugin widget. Loopback only.

## Why this one

**Push, not poll.** Others long-poll every 500 ms. This holds an SSE stream, so commands arrive immediately and idle costs nothing. Falls back to long-poll automatically where web streams are unavailable.

| 50 sequential round trips | SSE | long-poll |
|---|---|---|
| mean | **13.6 ms** | 25.8 ms |
| median | **12.8 ms** | 29.9 ms |
| p95 | **22.0 ms** | 30.9 ms |

Reproduce with `node scripts/latency.mjs --count 50 --compare`.

**Safe script edits.** Others assign `script.Source`, which discards your unsaved editor buffer. Every write here goes through `ScriptEditorService:UpdateSourceAsync` and every read through `GetEditorSource`. Batched edits are all-or-nothing.

**One Ctrl+Z per action.** Instance changes are wrapped in a `ChangeHistoryService` recording named after the tool that made them.

**Cheap in context.** 29 workflow-shaped tools (~16k tokens of schema) instead of 43–51 thin API wrappers — `find` alone replaces six. Everything is cursor-paged and capped, with `detail: concise | standard | full`. Property validation comes from the live Roblox API dump, so new properties work the day they ship and typos get suggestions (`Anchorred` → `Anchored`).

## Tools

| | |
|---|---|
| **Discover** | `studio_status` `tree` `inspect` `find` `api` |
| **Scripts** | `script_read` `script_edit` `script_grep` `script_create` |
| **Instances** | `create` `modify` `delete` `move` — all batched, one undo step |
| **World** | `geometry` `assets` `collision` `undo` |
| **Run & debug** | `playtest` `execute_luau` `character` `input` `console` `debug` `performance` |
| **Look** | `screenshot` `viewport` `device` |
| **Session** | `list_studios` `set_active_studio` |

Each tool carries its own documentation in its MCP schema. A few things worth knowing up front:

- `input` sends real key and mouse events to a running playtest. `character` pathfinds — use it for going places, `input` for testing controls.
- `device` emulates 42 phones, tablets and consoles. Emulation persists until `device op="stop"`.
- `screenshot` does not work during a playtest; Studio only lets client sessions capture, and bars them from HTTP.
- `debug` needs **API debugger Luau** enabled in `File → Beta Features`.

## Compared to what else exists

| | tools | transport | editor-safe writes | undo recording | live API dump | licence |
|---|---|---|---|---|---|---|
| **this** | 29 | **SSE push** | **yes** | **yes** | **yes** | MIT |
| [Roblox built-in](https://create.roblox.com/docs/studio/mcp) | ~27 | stdio | partial | — | n/a | closed source |
| [Chrrxs](https://github.com/Chrrxs/robloxstudio-mcp) | ~40 | poll | no | partial | no | MIT |
| [drgost1](https://github.com/drgost1/robloxstudio-mcp) | 51 | poll 500 ms | no | yes | no | MIT |
| [boshyxd](https://github.com/boshyxd/robloxstudio-mcp) | 43 | long-poll | no | no | no | MIT (archived) |
| [Roblox/studio-rust-mcp-server](https://github.com/Roblox/studio-rust-mcp-server) | 2 | HTTP | no | no | no | MIT (superseded) |

Not built here: terrain, and AI mesh and material generation. Keep the built-in server alongside if you need those.

## Security

Binds `127.0.0.1` only, rejects any request carrying an `Origin` header, and requires a custom header a browser cannot set cross-origin — which closes the DNS-rebinding hole a plain localhost port leaves open. Studio grants HTTP per plugin and per URL, so this never touches your experience's "Allow HTTP Requests" setting.

## Development

```bash
npm install
npm run build          # TypeScript -> dist/
npm run build:plugin   # plugin/src -> build/StudioMCP.rbxmx
npm run install:plugin # build + copy into the Studio plugins folder
npm test               # Luau unit tests
```

`build:plugin` compiles every Luau file first and refuses to pack if one fails. Put `luau`, `luau-compile` and `luau-analyze` from [the Luau releases](https://github.com/luau-lang/luau/releases) on `PATH` or in `tools/`.

`evals/` holds ten questions answerable only by driving a real Studio session, plus a fixture that makes the answers stable — see [evals/README.md](evals/README.md).

## Licence

MIT.
