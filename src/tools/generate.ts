import { z } from "zod";
import { text, type ToolResult } from "../lib/format.js";
import { defineTool, type ToolContext } from "../lib/tool.js";

interface GenerateResponse {
  path: string;
  parts: string[];
  size: string;
  schema: string;
  anchored: boolean;
  undoable: boolean;
  prompt?: string;
  uuid?: string;
}

/**
 * Generation is slow in a way no other tool here is. Tens of seconds is
 * ordinary and a complex prompt runs longer, so the deadline is set past what
 * the service itself will tolerate — a timeout here should mean the service
 * gave up, not that we did.
 */
const GENERATE_TIMEOUT_MS = 240_000;

export function registerGenerateTools(context: ToolContext): void {
  const { bridge } = context;

  defineTool(
    context,
    {
      name: "generate",
      title: "Generate 3D models",
      description:
        "Makes 3D geometry from a text prompt, using Roblox's Cube model.\n\n" +
        "THE SCHEMA IS THE IMPORTANT ARGUMENT. It decides how the result is " +
        "broken up, and it cannot be changed afterwards without another " +
        "generation:\n" +
        "- `Body1` — one MeshPart. Right for props: a crate, a tree, a lamp.\n" +
        "- `Car5` — a body and four wheels, under the fixed names `body`, " +
        "`front left wheel`, `front right wheel`, `rear left wheel`, `rear " +
        "right wheel`. Right for anything that has to drive, because a script " +
        "can find the wheels by name.\n" +
        "- `groups` — your own list of part names, for a structure the two " +
        "predefined schemas do not cover.\n\n" +
        "Asking for a car under `Body1` gives you a car-shaped rock. It looks " +
        "right and nothing can be articulated. If you only realise afterwards, " +
        "`geometry op=\"segment\"` cuts an existing mesh into named parts " +
        "without generating it again.\n\n" +
        "Expect tens of seconds per call. The service is metered and moderated: " +
        "a rejected prompt and a rate limit both come back as a failure that " +
        "says which, so read the hint before retrying.\n\n" +
        "`imageAssetId` conditions the generation on a picture — supply it with " +
        "a prompt or instead of one. `size` suggests proportions and " +
        "`maxTriangles` caps the poly count (low values give a faceted, " +
        "low-poly look). Results are anchored on arrival, because a multi-part " +
        "model dropped into the workspace unanchored falls apart.\n\n" +
        "EDIT MODE ONLY, for now. A generated mesh does not survive into a " +
        "playtest: inside one, its MeshContent and TextureContent read as empty. " +
        "`assets op=\"bake\"` does not fix this — the engine refuses to bake the " +
        "kind of content generation produces. So generate for building and " +
        "greyboxing, and do not rely on a generated mesh being visible in a " +
        "test or after a reopen until it has been published as a real asset.",
      inputSchema: {
        prompt: z
          .string()
          .optional()
          .describe('What to generate, e.g. "a weathered stone well".'),
        schema: z
          .enum(["Body1", "Car5"])
          .default("Body1")
          .describe("How to split the result. Ignored when `groups` is given."),
        groups: z
          .array(z.string())
          .max(16)
          .optional()
          .describe('Custom part names to split into, e.g. ["body", "lid"]. Overrides `schema`.'),
        imageAssetId: z
          .number()
          .int()
          .positive()
          .optional()
          .describe("An image asset id to condition the generation on."),
        size: z
          .string()
          .optional()
          .describe('Suggested size as "x, y, z". Approximate — use `scaleTo` for exact.'),
        maxTriangles: z
          .number()
          .int()
          .min(100)
          .max(100_000)
          .optional()
          .describe("Cap the triangle count. Lower is more faceted. Default is about 10000."),
        textures: z.boolean().default(true).describe("Generate textures. Off gives bare geometry."),
        scaleTo: z
          .number()
          .positive()
          .optional()
          .describe("Scale the result so its longest side is this many studs."),
        name: z.string().optional().describe("Name for the model."),
        parent: z.string().optional().describe("Where to put it. Defaults to Workspace."),
        position: z.string().optional().describe('Where to place it, e.g. "0, 10, 0".'),
        anchor: z.boolean().default(true).describe("Anchor every part. Turn off only if physics should act on it."),
        studioId: z.string().optional().describe("Target Studio; omit for the active one."),
      },
      destructive: true,
    },
    async (args): Promise<ToolResult> => {
      const response = await bridge.call<GenerateResponse>(
        "generate.model",
        {
          prompt: args.prompt,
          schema: args.schema,
          groups: args.groups,
          imageAssetId: args.imageAssetId,
          size: args.size,
          maxTriangles: args.maxTriangles,
          textures: args.textures,
          scaleTo: args.scaleTo,
          name: args.name,
          parent: args.parent,
          position: args.position,
          anchor: args.anchor,
        },
        { studioId: args.studioId, timeoutMs: GENERATE_TIMEOUT_MS },
      );

      const lines = [
        `${response.path}  (${response.schema}, ${response.size} studs)`,
        response.parts.length > 0 ? `Parts: ${response.parts.join(", ")}` : "Parts: none",
      ];
      if (!response.anchored) {
        lines.push("Left unanchored, so physics will move it.");
      }
      if (!response.undoable) {
        lines.push("Studio would not open an undo recording, so this is not one Ctrl+Z.");
      }
      if (response.uuid) {
        lines.push(`Generation ${response.uuid}.`);
      }
      return text(lines.join("\n"));
    },
  );
}
