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
import { readdirSync, readFileSync, statSync } from "node:fs";
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
// Without Roblox definitions, allow the engine globals explicitly. Everything
// else is still a real missing local (e.g. a constant lost during extraction).
const ENGINE_GLOBALS = new Set([
  "game", "workspace", "script", "plugin", "task", "Enum", "Instance", "settings", "version", "warn",
  "Vector2", "Vector3", "CFrame", "UDim", "UDim2", "Color3", "BrickColor", "Font", "Content",
  "ColorSequence", "ColorSequenceKeypoint", "NumberSequence", "NumberSequenceKeypoint", "NumberRange",
  "Rect", "Region3", "Ray", "RaycastParams", "OverlapParams", "PhysicalProperties", "TweenInfo",
  "DateTime", "DockWidgetPluginGuiInfo", "Random", "Axes", "Faces", "Vector3int16", "Region3int16",
]);
const unknownGlobals = [];
if (analyser !== null) {
  for (const file of files) {
    const result = spawnSync(analyser, [file], { encoding: "utf8" });
    const output = `${result.stdout ?? ""}${result.stderr ?? ""}`;
    for (const line of output.split("\n")) {
      if (line.includes("LocalShadow:")) shadowed.push(line.trim());
      else if (TYPE_PATTERNS.some((pattern) => pattern.test(line))) mistyped.push(line.trim());
      const unknown = /Unknown global '([^']+)'/.exec(line);
      if (unknown && !ENGINE_GLOBALS.has(unknown[1])) unknownGlobals.push(line.trim());
    }
  }
}

/*
 * Every operation the plugin answers has to have a readable name in the panel.
 *
 * `Phrase` falls back to tidying the wire name, so a missing entry is invisible
 * in testing and only shows up as "Data set" where "SAVE over 4212 in PlayerData"
 * belonged. Left unchecked it rots by default: 26 of 72 operations had drifted
 * out of the table, which is every tool added after the table was written. A
 * missing KIND is worse than cosmetic -- the fallback is "read", so an
 * unregistered terrain wipe was announced with the weight of an inspect.
 */
const unnamed = [];
const kindless = new Set();
{
  const phrase = readFileSync(join(root, "plugin", "src", "Phrase.luau"), "utf8");
  const described = new Set([...phrase.matchAll(/\["([^"]+)"\]\s*=\s*function/g)].map((m) => m[1]));
  const kinds = new Set([...phrase.matchAll(/^\t([a-z]+) = "/gm)].map((m) => m[1]));
  // `script` is split by action inside Phrase.kindOf rather than by a table row.
  kinds.add("script");

  for (const file of files) {
    const source = readFileSync(file, "utf8");
    for (const block of source.matchAll(/Dispatch\.registerAll\("([^"]+)",\s*\{([\s\S]*?)\n\t\}\)/g)) {
      const group = block[1];
      if (!kinds.has(group)) kindless.add(group);
      for (const entry of block[2].matchAll(/^\s*([A-Za-z0-9_]+)\s*=/gm)) {
        const op = `${group}.${entry[1]}`;
        if (!described.has(op)) unnamed.push(op);
      }
    }
  }
}

/*
 * A module cloned into a client relay has to bring everything it requires.
 *
 * The relay is a LocalScript in the player's client VM, where the plugin's own
 * module tree does not exist, so `require(script.Parent.X)` inside a cloned module
 * finds only what was cloned beside it. ExecRuntime gained a `LogBuffer` require
 * and the list of modules the exec relay clones did not, so every
 * `execute_luau target="client"` failed with "Requested module experienced an
 * error while loading" -- from a client VM nothing offline ever runs, and not
 * noticed until a live playtest. Each clone list is checked here against the
 * `require(script.Parent.X)` calls of the modules it names, transitively.
 */
const missingClones = [];
{
  const modules = new Map(
    files.map((file) => [
      file.replace(/\\/g, "/").replace(/^.*plugin\/src\//, "").replace(/\.luau$/, ""),
      readFileSync(file, "utf8"),
    ]),
  );
  const requiresOf = (name) =>
    [...(modules.get(name) ?? "").matchAll(/require\(script(?:\.Parent){1,2}\.([\w.]+)\)/g)]
      .map((m) => m[1].replace(/^Handlers\./, "handlers.").replaceAll(".", "/"));

  for (const [where, source] of modules) {
    for (const list of source.matchAll(
      /for _, name in \{([^}]*)\} do\s*local copy = script(?:\.Parent){1,2}\[name\]:Clone\(\)/g,
    )) {
      const cloned = new Set([...list[1].matchAll(/"(\w+)"/g)].map((m) => m[1]));
      if (source.includes("script.Parent.handlers.Discover:Clone()")) cloned.add("handlers/Discover");
      const needed = new Set();
      const pending = [...cloned];
      while (pending.length > 0) {
        for (const dependency of requiresOf(pending.pop())) {
          if (!needed.has(dependency)) {
            needed.add(dependency);
            pending.push(dependency);
          }
        }
      }
      for (const dependency of needed) {
        if (!cloned.has(dependency)) {
          missingClones.push(`${where}: clones ${[...cloned].join(", ")} but they require ${dependency}`);
        }
      }
    }
  }
}
if (missingClones.length > 0) {
  failures.push(
    "A client relay clones modules that require others it does not clone, so the " +
      "relay fails to load in the client VM:\n  " +
      missingClones.sort().join("\n  "),
  );
}

if (unnamed.length > 0) {
  failures.push(
    "These operations have no entry in Phrase.luau, so the Studio panel shows " +
      "the wire name instead of saying what they touch:\n  " +
      unnamed.sort().join("\n  "),
  );
}
if (kindless.size > 0) {
  failures.push(
    "These operation groups have no entry in Phrase KINDS, so they are announced " +
      'as "read" whatever they do:\n  ' +
      [...kindless].sort().join("\n  "),
  );
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
if (unknownGlobals.length > 0) {
  process.stderr.write(`\nUnknown globals outside Roblox's engine globals:\n${unknownGlobals.join("\n")}\n`);
}
process.exit(failures.length > 0 || shadowed.length > 0 || mistyped.length > 0 || unknownGlobals.length > 0 ? 1 : 0);
