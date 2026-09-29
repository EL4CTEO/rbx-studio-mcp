/**
 * The decisions behind `sync`, kept free of I/O so every one can be tested.
 *
 * Three questions are answered here:
 *
 *  - What is a script's file called? Roblox names can hold anything, and file
 *    names cannot (see `encodeName`).
 *  - Where does each script live on disk? The folder tree mirrors the instance
 *    tree, Rojo-style: `.server.luau`, `.client.luau`, `.luau`, and a script
 *    with scripts inside becomes a folder holding an `init` file (`layout`).
 *  - Given what the last sync recorded, what Studio holds now and what the disk
 *    holds now, what should happen to each file (`plan`)? This is a three-way
 *    comparison: the manifest is the common ancestor, so a side that moved is
 *    told apart from a side that did not, and a file both sides changed is a
 *    conflict rather than a silent win for whichever was looked at last.
 */

export type ScriptClass = "Script" | "LocalScript" | "ModuleScript";

/** One instance on the chain above some script, as `sync.scan` reports it. */
export interface StudioNode {
  path: string;
  name: string;
  className: string;
  /** Position of the parent in the same list, 1-based; 0 is the DataModel. */
  parent: number;
  /** Place among same-named siblings, when the name is not unique. */
  ordinal?: number;
}

export interface ScanResult {
  nodes: StudioNode[];
  items: Array<{ node: number; revision?: string; fileSynced?: boolean }>;
  roots: string[];
}

export interface ManifestEntry {
  /** Studio path of the script, as `Paths.of` wrote it. */
  path: string;
  className: string;
  /** Studio revision (`ScriptEdit.fingerprint`) at the last sync. */
  revision: string;
  /** sha256 of the file's normalised text at the last sync. */
  hash: string;
}

export interface BuildEntry {
  /** Studio path of the instance the build file describes. */
  path: string;
  /** Studio path of its parent, where a rebuild puts the new tree. */
  parent: string;
  /** sha256 of the file at the last sync. */
  hash: string;
  /**
   * sha256 of the tree as Studio exported it at the last sync. What makes a
   * build file two-way: a tree edited in Studio since is noticed, rather than
   * silently rebuilt over the next time the file changes.
   */
  studio?: string;
}

/**
 * A conflict sync has already reported, and the state of both sides then.
 *
 * Whichever side moves afterwards is taken as the resolution: edit the file to
 * the merged text and the next sync pushes it; fix it in Studio instead and the
 * next sync pulls. Only a side that has not moved since is still in conflict.
 */
export interface ConflictMemory {
  /** Studio revision (scripts) or export hash (build files) when reported. */
  studio: string;
  /** File hash when reported. */
  disk: string;
}

export interface Manifest {
  version: 1;
  placeId?: number;
  placeName?: string;
  roots?: string[];
  files: Record<string, ManifestEntry>;
  builds: Record<string, BuildEntry>;
  conflicts?: Record<string, ConflictMemory>;
}

export function emptyManifest(): Manifest {
  return { version: 1, files: {}, builds: {} };
}

// Names ---------------------------------------------------------------------

const EXTENSIONS: Record<ScriptClass, string> = {
  Script: ".server.luau",
  LocalScript: ".client.luau",
  ModuleScript: ".luau",
};

/** Extension a script of `className` is written with. */
export function extensionOf(className: string): string {
  return EXTENSIONS[className as ScriptClass] ?? ".luau";
}

/**
 * What a file name says about the script in it, or null for a file sync
 * ignores. `.lua` is read too, since editors and habits produce it, but only
 * ever written as `.luau`.
 */
export function classFromFile(fileName: string): { stem: string; className: ScriptClass; init: boolean } | null {
  const match = /^(.*?)(\.server|\.client)?\.luau?$/i.exec(fileName);
  if (!match || match[1] === undefined) return null;
  const stem = match[1];
  const kind = match[2]?.toLowerCase();
  const className: ScriptClass = kind === ".server" ? "Script" : kind === ".client" ? "LocalScript" : "ModuleScript";
  return { stem, className, init: stem.toLowerCase() === "init" };
}

