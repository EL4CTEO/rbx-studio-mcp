/**
 * Shared by the dev scripts: where the native server binary is, and the
 * plugin build id the server expects (same hash as server/build.rs).
 */
import { createHash } from "node:crypto";
import { existsSync, readdirSync, readFileSync } from "node:fs";
import { dirname, join, relative, resolve } from "node:path";
import { fileURLToPath } from "node:url";

export const root = resolve(dirname(fileURLToPath(import.meta.url)), "..", "..");

/** The newest local build of the server: release first, then debug. */
export function nativeBinary() {
  const exe = process.platform === "win32" ? ".exe" : "";
  const found = ["release", "debug"]
    .map((profile) => join(root, "server", "target", profile, `rbx-studio-mcp${exe}`))
    .find(existsSync);
  if (!found) throw new Error("No server build found. Run: cargo build --release --manifest-path server/Cargo.toml");
  return found;
}

/** sha256 over plugin/src, sorted by path, CRLF normalised; first 12 hex chars. */
export function pluginBuildId() {
  const dir = join(root, "plugin", "src");
  const files = [];
  const walk = (folder) => {
    for (const entry of readdirSync(folder, { withFileTypes: true })) {
      const path = join(folder, entry.name);
      if (entry.isDirectory()) walk(path);
      else if (entry.name.endsWith(".luau")) files.push([relative(dir, path).split("\\").join("/"), path]);
    }
  };
  walk(dir);
  files.sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0));
  const hash = createHash("sha256");
  for (const [name, path] of files) {
    hash.update(name);
    hash.update("\n");
    hash.update(readFileSync(path, "utf8").replace(/\r\n/g, "\n"));
    hash.update("\n");
  }
  return hash.digest("hex").slice(0, 12);
}
