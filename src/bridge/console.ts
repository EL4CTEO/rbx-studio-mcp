/**
 * The half of the console panel's command line that Studio cannot answer.
 *
 * Most of what someone types into the panel is answered inside the plugin --
 * `clear`, `theme`, `status` are all facts Studio already holds. The rest are
 * questions about the machine: is the port really ours, is the installed plugin
 * the one this package ships, which Studios are attached, and what happens when
 * a free-text prompt is typed at an agent. Those live here.
 *
 * Answers come back as console rows rather than as prose, so the panel prints
 * them with the same sigils, colours and columns as everything else it logs. A
 * diagnostic that renders differently from the log it appears in reads as a
 * foreign object pasted into the session.
 */
import { type Check, collectChecks } from "../doctor.js";
import type { Bridge } from "./rpc.js";
import { type HarnessLine, type Run, find, installed, run } from "./harness.js";

export type ConsoleLine = HarnessLine;

/** What a Studio panel sent up. `args` is the line already split on spaces. */
export interface ConsoleRequest {
  studioId: string;
  command: string;
  args: string[];
  /** The raw line, needed by `prompt` where the split is meaningless. */
  line: string;
}

/**
 * One agent per Studio, because the panel shows one log.
 *
 * Two runs writing into the same console interleave into something no reader
 * can untangle, and the second one is almost always a mistyped repeat of the
 * first. Refusing it and saying so costs nothing; the user can `stop`.
 */
interface AgentState {
  harnessId: string | null;
  session: string | null;
  active: Run | null;
}

const agents = new Map<string, AgentState>();

function agentFor(studioId: string): AgentState {
  let state = agents.get(studioId);
  if (state === undefined) {
    state = { harnessId: null, session: null, active: null };
    agents.set(studioId, state);
  }
  return state;
}

/**
 * Whether an agent is mid-run for this Studio.
 *
 * The panel dims its caret while one is, and the only other signal it gets is
 * the `agent-run` event fired when the run ends. A prompt that never started --
 * no harness installed, or a name that resolves to nothing -- fires no such
 * event, so the panel would sit "busy" forever on the one failure it is most
 * likely to hit first. Answered with the reply instead.
 */
export function agentRunning(studioId: string): boolean {
  return agents.get(studioId)?.active !== null && agents.get(studioId)?.active !== undefined;
}

const MARK: Record<Check["status"], ConsoleLine["level"]> = {
  ok: "ok",
  warn: "warn",
  bad: "error",
};

/**
 * `doctor`, rendered for a log rather than for a terminal.
 *
 * The CLI prints a blank line between checks and indents the explanation under
 * the title. Neither survives here: the console already separates rows and
 * already indents continuations, so the same output pasted in would be double
 * spaced and double indented. The checks are shared; only the shaping differs.
 */
function renderChecks(checks: Check[]): ConsoleLine[] {
  const lines: ConsoleLine[] = [];
  for (const check of checks) {
    lines.push({
      level: MARK[check.status],
      message: check.title,
      // The CLI's own two-space indent, undone: it exists to hang the detail
      // under the title in a flat stream of text, and this log does that itself.
      detail: check.detail.split("\n").map((piece) => piece.trim()).join(" "),
    });
  }
  const bad = checks.filter((check) => check.status === "bad").length;
  const warn = checks.filter((check) => check.status === "warn").length;
  lines.push({
    level: bad > 0 ? "error" : warn > 0 ? "warn" : "ok",
    message: `${checks.length - bad - warn} passed, ${warn} warning, ${bad} failure`,
  });
  return lines;
}

/** The Studios on this bridge, with the one calls land on marked. */
function renderStudios(bridge: Bridge, asking: string): ConsoleLine[] {
  const sessions = bridge.list();
  if (sessions.length === 0) return [{ level: "dim", message: "no Studio is connected" }];

  const active = bridge.activeId("panel");
  return [
    {
      level: "info",
      message: `${sessions.length} Studio${sessions.length === 1 ? "" : "s"} on this bridge`,
    },
    ...sessions.map((session, index): ConsoleLine => {
      const here = session.studioId === asking ? " (this panel)" : "";
      return {
        level: session.studioId === active ? "ok" : "dim",
        message: `  ${index + 1}. ${session.placeName}${here}`,
        detail: `${session.context ?? "edit"}  ${session.transport}  ${session.studioId.slice(0, 8)}`,
      };
    }),
  ];
}

/**
 * Resolves what someone typed after `use` into a studioId.
 *
 * Both forms are accepted because both are in front of them: `studios` prints a
 * number, and the tools print an id. Requiring the id would mean reading a
 * hex string off one line to type it into the next.
 */
function resolveStudio(bridge: Bridge, token: string): string | null {
  const sessions = bridge.list();
  const index = Number(token);
  if (Number.isInteger(index) && index >= 1 && index <= sessions.length) {
    return sessions[index - 1]?.studioId ?? null;
  }
  const byId = sessions.find((session) => session.studioId.startsWith(token));
  return byId?.studioId ?? null;
}

/** Which harnesses are installed, and which one prompts will go to. */
function renderAgents(state: AgentState): ConsoleLine[] {
  const available = installed();
  if (available.length === 0) {
    return [
      {
        level: "warn",
        message: "no coding agent found on PATH",
        detail:
          "Install one (claude, codex, opencode, gemini, cursor-agent) and it " +
          "will be picked up automatically. Commands still work without one.",
      },
    ];
  }
  const chosen = state.harnessId ?? available[0]?.id;
  return [
    { level: "info", message: `${available.length} agent${available.length === 1 ? "" : "s"} available` },
    ...available.map((entry): ConsoleLine => ({
      level: entry.id === chosen ? "ok" : "dim",
      message: `  ${entry.id}`,
      detail: entry.id === chosen ? `${entry.label}  (in use)` : entry.label,
    })),
    { level: "dim", message: "type anything that is not a command to send it to the agent" },
  ];
}

