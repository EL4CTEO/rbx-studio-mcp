import { z } from "zod";
import { json, type ToolResult } from "../lib/format.js";
import { ToolError } from "../lib/errors.js";
import type { StudioSession } from "../lib/protocol.js";
import { defineTool, type ToolContext } from "../lib/tool.js";

interface PlaytestResponse {
  changed: boolean;
  reason?: string;
  state: {
    isEdit: boolean;
    isRunning: boolean;
    isRunMode: boolean;
    editModeActive?: boolean;
    playerCount: number;
    players?: Array<{ name: string; userId: number; diagnosticsReady?: boolean }>;
    diagnosticsReady?: boolean;
    testPending: boolean;
    lastResult?: unknown;
    lastError?: string;
    [key: string]: unknown;
  };
}

const isRuntime = (session: StudioSession): boolean =>
  Boolean(session.context?.startsWith("playtest") && !session.context.includes("client"));

/** Never route a mutation to the first runtime in a multi-window project. */
function runtimeFor(sessions: StudioSession[], editor: StudioSession, exclude: ReadonlySet<string> = new Set()): StudioSession | undefined {
  const paired = sessions.filter(s => isRuntime(s) && s.editorStudioId === editor.studioId && !exclude.has(s.studioId));
  if (paired.length > 1) throw new ToolError("AMBIGUOUS_PLAYTEST", "Several runtimes belong to this editor. Specify the runtime studioId.");
  if (paired.length === 1) return paired[0];
  const legacy = sessions.filter(s => isRuntime(s) && !s.editorStudioId && s.placeId === editor.placeId && !exclude.has(s.studioId));
  const editors = sessions.filter(s => !isRuntime(s) && s.placeId === editor.placeId);
  if (legacy.length > 1 || (legacy.length > 0 && editors.length > 1))
    throw new ToolError("AMBIGUOUS_PLAYTEST", "Cannot identify this editor's runtime. Update the Studio plugin or specify a runtime studioId.");
  return legacy[0];
}

function editorFor(sessions: StudioSession[], target: StudioSession): StudioSession | undefined {
  if (!isRuntime(target)) return target;
  const editors = sessions.filter(s => !isRuntime(s) && (target.editorStudioId ? s.studioId === target.editorStudioId : s.placeId === target.placeId));
  const runtimes = sessions.filter(s => isRuntime(s) && s.placeId === target.placeId);
  return editors.length === 1 && (target.editorStudioId || runtimes.length === 1) ? editors[0] : undefined;
}

