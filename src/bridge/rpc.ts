import { randomUUID } from "node:crypto";
import type { ServerResponse } from "node:http";
import {
  AMBIGUOUS_STUDIO,
  DISCONNECTED,
  NO_STUDIO,
  SAME_PLACE_STUDIO,
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

/**
 * How long a client may go silent before we assume its process died.
 *
 * Peers post a keepalive well inside this, so the only thing it catches is a
 * client that was killed rather than closed. Matched to the session rule
 * deliberately: two different staleness windows on one bridge is a thing to
 * remember, and there is no reason for them to differ.
 */
const CLIENT_STALE_AFTER_MS = 90_000;

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

  /**
   * Every MCP client currently using this bridge, owner included.
   *
   * The bridge already knew clients existed -- `chosen` is keyed on them -- but
   * only ever learned of one at the moment it made a call, and never learned
   * that one had gone. So `forgetClient` sat here uncalled and a peer that
   * exited left its chosen Studio behind forever. Tracking them outright fixes
   * that leak and makes the count reportable, which is the thing a user sharing
   * one Studio between two agents actually wants to see.
   */
  private readonly clients = new Map<string, { lastSeenAt: number }>();

  /** Called whenever the client count changes, so the plugin can be told. */
  private onClientsChanged: ((count: number) => void) | null = null;

  /**
   * Which Studio each connected client chose, keyed by client.
   *
   * Per client, not per process, and that is the whole point. Any number of
   * agents share this bridge — the first server to start owns the port and the
   * rest proxy through it — so a single chosen target would be shared mutable
   * state between agents that cannot see each other: one calling
   * set_active_studio would silently retarget the next un-addressed call of
   * every other. Editing the wrong place is not a failure that announces
   * itself, so the answer is isolation rather than a warning.
   *
   * Presence in the map is what "chosen" means. That distinction decides what
   * happens when a second Studio appears: a client that never chose goes
   * ambiguous, because editing whichever place connected first is not a
   * reasonable guess, while one that did stays put, because it said what it
   * meant.
   */
  private readonly chosen = new Map<string, string>();

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

    // A choice that no longer exists is not a choice. Dropping it rather than
    // substituting a survivor is deliberate: with a pair left, going ambiguous
    // asks the question again, where quietly promoting whichever remains would
    // point the agent at a place nobody picked.
    for (const [clientId, chosenId] of this.chosen) {
      if (chosenId === studioId) this.chosen.delete(clientId);
    }
  }

  /** Drops sessions and clients that stopped checking in without a goodbye. */
  reapStale(): void {
    const cutoff = Date.now() - STALE_AFTER_MS;
    for (const [id, session] of this.sessions) {
      if (session.lastSeenAt < cutoff && !session.stream) this.detach(id);
    }

    // A client killed rather than closed never says goodbye. Without this its
    // entry would inflate the count for as long as the bridge lived.
    const clientCutoff = Date.now() - CLIENT_STALE_AFTER_MS;
    for (const [id, client] of this.clients) {
      if (client.lastSeenAt < clientCutoff) this.forgetClient(id);
    }
  }

  touch(studioId: string): void {
    const session = this.sessions.get(studioId);
    if (session) session.lastSeenAt = Date.now();
  }

  // --- clients -----------------------------------------------------------

  /** Records a client as present, or refreshes one already known. */
  noteClient(clientId: string): void {
    if (clientId.length === 0) return;
    const known = this.clients.has(clientId);
    this.clients.set(clientId, { lastSeenAt: Date.now() });
    if (!known) this.announceClients();
  }

  clientCount(): number {
    return this.clients.size;
  }

  /**
   * Subscribes to changes in the client count.
   *
   * A callback rather than the bridge writing to streams itself: the bridge
   * owns sessions and requests, and what a *change* should cause -- an SSE
   * frame, a log line, nothing at all -- belongs to whoever wired it up.
   */
  watchClients(listener: (count: number) => void): void {
    this.onClientsChanged = listener;
  }

  private announceClients(): void {
    this.onClientsChanged?.(this.clients.size);
  }

  /**
   * Records the place name a status call resolved.
   *
   * The identity announced at connect can only carry the data model's name
   * ("Place1"), because the real one takes a web lookup. Once any call has paid
   * for that lookup, every later mention of the session should use the name the
   * user recognises rather than reverting to the one they do not.
   */
  notePlaceName(studioId: string, placeName: string, context?: string): void {
    const session = this.sessions.get(studioId);
    if (!session) return;
    if (placeName) session.identity.placeName = placeName;
    if (context) session.identity.context = context;
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

  /**
   * What this client's calls target when they name no studioId.
   *
   * A lone Studio is reported as the target whether or not anyone picked it,
   * because with one connected there is nothing else a call could mean.
   */
  activeId(clientId: string): string | null {
    const picked = this.chosen.get(clientId);
    if (picked !== undefined && this.sessions.has(picked)) return picked;
    if (this.sessions.size === 1) return this.sessions.keys().next().value ?? null;
    return null;
  }

  /** True only once this client has actually picked a target. */
  activeIsChosen(clientId: string): boolean {
    const picked = this.chosen.get(clientId);
    return picked !== undefined && this.sessions.has(picked);
  }

  setActive(clientId: string, studioId: string): void {
    if (!this.sessions.has(studioId)) {
      throw new ToolError(
        "UNKNOWN_STUDIO",
        `No connected Studio has id "${studioId}".`,
        "Call list_studios to see the connected instances and their ids.",
      );
    }
    this.chosen.set(clientId, studioId);
  }

  /**
   * Drops a client that has gone away, and its chosen Studio with it.
   *
   * Returns true when the client was actually known, so a caller can tell a
   * real departure from a duplicate goodbye and only announce the first.
   */
  forgetClient(clientId: string): boolean {
    this.chosen.delete(clientId);
    if (!this.clients.delete(clientId)) return false;
    this.announceClients();
    return true;
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
    options: { clientId: string; studioId?: string; timeoutMs?: number },
  ): Promise<T> {
    const session = this.resolveSession(options.clientId, options.studioId);
    const timeoutMs = options.timeoutMs ?? DEFAULT_TIMEOUT_MS;
    const command: Command = { id: randomUUID(), op, params };

    return new Promise<T>((resolve, reject) => {
      const timer = setTimeout(() => {
        session.pending.delete(command.id);
        // A bare "it timed out" leaves nowhere to go, and the interesting part
        // is knowable here: whether the command ever left this process, and
        // whether the plugin has said anything since. A command still sitting in
        // the queue was never seen by Studio, which is a different fault from
        // one Studio took and did not finish.
        reject(
          TIMEOUT(op, timeoutMs, {
            delivered: session.queue.every((queued) => queued.id !== command.id),
            silentForMs: Date.now() - session.lastSeenAt,
            alsoInFlight: session.pending.size,
            transport: session.stream ? "sse" : "poll",
          }),
        );
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

  private resolveSession(clientId: string, studioId?: string): Session {
    if (studioId) {
      const session = this.sessions.get(studioId);
      if (!session) throw NO_STUDIO();
      return session;
    }
    if (this.sessions.size === 0) throw NO_STUDIO();

    // One Studio is never ambiguous, whether or not anyone chose it.
    const only = this.sessions.values().next().value;
    if (this.sessions.size === 1 && only) return only;

    const picked = this.chosen.get(clientId);
    if (picked !== undefined) {
      const session = this.sessions.get(picked);
      if (session) return session;
    }
    const connected = this.list();

    // The context is the part that decides it. Two rows reading "Untitled
    // Experience" are indistinguishable, and picking the playtest means work
    // that disappears when it stops.
    const rows = connected.map(
      (session) =>
        `${session.studioId} (${session.placeName}${session.context ? `, ${session.context}` : ""})`,
    );

    // A playtest is not a second place. Starting one connects a second session
    // on the same placeId, and telling the agent to go and ask which place the
    // user means is then a question with no answer -- there is one place, in two
    // states, and which to use follows from what is being asked rather than from
    // anything the user knows.
    const places = new Set(connected.map((session) => session.placeId));
    if (places.size === 1 && connected.length > 1) {
      throw SAME_PLACE_STUDIO(rows);
    }

    throw AMBIGUOUS_STUDIO(rows);
  }

  /**
   * Writes one non-command frame to every plugin holding an open stream.
   *
   * Poll sessions are not served here -- they have no socket to write to, and
   * their own response already carries the same value. Best-effort by design:
   * a plugin that misses one of these has stale trim on its header, which is
   * not worth a retry queue.
   */
  broadcast(frame: Record<string, unknown>): void {
    const payload = `data: ${JSON.stringify(frame)}\n\n`;
    for (const session of this.sessions.values()) {
      if (session.stream && !session.stream.writableEnded) session.stream.write(payload);
    }
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
