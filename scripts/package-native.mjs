/**
 * Builds the per-platform npm package for one compiled binary.
 *
 * Usage: node scripts/package-native.mjs <target> <path-to-binary> <out-dir>
 *   target: win32-x64 | win32-arm64 | darwin-arm64 | darwin-x64
 */
import { chmodSync, copyFileSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join, resolve } from "node:path";
import { root } from "./lib/native.mjs";

const [target, binary, outDir] = process.argv.slice(2);
const [os, cpu] = (target ?? "").split("-");
if (!["win32", "darwin"].includes(os) || !["x64", "arm64"].includes(cpu) || !binary || !outDir) {
  process.stderr.write("usage: node scripts/package-native.mjs <win32|darwin>-<x64|arm64> <binary> <out-dir>\n");
  process.exit(1);
}
const main = JSON.parse(readFileSync(join(root, "package.json"), "utf8"));
const dir = resolve(outDir, target);
mkdirSync(join(dir, "bin"), { recursive: true });
const exe = os === "win32" ? "rbx-studio-mcp.exe" : "rbx-studio-mcp";
copyFileSync(binary, join(dir, "bin", exe));
if (os !== "win32") chmodSync(join(dir, "bin", exe), 0o755);
writeFileSync(
  join(dir, "package.json"),
  `${JSON.stringify(
    {
      name: `${main.name}-${target}`,
      version: main.version,
      description: `${main.name} server binary for ${target}.`,
      license: main.license,
      repository: main.repository,
      os: [os],
      cpu: [cpu],
      files: ["bin"],
      preferUnplugged: true,
    },
    null,
    2,
  )}\n`,
);
copyFileSync(join(root, "LICENSE"), join(dir, "LICENSE"));
process.stdout.write(`${dir}\n`);
