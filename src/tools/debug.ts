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

/**
 * Locals the debugger reports in every frame regardless of the code.
 *
 * `_G`, `shared` and `script` are in scope everywhere and `...` is the empty
 * varargs tuple; none of them is ever the value someone set a breakpoint to see.
 * Left in, they were four of the six rows in each frame -- so on a loop with two
 * locals, two thirds of a capture was boilerplate repeated once per hit.
 */
const AMBIENT_LOCALS = new Set(["_G", "shared", "script", "..."]);

interface RawVariable {
  Name?: string;
  Value?: string;
  Type?: string;
  Scope?: string;
}

interface RawFrame {
  Id?: number;
  Line?: number;
  Name?: string;
  ScriptPath?: string;
}

/** Trims a debugger value string to something readable in a list. */
function briefly(value: string): string {
  const single = value.replace(/\s+/g, " ").trim();
  return single.length > 160 ? `${single.slice(0, 159)}…` : single;
}

function frameLabel(frame: RawFrame | undefined): string {
  if (!frame) {
    return "(unknown)";
  }
  const where = `${frame.ScriptPath ?? "?"}:${frame.Line ?? "?"}`;
  return frame.Name ? `${where} in ${frame.Name}` : where;
}

/**
 * Renders captured frames as a readable outline rather than raw JSON.
 *
 * The raw payload is Roblox's, and it is shaped for a debugger UI: variables are
 * a numbered map rather than a list, the call stack is repeated both inside each
 * frame and again alongside it, and every variable carries a reference id the
 * caller has no way to follow. Passed straight through, nine hits of a two-line
 * loop came back as roughly eight thousand tokens. This keeps what a person
 * reading the capture is actually after -- where it stopped, and what the values
 * were -- and drops the rest.
 */
function renderSnapshots(items: Array<Record<string, unknown>>): string {
  const blocks: string[] = [];
  let droppedAmbient = false;

  items.forEach((item, index) => {
    const frames = (item.frames ?? []) as Array<{
      variables?: Record<string, RawVariable>;
      frame?: RawFrame;
    }>;
    const stack = item.stack as { TotalFrames?: number; Frames?: Record<string, RawFrame> } | undefined;
    const reason = (item.stopped as { Reason?: string } | undefined)?.Reason;

    const lines: string[] = [];
    const head = frameLabel(frames[0]?.frame);
    const depth = stack?.TotalFrames ?? frames.length;
    lines.push(
      `#${index + 1}  ${head}${depth > 1 ? `  (${depth} frames)` : ""}` +
        (reason && !reason.endsWith("Breakpoint") ? `  [${reason}]` : ""),
    );

    for (const entry of frames) {
      if (frames.length > 1) {
        lines.push(`  ${frameLabel(entry.frame)}`);
      }
      const variables = Object.values(entry.variables ?? {});
      const shown = variables.filter((variable) => {
        if (variable.Name !== undefined && AMBIENT_LOCALS.has(variable.Name)) {
          droppedAmbient = true;
          return false;
        }
        return true;
      });
      if (shown.length === 0) {
        lines.push("    (no locals in scope)");
        continue;
      }
      for (const variable of shown) {
        const type = variable.Type ? ` : ${variable.Type}` : "";
        lines.push(`    ${variable.Name ?? "?"} = ${briefly(variable.Value ?? "nil")}${type}`);
      }
    }

    // Frames below the top one, when the capture only carried the stack for them.
    if (stack?.Frames && frames.length <= 1 && (stack.TotalFrames ?? 0) > 1) {
      const rest = Object.values(stack.Frames).slice(1);
      for (const frame of rest) {
        lines.push(`  called from ${frameLabel(frame)}`);
      }
    }

    blocks.push(lines.join("\n"));
  });

  if (droppedAmbient) {
    blocks.push("(_G, shared, script and ... are omitted -- they are in scope everywhere.)");
  }
  return blocks.join("\n\n");
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
        'is printed when the breakpoint is hit, so write `"health=" .. health` ' +
        "rather than `health={health}`. Prose is a syntax error. Read the lines " +
        "back with `console`.\n\n" +
        "Two things about it are measured, not assumed, and both waste your time " +
        "otherwise. A breakpoint fires ONCE PER RUN, not once per pass: on a " +
        "five-iteration loop it printed a single line, for the first iteration " +
        "only. It is not a way to watch a value change inside a loop — to see " +
        "every pass, have the code itself print and read that with `console`. " +
        "And a log expression CANNOT SEE THE LOOP CONTROL VARIABLE: on " +
        "`for index = 1, 5 do`, a breakpoint in the body read the body's own " +
        "locals correctly and `index` as nil. Wrap values in `tostring` so a nil " +
        "prints as \"nil\" instead of throwing.\n\n" +
        "A log expression that throws is reported as \"Breakpoint ... ignored\" in " +
        "`console`, NOT here — `set` still returns Verified, because Studio only " +
        "compiles the expression once the line is reached.\n\n" +
        "So the two kinds cost different things: a `logMessage` breakpoint never " +
        "stops and gives you one line you composed in advance, while one without " +
        "it stops briefly and gives you the whole frame — every local and its " +
        "type, without having to guess beforehand which value would matter. Both " +
        "give you that for one pass only. Reach for the log when you know what " +
        "to watch, the capture when you do not.\n\n" +
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
        const shown = response.items.length;
        const footer = [
          `${shown} of ${response.total} captured`,
          response.overflow ? `${response.overflow} older snapshots were dropped` : undefined,
        ]
          .filter(Boolean)
          .join(", ");
        return text(`${renderSnapshots(response.items)}\n\n[${footer}]`);
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
