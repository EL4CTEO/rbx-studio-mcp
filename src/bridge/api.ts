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
  /**
   * Tells the bridge this process is going away.
   *
   * Best-effort and never awaited for correctness -- a client killed outright
   * is swept by the staleness reaper instead -- but a clean goodbye is what
   * makes the console's "Agent finished task." land at the moment it happened
   * rather than ninety seconds later.
   */
  goodbye(): void | Promise<void>;

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
/**
 * How often the owner reminds the bridge it is still here.
 *
 * The same cadence a proxying peer uses, because it is the same problem. The
 * owner registered itself once and then never again, so the staleness reaper --
 * which cannot tell an absent client from a quiet one -- swept the owner out of
 * its own client list ninety seconds in, while it was actively serving. The
 * count then read one lower than the truth, and the drop was broadcast to the
 * Studio console as an agent having finished. Being in-process is not evidence
 * of being alive to a rule written in timestamps; the cheapest fix is to obey
 * the rule rather than carve an exception into it.
 */
const KEEPALIVE_MS = 30_000;

export class LocalBridge implements StudioBridge {
  readonly isOwner = true;
  private readonly clientId = randomUUID();
  private readonly keepalive: NodeJS.Timeout;

  constructor(private readonly inner: Bridge) {
    // Announced at construction rather than on first call, for the same reason
    // this class carries a client id at all: the process holding the port is
    // one agent among however many are connected, and it is connected from the
    // moment it starts, not from the moment it happens to ask for something.
    inner.noteClient(this.clientId);
    this.keepalive = setInterval(() => inner.noteClient(this.clientId), KEEPALIVE_MS);
    this.keepalive.unref();
  }

  /** Drops this process from the bridge's client list on shutdown. */
  goodbye(): void {
    clearInterval(this.keepalive);
    this.inner.forgetClient(this.clientId);
  }

  call<T = unknown>(
    op: string,
    params: Record<string, unknown> = {},
    options: { studioId?: string; timeoutMs?: number } = {},
  ): Promise<T> {
    // Working is proof of being here, exactly as it is for a peer on /call.
    this.inner.noteClient(this.clientId);
    return this.inner.call<T>(op, params, { ...options, clientId: this.clientId });
  }

  async sessions(): Promise<SessionsView> {
    this.inner.noteClient(this.clientId);
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
