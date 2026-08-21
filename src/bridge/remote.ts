import { CLIENT_HEADER, PROTOCOL_VERSION } from "../lib/protocol.js";
import { ToolError } from "../lib/errors.js";
import type { SessionsView, StudioBridge } from "./api.js";

/** How the port owner identifies itself, so we never proxy to a stranger. */
export interface OwnerIdentity {
  server: "roblox-studio-mcp";
  protocolVersion: number;
  pid: number;
}

const HEADERS = { [CLIENT_HEADER]: "peer", "Content-Type": "application/json" };

/**
 * Asks whatever holds `port` whether it is another copy of this server.
 *
 * Deliberately narrow. Something else on 44755 is a reason to fail with the
 * old "port is in use" message, not to start posting Luau at it, so this
 * returns null on anything that is not an exact match — wrong shape, wrong
 * protocol version, no answer at all.
 */
export async function probeOwner(port: number): Promise<OwnerIdentity | null> {
  try {
    const response = await fetch(`http://127.0.0.1:${port}/identity`, {
      headers: { [CLIENT_HEADER]: "peer" },
      signal: AbortSignal.timeout(2_000),
    });
    if (!response.ok) return null;
    const body = (await response.json()) as Partial<OwnerIdentity>;
    if (body.server !== "roblox-studio-mcp") return null;
    if (body.protocolVersion !== PROTOCOL_VERSION) return null;
    return body as OwnerIdentity;
  } catch {
    return null;
  }
}

/**
 * A bridge that forwards everything to the process holding the port.
 *
 * There is no second connection to Studio and no second copy of the in-flight
 * table: the owner does the work and this waits for the answer, so two agents
 * calling at once are simply two commands on the owner's queue, and the undo
 * recording each one opens still belongs to whichever tool made it.
 */
export class RemoteBridge implements StudioBridge {
  readonly isOwner = false;

  constructor(
    private readonly port: number,
    readonly owner: OwnerIdentity,
  ) {}

  private get base(): string {
    return `http://127.0.0.1:${this.port}`;
  }

  private async post<T>(path: string, body: unknown, timeoutMs: number): Promise<T> {
    let response: Response;
    try {
      response = await fetch(`${this.base}${path}`, {
        method: "POST",
        headers: HEADERS,
        body: JSON.stringify(body),
        // Padded past the command's own deadline so the owner's timeout wins and
        // its diagnosis reaches the caller, rather than being cut off by ours.
        signal: AbortSignal.timeout(timeoutMs + 10_000),
      });
    } catch (cause) {
      throw this.unreachable(cause);
    }

    const payload = (await response.json()) as {
      ok: boolean;
      data?: T;
      error?: { code: string; message: string };
    };
    if (!payload.ok) {
      const error = payload.error ?? { code: "PEER_ERROR", message: "the bridge owner refused" };
      throw new ToolError(error.code, error.message);
    }
    return payload.data as T;
  }

  private unreachable(cause: unknown): ToolError {
    return new ToolError(
      "OWNER_GONE",
      `The roblox-studio-mcp instance holding port ${this.port} (pid ${this.owner.pid}) ` +
        `stopped answering: ${cause instanceof Error ? cause.message : String(cause)}`,
      "That process owns the Studio connection and this one borrows it. It has most " +
        "likely exited — restart this MCP server and it will take the port itself.",
    );
  }

  call<T = unknown>(
    op: string,
    params: Record<string, unknown> = {},
    options: { studioId?: string; timeoutMs?: number } = {},
  ): Promise<T> {
    return this.post<T>("/call", { op, params, ...options }, options.timeoutMs ?? 15_000);
  }

  async sessions(): Promise<SessionsView> {
    try {
      const response = await fetch(`${this.base}/sessions`, {
        headers: { [CLIENT_HEADER]: "peer" },
        signal: AbortSignal.timeout(5_000),
      });
      return (await response.json()) as SessionsView;
    } catch (cause) {
      throw this.unreachable(cause);
    }
  }

  async setActive(studioId: string): Promise<void> {
    await this.post("/active", { studioId }, 5_000);
  }

  async notePlaceName(studioId: string, placeName: string, context?: string): Promise<void> {
    // Best effort: this only refreshes a display name on the owner, and losing
    // it should never fail the call that happened to learn it.
    try {
      await this.post("/place-name", { studioId, placeName, context }, 5_000);
    } catch {
      /* ignored */
    }
  }
}
