/**
 * `sync`: scripts mirrored between Studio and a folder on disk.
 *
 * The point is working the way an agent works best. Files on disk can be read
 * a window at a time, searched with real tools, edited in place and diffed,
 * all without a round trip to Studio per step; Studio is still where the game
 * runs and where the result is checked. This module moves text between the two
 * safely. `syncplan.ts` decides what should move; this does the moving.
 *
 * Safety is the design constraint throughout:
 *
 *  - Every write into Studio is conditional on the revision the last sync saw,
 *    checked inside the editor's own write callback. A script the user touched
 *    since is never overwritten; it becomes a conflict.
 *  - Every write to disk is checked against the file's last hash the same way.
 *  - Nothing is deleted on the first sync, deletions on disk go to a trash
 *    folder rather than away, deletions in Studio are one Ctrl+Z, and a run
 *    that would delete most of what it manages stops and asks.
 *  - A folder remembers which place it belongs to, so pointing the wrong place
 *    at it is refused instead of "syncing" one game over another.
 */
import { createHash } from "node:crypto";
import { watch as watchFolder, type FSWatcher } from "node:fs";
import { mkdir, readFile, readdir, rename, rmdir, stat, unlink, writeFile } from "node:fs/promises";
import path from "node:path";
import type { StudioBridge } from "../bridge/api.js";
import { parseCreateTree, typeCreateSpec } from "../tools/instances.js";
import { buildableProperties } from "./apidump.js";
import { ToolError } from "./errors.js";
import { pushNotice } from "./notices.js";
import type { StudioSession } from "./protocol.js";
import {
  classFromFile,
  decodeName,
  emptyManifest,
  encodeName,
  layout,
  normalise,
  placementOf,
  plan,
  type Action,
  type Direction,
  type Layout,
  type Manifest,
  type ScanResult,
  type ScriptClass,
} from "./syncplan.js";

const STATE_DIR = ".rbx-sync";
const MANIFEST = "manifest.json";
const BUILD_SUFFIX = ".build.json";

/** Past this many deletions, and past half of what is tracked, a run stops and asks. */
const MASS_DELETE = 10;

/** Studio sources per `sync.read` / writes per `sync.apply`, by size. */
const BATCH_BYTES = 1_500_000;
const BATCH_PATHS = 200;

export interface SyncOptions {
  dir: string;
  roots?: string[];
  studioId?: string;
  direction: Direction;
  prefer?: "studio" | "disk";
  dryRun?: boolean;
  confirmDeletes?: boolean;
  rebind?: boolean;
  /** Keep the plugin panel quiet about the scans (watch cycles). */
  quiet?: boolean;
  /** Include build files. Default true; watch checks them on its own timer. */
  builds?: boolean;
}

export interface SyncReport {
  dir: string;
  place: string;
  dryRun: boolean;
  /** One line per file touched, e.g. "push  ServerScriptService/Main.server.luau". */
  lines: string[];
  counts: Record<string, number>;
  conflicts: Array<{ file: string; path?: string; reason: string }>;
  /** Changes the direction held back, e.g. Studio edits during `push`. */
  held: string[];
  failures: Array<{ file: string; reason: string }>;
  /** Scripts left alone because Studio's own Script Sync binds them. */
  fileSynced: string[];
  builds: string[];
  undoStep?: string;
  /** Conflicts first seen in this run, for reporting each only once. */
  newConflicts?: string[];
  /** Build-file conflicts to remember, by file, with Studio's side. */
  buildConflicts?: Record<string, { studio: string; disk: string; text: string }>;
}

export const hashOf = (text: string): string => createHash("sha256").update(normalise(text), "utf8").digest("hex");

const posix = (relative: string) => relative.split(path.sep).join("/");
const absolute = (dir: string, relative: string) => path.join(dir, ...relative.split("/"));

// Target ---------------------------------------------------------------------

/**
 * The Studio session a sync runs against: named, or the active one, or the
 * only one. Always an edit session -- a playtest's DataModel is thrown away on
 * Stop, so syncing into it would look like it worked and then vanish.
 */
export async function targetSession(bridge: StudioBridge, studioId?: string): Promise<StudioSession> {
  const { list, activeId } = await bridge.sessions();
  const session =
    studioId !== undefined
      ? list.find((entry) => entry.studioId === studioId)
      : activeId !== null
        ? list.find((entry) => entry.studioId === activeId)
        : list.filter((entry) => !entry.context?.startsWith("playtest")).length === 1
          ? list.find((entry) => !entry.context?.startsWith("playtest"))
          : undefined;
  if (session === undefined) {
    if (list.length === 0) throw new ToolError("NO_STUDIO", "No Studio is connected.", "Open Studio with the plugin enabled.");
    throw new ToolError(
      "AMBIGUOUS_STUDIO",
      "Several Studio windows are connected and none is chosen.",
      "Pass `studioId` (see list_studios) or call set_active_studio.",
    );
  }
  if (session.context?.startsWith("playtest")) {
    throw new ToolError(
      "WRONG_CONTEXT",
      "That is a running playtest; anything synced into it is discarded on Stop.",
      "Pass the edit session's studioId (see list_studios).",
    );
  }
  return session;
}

// Disk -----------------------------------------------------------------------

/** Hashes by path, reused while a file's size and mtime have not moved. */
const hashCache = new Map<string, { size: number; mtimeMs: number; hash: string }>();

interface DiskState {
  /** Script files: relative path → hash. */
  scripts: Map<string, string>;
  /** Build files: relative path → hash. */
  builds: Map<string, string>;
}

/**
 * Every script and build file under `dir`. Dot-folders (`.git`, the sync's
 * own `.rbx-sync`) and `node_modules` are skipped; so are symlinks, which could
 * lead a sync to write outside the folder it was given.
 */
async function scanDisk(dir: string): Promise<DiskState> {
  const state: DiskState = { scripts: new Map(), builds: new Map() };
  const walk = async (folder: string) => {
    let entries;
    try {
      entries = await readdir(folder, { withFileTypes: true });
    } catch (cause) {
      if ((cause as NodeJS.ErrnoException).code === "ENOENT") return;
      throw cause;
    }
    await Promise.all(
      entries.map(async (entry) => {
        if (entry.name.startsWith(".") || entry.name === "node_modules" || entry.isSymbolicLink()) return;
        const full = path.join(folder, entry.name);
        if (entry.isDirectory()) return walk(full);
        if (!entry.isFile()) return;
        const isBuild = entry.name.endsWith(BUILD_SUFFIX);
        if (!isBuild && classFromFile(entry.name) === null) return;
        const info = await stat(full);
        const cached = hashCache.get(full);
        let hash = cached?.hash;
        if (!cached || cached.size !== info.size || cached.mtimeMs !== info.mtimeMs) {
          hash = hashOf(await readFile(full, "utf8"));
          hashCache.set(full, { size: info.size, mtimeMs: info.mtimeMs, hash });
        }
        (isBuild ? state.builds : state.scripts).set(posix(path.relative(dir, full)), hash!);
      }),
    );
  };
  await walk(dir);
  return state;
}

