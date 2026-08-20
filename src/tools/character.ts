import { z } from "zod";
import { json, type ToolResult } from "../lib/format.js";
import { defineTool, type ToolContext } from "../lib/tool.js";

interface MoveResponse {
  arrived: boolean;
  distance?: number;
  waypoints?: number;
  waypointsReached?: number;
  pathStatus: string;
  from: string;
  to?: string;
  goal: string;
  note?: string;
}

export function registerCharacterTools(context: ToolContext): void {
  const { bridge } = context;

  defineTool(
    context,
    {
      name: "character",
      title: "Drive the player during a playtest",
      description:
        "Moves and acts as the player character in a running playtest, so " +
        "gameplay can be tested without asking the user to play it.\n\n" +
        "`moveTo` walks to a position or to an instance, following a path " +
        "computed around walls and gaps rather than a straight line into them. " +
        "It reports whether it ACTUALLY ARRIVED and how far short it stopped — " +
        "a route blocked by something you did not know about otherwise looks " +
        "identical to a successful walk.\n\n" +
        "`act` does the one-shot things worth testing: jump, sit, stand, " +
        "respawn, kill (to exercise the death and respawn path), teleport, and " +
        "`equip`/`activate` to use a Tool — which is how combat gets tested, " +
        "since Activate is exactly what a mouse click triggers. Note " +
        "that teleport skips everything in between, so triggers and collisions " +
        "along the route do not fire — walk if you are testing those.\n\n" +
        "`state` reports position, health, walk speed and what the humanoid is " +
        "doing. Call it before and after anything else here.\n\n" +
        "This drives the Humanoid directly rather than simulating keystrokes. " +
        "Studio blocks plugins from synthetic input entirely — " +
        "`VirtualInputManager` requires the RobloxScript capability and " +
        "`VirtualUser` requires LocalUser — so key and mouse injection is not " +
        "available to any third-party server, including this one. Driving the " +
        "Humanoid answers the questions that actually matter (can it reach the " +
        "door, does the trap fire, does the checkpoint save) more directly " +
        "anyway.\n\n" +
        "REQUIRES A RUNNING PLAYTEST, and the character lives in the playtest's " +
        "data model — address these to the playtest's studioId from " +
        "`list_studios`, not the editor's. Run mode has no character at all; " +
        "use `playtest op=play`.",
      inputSchema: {
        op: z
          .enum(["moveTo", "act", "state"])
          .describe("'moveTo' walks somewhere, 'act' performs an action, 'state' only reports."),
        to: z
          .string()
          .optional()
          .describe('Target position, e.g. "25, 5, -10". Used by moveTo and by teleport.'),
        path: z
          .string()
          .optional()
          .describe("moveTo only: walk to this instance instead of a coordinate."),
        direct: z
          .boolean()
          .default(false)
          .describe(
            "moveTo only: walk straight at the target without pathfinding. Use " +
              "when a route is reported unreachable but you want to see what happens.",
          ),
        canJump: z.boolean().default(true).describe("moveTo only: allow the path to include jumps."),
        action: z
          .enum([
            "jump", "stop", "sit", "stand", "respawn", "kill", "teleport",
            "equip", "activate", "unequip",
          ])
          .optional()
          .describe(
            "act only: what to do. 'equip' takes a Tool from the Backpack or " +
              "StarterPack, 'activate' uses it (what a mouse click triggers).",
          ),
        tool: z.string().optional().describe("equip only: the Tool's name."),
        player: z
          .string()
          .optional()
          .describe("Which player, by name. Omit for the only one; needed in a multiplayer test."),
        studioId: z
          .string()
          .optional()
          .describe("The PLAYTEST session's id — not the editor's. See list_studios."),
      },
      destructive: false,
    },
    async (args): Promise<ToolResult> => {
      if (args.op === "moveTo") {
        const response = await bridge.call<MoveResponse>(
          "character.moveTo",
          { to: args.to, path: args.path, direct: args.direct, canJump: args.canJump, player: args.player },
          // Walking a long route is genuinely slow, and the handler waits for
          // each waypoint rather than returning before it arrives.
          { studioId: args.studioId, timeoutMs: 60_000 },
        );
        const notes: string[] = [];
        if (response.note) notes.push(response.note);
        if (!response.arrived && response.pathStatus === "Enum.PathStatus.Success") {
          notes.push(
            "The path was valid but the character did not reach the end — something " +
              "is physically in the way, or it fell. Take a `screenshot` to see where it stopped.",
          );
        }
        return json(response, notes.length > 0 ? notes.join(" ") : undefined);
      }

      if (args.op === "act") {
        const response = await bridge.call<Record<string, unknown>>(
          "character.act",
          { action: args.action ?? "jump", to: args.to, tool: args.tool, player: args.player },
          { studioId: args.studioId },
        );
        return json(response);
      }

      const response = await bridge.call<Record<string, unknown>>(
        "character.state",
        { player: args.player },
        { studioId: args.studioId },
      );
      return json(response);
    },
  );
}
