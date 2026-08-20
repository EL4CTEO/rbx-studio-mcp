# Roblox Studio MCP

Free and open source (MIT). Connects Claude Code, Claude Desktop, Cursor, Codex, Gemini CLI — anything that speaks MCP — to a live Roblox Studio session.

Built around three things the other servers get wrong.

## 1. It pushes instead of polling

Every community Roblox Studio MCP server long-polls the plugin on a fixed interval, typically 500 ms. That adds up to half the poll period to every single call, and keeps an HTTP request in flight around the clock.

This one holds a Server-Sent Events stream via `HttpService:CreateWebStreamClient`, so commands arrive the moment they are issued and an idle connection costs nothing. Studio has supported this since August 2025.

Studio permits only 4 concurrent web streams and closes them after 30 minutes, so exactly one is held and reconnects are routine. Where web streams are unavailable the plugin falls back to long-poll automatically — same protocol, same handlers, nothing to configure.

**Measured, not asserted.** 50 sequential `studio.ping` round trips on each transport, one run, same machine and same place:

| | push (SSE) | long-poll |
|---|---|---|
| mean | **13.6 ms** | 25.8 ms |
| median | **12.8 ms** | 29.9 ms |
| p95 | **22.0 ms** | 30.9 ms |
| best | 6.9 ms | 12.9 ms |

Roughly twice as fast, and the median gap is wider than the mean gap — polling's cost is not an occasional slow call but a floor under every one of them. Sequential rather than parallel on purpose: an agent waits for each answer before choosing what to ask next, so serial round trips are the figure that matters.

Reproduce it yourself against your own Studio, no source changes and nothing to shut down:

```
node scripts/latency.mjs --count 50 --compare
```

It times the transport in use, switches the plugin to the other, times that, and puts it back the way it found it.

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

Competing servers ship 43–51 thin wrappers around individual API calls — more tools to pick wrong from, each one a restatement of an API method the agent then has to assemble into something useful.

This one ships **26 workflow-shaped tools**, whose schemas measure ~14k tokens (`tools/list`, 56.6k characters). Fewer tools, and each covers a job rather than a call: `find` alone replaces six competitor tools by taking name, class, property and tag filters together.

Be clear about what that does and does not buy. The tool *count* is roughly half, but the token cost is not, because these descriptions are long on purpose — they carry what was measured rather than what the API reference says, so the agent is told that a breakpoint set to continue never captures, that a non-overlapping `subtract` returns the original whole, and that screenshots are unavailable mid-playtest. Paying a few hundred tokens once to stop an agent burning a dozen calls learning that the hard way is the trade being made, and it is a trade, not a free win.

