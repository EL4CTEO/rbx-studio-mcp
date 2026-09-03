import { createHash } from "node:crypto";
import { readdirSync, readFileSync, statSync } from "node:fs";
import { dirname, join, relative, resolve } from "node:path";
import { fileURLToPath } from "node:url";

/**
 * Fingerprint of the Luau sources this server package ships.
 *
 * Roblox Studio only reloads a plugin when it next takes focus, so a developer
 * who rebuilds the plugin while working in a terminal keeps talking to the
 * previous build — and the symptom is a handler quietly behaving like an older
 * version, which is miserable to debug. The plugin reports the fingerprint it
 * was built from, the server compares it against this one, and any mismatch is
 * surfaced in `studio_status` and `list_studios` with the fix.
 *
 * Must stay byte-identical to the hash in scripts/build-plugin.mjs.
 */

/**
 * Memo keyed by the sources' modification times, not held for the process.
 *
 * Caching the hash forever meant the server kept comparing against the sources
 * as they were WHEN IT STARTED. Rebuild the plugin mid-session and the freshly
 * installed plugin gets reported as the stale one, with advice — click into
 * Studio, reinstall — that cannot possibly help, because the plugin was already
 * the newer of the two. Re-hashing when a file's mtime moves costs a stat per
 * source file and keeps the comparison honest.
 */
let cached: { key: string; id: string } | null = null;

function pluginSourceDir(): string {
  // dist/lib/pluginbuild.js -> package root -> plugin/src
  return resolve(dirname(fileURLToPath(import.meta.url)), "..", "..", "plugin", "src");
}

function collect(dir: string, root: string, into: Array<[string, string]>): void {
  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    const path = join(dir, entry.name);
    if (entry.isDirectory()) {
      collect(path, root, into);
    } else if (entry.name.endsWith(".luau")) {
      into.push([relative(root, path).split("\\").join("/"), path]);
    }
  }
}

/**
 * Hashes every .luau file under plugin/src, sorted by path. Line endings are
 * normalised because git checkouts differ between platforms and the plugin
 * would otherwise look stale on Windows.
 */
export function expectedPluginBuildId(): string {
  try {
    const root = pluginSourceDir();
    const files: Array<[string, string]> = [];
    collect(root, root, files);
    files.sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0));

    // Cheap enough to check on every call, and the only way a rebuild during a
    // session is noticed at all.
    const key = files.map(([name, path]) => `${name}:${statSync(path).mtimeMs}`).join("|");
    if (cached !== null && cached.key === key) return cached.id;

    const hash = createHash("sha256");
    for (const [name, path] of files) {
      hash.update(name);
      hash.update("\n");
      hash.update(readFileSync(path, "utf8").replace(/\r\n/g, "\n"));
      hash.update("\n");
    }
    cached = { key, id: hash.digest("hex").slice(0, 12) };
  } catch {
    // Sources missing (an unusual install layout) means we cannot compare, and
    // an unverifiable version is better reported as "unknown" than as stale.
    cached = { key: "missing", id: "unknown" };
  }
  return cached.id;
}

/**
 * Human-readable warning when the connected plugin was built from different
 * sources, or null when it matches. Returned to the agent so it knows a
 * surprising result may just be a stale plugin.
 */
export function pluginStalenessWarning(reported: string | undefined): string | null {
  const expected = expectedPluginBuildId();
  if (expected === "unknown" || !reported || reported === expected) return null;

  if (reported === "dev") {
    return (
      "The connected plugin was loaded from source rather than a build, so its " +
      "version cannot be verified against this server."
    );
  }
  return (
    `The connected Studio plugin was built from different sources than this ` +
    `server (plugin ${reported}, server ${expected}). Studio only reloads a ` +
    `plugin when its window next takes focus — click into Studio, then retry. ` +
    `If that does not clear it, run \`npm run install:plugin\` and restart Studio.`
  );
}

/** Build ids already explained in full during this server process. */
const announced = new Set<string>();

/**
 * The staleness warning, told once.
 *
 * The full text is four sentences of instructions, and it was riding on every
 * `studio_status` and once per row in `list_studios` — with two windows open,
 * the same paragraph twice in one response, for the rest of the session. It
 * says one thing, and an agent only needs to be told it once: the first
 * observation of a build id gets the whole explanation, later ones get a tag
 * short enough to ignore.
 *
 * Keyed on the build id, so a plugin that actually reloads into a different
 * build is a new fact and gets the full text again. A plugin that reloads into
 * a *matching* build produces no warning at all, which is the real all-clear.
 */
export function pluginStalenessNotice(reported: string | undefined): string | null {
  const warning = pluginStalenessWarning(reported);
  if (warning === null) return null;

  const key = reported ?? "unknown";
  if (announced.has(key)) {
    return `Plugin is still the stale build ${key} (already explained in this session).`;
  }
  announced.add(key);
  return warning;
}

/** Test seam: forgets what has been announced, so a fresh process is simulable. */
export function resetStalenessNotices(): void {
  announced.clear();
}
