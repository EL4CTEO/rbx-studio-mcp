import { z } from "zod";
import { json, text, type ToolResult } from "../lib/format.js";
import {
  resolveDir,
  runBuild,
  runExport,
  runSync,
  startWatch,
  stopWatch,
  summarise,
  watchState,
  type SyncReport,
} from "../lib/sync.js";
import { defineTool, type ToolContext } from "../lib/tool.js";

/** Per-file lines past this are counted, not listed. */
const LINE_LIMIT = 60;

function render(report: SyncReport, heading: string): string {
  const out: string[] = [`${heading}: ${summarise(report)}  (${report.place} <-> ${report.dir})`];
  if (report.undoStep) out.push(`Studio changes are one undo step, "${report.undoStep}".`);
  const lines = report.lines.slice(0, LINE_LIMIT);
  if (lines.length > 0) out.push("", ...lines);
  if (report.lines.length > LINE_LIMIT) out.push(`… and ${report.lines.length - LINE_LIMIT} more`);
  if (report.conflicts.length > 0) {
    out.push("", "Conflicts (nothing was written for these):");
    for (const conflict of report.conflicts.slice(0, LINE_LIMIT)) out.push(`  ${conflict.file}: ${conflict.reason}`);
    out.push(
      'Settle them by editing one side to match the other, or rerun with prefer: "studio" or "disk" to let one side win.',
    );
  }
  if (report.held.length > 0) {
    out.push("", `Held back by the direction (${report.held.length}):`, ...report.held.slice(0, 20).map((line) => `  ${line}`));
  }
  if (report.failures.length > 0) {
    out.push("", "Failed:", ...report.failures.slice(0, LINE_LIMIT).map((failure) => `  ${failure.file}: ${failure.reason}`));
  }
  if (report.builds.length > 0) {
    out.push("", report.dryRun ? "Build files that would rebuild:" : "Rebuilt from build files:", ...report.builds.map((file) => `  ${file}`));
  }
  if (report.fileSynced.length > 0) {
    out.push("", `${report.fileSynced.length} script(s) left alone: Studio's own Script Sync already binds them to files.`);
  }
  return out.join("\n");
}