async function readText(dir: string, relative: string): Promise<string> {
  return normalise(await readFile(absolute(dir, relative), "utf8"));
}

/** Writes through a staging file, so a crash never leaves half a script. */
async function writeText(dir: string, relative: string, text: string): Promise<void> {
  const target = absolute(dir, relative);
  await mkdir(path.dirname(target), { recursive: true });
  const staging = `${target}.${process.pid}.tmp`;
  await writeFile(staging, text, "utf8");
  await rename(staging, target);
  hashCache.delete(target);
}

/** Moves a file into `.rbx-sync/trash/<run>/`, keeping its relative path. */
async function trash(dir: string, relative: string, run: string): Promise<void> {
  const from = absolute(dir, relative);
  const to = path.join(dir, STATE_DIR, "trash", run, ...relative.split("/"));
  await mkdir(path.dirname(to), { recursive: true });
  await rename(from, to);
  hashCache.delete(from);
}

async function unlinkQuiet(target: string): Promise<void> {
  await unlink(target).catch(() => undefined);
}

/** Removes folders a move or delete left empty, up to (never including) `dir`. */
async function pruneEmpty(dir: string, relatives: Iterable<string>): Promise<void> {
  const folders = new Set<string>();
  for (const relative of relatives) {
    let folder = path.dirname(absolute(dir, relative));
    while (folder.startsWith(dir) && folder !== dir) {
      folders.add(folder);
      folder = path.dirname(folder);
    }
  }
  for (const folder of [...folders].sort((a, b) => b.length - a.length)) {
    try {
      if ((await readdir(folder)).length === 0) await rmdir(folder);
    } catch {
      // Gone already, or not empty after all: either way nothing to prune.
    }
  }
}

async function loadManifest(dir: string): Promise<Manifest | null> {
  try {
    const parsed = JSON.parse(await readFile(path.join(dir, STATE_DIR, MANIFEST), "utf8")) as Manifest;
    if (parsed.version !== 1 || typeof parsed.files !== "object") return null;
    parsed.builds ??= {};
    return parsed;
  } catch {
    return null;
  }
}

async function saveManifest(dir: string, manifest: Manifest): Promise<void> {
  const folder = path.join(dir, STATE_DIR);
  await mkdir(folder, { recursive: true });
  // The manifest records this machine's view of one Studio session; committed,
  // it would be wrong on every other machine. Kept out of git by default.
  await writeFile(path.join(folder, ".gitignore"), "*\n", "utf8");
  const target = path.join(folder, MANIFEST);
  await writeFile(`${target}.tmp`, `${JSON.stringify(manifest, null, 2)}\n`, "utf8");
  await rename(`${target}.tmp`, target);
}

// Studio ---------------------------------------------------------------------

interface ReadItem {
  path: string;
  source?: string;
  revision?: string;
  className?: string;
  code?: string;
  message?: string;
}

async function readStudio(bridge: StudioBridge, studioId: string, paths: string[], quiet?: boolean): Promise<Map<string, ReadItem>> {
  const out = new Map<string, ReadItem>();
  for (let start = 0; start < paths.length; start += BATCH_PATHS) {
    const { items } = await bridge.call<{ items: ReadItem[] }>(
      "sync.read",
      { paths: paths.slice(start, start + BATCH_PATHS), quiet },
      { studioId, timeoutMs: 60_000 },
    );
    for (const item of items) out.set(item.path, item);
  }
  return out;
}

interface ApplyResult {
  ok: boolean;
  path?: string;
  from?: string;
  revision?: string;
  code?: string;
  message?: string;
}

interface ApplyResponse {
  writes: ApplyResult[];
  creates: ApplyResult[];
  deletes: ApplyResult[];
  moves: ApplyResult[];
  undoStep?: string;
}

// The run ---------------------------------------------------------------------

/** One run at a time per folder, so `watch` and a manual call never interleave. */
const locks = new Map<string, Promise<unknown>>();

function exclusive<T>(dir: string, body: () => Promise<T>): Promise<T> {
  const previous = locks.get(dir) ?? Promise.resolve();
  const next = previous.catch(() => undefined).then(body);
  locks.set(dir, next);
  return next;
}

export function resolveDir(dir: string | undefined): string {
  return path.resolve(process.cwd(), dir ?? "studio");
}

/**
 * One sync: scan both sides, plan, read what the plan needs, and apply it --
 * or, with `dryRun`, only say what would happen.
 */
export function runSync(bridge: StudioBridge, options: SyncOptions): Promise<SyncReport> {
  return exclusive(options.dir, () => syncOnce(bridge, options));
}

