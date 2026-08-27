#!/usr/bin/env node
import { execFileSync } from "node:child_process";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { DEFAULT_PORT, startBridgeServer } from "./bridge/server.js";
import type { ToolContext } from "./lib/tool.js";
import { registerDiscoverTools } from "./tools/discover.js";
import { registerInstanceTools } from "./tools/instances.js";
import { registerDebugTools } from "./tools/debug.js";
import { registerExecTools } from "./tools/exec.js";
import { registerPerfTools } from "./tools/perf.js";
import { registerPlaytestTools } from "./tools/playtest.js";
import { registerScreenshotTools } from "./tools/screenshot.js";
import { registerWorldTools } from "./tools/world.js";
import { registerCharacterTools } from "./tools/character.js";
import { registerScriptTools } from "./tools/scripts.js";
import { registerSessionTools } from "./tools/session.js";
import { registerInputTools } from "./tools/input.js";
import { registerDeviceTools } from "./tools/device.js";
import { registerApiTools } from "./tools/api.js";
import { registerResources } from "./resources.js";

const VERSION = "0.2.6";

function parsePort(argv: string[]): number {
  const flag = argv.indexOf("--port");
  const raw =
    flag !== -1 ? argv[flag + 1] : process.env["ROBLOX_STUDIO_MCP_PORT"];
  const port = raw ? Number.parseInt(raw, 10) : DEFAULT_PORT;
  if (!Number.isInteger(port) || port < 1 || port > 65535) {
    throw new Error(`Invalid port: ${raw}`);
  }
  return port;
}

/**
 * Builds the Studio plugin and copies it into the local plugins folder.
 *
 * Without this the npm package is only half of what someone needs: the server
 * installs with `npx` and the plugin is only reachable by cloning the repo,
 * which is a strange thing to ask of someone who just installed a package.
 *
 * The work is delegated to `scripts/install-plugin.mjs` rather than reimplemented
 * here, because Studio's plugins directory differs per platform and two copies of
 * that knowledge is one too many. That script is shipped in the package.
 */
function installPlugin(): void {
  const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
  execFileSync(process.execPath, [join(root, "scripts", "install-plugin.mjs")], {
    stdio: "inherit",
  });
  process.stderr.write(
    "Studio plugin installed. Open Studio and look for the Studio MCP button.\n",
  );
}

/**
 * How often to check the MCP client that spawned this process is still alive.
 *
 * Slow on purpose: this only has to beat "forever", and the cost of being wrong
 * about a recycled pid is shutting down a server somebody is using.
 */
const ORPHAN_CHECK_MS = 60_000;

