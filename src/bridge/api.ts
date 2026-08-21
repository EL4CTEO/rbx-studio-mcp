import { randomUUID } from "node:crypto";
import type { StudioSession } from "../lib/protocol.js";
import type { Bridge } from "./rpc.js";

/**
 * What a tool needs from the bridge, without knowing whether this process owns
 * the connection to Studio or is borrowing someone else's.
 *
 * The Studio plugin connects *out* to one TCP port, so exactly one process can
 * hold it — but every MCP client that registers this server starts its own
 * process. Two Claude sessions, or a Claude session and a Cursor window, and the
 * second one used to die on EADDRINUSE. Behind this interface the second, third
 * and tenth become clients of the first instead, and any number of agents drive
 * one Studio.
 *
 * Everything is async because the remote implementation is. `list` and the two
 * active-target reads collapse into one `sessions()` call: they are almost
 * always wanted together, and over HTTP three round trips for one answer is
 * three times the cost for none of the benefit.
 */
export interface StudioBridge {
  call<T = unknown>(
    op: string,
    params?: Record<string, unknown>,
    options?: { studioId?: string; timeoutMs?: number },
  ): Promise<T>;

  sessions(): Promise<SessionsView>;

  setActive(studioId: string): Promise<void>;

  notePlaceName(studioId: string, placeName: string, context?: string): Promise<void>;

  /** True when this process owns the port; false when it proxies to one that does. */
  readonly isOwner: boolean;
}

export interface SessionsView {
  list: StudioSession[];
  activeId: string | null;
  activeIsChosen: boolean;
}

/**
 * The bridge as seen from the process that actually holds the port.
 *
 * Carries a client id like any other, rather than being privileged as "the"
 * client. The process holding the port is still just one agent among however
 * many are connected, and its chosen Studio has no more right to leak into
 * everyone else's calls than a proxying peer's would.
 */
export class LocalBridge implements StudioBridge {
  readonly isOwner = true;
  private readonly clientId = randomUUID();

  constructor(private readonly inner: Bridge) {}

  call<T = unknown>(
    op: string,
    params: Record<string, unknown> = {},
    options: { studioId?: string; timeoutMs?: number } = {},
  ): Promise<T> {
    return this.inner.call<T>(op, params, { ...options, clientId: this.clientId });
  }

  async sessions(): Promise<SessionsView> {
    return {
      list: this.inner.list(),
      activeId: this.inner.activeId(this.clientId),
      activeIsChosen: this.inner.activeIsChosen(this.clientId),
    };
  }

  async setActive(studioId: string): Promise<void> {
    this.inner.setActive(this.clientId, studioId);
  }

  async notePlaceName(studioId: string, placeName: string, context?: string): Promise<void> {
    this.inner.notePlaceName(studioId, placeName, context);
  }
}