async function syncOnce(bridge: StudioBridge, options: SyncOptions): Promise<SyncReport> {
  const { dir, direction, prefer } = options;
  const session = await targetSession(bridge, options.studioId);
  const studioId = session.studioId;
  const stored = await loadManifest(dir);
  const manifest = stored ?? emptyManifest();

  assertPlace(options, manifest, session);

  const roots = options.roots ?? manifest.roots;
  const quiet = options.quiet;
  const scan = await bridge.call<ScanResult>("sync.scan", { roots, revisions: true, quiet }, { studioId, timeoutMs: 120_000 });
  const studio = layout(scan);
  const disk = await scanDisk(dir);
  const inScope = (studioPath: string) =>
    scan.roots.some((root) => studioPath === root || studioPath.startsWith(`${root}.`));
  // Files outside the roots are left alone, the same as scripts are: with
  // roots [ServerScriptService], a ReplicatedStorage/ file is not new work.
  const rootDirs = scan.roots.map(
    (root) => studio.dirOf.get(root) ?? root.split(".").map((name) => encodeName(name, "dir")).join("/"),
  );
  const underRoots = (file: string) => rootDirs.some((root) => file.startsWith(`${root}/`));
  for (const table of [disk.scripts, disk.builds]) {
    for (const file of [...table.keys()]) if (!underRoots(file)) table.delete(file);
  }

  const { actions, held } = plan({ manifest, studio, disk: disk.scripts, inScope, direction, prefer });

  const report: SyncReport = {
    dir,
    place: session.placeName,
    dryRun: options.dryRun === true,
    lines: [],
    counts: {},
    conflicts: [],
    held: held.map(describe),
    failures: [],
    fileSynced: studio.fileSynced,
    builds: [],
  };

  // A run that would delete most of what it tracks is far more likely to be a
  // wrong `dir` or `roots` than a real intent. Stop and say so.
  const deletions = actions.filter((action) => action.kind === "delete-disk" || action.kind === "delete-studio").length;
  const tracked = Object.keys(manifest.files).length;
  if (deletions > MASS_DELETE && deletions * 2 > tracked && !options.confirmDeletes && !options.dryRun) {
    throw new ToolError(
      "MASS_DELETE",
      `This sync would delete ${deletions} of the ${tracked} scripts it tracks.`,
      "Check `dir` and `roots` with op=\"status\". If the deletions are intended, pass `confirmDeletes: true`.",
    );
  }

  // Content ----------------------------------------------------------------
  const moveSource = new Map<string, string>();
  for (const action of [...actions, ...held]) {
    if (action.kind === "move-disk") moveSource.set(action.file, action.fromFile);
  }
  const diskText = new Map<string, string>();
  const readDisk = async (file: string) => {
    if (!diskText.has(file)) diskText.set(file, await readText(dir, moveSource.get(file) ?? file));
    return diskText.get(file)!;
  };

  const needsStudio = actions
    .filter((action) => ["pull", "create-disk", "merge", "adopt"].includes(action.kind))
    .map((action) => (action as { path: string }).path);
  const studioText = await readStudio(bridge, studioId, [...new Set(needsStudio)], quiet);
  const remembered = manifest.conflicts ?? {};
  const conflictsNow: Record<string, { studio: string; disk: string; text: string }> = {};
  // For pulls settled here: the file text the decision saw, which the write
  // may replace. Anything else on disk by then is a newer edit.
  const diskSeen = new Map<string, string>();

  // Merges and adoptions settle into ordinary actions once both texts are known.
  const settled: Action[] = [];
  const recorded: Array<{ file: string; path: string; revision: string; className: string; text: string }> = [];
  for (const action of actions) {
    if (action.kind !== "merge" && action.kind !== "adopt") {
      settled.push(action);
      continue;
    }
    const read = studioText.get(action.path);
    if (read?.source === undefined) {
      report.failures.push({ file: action.file, reason: read?.message ?? "could not be read from Studio" });
      continue;
    }
    const onDisk = await readDisk(action.file);
    const inStudio = normalise(read.source);
    // A conflict reported before: whichever side moved since is the answer.
    const memory = remembered[action.file];
    const studioMoved = memory !== undefined && read.revision !== memory.studio;
    const diskMoved = memory !== undefined && hashOf(onDisk) !== memory.disk;
    if (onDisk === inStudio) {
      recorded.push({ file: action.file, path: action.path, revision: read.revision!, className: action.className, text: onDisk });
    } else if (memory && diskMoved && !studioMoved && direction !== "pull") {
      settled.push({ kind: "push", file: action.file, path: action.path, revision: read.revision!, className: action.className });
    } else if (memory && studioMoved && !diskMoved && direction !== "push") {
      diskSeen.set(action.file, hashOf(onDisk));
      settled.push({ kind: "pull", file: action.file, path: action.path, revision: read.revision!, className: action.className });
    } else if (prefer === "studio" && direction !== "push") {
      diskSeen.set(action.file, hashOf(onDisk));
      settled.push({ kind: "pull", file: action.file, path: action.path, revision: read.revision!, className: action.className });
    } else if (prefer === "disk" && direction !== "pull") {
      settled.push({ kind: "push", file: action.file, path: action.path, revision: read.revision!, className: action.className });
    } else {
      conflictsNow[action.file] = { studio: read.revision!, disk: hashOf(onDisk), text: inStudio };
      settled.push({
        kind: "conflict",
        file: action.file,
        path: action.path,
        reason:
          (action.kind === "adopt"
            ? "exists in both places with different text, and sync has no record of either"
            : "changed in both Studio and on disk since the last sync") +
          `. Studio's version: ${STATE_DIR}/conflicts/${action.file}. Edit the file to the merged text (or fix it in Studio) and sync again.`,
      });
    }
  }

  for (const action of settled) {
    if (action.kind === "conflict") report.conflicts.push({ file: action.file, path: action.path, reason: action.reason });
  }
  const work = settled.filter((action) => action.kind !== "conflict");

  if (options.dryRun) {
    for (const action of work) tally(report, action);
    if (options.builds !== false) await syncBuilds(bridge, studioId, manifest, disk, studio, report, options);
    return report;
  }

  const run = new Date().toISOString().replace(/[:.]/g, "-");
  const touched: string[] = [];

  // 1. Files renamed on disk to follow Studio, first: later steps read them there.
  for (const action of work) {
    if (action.kind !== "move-disk") continue;
    try {
      // Checked on disk, not against the plan: on Windows and macOS `Util.luau`
      // is also `UTIL.luau`, which the plan may be about to trash.
      if (await stat(absolute(dir, action.file)).then(() => true, () => false)) {
        report.failures.push({ file: action.file, reason: `a file is already there, so ${action.fromFile} was not moved; sync again once it is gone` });
        continue;
      }
      await mkdir(path.dirname(absolute(dir, action.file)), { recursive: true });
      await rename(absolute(dir, action.fromFile), absolute(dir, action.file));
      hashCache.delete(absolute(dir, action.fromFile));
      moveSource.delete(action.file);
      delete manifest.files[action.fromFile];
      manifest.files[action.file] = { path: action.path, className: action.className, revision: action.revision, hash: action.hash };
      touched.push(action.fromFile);
      tally(report, action);
    } catch (cause) {
      report.failures.push({ file: action.file, reason: `could not move from ${action.fromFile}: ${String(cause)}` });
    }
  }

  // 2. Studio: structure and text in batches, each item checked against its revision.
  const placements = new Map<string, ReturnType<typeof placementOf>>();
  const initClassOf = (folder: string): ScriptClass | undefined => {
    for (const [file] of disk.scripts) {
      if (!file.startsWith(`${folder}/`) || file.slice(folder.length + 1).includes("/")) continue;
      const parsed = classFromFile(file.slice(folder.length + 1));
      if (parsed?.init) return parsed.className;
    }
    return undefined;
  };
  const placement = (file: string) => {
    if (!placements.has(file)) placements.set(file, placementOf(file, studio, initClassOf));
    return placements.get(file)!;
  };

  const creates: Array<{ action: Extract<Action, { kind: "create-studio" }>; item: Record<string, unknown>; text: string }> = [];
  const moves: Array<{ action: Extract<Action, { kind: "move-studio" }>; item: Record<string, unknown> }> = [];
  const deletes: Array<{ action: Extract<Action, { kind: "delete-studio" }>; item: Record<string, unknown> }> = [];
  const writes: Array<{ action: Extract<Action, { kind: "push" }>; item: Record<string, unknown>; text: string }> = [];

  for (const action of work) {
    if (action.kind === "create-studio" || action.kind === "move-studio") {
      const where = placement(action.file);
      if ("error" in where) {
        report.failures.push({ file: action.file, reason: where.error });
        continue;
      }
      const target = { parentPath: where.parentPath, parents: where.parents, name: where.name };
      if (action.kind === "create-studio") {
        const text = await readDisk(action.file);
        creates.push({ action, item: { ...target, className: where.className, source: text }, text });
      } else {
        moves.push({ action, item: { ...target, path: action.path, revision: action.revision } });
      }
    } else if (action.kind === "delete-studio") {
      deletes.push({ action, item: { path: action.path, revision: action.revision } });
    } else if (action.kind === "push") {
      const text = await readDisk(action.file);
      writes.push({ action, item: { path: action.path, source: text, revision: action.revision }, text });
    }
  }
  // Outer scripts before the ones inside them, so a new folder's init script
  // exists before its children look for their parent.
  creates.sort((a, b) => depthOf(a.action.file) - depthOf(b.action.file) || initFirst(a.action.file, b.action.file));

  if (creates.length + moves.length + deletes.length > 0) {
    const response = await bridge.call<ApplyResponse>(
      "sync.apply",
      { creates: creates.map((entry) => entry.item), moves: moves.map((entry) => entry.item), deletes: deletes.map((entry) => entry.item), quiet },
      { studioId, timeoutMs: 120_000 },
    );
    report.undoStep = response.undoStep;
    response.creates.forEach((result, index) => {
      const { action, text } = creates[index]!;
      if (!result.ok || !result.path) return report.failures.push({ file: action.file, reason: `${result.code}: ${result.message}` });
      const where = placement(action.file) as Exclude<ReturnType<typeof placementOf>, { error: string }>;
      manifest.files[action.file] = { path: result.path, className: where.className, revision: result.revision ?? "", hash: hashOf(text) };
      tally(report, action);
    });
    response.moves.forEach((result, index) => {
      const { action } = moves[index]!;
      if (!result.ok || !result.path) return report.failures.push({ file: action.file, reason: `${result.code}: ${result.message}` });
      delete manifest.files[action.fromFile];
      manifest.files[action.file] = { path: result.path, className: action.className, revision: action.revision, hash: action.hash };
      tally(report, action);
    });
    response.deletes.forEach((result, index) => {
      const { action } = deletes[index]!;
      if (!result.ok) return report.failures.push({ file: action.file, reason: `${result.code}: ${result.message}` });
      delete manifest.files[action.file];
      tally(report, action);
    });
  }

  for (const batch of batches(writes, (entry) => entry.text.length)) {
    const response = await bridge.call<ApplyResponse>(
      "sync.apply",
      { writes: batch.map((entry) => entry.item), quiet },
      { studioId, timeoutMs: 120_000 },
    );
    response.writes.forEach((result, index) => {
      const { action, text } = batch[index]!;
      if (!result.ok) {
        const conflict = result.code === "STALE_SCRIPT";
        if (conflict) report.conflicts.push({ file: action.file, path: action.path, reason: "changed in Studio while syncing" });
        else report.failures.push({ file: action.file, reason: `${result.code}: ${result.message}` });
        return;
      }
      manifest.files[action.file] = { path: action.path, className: action.className, revision: result.revision ?? "", hash: hashOf(text) };
      tally(report, action);
    });
  }

  // 3. Disk: Studio's text into files, checked against the hash the plan saw.
  for (const action of work) {
    if (action.kind !== "pull" && action.kind !== "create-disk") continue;
    const read = studioText.get(action.path);
    if (read?.source === undefined || read.revision === undefined) {
      report.failures.push({ file: action.file, reason: read?.message ?? "could not be read from Studio" });
      continue;
    }
    // Re-read now, not from the scan: an editor may have saved in between.
    const expected = diskSeen.get(action.file) ?? (action.kind === "pull" ? manifest.files[action.file]?.hash : undefined);
    const current = await readText(dir, action.file).then(hashOf, () => undefined);
    const overwrites = action.kind === "create-disk" ? current !== undefined : current !== undefined && current !== expected;
    if (overwrites && prefer !== "studio") {
      report.conflicts.push({ file: action.file, path: action.path, reason: "changed on disk while syncing" });
      continue;
    }
    try {
      await writeText(dir, action.file, read.source);
      manifest.files[action.file] = { path: action.path, className: read.className ?? action.className, revision: read.revision, hash: hashOf(read.source) };
      tally(report, action);
    } catch (cause) {
      report.failures.push({ file: action.file, reason: String(cause) });
    }
  }

  for (const entry of recorded) {
    manifest.files[entry.file] = { path: entry.path, className: entry.className, revision: entry.revision, hash: hashOf(entry.text) };
  }

  for (const action of work) {
    if (action.kind === "delete-disk") {
      try {
        await trash(dir, action.file, run);
        delete manifest.files[action.file];
        touched.push(action.file);
        tally(report, action);
      } catch (cause) {
        report.failures.push({ file: action.file, reason: String(cause) });
      }
    } else if (action.kind === "forget") {
      delete manifest.files[action.file];
    }
  }
  await pruneEmpty(dir, touched);

  // 4. Build files, both ways.
  if (options.builds !== false) {
    await syncBuilds(bridge, studioId, manifest, disk, studio, report, options);
  }

  // 5. Conflicts: remember this run's, with Studio's side beside them to merge
  // from; forget the ones that were settled.
  const newConflicts = Object.keys(conflictsNow).filter((file) => remembered[file] === undefined);
  const nextMemory: Record<string, { studio: string; disk: string }> = {};
  for (const [file, conflict] of Object.entries(conflictsNow)) {
    nextMemory[file] = { studio: conflict.studio, disk: conflict.disk };
    await writeText(path.join(dir, STATE_DIR), `conflicts/${file}`, conflict.text).catch(() => undefined);
  }
  for (const [file, memory] of Object.entries(report.buildConflicts ?? {})) {
    nextMemory[file] = { studio: memory.studio, disk: memory.disk };
    if (remembered[file] === undefined) newConflicts.push(file);
    await writeText(path.join(dir, STATE_DIR), `conflicts/${file}`, memory.text).catch(() => undefined);
  }
  // Build files outside this run keep their memory.
  if (options.builds === false) {
    for (const [file, memory] of Object.entries(remembered)) {
      if (file.endsWith(BUILD_SUFFIX)) nextMemory[file] = memory;
    }
  }
  for (const file of Object.keys(remembered)) {
    if (nextMemory[file] === undefined) {
      await unlinkQuiet(path.join(dir, STATE_DIR, "conflicts", ...file.split("/")));
    }
  }
  manifest.conflicts = Object.keys(nextMemory).length > 0 ? nextMemory : undefined;

  manifest.placeId = session.placeId;
  manifest.placeName = session.placeName;
  manifest.roots = options.roots ?? manifest.roots;
  await saveManifest(dir, manifest);

  const diskSide = ["pull", "create-disk", "delete-disk", "move-disk"]
    .map((kind) => [kind, report.counts[kind] ?? 0] as const)
    .filter(([, count]) => count > 0);
  if (diskSide.length > 0 || newConflicts.length > 0) {
    const lines = [];
    if (diskSide.length > 0) {
      lines.push({ level: "ok", message: `sync to files: ${diskSide.map(([kind, count]) => `${count} ${LABELS[kind]}`).join(", ")}`, detail: path.basename(dir) });
    }
    // Once per conflict, not once per run: a watch would repeat it every second.
    for (const conflict of report.conflicts.filter((entry) => newConflicts.includes(entry.file)).slice(0, 5)) {
      lines.push({ level: "warn", message: `sync conflict: ${conflict.file}`, detail: "changed on both sides; see .rbx-sync/conflicts" });
    }
    if (lines.length > 0) await bridge.call("sync.log", { lines }, { studioId, timeoutMs: 5_000 }).catch(() => undefined);
  }
  report.newConflicts = newConflicts;
  return report;
}

