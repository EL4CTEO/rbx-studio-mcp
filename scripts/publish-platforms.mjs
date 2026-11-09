/**
 * Runs before `npm publish` (as `prepublishOnly`) so one command ships a
 * release: the four platform packages first, then npm publishes the main one.
 *
 * The platform packages hold native binaries that only the Release workflow
 * builds, so they are taken from the GitHub release for this version rather
 * than built here. Any already on npm are skipped, so a publish that failed
 * half way can simply be run again.
 *
 * Refuses when the tree is not clean or not on the tag, because the main
 * package is packed from this checkout and must match the binaries.
 */
import { spawnSync } from "node:child_process";
import { mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const pkg = JSON.parse(readFileSync(join(root, "package.json"), "utf8"));
const version = pkg.version;
const tag = `v${version}`;
const repo = "EL4CTEO/rbx-studio-mcp";

function fail(message) {
  console.error(`\npublish stopped: ${message}\n`);
  process.exit(1);
}

function git(...args) {
  const r = spawnSync("git", args, { cwd: root, encoding: "utf8" });
  return r.status === 0 ? r.stdout.trim() : null;
}

// npm itself, the same one running this publish.
function npm(args, options = {}) {
  const cli = process.env.npm_execpath;
  return cli
    ? spawnSync(process.execPath, [cli, ...args], { cwd: root, ...options })
    : spawnSync(process.platform === "win32" ? "npm.cmd" : "npm", args, { cwd: root, shell: process.platform === "win32", ...options });
}

if (git("status", "--porcelain")) fail("there are uncommitted changes. Commit them first.");
const tagged = git("rev-parse", `${tag}^{commit}`);
if (!tagged) fail(`there is no ${tag} tag. Tag and push it so the Release workflow builds the binaries.`);
if (git("merge-base", "--is-ancestor", tag, "HEAD") === null) fail(`this checkout does not contain ${tag}. Run: git checkout main`);
// The main package is the launcher plus docs; the launcher must be the tagged one.
if (spawnSync("git", ["diff", "--quiet", tag, "HEAD", "--", "bin"], { cwd: root }).status !== 0) {
  fail(`bin/ changed since ${tag}. Release a new version instead.`);
}

const platforms = Object.keys(pkg.optionalDependencies ?? {});
const dir = mkdtempSync(join(tmpdir(), "rbx-publish-"));

for (const name of platforms) {
  const seen = npm(["view", `${name}@${version}`, "version"], { encoding: "utf8" });
  if (seen.status === 0 && seen.stdout.trim() === version) {
    console.log(`${name}@${version} is already on npm`);
    continue;
  }
  const file = `${name.replace("@", "").replace("/", "-")}-${version}.tgz`;
  const url = `https://github.com/${repo}/releases/download/${tag}/${file}`;
  const response = await fetch(url);
  if (!response.ok) fail(`could not download ${file} from the ${tag} release (${response.status}). Has the Release workflow finished?`);
  const path = join(dir, file);
  writeFileSync(path, Buffer.from(await response.arrayBuffer()));
  console.log(`publishing ${name}@${version}`);
  const result = npm(["publish", path, "--access", "public", "--ignore-scripts"], { stdio: "inherit" });
  if (result.status !== 0) fail(`npm refused ${name}. Fix that and run npm publish again; finished ones are skipped.`);
}

console.log(`platform packages ready; publishing ${pkg.name}@${version}`);
