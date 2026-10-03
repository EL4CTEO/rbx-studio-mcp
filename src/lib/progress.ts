import { AsyncLocalStorage } from "node:async_hooks";

/**
 * Progress notifications for calls that take a while.
 *
 * MCP clients give every tool call a deadline -- about a minute in some -- and
 * several calls here are slower than that by nature: a generated model, a
 * script queued on Roblox's servers, an upload waiting on moderation. The
 * client gives up, the agent is told it failed, and the work usually finishes
 * anyway; the agent retries and does it twice.
 *
 * The protocol's answer is `notifications/progress`: a client that attaches a
 * progress token to a call is saying it will listen, and the SDK's clients
 * restart their deadline each time one arrives. So while a call runs, a short
 * heartbeat is sent. A client that sent no token gets nothing, and a quick call
 * finishes before the first heartbeat is due.
 */

/** Overridable so a test need not wait out real intervals. */
export const progressTiming = { firstMs: 5_000, everyMs: 8_000 };

interface Status {
  note?: string;
}

const current = new AsyncLocalStorage<Status>();

/**
 * Says what the running call is waiting on, for the next heartbeat. Harmless
 * anywhere else: with no call listening it does nothing.
 */
export function reportProgress(note: string): void {
  const status = current.getStore();
  if (status) status.note = note;
}

/** What a request carries when its client wants progress. */
export interface ProgressExtra {
  _meta?: { progressToken?: string | number };
  sendNotification?: (notification: {
    method: "notifications/progress";
    params: { progressToken: string | number; progress: number; message?: string };
  }) => Promise<void>;
}

/** Runs `work`, sending heartbeats for as long as it takes if the client asked. */
export async function withProgress<T>(label: string, extra: ProgressExtra | undefined, work: () => Promise<T>): Promise<T> {
  const token = extra?._meta?.progressToken;
  const send = extra?.sendNotification;
  if (token === undefined || send === undefined) return work();

  const status: Status = {};
  const started = Date.now();
  let beats = 0;
  let interval: NodeJS.Timeout | undefined;

  const beat = (): void => {
    beats += 1;
    const seconds = Math.round((Date.now() - started) / 1000);
    // A closed connection or a client that dropped the call is not this call's failure.
    void send({
      method: "notifications/progress",
      params: { progressToken: token, progress: beats, message: `${label}: ${status.note ?? "working"} (${seconds}s)` },
    }).catch(() => undefined);
  };

  const first = setTimeout(() => {
    beat();
    interval = setInterval(beat, progressTiming.everyMs);
    interval.unref();
  }, progressTiming.firstMs);
  first.unref();

  try {
    return await current.run(status, work);
  } finally {
    clearTimeout(first);
    if (interval) clearInterval(interval);
  }
}
