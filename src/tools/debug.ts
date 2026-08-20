import { z } from "zod";
import { json, text, type ToolResult } from "../lib/format.js";
import { defineTool, type ToolContext } from "../lib/tool.js";

interface SetResponse {
  added: Array<{ path: string; line: number; mode: "log" | "capture"; result?: unknown }>;
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
        "is skipped. The engine prints it without stopping the thread at all, " +
        "which makes it the cheapest way to watch a value change on a hot path " +
        "or inside a tight loop — read the lines back with `console`.\n\n" +
        "So the two kinds cost different things: a `logMessage` breakpoint never " +
        "stops and gives you one line you composed in advance, while one without " +
        "it stops briefly and gives you the whole frame — every local and its " +
        "type, without having to guess beforehand which value would matter. " +
        "Reach for the log when you know what to watch, the capture when you do " +
        "not.\n\n" +
        "Only one breakpoint exists per line, so the same line cannot both log " +
        "and capture.\n\n" +
        "Put the breakpoint on a line that does something. A `return`, an `end` " +
        "or a bare declaration can verify and then never fire — measured, not " +
        "guessed: the same breakpoint moved from `return squared, tag` to the " +
        "assignment above it went from silent to firing on every pass. If one " +
        "verifies but catches nothing, suspect the line before suspecting the " +
        "condition.\n\n" +
        "Breakpoints belong to the session that holds them. Set them in the " +
        "editor session BEFORE starting a playtest, since code that already ran " +
        "cannot be caught retroactively.\n\n" +
        "Nothing here leaves a thread stopped waiting for you. A capture " +
        "breakpoint stops for as long as it takes to read the frame and then " +
        "resumes itself, so a script with one mid-loop still runs to its last " +
        "line, and the user is never left with a frozen Studio to rescue.",
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