/**
 * Says where the prompt came from, once at the start of a conversation.
 *
 * The agent is spawned in this repository's working directory, so its instinct
 * for "create a simple script, then edit it" is a file on disk -- which is what
 * happened the first time this was tried: it reached for Bash and `cat >`, was
 * refused by its own permission mode, and reported the test impossible. The
 * user was sitting in front of a Roblox place at the time.
 *
 * Nothing about the prompt itself says otherwise. It arrives as a bare line
 * typed into a panel, with none of the context the panel has: that there is a
 * place open, that the tools reaching it are already connected, and that
 * "script" almost certainly means a Script instance rather than a source file.
 *
 * Only on the first turn. A continued session already has this in its history,
 * and repeating it every message would spend context restating something the
 * agent has not forgotten -- and would start reading as nagging.
 */
export function frame(prompt: string): string {
  return (
    "You are answering someone typing into a console panel docked inside " +
    "Roblox Studio, with a place open in front of them. The rbx-studio MCP " +
    "tools are connected to that place: use them for anything about the " +
    "game -- `script_create` and `script_edit` for code, `create`/`modify` " +
    "for instances, `terrain` for terrain. \"A script\" means a Script " +
    "instance in the place, not a file on disk. Reach for the filesystem " +
    "only if they clearly mean this MCP server's own source.\n\n" +
    prompt
  );
}

/**
 * Starts an agent on `prompt` and streams its work into the asking panel.
 *
 * Returns immediately with the rows that describe the start. Everything the
 * agent then does arrives over the Studio's own event stream, which is why this
 * needs the bridge and not just a return value: a run takes minutes, and a
 * request held open that long is a request that times out.
 */
function startAgent(
  bridge: Bridge,
  state: AgentState,
  studioId: string,
  prompt: string,
): ConsoleLine[] {
  if (state.active !== null) {
    return [{ level: "warn", message: "an agent is already running", detail: "type stop to cancel it" }];
  }

  const available = installed();
  if (available.length === 0) return renderAgents(state);

  const wanted = state.harnessId === null ? available[0] : find(state.harnessId);
  if (wanted === undefined) {
    return [{ level: "error", message: `unknown agent "${state.harnessId}"` }];
  }

  const emit = (line: ConsoleLine): void => {
    bridge.notify(studioId, { event: "console", ...line });
  };

  const started = run(wanted, state.session === null ? frame(prompt) : prompt, {
    cwd: process.cwd(),
    session: state.session,
    emit,
  });
  state.active = started;

  void started.done.then((session) => {
    state.session = session;
    state.active = null;
    bridge.notify(studioId, { event: "agent-run", state: "idle" });
  });

  //[[ The panel already echoed the line; this says who picked it up.
  //
  // It used to repeat the prompt, which put the same sentence on screen twice
  // in the same second under two different labels -- the second one reading as
  // if the agent had said it back.
  //]]
  return [
    {
      level: "dim",
      message: wanted.label,
      detail: state.session === null ? "starting" : "continuing",
    },
  ];
}

/**
 * Answers one line typed into a console panel.
 *
 * Unknown commands are not an error here: the plugin decides what is a command
 * and what is a prompt before it ever reaches this file, so anything arriving
 * with a name we do not know is a genuine mismatch between plugin and server
 * versions, and saying so beats guessing.
 */
export async function handleConsole(
  bridge: Bridge,
  port: number,
  request: ConsoleRequest,
): Promise<ConsoleLine[]> {
  const state = agentFor(request.studioId);

  switch (request.command) {
    case "doctor":
      return renderChecks(await collectChecks(port));

    case "studios":
      return renderStudios(bridge, request.studioId);

    case "use": {
      const token = request.args[0];
      if (token === undefined) {
        return [{ level: "dim", message: "usage: use <number|id>", detail: "run studios to see them" }];
      }
      const target = resolveStudio(bridge, token);
      if (target === null) return [{ level: "error", message: `no Studio matches "${token}"` }];
      bridge.setActiveForAll(target);
      const name = bridge.list().find((session) => session.studioId === target)?.placeName ?? target;
      return [{ level: "ok", message: `calls now target ${name}` }];
    }

    case "agent": {
      const verb = request.args[0];
      if (verb === undefined || verb === "list") return renderAgents(state);
      if (verb === "use") {
        const id = request.args[1];
        if (id === undefined) return [{ level: "dim", message: "usage: agent use <id>" }];
        const wanted = find(id);
        if (wanted === undefined) return [{ level: "error", message: `unknown agent "${id}"` }];
        state.harnessId = wanted.id;
        // A new harness cannot continue another harness's conversation, and
        // handing it a stranger's session id fails in a way that reads as the
        // switch itself being broken.
        state.session = null;
        return [{ level: "ok", message: `prompts now go to ${wanted.label}` }];
      }
      if (verb === "new") {
        state.session = null;
        return [{ level: "ok", message: "next prompt starts a fresh conversation" }];
      }
      return [{ level: "dim", message: "usage: agent [list|use <id>|new]" }];
    }

    case "stop": {
      if (state.active === null) return [{ level: "dim", message: "nothing is running" }];
      state.active.cancel();
      return [{ level: "warn", message: "stopping the agent" }];
    }

    case "prompt": {
      const prompt = request.line.trim();
      if (prompt === "") return [];
      return startAgent(bridge, state, request.studioId, prompt);
    }

    default:
      return [
        {
          level: "error",
          message: `this bridge does not know "${request.command}"`,
          detail: "the plugin and the server are probably different builds",
        },
      ];
  }
}
