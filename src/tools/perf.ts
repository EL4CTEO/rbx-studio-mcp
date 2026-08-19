import { z } from "zod";
import { json, limitSchema, table, text, type ToolResult } from "../lib/format.js";
import { defineTool, type ToolContext } from "../lib/tool.js";

interface ConsoleResponse {
  items: Array<{ level: string; message: string; timestamp?: number }>;
  total: number;
  dropped: number;
}

interface SnapshotResponse {
  frame: Record<string, number | undefined>;
  scene: Record<string, number | undefined>;
  network: Record<string, number | undefined>;
  memory: { totalMb?: number; categories: Array<{ category: string; megabytes: number }> };
}

interface ProfileResponse {
  seconds: number;
  frequency: number;
  data?: unknown;
  raw?: string;
}

export function registerPerfTools(context: ToolContext): void {
  const { bridge } = context;

  defineTool(
    context,
    {
      name: "console",
      title: "Read Studio output",
      description:
        "Reads the Studio Output window — prints, warnings and runtime errors, " +
        "newest last.\n\n" +
        "This is how to find out what actually happened after a playtest or an " +
        "`execute_luau` call. An error here usually names the script and line, " +
        "which `script_read` can then open directly.\n\n" +
        "Filter with `level` to see only errors, or `pattern` to follow one " +
        "subsystem's logging. The log holds the whole session, so prefer a filter " +
        "over a large `limit`.",
      inputSchema: {
        level: z
          .enum(["print", "info", "warning", "error"])
          .optional()
          .describe("Only this severity. Omit for everything."),
        pattern: z
          .string()
          .optional()
          .describe(
            'Lua pattern the message must match, e.g. "Combat" or "^%[Server%]". ' +
              "Lua patterns escape with %, not backslash.",
          ),
        limit: limitSchema,
        studioId: z.string().optional().describe("Target Studio; omit for the active one."),
      },
      readOnly: true,
    },
    async (args): Promise<ToolResult> => {
      const response = await bridge.call<ConsoleResponse>(
        "perf.console",
        { level: args.level, pattern: args.pattern, limit: args.limit },
        { studioId: args.studioId },
      );

      if (response.items.length === 0) {
        return text(
          args.level || args.pattern
            ? "No output matched. Try dropping the filter, or run a playtest first."
            : "The output log is empty.",
        );
      }

      const lines = response.items.map((entry) => `[${entry.level}] ${entry.message}`);
      const trailer =
        response.dropped > 0
          ? `\n\n[showing the newest ${response.items.length} of ${response.total} matching lines]`
          : "";
      return text(lines.join("\n") + trailer);
    },
  );

  defineTool(
    context,
    {
      name: "performance",
      title: "Performance and memory",
      description:
        "Reads the engine's own counters, and can run the script profiler.\n\n" +
        "`snapshot` returns what the Developer Console shows: frame, physics and " +
        "render times in milliseconds, instance and part counts, draw calls, " +
        "network rates, and memory broken down by category. Use it to answer " +
        "'why is this place heavy' with numbers instead of guesses.\n\n" +
        "`profile` runs Studio's script profiler — the Script Performance window " +
        "— for `seconds` and reports which scripts consumed CPU. It blocks for " +
        "that long, so keep it short. It only sees code that actually runs, so " +
        "start a playtest first; profiling an idle edit session returns nothing.\n\n" +
        "Frame and network figures are only meaningful while something is " +
        "running. Instance counts and memory are useful in edit mode too.",
      inputSchema: {
        op: z
          .enum(["snapshot", "profile"])
          .default("snapshot")
          .describe("'snapshot' reads counters now; 'profile' samples running scripts."),
        seconds: z
          .number()
          .int()
          .min(1)
          .max(30)
          .default(5)
          .describe("profile only: how long to sample. The call blocks for this long."),
        frequency: z
          .number()
          .int()
          .min(100)
          .max(10000)
          .default(1000)
          .describe("profile only: samples per second. Higher is more precise and costlier."),
        studioId: z.string().optional().describe("Target Studio; omit for the active one."),
      },
      readOnly: true,
    },
    async (args): Promise<ToolResult> => {
      if (args.op === "profile") {
        const response = await bridge.call<ProfileResponse>(
          "perf.profile",
          { seconds: args.seconds, frequency: args.frequency },
          // The plugin blocks for the sample, so the deadline must outlast it.
          { studioId: args.studioId, timeoutMs: (args.seconds + 20) * 1_000 },
        );
        return json(
          response,
          `Sampled for ${response.seconds}s at ${response.frequency}Hz.`,
        );
      }

      const snapshot = await bridge.call<SnapshotResponse>(
        "perf.snapshot",
        {},
        { studioId: args.studioId },
      );

      // Memory is the one part that is a genuine list, and the part most often
      // scanned for an outlier, so it gets a table instead of nested JSON.
      const categories = snapshot.memory.categories.slice(0, 15);
      const parts = [
        json({
          frame: snapshot.frame,
          scene: snapshot.scene,
          network: snapshot.network,
          totalMemoryMb: snapshot.memory.totalMb,
        }).content[0]!.text,
      ];
      if (categories.length > 0) {
        parts.push(
          "\nMemory by category (MB):\n" +
            table(["category", "megabytes"], categories).content[0]!.text,
        );
      }
      return text(parts.join("\n"));
    },
  );
}
