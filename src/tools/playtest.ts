import { z } from "zod";
import { json, type ToolResult } from "../lib/format.js";
import { defineTool, type ToolContext } from "../lib/tool.js";

interface PlaytestResponse {
  changed: boolean;
  reason?: string;
  state: {
    playtestsAllowed?: boolean;
    isEdit: boolean;
    isRunning: boolean;
    isRunMode: boolean;
    editModeActive?: boolean;
    playerCount: number;
    players?: Array<{ name: string; userId: number }>;
    testPending: boolean;
    lastResult?: unknown;
    lastError?: string;
    runningForSeconds?: number;
  };
}

/**
 * The studioId of the running playtest's server session, or null.
 *
 * Prefers the cached context so the common case costs nothing, and asks the
 * sessions directly when nothing is cached -- which is the situation right
 * after this tool started a test, since the new session has never been queried
 * and its context is exactly what the caller needs.
 */
async function findPlaytestSession(bridge: ToolContext["bridge"], exclude: ReadonlySet<string> = new Set()): Promise<string | null> {
  const sessions = (await bridge.sessions()).list;
  const cached = sessions.find((session) => !exclude.has(session.studioId) && session.context?.includes("playtest") && !session.context?.includes("client"));
  if (cached) return cached.studioId;

  const unknown = sessions.filter((session) => !exclude.has(session.studioId) && session.context === undefined);
  const probed = await Promise.all(
    unknown.map(async (session) => {
      try {
        const status = await bridge.call<{ placeName: string; context?: string }>(
          "studio.status",
          {},
          { studioId: session.studioId, timeoutMs: 3_000 },
        );
        await bridge.notePlaceName(session.studioId, status.placeName, status.context);
        return status.context?.includes("playtest") && !status.context?.includes("client") ? session.studioId : null;
      } catch {
        return null;
      }
    }),
  );
  return probed.find((id): id is string => id !== null) ?? null;
}

