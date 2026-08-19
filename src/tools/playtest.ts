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
    isPaused: boolean;
    playerCount: number;
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
        "Starts, pauses and stops Studio's simulation, so scripts can be made to " +
        "run and then observed without asking the user to press anything.\n\n" +
        "Pair it with `console` and `performance`: run, let the place do its " +
        "thing, then read the output, the counters or the coverage. `op: \"state\"` " +
        "reports where Studio is now without changing it.\n\n" +
        "This is Run mode, not Play mode. Scripts execute in the current place, " +
        "but no player joins and no character spawns, so anything waiting on " +
        "`Players.PlayerAdded` never fires — for that the user still has to press " +
        "Play themselves. Run mode also stays in one session rather than spawning " +
        "a second one, so the studioId does not change.\n\n" +
        "Stopping discards everything the simulation changed, exactly as pressing " +
        "Stop does. Build in edit mode, then run — not the other way round.\n\n" +
        "The reply says whether the mode actually moved, not merely that Studio " +
        "accepted the request.",
      inputSchema: {
        op: z
          .enum(["run", "pause", "stop", "state"])
          .describe(
            "'run' starts the simulation, 'pause' freezes it, 'stop' ends it and " +
              "discards its changes, 'state' only reports.",
          ),
        studioId: z.string().optional().describe("Target Studio; omit for the active one."),
      },
      readOnly: false,
      destructive: true,
    },
    async (args): Promise<ToolResult> => {
      const response = await bridge.call<PlaytestResponse>(
        "playtest.control",
        { op: args.op },
        { studioId: args.studioId, timeoutMs: 20_000 },
      );

      const note =
        args.op !== "state" && !response.changed
          ? response.reason ?? "Studio accepted the call but nothing changed."
          : undefined;

      return json(response.state, note);
    },
  );
}
