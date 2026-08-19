import { z } from "zod";
import { json, type ToolResult } from "../lib/format.js";
import { defineTool, type ToolContext } from "../lib/tool.js";

interface PlaytestResponse {
  changed: boolean;
  reason?: string;
  state: {
    isEdit: boolean;
    isRunning: boolean;
    isRunMode: boolean;
    editModeActive?: boolean;
    playerCount: number;
    testPending: boolean;
    lastResult?: unknown;
    lastError?: string;
    runningForSeconds?: number;
  };
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
        "Pressing play adds a SECOND connected session for the playtest's server, " +
        "and that is where the running game lives — `console`, `performance` and " +
        "`execute_luau` must target its studioId, not the editor's. Call " +
        "`list_studios` after starting and look for the entry whose context is a " +
        "playtest.\n\n" +
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
        "accepted the request.",
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
      if ((args.op === "play" || args.op === "multiplayer") && response.state.testPending) {
        notes.push(
          "The playtest runs in its own session. Call list_studios and target the " +
            "entry whose context is a playtest for console, performance and execute_luau.",
        );
      }

      return json(response.state, notes.length > 0 ? notes.join("\n") : undefined);
    },
  );
}