export function registerPlaytestTools(context: ToolContext): void {
  const { bridge } = context;

  defineTool(
    context,
    {
      name: "playtest",
      title: "Run, pause and stop the simulation",
      description:
        "Starts and stops playtests, so scripts can be made to run and then " +
        "observed without asking the user to press anything.\n\n" +
        "`play` is the Play button: a character spawns and `Players.PlayerAdded` " +
        "fires. `run` is Run mode, which executes scripts with no player at all. " +
        "`multiplayer` starts a test with several players for testing " +
        "replication. `state` reports without changing anything.\n\n" +
        "Play and multiplayer return the playtest server's studioId once it connects. " +
        "Use that ID directly for `console`, `performance` and `execute_luau`; " +
        "the editor session has a separate log. If connection takes too long, " +
        "the reply says so and `list_studios` can find it later.\n\n" +
        "A test does not block this call: it starts and the reply reports the " +
        "state reached. Studio only ends it when something inside calls " +
        "`StudioTestService:EndTest(value)` or when `stop` is used here; whatever " +
        "EndTest passed comes back as `lastResult` on a later `state`. That makes " +
        "a scripted check possible end to end: `args` is readable inside the test " +
        "via `StudioTestService:GetTestArgs()`, so a test can be told what to do " +
        "and report back what happened.\n\n" +
        "Stopping discards everything the playtest changed, exactly as pressing " +
        "Stop does. Build in edit mode, then play — not the other way round.\n\n" +
        "The reply says whether the mode actually moved, not merely that Studio " +
        "accepted the request.\n\n" +
        "The panel's `playtests on` grants permission, never a requirement: obey " +
        "AGENTS.md, CLAUDE.md, user instructions and project guidance that prohibit " +
        "playtesting even when ON. `playtests off` is a hard MCP lock: play, run and " +
        "multiplayer are refused regardless of instructions to test; state and stop " +
        "remain available. The lock only blocks starting simulation: screenshots, tree, " +
        "inspect, script reads, edit-mode execute_luau and UI inspection stay available. " +
        "Continue using edit-mode tools and static inspection where possible. " +
        "Only the user can re-enable it with `playtests on` in " +
        "the panel. Do not bypass the lock through execute_luau, Studio APIs or " +
        "another operation. Manual Studio Play is unaffected.",
      inputSchema: {
        op: z
          .enum(["play", "run", "multiplayer", "stop", "state"])
          .describe(
            "'play' starts a playtest with a character, 'run' runs scripts with " +
              "no player, 'multiplayer' starts a several-player test, 'stop' ends " +
              "it and discards its changes, 'state' only reports.",
          ),
        players: z
          .number()
          .int()
          .min(1)
          .max(8)
          .default(2)
          .describe("multiplayer only: how many players to start."),
        args: z
          .string()
          .optional()
          .describe(
            "Value handed to the test, readable inside it with " +
              "`StudioTestService:GetTestArgs()`. Use it to tell a test which " +
              "case to exercise.",
          ),
        studioId: z.string().optional().describe("Target Studio; omit for the active one."),
      },
      readOnly: false,
      destructive: true,
    },
    async (args): Promise<ToolResult> => {
      //[[
      // Stopping is routed rather than sent where it was asked.
      //
      // Starting a playtest creates a second session, which immediately makes
      // every later call ambiguous -- including the stop for the test just
      // started, so the tool could begin something it could not end. And the
      // stop cannot be served by the editor session anyway: `LeaveTest` is
      // client-DataModel only and a playtest client can never reach this
      // bridge, so only `EndTest`, from the playtest's server session, ends a
      // test. Both problems have the same answer: find that session.
      //]]
      if (args.op === "stop") {
        const playtest = await findPlaytestSession(bridge);
        if (playtest) {
          //[[
          // The stop is sent to the session it will destroy, so its reply is
          // expected to go missing and a transport failure here says nothing
          // about whether the test ended. The answer comes from the editor
          // session, which survives — and which is also the only session that
          // holds the value EndTest passed back.
          //]]
          await bridge
            .call("playtest.control", { op: "endTest", value: args.args }, {
              studioId: playtest,
              timeoutMs: 10_000,
            })
            .catch(() => null);

          const survivor = (await bridge.sessions()).list.find(
            (session) => session.studioId !== playtest,
          );
          if (survivor) {
            //[[
            // Waited for, not sampled. The teardown is deliberately deferred so
            // the reply can leave first, and tearing a DataModel down is not
            // instant either — so a single read taken straight afterwards
            // reports a test still running that is already on its way out. That
            // is the same false report as before, just pointing the other way.
            //]]
            const deadline = Date.now() + 10_000;
            let after: PlaytestResponse;
            for (;;) {
              after = await bridge.call<PlaytestResponse>(
                "playtest.control",
                // `waitingForStop` is inert on the plugin side -- Playtest.control
                // reads only `op`. It rides along so the console can tell this
                // poll apart from an agent's own `state` check: without it, five
                // identical "Check the playtest" lines in two seconds read as
                // unexplained noise rather than what they are, which is this
                // call waiting for the teardown it just started.
                { op: "state", waitingForStop: true },
                { studioId: survivor.studioId, timeoutMs: 10_000 },
              );
              const settled = after.state.editModeActive !== false && !after.state.testPending;
              if (settled || Date.now() >= deadline) break;
              await new Promise((resolve) => setTimeout(resolve, 400));
            }

            const stopped = after.state.editModeActive !== false && !after.state.testPending;
            return json(
              after.state,
              stopped
                ? undefined
                : "The stop was sent but Studio is still in a test. Check whether " +
                    "something inside it is holding the session open.",
            );
          }
        }
      }

      const starting = args.op === "play" || args.op === "multiplayer";
      const before = starting ? new Set((await bridge.sessions()).list.map((session) => session.studioId)) : new Set<string>();
      const response = await bridge.call<PlaytestResponse>(
        "playtest.control",
        { op: args.op, players: args.players, args: args.args },
        { studioId: args.studioId, timeoutMs: 30_000 },
      );

      const notes: string[] = [];
      if (args.op !== "state" && !response.changed) {
        notes.push(response.reason ?? "Studio accepted the call but nothing changed.");
      } else if (response.reason) {
        notes.push(response.reason);
      }

      // The running game is a different session from the one just asked to start
      // it, and every subsequent read has to go to that one instead. Said here
      // because the alternative is an agent reading the editor's empty log and
      // concluding the playtest did nothing.
      let runtime: { studioId: string; players?: Array<{ name: string; userId: number }> } | undefined;
      if (starting && response.changed && response.state.testPending) {
        const deadline = Date.now() + 6_000;
        do {
          const id = runtime?.studioId ?? await findPlaytestSession(bridge, before);
          if (id) {
            runtime ??= { studioId: id };
            try {
              const state = await bridge.call<PlaytestResponse>("playtest.control", { op: "state" }, { studioId: id, timeoutMs: 2_000 });
              runtime.players = state.state.players;
            } catch { /* A connecting session can already be listed before it answers. */ }
            if ((runtime.players?.length ?? 0) >= (args.op === "multiplayer" ? args.players : 1)) break;
          }
          if (Date.now() >= deadline) break;
          await new Promise((resolve) => setTimeout(resolve, 300));
        } while (true);
        if (!runtime) notes.push("The playtest server has not connected yet. Use list_studios later to find its studioId.");
        else if (!runtime.players?.length) notes.push("The playtest server connected, but players are still joining. Query playtest state later for names.");
      }

      return json(runtime ? { ...response.state, ...runtime } : response.state, notes.length > 0 ? notes.join("\n") : undefined);
    },
  );
}