export function registerSyncTools(context: ToolContext): void {
  const { bridge } = context;

  defineTool(
    context,
    {
      name: "sync",
      title: "Sync scripts with files on disk",
      description:
        "Mirrors the place's scripts into a folder on disk, so you can work on code with your own " +
        "file tools -- read a window, search, edit in place, diff -- and then send it back to Studio " +
        "in one call. Studio stays where the game runs: use playtest, screenshot, console and input " +
        "to check the result.\n\n" +
        "Layout mirrors the instance tree, Rojo-style: `ServerScriptService/Main.server.luau` is a " +
        "Script, `.client.luau` a LocalScript, `.luau` a ModuleScript, and a script with scripts " +
        "inside is a folder holding `init.server.luau` (or `init.client.luau`, `init.luau`). New " +
        "files become new scripts, and a file moved or renamed moves the script itself, keeping its " +
        "identity.\n\n" +
        "Ops: `status` shows what would change without changing anything. `sync` goes both ways, " +
        "`pull` only Studio -> disk, `push` only disk -> Studio. `watch` keeps them in step until " +
        "`stop`: edit files and Studio follows within a second, and edits in Studio land on disk.\n\n" +
        "Nothing is overwritten blind. The last sync is remembered per file, so a file changed on " +
        "both sides is a conflict, reported and left alone -- settle it, or pass `prefer`. Deleting " +
        "a file deletes the script (one Ctrl+Z in Studio); a script deleted in Studio moves its file " +
        "to `.rbx-sync/trash`. Nothing is deleted on a first sync.\n\n" +
        "UI and other instance trees: `export` writes one as a build file (e.g. " +
        "`StarterGui/Shop.build.json`, the same fields `create` takes, only non-default " +
        "properties). Edit it, then `build` -- or any sync -- rebuilds the tree in one undo step, " +
        "keeping the scripts inside it. Build files are two-way too: a tree edited in Studio is written " +
        "back to its file, and edits on both sides are a conflict rather than one silently undoing the other.\n\n" +
        "Conflicts leave Studio's version in `.rbx-sync/conflicts/`. Merge into the file (or fix Studio) " +
        "and sync again: whichever side changed since the conflict wins. While `watch` runs, new conflicts " +
        "and errors are appended to your next tool reply.",
      inputSchema: {
        op: z
          .enum(["status", "sync", "pull", "push", "watch", "stop", "export", "build"])
          .describe(
            "'status': dry run. 'sync': both ways. 'pull': Studio -> disk. 'push': disk -> Studio. " +
              "'watch'/'stop': continuous two-way sync. 'export': instance trees -> build files. " +
              "'build': build files -> instance trees.",
          ),
        dir: z
          .string()
          .optional()
          .describe('Sync folder, relative to the working directory. Default "studio".'),
        roots: z
          .array(z.string())
          .optional()
          .describe(
            'Studio paths to sync, e.g. ["ServerScriptService", "ReplicatedStorage.Shared"]. Default: every ' +
              "service scripts are authored in. Remembered for the folder once given.",
          ),
        prefer: z
          .enum(["studio", "disk"])
          .optional()
          .describe("Settle conflicts in favour of one side instead of reporting them."),
        paths: z
          .array(z.string())
          .optional()
          .describe('export: instances to write as build files, e.g. ["StarterGui.Shop"].'),
        files: z
          .array(z.string())
          .optional()
          .describe('build: build files to apply, relative to the folder. Default: those changed since last built.'),
        confirmDeletes: z
          .boolean()
          .optional()
          .describe("Allow a run that deletes most of what the folder tracks. Check `status` first."),
        rebind: z
          .boolean()
          .optional()
          .describe("Let a folder synced with one place follow a different place. Almost never what you want."),
        studioId: z.string().optional().describe("Target Studio; omit for the active one."),
      },
    },
    async (args): Promise<ToolResult> => {
      const dir = resolveDir(args.dir);
      const base = {
        dir,
        roots: args.roots,
        studioId: args.studioId,
        prefer: args.prefer,
        confirmDeletes: args.confirmDeletes,
        rebind: args.rebind,
      };

      switch (args.op) {
        case "status": {
          const report = await runSync(bridge, { ...base, direction: "both", dryRun: true });
          const watching = watchState(dir);
          const lines = [render(report, "Would sync")];
          if (watching) {
            lines.push(
              "",
              `Watching since ${new Date(watching.since).toISOString()}: ${watching.cycles} sync(s), ${watching.echoes} echo(es) skipped` +
                (watching.lastCycle ? `; last change: ${watching.lastCycle.summary} (${watching.lastCycle.ms}ms)` : "") +
                (watching.lastError ? `; last error: ${watching.lastError.message}` : ""),
            );
          }
          return text(lines.join("\n"));
        }
        case "sync":
        case "pull":
        case "push": {
          const direction = args.op === "sync" ? "both" : args.op;
          const report = await runSync(bridge, { ...base, direction });
          return text(render(report, args.op === "sync" ? "Synced" : args.op === "pull" ? "Pulled" : "Pushed"));
        }
        case "watch": {
          const { state, first, already } = await startWatch(bridge, { ...base, direction: "both" });
          if (already) return text(`Already watching ${state.dir}. op="status" shows how it is going.`);
          return text(
            [
              first.lines.length > 0 || first.conflicts.length > 0 ? render(first, "First sync") : "Already in step.",
              "",
              `Watching ${state.dir}: file edits reach Studio within a second, Studio edits reach the files. ` +
                'Conflicts are left alone and listed by op="status". Stop with op="stop".',
            ].join("\n"),
          );
        }
        case "stop": {
          const state = stopWatch(dir);
          return text(
            state
              ? `Stopped watching ${dir} after ${state.cycles} run(s).`
              : `Nothing was watching ${dir}.`,
          );
        }
        case "export": {
          if (!args.paths || args.paths.length === 0) {
            return text('export needs `paths`, e.g. ["StarterGui.Shop"].');
          }
          const written = await runExport(bridge, { ...base, direction: "both", paths: args.paths });
          return json(
            written.map((entry) => ({
              path: entry.path,
              file: entry.file,
              instances: entry.instances,
              // Scripts are synced as files, not written into the build file.
              scriptsLeftAsFiles: entry.scripts,
              ...(entry.skipped.length > 0 ? { propertiesNotExported: entry.skipped.slice(0, 30) } : {}),
            })),
            "Edit the file, then sync op=\"build\" (or any push) rebuilds the tree in one undo step.",
          );
        }
        case "build": {
          const report = await runBuild(bridge, { ...base, direction: "push", files: args.files });
          return text(render(report, "Built"));
        }
      }
    },
  );
}
