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

// Exercise the public schemas and forwarding through the real tool handlers.
const { z } = await import("zod");
const { registerExecTools } = await import("../dist/tools/exec.js");
const { registerInputTools } = await import("../dist/tools/input.js");
const registered = new Map();
const calls = [];
const context = {
  server: { registerTool(name, spec, handler) { registered.set(name, { spec, handler }); } },
  bridge: { async call(op, params, options) {
    calls.push({op, params, options});
    return op === "exec.run" ? {ok:true,returned:["nil",{answer:42}],output:[],milliseconds:1} : {delivered:true,steps:1,player:"Alice"};
  } },
};
registerExecTools(context);
registerInputTools(context);
const execute = registered.get("execute_luau");
const parsed = z.object(execute.spec.inputSchema).parse({source:"return nil",target:"client",player:"Alice",timeoutSeconds:2});
await execute.handler(parsed);
assert.equal(calls.at(-1).params.target, "client");
assert.equal(calls.at(-1).params.player, "Alice");
assert.equal(calls.at(-1).options.timeoutMs, 12000);
await execute.handler(z.object(execute.spec.inputSchema).parse({source:"return 1"}));
assert.equal(calls.at(-1).params.target, "studio");
assert.equal(calls.at(-1).options.timeoutMs, 60000);
const input = registered.get("input");
for (const step of [{kind:"click",target:"PlayerGui.HUD.BuyButton"},{kind:"text",target:"PlayerGui.HUD.NameBox",text:"hello"},{kind:"click",x:100,y:200}]) {
 await input.handler(z.object(input.spec.inputSchema).parse({steps:[step]}));
 assert.deepEqual(calls.at(-1).params.steps[0], step);
}
assert.deepEqual([...registered.keys()].sort(), ["execute_luau", "input", "viewport"]);
process.stdout.write("client tool schemas: ok\n");

const { registerDebugTools } = await import("../dist/tools/debug.js");
registerDebugTools(context);
const debug = registered.get("debug");
const remoteArgs = z.object(debug.spec.inputSchema).parse({op:"remotes",path:"ReplicatedStorage",player:"Alice",seconds:3});
await debug.handler(remoteArgs);
assert.equal(calls.at(-1).op, "debug.remotes");
assert.deepEqual(calls.at(-1).params, {path:"ReplicatedStorage",player:"Alice",seconds:3});
assert.equal(calls.at(-1).options.timeoutMs, 18000);
assert.throws(() => z.object(debug.spec.inputSchema).parse({op:"remotes",seconds:16}));
assert.deepEqual([...registered.keys()].sort(), ["debug", "execute_luau", "input", "viewport"]);
process.stdout.write("remote trace schema: ok\n");

const { registerPlaytestTools } = await import("../dist/tools/playtest.js");
registerPlaytestTools(context);
const playtest = registered.get("playtest");
for (const guidance of ["AGENTS.md", "CLAUDE.md", "user instructions", "project guidance", "even when ON", "Do not bypass"]) {
 assert.ok(playtest.spec.description.includes(guidance), `playtest guidance preserves ${guidance}`);
}
const normalCall = context.bridge.call;
context.bridge.call = async (op, params) => {
 if (["play", "run", "multiplayer"].includes(params.op)) {
  const { ToolError } = await import("../dist/lib/errors.js");
  throw new ToolError("PLAYTEST_DISABLED", "Playtests are disabled by the user.", "Do not start or simulate a playtest. Continue using edit-mode tools and static inspection where possible.\nRun `playtests on` in the Studio MCP panel to re-enable playtesting.");
 }
 return {changed:false,state:{playtestsAllowed:false}};
};
for (const op of ["play", "run", "multiplayer"]) {
 const result = await playtest.handler(z.object(playtest.spec.inputSchema).parse({op}));
 assert.equal(result.isError, true);
 assert.match(result.content[0].text, /PLAYTEST_DISABLED/);
 assert.match(result.content[0].text, /playtests on/);
}
const stateResult = await playtest.handler(z.object(playtest.spec.inputSchema).parse({op:"state"}));
assert.ok(!stateResult.isError);
context.bridge.call = normalCall;
process.stdout.write("playtest lock errors and instruction precedence: ok\n");

// OFF affects simulation starts, not the ordinary edit-mode tool paths.
const { registerDiscoverTools } = await import("../dist/tools/discover.js");
const { registerScriptTools } = await import("../dist/tools/scripts.js");
const { registerScreenshotTools } = await import("../dist/tools/screenshot.js");
registerDiscoverTools(context);
registerScriptTools(context);
registerScreenshotTools(context);
const editOps = [];
context.bridge.sessions = async () => ({list:[{studioId:"edit",context:"edit"}],activeId:"edit"});
context.bridge.call = async (op, params) => {
 editOps.push(op);
 if (op === "playtest.control") {
  if (["play", "run", "multiplayer"].includes(params.op)) throw new Error("PLAYTEST_DISABLED");
  return {changed:false,state:{playtestsAllowed:false}};
 }
 const results = {
  "exec.run": {ok:true,returned:[42],output:[],milliseconds:1},
  "discover.tree": {items:[],total:0,offset:0},
  "discover.inspect": {items:[],failures:[]},
  "script.read": {items:[],failures:[]},
  "viewport.ui": {findings:[],checked:0,hidden:0,root:"StarterGui",screen:"800x600"},
  "capture.screenshot": {encoding:"png",data:"AA==",width:1,height:1,sourceWidth:1,sourceHeight:1,bytes:1,context:"edit"},
 };
 assert.ok(op in results, `unexpected edit-mode operation ${op}`);
 return results[op];
};
for (const [name, args, expected] of [
 ["execute_luau",{source:"return 42",target:"studio"},"exec.run"],
 ["tree",{},"discover.tree"],
 ["inspect",{paths:["Workspace"],detail:"concise"},"discover.inspect"],
 ["script_read",{paths:["ServerScriptService.Example"]},"script.read"],
 ["viewport",{op:"ui",path:"StarterGui"},"viewport.ui"],
 ["screenshot",{},"capture.screenshot"],
]) {
 const tool = registered.get(name);
 const result = await tool.handler(z.object(tool.spec.inputSchema).parse(args));
 assert.ok(!result.isError, `${name} remains usable with playtests OFF: ${JSON.stringify(result)}`);
 assert.equal(editOps.at(-1),expected);
}
assert.ok(!editOps.includes("playtest.control"), "edit-mode tools never start or probe a simulation");
context.bridge.call = normalCall;
process.stdout.write("playtest lock leaves edit-mode tools available: ok\n");