const LABELS: Record<string, string> = {
  push: "written to Studio",
  pull: "written to disk",
  "create-studio": "created in Studio",
  "create-disk": "created on disk",
  "delete-studio": "deleted in Studio",
  "delete-disk": "moved to .rbx-sync/trash",
  "move-studio": "moved in Studio",
  "move-disk": "moved on disk",
  export: "build files updated from Studio",
};

function describe(action: Action): string {
  switch (action.kind) {
    case "move-disk":
    case "move-studio":
      return `${action.kind.padEnd(13)} ${action.fromFile} -> ${action.file}`;
    case "conflict":
      return `conflict      ${action.file}: ${action.reason}`;
    default:
      return `${action.kind.padEnd(13)} ${action.file}`;
  }
}

function tally(report: SyncReport, action: Action): void {
  report.counts[action.kind] = (report.counts[action.kind] ?? 0) + 1;
  report.lines.push(describe(action));
}

const depthOf = (file: string) => file.split("/").length;
const initFirst = (a: string, b: string) =>
  Number(!classFromFile(a.split("/").pop()!)?.init) - Number(!classFromFile(b.split("/").pop()!)?.init);

function* batches<T>(items: T[], size: (item: T) => number): Generator<T[]> {
  let batch: T[] = [];
  let bytes = 0;
  for (const item of items) {
    const cost = size(item);
    if (batch.length > 0 && (bytes + cost > BATCH_BYTES || batch.length >= BATCH_PATHS)) {
      yield batch;
      batch = [];
      bytes = 0;
    }
    batch.push(item);
    bytes += cost;
  }
  if (batch.length > 0) yield batch;
}

