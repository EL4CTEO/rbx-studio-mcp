# Roblox Studio MCP

Free and open source (MIT). Connects Claude Code, Claude Desktop, Cursor, Codex, Gemini CLI — anything that speaks MCP — to a live Roblox Studio session.

Built around three things the other servers get wrong.

## 1. It pushes instead of polling

Every community Roblox Studio MCP server long-polls the plugin on a fixed interval, typically 500 ms. That adds up to half the poll period to every single call, and keeps an HTTP request in flight around the clock.

This one holds a Server-Sent Events stream via `HttpService:CreateWebStreamClient`, so commands arrive the moment they are issued and an idle connection costs nothing. Studio has supported this since August 2025.

Studio permits only 4 concurrent web streams and closes them after 30 minutes, so exactly one is held and reconnects are routine. Where web streams are unavailable the plugin falls back to long-poll automatically — same protocol, same handlers, nothing to configure.

## 2. It doesn't corrupt scripts you have open

Other servers assign `script.Source` directly. When that script is open in the Studio editor, the editor holds its own buffer: your unsaved edits get discarded, or the write gets silently reverted.

This server routes every write through `ScriptEditorService:UpdateSourceAsync`, which is the API Roblox added to close exactly that gap, and reads through `GetEditorSource` so the agent sees what you see rather than stale saved text.

A batch of edits is also all-or-nothing. Every script is read and transformed in
memory before anything is written, so a `find` that matches nothing — or matches
twice — fails with the place untouched rather than half-edited.

Instance changes are wrapped in a `ChangeHistoryService` recording, so one agent
action is **one Ctrl+Z**, named after the tool that did it. Source changes are
not: `UpdateSourceAsync` goes through the script editor's own per-document
history, so Ctrl+Z in a script tab reverts that script. Anything claiming a
recording rolls back a script edit has not tested it — we did, and it does not.

## 3. It stays cheap in context

Competing servers ship 43–51 thin wrappers around individual API calls. That is 15–20k tokens of tool schemas loaded before the agent does anything, and more tools to pick wrong from.

This one ships 14 workflow-shaped tools today. `find` alone replaces six competitor tools. Every list is cursor-paged, every response is capped at 25k characters with an explicit marker when something was left out, and every tool takes `detail: concise | standard | full` so the agent chooses what it pays for.

Property handling comes from the **live Roblox API dump**, refreshed daily, not a hardcoded table — so new engine properties work the day they ship, and a typo gets a suggestion (`Anchorred` → `Anchored`) instead of a dead end.

---

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

Then install the Studio plugin. From a clone:

```bash
npm install
npm run install:plugin      # builds and drops it in your Studio plugins folder
```

Open Studio. The plugin connects on its own; the **Studio MCP** toolbar button toggles the connection and shows status. The first request pops a Studio permission prompt for `127.0.0.1` — accept it.

Verify with `studio_status`.

### Ports

Server and plugin default to **44755**. Change it with `--port` (or `ROBLOX_STUDIO_MCP_PORT`) and set the same port in the plugin widget. The bridge binds loopback only.

## Compared to what else exists

| | tools | transport | editor-safe writes | undo recording | live API dump | licence |
|---|---|---|---|---|---|---|
| **this** | 14 | **SSE push** | **yes** | **yes, cancel on failure** | **yes** | MIT |
| [Roblox built-in](https://create.roblox.com/docs/studio/mcp) | ~27 | stdio from Studio | partial | — | n/a | closed source |
| [Chrrxs](https://github.com/Chrrxs/robloxstudio-mcp) | ~40 | HTTP poll | no | partial | no | MIT |
| [drgost1](https://github.com/drgost1/robloxstudio-mcp) | 51 | HTTP poll 500 ms | no | yes | no | MIT |
| [boshyxd](https://github.com/boshyxd/robloxstudio-mcp) | 43 | HTTP long-poll | no | no | no | MIT (archived) |
| [Roblox/studio-rust-mcp-server](https://github.com/Roblox/studio-rust-mcp-server) | 2 | HTTP | no | no | no | MIT (superseded) |

Roblox's built-in server is the one to beat: it is first-party, free, and has AI mesh and material generation. It is also closed source, caps results at 10–50, and has no bulk instance or property operations and no undo integration.

**Not yet built here:** `execute_luau`, playtest control, console output, screenshots, terrain, Creator Store insertion, and the AI generation tools. If you need those today, keep the built-in server alongside this one. The goal is to replace it; that is not true yet.

## Security

The bridge listens on `127.0.0.1` only, rejects any request carrying an `Origin` header, and requires a custom header that a browser cannot set cross-origin without a preflight it never answers. Together that closes the DNS-rebinding hole a plain localhost port would leave open.

Studio grants HTTP access per plugin and per URL through Plugin Management, so this never touches your experience's "Allow HTTP Requests" setting.

## Development

```bash
npm install
npm run build          # TypeScript -> dist/
npm run build:plugin   # plugin/src -> build/StudioMCP.rbxmx
npm run install:plugin # build + copy into the Studio plugins folder
```

`plugin/default.project.json` is there for Rojo users; the bundled builder means you do not need a Luau toolchain to produce an installable plugin.

## Licence

MIT.