const RESERVED = /^(con|prn|aux|nul|com[1-9]|lpt[1-9])(\..*)?$/i;

/**
 * An instance name as a file or folder name that every OS accepts and that
 * decodes back to the same name.
 *
 * Anything Windows refuses (`<>:"/\|?*`, control characters, a trailing dot
 * or space, CON and friends) becomes `%XX`, and so does `%` itself so decoding
 * is unambiguous. A script's file name also escapes dots, or a ModuleScript
 * named `Config.server` would come back as a Script named `Config`, and
 * escapes a script literally named `init`, which would read as a folder's own.
 */
export function encodeName(name: string, kind: "dir" | "script"): string {
  if (name === "") return "%00";
  const escape = (char: string) => `%${char.charCodeAt(0).toString(16).toUpperCase().padStart(2, "0")}`;
  let out = "";
  for (const char of name) {
    const code = char.charCodeAt(0);
    if (code < 0x20 || code === 0x7f || '<>:"/\\|?*%'.includes(char) || (kind === "script" && char === ".")) {
      out += escape(char);
    } else {
      out += char;
    }
  }
  if (/^\.+$/.test(out)) out = out.replace(/\./g, "%2E");
  if (/[. ]$/.test(out)) out = out.slice(0, -1) + escape(out.slice(-1));
  if (RESERVED.test(out) || (kind === "script" && out.toLowerCase() === "init")) out = escape(out[0]!) + out.slice(1);
  return out;
}

export function decodeName(encoded: string): string {
  if (encoded === "%00") return "";
  return encoded.replace(/%([0-9A-Fa-f]{2})/g, (_, hex: string) => String.fromCharCode(Number.parseInt(hex, 16)));
}

/** Strips a `~2` collision suffix added by `layout`. */
function stripSuffix(encoded: string): string {
  return encoded.replace(/~\d+$/, "");
}

// Layout --------------------------------------------------------------------

export interface Layout {
  /** Script studio path → file, relative to the sync folder, `/`-separated. */
  fileOf: Map<string, string>;
  /** Folder → the studio path of the instance it stands for. */
  pathOfDir: Map<string, string>;
  /** Studio path → folder, the reverse of `pathOfDir`. */
  dirOf: Map<string, string>;
  /** Scripts sync manages: studio path → class and revision. */
  scripts: Map<string, { className: string; revision?: string }>;
  /** Scripts Studio's own Script Sync already binds to a file; left alone. */
  fileSynced: string[];
}

/**
 * Where every scanned script goes on disk.
 *
 * Deterministic for a given scan: siblings whose names collide once encoded
 * and case-folded (Windows and macOS do not tell `Shop` from `shop`) are
 * ordered by studio path, the first keeps its name and the rest get `~2`,
 * `~3`. The manifest remembers which file is which, so the suffix never has
 * to be decoded for a file sync already knows.
 */