Every list is cursor-paged, every response is capped at 25k characters with an explicit marker when something was left out, and every tool takes `detail: concise | standard | full` so the agent chooses what it pays for.

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
| **this** | 26 | **SSE push** | **yes** | **yes, cancel on failure** | **yes** | MIT |
| [Roblox built-in](https://create.roblox.com/docs/studio/mcp) | ~27 | stdio from Studio | partial | — | n/a | closed source |
| [Chrrxs](https://github.com/Chrrxs/robloxstudio-mcp) | ~40 | HTTP poll | no | partial | no | MIT |
| [drgost1](https://github.com/drgost1/robloxstudio-mcp) | 51 | HTTP poll 500 ms | no | yes | no | MIT |
| [boshyxd](https://github.com/boshyxd/robloxstudio-mcp) | 43 | HTTP long-poll | no | no | no | MIT (archived) |
| [Roblox/studio-rust-mcp-server](https://github.com/Roblox/studio-rust-mcp-server) | 2 | HTTP | no | no | no | MIT (superseded) |

Roblox's built-in server is the one to beat: it is first-party, free, and has AI mesh and material generation. It is also closed source, caps results at 10–50, and has no bulk instance or property operations and no undo integration.

**Not built here:** terrain, and AI mesh and material generation.

Generation is the one worth explaining, because it is half-open rather than shut.
`GenerationService:GenerateModelAsync` **does** work from a plugin — called with a
text prompt it returns a real `Model` after about 40 seconds, wheels and body as
separate `MeshPart`s, no `RobloxScriptSecurity` loader involved. What it will not
do is generate anything you ask for: the schema must be one of exactly two
values, `Car5` or `Body1`, so it makes cars and avatar bodies and nothing else.
`GenerateMeshAsync` is present but refuses every input shape tried with "Unable
to cast value to Object", and the `LoadModelFromGlbAsync` / `LoadModelFromUrlAsync`
pair that would fetch a generated asset does require `RobloxScriptSecurity` and
is closed to plugins. So arbitrary text-to-mesh remains the built-in server's,
and a `generate` tool here would honestly be called `generate_car`.

If you need terrain or general generation today, keep the built-in server
alongside this one. The goal is to replace it; that is not true yet.

### Debugging and playtests

Both work, and both took finding the right API rather than the obvious one.

`playtest` starts and stops real playtests through `StudioTestService` — Play
mode with a character, Run mode, or a multiplayer session. `RunService:Run()` is
the API this looks like it should use; it is marked `PluginSecurity`, accepts the
call, and does nothing at all. Arguments passed to a test are readable inside it
with `GetTestArgs()`, and whatever the test returns through `EndTest(value)`
comes back to the caller, so a scripted check runs end to end without anyone
touching Studio.

`debug` sets conditional breakpoints and logpoints through
`ScriptDebuggerService` and reports the stack and the variables in scope when one
is hit. Not `DebuggerManager`, which is the legacy service and refuses plugins
outright.

**The debugger needs a Studio beta feature enabled.** In `File → Beta Features`,
turn on **API debugger Luau**. Without it `AddBreakpoint` fails with a flat
"Failed to execute AddBreakpoint request" that names no cause; with it the same
call returns `{Line = 5, Verified = true}`.

Two behaviours worth knowing, both measured:

- A breakpoint either stops or logs, and it cannot do both. `ContinueExecution`
  reads like a convenience and is not: stopping is the only thing that raises
  `OnStopped`, so a breakpoint set to continue never captures anything at all.
  It verified, it fired, and it reported nothing — which looked exactly like a
  condition that never matched. So a breakpoint with `logMessage` continues and
  prints the one value you named in advance, and a breakpoint without one stops
  briefly and hands back the whole frame.
- Put a breakpoint on a line that *does* something. A `return` or an `end` can
  report `Verified` and then never fire, which reads like a broken condition.

### Not reached yet, and why

Neither of these is settled. Both were first written here as things a plugin
could not do, which is the same word this project has already been wrong with
twice — `RunService:Run` looked like proof that playtests were out of reach, and
`DebuggerManager` looked like proof that debugging was. Both were the wrong API,
not a closed door.

| | where it stands |
|---|---|
| Reading a playtest **client's** output | Studio bars client sessions from making HTTP requests, so the client cannot talk to this bridge directly. It is not sealed off, though: client and server DataModels replicate to each other, so a plugin on the client could pass its log to the server session over a `RemoteEvent` and let that forward it. Not built. |
| Stepping through code | `OnStopped` must return its resume decision synchronously, so it cannot wait for a tool call — interactive, one-step-per-request debugging is genuinely out. But the decision it returns may be `StepInto`, `StepOut` or `StepOver` as well as `Resume`, so a "step N lines from here and record each stop" tool is possible. Not built. |

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

`build:plugin` compiles every Luau file before packing and refuses to pack if
one fails, because nothing else in the build ever read the Luau — a syntax error
used to ship, install, and surface only when Studio next loaded the plugin. Put
`luau-compile` and `luau-analyze` from
[the Luau releases](https://github.com/luau-lang/luau/releases) on `PATH` or in
`tools/`.

### Evaluations

`evals/` holds ten questions that can only be answered by driving a real Studio
session through these tools, plus the fixture that makes their answers stable —
this server has no fixed dataset of its own, since it drives whatever place you
have open. See [evals/README.md](evals/README.md).

## Licence

MIT.
