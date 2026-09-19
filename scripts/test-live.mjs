#!/usr/bin/env node
/**
 * Drives a real, connected Studio through the running bridge and checks the
 * paths no fake can: big payloads over the actual stream, and scripts that
 * survive a create -> read -> edit -> delete round trip.
 *
 * Not part of `npm test`, because it needs Studio open with the plugin. It
 * exists because the worst transport bug this project had -- any command the
 * stream delivered in more than one piece was dropped, so a big `script_create`
 * timed out -- passed every offline test and only showed up against Studio.
 *
 * Everything it makes is named `__mcp_live_*` under ServerScriptService and is
 * deleted before it exits, pass or fail.
 *
 * Usage: node scripts/test-live.mjs [--port 44755] [--sizes 1000,16000,64000,256000]
 */
import { expectedPluginBuildId } from "../dist/lib/pluginbuild.js";

const args = process.argv.slice(2);
const flag = (name, fallback) => {
  const at = args.indexOf(`--${name}`);
  return at === -1 ? fallback : args[at + 1];
};
const port = Number.parseInt(flag("port", "44755"), 10);
const sizes = flag("sizes", "1000,16000,64000,256000").split(",").map(Number);
const base = `http://127.0.0.1:${port}`;
const HEADERS = {
  "x-roblox-studio-mcp": "test-live",
  "x-roblox-studio-mcp-peer": `test-live-${process.pid}`,
  "content-type": "application/json",
};
const PREFIX = "__mcp_live_";

async function call(op, params, timeoutMs = 20_000) {
  const response = await fetch(`${base}/call`, {
    method: "POST",
    headers: HEADERS,
    body: JSON.stringify({ op, params, timeoutMs }),
  });
  const body = await response.json();
  if (!body.ok) throw new Error(`${op}: [${body.error?.code}] ${body.error?.message}`);
  return body.data;
}

/** Luau source of about `size` bytes, with quotes and non-ASCII so escaping is exercised. */
function sourceOf(size) {
  const lines = [];
  let length = 0;
  for (let index = 0; length < size; index += 1) {
    const line = `local value${index} = "line ${index}: \\"quoted\\" ünïcode ✓"`;
    lines.push(line);
    length += line.length + 1;
  }
  return lines.join("\n");
}

let sessions;
try {
  sessions = await (await fetch(`${base}/sessions`, { headers: HEADERS })).json();
} catch {
  process.stderr.write(`Nothing is listening on port ${port}. Start the MCP server and open Studio.\n`);
  process.exit(1);
}
const studio = sessions.list[0];
if (studio === undefined) {
  process.stderr.write("The bridge is up but no Studio is connected.\n");
  process.exit(1);
}
if (studio.buildId !== expectedPluginBuildId()) {
  process.stderr.write(
    `warning: Studio runs plugin build ${studio.buildId}, this checkout is ` +
      `${expectedPluginBuildId()}. Results describe the plugin Studio has loaded.\n`,
  );
}
process.stdout.write(`Studio: ${studio.placeName} (${studio.transport})\n`);

const created = [];
let failures = 0;
const check = (ok, what) => {
  process.stdout.write(`${ok ? "ok  " : "FAIL"}  ${what}\n`);
  if (!ok) failures += 1;
};

try {
  for (const size of sizes) {
    const name = `${PREFIX}${size}`;
    const source = sourceOf(size);
    const started = Date.now();
    try {
      await call("script.create", {
        scripts: [{ parent: "ServerScriptService", name, className: "ModuleScript", source }],
      });
      created.push(`ServerScriptService.${name}`);
      const read = await call("script.read", { paths: [`ServerScriptService.${name}`] });
      const item = read.items[0];
      check(item?.source === source, `${size} bytes: create + read back identical (${Date.now() - started}ms)`);

      const edited = await call("script.edit", {
        edits: [{ path: `ServerScriptService.${name}`, find: "local value0 =", replace: "local first =", revision: item.revision }],
      });
      check(edited.items[0]?.edits === 1, `${size} bytes: conditional edit applied`);
    } catch (cause) {
      check(false, `${size} bytes: ${cause.message}`);
    }
  }
} finally {
  if (created.length > 0) {
    await call("instances.delete", { paths: created }).catch((cause) => {
      process.stderr.write(`cleanup failed, delete ${created.join(", ")} by hand: ${cause.message}\n`);
    });
  }
}

process.stdout.write(failures === 0 ? "live: ok\n" : `live: ${failures} failure(s)\n`);
process.exit(failures === 0 ? 0 : 1);
