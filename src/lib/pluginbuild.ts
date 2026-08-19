import { createHash } from "node:crypto";
import { readdirSync, readFileSync } from "node:fs";
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

let cached: string | null = null;

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
      into.push([
        relative(root, path).split("\\").join("/"),
        readFileSync(path, "utf8"),
      ]);
    }
  }
}

/**
 * Hashes every .luau file under plugin/src, sorted by path. Line endings are
 * normalised because git checkouts differ between platforms and the plugin
 * would otherwise look stale on Windows.
 */
export function expectedPluginBuildId(): string {
  if (cached !== null) return cached;

  try {
    const root = pluginSourceDir();
    const files: Array<[string, string]> = [];
    collect(root, root, files);
    files.sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0));

    const hash = createHash("sha256");
    for (const [path, contents] of files) {
      hash.update(path);
      hash.update("\n");
      hash.update(contents.replace(/\r\n/g, "\n"));
      hash.update("\n");
    }
    cached = hash.digest("hex").slice(0, 12);
  } catch {
    // Sources missing (an unusual install layout) means we cannot compare, and
    // an unverifiable version is better reported as "unknown" than as stale.
    cached = "unknown";
  }
  return cached;
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
