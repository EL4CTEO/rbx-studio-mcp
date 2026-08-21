import type { CommandError } from "./protocol.js";

/**
 * Error whose message is written for an agent, not a human log reader: it says
 * what failed and what to try next, because that is the only feedback channel
 * the model has for learning correct tool usage.
 */
export class ToolError extends Error {
  readonly code: string;
  readonly hint: string | undefined;

  constructor(code: string, message: string, hint?: string) {
    super(hint ? `${message}\n${hint}` : message);
    this.name = "ToolError";
    this.code = code;
    this.hint = hint;
  }

  static fromCommandError(error: CommandError): ToolError {
    return new ToolError(error.code, error.message, error.hint);
  }
}

export const NO_STUDIO = (): ToolError =>
  new ToolError(
    "NO_STUDIO",
    "No Roblox Studio instance is connected to this MCP server.",
    "Open Roblox Studio with the companion plugin installed — it connects " +
      "automatically on load. If it asks for permission to reach 127.0.0.1, " +
      "accept it. Check connection status under the Studio MCP toolbar button, " +
      "and use the reconnect button in that console if it is disconnected. " +
      "Then retry.",
  );

export const AMBIGUOUS_STUDIO = (names: string[]): ToolError =>
  new ToolError(
    "AMBIGUOUS_STUDIO",
    `${names.length} Studio instances are connected and the user has not said ` +
      "which one to work in.",
    "Ask the user which place they mean, then call set_active_studio with its " +
      `studioId. Connected now: ${names.join("; ")}. To act on one place without ` +
      "changing the default, pass `studioId` to the tool directly.",
  );

/**
 * One place, two sessions — which is what a running playtest looks like.
 *
 * Worth its own error because the generic one sends the agent to ask the user
 * which place they mean, and there is only one place. The choice is not the
 * user's to make: it follows from what the call does. Anything meant to persist
 * belongs in the edit session, because the playtest's data model is thrown away
 * when it stops; anything about the game as it runs is only true in the playtest.
 */
export const SAME_PLACE_STUDIO = (rows: string[]): ToolError =>
  new ToolError(
    "AMBIGUOUS_STUDIO",
    "One place is open with a playtest running, so two sessions are connected " +
      "and neither is the default.",
    "Pass `studioId` explicitly — do not ask the user, this is not two places. " +
      "Use the *edit* session for anything that must survive the playtest: " +
      "creating or modifying instances, script edits, geometry. Use the " +
      "*playtest* session for anything about the running game: character, input, " +
      "console, debug, performance. Edits made against the playtest are " +
      `discarded when it stops. Connected now: ${rows.join("; ")}.`,
  );

/** What the bridge knew about the request at the moment it gave up. */
export interface TimeoutState {
  /** False means the command never left this process — Studio never saw it. */
  delivered: boolean;
  /** How long since the plugin last said anything at all. */
  silentForMs: number;
  /** Other calls still outstanding on the same session. */
  alsoInFlight: number;
  transport: "sse" | "poll";
}

/**
 * Timed out — with what the bridge knew when it gave up.
 *
 * This used to say only "Studio did not answer", which is the least useful true
 * statement available: a trivial string operation timing out at 60s reads as a
 * broken tool, and the caller has no way to tell a wedged plugin from a command
 * that was never picked up. All of it is knowable here, so all of it is said.
 */
export const TIMEOUT = (op: string, ms: number, state?: TimeoutState): ToolError => {
  if (!state) {
    return new ToolError(
      "TIMEOUT",
      `Studio did not answer "${op}" within ${ms}ms.`,
      "Call studio_status to check, then retry.",
    );
  }

  const silence = Math.round(state.silentForMs / 1000);
  const facts = [
    state.delivered
      ? "The command reached Studio and Studio did not finish it."
      : "The command never reached Studio — it was still queued when the deadline passed.",
    `Last heard from the plugin ${silence}s ago, over ${state.transport}.`,
    state.alsoInFlight > 0
      ? `${state.alsoInFlight} other call${state.alsoInFlight === 1 ? " is" : "s are"} still outstanding on this session.`
      : "Nothing else was in flight.",
  ];

  // The two shapes point in opposite directions, so the advice does too.
  const hint = state.delivered
    ? "Studio is usually compiling, mid-playtest transition, or blocked on a modal " +
      "dialog. It often clears on its own — retry once before treating it as broken. " +
      "If the work is genuinely long, run it through execute_luau in your own coroutine."
    : "The plugin has stopped collecting commands, which normally means Studio is " +
      "starting or stopping a playtest, or the window lost its connection. Call " +
      "list_studios to see which sessions are live, and address the call at one of them.";

  return new ToolError("TIMEOUT", `Studio did not answer "${op}" within ${ms}ms. ${facts.join(" ")}`, hint);
};

export const DISCONNECTED = (): ToolError =>
  new ToolError(
    "DISCONNECTED",
    "The Studio connection dropped while the request was in flight.",
    "Studio was closed, the place was switched, or the plugin was disabled. " +
      "Call studio_status to confirm a live connection, then retry the request.",
  );

/** Wraps unknown throwables so every tool boundary reports the same shape. */
export function toToolError(cause: unknown): ToolError {
  if (cause instanceof ToolError) return cause;
  const message = cause instanceof Error ? cause.message : String(cause);
  return new ToolError("INTERNAL", message);
}
