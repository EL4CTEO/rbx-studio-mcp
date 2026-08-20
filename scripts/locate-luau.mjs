/**
 * Finds a Luau binary, the same way for every script that needs one.
 *
 * This is shared because it once was not. `check-plugin.mjs` looked in ./tools
 * and `test-plugin.mjs` looked only on PATH, so on a machine with the binaries
 * unpacked into ./tools -- which is what the README tells you to do -- one of
 * them worked and the other reported the interpreter missing. The tests were
 * not failing; they were not running, and saying so in a way that read like a
 * setup problem the user had already solved.
 *
 * Order is: explicit environment variable, then ./tools, then PATH. The env var
 * wins because someone who set it means it.
 */
import { spawnSync } from "node:child_process";
import { existsSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");

/**
 * @param {string} envVar name of the environment variable that overrides the search
 * @param {string[]} names candidate executable names, most specific first
 * @returns {string | null} a command that runs, or null
 */
export function locateLuau(envVar, names) {
  const fromEnv = process.env[envVar];
  if (fromEnv) return fromEnv;

  for (const name of names) {
    const local = join(root, "tools", name);
    if (existsSync(local)) return local;
  }

  for (const name of names) {
    // `--help` rather than `--version`: every one of these supports it, and a
    // binary that is present but refuses to start should not count as found.
    const probe = spawnSync(name, ["--help"], { encoding: "utf8" });
    if (!probe.error) return name;
  }

  return null;
}

/** The message to print when `locateLuau` comes back empty. */
export function missingLuau(what, envVar) {
  return (
    `No ${what} found. Put it on PATH or in ./tools, or set ${envVar}.\n` +
    "Download: https://github.com/luau-lang/luau/releases\n"
  );
}
