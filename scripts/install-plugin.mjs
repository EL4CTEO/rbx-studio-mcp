/**
 * Builds the plugin and drops it into the local Roblox Studio plugins folder.
 *
 * Studio watches that directory and hot-reloads, so re-running this while Studio
 * is open picks up the new build without a restart.
 *
 * Usage: node scripts/install-plugin.mjs
 */
import { execFileSync } from "node:child_process";
import { copyFileSync, existsSync, mkdirSync } from "node:fs";
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
copyFileSync(built, join(target, "StudioMCP.rbxmx"));