export function layout(scan: ScanResult): Layout {
  const children = new Map<number, number[]>();
  scan.nodes.forEach((node, index) => {
    const list = children.get(node.parent) ?? [];
    list.push(index + 1);
    children.set(node.parent, list);
  });
  const scriptNodes = new Map<number, { revision?: string; fileSynced?: boolean }>();
  for (const item of scan.items) scriptNodes.set(item.node, item);

  const result: Layout = {
    fileOf: new Map(),
    pathOfDir: new Map(),
    dirOf: new Map(),
    scripts: new Map(),
    fileSynced: [],
  };

  const visit = (parentIndex: number, parentDir: string) => {
    const kids = (children.get(parentIndex) ?? []).map((index) => {
      const node = scan.nodes[index - 1]!;
      const isScript = scriptNodes.has(index);
      const hasKids = (children.get(index)?.length ?? 0) > 0;
      const asDir = !isScript || hasKids;
      const base = encodeName(node.name, asDir ? "dir" : "script");
      const ext = asDir ? "" : extensionOf(node.className);
      return { index, node, isScript, asDir, base, ext };
    });

    const groups = new Map<string, typeof kids>();
    for (const kid of kids) {
      const key = `${kid.asDir ? "d" : "f"}:${(kid.base + kid.ext).toLowerCase()}`;
      const group = groups.get(key) ?? [];
      group.push(kid);
      groups.set(key, group);
    }
    for (const group of groups.values()) {
      group.sort((a, b) => (a.node.path < b.node.path ? -1 : a.node.path > b.node.path ? 1 : 0));
      group.forEach((kid, position) => {
        const stem = position === 0 ? kid.base : `${kid.base}~${position + 1}`;
        const entry = parentDir === "" ? stem + kid.ext : `${parentDir}/${stem}${kid.ext}`;
        const script = scriptNodes.get(kid.index);
        if (kid.asDir) {
          result.pathOfDir.set(entry, kid.node.path);
          result.dirOf.set(kid.node.path, entry);
        }
        if (script) {
          if (script.fileSynced) {
            result.fileSynced.push(kid.node.path);
          } else {
            result.scripts.set(kid.node.path, { className: kid.node.className, revision: script.revision });
            result.fileOf.set(kid.node.path, kid.asDir ? `${entry}/init${extensionOf(kid.node.className)}` : entry);
          }
        }
        if (kid.asDir) visit(kid.index, entry);
      });
    }
  };
  visit(0, "");
  return result;
}

/** Where a file on disk says a new script should be created. */
export interface Placement {
  /** Deepest existing instance the file sits under, when there is one. */
  parentPath?: string;
  /** Instances to find or create below `parentPath`, outermost first. */
  parents: Array<{ name: string; className: string }>;
  name: string;
  className: ScriptClass;
}

/**
 * Reads a script's intended place in Studio from its file path.
 *
 * Folders the last scan already knows resolve to their exact instance, so a
 * file dropped into `Weapons~2/` lands in the second Weapons folder rather
 * than a new one called "Weapons~2". Folders it does not know become Folder
 * instances -- or the script class of an `init` file inside them.
 */
export function placementOf(
  file: string,
  known: Layout,
  initClassOf: (dir: string) => ScriptClass | undefined,
): Placement | { error: string } {
  const parts = file.split("/");
  const fileName = parts.pop()!;
  const parsed = classFromFile(fileName);
  if (!parsed) return { error: "not a .luau file" };
  if (parts.length === 0) return { error: "scripts go inside a service folder, e.g. ServerScriptService/" };

  let name: string;
  let dirs = parts;
  if (parsed.init) {
    name = decodeName(stripSuffix(parts[parts.length - 1]!));
    dirs = parts.slice(0, -1);
    if (dirs.length === 0) return { error: "a service folder cannot hold an init file" };
    if (known.pathOfDir.has(parts.join("/")) && !known.fileOf.has(known.pathOfDir.get(parts.join("/"))!)) {
      return { error: "that folder is a non-script instance in Studio; an init file cannot turn it into a script" };
    }
  } else {
    name = decodeName(parsed.stem);
  }

  let depth = dirs.length;
  while (depth > 0 && !known.pathOfDir.has(dirs.slice(0, depth).join("/"))) depth -= 1;
  const parentPath = depth > 0 ? known.pathOfDir.get(dirs.slice(0, depth).join("/")) : undefined;
  const parents = dirs.slice(depth).map((segment, offset) => {
    const dir = dirs.slice(0, depth + offset + 1).join("/");
    return { name: decodeName(stripSuffix(segment)), className: initClassOf(dir) ?? "Folder" };
  });
  return { parentPath, parents, name, className: parsed.className };
}

// Plan ----------------------------------------------------------------------

