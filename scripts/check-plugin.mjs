/**
 * Compiles every plugin source file, so a broken one is caught here rather than
 * in Studio.
 *
 * This exists because the feedback loop without it is terrible. Nothing in the
 * Node build reads the Luau at all -- `build:plugin` packs the files into an
 * .rbxmx as text -- so a syntax error ships, installs, and is only discovered
 * when the user focuses Studio and the plugin fails to load. It cost two
 * sessions in one afternoon: a literal newline written into a string where an
 * escape was meant, and a closure that captured a nil global because it sat
 * above the forward declaration of the local it meant to call. The first is a
 * compile error and would have been caught instantly by this. The second is not,
 * which is why `--!strict` analysis runs too when the analyser is available:
 * an unknown global is exactly what it flags.
 *
 * Needs `luau-compile` (and ideally `luau-analyze`) on PATH, in ./tools, or
 * named by the LUAU_COMPILE / LUAU_ANALYZE environment variables. Get them from
 * https://github.com/luau-lang/luau/releases.
 *
 * Silent and exit 0 when everything compiles; prints what failed otherwise.
 *
 * Usage: node scripts/check-plugin.mjs
 */
import { spawnSync } from "node:child_process";
import { readdirSync, statSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { locateLuau, missingLuau } from "./locate-luau.mjs";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");

function luauFiles(directory) {
  const found = [];
  for (const entry of readdirSync(directory)) {
    const path = join(directory, entry);
    if (statSync(path).isDirectory()) found.push(...luauFiles(path));
    else if (entry.endsWith(".luau")) found.push(path);
  }
  return found;
}

const compiler = locateLuau("LUAU_COMPILE", ["luau-compile.exe", "luau-compile"]);
if (compiler === null) {
  process.stderr.write(
    "No luau-compile found. Put it on PATH or in ./tools, or set LUAU_COMPILE.\n" +
      "Download: https://github.com/luau-lang/luau/releases\n",
  );
  process.exit(1);
}

const files = luauFiles(join(root, "plugin", "src"));
const failures = [];

for (const file of files) {
  // --binary throws the bytecode away; only the exit status and diagnostics
  // matter, and writing it anywhere would just be litter to clean up.
  const result = spawnSync(compiler, ["--binary", file], { encoding: "utf8" });
  const diagnostics = `${result.stderr ?? ""}${result.status === 0 ? "" : (result.stdout ?? "")}`.trim();
  if (result.status !== 0 || diagnostics.length > 0) {
    failures.push(`${file.slice(root.length + 1)}\n${diagnostics}`);
  }
}

/*
 * One diagnostic from the analyser, deliberately.
 *
 * `LocalShadow` is reported when a name is used as a global and a local of that
 * same name is declared later in the file -- which is the shape of the bug this
 * check was written for, and is unambiguous. Running the analyser without
 * Roblox's type definitions also reports every engine global as unknown, so
 * `script`, `task`, `Color3` and friends produce hundreds of lines of noise;
 * filtering to this one diagnostic gets the signal without needing a
 * definitions file that would then have to be kept current with the engine.
 */
/*
 * Diagnostics about a table this file declares its own type for.
 *
 * The LocalShadow filter was the only thing let through, and that let a whole
 * class of error ship: a field read or written on a `--!strict` table type that
 * does not declare it. The plugin failed to load on the first line it logged --
 * "attempt to perform arithmetic on nil" -- because a batch of edits added five
 * uses of `state.entries` and the edit declaring it never landed. The analyser
 * had said so, four times, and this script threw it away.
 *
 * These two patterns are safe to surface where the rest is not. Without Roblox
 * type definitions the analyser cannot know what `Instance` or `Color3` are, so
 * it reports engine globals in their hundreds -- but those come out as unknown
 * *globals* and unknown *types*. A key missing from a named table type can only
 * be a table this file declared itself.
 */
const TYPE_PATTERNS = [/Key '[^']+' not found in table/, /Cannot add property '[^']+' to table/];

const analyser = locateLuau("LUAU_ANALYZE", ["luau-analyze.exe", "luau-analyze"]);
const shadowed = [];
const mistyped = [];
if (analyser !== null) {
  for (const file of files) {
    const result = spawnSync(analyser, [file], { encoding: "utf8" });
    const output = `${result.stdout ?? ""}${result.stderr ?? ""}`;
    for (const line of output.split("\n")) {
      if (line.includes("LocalShadow:")) shadowed.push(line.trim());
      else if (TYPE_PATTERNS.some((pattern) => pattern.test(line))) mistyped.push(line.trim());
    }
  }
}

if (failures.length > 0) {
  process.stderr.write(`${failures.join("\n\n")}\n`);
}
if (shadowed.length > 0) {
  process.stderr.write(
    "\nA local is used before it is declared, so the call reaches a nil global " +
      "instead:\n" +
      `${shadowed.join("\n")}\n`,
  );
}
if (mistyped.length > 0) {
  process.stderr.write(
    "\nA field is used on a table whose type does not declare it. It is nil at " +
      "runtime, and the plugin fails the first time that line runs:\n" +
      `${mistyped.join("\n")}
`,
  );
}
process.exit(failures.length > 0 || shadowed.length > 0 || mistyped.length > 0 ? 1 : 0);
