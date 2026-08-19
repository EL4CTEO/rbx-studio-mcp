import { randomUUID } from "node:crypto";
import type { ServerResponse } from "node:http";
import {
  AMBIGUOUS_STUDIO,
  DISCONNECTED,
  NO_STUDIO,
  TIMEOUT,
  ToolError,
} from "../lib/errors.js";
import type {
  Command,
  CommandResult,
  StudioIdentity,
  StudioSession,
} from "../lib/protocol.js";

/** Default per-command deadline. Studio round trips are single-digit ms over SSE. */
export const DEFAULT_TIMEOUT_MS = 15_000;

/** How long a long-poll request is parked before we answer "idle". */
export const POLL_HOLD_MS = 25_000;

/** A session is considered dead if we have not heard from it in this long. */
const STALE_AFTER_MS = 90_000;

interface Pending {
  resolve: (value: unknown) => void;
  reject: (reason: ToolError) => void;
  timer: NodeJS.Timeout;
  op: string;
}

/** One connected Studio process, plus whatever it is using to receive commands. */
interface Session {
  identity: StudioIdentity;
  connectedAt: number;
  lastSeenAt: number;
  /** Live SSE response, when the plugin negotiated a stream. */
  stream: ServerResponse | null;
  /** Commands waiting for a long-poll request to pick them up. */
  queue: Command[];
  /** A parked long-poll request, if one is currently waiting. */
  waiter: ((command: Command | null) => void) | null;
  pending: Map<string, Pending>;
}

/**
 * Owns every connected Studio and the in-flight request table.
 *
 * The two transports converge here: `deliver` either writes straight to an open
 * SSE stream or parks the command for the next long-poll. Tools call `call()`
 * and never learn which one was used.
 */
export class Bridge {
  private readonly sessions = new Map<string, Session>();
  private activeStudioId: string | null = null;
  /**
   * Whether `activeStudioId` was picked by the user via set_active_studio, as
   * opposed to being the only session that happened to connect first.
   *
   * The distinction decides what happens when a second Studio appears. A
   * defaulted target silently becomes ambiguous — editing whichever place
   * connected first is not a reasonable guess — while a chosen one stays put,
   * because the user said which place they meant.
   */
  private activeWasChosen = false;

  // --- session lifecycle -------------------------------------------------

  attach(identity: StudioIdentity, stream: ServerResponse | null): string {
    const existing = this.sessions.get(identity.studioId);
    if (existing) {
      // Studio reconnected (SSE hit the 30-minute cap, or the plugin reloaded).
      // Keep pending calls alive across the gap so an in-flight tool survives.
      existing.stream?.end();
      existing.identity = identity;
      existing.stream = stream;
      existing.lastSeenAt = Date.now();
      this.flush(existing);
      return identity.studioId;
    }

    this.sessions.set(identity.studioId, {
      identity,
      connectedAt: Date.now(),
      lastSeenAt: Date.now(),
      stream,
      queue: [],
      waiter: null,
      pending: new Map(),
    });
    this.activeStudioId ??= identity.studioId;
    return identity.studioId;
  }

  detach(studioId: string): void {
    const session = this.sessions.get(studioId);
    if (!session) return;
    for (const pending of session.pending.values()) {
      clearTimeout(pending.timer);
      pending.reject(DISCONNECTED());
    }
    session.pending.clear();
    session.waiter?.(null);
    session.stream?.end();
    this.sessions.delete(studioId);
    if (this.activeStudioId === studioId) {
      // The place the user chose is gone, so the replacement is a fallback, not
      // a choice: mark it as such so a remaining pair goes ambiguous again.
      this.activeStudioId = this.sessions.keys().next().value ?? null;
      this.activeWasChosen = false;
    }
  }

  /** Drops sessions whose plugin stopped checking in without a clean detach. */
  reapStale(): void {
    const cutoff = Date.now() - STALE_AFTER_MS;
    for (const [id, session] of this.sessions) {
      if (session.lastSeenAt < cutoff && !session.stream) this.detach(id);
    }
  }

  touch(studioId: string): void {
    const session = this.sessions.get(studioId);
    if (session) session.lastSeenAt = Date.now();
  }

  /**
   * Records the place name a status call resolved.
   *
   * The identity announced at connect can only carry the data model's name
   * ("Place1"), because the real one takes a web lookup. Once any call has paid
   * for that lookup, every later mention of the session should use the name the
   * user recognises rather than reverting to the one they do not.
   */
  notePlaceName(studioId: string, placeName: string): void {
    const session = this.sessions.get(studioId);
    if (session && placeName) session.identity.placeName = placeName;
  }

  has(studioId: string): boolean {
    return this.sessions.has(studioId);
  }

