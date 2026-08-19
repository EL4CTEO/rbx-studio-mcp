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
    "Open Roblox Studio, install the companion plugin, and make sure it is enabled " +
      "(Plugins tab -> Studio MCP -> Connect). If the plugin asks for permission to " +
      "reach 127.0.0.1, accept it. Then retry.",
  );

export const AMBIGUOUS_STUDIO = (names: string[]): ToolError =>
  new ToolError(
    "AMBIGUOUS_STUDIO",
    `${names.length} Studio instances are connected and none is marked active.`,
    `Call set_active_studio with one of: ${names.join(", ")}.`,
  );

export const TIMEOUT = (op: string, ms: number): ToolError =>
  new ToolError(
    "TIMEOUT",
    `Studio did not answer "${op}" within ${ms}ms.`,
    "Studio is usually busy compiling, mid-playtest, or blocked on a modal dialog. " +
      "Call studio_status to check, then retry. If the work is genuinely long, " +
      "run it through execute_luau with your own coroutine instead.",
  );

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
