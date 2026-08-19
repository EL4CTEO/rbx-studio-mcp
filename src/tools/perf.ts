import { z } from "zod";
import { json, limitSchema, table, text, type ToolResult } from "../lib/format.js";
import { defineTool, type ToolContext } from "../lib/tool.js";

interface ConsoleResponse {
  items: Array<{ level: string; message: string; timestamp?: number }>;
  total: number;
  dropped: number;
  /** Lines lost to the buffer's capacity, not to this call's limit. */
  evicted?: number;
}

interface SnapshotResponse {
  /** True when this session has no renderer, so drawing counters are all zero. */
  renderless?: boolean;
  frame: Record<string, number | undefined>;
  scene: Record<string, number | undefined>;
  network: Record<string, number | undefined>;
  memory: {
    totalMb?: number;
    trackingEnabled?: boolean;
    problem?: string;
    categories: Array<{ category: string; megabytes: number }>;
  };
}

interface CoverageResponse {
  enabled: string[];
  scripts: Array<{
    path: string;
    instrumentedLines: number;
    coveredLines: number;
    percent: number;
  }>;
  raw?: unknown;
}

/**
 * Roblox's profiler payload. Undocumented, so this is the shape observed from a
 * real capture: `Nodes` is a call tree and `Functions` the flat per-function
 * totals, which is the view the Script Performance window actually shows.
 */
interface ProfileResponse {
  seconds: number;
  frequency: number;
  data?: {
    Version?: number;
    Functions?: Array<{
      TotalDuration?: number;
      Name?: string;
      Source?: string;
      Line?: number;
      IsPlugin?: boolean;
    }>;
  };
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
        "subsystem's logging. Up to 2000 lines are held, so prefer a filter over " +
        "a large `limit`.\n\n" +
        "Each connected session keeps its own log, recorded from the moment its " +
        "plugin loaded — the editor session and a running playtest server do not " +
        "share one. To read what a playtest printed, target the playtest's " +
        "studioId (see `list_studios`); the editor's log will not have it. " +
        "Nothing printed before the plugin loaded is recoverable, and output from " +
        "the playtest *client* is not reachable at all, because Studio forbids " +
        "client sessions from making HTTP requests.",
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
      const notes: string[] = [];
      if (response.dropped > 0) {
        notes.push(
          `showing the newest ${response.items.length} of ${response.total} matching lines`,
        );
      }
      // A different loss from the one above, and the only one worth acting on:
      // these lines are gone from the session entirely, not merely unshown.
      if (response.evicted) {
        notes.push(
          `${response.evicted} older lines have fallen out of the buffer and cannot be recovered`,
        );
      }
      const trailer = notes.length > 0 ? `\n\n[${notes.join("; ")}]` : "";
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
        "`coverage` reports which lines of which scripts actually executed — dead " +
        "code, untested branches, whether a fix was even reached. Coverage must be " +
        "switched on before a script runs, so pass `enable` first, play, then read " +
        "back.\n\n" +
        "Frame and network figures are only meaningful while something is " +
        "running. Instance counts and memory are useful in edit mode too.",
      inputSchema: {
        op: z
          .enum(["snapshot", "profile", "coverage"])
          .default("snapshot")
          .describe(
            "'snapshot' reads counters now; 'profile' samples running scripts; " +
              "'coverage' reports which lines have executed.",
          ),
        enable: z
          .array(z.string())
          .optional()
          .describe(
            "coverage only: scripts to start measuring. Coverage must be switched " +
              "on before the code runs, so enable first, then play, then read back.",
          ),
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
        includePlugins: z
          .boolean()
          .default(false)
          .describe(
            "profile only: include Studio plugins in the results. Off by default " +
              "— an idle Studio is mostly plugin activity, which buries the " +
              "place's own scripts.",
          ),
        studioId: z.string().optional().describe("Target Studio; omit for the active one."),
      },
      readOnly: true,
    },
    async (args): Promise<ToolResult> => {
      if (args.op === "coverage") {
        const response = await bridge.call<CoverageResponse>(
          "perf.coverage",
          { enable: args.enable },
          { studioId: args.studioId },
        );

        if (response.raw !== undefined) {
          return json(
            response.raw,
            "Coverage came back in an unrecognised shape, so it is shown as Studio " +
              "returned it rather than summarised into numbers that might be wrong.",
          );
        }
        if (response.scripts.length === 0) {
          return text(
            (response.enabled.length > 0
              ? `Coverage enabled for ${response.enabled.length} script(s). `
              : "") +
              "No coverage recorded yet.\n" +
              "Coverage must be switched on before a script runs: enable it, start " +
              "a playtest, then read back.",
          );
        }
        return table(
          ["path", "coveredLines", "instrumentedLines", "percent"],
          response.scripts as unknown as Array<Record<string, unknown>>,
          { more: "percent is lines executed at least once" },
        );
      }

      if (args.op === "profile") {
        const response = await bridge.call<ProfileResponse>(
          "perf.profile",
          { seconds: args.seconds, frequency: args.frequency },
          // The plugin blocks for the sample, so the deadline must outlast it.
          { studioId: args.studioId, timeoutMs: (args.seconds + 20) * 1_000 },
        );
        const functions = response.data?.Functions ?? [];
        if (functions.length === 0) {
          return text(
            `Nothing ran during the ${response.seconds}s sample.\n` +
              "The profiler only sees code that executes. Start a playtest, or " +
              "profile while the behaviour you are investigating is happening.",
          );
        }

        const ranked = [...functions]
          .sort((a, b) => (b.TotalDuration ?? 0) - (a.TotalDuration ?? 0))
          .filter((entry) => (args.includePlugins ? true : entry.IsPlugin !== true))
          .slice(0, 25)
          .map((entry) => ({
            // A frame with no Source is a C function or a plugin's root entry.
            source: entry.Source ?? "(engine)",
            name: entry.Name ?? "",
            line: entry.Line || "",
            ms: Math.round((entry.TotalDuration ?? 0) * 1000 * 1000) / 1000,
            plugin: entry.IsPlugin === true ? "yes" : "",
          }));

        if (ranked.length === 0) {
          return text(
            `Every sample in ${response.seconds}s came from Studio plugins, not ` +
              "from this place's scripts.\n" +
              "No game code consumed measurable CPU. Pass `includePlugins` to see " +
              "the plugin activity anyway.",
          );
        }

        return table(["source", "name", "line", "ms", "plugin"], ranked, {
          more:
            `sampled ${response.seconds}s at ${response.frequency}Hz, ` +
            `slowest first, ms is total time in that function`,
        });
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
      } else {
        // An absent breakdown beside a healthy total reads as "this place uses
        // no memory", so say which of the two reasons it is.
        parts.push(
          snapshot.memory.trackingEnabled === false
            ? "\n[No memory breakdown: Stats.MemoryTrackingEnabled is off in this session.]"
            : `\n[No memory breakdown: ${
                snapshot.memory.problem ?? "Studio returned an empty one."
              }]`,
        );
      }

      // Zeroes that mean "not measured here" look exactly like zeroes that mean
      // "nothing to draw", and the flattering reading is the wrong one.
      if (snapshot.renderless) {
        parts.push(
          "\n[This is a playtest server, which does not render: frame time, draw " +
            "calls and triangle counts read zero because nothing measures them, " +
            "not because the place is cheap. Physics, instance counts, network " +
            "and memory above are real. For rendering figures, snapshot the " +
            "editor session instead.]",
        );
      }
      return text(parts.join("\n"));
    },
  );
}
