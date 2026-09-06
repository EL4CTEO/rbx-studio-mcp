import { existsSync, readFileSync, statSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { CLIENT_HEADER, PROTOCOL_VERSION } from "./lib/protocol.js";
import type { StudioSession } from "./lib/protocol.js";
import { probeOwner } from "./bridge/remote.js";

/**
 * Answers "why is this not working" without anyone having to guess.
 *
 * Every failure this checks for has been reported at least once, and every one
 * of them looked like something else at the time: a plugin that never loaded
 * reads as a bridge problem, a stale plugin reads as a broken tool, and a
 * second server holding the port reads as nothing at all. Each check therefore
 * ends in an instruction rather than a verdict -- "not connected" is where the
 * old confusion started, not where it ended.
 */

type Status = "ok" | "warn" | "bad";

interface Check {
  status: Status;
  title: string;
  detail: string;
}

const MARK: Record<Status, string> = { ok: "PASS", warn: "WARN", bad: "FAIL" };

/** Studio's per-user plugin directory, which differs per platform. */
function pluginsDir(): string | null {
  if (process.platform === "win32") {
    const local = process.env["LOCALAPPDATA"] ?? join(homedir(), "AppData", "Local");
    return join(local, "Roblox", "Plugins");
  }
  if (process.platform === "darwin") return join(homedir(), "Documents", "Roblox", "Plugins");
  return null;
}

function root(): string {
  return resolve(dirname(fileURLToPath(import.meta.url)), "..");
}

/** What this package would install, so an installed copy can be compared to it. */
function builtBuildId(): string | null {
  const stamp = join(root(), "build", "plugin-build-id.txt");
  if (!existsSync(stamp)) return null;
  return readFileSync(stamp, "utf8").trim();
}

function checkPluginFile(): Check {
  const dir = pluginsDir();
  if (dir === null) {
    return {
      status: "warn",
      title: "Studio plugin",
      detail:
        "Roblox Studio does not run natively on this platform, so there is no " +
        "plugins folder to check.",
    };
  }
  const file = join(dir, "StudioMCP.rbxmx");
  if (!existsSync(file)) {
    return {
      status: "bad",
      title: "Studio plugin",
      detail: `Not installed. No file at ${file}.\n  Fix: npx rbx-studio-mcp --install-plugin`,
    };
  }
  const age = statSync(file).mtime.toISOString().slice(0, 16).replace("T", " ");
  return { status: "ok", title: "Studio plugin", detail: `Installed ${age} at ${file}` };
}

/**
 * Whether something is on the port, and whether it is one of us.
 *
 * The distinction is the whole value of this check. Nothing listening and a
 * stranger listening produce the same symptom in Studio -- a console that will
 * not connect -- and opposite fixes.
 */
async function checkPort(port: number): Promise<Check> {
  const owner = await probeOwner(port);
  if (owner === null) {
    return {
      status: "warn",
      title: `Bridge on 127.0.0.1:${port}`,
      detail:
        "Nothing answering, or something that is not this server.\n" +
        "  That is normal if no agent is running: the server starts when your " +
        "MCP client launches it.\n" +
        "  If an agent IS running, something else holds the port. Start with " +
        "--port <other> and set the same port in the Studio panel.",
    };
  }
  const drift =
    owner.protocolVersion === PROTOCOL_VERSION
      ? ""
      : `\n  Protocol ${owner.protocolVersion} vs this build's ${PROTOCOL_VERSION}.`;
  return {
    status: "ok",
    title: `Bridge on 127.0.0.1:${port}`,
    detail: `Answering, owned by pid ${owner.pid}.${drift}`,
  };
}

/** Asks the running bridge which Studios it can see, and whether they are current. */
async function checkStudios(port: number, built: string | null): Promise<Check[]> {
  let sessions: StudioSession[];
  try {
    const response = await fetch(`http://127.0.0.1:${port}/sessions`, {
      headers: { [CLIENT_HEADER]: "doctor" },
      signal: AbortSignal.timeout(5_000),
    });
    sessions = ((await response.json()) as { list: StudioSession[] }).list;
  } catch {
    return [];
  }

  if (sessions.length === 0) {
    return [
      {
        status: "bad",
        title: "Studio sessions",
        detail:
          "The bridge is up but no Studio is connected.\n" +
          "  Open Studio. If it is already open, click the Studio MCP toolbar " +
          "button and check the console panel; use its reconnect button.\n" +
          "  If Studio asked for permission to reach 127.0.0.1, it must be allowed.",
      },
    ];
  }

  return sessions.map((session) => {
    // A plugin built from different sources answers with older handlers and no
    // other symptom, which is the hardest failure here to recognise from inside.
    const stale = built !== null && session.buildId !== built;
    return {
      status: stale ? "warn" : "ok",
      title: `Studio: ${session.placeName}`,
      detail: stale
        ? `Plugin build ${session.buildId} does not match this package's ${built}.\n` +
          "  Fix: npx rbx-studio-mcp --install-plugin, then restart Studio."
        : `${session.context ?? "edit"}, over ${session.transport}, plugin ${session.pluginVersion}`,
    };
  });
}

function checkNode(): Check {
  const [major, minor] = process.versions.node.split(".").map(Number);
  const enough = (major ?? 0) > 22 || ((major ?? 0) === 22 && (minor ?? 0) >= 15);
  return {
    status: enough ? "ok" : "bad",
    title: "Node",
    detail: enough
      ? `v${process.versions.node}`
      : `v${process.versions.node} is below the required 22.15.`,
  };
}

/**
 * Confirms the Luau toolchain the plugin build needs, without failing over it.
 *
 * Presence is checked by looking, not by running: `luau --version` is not a
 * flag it accepts, so asking cost a line of error output and a warning that was
 * simply wrong. What this needs to know is whether the file is there.
 */
function checkLuau(): Check {
  const exe = process.platform === "win32" ? ".exe" : "";
  const missing = ["luau", "luau-analyze"].filter(
    (tool) => !existsSync(join(root(), "tools", tool + exe)),
  );
  if (missing.length === 0) {
    return { status: "ok", title: "Luau tools", detail: "Present, so the plugin can be rebuilt." };
  }
  return {
    status: "warn",
    title: "Luau tools",
    detail:
      `Missing from ./tools: ${missing.join(", ")}. Only needed to rebuild the ` +
      "plugin from source; installing the published build does not use them.",
  };
}

export async function runDoctor(port: number): Promise<void> {
  const built = builtBuildId();
  const checks: Check[] = [checkNode(), checkLuau(), checkPluginFile(), await checkPort(port)];
  checks.push(...(await checkStudios(port, built)));

  const lines = checks.map((check) => `[${MARK[check.status]}] ${check.title}\n  ${check.detail}`);
  const bad = checks.filter((check) => check.status === "bad").length;
  const warn = checks.filter((check) => check.status === "warn").length;

  // stdout, not stderr: this is the command's output, and unlike every other
  // path in this process there is no MCP transport here to keep it clear for.
  process.stdout.write(
    `${lines.join("\n\n")}\n\n${checks.length - bad - warn} passed, ${warn} warning(s), ${bad} failure(s)\n`,
  );
  process.exitCode = bad > 0 ? 1 : 0;
}
