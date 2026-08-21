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

const VERSION = "0.1.8";

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

  const shutdown = async (): Promise<void> => {
    await bridgeServer.close();
    await server.close();
    process.exit(0);
  };
  process.on("SIGINT", () => void shutdown());
  process.on("SIGTERM", () => void shutdown());

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
