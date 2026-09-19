/**
 * Offline checks for tool output shaping that needs no Studio.
 *
 * Usage: node scripts/test-tools.mjs
 */
import assert from "node:assert/strict";
import { CHARACTER_LIMIT } from "../dist/lib/format.js";
import { clipListing, numbered } from "../dist/tools/scripts.js";

const item = (path, lineCount) => ({ path, className: "ModuleScript", lineCount, startLine: 1, source: "" });
const listing = (path, lines) =>
  `${path}  (ModuleScript, ${lines} lines)\n` +
  numbered(Array.from({ length: lines }, (_, index) => `local v${index} = ${index}`).join("\n"), 1);

// Small reads pass through untouched.
{
  const blocks = [listing("A", 3)];
  assert.equal(clipListing(blocks, [item("A", 3)], null), blocks[0]);
}

// A big read is cut on a whole line and names the exact next window.
{
  const out = clipListing([listing("Big", 5000), listing("After", 5)], [item("Big", 5000), item("After", 5)], null);
  assert.ok(out.length <= CHARACTER_LIMIT, "fits the limit");
  const match = /Big stops at line (\d+) of 5000\. Continue with \{ path: "Big", startLine: (\d+) \}/.exec(out);
  assert.ok(match, "names where to continue");
  assert.equal(Number(match[2]), Number(match[1]) + 1);
  const lastShown = out.split("\n\n[clipped")[0].split("\n").pop();
  assert.match(lastShown, new RegExp(`^\s*${match[1]}│ local v${Number(match[1]) - 1} = ${Number(match[1]) - 1}$`), "last line is whole");
  assert.match(out, /1 more script\(s\) after it were not shown/);
}

// Failures are never the part that gets clipped away.
{
  const out = clipListing([listing("Big", 5000)], [item("Big", 5000)], "Could not read 1 path(s):\n  - Nope");
  assert.ok(out.startsWith("Could not read 1 path(s)"));
}

process.stdout.write("tools: ok\n");
