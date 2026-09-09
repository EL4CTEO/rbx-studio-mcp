# Roblox Studio MCP

Let an AI agent drive Roblox Studio: read your place, edit scripts, build and generate geometry, run playtests, take screenshots. 30 tools. MIT.

![The Studio MCP panel: a live activity band, a call log with latencies, and the theme drawer open](docs/rbx-studio.png)

## Install

**1. The Studio plugin**

```bash
npx -y @el4cteo/rbx-studio-mcp --install-plugin
```

Or download `StudioMCP.rbxmx` from [Releases](https://github.com/EL4CTEO/rbx-studio-mcp/releases) into your Studio plugins folder.

**2. The server**, in whichever client you use:

<details>
<summary><b>Claude Code</b></summary>

```bash
claude mcp add roblox-studio -- npx -y @el4cteo/rbx-studio-mcp
```
</details>

<details>
<summary><b>Codex CLI</b></summary>

```bash
codex mcp add roblox-studio -- npx -y @el4cteo/rbx-studio-mcp
```
</details>

<details>
<summary><b>Cursor</b> — <code>~/.cursor/mcp.json</code> or <code>.cursor/mcp.json</code></summary>

```json
{
  "mcpServers": {
    "roblox-studio": {
      "command": "npx",
      "args": ["-y", "@el4cteo/rbx-studio-mcp"]
    }
  }
}
```
</details>

<details>
<summary><b>Claude Desktop</b> — <code>claude_desktop_config.json</code></summary>

```json
{
  "mcpServers": {
    "roblox-studio": {
      "command": "npx",
      "args": ["-y", "@el4cteo/rbx-studio-mcp"]
    }
  }
}
```
</details>

<details>
<summary><b>Gemini CLI</b> — <code>~/.gemini/settings.json</code></summary>

```json
{
  "mcpServers": {
    "roblox-studio": {
      "command": "npx",
      "args": ["-y", "@el4cteo/rbx-studio-mcp"]
    }
  }
}
```
</details>

<details>
<summary><b>Windsurf</b> — <code>~/.codeium/windsurf/mcp_config.json</code></summary>

```json
{
  "mcpServers": {
    "roblox-studio": {
      "command": "npx",
      "args": ["-y", "@el4cteo/rbx-studio-mcp"]
    }
  }
}
```
</details>

<details>
<summary><b>VS Code / Copilot</b> — <code>.vscode/mcp.json</code></summary>

```json
{
  "servers": {
    "roblox-studio": {
      "type": "stdio",
      "command": "npx",
      "args": ["-y", "@el4cteo/rbx-studio-mcp"]
    }
  }
}
```
</details>

<details>
<summary><b>opencode</b> — <code>opencode.json</code></summary>

```json
{
  "$schema": "https://opencode.ai/config.json",
  "mcp": {
    "roblox-studio": {
      "type": "local",
      "command": ["npx", "-y", "@el4cteo/rbx-studio-mcp"],
      "enabled": true
    }
  }
}
```
</details>

**3.** Open Studio and accept the `127.0.0.1` prompt — the plugin connects automatically. Verify with `studio_status`.

**4.** `debug` additionally needs **Debugger Luau API** in File → Beta Features, plus a Studio restart. Nothing else requires it.

![The Debugger Luau API beta feature toggle in Studio](docs/betatoggle.png)

Port defaults to **44755** — change with `--port` or `ROBLOX_STUDIO_MCP_PORT`, and match it in the plugin widget. Loopback only.

If anything looks wrong, run the health check. It reports Node, the plugin install, the bridge, and every connected Studio, and ends each line with the fix:

```bash
npx -y @el4cteo/rbx-studio-mcp doctor
```

## Multiple agents

Register the server in as many clients as you like. No extra configuration.

Each agent keeps its own target, so two agents can work on two open places. Subagents share their parent's target — give them an explicit `studioId` per call.

## Tools

| | |
|---|---|
| **Session** | `studio_status` `list_studios` `set_active_studio` |
| **Discover** | `tree` `inspect` `find` `api` |
| **Scripts** | `script_read` `script_edit` `script_grep` `script_create` |
| **Instances** | `create` `modify` `delete` `move` |
| **World** | `geometry` `generate` `assets` `collision` `undo` |
| **Run & debug** | `playtest` `execute_luau` `character` `input` `console` `debug` `performance` |
| **Look** | `screenshot` `viewport` `device` |

`geometry` holds every mesh operation: `union`, `subtract`, `intersect`, `fragment`, `segment` (cut a mesh into parts you name) and `sweep` (the volume a part moves through, and what it would hit).

`generate` builds 3D models from a prompt using Roblox's Cube model — `Body1` for props, `Car5` for a body and four named wheels a script can drive, or your own part names.

Gotchas: during a playtest two sessions connect — pass `studioId` explicitly and use the edit session for anything that must persist. `device` emulation persists until `device op="stop"`. Generated meshes are edit-mode only; their content reads as empty inside a playtest.

## The console panel

Every call is logged with its latency, above a trace of the last forty. The badge names which agents are connected, with process id and uptime.

Under the header is a command line. Type a command, or type a sentence and it goes to a coding agent.

| | |
|---|---|
| `help` | list everything |
| `doctor` | check every part of the setup |
| `status` `version` `place` `clients` | what this session is |
| `studios` `use <n>` | which Studio window calls land on |
| `theme [name]` `visuals` `log [level]` `clear` `copy` | the panel itself |
| `port [n]` `reconnect` | the connection |
| `agent [use <id>\|new]` `stop` | which coding agent runs your prompts |
| anything else | sent to that agent |

Up and down walk the history, Tab completes.

**Prompts start a real agent.** The bridge runs whichever tool you have on PATH — Claude Code, Codex, opencode, DeepSeek Harness, Gemini, Cursor, Amp, Qwen Code, Factory Droid, goose, GitHub Copilot CLI, Aider, Crush — in headless mode. It connects back to this same bridge, drives the same Studio, and its work streams into the log line by line. It is a separate session from the terminal you may already have open, billed separately, and it is allowed the `rbx-studio` tools and nothing else. `stop` cancels it.

Hover the tab on the right edge for eight themes — Lattice, Observatory, Orbit, Void, Nebula, Aurora, Phosphor, Blueprint. Each redraws the activity band, not just its colours. Your pick is remembered.

## DeepSeek Harness (dsh)

dsh is "everything is a plugin", and this server becomes one through its MCP bridge. One overlay row, and the tools arrive as `mcp__rbx-studio__*` — the same names Claude Code and Codex use.

```sh
dsh --profile headless --patch config/dsh.cordis.yml "add a spawn point"
```

To keep it, append that row to your own patch layer — `$DSH_HOME/profiles/<name>/cordis.patch.yml` for one profile, `$DSH_HOME/cordis.patch.yml` for all of them. Don't overwrite the file; it may already hold unrelated patches.

`config/dsh.cordis.yml` in this repo is the row. The console panel also lists `dsh` as an agent, and passes the overlay itself, so a prompt typed there works before you have merged anything.

Two limits, both dsh's rather than ours: its headless profile prints the final answer instead of streaming, so the panel shows the reply at the end rather than step by step, and it has no `--resume`, so every prompt is a fresh conversation. It needs `DEEPSEEK_API_KEY`.

## Batching

Every write tool takes an array — ten script edits is one call.

| tool | takes | cap |
|---|---|---|
| `create` | instances, each nesting `children` to any depth | 100 |
| `modify` | entries, each with an unlimited list of `paths` | 100 entries |
| `delete` | paths | 200 |
| `move` | moves | 200 |
| `script_edit` | edits, across any number of scripts | 50 |
| `script_create` | scripts | 50 |
| `inspect` | paths | 50 |
| `input` | input steps, delivered in order | 40 |

`modify` caps *entries*, not targets — one entry can anchor five hundred parts.

Each batch is one **Ctrl+Z**, and all-or-nothing: a failed match leaves the place untouched.

## Why this one

- **Push, not poll.** 50 sequential round trips average 13.6 ms, against 25.8 ms polling — reproduce with `node scripts/latency.mjs --count 50 --compare`.
- **Safe script edits.** Writes go through `ScriptEditorService:UpdateSourceAsync`, so your unsaved editor buffer survives.
- **Edits can refuse to be stale.** `script_read` prints a `rev`; pass it back and the write is rejected if anyone changed the script meanwhile, instead of landing on lines that moved.
- **One Ctrl+Z per call.** Every batch is a single undo recording.
- **Property names are checked** against the running engine's API dump, so a typo comes back as `Anchorred` → `Anchored` instead of a runtime error.
- **~16k tokens of schema**, cursor-paged and capped, with `detail: concise | standard | full`.

Not built here: material generation.

## Security

Loopback only. Requires a header a browser cannot set cross-origin, which closes the DNS-rebinding hole. Your experience's "Allow HTTP Requests" setting is untouched.

## Development

```bash
npm install
npm run build          # TypeScript -> dist/
npm run build:plugin   # plugin/src -> build/StudioMCP.rbxmx
npm run install:plugin # build + copy into the Studio plugins folder
npm test               # plugin (Luau) + bridge (Node) tests
```

Needs `luau`, `luau-compile` and `luau-analyze` from [the Luau releases](https://github.com/luau-lang/luau/releases) on `PATH` or in `tools/`.

`evals/` holds ten questions answerable only by driving a real Studio session — see [evals/README.md](evals/README.md).

## Licence

MIT.
