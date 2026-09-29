/** Build from a clean output directory so removed tools cannot enter npm packs. */
import { execFileSync } from "node:child_process";
import { existsSync, realpathSync, rmSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const root = realpathSync(resolve(dirname(fileURLToPath(import.meta.url)), ".."));
const output = join(root, "dist");
if (existsSync(output)) {
  // Refuse junctions/symlinks outside the exact generated-output directory.
  if (realpathSync(output) !== output) throw new Error("dist resolves outside the expected build directory");
  rmSync(output, { recursive: true, force: true });
}
execFileSync(process.execPath, [join(root, "node_modules", "typescript", "bin", "tsc")], { cwd: root, stdio: "inherit" });
