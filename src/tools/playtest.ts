import { z } from "zod";
import { errorText, json, type ToolResult } from "../lib/format.js";
import { defineTool, type ToolContext } from "../lib/tool.js";

/** Set by the plugin when Workspace is big enough to make Stop freeze Studio. */
export interface HeavyWorkspace {
  instances: number;
  heaviest: Array<{ path: string; instances: number }>;
  animSavesInstances?: number;
  build: number;
}

interface PlaytestResponse {
  changed: boolean;
  reason?: string;
  heavyWorkspace?: HeavyWorkspace;
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

/** How long a stop of a heavy place is waited for, against 10s for an ordinary one. */
const HEAVY_STOP_WAIT_MS = 120_000;

const count = (value: number): string => value.toLocaleString("en-US");

/**
 * Explains a stop that is about to freeze Studio, or one that just did.
 *
 * From build 743 the playtest server clears a large Workspace so slowly that
 * the whole UI hangs for a minute or more (DevForum topic 4933776, ~220k
 * instances: 3-4s on 742, 65-75s on 743). It looks like a crash to the user
 * and a timeout to the agent, and neither is true: it ends on its own.
 */
export function heavyStopNote(heavy: HeavyWorkspace, stopping: boolean): string {
  const biggest = heavy.heaviest.map((entry) => `${entry.path} (${count(entry.instances)})`).join(", ");
  const animSaves = heavy.animSavesInstances
    ? ` ${count(heavy.animSavesInstances)} are inside AnimSaves (saved Animation Editor clips), the usual cause;` +
      " moving them out of Workspace, e.g. to ServerStorage, removes the freeze."
    : "";
  return (
    `Workspace holds ${count(heavy.instances)} instances. Studio ${heavy.build} can freeze for a minute or more ` +
    "while a playtest of a place this size stops (a known Roblox regression, not a crash). " +
    `Largest: ${biggest}.${animSaves}` +
    (stopping ? " Waited up to 2 minutes for the stop." : " Warn the user before stopping it.")
  );
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
        "replication. `addPlayers` joins more players to a running multiplayer " +
        "test, for late joins and lobby fill-up. `state` reports without " +
        "changing anything.\n\n" +
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
        "playtesting even when ON. `playtests off` is a hard MCP lock: play, run, " +
        "multiplayer and addPlayers are refused regardless of instructions to test; state and stop " +
        "remain available. The lock only blocks starting simulation: screenshots, tree, " +
        "inspect, script reads, edit-mode execute_luau and UI inspection stay available. " +
        "Continue using edit-mode tools and static inspection where possible. " +
        "Only the user can re-enable it with `playtests on` in " +
        "the panel. Do not bypass the lock through execute_luau, Studio APIs or " +
        "another operation. Manual Studio Play is unaffected.",
      inputSchema: {
        op: z
          .enum(["play", "run", "multiplayer", "addPlayers", "stop", "state"])
          .describe(
            "'play' starts a playtest with a character, 'run' runs scripts with " +
              "no player, 'multiplayer' starts a several-player test, 'addPlayers' " +
              "joins more to a running multiplayer test, 'stop' ends it and " +
              "discards its changes, 'state' only reports.",
          ),
        players: z
          .number()
          .int()
          .min(1)
          .max(8)
          .optional()
          .describe(
            "multiplayer: how many players to start (default 2). addPlayers: how " +
              "many to add (default 1).",
          ),
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
          const ended = await bridge
            .call<PlaytestResponse>("playtest.control", { op: "endTest", value: args.args }, {
              studioId: playtest,
              timeoutMs: 10_000,
            })
            .catch(() => null);
          const heavy = ended?.heavyWorkspace;

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
            const deadline = Date.now() + (heavy ? HEAVY_STOP_WAIT_MS : 10_000);
            let after: PlaytestResponse | undefined;
            for (;;) {
              // A frozen Studio answers nothing, so a failed poll is a reason
              // to keep waiting, not a failed stop.
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
              ).catch(() => after);
              const settled = after !== undefined && after.state.editModeActive !== false && !after.state.testPending;
              if (settled || Date.now() >= deadline) break;
              await new Promise((resolve) => setTimeout(resolve, heavy ? 1_000 : 400));
            }

            const stopped = after !== undefined && after.state.editModeActive !== false && !after.state.testPending;
            const notes: string[] = [];
            if (heavy) notes.push(heavyStopNote(heavy, true));
            if (!stopped) {
              notes.push(
                heavy
                  ? 'Studio is still tearing the test down. Check `playtest op="state"` again in a minute.'
                  : "The stop was sent but Studio is still in a test. Check whether " +
                      "something inside it is holding the session open.",
              );
            }
            return json(after?.state ?? { stopping: true }, notes.length > 0 ? notes.join("\n") : undefined);
          }
        }
      }

      // Routed like `stop`: AddPlayers is only callable from the running test's
      // server, and the new clients take seconds to load, so the reply waits
      // until they are in rather than reporting the count from before.
      if (args.op === "addPlayers") {
        const playtest = await findPlaytestSession(bridge);
        if (!playtest) {
          return errorText('No playtest is running. Start one with `playtest op="multiplayer"` first.');
        }
        const adding = args.players ?? 1;
        const started = await bridge.call<PlaytestResponse>(
          "playtest.control",
          { op: "addPlayers", players: adding },
          { studioId: playtest, timeoutMs: 10_000 },
        );
        const target = started.state.playerCount + adding;
        const deadline = Date.now() + 20_000;
        let after = started;
        while (after.state.playerCount < target && Date.now() < deadline) {
          await new Promise((resolve) => setTimeout(resolve, 500));
          after = await bridge.call<PlaytestResponse>(
            "playtest.control",
            { op: "state" },
            { studioId: playtest, timeoutMs: 5_000 },
          );
        }
        return json(
          { ...after.state, studioId: playtest },
          after.state.playerCount < target
            ? `${target - after.state.playerCount} of ${adding} new players had not joined after 20s. Check \`state\` again shortly.`
            : undefined,
        );
      }

      const starting = args.op === "play" || args.op === "multiplayer";
      const before = starting ? new Set((await bridge.sessions()).list.map((session) => session.studioId)) : new Set<string>();
      const response = await bridge.call<PlaytestResponse>(
        "playtest.control",
        { op: args.op, players: args.players, args: args.args },
        { studioId: args.studioId, timeoutMs: 30_000 },
      );

      const notes: string[] = [];
      if (starting && response.heavyWorkspace) notes.push(heavyStopNote(response.heavyWorkspace, false));
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
            if ((runtime.players?.length ?? 0) >= (args.op === "multiplayer" ? (args.players ?? 2) : 1)) break;
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
