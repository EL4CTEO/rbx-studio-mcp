/**
 * Builds the plugin and drops it into the local Roblox Studio plugins folder.
 *
 * Studio watches that directory and hot-reloads, so re-running this while Studio
 * is open picks up the new build without a restart.
 *
 * Usage: node scripts/install-plugin.mjs
 */
import { execFileSync } from "node:child_process";
import { copyFileSync, existsSync, mkdirSync, renameSync, rmSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const built = join(root, "build", "StudioMCP.rbxmx");

/** Studio's per-user plugin directory, which differs per platform. */
function pluginsDir() {
  if (process.platform === "win32") {
    const local = process.env.LOCALAPPDATA ?? join(homedir(), "AppData", "Local");
    return join(local, "Roblox", "Plugins");
  }
  if (process.platform === "darwin") {
    return join(homedir(), "Documents", "Roblox", "Plugins");
  }
  // Studio only ships for Windows and macOS; anything else is a Wine/Proton
  // layout we cannot guess, so make the user point us at it.
  throw new Error(
    "Roblox Studio does not run natively on this platform. Build with " +
      "`npm run build:plugin` and copy build/StudioMCP.rbxmx into your plugins folder.",
  );
}

execFileSync(process.execPath, [join(root, "scripts", "build-plugin.mjs")], { stdio: "inherit" });

const target = pluginsDir();
if (!existsSync(target)) mkdirSync(target, { recursive: true });

/*
 * Copied beside the target and renamed over it, never written in place.
 *
 * Studio watches this directory and reloads the moment the file changes, so an
 * in-place copy hands it whatever is on disk at that instant -- which, for a
 * file of this size, is regularly half of one build and none of the next. The
 * plugin then fails to parse and Studio drops it silently: no toolbar button,
 * nothing in the plugin list, and no error saying why. It reads as the plugin
 * randomly not being installed, and re-running the install "fixes" it, which is
 * exactly what you would expect from a race.
 *
 * Rename within one directory is atomic, so Studio sees the old file or the new
 * one and never the seam between them.
 */
const destination = join(target, "StudioMCP.rbxmx");
const staged = join(target, "StudioMCP.rbxmx.incoming");
try {
  copyFileSync(built, staged);
  renameSync(staged, destination);
} catch (cause) {
  rmSync(staged, { force: true });
  throw cause;
}
