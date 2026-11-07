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
import { existsSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
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

/** Plain prose on stdout, one row per line: for CLIs with no event stream. */
function readProse(line: string): Reading {
  return line.trim() === "" ? NOTHING : { lines: [{ level: "reply", message: line.trim() }] };
}

/** A tool call written the way the console writes its own. */
/**
 * What to do with a line that is not the JSON we expected.
 *
 * Never nothing. Dropping unrecognised input is precisely how the opencode
 * adapter printed a blank run for months: it understood none of what it was
 * sent and said so by staying quiet. A line nobody can parse is still evidence,
 * and dim is the level for evidence.
 */
function unparsed(line: string): Reading {
  const text = line.trim();
  return text === "" ? NOTHING : { lines: [{ level: "dim", message: text }] };
}

/**
 * The MCP server this panel belongs to, as the agents spell it.
 *
 * Every harness renames MCP tools its own way: Claude and Codex write
 * `mcp__rbx-studio__tree`, opencode writes `rbx-studio_tree`. Both are the same
 * call, and neither is what a reader wants to see -- the tool is `tree`.
 */
const OWN_SERVER = "rbx-studio";

/** Strips whatever prefix a harness put in front of an MCP tool name. */
function shorten(name: string): string {
  return name
    .replace(/^mcp__[^_]+__/, "")
    .replace(/^mcp__/, "")
    .replace(new RegExp("^" + OWN_SERVER + "[_-]+"), "");
}

/**
 * Whether a tool name, as a harness spelled it, is one of THIS server's.
 *
 * Told apart from the name alone, not from whether a prefix could be stripped:
 * `shorten` strips any `mcp__<server>__`, so keying on "did anything change"
 * treated a call to another MCP server as ours and dropped its row -- and Studio
 * never logs those, so they vanished from the panel entirely.
 */
function isOwnTool(name: string): boolean {
  return name.startsWith(`mcp__${OWN_SERVER}__`) || new RegExp("^" + OWN_SERVER + "[_-]").test(name);
}

/**
 * Rows for one tool call -- usually one, and none for our own tools.
 *
 * Studio logs every call that reaches it, with a friendly name and the time it
 * took, for EVERY client. So an agent's own row for a `rbx-studio` call is the
 * same event written twice, one line apart: "Check Studio 441ms" from the
 * plugin, "rbx-studio_studio_status" from the agent. Two lines per call, and
 * the panel's four-call test read as eight.
 *
 * The agent's copy is the one to drop. Studio's has the duration, has the
 * readable name, and appears whichever client made the call -- including the
 * user's own terminal session, which no adapter here ever sees. What is lost is
 * the arguments; that is a fair price for a log that reads as one event per
 * line, and `console` still has them.
 *
 * Everything else the agent does -- reading a file, running a shell command --
 * Studio never sees, so those rows are all there is and they stay.
 */
function toolLines(name: string, input: unknown): HarnessLine[] {
  if (isOwnTool(name)) return [];
  const short = shorten(name);

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
  return [{ level: "call", message: short, detail }];
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
    if (event === null) return unparsed(line);

    if (event.type === "system" && event.subtype === "init") {
      return { lines: [], session: event.session_id };
    }
    if (event.type === "assistant") {
      const lines: HarnessLine[] = [];
      for (const part of event.message?.content ?? []) {
        if (part.type === "text" && String(part.text).trim() !== "") lines.push(...say(part.text));
        if (part.type === "tool_use") lines.push(...toolLines(part.name, part.input));
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
    if (event === null) return unparsed(line);

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
      if (item.type === "mcp_tool_call") {
        // Codex names the server and the tool separately, so the tool alone
        // carries no prefix to recognise it by.
        if (item.server === OWN_SERVER) return NOTHING;
        return { lines: toolLines(String(item.tool ?? "tool"), item.arguments) };
      }
      if (item.type === "command_execution") return { lines: toolLines("shell", item.command) };
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
    if (event === null) return unparsed(line);

    const session = typeof event.sessionID === "string" ? event.sessionID : undefined;
    const kind = event.type;
    const part = event.part ?? {};

    if (kind === "text" && typeof part.text === "string") {
      return { lines: say(part.text), session };
    }
    if (kind === "tool_use" && typeof part.tool === "string") {
      return { lines: toolLines(part.tool, part.state?.input), session };
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
  read: (line) => readProse(line),
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
    if (event === null) return unparsed(line);

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
      return { lines: toolLines(String(event.name ?? event.tool ?? "tool"), event.args ?? event.input) };
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
    if (event === null) return unparsed(line);
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
      return { lines: toolLines(inner.name ?? named, inner.args), session };
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
  read: (line) => readProse(line),
};

/**
 * Reads Claude Code's `stream-json` envelope, which several other CLIs copy.
 *
 * Amp says so outright ("Claude Code-compatible protocol"), and the shape is
 * the same three events with the same field names: `system`/`init` carrying
 * `session_id`, `assistant` carrying `message.content[]` of `text` and
 * `tool_use` parts, and `result` ending the run. Sharing the reader means a fix
 * to one is a fix to all of them, and means a new CLI that adopts the envelope
 * costs an argv and nothing else.
 *
 * `result` detail is left to the caller: Claude reports cost and duration in
 * fields the others do not have.
 */
function readAnthropicStream(line: string): Reading {
  const event = parse(line);
  if (event === null) return unparsed(line);

  if (event.type === "system" && event.subtype === "init") {
    return { lines: [], session: event.session_id };
  }
  if (event.type === "assistant") {
    const lines: HarnessLine[] = [];
    for (const part of event.message?.content ?? []) {
      if (part.type === "text" && String(part.text).trim() !== "") lines.push(...say(part.text));
      if (part.type === "tool_use") lines.push(...toolLines(part.name, part.input));
    }
    return { lines, session: event.session_id };
  }
  if (event.type === "result") {
    return {
      lines: [
        event.is_error === true
          ? { level: "error", message: "agent failed" }
          : { level: "ok", message: "agent done" },
      ],
      session: event.session_id,
    };
  }
  return NOTHING;
}

/**
 * Sourcegraph Amp. `-x` is its execute verb and `--stream-json` its event
 * stream, in Claude Code's own envelope.
 *
 * Continuing is a different COMMAND rather than a flag -- `amp threads continue
 * <id>` -- so the resumed argv is not the first-run argv with something added,
 * which is why this builds both shapes rather than appending.
 */
const amp: Harness = {
  id: "amp",
  label: "Amp",
  bin: "amp",
  argv: (prompt, session) =>
    session === null
      ? ["-x", "--stream-json", prompt]
      : ["threads", "continue", session, "-x", "--stream-json", prompt],
  read: readAnthropicStream,
};

/**
 * Qwen Code. A Gemini CLI fork, and it kept the headless interface: `-p` with
 * `--output-format stream-json`, and the same `init`/`message`/`tool_use`
 * events.
 */
const qwen: Harness = {
  id: "qwen",
  label: "Qwen Code",
  bin: "qwen",
  argv: (prompt) => ["--output-format", "stream-json", "-p", prompt],
  read: (line) => gemini.read(line),
};

/**
 * Factory Droid. `exec` is headless; `--output-format json` answers with ONE
 * object at the end rather than a stream.
 *
 * `stream-json` exists and is deprecated -- it prints a warning -- and its
 * replacement, `stream-jsonrpc`, is a request/response protocol that expects a
 * client writing to stdin, not a log to read. A single object at the end is the
 * honest fit for a one-shot prompt, at the cost of the panel showing the work
 * only when it is done.
 *
 * `--auto medium` because a headless agent cannot answer an approval prompt,
 * and `low` refuses the file edits an agent asked to build something needs.
 */
const droid: Harness = {
  id: "droid",
  label: "Factory Droid",
  bin: "droid",
  argv: (prompt, session) => [
    "exec",
    "--output-format",
    "json",
    "--auto",
    "medium",
    ...(session === null ? [] : ["--session-id", session]),
    prompt,
  ],
  read: (line) => {
    const event = parse(line);
    if (event === null) return unparsed(line);
    const text = event.result ?? event.output ?? event.message ?? event.text;
    const session = event.session_id ?? event.sessionId;
    if (typeof text === "string" && text.trim() !== "") return { lines: say(text), session };
    return { lines: [], session };
  },
};

/**
 * Block's goose. `run -t` is its headless verb, and it speaks `stream-json`.
 *
 * Sessions are named rather than identified: `--resume -n <name>` reopens one,
 * so the name goose reports is stored where the other harnesses store an id.
 */
const goose: Harness = {
  id: "goose",
  label: "goose",
  bin: "goose",
  argv: (prompt, session) => [
    "run",
    ...(session === null ? [] : ["--resume", "-n", session]),
    "--output-format",
    "stream-json",
    "-t",
    prompt,
  ],
  read: (line) => {
    const event = parse(line);
    if (event === null) return unparsed(line);
    const session = event.session_id ?? event.session ?? event.name;
    const kind = event.type;
    if (kind === "text" || kind === "message" || kind === "assistant") {
      const text = event.text ?? event.content ?? event.message?.content;
      if (typeof text === "string") return { lines: say(text), session };
    }
    if (kind === "tool_use" || kind === "tool_request") {
      return { lines: toolLines(String(event.name ?? event.tool ?? "tool"), event.input), session };
    }
    if (kind === "error") {
      return { lines: [{ level: "error", message: String(event.message ?? "agent failed") }], session };
    }
    return { lines: [], session };
  },
};

/**
 * GitHub Copilot CLI. `-p` runs one prompt; there is no structured output --
 * the request for it is open and unimplemented -- so this reads plain text.
 *
 * `--no-ask-user` matters more here than the missing JSON: without it Copilot
 * pauses for clarification, and a headless run with nothing to answer it sits
 * there until it is killed. `--allow-tool` is scoped to this server's tools for
 * the same reason Claude's is: a prompt typed in a Studio panel is not consent
 * to touch the disk.
 */
const copilot: Harness = {
  id: "copilot",
  label: "GitHub Copilot CLI",
  bin: "copilot",
  // Copilot allows a whole MCP server by its bare name, as the user registered
  // it. `roblox-studio` is what the README told people to register earlier.
  argv: (prompt) => [
    "-p",
    prompt,
    "--no-ask-user",
    "--allow-tool",
    "rbx-studio",
    "--allow-tool",
    "roblox-studio",
  ],
  read: (line) => readProse(line),
};

/**
 * Aider. `--message` is one shot; `--yes` answers the confirmations it would
 * otherwise block on. No event stream, so its prose arrives as prose.
 */
const aider: Harness = {
  id: "aider",
  label: "Aider",
  bin: "aider",
  argv: (prompt) => ["--message", prompt, "--yes", "--no-pretty"],
  read: (line) => readProse(line),
};

/** The field names CLIs use for the id a follow-up resumes. */
const SESSION_KEYS = [
  "session_id",
  "sessionId",
  "sessionID",
  "thread_id",
  "threadId",
  "conversation_id",
  "conversationId",
];

function sessionOf(event: any): string | undefined {
  for (const key of SESSION_KEYS) {
    const value = event?.[key];
    if (typeof value === "string" && value !== "") return value;
  }
  return undefined;
}

/** Text out of a string, or out of an array of `{type:"text", text}` parts. */
function textOf(value: unknown): string {
  if (typeof value === "string") return value;
  if (Array.isArray(value)) {
    return value
      .map((part: any) =>
        typeof part === "string" ? part : part?.type === "text" || part?.type === undefined ? String(part?.text ?? "") : "",
      )
      .join("");
  }
  return "";
}

/** A tool call's arguments, which some CLIs send as a JSON string. */
function argsOf(value: unknown): unknown {
  if (typeof value !== "string") return value;
  try {
    return JSON.parse(value);
  } catch {
    return undefined;
  }
}

/**
 * Reads the event streams the newer CLIs emit, whichever family they copied.
 *
 * Most of them borrowed an envelope rather than inventing one: Claude Code's
 * `system`/`assistant`/`result`, opencode's `text`/`tool_use` with a `part`,
 * Gemini's `init`/`message`, Codex's `item`, or a bare OpenAI chat message with
 * `role` and `tool_calls`. Their docs name the format and rarely the fields, so
 * an adapter written against one guessed shape is the opencode failure again --
 * silence. This recognises each family by what is actually in the object, and
 * anything still unrecognised but carrying text is shown rather than dropped.
 */
function readEvents(line: string): Reading {
  const event = parse(line);
  if (event === null || Array.isArray(event)) return unparsed(line);
  const session = sessionOf(event);
  const kind = typeof event.type === "string" ? event.type : "";
  const withSession = (reading: Reading): Reading => ({
    lines: reading.lines,
    session: reading.session ?? session,
  });

  // The other side of the conversation, and tool output: the prompt is already
  // in the log, and results belong to Studio's own rows.
  if (kind === "user" || event.role === "user" || event.role === "tool" || event.role === "system") {
    return { lines: [], session };
  }
  if (kind === "tool_result" || kind === "observation" || kind === "hook_event" || kind === "team_event") {
    return { lines: [], session };
  }

  // Claude Code's envelope.
  if ((kind === "system" && event.subtype === "init") || (kind === "assistant" && event.message)) {
    return withSession(readAnthropicStream(line));
  }
  if (kind === "result") {
    const failed = event.is_error === true || event.subtype === "error" || event.status === "error";
    if (!failed) return { lines: [{ level: "ok", message: "agent done" }], session };
    // The reason, when the record carries one: "agent failed" alone sends the
    // user to the CLI's own logs for the one fact this row could have given.
    const error = event.error;
    const reason = typeof error === "string" ? error : error?.message ?? (typeof event.result === "string" ? event.result : undefined);
    return {
      lines: [{ level: "error", message: "agent failed", detail: reason ? String(reason).slice(0, 200) : undefined }],
      session,
    };
  }

  // Codex's `item` envelope.
  if (event.item !== undefined && typeof kind === "string" && kind.startsWith("item.")) {
    return withSession(codex.read(line));
  }

  // Cline: `run_result` closes the run with the final text; `agent_event`
  // repeats that text in pieces, so only its errors are taken.
  if (kind === "run_result") {
    const reason = String(event.finishReason ?? "");
    return {
      lines: [
        ...say(textOf(event.text)),
        /error|fail/i.test(reason)
          ? { level: "error", message: "agent failed", detail: reason }
          : { level: "ok", message: "agent done" },
      ],
      session,
    };
  }
  if (kind === "run_aborted") {
    return { lines: [{ level: "warn", message: String(event.message ?? event.reason ?? "agent stopped") }], session };
  }
  if (kind === "agent_event") {
    const inner = event.event ?? {};
    if (inner.type === "error") {
      return { lines: [{ level: "error", message: String(inner.message ?? inner.error ?? "agent failed") }], session };
    }
    const tool = inner.toolName ?? inner.tool_name ?? (/tool/i.test(String(inner.contentType ?? "")) ? inner.name : undefined);
    if (inner.type === "content_start" && typeof tool === "string") {
      return { lines: toolLines(tool, argsOf(inner.input ?? inner.args)), session };
    }
    return { lines: [], session };
  }

  // OpenHands: actions are what it did; a `message`/`finish` action is it talking.
  if (kind === "action") {
    const action = String(event.action ?? "action");
    if (action === "message" || action === "finish") {
      return { lines: say(textOf(event.message ?? event.content ?? event.thought ?? event.final_thought)), session };
    }
    return { lines: toolLines(action, { path: event.path, command: event.command }), session };
  }

  // A bare chat message, as Kimi Code writes them.
  if (event.role === "assistant") {
    const lines = say(textOf(event.content));
    for (const call of Array.isArray(event.tool_calls) ? event.tool_calls : []) {
      const name = call?.function?.name ?? call?.name;
      if (typeof name === "string") lines.push(...toolLines(name, argsOf(call?.function?.arguments ?? call?.arguments)));
    }
    return { lines, session };
  }

  // opencode's family (Kilo, Grok CLI): a `part`, or the same type names flat.
  const part = event.part ?? {};
  if (kind === "text" || (kind === "message" && event.role !== "user")) {
    return { lines: say(textOf(part.text ?? event.text ?? event.content)), session };
  }
  if (kind === "tool_use" || kind === "tool_call" || kind === "tool_request") {
    const name = part.tool ?? event.name ?? event.tool ?? event.tool_name ?? "tool";
    return { lines: toolLines(String(name), argsOf(part.state?.input ?? event.input ?? event.args ?? event.arguments)), session };
  }
  if (kind === "init" || kind === "step_start" || kind === "step_finish") return { lines: [], session };

  if (kind === "error" || event.ok === false) {
    const error = event.error;
    const message = typeof error === "string" ? error : error?.message ?? event.message ?? "agent failed";
    return { lines: [{ level: "error", message: String(message) }], session };
  }

  // One object at the end: OpenClaw's `payloads`, or a plain text field.
  if (Array.isArray(event.payloads)) {
    return { lines: event.payloads.flatMap((payload: any) => say(textOf(payload?.text))), session };
  }
  const prose = textOf(event.text ?? event.content ?? event.output ?? event.result ?? event.message);
  return { lines: say(prose), session };
}

/**
 * Kimi Code. `-p` is print mode and `--output-format stream-json` writes one
 * chat message per line; print mode already runs with `auto` permissions.
 */
const kimi: Harness = {
  id: "kimi",
  label: "Kimi Code",
  bin: "kimi",
  argv: (prompt, session) => [
    ...(session === null ? [] : ["--session", session]),
    "--output-format",
    "stream-json",
    "-p",
    prompt,
  ],
  read: readEvents,
};

/**
 * Cline CLI. A bare prompt runs headless with auto-approve on by default;
 * `--json` writes `agent_event` lines and a closing `run_result`.
 */
const cline: Harness = {
  id: "cline",
  label: "Cline",
  bin: "cline",
  argv: (prompt, session) => [...(session === null ? [] : ["--id", session]), "--json", prompt],
  read: readEvents,
};

/**
 * Kilo Code CLI, an opencode fork with the same `run --format json` stream.
 * `--auto` because without it a run rejects every permission it is asked for.
 */
const kilo: Harness = {
  id: "kilo",
  label: "Kilo Code",
  bin: "kilo",
  argv: (prompt, session) => [
    "run",
    "--auto",
    ...(session === null ? [] : ["--session", session]),
    "--format",
    "json",
    prompt,
  ],
  read: readEvents,
};

/** Augment's Auggie. `--print` with `--mode json`; takes our MCP config inline. */
const auggie: Harness = {
  id: "auggie",
  label: "Auggie",
  bin: "auggie",
  mcpFlag: () => ["--mcp-config", mcpConfig()],
  argv: (prompt) => ["--print", "--mode", "json", prompt],
  read: readEvents,
};

/** Qoder CLI. `-p -o stream-json`, `--session-id` to continue, `--mcp-config` for us. */
const qoder: Harness = {
  id: "qoder",
  label: "Qoder CLI",
  bin: "qoder",
  mcpFlag: () => ["--mcp-config", mcpConfig()],
  argv: (prompt, session) => [
    ...(session === null ? [] : ["--session-id", session]),
    "-p",
    "-o",
    "stream-json",
    prompt,
  ],
  read: readEvents,
};

/** Continue's `cn`. `-p` is headless and `--format json` structures the answer. */
const continueCli: Harness = {
  id: "continue",
  label: "Continue CLI",
  bin: "cn",
  argv: (prompt) => ["-p", "--format", "json", prompt],
  read: readEvents,
};

/**
 * Kiro CLI, Amazon Q Developer CLI's successor. `chat --no-interactive`; the
 * JSON Lines stream needs the v3 engine, so it is asked for explicitly.
 */
const kiro: Harness = {
  id: "kiro",
  label: "Kiro CLI",
  bin: "kiro-cli",
  argv: (prompt, session) => [
    "chat",
    "--no-interactive",
    "--agent-engine",
    "v3",
    "--output-format",
    "stream-json",
    ...(session === null ? [] : ["--resume-id", session]),
    prompt,
  ],
  read: readEvents,
};

/** Mistral Vibe. `--prompt` with `--output streaming`, one JSON message per line. */
const vibe: Harness = {
  id: "vibe",
  label: "Mistral Vibe",
  bin: "vibe",
  argv: (prompt, session) => [
    ...(session === null ? [] : ["--resume", session]),
    "--output",
    "streaming",
    "--prompt",
    prompt,
  ],
  read: readEvents,
};

/** Grok CLI. `-p` headless, `--format json` in opencode's event names. */
const grok: Harness = {
  id: "grok",
  label: "Grok CLI",
  bin: "grok",
  argv: (prompt, session) => [
    ...(session === null ? [] : ["--session", session]),
    "--format",
    "json",
    "-p",
    prompt,
  ],
  read: readEvents,
};

/** OpenHands. `--headless --json -t`; headless always runs in always-approve. */
const openhands: Harness = {
  id: "openhands",
  label: "OpenHands",
  bin: "openhands",
  argv: (prompt) => ["--headless", "--json", "-t", prompt],
  read: readEvents,
};

/** Hermes Agent. `chat -q --format stream-json`, ending on a `result` record. */
const hermes: Harness = {
  id: "hermes",
  label: "Hermes Agent",
  bin: "hermes",
  argv: (prompt, session) => [
    "chat",
    ...(session === null ? [] : ["--resume", session]),
    "--format",
    "stream-json",
    "-q",
    prompt,
  ],
  read: readEvents,
};

/**
 * OpenClaw. `agent --local` runs the embedded agent one-shot; it needs a
 * session selector, so the panel keeps its own named session.
 */
const openclaw: Harness = {
  id: "openclaw",
  label: "OpenClaw",
  bin: "openclaw",
  argv: (prompt, session) => [
    "agent",
    "--local",
    "--session-id",
    session ?? "rbx-studio-panel",
    "--json",
    "--message",
    prompt,
  ],
  read: readEvents,
};

/** Warp's Oz CLI. `agent run --prompt`; `--mcp` takes our config file. */
const oz: Harness = {
  id: "oz",
  label: "Warp Oz",
  bin: "oz",
  mcpFlag: () => ["--mcp", mcpConfig()],
  argv: (prompt) => ["agent", "run", "--prompt", prompt],
  read: readEvents,
};

/** Atlassian Rovo Dev, behind `acli`. `rovodev run <instruction>` is one-shot. */
const rovodev: Harness = {
  id: "rovodev",
  label: "Rovo Dev",
  bin: "acli",
  argv: (prompt, session) => [
    "rovodev",
    "run",
    ...(session === null ? [] : ["--restore", session]),
    prompt,
  ],
  read: readProse,
};

/** Forge. `-p` runs one prompt; `--conversation-id` continues one. */
const forge: Harness = {
  id: "forge",
  label: "Forge",
  bin: "forge",
  argv: (prompt, session) => [...(session === null ? [] : ["--conversation-id", session]), "-p", prompt],
  read: readProse,
};

/** pi. `-p` prints the final answer and exits. */
const pi: Harness = {
  id: "pi",
  label: "pi",
  bin: "pi",
  argv: (prompt, session) => [...(session === null ? [] : ["--session", session]), "-p", prompt],
  read: readProse,
};

/** Letta Code. `-p` is headless. */
const letta: Harness = {
  id: "letta",
  label: "Letta Code",
  bin: "letta",
  argv: (prompt) => ["-p", prompt],
  read: readProse,
};

/** ByteDance's Trae Agent. `run <task>`, working in the panel's directory. */
const trae: Harness = {
  id: "trae",
  label: "Trae Agent",
  bin: "trae-cli",
  argv: (prompt) => ["run", prompt],
  read: readProse,
};

const REGISTRY: Harness[] = [
  claude,
  codex,
  opencode,
  dsh,
  gemini,
  cursor,
  amp,
  qwen,
  droid,
  goose,
  copilot,
  aider,
  crush,
  kimi,
  cline,
  kilo,
  auggie,
  qoder,
  continueCli,
  kiro,
  vibe,
  grok,
  openhands,
  hermes,
  openclaw,
  oz,
  rovodev,
  forge,
  pi,
  letta,
  trae,
];

/** Every harness this build knows, installed or not. */
export function known(): Harness[] {
  return REGISTRY;
}

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
 * The full path matters beyond the yes/no answer. On Windows most of these
 * tools are installed as a `.cmd` shim, which has to be started through
 * cmd.exe with every argument escaped for it -- see `cmdQuote` -- and the
 * extension is how `run` knows to do that.
 */
function whereIs(bin: string): string | null {
  const paths = (process.env["PATH"] ?? "").split(delimiter).filter((entry) => entry !== "");
  const extensions =
    process.platform === "win32"
      ? // Empty entries dropped: a trailing ";" would otherwise match npm's
        // extensionless sh shim, which Windows cannot run.
        (process.env["PATHEXT"] || ".EXE;.CMD;.BAT").split(";").filter((entry) => entry !== "")
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

/**
 * Quotes one argument for a `cmd.exe /d /s /c "..."` command line.
 *
 * Two layers, in this order: the quoting the target program's argument parser
 * expects (backslashes before a quote doubled, the quote escaped), then a caret
 * before every character cmd.exe itself treats specially -- the surrounding
 * quotes included, so cmd never sees a quoted region and every caret applies.
 * The same scheme cross-spawn uses. cmd cannot carry a line break inside an
 * argument at all, so those become spaces.
 */
export function cmdQuote(arg: string): string {
  const quoted =
    '"' +
    arg
      .replace(/\r?\n/g, " ")
      .replace(/(\\*)"/g, '$1$1\\"')
      .replace(/(\\*)$/, "$1$1") +
    '"';
  return quoted.replace(/[()[\]%!^"`<>&|;, *?]/g, "^$&");
}

export function installed(): Harness[] {
  return REGISTRY.filter((entry) => whereIs(entry.bin) !== null);
}

export function find(id: string): Harness | undefined {
  return REGISTRY.find((entry) => entry.id === id || entry.bin === id);
}

/** Directories this process made for agent configs; see `scratchDir`. */
const scratchDirs: string[] = [];

/**
 * A fresh temp directory that is removed when this process exits.
 *
 * The config and overlay files each live in one, written once per process. With
 * nothing removing them, every server process that ever handed a prompt to an
 * agent left a `rbx-studio-mcp-XXXXXX` folder in the temp directory for good.
 */
function scratchDir(): string {
  const dir = mkdtempSync(join(tmpdir(), "rbx-studio-mcp-"));
  if (scratchDirs.length === 0) {
    process.once("exit", () => {
      for (const made of scratchDirs) {
        try {
          rmSync(made, { recursive: true, force: true });
        } catch {
          /* best effort: a temp file that will not go is not worth a crash on the way out */
        }
      }
    });
  }
  scratchDirs.push(dir);
  return dir;
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
  const dir = scratchDir();
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
      // A spawn failure (taskkill missing, say) arrives as an `error` event, not
      // a throw -- and an unhandled one would take this whole server down.
      spawn("taskkill", ["/pid", String(pid), "/T", "/F"], { stdio: "ignore" }).on(
        "error",
        () => child.kill(),
      );
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
  const dir = scratchDir();
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

  //[[ .cmd shims go through cmd.exe, escaped here rather than by Node.
  //
  // CreateProcess will not run a .cmd directly, and `shell: true` does NOT
  // escape anything -- Node only joins the arguments with spaces (DEP0190). A
  // prompt typed in the panel as `add a door & a window` ran `a window` as a
  // second command, and any quote, pipe or percent sign broke the prompt.
  //]]
  const viaCmd = process.platform === "win32" && /\.(cmd|bat)$/i.test(executable);
  const [file, args] = viaCmd
    ? [
        process.env["ComSpec"] ?? "cmd.exe",
        ["/d", "/s", "/c", `"${[executable, ...argv].map(cmdQuote).join(" ")}"`],
      ]
    : [executable, argv];

  let child: ChildProcess;
  try {
    child = spawn(file, args, {
      cwd: options.cwd,
      windowsVerbatimArguments: viaCmd,
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
      // A line an adapter did not expect must cost that line, not the process:
      // this runs inside a stream handler, where a throw is uncaught and would
      // take the bridge -- and every agent using it -- down with it.
      try {
        const reading = harness.read(line);
        if (reading.session !== undefined && reading.session !== "") session = reading.session;
        for (const row of reading.lines) options.emit(row);
      } catch {
        if (line.trim() !== "") options.emit({ level: "dim", message: line.slice(0, 400) });
      }
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
