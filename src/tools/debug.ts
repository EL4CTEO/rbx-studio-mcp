import { z } from "zod";
import { json, text, type ToolResult } from "../lib/format.js";
import { defineTool, type ToolContext } from "../lib/tool.js";

interface SetResponse {
  added: Array<{ path: string; line: number; pauses: boolean; result?: unknown }>;
  failed: Array<{ path: string; line: number; error: string }>;
  installed: boolean;
}

interface SnapshotResponse {
  items: Array<Record<string, unknown>>;
  total: number;
  overflow?: number;
  installed: boolean;
}

export function registerDebugTools(context: ToolContext): void {
  const { bridge } = context;

  defineTool(
    context,
    {
      name: "debug",
      title: "Breakpoints and runtime inspection",
      description:
        "Sets breakpoints that record the stack and variables when they are hit, " +
        "then reads back what they caught.\n\n" +
        "These are tracepoints, not a step debugger. A breakpoint fires, captures " +
        "the call stack and the variables in scope, and lets execution continue; " +
        "`op: \"snapshots\"` returns what was captured. Studio's debugger has to " +
        "decide whether to resume the instant it stops, and cannot wait for a " +
        "tool call to come back with an answer, so stepping through code line by " +
        "line is not possible this way — but 'what was this value when it got " +
        "here' is, which is usually the actual question.\n\n" +
        "`condition` is a Luau expression evaluated where the breakpoint sits, so " +
        "a breakpoint can fire only on the case that matters — `health < 0`, " +
        "`player.Name == \"someone\"`.\n\n" +
        "`logMessage` is ALSO a Luau expression, not a template string: its value " +
        'is printed when the breakpoint is hit, so write `"index=" .. index` ' +
        "rather than `index={index}`. Prose is a syntax error and the breakpoint " +
        "is skipped. It pauses nothing, which makes it the cheapest way to watch " +
        "a value change in a running game — read the lines back with `console`.\n\n" +
        "Only one breakpoint exists per line, so a log and a pause on the same " +
        "line will not both apply.\n\n" +
        "Put the breakpoint on a line that does something. A `return`, an `end` " +
        "or a bare declaration can verify and then never fire — measured, not " +
        "guessed: the same breakpoint moved from `return squared, tag` to the " +
        "assignment above it went from silent to firing on every pass. If one " +
        "verifies but catches nothing, suspect the line before suspecting the " +
        "condition.\n\n" +
        "Breakpoints belong to the session that holds them. Set them in the " +
        "editor session BEFORE starting a playtest, since code that already ran " +
        "cannot be caught retroactively.\n\n" +
        "`pause: true` genuinely halts the running thread, and Studio offers " +
        "plugins no way to resume it — the user has to press Resume or Stop " +
        "themselves. Leave it off unless someone has asked for it.",
      inputSchema: {
        op: z
          .enum(["set", "clear", "snapshots", "exceptions"])
          .describe(
            "'set' adds breakpoints, 'clear' removes one or all, 'snapshots' " +
              "reads what has been captured, 'exceptions' controls breaking on errors.",
          ),
        breakpoints: z
          .array(
            z.object({
              path: z.string().describe('Script path, e.g. "ServerScriptService.Combat".'),
              line: z.number().int().min(1).describe("Line to break on."),
              condition: z
                .string()
                .optional()
                .describe(
                  "Luau expression; the breakpoint only fires when it is true, " +
                    'evaluated in scope at that line, e.g. "count > 100".',
                ),
              logMessage: z
                .string()
                .optional()
                .describe("Write this to the output when hit, instead of capturing a snapshot."),
              pause: z
                .boolean()
                .optional()
                .describe(
                  "Actually halt the thread. Nothing here can resume it — the " +
                    "user must do that in Studio. Off by default.",
                ),
            }),
          )
          .max(50)
          .optional()
          .describe("set only: breakpoints to add."),
        path: z
          .string()
          .optional()
          .describe("clear only: remove breakpoints from this script. Omit to clear everything."),
        line: z.number().int().min(1).optional().describe("clear only: which line to remove."),
        mode: z
          .enum(["Never", "Always", "Unhandled"])
          .optional()
          .describe(
            "exceptions only: break on every error, only unhandled ones, or never. " +
              "Defaults to Unhandled.",
          ),
        limit: z
          .number()
          .int()
          .min(1)
          .max(40)
          .default(10)
          .describe("snapshots only: how many of the most recent to return."),
        clear: z
          .boolean()
          .default(false)
          .describe("snapshots only: discard what is returned, so the next read starts fresh."),
        studioId: z.string().optional().describe("Target Studio; omit for the active one."),
      },
      destructive: false,
    },
    async (args): Promise<ToolResult> => {
      if (args.op === "snapshots") {
        const response = await bridge.call<SnapshotResponse>(
          "debug.snapshots",
          { limit: args.limit, clear: args.clear },
          { studioId: args.studioId },
        );
        if (response.items.length === 0) {
          return text(
            "No breakpoints have been hit.\n" +
              "Breakpoints only catch code that runs after they are set, and they " +
              "belong to one session — if the code runs in a playtest, set them " +
              "before starting it and read them back from that playtest's studioId.",
          );
        }
        return json(response, response.overflow ? `${response.overflow} older snapshots were dropped.` : undefined);
      }

      if (args.op === "set") {
        if (!args.breakpoints || args.breakpoints.length === 0) {
          return text("set needs a `breakpoints` array.");
        }
        const response = await bridge.call<SetResponse>(
          "debug.set",
          { breakpoints: args.breakpoints },
          { studioId: args.studioId },
        );
        const notes: string[] = [];
        if (response.failed.length > 0) {
          notes.push(
            "Refused:\n" +
              response.failed.map((f) => `  ${f.path}:${f.line} — ${f.error}`).join("\n"),
          );
        }
        if (response.added.some((entry) => entry.pauses)) {
          notes.push(
            "One or more of these halt the thread when hit. Nothing here can " +
              "resume it; the user has to press Resume or Stop in Studio.",
          );
        }
        return json(response.added, notes.length > 0 ? notes.join("\n\n") : undefined);
      }

      if (args.op === "exceptions") {
        const response = await bridge.call<{ mode: string }>(
          "debug.exceptions",
          { mode: args.mode ?? "Unhandled" },
          { studioId: args.studioId },
        );
        return text(`Breaking on exceptions: ${response.mode}.`);
      }

      const response = await bridge.call<Record<string, unknown>>(
        "debug.clear",
        { path: args.path, line: args.line },
        { studioId: args.studioId },
      );
      return json(response);
    },
  );
}