async function main(): Promise<void> {
  if (process.argv.includes("--install-plugin")) {
    installPlugin();
    return;
  }

  const bridgeServer = await startBridgeServer({ port: parsePort(process.argv) });

  const server = new McpServer(
    { name: "roblox-studio-mcp", version: VERSION },
    {
      instructions:
        "Drives a live Roblox Studio session through a companion plugin.\n\n" +
        "Start with `studio_status` to confirm Studio is connected. Instances are " +
        "addressed by dot-notation path from the DataModel root, e.g. " +
        '"Workspace.Map.Spawn" or "ServerScriptService.Systems.Combat". Paths are ' +
        "case-sensitive.\n\n" +
        "The user may have several Studio windows open on different places. When " +
        "more than one is connected, no place is targeted by default and tools " +
        "refuse with AMBIGUOUS_STUDIO: call `list_studios`, ask the user which " +
        "place they mean, then `set_active_studio`. Do the same whenever they " +
        "mention their other place — never assume a switch.\n\n" +
        "Prefer the batch tools: `create`, `modify`, `delete`, `move` and " +
        "`script_edit` all take arrays and apply as a single undo step, so one " +
        "call beats a loop of calls both in latency and in how cleanly the user " +
        "can revert your work. Reach for `execute_luau` only when no dedicated " +
        "tool fits — it is the escape hatch, not the default.",
    },
  );

  const context: ToolContext = { server, bridge: bridgeServer.bridge };
  registerSessionTools(context);
  registerDiscoverTools(context);
  registerScriptTools(context);
  registerInstanceTools(context);
  registerPerfTools(context);
  registerPlaytestTools(context);
  registerExecTools(context);
  registerDebugTools(context);
  registerScreenshotTools(context);
  registerInputTools(context);
  registerDeviceTools(context);
  registerApiTools(context);
  registerWorldTools(context);
  registerCharacterTools(context);
  registerResources(context);

  /**
   * Leaves the bridge cleanly, however this process is asked to stop.
   *
   * Guarded because the paths overlap: an MCP client that quits closes stdin,
   * which closes the transport, which fires `onclose` -- and the same quit
   * often sends a signal too. Running the teardown twice would race the socket
   * close against itself for no benefit.
   */
  let stopping = false;
  const shutdown = async (): Promise<void> => {
    if (stopping) return;
    stopping = true;
    // Said before the server goes down, because when this process is proxying
    // to another one, the owner is still there to hear it -- and telling it is
    // what makes the Studio console report the agent as finished at the moment
    // it finished, rather than when the staleness reaper notices.
    await bridgeServer.bridge.goodbye();
    await bridgeServer.close();
    await server.close();

    /*
     * Set rather than called, so the process ends by running out of work.
     *
     * `process.exit` here aborted on Windows -- "Assertion failed:
     * !(handle->flags & UV_HANDLE_CLOSING), src\win\async.c" -- because the
     * stdin-end path calls this while libuv is still tearing that handle down,
     * and exiting mid-teardown trips the assertion. The goodbye had already
     * been sent by then, so the crash cost nothing but an alarming exit code;
     * it is still not something to ship. Everything this process owns is closed
     * or unref'd by the time we get here, so there is nothing left to run and
     * it exits on its own.
     */
    process.exitCode = 0;
  };
  process.on("SIGINT", () => void shutdown());
  process.on("SIGTERM", () => void shutdown());

  /*
   * The client hanging up is the one unambiguous "this agent is done".
   *
   * Hooked on stdin rather than on the transport or the server, because neither
   * of those fires. `StdioServerTransport` subscribes to `data` and `error` on
   * stdin and to nothing else, so EOF never closes it and `onclose` is never
   * called; `connect` also overwrites `transport.onclose` with its own handler,
   * so setting it beforehand achieves nothing either. Both were tried against a
   * real peer before this was, and the count stayed up in both cases.
   *
   * Registering here also matters for a second reason. A proxying instance owns
   * no listening socket, so when stdin ends there is nothing ref'd left to hold
   * the event loop open and the process exits immediately. Starting the goodbye
   * from inside this callback gets a request in flight while the loop is still
   * turning, and that in-flight request is itself what keeps the process alive
   * long enough to finish sending it.
   */
  process.stdin.on("end", () => void shutdown());

  /*
   * The same hang-up, for a client that was killed rather than closed.
   *
   * `end` covers a clean exit. It does not cover the parent dying without its
   * side of the pipe being closed -- and when that happens this process lives
   * on forever: it keeps the bridge port bound, and `LocalBridge` keeps
   * re-registering it every 30s, so the staleness reaper never sweeps it and
   * the Studio console shows an agent that left hours ago. Found exactly that
   * way: two server processes alive, the older one from a session that had
   * long since ended, and the panel truthfully reporting two clients.
   *
   * Guarded on stdin being a pipe. That is what says an MCP client is driving
   * this process, and it keeps the check away from a server started detached
   * from a shell that exits immediately -- there, a vanished parent is normal
   * and shutting down would be the bug.
   */
  if (!process.stdin.isTTY && process.ppid > 0) {
    const parent = process.ppid;
    const orphanWatch = setInterval(() => {
      try {
        // Signal 0 tests for existence without delivering anything.
        process.kill(parent, 0);
      } catch {
        clearInterval(orphanWatch);
        void shutdown();
      }
    }, ORPHAN_CHECK_MS);
    orphanWatch.unref();
  }

  // stdout belongs to the MCP transport from here on; nothing else may write to it.
  await server.connect(new StdioServerTransport());
}

main().catch((cause: unknown) => {
  process.stderr.write(
    `roblox-studio-mcp failed to start: ${
      cause instanceof Error ? cause.message : String(cause)
    }\n`,
  );
  process.exit(1);
});