export type Action =
  /** Disk changed: write the file into Studio. */
  | { kind: "push"; file: string; path: string; revision: string; className: string }
  /** Studio changed: write the script to disk. */
  | { kind: "pull"; file: string; path: string; revision: string; className: string }
  /** Both changed: equal text is fine, different text is a conflict. */
  | { kind: "merge"; file: string; path: string; revision: string; className: string }
  /** Both exist and sync has never seen them: adopt if equal, else conflict. */
  | { kind: "adopt"; file: string; path: string; revision: string; className: string }
  | { kind: "create-studio"; file: string }
  | { kind: "create-disk"; file: string; path: string; revision: string; className: string }
  | { kind: "delete-studio"; file: string; path: string; revision: string }
  | { kind: "delete-disk"; file: string; path: string }
  /** A file was renamed or moved on disk: move the script, keeping it the same instance. */
  | { kind: "move-studio"; file: string; fromFile: string; path: string; revision: string; hash: string; className: string }
  /** A script was renamed or moved in Studio (or its file name changed): move the file. */
  | { kind: "move-disk"; file: string; fromFile: string; path: string; revision: string; hash: string; className: string }
  /** Both sides are gone: drop the record. */
  | { kind: "forget"; file: string }
  | { kind: "conflict"; file: string; path?: string; reason: string };

export type Direction = "both" | "pull" | "push";

export interface PlanInput {
  manifest: Manifest;
  studio: Layout;
  /** Script files on disk, relative path → hash of normalised text. */
  disk: Map<string, string>;
  /** Whether a studio path is inside the scanned roots. */
  inScope: (path: string) => boolean;
  direction: Direction;
  prefer?: "studio" | "disk";
}

export interface Plan {
  actions: Action[];
  /** Actions the direction does not allow this time; reported, not done. */
  held: Action[];
}

const STUDIO_SIDE = new Set(["push", "create-studio", "delete-studio", "move-studio"]);
const DISK_SIDE = new Set(["pull", "create-disk", "delete-disk", "move-disk"]);

/**
 * Decides what each file needs, from the manifest (the last agreed state),
 * Studio now and the disk now.
 *
 * Deletions only ever follow a record: a file or script sync has never seen is
 * something to create on the other side, never something to delete. And a
 * rename is recognised by content -- the vanished file's last hash on one side,
 * the new one's on the other -- so moving a script keeps it the same instance,
 * with its attributes and every reference to it intact, instead of deleting
 * one script and creating a stranger.
 */