  list(): StudioSession[] {
    return [...this.sessions.values()].map((session) => ({
      ...session.identity,
      connectedAt: session.connectedAt,
      lastSeenAt: session.lastSeenAt,
    }));
  }

  get activeId(): string | null {
    return this.activeStudioId;
  }

  /** True only once the user has actually picked a target. */
  get activeIsChosen(): boolean {
    return this.activeWasChosen;
  }

  setActive(studioId: string): void {
    if (!this.sessions.has(studioId)) {
      throw new ToolError(
        "UNKNOWN_STUDIO",
        `No connected Studio has id "${studioId}".`,
        "Call list_studios to see the connected instances and their ids.",
      );
    }
    this.activeStudioId = studioId;
    this.activeWasChosen = true;
  }

  // --- request/response --------------------------------------------------

  /**
   * Sends `op` to a Studio instance and resolves with its `data` payload.
   * Rejects with a ToolError carrying an agent-readable hint on any failure,
   * including errors raised inside the plugin.
   */
  call<T = unknown>(
    op: string,
    params: Record<string, unknown> = {},
    options: { studioId?: string; timeoutMs?: number } = {},
  ): Promise<T> {
    const session = this.resolveSession(options.studioId);
    const timeoutMs = options.timeoutMs ?? DEFAULT_TIMEOUT_MS;
    const command: Command = { id: randomUUID(), op, params };

    return new Promise<T>((resolve, reject) => {
      const timer = setTimeout(() => {
        session.pending.delete(command.id);
        reject(TIMEOUT(op, timeoutMs));
      }, timeoutMs);

      session.pending.set(command.id, {
        resolve: resolve as (value: unknown) => void,
        reject,
        timer,
        op,
      });
      this.deliver(session, command);
    });
  }

  /** Settles the promise a plugin result belongs to. Unknown ids are ignored. */
  settle(studioId: string, result: CommandResult): void {
    const session = this.sessions.get(studioId);
    if (!session) return;
    session.lastSeenAt = Date.now();

    const pending = session.pending.get(result.id);
    if (!pending) return; // already timed out; the tool has moved on
    session.pending.delete(result.id);
    clearTimeout(pending.timer);

    if (result.ok) {
      pending.resolve(result.data);
    } else {
      pending.reject(
        result.error
          ? ToolError.fromCommandError(result.error)
          : new ToolError("PLUGIN_ERROR", `Studio failed to run "${pending.op}".`),
      );
    }
  }

  /**
   * Parks a long-poll request until a command arrives or the hold expires.
   * Resolves null on expiry so the plugin can re-poll with a fresh request
   * rather than sitting on a connection Studio may time out underneath it.
   */
  waitForCommand(studioId: string): Promise<Command | null> {
    const session = this.sessions.get(studioId);
    if (!session) return Promise.resolve(null);
    session.lastSeenAt = Date.now();

    const queued = session.queue.shift();
    if (queued) return Promise.resolve(queued);

    return new Promise((resolve) => {
      const settle = (command: Command | null): void => {
        clearTimeout(timer);
        session.waiter = null;
        resolve(command);
      };
      const timer = setTimeout(() => {
        if (session.waiter === settle) session.waiter = null;
        resolve(null);
      }, POLL_HOLD_MS);
      session.waiter = settle;
    });
  }

  // --- internals ---------------------------------------------------------

  private resolveSession(studioId?: string): Session {
    if (studioId) {
      const session = this.sessions.get(studioId);
      if (!session) throw NO_STUDIO();
      return session;
    }
    if (this.sessions.size === 0) throw NO_STUDIO();

    // One Studio is never ambiguous, whether or not anyone chose it.
    const only = this.sessions.values().next().value;
    if (this.sessions.size === 1 && only) return only;

    if (this.activeWasChosen && this.activeStudioId) {
      const session = this.sessions.get(this.activeStudioId);
      if (session) return session;
    }
    throw AMBIGUOUS_STUDIO(
      this.list().map((session) => `${session.studioId} (${session.placeName})`),
    );
  }

  private deliver(session: Session, command: Command): void {
    if (session.stream && !session.stream.writableEnded) {
      session.stream.write(`data: ${JSON.stringify(command)}\n\n`);
      return;
    }
    if (session.waiter) {
      session.waiter(command);
      return;
    }
    session.queue.push(command);
  }

  /** Hands any queued commands to a stream that just (re)connected. */
  private flush(session: Session): void {
    if (!session.stream || session.stream.writableEnded) return;
    for (const command of session.queue.splice(0)) {
      session.stream.write(`data: ${JSON.stringify(command)}\n\n`);
    }
  }
}
