/**
 * Runs a coding agent next to the user, on the panel's behalf.
 *
 * The console panel has a prompt line, and free text typed into it is not a
 * command -- it is a request for an agent. MCP gives no way to deliver that to
 * the agent already attached to this bridge: a server answers clients, it never
 * calls them, so there is no inbound channel into a session someone is sitting
 * in. What there IS, on every machine that has one of these tools installed, is
 * a headless mode. So the bridge starts its own.
 *
 * The agent it starts connects back to this same bridge as an ordinary MCP
 * client -- the port is taken, so its server becomes a peer and proxies -- and
 * drives the same Studio the user is looking at. Its output is streamed into
 * the console log line by line, which is what makes the panel its face rather
 * than a black box with a spinner.
 *
 * Deliberately a registry rather than a `claude` integration. Users arrive with
 * whatever harness they already use, and every one of them ships the same three
 * things: a binary, a one-shot flag, and a way to ask for machine-readable
 * output. Adding one is a table entry, and a harness nobody wrote an adapter
 * for still works through `generic`, which simply prints what it prints.
 */
import { type ChildProcess, spawn } from "node:child_process";
import { existsSync, mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { delimiter, dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

/** One row for the console, in the same shape the plugin logs. */
export interface HarnessLine {
  level: "ok" | "error" | "warn" | "info" | "dim" | "call" | "reply";
  message: string;
  detail?: string;
}

interface Reading {
  lines: HarnessLine[];
  /** A session id the harness just told us, so a follow-up can continue it. */
  session?: string;
}

export interface Harness {
  id: string;
  label: string;
  /** Executable looked up on PATH. */
  bin: string;
  /**
   * Arguments that hand this harness our MCP server on the command line.
   *
   * Takes nothing, because the harnesses do not agree on a format: Claude reads
   * a JSON config file, dsh reads a Cordis overlay in YAML. Each one calls the
   * writer it can read rather than being handed a file it cannot.
   *
   * Omitted by harnesses that cannot be told at launch. Those are expected to
   * have the server configured already, which is the normal case -- the user is
   * running this panel because their agent is wired to it.
   */
  mcpFlag?: () => string[];
  argv: (prompt: string, session: string | null) => string[];
  read: (line: string) => Reading;
}

const NOTHING: Reading = { lines: [] };

/** JSON if it parses, null otherwise. Harness stdout carries plain lines too. */
function parse(line: string): any {
  const text = line.trim();
  if (text === "" || (text[0] !== "{" && text[0] !== "[")) return null;
  try {
    return JSON.parse(text);
  } catch {
    return null;
  }
}

/** A tool call written the way the console writes its own. */
function toolLine(name: string, input: unknown): HarnessLine {
  const short = name.replace(/^mcp__[^_]+__/, "").replace(/^mcp__/, "");
  let detail: string | undefined;
  if (input !== null && typeof input === "object") {
    const parts = Object.entries(input as Record<string, unknown>)
      .filter(([, value]) => typeof value === "string" || typeof value === "number")
      .slice(0, 2)
      // Flattened before it is cut, not after: a Luau snippet passed to
      // execute_luau is multi-line, and 32 characters of it took a newline
      // along into a log whose rows are lines.
      .map(([key, value]) => key + "=" + String(value).replace(/\s+/g, " ").slice(0, 32));
    if (parts.length > 0) detail = parts.join(" ");
  }
  return { level: "call", message: short, detail };
}

/** Collapses a paragraph into the one-line rows a console log can hold. */
function say(text: string): HarnessLine[] {
  return text
    .split("\n")
    .map((piece) => piece.trim())
    .filter((piece) => piece !== "")
    .map((piece) => ({ level: "reply" as const, message: piece }));
}

/**
 * Claude Code. `--print` with `stream-json` emits one JSON object per step,
 * which is exactly the granularity this log wants: a row per thought and a row
 * per tool call, rather than a wall of text at the end.
 */
const claude: Harness = {
  id: "claude",
  label: "Claude Code",
  bin: "claude",
  mcpFlag: () => ["--mcp-config", mcpConfig()],
  argv: (prompt, session) => [
    ...(session === null ? [] : ["--resume", session]),
    "--print",
    prompt,
    "--output-format",
    "stream-json",
    "--verbose",
    // A headless agent cannot show an approval dialog, so what it may do is
    // decided here rather than asked for later. Studio tools and nothing else:
    // this prompt came from a Studio panel, and a request typed there is not
    // consent to edit the user's disk.
    "--allowedTools",
    "mcp__rbx-studio",
    "--permission-mode",
    "dontAsk",
  ],
  read: (line) => {
    const event = parse(line);
    if (event === null) return NOTHING;

    if (event.type === "system" && event.subtype === "init") {
      return { lines: [], session: event.session_id };
    }
    if (event.type === "assistant") {
      const lines: HarnessLine[] = [];
      for (const part of event.message?.content ?? []) {
        if (part.type === "text" && String(part.text).trim() !== "") lines.push(...say(part.text));
        if (part.type === "tool_use") lines.push(toolLine(part.name, part.input));
      }
      return { lines, session: event.session_id };
    }
    if (event.type === "result") {
      const cost =
        typeof event.total_cost_usd === "number" ? "$" + event.total_cost_usd.toFixed(4) : "";
      const took =
        typeof event.duration_ms === "number" ? (event.duration_ms / 1000).toFixed(1) + "s" : "";
      const detail = [took, cost].filter((piece) => piece !== "").join("  ");
      return {
        lines: [
          {
            level: event.is_error === true ? "error" : "ok",
            message: event.is_error === true ? "agent failed" : "agent done",
            detail: detail === "" ? undefined : detail,
          },
        ],
        session: event.session_id,
      };
    }
    return NOTHING;
  },
};

/**
 * OpenAI Codex CLI. `exec` is its headless verb and `--json` its event stream.
 *
 * Documented shape, one JSON object per line:
 *
 *   {"type":"thread.started","thread_id":"019cec77-..."}
 *   {"type":"turn.started"}
 *   {"type":"item.completed","item":{"type":"agent_message","text":"..."}}
 *   {"type":"item.started",  "item":{"type":"mcp_tool_call","server":"...","tool":"..."}}
 *   {"type":"turn.completed","usage":{...}}
 *   {"type":"turn.failed","error":{"message":"..."}}
 *
 * Two things here were wrong and are worth naming, because both fail quietly.
 *
 * The session id is `thread_id` on `thread.started`, not `session_id` on a
 * `session.created` that codex never sends -- so every panel prompt started a
 * new conversation and "continuing" was a lie.
 *
 * And global flags must precede the `resume` subcommand: codex rejects
 * `--skip-git-repo-check` placed after it, so the old argv could only ever
 * work on the FIRST turn and broke on every follow-up.
 */
const codex: Harness = {
  id: "codex",
  label: "Codex CLI",
  bin: "codex",
  argv: (prompt, session) => [
    "exec",
    "--json",
    "--skip-git-repo-check",
    ...(session === null ? [] : ["resume", session]),
    prompt,
  ],
  read: (line) => {
    const event = parse(line);
    if (event === null) return NOTHING;

    if (event.type === "thread.started") {
      return { lines: [], session: event.thread_id };
    }
    if (event.type === "turn.completed") {
      return { lines: [{ level: "ok", message: "agent done" }] };
    }
    if (event.type === "turn.failed" || event.type === "error") {
      const message = event.error?.message ?? event.message ?? "agent failed";
      return { lines: [{ level: "error", message: String(message) }] };
    }

    const item = event.item;
    if (item === undefined) return NOTHING;

    // Tools report twice, `item.started` then `item.completed`. The started one
    // is taken because it is the one that arrives while the work is happening,
    // which is what a live log is for; taking both printed every call twice.
    if (item.type === "agent_message" && event.type === "item.completed") {
      return { lines: say(String(item.text ?? "")) };
    }
    if (event.type === "item.started") {
      if (item.type === "mcp_tool_call") return { lines: [toolLine(String(item.tool ?? "tool"), item.arguments)] };
      if (item.type === "command_execution") return { lines: [toolLine("shell", item.command)] };
    }
    if (item.type === "error" && event.type === "item.completed") {
      return { lines: [{ level: "error", message: String(item.message ?? "agent failed") }] };
    }
    return NOTHING;
  },
};

/**
 * opencode. `run` is one-shot; `--format json` turns it into an event stream.
 *
 * The envelope here was WRONG until it was recorded from a live run, and wrong
 * in the way that produces silence rather than an error: it expected
 * `message.part.updated`, `session.created` and `session.idle`, none of which
 * opencode emits. Every line fell through to NOTHING, so a prompt started the
 * agent, the agent answered, and the panel printed a blank run and went idle.
 *
 * What it actually emits, one JSON object per line, verified on 1.18.30:
 *
 *   {"type":"step_start", "sessionID":"ses_...", "part":{...}}
 *   {"type":"tool_use",   "sessionID":"ses_...", "part":{"type":"tool","tool":"glob","state":{...}}}
 *   {"type":"text",       "sessionID":"ses_...", "part":{"type":"text","text":"Hi there"}}
 *   {"type":"step_finish","sessionID":"ses_...", "part":{"tokens":{...},"cost":0.004}}
 *
 * `sessionID` rides on EVERY event rather than arriving in one of its own, so
 * it is read from whatever comes first instead of being waited for.
 *
 * `step_finish` is per step, not per run -- a turn that calls a tool emits two
 * of them -- so it is not "agent done". The run's end is the process exiting,
 * which `run` already reports.
 */
const opencode: Harness = {
  id: "opencode",
  label: "opencode",
  bin: "opencode",
  argv: (prompt, session) => [
    "run",
    ...(session === null ? [] : ["--session", session]),
    "--format",
    "json",
    prompt,
  ],
  read: (line) => {
    const event = parse(line);
    if (event === null) {
      return line.trim() === "" ? NOTHING : { lines: [{ level: "dim", message: line.trim() }] };
    }

    const session = typeof event.sessionID === "string" ? event.sessionID : undefined;
    const kind = event.type;
    const part = event.part ?? {};

    if (kind === "text" && typeof part.text === "string") {
      return { lines: say(part.text), session };
    }
    if (kind === "tool_use" && typeof part.tool === "string") {
      return { lines: [toolLine(part.tool, part.state?.input)], session };
    }
    if (kind === "error") {
      const message = event.error ?? part.error ?? "agent failed";
      return { lines: [{ level: "error", message: String(message) }], session };
    }
    // step_start and step_finish are turn bookkeeping. They carry the token
    // count and cost, which the panel already gets from the run's own summary,
    // and printing a row per step would double the log for nothing.
    return { lines: [], session };
  },
};

/**
 * Anything else on PATH, printed as it prints.
 *
 * Worth having even though it understands nothing: a harness with no adapter
 * still shows its work in the panel, which is the whole point, and writing a
 * real adapter later only changes how tidy it looks.
 */
function generic(id: string, bin: string, label: string): Harness {
  return {
    id,
    label,
    bin,
    argv: (prompt) => ["-p", prompt],
    read: (line) =>
      line.trim() === "" ? NOTHING : { lines: [{ level: "dim", message: line.trim() }] },
  };
}

/**
 * DeepSeek Harness. `--profile headless` is its one-shot verb: one fresh
 * session, the final answer on stdout, exit.
 *
 * No event stream and no `--resume` on that profile -- both belong to its
 * terminal and SDK profiles -- so this reads plain lines and starts a new
 * conversation each time. That is a real limitation rather than a gap in this
 * adapter, and it is why `say` gets the whole answer at the end instead of a
 * row per step.
 *
 * The overlay is passed on every run rather than asking the user to install it,
 * so a prompt typed in the panel reaches Studio whether or not they have
 * merged the row into their own patch layer.
 */
const dsh: Harness = {
  id: "dsh",
  label: "DeepSeek Harness",
  bin: "dsh",
  //[[ Built here rather than through `mcpFlag`, because order is load-bearing.
  //
  // `dsh [options] [command] [args...]`: `--patch` is a launcher option and the
  // prompt is a positional argument for the booted profile, so the flag has to
  // come first. `mcpFlag` appends, which would have put it after the prompt.
  //]]
  argv: (prompt) => ["--profile", "headless", "--patch", dshOverlay(), prompt],
  read: (line) =>
    line.trim() === "" ? NOTHING : { lines: [{ level: "reply", message: line.trim() }] },
};

/**
 * Gemini CLI. `-p` is its headless verb; `--output-format stream-json` turns it
 * into an event stream of `init`, `message`, `tool_use`, `tool_result`, `error`
 * and `result`.
 *
 * No documented way to resume a headless session, so every prompt is a fresh
 * conversation. That is the CLI's limitation rather than this adapter's, and it
 * is why `session` is ignored here instead of being passed to a flag that does
 * not exist.
 */
const gemini: Harness = {
  id: "gemini",
  label: "Gemini CLI",
  bin: "gemini",
  argv: (prompt) => ["--output-format", "stream-json", "-p", prompt],
  read: (line) => {
    const event = parse(line);
    if (event === null) return NOTHING;

    if (event.type === "init") {
      return { lines: [], session: event.session_id ?? event.sessionId };
    }
    if (event.type === "message") {
      // Both sides of the conversation come through here; the user's half is
      // the prompt that was just typed into the panel, and echoing it back
      // reads as the agent repeating the question.
      if (event.role === "user") return NOTHING;
      return { lines: say(String(event.content ?? event.text ?? "")) };
    }
    if (event.type === "tool_use") {
      return { lines: [toolLine(String(event.name ?? event.tool ?? "tool"), event.args ?? event.input)] };
    }
    if (event.type === "error") {
      return { lines: [{ level: "error", message: String(event.message ?? "agent failed") }] };
    }
    if (event.type === "result") {
      return { lines: [{ level: "ok", message: "agent done" }] };
    }
    return NOTHING;
  },
};

/**
 * Cursor Agent. `-p` with `--output-format stream-json`, an envelope shaped
 * closely after Claude's -- `system`/`assistant`/`result` with `session_id` on
 * every event -- but with its own tool shape: `tool_call` carries a single key
 * naming the kind of call, `readToolCall`, `writeToolCall` or `function`.
 */
const cursor: Harness = {
  id: "cursor",
  label: "Cursor Agent",
  bin: "cursor-agent",
  argv: (prompt, session) => [
    ...(session === null ? [] : ["--resume", session]),
    "--output-format",
    "stream-json",
    "-p",
    prompt,
  ],
  read: (line) => {
    const event = parse(line);
    if (event === null) return NOTHING;
    const session = typeof event.session_id === "string" ? event.session_id : undefined;

    if (event.type === "assistant") {
      const parts = event.message?.content;
      const text = Array.isArray(parts)
        ? parts.filter((piece: any) => piece?.type === "text").map((piece: any) => piece.text).join("")
        : "";
      return { lines: say(String(text)), session };
    }
    if (event.type === "tool_call" && event.subtype === "started") {
      const call = event.tool_call ?? {};
      const named = Object.keys(call)[0] ?? "tool";
      const inner = call[named] ?? {};
      return { lines: [toolLine(inner.name ?? named, inner.args)], session };
    }
    if (event.type === "result") {
      return {
        lines: [
          event.is_error === true
            ? { level: "error", message: "agent failed" }
            : { level: "ok", message: "agent done" },
        ],
        session,
      };
    }
    if (event.type === "error") {
      return { lines: [{ level: "error", message: String(event.message ?? "agent failed") }], session };
    }
    return { lines: [], session };
  },
};

/**
 * Crush. `run` takes the prompt and prints the answer as plain text -- there is
 * no event stream and no resume, so this is `generic` with the right verb.
 *
 * The verb matters: the generic adapter guesses `-p`, which crush rejects as an
 * unknown flag. A harness that is merely unstructured still works; one invoked
 * wrongly does not run at all.
 */
const crush: Harness = {
  id: "crush",
  label: "Crush",
  bin: "crush",
  argv: (prompt) => ["run", prompt],
  read: (line) =>
    line.trim() === "" ? NOTHING : { lines: [{ level: "reply", message: line.trim() }] },
};

const REGISTRY: Harness[] = [claude, codex, opencode, dsh, gemini, cursor, crush];

/**
 * Whether an MCP client's self-reported name is this harness.
 *
 * The names nearly agree and not quite: the harness ids here are `claude`,
 * `codex`, `opencode`, and the clients introduce themselves as `claude-code`,
 * `codex`, `opencode`. Compared with the punctuation stripped and either one
 * allowed to be the prefix, which covers `claude` against `claude-code`
 * without needing a second table to keep in sync with the first.
 *
 * Deliberately not clever. A wrong match here picks the wrong agent, and the
 * cost of no match is only that the first installed one is used instead --
 * which is the behaviour this replaces, so a miss is never worse than before.
 */
export function matchesClient(harness: Harness, clientName: string): boolean {
  const flat = (value: string): string => value.toLowerCase().replace(/[^a-z0-9]/g, "");
  const id = flat(harness.id);
  const name = flat(clientName);
  if (id.length === 0 || name.length === 0) return false;
  return name.startsWith(id) || id.startsWith(name);
}

/**
 * Where a binary is on PATH, or null. Found by looking rather than by running.
 *
 * Running `--version` to find out costs a process per candidate on every
 * `agent` listing, and several of these tools take a second to start.
 *
 * The full path matters beyond the yes/no answer. On Windows every one of these
 * tools is installed as a `.cmd` shim, and Node only applies its cmd-specific
 * argument escaping when it can SEE that extension. Handed a bare "claude" with
 * `shell: true` it concatenates instead, which strips every quote in the
 * command line -- that is not just a formatting bug, it is the difference
 * between passing a prompt and pasting whatever is in it into a shell.
 */
function whereIs(bin: string): string | null {
  const paths = (process.env["PATH"] ?? "").split(delimiter).filter((entry) => entry !== "");
  const extensions =
    process.platform === "win32"
      ? (process.env["PATHEXT"] ?? ".EXE;.CMD;.BAT").split(";")
      : [""];
  for (const dir of paths) {
    for (const extension of extensions) {
      for (const candidate of extension === ""
        ? [join(dir, bin)]
        : [join(dir, bin + extension), join(dir, bin + extension.toLowerCase())]) {
        if (existsSync(candidate)) return candidate;
      }
    }
  }
  return null;
}

export function installed(): Harness[] {
  return REGISTRY.filter((entry) => whereIs(entry.bin) !== null);
}

export function find(id: string): Harness | undefined {
  return REGISTRY.find((entry) => entry.id === id || entry.bin === id);
}

/** Written once per process, reused by every run. */
let configPath: string | null = null;

/**
 * An MCP config naming THIS package, written to a file.
 *
 * A file rather than the inline JSON string these flags also accept, because
 * the string is a brace-and-quote-heavy argument crossing a Windows command
 * line, and the first attempt at it arrived at the other end with every quote
 * gone. A path has nothing in it to mangle.
 *
 * Points at our own entry rather than at `npx` so the agent cannot end up
 * driving a different version of the bridge than the one it is talking to.
 */
function mcpConfig(): string {
  if (configPath !== null) return configPath;
  const entry = resolve(dirname(fileURLToPath(import.meta.url)), "..", "index.js");
  const dir = mkdtempSync(join(tmpdir(), "rbx-studio-mcp-"));
  configPath = join(dir, "mcp.json");
  writeFileSync(
    configPath,
    JSON.stringify({
      mcpServers: {
        "rbx-studio": {
          command: process.execPath,
          args: [entry],
          //[[ Stated here as well as in the spawn's own environment.
          //
          // The agent inherits RBX_STUDIO_MCP_SPAWNED, but the agent is not
          // what connects: it launches its own copy of this server as a child,
          // and whether that child inherits the agent's environment is the
          // agent's business, not ours. Claude's did not, so the spawned server
          // announced itself as a stranger -- the panel said "2 MCP clients
          // connected" on every prompt, and a stopped agent stayed in `clients`
          // until the 90-second stale timeout swept it.
          //
          // Written into the config the agent reads, it survives whatever the
          // agent does to the environment on the way.
          //]]
          env: { RBX_STUDIO_MCP_SPAWNED: "1" },
        },
      },
    }),
    "utf8",
  );
  return configPath;
}

/**
 * Ends a run, and everything it started.
 *
 * `child.kill()` is not enough, and the way it fails is the worst kind: it
 * returns true, the streams close, the promise settles, the panel says
 * "stopping the agent" and goes back to idle -- and the agent carries on
 * editing the user's place. Measured on Windows, `claude.exe` was still running
 * five seconds after a cancel that reported success, because what actually died
 * was the launcher holding the pipes while the work ran in a descendant.
 *
 * So the tree goes, not the process. `taskkill /T` walks the children on
 * Windows; elsewhere the child was given its own process group at spawn, and
 * the negative pid signals all of it. Both fall back to the plain kill, because
 * a cancel that half works still beats one that throws.
 */
function kill(child: ChildProcess): void {
  const pid = child.pid;
  if (pid === undefined) return;

  if (process.platform === "win32") {
    try {
      spawn("taskkill", ["/pid", String(pid), "/T", "/F"], { stdio: "ignore" });
      return;
    } catch {
      /* falls through to the plain kill */
    }
  } else {
    try {
      process.kill(-pid, "SIGTERM");
      return;
    } catch {
      /* the group is gone, or was never made */
    }
  }
  child.kill();
}

let overlayPath: string | null = null;

/**
 * The same server, written as the Cordis overlay row dsh reads.
 *
 * A second format rather than a translation of the first, because the two are
 * not the same statement: dsh's row also fixes the tool namespace, the per-call
 * timeout, and what happens when Studio is not open yet. Kept byte-identical in
 * meaning to `config/dsh.cordis.yml`, which is the copy a user merges into
 * their own profile -- this one exists so a panel prompt works before they have.
 */
function dshOverlay(): string {
  if (overlayPath !== null) return overlayPath;
  const entry = resolve(dirname(fileURLToPath(import.meta.url)), "..", "index.js");
  const dir = mkdtempSync(join(tmpdir(), "rbx-studio-mcp-"));
  overlayPath = join(dir, "rbx-studio.cordis.yml");
  // Written by hand rather than through a YAML library: it is six fixed keys
  // and one interpolated path, and a dependency for that is a dependency to
  // keep patched forever.
  writeFileSync(
    overlayPath,
    [
      "- insert:",
      "    - id: mcp-rbx-studio",
      "      name: '@deepseek-ai/dsh-mcp-client'",
      "      config:",
      "        serverName: rbx-studio",
      "        transport: stdio",
      `        command: ${JSON.stringify(process.execPath)}`,
      `        args: [${JSON.stringify(entry)}]`,
      "        toolCallTimeoutMs: 60000",
      "        failOnStartupError: false",
      // The same declaration as the Claude config's `env`, for the same
      // reason: what dsh passes to a server it starts is dsh's business.
      "        env:",
      "          RBX_STUDIO_MCP_SPAWNED: '1'",
      "",
    ].join("\n"),
    "utf8",
  );
  return overlayPath;
}

export interface Run {
  /** Stops the run. Safe to call after it has already ended. */
  cancel: () => void;
  /** Resolves when the process exits, with the session id if one was learned. */
  done: Promise<string | null>;
}

/**
 * Starts `harness` on `prompt`, reporting every step through `emit`.
 *
 * stdout is read line by line because every adapter here is line-oriented, and
 * a chunk boundary lands mid-object often enough that not buffering shows up as
 * randomly missing rows rather than as an obvious break.
 */
export function run(
  harness: Harness,
  prompt: string,
  options: { cwd: string; session: string | null; emit: (line: HarnessLine) => void },
): Run {
  const argv = [...harness.argv(prompt, options.session)];
  if (harness.mcpFlag !== undefined) argv.push(...harness.mcpFlag());

  const executable = whereIs(harness.bin);
  if (executable === null) {
    options.emit({ level: "error", message: harness.bin + " is not on PATH" });
    return { cancel: () => {}, done: Promise.resolve(null) };
  }

  let child: ChildProcess;
  try {
    child = spawn(executable, argv, {
      cwd: options.cwd,
      // Only for the .cmd shims Windows installs these as, which CreateProcess
      // will not run. Node escapes arguments correctly for those precisely
      // because the extension is visible in the path; anything else is spawned
      // directly, with no shell to quote for.
      shell: /\.(cmd|bat)$/i.test(executable),
      stdio: ["ignore", "pipe", "pipe"],
      // Its own process group, so cancelling can take the whole tree down with
      // one signal. See `kill`.
      detached: process.platform !== "win32",
      // Travels down to the MCP server this agent will start, which is the only
      // thing in a position to tell the bridge that its client was not a person
      // opening a second editor. See ClientView.spawned.
      env: { ...process.env, RBX_STUDIO_MCP_SPAWNED: "1" },
    });
  } catch (cause) {
    const message = cause instanceof Error ? cause.message : String(cause);
    options.emit({ level: "error", message: "could not start " + harness.bin, detail: message });
    return { cancel: () => {}, done: Promise.resolve(null) };
  }

  let session = options.session;
  let pending = "";
  // Set by `cancel`, so a non-zero exit can be reported as the stop the user
  // asked for rather than as a failure they did not.
  let stopped = false;

  const feed = (chunk: string): void => {
    pending += chunk;
    let cut = pending.indexOf("\n");
    while (cut !== -1) {
      const line = pending.slice(0, cut);
      pending = pending.slice(cut + 1);
      const reading = harness.read(line);
      if (reading.session !== undefined && reading.session !== "") session = reading.session;
      for (const row of reading.lines) options.emit(row);
      cut = pending.indexOf("\n");
    }
  };

  child.stdout?.setEncoding("utf8");
  child.stdout?.on("data", feed);

  // stderr is where these tools put the reason they refused to start, and that
  // is the single most useful line the panel can show when nothing happens.
  let complaint = "";
  child.stderr?.setEncoding("utf8");
  child.stderr?.on("data", (chunk: string) => {
    complaint = (complaint + chunk).slice(-400);
  });

  const done = new Promise<string | null>((settle) => {
    child.on("error", (cause) => {
      options.emit({
        level: "error",
        message: "could not start " + harness.bin,
        detail: cause.message,
      });
      settle(session);
    });
    child.on("close", (code) => {
      if (pending !== "") feed("\n");
      if (stopped) {
        options.emit({ level: "warn", message: "agent stopped" });
      } else if (code !== 0 && code !== null) {
        const tail = complaint.trim().split("\n").slice(-2).join(" ");
        options.emit({
          level: "error",
          message: harness.label + " exited " + code,
          detail: tail === "" ? undefined : tail,
        });
      }
      settle(session);
    });
  });

  return {
    cancel: () => {
      stopped = true;
      kill(child);
    },
    done,
  };
}
