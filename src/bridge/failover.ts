import { ToolError } from "../lib/errors.js";
import type { ClientDescription, SessionsView, StudioBridge } from "./api.js";
import type { RemoteBridge } from "./remote.js";

/**
 * How often a proxying peer checks whether the port has come free.
 *
 * The check is an ordinary bind attempt, which costs one syscall against a port
 * somebody holds, so this can be frequent without being wasteful. It is also
 * the only thing standing between the owner exiting and every other agent -- and
 * the Studio plugin -- having nothing to talk to, so frequent is what it should
 * be. Three seconds sits inside the plugin's own reconnect backoff, which means
 * the plugin usually finds the new owner on a retry it was going to make anyway.
 */
const WATCH_MS = 3_000;

/** What `claimPort` hands back when this process wins the port. */
export interface ClaimedPort {
  bridge: StudioBridge;
  close: () => Promise<void>;
}

/**
 * A bridge that proxies to the port owner, and becomes the owner if it dies.
 *
 * Ownership of the port is not a property of a process, it is a lease. Exactly
 * one process can hold the port the plugin dials, and every other MCP client
 * that starts this server proxies through that one. The gap this closes is what
 * used to happen when the holder exited: the peers went on proxying to a socket
 * nobody was listening on, so every tool call failed with OWNER_GONE and the
 * plugin's console sat on "Nothing is listening on port 44755" -- with two
 * perfectly healthy server processes running, either of which could have taken
 * over. Restarting the MCP client was the only way out, and nothing said so.
 *
 * The swap is invisible above this class. `ToolContext` holds this object, not
 * whatever it currently delegates to, so tools registered at startup keep
 * working across a handover without knowing one happened.
 */
export class FailoverBridge implements StudioBridge {
  private current: StudioBridge;
  private claimed: ClaimedPort | null = null;
  private watch: NodeJS.Timeout | null = null;
  private claiming = false;
  private stopped = false;

  /*
   * Remembered so a handover does not forget who we are. The MCP handshake
   * happens once, at startup; taking the port over happens whenever the holder
   * exits, which can be long after. Without this the new owner would list
   * itself as "unknown" for the rest of the session.
   */
  private about: ClientDescription | null = null;

  constructor(
    private readonly peer: RemoteBridge,
    private readonly claim: () => Promise<ClaimedPort | null>,
  ) {
    this.current = peer;
    this.watch = setInterval(() => void this.promote(), WATCH_MS);
    // Unref'd: watching for a vacancy is not a reason to keep this process
    // alive after its MCP client has gone.
    this.watch.unref();
  }

  /** Reads through, because which one is true changes under us. */
  get isOwner(): boolean {
    return this.current.isOwner;
  }

  /**
   * Takes the port if it is going spare.
   *
   * The bind attempt *is* the test. Probing first and binding after would leave
   * a window in which two peers both see a free port and both decide to take
   * it; binding is atomic, so at most one wins and the losers stay peers and
   * try again -- against, by then, the process that beat them.
   */
  private async promote(): Promise<void> {
    if (this.stopped || this.claiming || this.claimed !== null) return;
    this.claiming = true;
    try {
      const port = await this.claim();
      if (port === null) return; // Still someone else's. Fine; that is the normal case.
      if (this.stopped) {
        await port.close();
        return;
      }
      // Stops the keepalive aimed at the process that is gone. Best effort by
      // construction, and the request would now arrive at this process anyway.
      await this.peer.goodbye();
      this.claimed = port;
      this.current = port.bridge;
      if (this.about !== null) void port.bridge.describe(this.about);
      this.stopWatching();
      // stdout belongs to the MCP transport, so this goes to stderr. Worth
      // saying: a handover explains a Studio reconnect and a lost target
      // choice, and the absence of any such line is what made the original
      // failure so hard to read.
      process.stderr.write(
        "roblox-studio-mcp: the instance holding the bridge port exited; this one took it over.\n",
      );
    } catch {
      // A port we cannot have is not an error here, it is next tick's problem.
    } finally {
      this.claiming = false;
    }
  }

  private stopWatching(): void {
    if (this.watch === null) return;
    clearInterval(this.watch);
    this.watch = null;
  }

  /** Shuts down whichever role this process ended up in. */
  async close(): Promise<void> {
    this.stopped = true;
    this.stopWatching();
    if (this.claimed !== null) await this.claimed.close();
  }

  goodbye(): void | Promise<void> {
    return this.current.goodbye();
  }

  async call<T = unknown>(
    op: string,
    params: Record<string, unknown> = {},
    options: { studioId?: string; timeoutMs?: number } = {},
  ): Promise<T> {
    // Read per call, never cached: a handover mid-session must land on the next
    // call, not on the next restart. Deliberately not retried across one -- a
    // call that reached the old owner may have run, and running an edit twice
    // is a worse failure than reporting one that did not answer.
    return await this.failing(this.current.call<T>(op, params, options));
  }

  async sessions(): Promise<SessionsView> {
    return await this.failing(this.current.sessions());
  }

  /**
   * Lets a call that found the owner gone start the handover itself.
   *
   * The watchdog would get there within a few seconds anyway; this makes the
   * *next* call the one that works, rather than the one after the tick. The
   * failed call is still failed -- see `call` on why it is not retried here.
   */
  private async failing<T>(work: Promise<T>): Promise<T> {
    try {
      return await work;
    } catch (cause) {
      if (cause instanceof ToolError && cause.code === "OWNER_GONE") {
        void this.promote();
      }
      throw cause;
    }
  }

  setActive(studioId: string): Promise<void> {
    return this.current.setActive(studioId);
  }

  notePlaceName(studioId: string, placeName: string, context?: string): Promise<void> {
    return this.current.notePlaceName(studioId, placeName, context);
  }

  describe(about: ClientDescription): void | Promise<void> {
    this.about = about;
    return this.current.describe(about);
  }
}
