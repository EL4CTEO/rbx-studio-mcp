import type { Credentials } from "./credentials.js";
import { ToolError } from "./errors.js";
import { call } from "./opencloud.js";

/**
 * Running Luau against the PUBLISHED game, over Open Cloud.
 *
 * `execute_luau` already runs code — inside Studio, against the place someone
 * has open. This runs it on Roblox's own servers against the published place,
 * with no Studio involved at all. That is a different question with the same
 * shape: "what does this code do here" versus "what does this code do in
 * production", and it is the only way to answer the second one.
 *
 * Roblox models it as a task rather than a request: you create one, it queues,
 * a server picks it up, and the result appears later. So this submits and then
 * polls, and reports the state it ended in rather than pretending it was
 * synchronous.
 *
 * It is genuinely dangerous in a way the Studio path is not. Studio has an undo
 * stack and a place file nobody is playing; this touches live data stores and
 * live players, and nothing here can put any of it back. The tool gates it.
 */
const POLL_INTERVAL_MS = 2_000;

interface Task {
  path?: string;
  state?: string;
  script?: string;
  output?: { results?: unknown[] };
  error?: { code?: string; message?: string };
}

interface LogPage {
  luauExecutionSessionTaskLogs?: Array<{ messages?: string[] }>;
}

export async function runLiveLuau(
  credentials: Credentials,
  args: { universeId: string; placeId: string; source: string; timeoutSeconds: number },
): Promise<Record<string, unknown>> {
  const started = await call<Task>(credentials, {
    method: "POST",
    path:
      `/cloud/v2/universes/${encodeURIComponent(args.universeId)}` +
      `/places/${encodeURIComponent(args.placeId)}/luau-execution-session-tasks`,
    body: { script: args.source, timeout: `${args.timeoutSeconds}s` },
    scope: "universe.place.luau-execution-session:write",
  });

  if (!started.path) {
    throw new ToolError(
      "NO_TASK",
      "Roblox accepted the script but did not say where to track it.",
    );
  }

  /**
   * Waited on for the script's own timeout plus a margin.
   *
   * The margin is for the queue: a task is not running the moment it is
   * created, and giving up at exactly the script timeout would report a
   * failure for a script that had not started yet.
   */
  const deadline = Date.now() + (args.timeoutSeconds + 30) * 1000;
  let task = started;

  while (task.state === "QUEUED" || task.state === "PROCESSING" || task.state === undefined) {
    if (Date.now() >= deadline) {
      return {
        target: "live",
        state: task.state ?? "UNKNOWN",
        task: started.path,
        note:
          "Gave up waiting. The task may still be running on Roblox's side — " +
          "it was not cancelled.",
      };
    }
    await new Promise((done) => setTimeout(done, POLL_INTERVAL_MS));
    task = await call<Task>(credentials, {
      path: `/cloud/v2/${started.path}`,
      query: { view: "FULL" },
      scope: "universe.place.luau-execution-session:write",
    });
  }

  // Logs are a separate resource from the result, and they hold everything the
  // script printed — which for a diagnostic script is the whole point.
  let logs: string[] = [];
  try {
    const page = await call<LogPage>(credentials, {
      path: `/cloud/v2/${started.path}/logs`,
      query: { maxPageSize: 100 },
      scope: "universe.place.luau-execution-session:write",
    });
    logs = (page.luauExecutionSessionTaskLogs ?? []).flatMap((entry) => entry.messages ?? []);
  } catch {
    // A missing log page is not worth failing a successful run over.
  }

  return {
    target: "live",
    universeId: args.universeId,
    placeId: args.placeId,
    state: task.state,
    results: task.output?.results,
    logs,
    error: task.error ? `${task.error.code ?? "error"}: ${task.error.message ?? ""}` : undefined,
  };
}