export function plan(input: PlanInput): Plan {
  const { manifest, studio, disk, inScope, direction, prefer } = input;
  const out: Plan = { actions: [], held: [] };
  const emit = (action: Action) => {
    const blocked =
      (direction === "pull" && STUDIO_SIDE.has(action.kind)) || (direction === "push" && DISK_SIDE.has(action.kind));
    (blocked ? out.held : out.actions).push(action);
  };

  const entries = Object.entries(manifest.files)
    .filter(([, entry]) => inScope(entry.path))
    .map(([file, entry]) => ({ file, ...entry }));
  const byPath = new Map(entries.map((entry) => [entry.path, entry]));
  const claimed = new Set<string>(entries.map((entry) => entry.file));

  const studioNew: string[] = [];
  const studioGone: typeof entries = [];
  const diskGone: typeof entries = [];

  for (const [path, info] of studio.scripts) {
    const entry = byPath.get(path);
    const target = studio.fileOf.get(path)!;
    const revision = info.revision ?? "";
    if (!entry) {
      studioNew.push(path);
      continue;
    }
    const studioChanged = revision !== entry.revision;
    let file = entry.file;
    let hash = disk.get(file);

    // Same script, different file name: it gained scripts inside it (and now
    // needs a folder with an init file), or a sibling now collides with it.
    if (file !== target && hash !== undefined) {
      if (disk.has(target) && !claimed.has(target)) {
        emit({ kind: "conflict", file: target, path, reason: `${path} should now be at ${target}, but a different file is already there` });
        continue;
      }
      emit({ kind: "move-disk", file: target, fromFile: file, path, revision: entry.revision, hash: entry.hash, className: entry.className });
      claimed.add(target);
      file = target;
    }

    if (hash === undefined) {
      if (!studioChanged) {
        diskGone.push(entry);
      } else if (prefer === "studio") {
        emit({ kind: "pull", file: target, path, revision, className: info.className });
      } else if (prefer === "disk") {
        emit({ kind: "delete-studio", file: entry.file, path, revision });
      } else {
        emit({ kind: "conflict", file: entry.file, path, reason: "deleted on disk, but changed in Studio since the last sync" });
      }
      continue;
    }

    const diskChanged = hash !== entry.hash;
    if (studioChanged && diskChanged) emit({ kind: "merge", file, path, revision, className: info.className });
    else if (diskChanged) emit({ kind: "push", file, path, revision: entry.revision, className: entry.className });
    else if (studioChanged) emit({ kind: "pull", file, path, revision, className: info.className });
    hash = undefined;
  }

  for (const entry of entries) {
    if (studio.scripts.has(entry.path)) continue;
    const hash = disk.get(entry.file);
    if (hash === undefined) {
      emit({ kind: "forget", file: entry.file });
    } else if (hash === entry.hash) {
      studioGone.push(entry);
    } else if (prefer === "disk") {
      emit({ kind: "create-studio", file: entry.file });
    } else if (prefer === "studio") {
      emit({ kind: "delete-disk", file: entry.file, path: entry.path });
    } else {
      emit({ kind: "conflict", file: entry.file, path: entry.path, reason: "deleted in Studio, but edited on disk since the last sync" });
    }
  }

  const diskNew = [...disk.keys()].filter((file) => !claimed.has(file)).sort();
  const diskNewSet = new Set(diskNew);

  // Renamed or moved in Studio: the same text turned up at a new path.
  for (const entry of studioGone) {
    const match = studioNew.find(
      (path) => studio.scripts.get(path)!.revision === entry.revision && studio.scripts.get(path)!.className === entry.className,
    );
    if (match === undefined) {
      emit({ kind: "delete-disk", file: entry.file, path: entry.path });
      continue;
    }
    studioNew.splice(studioNew.indexOf(match), 1);
    const target = studio.fileOf.get(match)!;
    if (diskNewSet.has(target)) {
      emit({ kind: "conflict", file: target, path: match, reason: `${match} was moved in Studio, but a different file already exists at its new place` });
      continue;
    }
    emit({ kind: "move-disk", file: target, fromFile: entry.file, path: match, revision: entry.revision, hash: entry.hash, className: entry.className });
  }

  // Renamed or moved on disk: the same text turned up in a new file.
  for (const entry of diskGone) {
    const match = diskNew.find(
      (file) => diskNewSet.has(file) && disk.get(file) === entry.hash && classFromFile(file.split("/").pop()!)?.className === entry.className,
    );
    if (match === undefined) {
      emit({ kind: "delete-studio", file: entry.file, path: entry.path, revision: entry.revision });
      continue;
    }
    diskNewSet.delete(match);
    emit({ kind: "move-studio", file: match, fromFile: entry.file, path: entry.path, revision: entry.revision, hash: entry.hash, className: entry.className });
  }

  for (const path of studioNew) {
    const target = studio.fileOf.get(path)!;
    const info = studio.scripts.get(path)!;
    if (diskNewSet.has(target)) {
      diskNewSet.delete(target);
      emit({ kind: "adopt", file: target, path, revision: info.revision ?? "", className: info.className });
    } else {
      emit({ kind: "create-disk", file: target, path, revision: info.revision ?? "", className: info.className });
    }
  }

  for (const file of diskNew) {
    if (diskNewSet.has(file)) emit({ kind: "create-studio", file });
  }

  return out;
}

/** Text as it is compared and hashed: no BOM, `\n` line ends. */
export function normalise(text: string): string {
  return text.replace(/^﻿/, "").replace(/\r\n?/g, "\n");
}