// Build files -------------------------------------------------------------------

interface ExportResponse {
  path: string;
  spec: Record<string, unknown>;
  instances: number;
  scripts: number;
  skipped: string[];
}

/**
 * Keys in a fixed order, so exporting an unchanged tree writes the same bytes
 * and a diff shows only what really changed.
 */
function canonical(value: unknown): unknown {
  if (Array.isArray(value)) return value.map(canonical);
  if (value === null || typeof value !== "object") return value;
  const order = ["className", "name", "properties", "attributes", "tags", "children"];
  const entries = Object.entries(value as Record<string, unknown>).sort(([a], [b]) => {
    const ai = order.indexOf(a);
    const bi = order.indexOf(b);
    if (ai !== -1 || bi !== -1) return (ai === -1 ? 99 : ai) - (bi === -1 ? 99 : bi);
    return a < b ? -1 : a > b ? 1 : 0;
  });
  return Object.fromEntries(entries.map(([key, item]) => [key, canonical(item)]));
}

/** Property lists per class, from the API dump; they do not change within a run. */
const propertyLists = new Map<string, Array<{ name: string; type: string }>>();

interface Exported {
  path: string;
  text: string;
  chain: Array<{ name: string; className: string; path: string; ordinal?: number }>;
  instances: number;
  scripts: number;
  skipped: string[];
}

/**
 * A tree as build-file text, exactly as `export` would write it -- or null when
 * nothing is at that path any more. The same function feeds `export` and the
 * change check, so "Studio changed" never means "the exporter changed".
 */
async function exportTree(bridge: StudioBridge, studioId: string, target: string, quiet?: boolean): Promise<Exported | null> {
  let listed;
  try {
    listed = await bridge.call<{
      path: string;
      classes: string[];
      chain: Exported["chain"];
    }>("sync.classes", { path: target, quiet }, { studioId, timeoutMs: 30_000 });
  } catch (cause) {
    if (cause instanceof ToolError && cause.code === "NOT_FOUND") return null;
    throw cause;
  }
  const properties: Record<string, Array<{ name: string; type: string }>> = {};
  for (const className of listed.classes) {
    if (!propertyLists.has(className)) {
      propertyLists.set(className, (await buildableProperties(className)).map((info) => ({ name: info.name, type: info.valueType })));
    }
    properties[className] = propertyLists.get(className)!;
  }
  const exported = await bridge.call<ExportResponse>(
    "sync.export",
    { path: listed.path, properties, quiet },
    { studioId, timeoutMs: 120_000 },
  );
  return {
    path: exported.path,
    text: `${JSON.stringify(canonical(exported.spec), null, 2)}\n`,
    chain: listed.chain,
    instances: exported.instances,
    scripts: exported.scripts,
    skipped: exported.skipped,
  };
}

/** The studio path a build file's folder stands for, or null. */
function parentOfBuild(file: string, studio: Layout): string | null {
  const folder = file.split("/").slice(0, -1).join("/");
  if (folder === "") return null;
  const known = studio.pathOfDir.get(folder);
  if (known !== undefined) return known;
  // A bare service folder with no scripts in it yet.
  return folder.includes("/") ? null : decodeName(folder);
}

/** Replaces the tree at `parent` from a build file; returns the new tree's export. */
async function buildFrom(
  bridge: StudioBridge,
  studioId: string,
  dir: string,
  file: string,
  parent: string,
  quiet?: boolean,
  replaces?: string,
): Promise<{ path: string; exported: Exported | null; carried: Array<{ path: string; exact: boolean }> }> {
  let raw: unknown;
  try {
    raw = JSON.parse(await readText(dir, file));
  } catch (cause) {
    throw new ToolError("BAD_BUILD_FILE", `${file} is not valid JSON: ${(cause as Error).message}`, "Fix the file and sync again.");
  }
  const [spec] = parseCreateTree([raw]);
  const typed = await typeCreateSpec(spec!, file);
  const result = await bridge.call<{ path?: string; carried: Array<{ path: string; exact: boolean }> }>(
    "sync.build",
    { parent, spec: typed, replaces, quiet },
    { studioId, timeoutMs: 120_000 },
  );
  const built = result.path ?? `${parent}.${spec!.name ?? spec!.className}`;
  return { path: built, exported: await exportTree(bridge, studioId, built, quiet), carried: result.carried };
}

/**
 * Build files, both ways, with the same three-way logic as scripts.
 *
 * The manifest holds the file's hash and Studio's export hash from the last
 * sync. The file changed alone: rebuild the tree. Studio changed alone (someone
 * moved a frame in the editor): write the new export into the file. Both
 * changed: a conflict, with Studio's export beside it to merge from -- which is
 * the fix for a build silently undoing work done in Studio.
 */
