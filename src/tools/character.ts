import { z } from "zod";
import { json, table, text, textOf, type ToolResult } from "../lib/format.js";
import { defineTool, type ToolContext } from "../lib/tool.js";

interface PathResponse {
  reachable: boolean;
  status: string;
  from: string;
  to: string;
  straightLineDistance: number;
  pathDistance: number;
  detour: number;
  waypointCount: number;
  jumps: number;
  waypoints: Array<{ index: number; action: string; position: string; label?: string }>;
  hint: string;
}

interface MoveResponse {
  /** Where it stopped making progress, when it did not arrive. */
  stuckAt?: string;
  /** The instance a ray found between it and the next waypoint. */
  blockedBy?: string;
  jumps?: number;
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
        "This drives the Humanoid directly rather than simulating keystrokes, " +
        "which is the right tool for going places: pathfinding around a wall is " +
        "one call here and a sequence of guessed key presses otherwise. For " +
        "anything bound to a control rather than to movement — does E open the " +
        "door, does the sprint key work, does Escape close the menu — use " +
        "`input`, which sends real key and mouse events.\n\n" +
        "REQUIRES A RUNNING PLAYTEST, and the character lives in the playtest's " +
        "data model — address these to the playtest's studioId from " +
        "`list_studios`, not the editor's. Run mode has no character at all; " +
        "use `playtest op=play`.",
      inputSchema: {
        op: z
          .enum(["moveTo", "path", "act", "state"])
          .describe(
            "'moveTo' walks somewhere, 'path' checks a route without walking it, " +
              "'act' performs an action, 'state' only reports.",
          ),
        to: z
          .string()
          .optional()
          .describe('Target position, e.g. "25, 5, -10". Used by moveTo and by teleport.'),
        path: z
          .string()
          .optional()
          .describe("moveTo only: walk to this instance instead of a coordinate."),
        from: z
          .string()
          .optional()
          .describe('path only: where the route starts, e.g. "0, 5, 0". Defaults to the character.'),
        fromPath: z
          .string()
          .optional()
          .describe('path only: an instance to start from, e.g. "Workspace.SpawnLocation".'),
        toPath: z
          .string()
          .optional()
          .describe("path only: an instance to end at instead of `to`."),
        agentRadius: z
          .number()
          .min(0.1)
          .max(50)
          .optional()
          .describe(
            "How wide the walker is, in studs. Defaults to 2 — a standard " +
              "character. Raise it to ask whether a bigger NPC fits through the " +
              "same gaps a player does.",
          ),
        agentHeight: z
          .number()
          .min(0.1)
          .max(100)
          .optional()
          .describe("How tall the walker is. Defaults to 5, a standard character."),
        canClimb: z.boolean().optional().describe("Whether it may climb truss. Off by default."),
        spacing: z
          .number()
          .min(0.1)
          .max(100)
          .optional()
          .describe(
            "Studs between waypoints, default 4. Tighter follows the geometry more " +
              "closely; wider is a coarser route.",
          ),
        costs: z
          .record(z.string(), z.number())
          .optional()
          .describe(
            'Material or PathfindingModifier label → cost, e.g. { "Water": 20 } to ' +
              "avoid swimming. Higher is more avoided; the route chosen is the " +
              "cheapest total, not the shortest.",
          ),
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
      /*
       * Agent shape travels with both ops, from one place, so a route `path`
       * reports as walkable is a route `moveTo` walks with the same body.
       */
      const agent = {
        agentRadius: args.agentRadius,
        agentHeight: args.agentHeight,
        canJump: args.canJump,
        canClimb: args.canClimb,
        spacing: args.spacing,
        costs: args.costs,
      };

      if (args.op === "path") {
        const route = await bridge.call<PathResponse>(
          "character.path",
          { from: args.from, fromPath: args.fromPath, to: args.to, toPath: args.toPath, ...agent },
          { studioId: args.studioId, timeoutMs: 30_000 },
        );

        if (!route.reachable) {
          return text(
            `No route: ${route.status}.\n` +
              `${route.from} → ${route.to} is ${route.straightLineDistance} studs apart in a ` +
              `straight line, but nothing walkable connects them for an agent this size.\n\n` +
              route.hint,
          );
        }

        const lines = [
          `Reachable — ${route.pathDistance} studs walked vs ${route.straightLineDistance} ` +
            `straight (detour ${route.detour}x), ${route.waypointCount} waypoints, ${route.jumps} jump(s).`,
        ];
        if (route.detour > 2) {
          lines.push(
            "",
            `That is a long way round for the distance. Something between the two points ` +
              "is forcing a detour — worth a look if it was meant to be a direct route.",
          );
        }
        if (route.jumps > 0) {
          lines.push(
            "",
            `${route.jumps} jump(s) on this route. Anything that cannot jump — a vehicle, ` +
              "an NPC with jumping disabled — cannot follow it.",
          );
        }
        lines.push(
          "",
          textOf(
            table(
              ["index", "action", "position", "label"],
              route.waypoints as unknown as Array<Record<string, unknown>>,
              { more: "walking waypoints between these are omitted" },
            ),
          ),
        );
        return text(lines.join("\n"));
      }

      if (args.op === "moveTo") {
        const response = await bridge.call<MoveResponse>(
          "character.moveTo",
          { to: args.to, path: args.path, direct: args.direct, player: args.player, ...agent },
          // Walking a long route is genuinely slow, and the handler waits for
          // each waypoint rather than returning before it arrives.
          { studioId: args.studioId, timeoutMs: 60_000 },
        );
        const notes: string[] = [];
        if (response.note) notes.push(response.note);
        /*
         * Only add the vague advice when the handler could not name a cause.
         * With `blockedBy` set it already said which instance is in the way,
         * and following that with "something is in the way" reads as if the
         * tool did not know — which it did.
         */
        /*
         * Only when the handler said nothing itself. It already explains what
         * happened in `note`, and appending "something is physically in the
         * way" after "nothing was in the ray's way" contradicts it in the same
         * breath.
         */
        if (
          !response.arrived &&
          response.note === undefined &&
          response.pathStatus === "Enum.PathStatus.Success"
        ) {
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
