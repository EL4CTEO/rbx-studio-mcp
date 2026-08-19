/**
 * Runs the plugin's unit tests outside Roblox Studio.
 *
 * The modules under test import their dependencies with `require(script.Parent.X)`,
 * which only resolves inside Studio. Rather than mock the engine, this bundles
 * the real module source with a stub for its one dependency and runs the result
 * through the standalone Luau interpreter, so the tests exercise the shipped
 * code rather than a copy of it.
 *
 * Needs the `luau` binary on PATH, or its path in the LUAU environment variable.
 * Get one from https://github.com/luau-lang/luau/releases.
 *
 * Usage: node scripts/test-plugin.mjs
 */
import { spawnSync } from "node:child_process";
import { mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const luau = process.env["LUAU"] ?? "luau";

/** Modules under test, paired with the test file that exercises each. */
const suites = [{ module: "plugin/src/TextEdit.luau", test: "tests/textedit.luau" }];

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
    "local Module = (function()",
    moduleSource,
    "end)()",
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

process.exit(failures === 0 ? 0 : 1);
