import { z } from "zod";
import { json, table, text, type ToolResult } from "../lib/format.js";
import { defineTool, type ToolContext } from "../lib/tool.js";

interface ExecResponse {
  ok: boolean;
  error?: string;
  returned?: unknown[];
  output: Array<{ level: string; message: string }>;
  milliseconds: number;
  /** Present only when how the code ran limited what it could do. */
  note?: string;
}

interface RaycastResponse {
  hit: boolean;
  path?: string;
  className?: string;
  position?: string;
  normal?: string;
  distance?: number;
  material?: string;
  origin?: string;
  direction?: string;
}

interface SelectResponse {
  items: Array<{ path: string; className: string }>;
  count: number;
}

export function registerExecTools(context: ToolContext): void {
  const { bridge } = context;

  defineTool(
    context,
    {
      name: "execute_luau",
      title: "Run Luau in Studio",
      description:
        "Runs Luau in Studio's plugin context and returns whatever it printed, " +
        "returned, or threw.\n\n" +
        "This is the escape hatch. Reach for it only when no dedicated tool " +
        "fits — `create`, `modify`, `delete`, `move`, `script_edit` and `find` " +
        "validate their input, type values from the live API dump, and wrap " +
        "writes in an undo recording. Code run here does none of that, so a typo " +
        "becomes a runtime error instead of a suggestion, and changes it makes " +
        "may not be undoable as one step.\n\n" +
        "Good uses: reading something no tool exposes, a one-off calculation " +
        "over many instances, or calling an engine API the tools do not cover.\n\n" +
        "Output printed while it runs is captured and returned, so `print` is a " +
        "reasonable way to get values out. `return` works too, including " +
        "returning a table — it comes back as a structure, not a summary. There " +
        "is no timeout: an infinite loop will hang Studio until it is " +
        "force-quit.\n\n" +
        "Against a running playtest server, Studio disables `loadstring`, so the " +
        "code is compiled through a ModuleScript instead and runs at script " +
        "identity — plugin-only APIs are unavailable there. When that happens it " +
        "is stated in the result rather than left to be inferred from a failure.",
      inputSchema: {
        source: z
          .string()
          .min(1)
          .describe(
            "Luau to run. In an editor session this has plugin permissions, so " +
              "`game`, `workspace` and plugin-only APIs are all reachable.",
          ),
        studioId: z.string().optional().describe("Target Studio; omit for the active one."),
      },
      destructive: true,
    },
    async (args): Promise<ToolResult> => {
      const response = await bridge.call<ExecResponse>(
        "exec.run",
        { source: args.source },
        { studioId: args.studioId, timeoutMs: 60_000 },
      );

      const parts: string[] = [];
      if (response.output.length > 0) {
        parts.push(
          "Output:\n" +
            response.output.map((line) => `  [${line.level}] ${line.message}`).join("\n"),
        );
      }
      if (response.ok) {
        if (response.returned && response.returned.length > 0) {
          // Indented, because returned values are now whole structures rather
          // than one-line summaries and a single-line dump of a nested table is
          // no more readable than the "<table with 5 entries>" it replaced.
          const single = response.returned.length === 1 ? response.returned[0] : response.returned;
          parts.push(`Returned:\n${JSON.stringify(single, null, 2)}`);
        }
        if (parts.length === 0) {
          parts.push("Ran successfully. Nothing was printed or returned.");
        }
      } else {
        // A thrown error is reported as content rather than a tool failure: the
        // output captured before the throw is usually what explains it.
        parts.push(`Error: ${response.error ?? "unknown"}`);
      }

      if (response.note) parts.push(`Note: ${response.note}`);
      parts.push(`(${response.milliseconds}ms)`);
      return text(parts.join("\n\n"));
    },
  );

  defineTool(
    context,
    {
      name: "viewport",
      title: "Viewport and selection",
      description:
        "Works with the 3D view and the Studio selection.\n\n" +
        "`select` sets, extends or shrinks what is highlighted in Studio. Select " +
        "what you just built or changed — it shows the user the result, and puts " +
        "the instance under Studio's own move and scale handles. `studio_status` " +
        "reports the current selection; this sets it.\n\n" +
        "`focus` aims the Studio camera at an instance and frames it so the " +
        "whole thing is on screen. This is what makes `screenshot` worth having: " +
        "a picture of wherever the camera happened to be answers nothing, while " +
        "a picture of the thing you just built answers 'does it look right', " +
        "which no amount of reading properties can. Build, focus, screenshot.\n\n" +
        "The distance is computed from the subject's size and the camera's field " +
        "of view, so a doorway and a whole map both arrive filling a similar " +
        "share of the frame. `from` changes the angle you view it from, and " +
        "`padding` how tightly it is framed.\n\n" +
        "`camera` sets or reads the camera directly, for shots framing cannot " +
        "express — standing inside a room, or looking along a corridor.\n\n" +
        "`raycast` fires a ray through the world and reports the first thing it " +
        "hits, with position, surface normal, distance and material. This answers " +
        "'what occupies this space', which the data model alone cannot: use it to " +
        "find the ground under a spawn point, or check whether a gap is clear " +
        "before placing something.",
      inputSchema: {
        op: z
          .enum(["select", "raycast", "focus", "camera"])
          .describe(
            "'focus' points the camera at something and frames it, 'camera' sets " +
              "it explicitly, 'select' changes the Studio selection, 'raycast' " +
              "queries the world.",
          ),
        path: z
          .string()
          .optional()
          .describe("focus only: the instance to look at. A model, part, or folder containing them."),
        at: z
          .string()
          .optional()
          .describe('focus only: look at this point instead of an instance, e.g. "0, 10, 0".'),
        from: z
          .string()
          .optional()
          .describe(
            'focus only: direction to view from, e.g. "0, 1, 0" for directly above ' +
              'or "1, 0, 0" from the side. Defaults to a raised three-quarter view.',
          ),
        padding: z
          .number()
          .min(1)
          .max(5)
          .default(1.5)
          .describe("focus only: how much room to leave around the subject. 1 is tight."),
        position: z.string().optional().describe('camera only: where to put the camera, e.g. "0, 20, 30".'),
        lookAt: z.string().optional().describe("camera only: the point to aim at."),
        fieldOfView: z
          .number()
          .min(1)
          .max(120)
          .optional()
          .describe("camera only: field of view in degrees. Lower is more zoomed in."),
        paths: z
          .array(z.string())
          .optional()
          .describe("select only: instances to select. An empty array clears the selection."),
        mode: z
          .enum(["set", "add", "remove"])
          .default("set")
          .describe("select only: replace the selection, extend it, or remove from it."),
        origin: z
          .string()
          .optional()
          .describe('raycast only: where the ray starts, e.g. "0, 50, 0".'),
        direction: z
          .string()
          .optional()
          .describe('raycast only: which way it points, e.g. "0, -1, 0" for straight down.'),
        maxDistance: z
          .number()
          .positive()
          .default(1000)
          .describe("raycast only: how far to look, in studs."),
        ignore: z
          .array(z.string())
          .optional()
          .describe("raycast only: instances the ray passes through."),
        studioId: z.string().optional().describe("Target Studio; omit for the active one."),
      },
      destructive: false,
      idempotent: true,
    },
    async (args): Promise<ToolResult> => {
      if (args.op === "focus") {
        if (!args.path && !args.at) {
          return text("focus needs a `path` to look at, or an `at` position.");
        }
        const response = await bridge.call<Record<string, unknown>>(
          "viewport.focus",
          { path: args.path, at: args.at, from: args.from, padding: args.padding },
          { studioId: args.studioId },
        );
        return json(response, "Take a `screenshot` to see it.");
      }

      if (args.op === "camera") {
        const response = await bridge.call<Record<string, unknown>>(
          "viewport.camera",
          { position: args.position, lookAt: args.lookAt, fieldOfView: args.fieldOfView },
          { studioId: args.studioId },
        );
        return json(response);
      }

      if (args.op === "raycast") {
        if (!args.origin || !args.direction) {
          return text(
            "raycast needs `origin` and `direction`.\n" +
              'For example origin "0, 100, 0" and direction "0, -1, 0" to find the ' +
              "ground below a point.",
          );
        }
        const response = await bridge.call<RaycastResponse>(
          "viewport.raycast",
          {
            origin: args.origin,
            direction: args.direction,
            maxDistance: args.maxDistance,
            ignore: args.ignore,
          },
          { studioId: args.studioId },
        );
        if (!response.hit) {
          return text(
            `Nothing within ${args.maxDistance} studs along that ray.\n` +
              "Check the direction points the way you expect, or raise `maxDistance`.",
          );
        }
        return json(response);
      }

      const response = await bridge.call<SelectResponse>(
        "viewport.select",
        { paths: args.paths ?? [], mode: args.mode },
        { studioId: args.studioId },
      );
      if (response.count === 0) return text("Selection cleared.");
      return table(["path", "className"], response.items, {
        total: response.count,
        more: `${response.count} selected in Studio`,
      });
    },
  );
}