async function syncBuilds(
  bridge: StudioBridge,
  studioId: string,
  manifest: Manifest,
  disk: DiskState,
  studio: Layout,
  report: SyncReport,
  options: SyncOptions & { only?: string[] },
): Promise<void> {
  const { dir, direction, prefer, dryRun, quiet } = options;
  const remembered = manifest.conflicts ?? {};
  const files = options.only ?? [...new Set([...Object.keys(manifest.builds), ...disk.builds.keys()])].sort();
  const conflicts: NonNullable<SyncReport["buildConflicts"]> = {};
  const run = new Date().toISOString().replace(/[:.]/g, "-");

  for (const file of files) {
    const entry = manifest.builds[file];
    const diskHash = disk.builds.get(file);
    try {
      if (diskHash === undefined) {
        if (options.only) {
          report.failures.push({ file, reason: "no such build file" });
        } else if (entry && !dryRun) {
          // The file was deleted: stop tracking. The tree in Studio stays.
          delete manifest.builds[file];
          report.lines.push(`forget        ${file} (file deleted; the tree in Studio is left as it is)`);
        }
        continue;
      }

      const parent = entry?.parent ?? parentOfBuild(file, studio);
      if (!parent) {
        report.failures.push({ file, reason: "its folder does not match an instance in Studio; export the tree to place it" });
        continue;
      }
      let target = entry?.path;
      if (target === undefined) {
        const raw = JSON.parse(await readText(dir, file)) as { name?: string; className?: string };
        target = `${parent}.${raw.name ?? raw.className}`;
      }
      const current = await exportTree(bridge, studioId, target, quiet);
      const studioHash = current ? hashOf(current.text) : undefined;
      const diskText = await readText(dir, file);
      const diskChanged = entry === undefined || diskHash !== entry.hash;
      // A record from before build files were two-way has no Studio hash: take
      // today's as the baseline rather than calling everything changed.
      const studioChanged = entry !== undefined && entry.studio !== undefined && studioHash !== entry.studio;
      const memory = remembered[file];

      const doBuild = async () => {
        if (direction === "pull") return report.held.push(`build         ${file}`);
        if (dryRun) return report.builds.push(file);
        const built = await buildFrom(bridge, studioId, dir, file, parent, quiet, current?.path);
        manifest.builds[file] = { path: built.path, parent, hash: diskHash, studio: built.exported ? hashOf(built.exported.text) : undefined };
        report.builds.push(file);
        report.lines.push(`build         ${file}`);
        for (const moved of built.carried.filter((item) => !item.exact)) {
          report.failures.push({ file, reason: `${moved.path} kept, but its folder is gone from the new tree; it now sits at the root` });
        }
      };
      const doPull = async (exported: Exported) => {
        if (direction === "push") return report.held.push(`export        ${file}`);
        if (dryRun) return tally(report, { kind: "pull", file, path: exported.path, revision: "", className: "" });
        await writeText(dir, file, exported.text);
        manifest.builds[file] = { path: exported.path, parent, hash: hashOf(exported.text), studio: hashOf(exported.text) };
        report.lines.push(`export        ${file}`);
        report.counts.export = (report.counts.export ?? 0) + 1;
      };
      const conflict = (reason: string) => {
        report.conflicts.push({ file, path: target, reason: `${reason}. Studio's version: ${STATE_DIR}/conflicts/${file}.` });
        if (current) conflicts[file] = { studio: studioHash!, disk: diskHash, text: current.text };
      };

      if (!current) {
        // Nothing in Studio at that path.
        if (entry === undefined || diskChanged || prefer === "disk") {
          await doBuild();
        } else if (!dryRun && direction !== "push") {
          await trash(dir, file, run);
          delete manifest.builds[file];
          report.lines.push(`delete-disk   ${file} (the tree was deleted in Studio)`);
        }
        continue;
      }

      if (options.only) {
        // An explicit build still refuses to undo Studio edits it has not seen.
        if (studioChanged && prefer !== "disk") conflict("the tree was edited in Studio since the last sync; pass prefer: \"disk\" to rebuild over it");
        else await doBuild();
        continue;
      }

      if (normalise(current.text) === diskText) {
        if (!dryRun) manifest.builds[file] = { path: current.path, parent, hash: diskHash, studio: studioHash };
        continue;
      }
      if (entry !== undefined && entry.studio === undefined && !dryRun) entry.studio = studioHash;

      const studioMoved = memory !== undefined && studioHash !== memory.studio;
      const diskMoved = memory !== undefined && diskHash !== memory.disk;
      if (memory && diskMoved && !studioMoved) await doBuild();
      else if (memory && studioMoved && !diskMoved) await doPull(current);
      else if (diskChanged && !studioChanged) await doBuild();
      else if (studioChanged && !diskChanged) await doPull(current);
      else if (!diskChanged && !studioChanged) continue;
      else if (prefer === "disk") await doBuild();
      else if (prefer === "studio") await doPull(current);
      else conflict(entry === undefined ? "the file and the tree in Studio differ, and sync has no record of either" : "changed in both Studio and the file since the last sync");
    } catch (cause) {
      report.failures.push({ file, reason: cause instanceof ToolError ? `${cause.code}: ${cause.message}` : String(cause) });
    }
  }
  report.buildConflicts = conflicts;
}

/** Rebuilds named build files now (default: every changed one). */
export function runBuild(bridge: StudioBridge, options: SyncOptions & { files?: string[] }): Promise<SyncReport> {
  return exclusive(options.dir, async () => {
    const session = await targetSession(bridge, options.studioId);
    const manifest = (await loadManifest(options.dir)) ?? emptyManifest();
    assertPlace(options, manifest, session);
    const disk = await scanDisk(options.dir);
    const scan = await bridge.call<ScanResult>(
      "sync.scan",
      { roots: options.roots ?? manifest.roots, revisions: false },
      { studioId: session.studioId, timeoutMs: 120_000 },
    );
    const report = emptyReport(options.dir, session.placeName);
    const only = options.files?.map((file) => file.replace(/\\/g, "/"));
    await syncBuilds(bridge, session.studioId, manifest, disk, layout(scan), report, { ...options, direction: "push", only });
    rememberBuildConflicts(manifest, report);
    manifest.placeId ||= session.placeId;
    manifest.placeName ||= session.placeName;
    await saveManifest(options.dir, manifest);
    return report;
  });
}

function rememberBuildConflicts(manifest: Manifest, report: SyncReport): void {
  const entries = Object.entries(report.buildConflicts ?? {});
  if (entries.length === 0) return;
  manifest.conflicts ??= {};
  for (const [file, memory] of entries) {
    manifest.conflicts[file] = { studio: memory.studio, disk: memory.disk };
    void writeText(path.join(report.dir, STATE_DIR), `conflicts/${file}`, memory.text).catch(() => undefined);
  }
}

function assertPlace(options: SyncOptions, manifest: Manifest, session: StudioSession): void {
  if (manifest.placeId && session.placeId && manifest.placeId !== session.placeId && !options.rebind) {
    throw new ToolError(
      "PLACE_MISMATCH",
      `${options.dir} is synced with place ${manifest.placeId} (${manifest.placeName ?? "unnamed"}), not ${session.placeId} (${session.placeName}).`,
      "Use a different `dir` for this place. Pass `rebind: true` only if this folder really should follow the new place.",
    );
  }
}

