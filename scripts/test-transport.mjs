/**
 * Exercises the plugin's SSE frame parser outside Studio.
 *
 * `Transport.luau` cannot be loaded whole by the interpreter -- it reaches for
 * HttpService at module scope -- and `parseFrames` is a local, so neither the
 * existing bundling harness nor a plain require can get at it. It is lifted out
 * of the real file by name instead, so this cannot quietly drift from what ships:
 * rename or delete the function and the extraction fails the test run.
 *
 * The bug it covers cost a session to find and would have been invisible in
 * review. Two SSE writes in the same tick arrive as one chunk, and the old
 * parser JSON-decoded the whole chunk, so BOTH frames were dropped. It showed up
 * as a client-count badge that would not come back down; the part that mattered
 * is that a command sharing a chunk with a keepalive would have vanished the
 * same way, losing a tool call with no error at either end.
 *
 * Usage: node scripts/test-transport.mjs
 */
import { spawnSync } from "node:child_process";
import { mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { locateLuau, missingLuau } from "./locate-luau.mjs";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const luau = locateLuau("LUAU", ["luau.exe", "luau"]);
if (luau === null) {
  process.stderr.write(missingLuau("luau", "LUAU"));
  process.exit(1);
}

/** Lifts one top-level `local function` out of a module, body and all. */
function extractFunction(source, name) {
  // Normalised first: the plugin sources are CRLF and every anchor here is LF.
  const text = source.split(String.fromCharCode(13, 10)).join(String.fromCharCode(10));
  const opener = `local function ${name}(`;
  const start = text.indexOf(opener);
  if (start === -1) throw new Error(`${name} is not in Transport.luau any more`);
  const closer = String.fromCharCode(10) + 'end' + String.fromCharCode(10);
  const end = text.indexOf(closer, start);
  if (end === -1) throw new Error(`could not find the end of ${name}`);
  return text.slice(start, end + closer.length).replace(opener, `function ${name}(`);
}
const transport = readFileSync(join(root, "plugin", "src", "Transport.luau"), "utf8");
const stub = readFileSync(join(root, "tests", "jsonstub.luau"), "utf8").replace(/^return Net$/m, "");
const cases = readFileSync(join(root, "tests", "sseframes.luau"), "utf8");

const bundle = [stub, extractFunction(transport, "parseFrames"), cases].join("\n");
const bundlePath = join(mkdtempSync(join(tmpdir(), "studio-mcp-sse-")), "bundle.luau");
writeFileSync(bundlePath, bundle, "utf8");

const result = spawnSync(luau, [bundlePath], { stdio: "inherit" });
if (result.error) {
  process.stderr.write(`could not run '${luau}': ${result.error.message}\n`);
  process.exit(1);
}
process.exit(result.status ?? 1);
