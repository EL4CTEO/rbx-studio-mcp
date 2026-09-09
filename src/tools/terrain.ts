import { z } from "zod";
import { json, text, type ToolResult } from "../lib/format.js";
import { defineTool, type ToolContext } from "../lib/tool.js";

interface FilledShape {
  shape: string;
  material: string;
  position: string;
  voxels: number;
}

interface FillResponse {
  filled: FilledShape[];
  voxels: number;
  undoable: boolean;
}

interface StatsResponse {
  cells: number;
  waterColor: string;
  waterWaveSize: number;
  limitStuds: number;
}

export function registerTerrainTools(context: ToolContext): void {
  const { bridge } = context;

  defineTool(
    context,
    {
      name: "terrain",
      title: "Build and edit terrain",
      description:
        "Fills, repaints and clears Roblox terrain — hills, water, caves, roads.\n\n" +
        "Terrain is not made of instances, so none of the instance tools reach " +
        "it: there is nothing to `create`, no path for `find`, and no property " +
        "for `modify`. This is the only way to shape it short of writing " +
        "FillBall calls by hand through `execute_luau`.\n\n" +
        "`fill` takes an ARRAY of solids and applies them as one undo step, " +
        "which is how terrain is actually built: a hill is several overlapping " +
        "balls, a road is a row of blocks. Shapes are `block` (needs `size`), " +
        "`ball` (needs `radius`), `cylinder` (needs `radius` and `height`) and " +
        "`wedge` (needs `size`).\n\n" +
        "To CARVE, fill with material `Air`. That is not a special mode — a " +
        "cave is a ball of Air inside a hill, and a tunnel is a row of them.\n\n" +
        "`replace` swaps one material for another inside a region and leaves " +
        "the shape alone, which is how you turn a grass hill to snow without " +
        "rebuilding it. `clear` empties a region, or everything with " +
        "confirm=true. `stats` says whether the place uses terrain at all " +
        "-- call it first in an unfamiliar place. It cannot say WHERE the " +
        "terrain is: Roblox exposes no bounding box for it, only the fixed " +
        "limit. Take a `screenshot` to see the shape.\n\n" +
        "Positions are the centre of the solid, in studs, as \"x, y, z\". " +
        "Terrain snaps to a 4-stud voxel grid, so small features come out " +
        "blockier than the numbers suggest; nothing thinner than about 4 studs " +
        "survives.",
      inputSchema: {
        op: z
          .enum(["fill", "replace", "clear", "stats"])
          .default("stats")
          .describe(
            "'fill' adds solids (use material Air to carve), 'replace' swaps a " +
              "material in place, 'clear' empties a region or everything, " +
              "'stats' reports what is there.",
          ),
        shapes: z
          .array(
            z.object({
              shape: z
                .enum(["block", "ball", "cylinder", "wedge"])
                .default("block")
                .describe("Which solid to fill."),
              position: z
                .string()
                .describe('Centre of the solid in studs, e.g. "0, 20, 0".'),
              size: z
                .string()
                .optional()
                .describe('block and wedge: extent in studs, e.g. "100, 20, 100".'),
              radius: z.number().optional().describe("ball and cylinder: radius in studs."),
              height: z.number().optional().describe("cylinder: height in studs."),
              orientation: z
                .string()
                .optional()
                .describe('Rotation in degrees, e.g. "0, 45, 0". Omit for none.'),
              material: z
                .string()
                .default("Grass")
                .describe(
                  'Terrain material — Grass, Rock, Sand, Water, Snow, Basalt, ' +
                    'Mud, LeafyGrass... Use "Air" to carve out existing terrain.',
                ),
            }),
          )
          .max(100)
          .optional()
          .describe("fill only: the solids to apply, together, as one undo step."),
        position: z
          .string()
          .optional()
          .describe('replace and clear: centre of the region, e.g. "0, 0, 0".'),
        size: z
          .string()
          .optional()
          .describe('replace and clear: extent of the region in studs, e.g. "512, 256, 512".'),
        from: z.string().optional().describe("replace only: the material to look for."),
        to: z.string().optional().describe("replace only: the material to write instead."),
        confirm: z
          .boolean()
          .optional()
          .describe(
            "clear only: required to empty ALL terrain. Omit it and give " +
              "`position`/`size` to clear one region instead.",
          ),
        studioId: z.string().optional().describe("Target Studio; omit for the active one."),
      },
      readOnly: false,
      destructive: true,
    },
    async (args): Promise<ToolResult> => {
      // Terrain writes are slow in a way instance writes are not: the engine
      // rebuilds the voxel mesh for the whole affected volume before it
      // answers, and a large region takes real seconds.
      const timeoutMs = 60_000;

      if (args.op === "stats") {
        const response = await bridge.call<StatsResponse>(
          "terrain.stats",
          {},
          { studioId: args.studioId, timeoutMs },
        );
        return json(
          response,
          response.cells === 0
            ? "This place has no terrain yet. `fill` a block of Grass to start one."
            : undefined,
        );
      }

      if (args.op === "fill") {
        if (args.shapes === undefined || args.shapes.length === 0) {
          return text('fill needs `shapes`, e.g. [{ shape: "ball", position: "0, 10, 0", radius: 24, material: "Grass" }].');
        }
        const response = await bridge.call<FillResponse>(
          "terrain.fill",
          { shapes: args.shapes },
          { studioId: args.studioId, timeoutMs },
        );
        return json(
          response,
          "Terrain snaps to 4-stud voxels, so take a `screenshot` before " +
            "building on top of this — the result is blockier than the numbers.",
        );
      }

      if (args.op === "replace") {
        if (args.from === undefined || args.to === undefined) {
          return text('replace needs `from` and `to`, e.g. from="Grass" to="Snow".');
        }
        const response = await bridge.call<Record<string, unknown>>(
          "terrain.replace",
          { position: args.position, size: args.size, from: args.from, to: args.to },
          { studioId: args.studioId, timeoutMs },
        );
        return json(response);
      }

      const response = await bridge.call<Record<string, unknown>>(
        "terrain.clear",
        { position: args.position, size: args.size, confirm: args.confirm },
        { studioId: args.studioId, timeoutMs },
      );
      return json(response);
    },
  );
}