/**
 * Writes instance trees as build files beside the synced scripts: a ScreenGui
 * at StarterGui.Shop becomes `StarterGui/Shop.build.json`, next to the
 * `StarterGui/Shop/` folder its LocalScripts sync into.
 */
export function runExport(
  bridge: StudioBridge,
  options: SyncOptions & { paths: string[] },
): Promise<Array<{ path: string; file: string; instances: number; scripts: number; skipped: string[] }>> {
  return exclusive(options.dir, async () => {
    const session = await targetSession(bridge, options.studioId);
    const studioId = session.studioId;
    const manifest = (await loadManifest(options.dir)) ?? emptyManifest();
    assertPlace(options, manifest, session);
    const scan = await bridge.call<ScanResult>(
      "sync.scan",
      { roots: options.roots ?? manifest.roots, revisions: false },
      { studioId, timeoutMs: 120_000 },
    );
    const studio = layout(scan);
    const out = [];
    for (const wanted of options.paths) {
      const exported = await exportTree(bridge, studioId, wanted);
      if (!exported) throw new ToolError("NOT_FOUND", `Nothing at ${wanted}.`, "Check the path with find or tree.");
      const chain = exported.chain;
      if (chain.length < 2) {
        throw new ToolError(
          "BAD_PATH",
          `${exported.path} is a service; a build file replaces its tree, and a service cannot be replaced.`,
          "Export the instances inside it instead, e.g. StarterGui.Shop.",
        );
      }
      const folders: string[] = [];
      for (const link of chain.slice(0, -1)) {
        const known = studio.dirOf.get(link.path);
        folders.push(known ? known.split("/").pop()! : encodeName(link.name, "dir") + (link.ordinal && link.ordinal > 1 ? `~${link.ordinal}` : ""));
      }
      const last = chain[chain.length - 1]!;
      const stem = encodeName(last.name, "dir") + (last.ordinal && last.ordinal > 1 ? `~${last.ordinal}` : "");
      const file = [...folders, `${stem}${BUILD_SUFFIX}`].join("/");
      await writeText(options.dir, file, exported.text);
      const hash = hashOf(exported.text);
      manifest.builds[file] = { path: exported.path, parent: chain[chain.length - 2]!.path, hash, studio: hash };
      if (manifest.conflicts?.[file]) delete manifest.conflicts[file];
      out.push({ path: exported.path, file, instances: exported.instances, scripts: exported.scripts, skipped: exported.skipped });
    }
    manifest.placeId ||= session.placeId;
    manifest.placeName ||= session.placeName;
    await saveManifest(options.dir, manifest);
    return out;
  });
}

// Watch -------------------------------------------------------------------------

export interface WatchState {
  dir: string;
  studioId: string;
  since: number;
  /** Syncs actually run. */
  cycles: number;
  /** Changes that turned out to be this watch's own writes coming back. */
  echoes: number;
  lastCycle?: { at: number; summary: string; ms: number };
  lastError?: { at: number; message: string };
  conflicts: SyncReport["conflicts"];
}

/** How often build trees are compared with Studio; they send no events. */
const BUILD_CHECK_MS = 10_000;

/**
 * Keeps a folder and Studio in step until stopped.
 *
 * Runs a sync when something changed and only then: the disk says so through
 * a file watcher, Studio through `sync.changes`, which the plugin answers from
 * edit and property events without touching any script. A slow shape check
 * covers what neither sees -- a folder renamed in Studio moves every script
 * inside it without a single script event.
 *
 * Most events are echoes: writing a file into Studio fires a Studio edit event,
 * pulling one to disk fires a file event. Each is checked against the manifest
 * first -- a file hash, or a revision the plugin has cached -- and dropped when
 * it matches what the last sync wrote, so a watch settles instead of running a
 * second sync after every real one.
 */
class Watch {
  readonly state: WatchState;
  private watcher: FSWatcher | null = null;
  private readonly timers: NodeJS.Timeout[] = [];
  private debounce: NodeJS.Timeout | null = null;
  private running = false;
  private again = false;
  private token: string | undefined;
  private shape = "";
  private stopped = false;
  private readonly files = new Set<string>();
  private readonly dirty = new Set<string>();
  private structural = false;
  private buildsDue = false;

  constructor(
    private readonly bridge: StudioBridge,
    private readonly options: SyncOptions,
    studioId: string,
  ) {
    this.state = { dir: options.dir, studioId, since: Date.now(), cycles: 0, echoes: 0, conflicts: [] };
  }

  async start(): Promise<SyncReport> {
    const first = await runSync(this.bridge, { ...this.options, studioId: this.state.studioId });
    this.record(first, 0);
    // Take the tracking token now, so the first poll is not mistaken for a
    // plugin that reloaded.
    await this.pollStudio(true);
    await mkdir(this.options.dir, { recursive: true });
    this.watcher = watchFolder(this.options.dir, { recursive: true }, (_event, name) => {
      const changed = name ? posix(String(name)) : "";
      if (changed === "" || changed.split("/").some((part) => part.startsWith(".")) || changed.endsWith(".tmp")) return;
      this.files.add(changed);
      this.schedule(250);
    });
    this.watcher.on("error", (cause) => this.fail(cause));
    this.timers.push(setInterval(() => void this.pollStudio(false), 500));
    this.timers.push(setInterval(() => void this.checkShape(), 5_000));
    this.timers.push(
      setInterval(() => {
        this.buildsDue = true;
        this.schedule(0);
      }, BUILD_CHECK_MS),
    );
    return first;
  }

  stop(): void {
    this.stopped = true;
    this.watcher?.close();
    for (const timer of this.timers) clearInterval(timer);
    if (this.debounce) clearTimeout(this.debounce);
    void this.bridge.call("sync.stop", {}, { studioId: this.state.studioId, timeoutMs: 5_000 }).catch(() => undefined);
  }

  private schedule(delay: number): void {
    if (this.stopped) return;
    if (this.debounce) clearTimeout(this.debounce);
    this.debounce = setTimeout(() => void this.cycle(), delay);
  }

  private async pollStudio(initial: boolean): Promise<void> {
    if (this.stopped) return;
    try {
      const changes = await this.bridge.call<{ token: string; reset: boolean; dirty: string[]; structural: boolean }>(
        "sync.changes",
        { token: this.token },
        { studioId: this.state.studioId, timeoutMs: 5_000 },
      );
      const fresh = changes.token !== this.token;
      this.token = changes.token;
      if (initial) return;
      // A new token means the plugin reloaded and forgot what it had seen.
      if (fresh || changes.structural) this.structural = true;
      for (const changed of changes.dirty) this.dirty.add(changed);
      if (this.structural || this.dirty.size > 0) this.schedule(150);
    } catch (cause) {
      if (!(await this.reattach(cause))) this.fail(cause);
    }
  }

