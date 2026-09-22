/**
 * Runs the plugin's unit tests outside Roblox Studio.
 *
 * The modules under test import their dependencies with `require(script.Parent.X)`,
 * which only resolves inside Studio. Rather than mock the engine, this bundles
 * the real module source with a stub for its one dependency and runs the result
 * through the standalone Luau interpreter, so the tests exercise the shipped
 * code rather than a copy of it.
 *
 * Needs the `luau` binary on PATH, in ./tools, or named by the LUAU variable.
 * Get one from https://github.com/luau-lang/luau/releases.
 *
 * Usage: node scripts/test-plugin.mjs
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

/** Modules under test, paired with the test file that exercises each. */
const suites = [
  { module: "plugin/src/handlers/Playtest.luau", test: "tests/playtests.luau", prelude: "tests/playtests-stub.luau" },
  { module: "plugin/src/Commands.luau", test: "tests/playtests-commands.luau", prelude: "tests/playtests-stub.luau", dependency: "plugin/src/handlers/Playtest.luau" },
  { module: "plugin/src/RemoteTrace.luau", test: "tests/remote-trace.luau", prelude: "tests/remote-trace-stub.luau" },
  { module: "plugin/src/ExecRuntime.luau", test: "tests/exec-runtime.luau", prelude: "tests/exec-runtime-stub.luau" },
  { module: "plugin/src/ClientRelay.luau", test: "tests/client-relay.luau", prelude: "tests/client-relay-stub.luau" },
  { module: "plugin/src/LogBuffer.luau", test: "tests/log-buffer.luau", prelude: "tests/log-buffer-stub.luau" },
  { module: "plugin/src/handlers/Perf.luau", test: "tests/perf-console.luau", prelude: "tests/perf-console-stub.luau" },
  { module: "plugin/src/TextEdit.luau", test: "tests/textedit.luau" },
  { module: "plugin/src/Format.luau", test: "tests/format.luau" },
];

/**
 * The stub stands in for Dispatch. It has to raise the same structured table the
 * real one does, because the tests assert on `code` -- that contract is what the
 * MCP server turns into an actionable error for the agent.
 */
const DISPATCH_STUB = `local Dispatch = {}
function Dispatch.fail(code, message, hint)
\terror({ code = code, message = message, hint = hint }, 0)
end
`;

/** Drops the module's own requires; the stub above is already in scope. */
const stripRequires = (source) =>
  source.replace(/^local \w+ = require\(script[^\n]*\n/gm, "");

let failures = 0;

for (const suite of suites) {
  const moduleSource = stripRequires(readFileSync(join(root, suite.module), "utf8"));
  const testSource = readFileSync(join(root, suite.test), "utf8");

  const bundle = [
    DISPATCH_STUB,
    suite.prelude ? readFileSync(join(root, suite.prelude), "utf8") : "",
    suite.dependency ? `local Playtest = (function()\n${stripRequires(readFileSync(join(root, suite.dependency), "utf8"))}\nend)()` : "",
    "local function loadModule()",
    moduleSource,
    "end",
    "local Module = loadModule()",
    "local run = function(...)",
    testSource,
    "end",
    "run(Module)",
    "",
  ].join("\n");

  const bundlePath = join(mkdtempSync(join(tmpdir(), "studio-mcp-test-")), "bundle.luau");
  writeFileSync(bundlePath, bundle, "utf8");

  const result = spawnSync(luau, [bundlePath], { stdio: "inherit" });
  if (result.error) {
    process.stderr.write(
      `could not run '${luau}': ${result.error.message}\n` +
        "Set LUAU to the path of a Luau interpreter.\n",
    );
    process.exit(1);
  }
  if (result.status !== 0) {
    process.stderr.write(`FAIL ${suite.test}\n`);
    failures += 1;
  }
}

// Embedded LocalScript bodies must compile too; the module compiler sees strings.
for (const name of ["Exec", "Input", "Debug"]) {
  const source = readFileSync(join(root, `plugin/src/handlers/${name}.luau`), "utf8");
  const relay = source.match(/\[==\[([\s\S]*?)\]==\]/)?.[1];
  if (!relay) throw new Error(`Missing ${name} relay`);
  const path = join(mkdtempSync(join(tmpdir(), "studio-mcp-relay-")), "compile.luau");
  writeFileSync(path, `local chunk, err = loadstring(${JSON.stringify(relay)})\nassert(chunk, err)\n`);
  if (spawnSync(luau, [path], {stdio:"inherit"}).status !== 0) failures += 1;
}

process.exit(failures === 0 ? 0 : 1);