export function registerPlaytestTools(context: ToolContext): void {
  const { bridge } = context;
  defineTool(context, {
    name: "playtest", title: "Run and stop the simulation",
    description:
      "Start play (one character), run (no player), multiplayer, addPlayers, stop, or read state. " +
      "Returns separate editorStudioId/runtimeStudioId and runtime state. Use runtimeStudioId for console, performance and execute_luau. " +
      "waitFor=ready waits for the runtime, requested players and client diagnostic relays; it does not guarantee game initialization. " +
      "waitFor=completed waits for StudioTestService:EndTest(value); the editor reports lastResult/lastError. " +
      "args is readable via StudioTestService:GetTestArgs(). Stop discards runtime changes; build in edit mode. " +
      "Obey AGENTS.md, CLAUDE.md, user instructions and project guidance against playtesting even when ON. " +
      "The panel's playtests off is a hard lock on play/run/multiplayer/addPlayers; state and stop remain available. " +
      "Use edit-mode inspection while locked. Only the user can re-enable playtests on. Do not bypass the lock through execute_luau or Studio APIs.",
    inputSchema: {
      op: z.enum(["play", "run", "multiplayer", "addPlayers", "stop", "state"]),
      players: z.number().int().min(1).max(8).optional().describe("multiplayer: initial count (default 2); addPlayers: additional count (default 1)."),
      args: z.string().optional().describe("Test argument, or stop's EndTest result."),
      waitFor: z.enum(["ready", "completed"]).optional().describe("Default: ready for starts/addPlayers; completed for stop; otherwise a snapshot."),
      waitSeconds: z.number().min(0).max(30).default(6).describe("Maximum lifecycle wait in seconds; partial state returned on timeout."),
      studioId: z.string().optional().describe("Editor or runtime; required if selection is ambiguous."),
    }, readOnly: false, destructive: true,
  }, async (args): Promise<ToolResult> => {
    const view = await bridge.sessions();
    const sessions = view.list;
    let target = args.studioId ? sessions.find(s => s.studioId === args.studioId) :
      sessions.length === 1 ? sessions[0] : view.activeIsChosen ? sessions.find(s => s.studioId === view.activeId) : undefined;
    if (!target && !args.studioId) {
      const editors = sessions.filter(s => !isRuntime(s));
      if (editors.length === 1 && sessions.every(s => s === editors[0] || s.editorStudioId === editors[0]!.studioId ||
        (!s.editorStudioId && isRuntime(s) && s.placeId === editors[0]!.placeId && sessions.length === 2))) target = editors[0];
    }
    if (!target) {
      if (sessions.length === 0) return json((await bridge.call<PlaytestResponse>("playtest.control", args, { studioId: args.studioId })).state);
      throw new ToolError(args.studioId ? "NO_STUDIO" : "AMBIGUOUS_STUDIO", "Select the editor or runtime studioId for this test.");
    }
    const editor = editorFor(sessions, target);
    const starting = ["play", "run", "multiplayer"].includes(args.op);
    if (starting && isRuntime(target)) throw new ToolError("WRONG_CONTEXT", "Start tests from an editor session.");
    let runtime = isRuntime(target) ? target : runtimeFor(sessions, target);
    const before = new Set(sessions.map(s => s.studioId));
    let response: PlaytestResponse;
    let stateSession: string;
    if (args.op === "stop" && runtime) {
      if (!editor) throw new ToolError("NO_EDITOR_SESSION", "Cannot verify teardown without this runtime's editor. Update the plugin.");
      try {
        await bridge.call("playtest.control", { op: "endTest", value: args.args }, { studioId: runtime.studioId, timeoutMs: 10_000 });
      } catch (error) {
        // Teardown can destroy the responder, but permission/handler errors are real.
        if (!(error instanceof ToolError) || !["DISCONNECTED", "TIMEOUT", "NO_STUDIO"].includes(error.code)) throw error;
      }
      response = await bridge.call<PlaytestResponse>("playtest.control", { op: "state", waitingForStop: true }, { studioId: editor.studioId });
      stateSession = editor.studioId;
    } else {
      if (args.op === "addPlayers" && !runtime) throw new ToolError("NO_PLAYTEST", "Start a multiplayer test first.");
      if (args.waitFor === "completed" && !editor) throw new ToolError("NO_EDITOR_SESSION", "Completion is reported by the originating editor.");
      stateSession = args.op === "addPlayers" ? runtime!.studioId : args.op === "state" && args.waitFor === "completed" ? editor!.studioId : target.studioId;
      response = await bridge.call<PlaytestResponse>("playtest.control", { op: args.op, players: args.players, args: args.args },
        { studioId: stateSession, timeoutMs: 30_000 });
    }
    const waiting = args.op === "stop" ? "completed" : args.waitFor ?? ((starting || args.op === "addPlayers") ? "ready" : undefined);
    const exclude = starting && response.changed ? before : undefined;
    const deadline = Date.now() + (args.waitSeconds ?? 6) * 1000;
    const expected = args.op === "multiplayer" ? args.players ?? 2 : args.op === "addPlayers" ? response.state.playerCount + (args.players ?? 1) : 1;
    let ready = false;
    let completed = false;
    let first = true;
    do {
      if (editor) {
        const current = (await bridge.sessions()).list;
        runtime = isRuntime(target) ? current.find(s => s.studioId === target.studioId) : runtimeFor(current, editor, exclude);
      }
      if (waiting === "completed" && editor) {
        if (!first || stateSession !== editor.studioId || (args.op !== "state" && args.op !== "stop"))
          response = await bridge.call<PlaytestResponse>("playtest.control", { op: "state", waitingForStop: args.op === "stop" }, { studioId: editor.studioId, timeoutMs: 3_000 });
        stateSession = editor.studioId;
      } else if (runtime) {
        try {
          if (!first || stateSession !== runtime.studioId || args.op !== "state")
            response = await bridge.call<PlaytestResponse>("playtest.control", { op: "state" }, { studioId: runtime.studioId, timeoutMs: 3_000 });
          stateSession = runtime.studioId;
        }
        catch (error) {
          if (!starting || !(error instanceof ToolError) || !["DISCONNECTED", "TIMEOUT", "NO_STUDIO"].includes(error.code)) throw error;
        }
      } else if (starting && editor) {
        response = await bridge.call<PlaytestResponse>("playtest.control", { op: "state" }, { studioId: editor.studioId, timeoutMs: 3_000 });
      }
      first = false;
      completed = Boolean(editor && response.state.isEdit === true && response.state.editModeActive !== false && !response.state.testPending && !response.state.isRunning);
      ready = response.state.isRunMode ? response.state.isRunning : Boolean(runtime && response.state.playerCount >= expected && response.state.diagnosticsReady);
      if (!waiting || response.state.lastError || completed || (waiting === "ready" && ready) || Date.now() >= deadline) break;
      await new Promise<void>(resolve => setTimeout(resolve, Math.min(300, Math.max(0, deadline - Date.now()))));
    } while (Date.now() <= deadline);
    return json({ ...response.state,
      editorStudioId: editor?.studioId, runtimeStudioId: completed ? undefined : runtime?.studioId,
      studioId: completed ? editor?.studioId : runtime?.studioId ?? target.studioId,
      lifecycle: response.state.lastError ? "failed" : completed ? "completed" : ready ? "ready" : response.state.isRunning ? "running" : response.state.testPending ? "starting" : "idle",
      ready, waitTimedOut: Boolean(waiting && !response.state.lastError && !(waiting === "ready" ? ready || completed : completed)),
    }, response.reason);
  });
}