  /**
   * Studio restarted, or the place was reopened: the session this watch was
   * pinned to is gone. Follow the new one -- but only to the SAME place, since
   * following whatever window is active would sync this folder into another game.
   */
  private async reattach(cause: unknown): Promise<boolean> {
    if (!(cause instanceof ToolError) || !["UNKNOWN_STUDIO", "NO_STUDIO", "DISCONNECTED"].includes(cause.code)) return false;
    try {
      const manifest = await loadManifest(this.options.dir);
      const { list } = await this.bridge.sessions();
      const next = list.find(
        (session) => !session.context?.startsWith("playtest") && manifest?.placeId !== undefined && session.placeId === manifest.placeId,
      );
      if (!next || next.studioId === this.state.studioId) return false;
      this.state.studioId = next.studioId;
      this.token = undefined;
      this.structural = true;
      this.state.lastError = undefined;
      pushNotice(`reconnected to ${next.placeName} after Studio restarted.`);
      this.schedule(0);
      return true;
    } catch {
      return false;
    }
  }

  private async checkShape(): Promise<void> {
    if (this.stopped || this.running) return;
    try {
      const { shape } = await this.bridge.call<{ shape: string }>(
        "sync.shape",
        { roots: this.options.roots },
        { studioId: this.state.studioId, timeoutMs: 30_000 },
      );
      if (this.shape !== "" && shape !== this.shape) {
        this.structural = true;
        this.schedule(0);
      }
      this.shape = shape;
    } catch (cause) {
      this.fail(cause);
    }
  }

  /**
   * Whether anything in the queue is a real change rather than an echo.
   * Errs towards "yes": a check that cannot decide runs the sync.
   */
  private async worthRunning(files: string[], dirty: string[]): Promise<boolean> {
    if (this.structural || this.buildsDue) return true;
    const manifest = await loadManifest(this.options.dir);
    if (!manifest) return true;
    for (const file of files) {
      const hash = await readText(this.options.dir, file).then(hashOf, () => undefined);
      const known = manifest.files[file]?.hash ?? manifest.builds[file]?.hash;
      if (hash === undefined ? known !== undefined : hash !== known) {
        // A folder event names the folder, not a file; only a real file counts.
        if (hash !== undefined || classFromFile(file.split("/").pop()!) || file.endsWith(BUILD_SUFFIX)) return true;
      }
    }
    if (dirty.length > 0) {
      const byPath = new Map(Object.values(manifest.files).map((entry) => [entry.path, entry.revision]));
      if (dirty.some((studioPath) => !byPath.has(studioPath))) return true;
      const { items } = await this.bridge.call<{ items: Array<{ path: string; revision?: string; missing?: boolean }> }>(
        "sync.revisions",
        { paths: dirty },
        { studioId: this.state.studioId, timeoutMs: 10_000 },
      );
      if (items.some((item) => item.missing || item.revision !== byPath.get(item.path))) return true;
    }
    return false;
  }

  private async cycle(): Promise<void> {
    if (this.stopped) return;
    if (this.running) {
      this.again = true;
      return;
    }
    this.running = true;
    const files = [...this.files];
    const dirty = [...this.dirty];
    const builds = this.buildsDue || files.some((file) => file.endsWith(BUILD_SUFFIX));
    this.files.clear();
    this.dirty.clear();
    try {
      if (!(await this.worthRunning(files, dirty))) {
        this.state.echoes += 1;
        return;
      }
      this.structural = false;
      this.buildsDue = false;
      const started = Date.now();
      const report = await runSync(this.bridge, { ...this.options, studioId: this.state.studioId, quiet: true, builds });
      this.record(report, Date.now() - started);
    } catch (cause) {
      this.fail(cause);
    } finally {
      this.running = false;
      if (this.again) {
        this.again = false;
        this.schedule(100);
      }
    }
  }

  private record(report: SyncReport, ms: number): void {
    this.state.cycles += 1;
    this.state.conflicts = report.conflicts;
    if (report.lines.length > 0 || report.conflicts.length > 0) {
      this.state.lastCycle = { at: Date.now(), summary: summarise(report), ms };
    }
    for (const file of report.newConflicts ?? []) {
      pushNotice(`conflict in ${file}: changed on both sides; Studio's version is in ${STATE_DIR}/conflicts/${file}. Merge into the file, or run sync with prefer.`);
    }
    for (const failure of report.failures.slice(0, 3)) pushNotice(`${failure.file}: ${failure.reason}`);
    this.state.lastError = undefined;
  }

  private fail(cause: unknown): void {
    const message = cause instanceof ToolError ? `${cause.code}: ${cause.message}` : String(cause);
    if (this.state.lastError?.message !== message) {
      pushNotice(`stopped syncing for now: ${message}. It retries on the next change.`);
      void this.bridge
        .call("sync.log", { lines: [{ level: "warn", message: "sync watch: " + message }] }, { studioId: this.state.studioId, timeoutMs: 5_000 })
        .catch(() => undefined);
    }
    this.state.lastError = { at: Date.now(), message };
  }
}

const watches = new Map<string, Watch>();

export async function startWatch(bridge: StudioBridge, options: SyncOptions): Promise<{ state: WatchState; first: SyncReport; already: boolean }> {
  const existing = watches.get(options.dir);
  if (existing) return { state: existing.state, first: emptyReport(options.dir, ""), already: true };
  const session = await targetSession(bridge, options.studioId);
  const watch = new Watch(bridge, { ...options, direction: "both" }, session.studioId);
  const first = await watch.start();
  watches.set(options.dir, watch);
  return { state: watch.state, first, already: false };
}

export function stopWatch(dir: string): WatchState | null {
  const watch = watches.get(dir);
  if (!watch) return null;
  watch.stop();
  watches.delete(dir);
  return watch.state;
}

export function watchState(dir: string): WatchState | null {
  return watches.get(dir)?.state ?? null;
}

export function stopAllWatches(): void {
  for (const dir of [...watches.keys()]) stopWatch(dir);
}

function emptyReport(dir: string, place: string): SyncReport {
  return { dir, place, dryRun: false, lines: [], counts: {}, conflicts: [], held: [], failures: [], fileSynced: [], builds: [] };
}

/** One line for the whole run, e.g. "3 written to Studio, 1 created on disk". */
export function summarise(report: SyncReport): string {
  const parts = Object.entries(report.counts)
    .filter(([kind]) => kind in LABELS)
    .map(([kind, count]) => `${count} ${LABELS[kind]}`);
  if (report.builds.length > 0) parts.push(`${report.builds.length} ${report.dryRun ? "to build" : "built"}`);
  if (report.conflicts.length > 0) parts.push(`${report.conflicts.length} conflict${report.conflicts.length === 1 ? "" : "s"}`);
  if (report.failures.length > 0) parts.push(`${report.failures.length} failed`);
  return parts.length > 0 ? parts.join(", ") : "nothing to do";
}
