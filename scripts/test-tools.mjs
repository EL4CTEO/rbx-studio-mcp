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
  bridge: { async sessions() { return {list:[]}; }, async call(op, params, options) {
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
// Issue #4: ordinary decimal holds/waits retain padding and yield whole milliseconds.
for (const steps of [
 [{kind:"key",key:"E",hold:0.1,after:4.1}, ...Array.from({length:24}, () => ({kind:"key",key:"Left",hold:0.05,after:1.065}))],
 [{kind:"key",key:"E",hold:0.05,after:1.0651}],
]) {
 await input.handler(z.object(input.spec.inputSchema).parse({steps}));
 const raw = (35 + steps.reduce((sum, step) => sum + step.hold + step.after + 0.5, 0)) * 1000;
 assert.equal(calls.at(-1).options.timeoutMs, Math.ceil(raw));
 assert.ok(Number.isInteger(calls.at(-1).options.timeoutMs));
 assert.deepEqual(calls.at(-1).params.steps, steps, "step timing itself is unchanged");
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

// A successful start includes the newly attached runtime session and player
// names, using the same discovery path as stop. The editor ID is excluded.
{
 let started = false;
 let operation = "play";
 const originalSessions = context.bridge.sessions;
 const originalCall = context.bridge.call;
 context.bridge.sessions = async () => ({list: started
   ? [{studioId:"editor",context:"edit"},{studioId:"runtime",context:"playtest server"}]
   : [{studioId:"editor",context:"edit"}]});
 context.bridge.call = async (op, params, options) => {
  assert.equal(op, "playtest.control");
  if (params.op === operation) {
   started = true;
   return {changed:true,state:{testPending:true,isRunning:false}};
  }
  assert.equal(options.studioId, "runtime");
  return {changed:false,state:{players:operation === "multiplayer" ? [{name:"Alice",userId:123},{name:"Bob",userId:456}] : [{name:"Alice",userId:123}]}};
 };
 for (operation of ["play", "multiplayer"]) {
  started = false;
  const result = await playtest.handler(z.object(playtest.spec.inputSchema).parse({op:operation,studioId:"editor"}));
  assert.match(result.content[0].text, /"studioId": ?"runtime"/);
  assert.match(result.content[0].text, /"name": ?"Alice"/);
 }
 context.bridge.sessions = originalSessions;
 context.bridge.call = originalCall;
}
process.stdout.write("playtest runtime identity: ok\n");

// addPlayers goes to the running test's server and waits for the new players.
{
 const originalSessions = context.bridge.sessions;
 const originalCall = context.bridge.call;
 let joined = 1;
 const sent = [];
 context.bridge.sessions = async () => ({list:[{studioId:"editor",context:"edit"},{studioId:"runtime",context:"playtest server"}]});
 context.bridge.call = async (op, params, options) => {
  sent.push({op: params.op, studioId: options.studioId, players: params.players});
  if (params.op === "addPlayers") return {changed:true,state:{playerCount:joined}};
  joined = 3;
  return {changed:false,state:{playerCount:joined}};
 };
 const result = await playtest.handler(z.object(playtest.spec.inputSchema).parse({op:"addPlayers",players:2}));
 assert.ok(!result.isError);
 assert.deepEqual(sent[0], {op:"addPlayers",studioId:"runtime",players:2});
 assert.match(result.content[0].text, /"playerCount": ?3/);
 context.bridge.sessions = async () => ({list:[{studioId:"editor",context:"edit"}]});
 const none = await playtest.handler(z.object(playtest.spec.inputSchema).parse({op:"addPlayers"}));
 assert.equal(none.isError, true);
 context.bridge.sessions = originalSessions;
 context.bridge.call = originalCall;
}
process.stdout.write("playtest addPlayers routing: ok\n");

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

const { registerPerfTools } = await import("../dist/tools/perf.js");
registerPerfTools(context);
const consoleTool = registered.get("console");
const consoleArgs = z.object(consoleTool.spec.inputSchema).parse({target:"client",player:"Alice",studioId:"runtime",since:"cursor-1",limit:10});
context.bridge.call = async (op, params, options) => {
 assert.equal(op, "perf.console");
 assert.equal(params.target, "client");
 assert.equal(params.player, "Alice");
 assert.equal(params.since, "cursor-1");
 assert.equal(options.studioId, "runtime");
 return {items:[],total:0,dropped:0,evicted:2,nextCursor:"cursor-2",capturing:true};
};
const consoleResult = await consoleTool.handler(consoleArgs);
assert.match(consoleResult.content[0].text, /2 older lines were evicted/);
assert.match(consoleResult.content[0].text, /nextCursor: cursor-2/);
context.bridge.call = async () => ({
 items: Array.from({length:60}, (_, index) => ({level:"print",message:`${index} ${"x".repeat(1000)}`})),
 total:60,dropped:0,nextCursor:"cursor-3",
});
const boundedConsole = await consoleTool.handler(z.object(consoleTool.spec.inputSchema).parse({}));
assert.ok(boundedConsole.content[0].text.length < 25_000);
assert.match(boundedConsole.content[0].text, /older matching lines omitted/);
process.stdout.write("client console schema and cursor forwarding: ok\n");

// `create` must not advertise a recursive schema -- Gemini / Vertex AI reject a
// `$ref` with HTTP 400 -- yet a bad nested child is still refused by name.
{
 const { registerInstanceTools } = await import("../dist/tools/instances.js");
 const tools = new Map();
 registerInstanceTools({ server: { registerTool(name, spec, handler) { tools.set(name, { spec, handler }); } }, bridge: { async call() { throw new Error("must not reach Studio"); } } });
 const create = tools.get("create");
 const schema = JSON.stringify(z.toJSONSchema(z.object(create.spec.inputSchema)));
 assert.ok(!schema.includes("$ref") && !schema.includes("$defs") && !schema.includes("definitions"), "create schema is not recursive");
 const bad = await create.handler(z.object(create.spec.inputSchema).parse({ instances: [{ parent: "Workspace", className: "Model", children: [{ className: "Part", children: [{ name: "NoClass" }] }] }] }));
 assert.equal(bad.isError, true);
 assert.match(bad.content[0].text, /BAD_PARAMS\] instances\[0\]\.children\[0\]\.children\[0\]\.className/);
 process.stdout.write("create schema without recursion, nested validation: ok\n");
}

// Compact JSON: short structures on one line, and always parsed back identical.
{
 const { stringify } = await import("../dist/lib/format.js");
 const value = { rows: [{ path: "Workspace.A", className: "Part" }], nested: { list: [1, "two", null, undefined], skip: undefined, when: new Date(0) }, long: "x".repeat(150) };
 assert.deepEqual(JSON.parse(stringify(value)), JSON.parse(JSON.stringify(value)));
 assert.match(stringify(value), /\n  "rows": \[\{"path":"Workspace.A","className":"Part"\}\],\n/, "a short row stays on one line");
 assert.equal(stringify([]), "[]");
 assert.equal(stringify(undefined), "null");
 process.stdout.write("compact json: ok\n");
}

// Screenshot scaling: box filter averages everything under a pixel; enlarging copies blocks.
{
 const { boxResample, upscaleNearest } = await import("../dist/lib/png.js");
 const stripes = Buffer.from([0,0,0, 200,200,200, 0,0,0, 200,200,200, 0,0,0, 200,200,200, 0,0,0, 200,200,200]);
 assert.deepEqual([...boxResample(stripes, 4, 2, 2).rgb], [100,100,100, 100,100,100], "averages, never samples");
 const W = 1661, H = 719, line = Buffer.alloc(W * H * 3);
 for (let y = 0; y < H; y += 1) line[(y * W + 831) * 3] = 255;
 const scaled = boxResample(line, W, H, 800);
 assert.equal(scaled.width, 800);
 assert.equal(scaled.height, 346);
 let red = 0; for (let i = 0; i < scaled.rgb.length; i += 3) red = Math.max(red, scaled.rgb[i]);
 assert.ok(red > 100, "a one-pixel line survives a 2x reduction");
 assert.equal(boxResample(stripes, 4, 2, 8).width, 4, "never scales up");
 assert.deepEqual([...upscaleNearest(Buffer.from([1,2,3,4,5,6]), 2, 1, 2).rgb], [1,2,3,1,2,3,4,5,6,4,5,6,1,2,3,1,2,3,4,5,6,4,5,6]);
 process.stdout.write("screenshot scaling: ok\n");
}

// The PNG writer: every chunk carries the right checksum and the pixels survive.
// A wrong CRC still yields a file, and a file every decoder refuses with no hint
// which byte was at fault -- so the checksums are recomputed here by a separate
// implementation rather than by the one under test.
{
 const { encodePng } = await import("../dist/lib/png.js");
 const { inflateSync } = await import("node:zlib");
 const table = new Int32Array(256).map((_, n) => {
  let c = n;
  for (let k = 0; k < 8; k += 1) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
  return c;
 });
 const reference = (bytes) => {
  let c = -1;
  for (const byte of bytes) c = table[(c ^ byte) & 0xff] ^ (c >>> 8);
  return (c ^ -1) >>> 0;
 };
 const width = 3, height = 2;
 const rgb = Buffer.from([255,0,0, 0,255,0, 0,0,255,  10,20,30, 40,50,60, 70,80,90]);
 const png = encodePng(rgb, width, height);
 assert.deepEqual([...png.subarray(0, 8)], [0x89,0x50,0x4e,0x47,0x0d,0x0a,0x1a,0x0a], "PNG signature");
 let offset = 8, idat;
 const kinds = [];
 while (offset < png.length) {
  const length = png.readUInt32BE(offset);
  const kind = png.toString("ascii", offset + 4, offset + 8);
  assert.equal(png.readUInt32BE(offset + 8 + length), reference(png.subarray(offset + 4, offset + 8 + length)), `${kind} checksum`);
  if (kind === "IHDR") {
   assert.equal(png.readUInt32BE(offset + 8), width, "IHDR width");
   assert.equal(png.readUInt32BE(offset + 12), height, "IHDR height");
  }
  if (kind === "IDAT") idat = png.subarray(offset + 8, offset + 8 + length);
  kinds.push(kind);
  offset += 12 + length;
 }
 assert.deepEqual(kinds, ["IHDR", "IDAT", "IEND"]);
 const raw = inflateSync(idat);
 assert.equal(raw.length, (width * 3 + 1) * height, "one filter byte per row");
 assert.deepEqual([...raw.subarray(1, 10)], [...rgb.subarray(0, 9)], "first row survives");
 assert.deepEqual([...raw.subarray(11)], [...rgb.subarray(9)], "second row survives");
 assert.throws(() => encodePng(Buffer.alloc(5), 2, 2), /short of the 12 needed/, "short pixel data is refused");
 process.stdout.write("png encoding: ok\n");
}

// scene: a category of bare counts renders on one line; owned entries keep theirs.
{
 const perf = registered.get("performance");
 context.bridge.call = async () => ({
  composition: {total: 12, unit: "instances", entries: [
   {name: "Physics", depth: 1, size: 10},
   {name: "Motor6D", depth: 2, size: 6},
   {name: "Attachment", depth: 2, size: 4},
   {name: "Misc", depth: 1, size: 2},
  ]},
  animationMemory: {total: 100, unit: "bytes", entries: [
   {name: "Walk", depth: 1, size: 100, owners: ["Workspace.Npc.Animator"]},
  ]},
 });
 const result = await perf.handler(z.object(perf.spec.inputSchema).parse({op: "scene"}));
 const out = result.content[0].text;
 assert.match(out, /  Physics — 10 instances: Motor6D 6, Attachment 4\n/);
 assert.match(out, /  Misc — 2 instances/);
 assert.match(out, /  Walk — 100 bytes\n      used by Workspace\.Npc\.Animator/);
 process.stdout.write("scene compact rows: ok\n");
}

// inspect: children come back as compact "Name (Class)" strings.
{
 const inspect = registered.get("inspect");
 context.bridge.call = async () => ({
  items: [{path: "Workspace.Npc", className: "Model", childCount: 2, properties: {Name: "Npc"},
   children: [{name: "Head", className: "Part"}, {name: "Humanoid", className: "Humanoid"}]}],
  failures: [],
 });
 const result = await inspect.handler(z.object(inspect.spec.inputSchema).parse({paths: ["Workspace.Npc"], properties: ["Name"]}));
 assert.match(result.content[0].text, /"children": ?\["Head \(Part\)", ?"Humanoid"\]/);
 process.stdout.write("inspect compact children: ok\n");
}

// universe servers/logs: routed to Server Management with the wildcard version,
// rendered as a table and as log blocks. Fetch is stubbed; nothing leaves.
{
 const { registerUniverseTools } = await import("../dist/tools/universe.js");
 registerUniverseTools(context);
 const universe = registered.get("universe");
 const saved = { fetch: globalThis.fetch, env: { ...process.env } };
 Object.assign(process.env, { ROBLOX_API_KEY: "test-key", ROBLOX_USER_ID: "1", ROBLOX_UNIVERSE_ID: "10", ROBLOX_PLACE_ID: "20" });
 context.bridge.call = async () => ({ placeId: 20 });
 const urls = [];
 globalThis.fetch = async (url) => {
  urls.push(String(url));
  if (String(url).includes("/universes/v1/places/")) return new Response(JSON.stringify({ universeId: 10 }), { status: 200 });
  const body = String(url).includes("/logs")
   ? { gameServerLogs: [{ messageTimestampMs: "0", severity: 3, message: "boom", stackTrace: "Script 'X', Line 4", context: "{\"id\":1}", skippedCount: 2 }], nextPageToken: null }
   : { gameServers: [{ jobId: "job-1", status: "active", occupancy: 3, maxOccupancy: 10, uptime: "120s", frameRate: 59.7, memoryUsageBytes: 104857600, placeVersion: "12" }], nextPageToken: null };
  return new Response(JSON.stringify(body), { status: 200 });
 };
 try {
  const servers = await universe.handler(z.object(universe.spec.inputSchema).parse({ op: "servers" }));
  assert.match(servers.content[0].text, /job-1 \| active \| 3\/10 \| 120s \| 60 \| 100 \| 12/);
  assert.match(urls.find((u) => u.includes("game-servers")), /\/server-management\/v1\/universes\/10\/places\/20\/versions\/-\/game-servers\?/);
  const logs = await universe.handler(z.object(universe.spec.inputSchema).parse({ op: "logs", jobId: "job-1", severity: "error", search: "boom" }));
  const out = logs.content[0].text;
  assert.match(out, /\[error\] boom  \(\+2 similar\)\n  Script 'X', Line 4\n  context: \{"id":1\}/);
  assert.equal(new URL(urls.find((u) => u.includes("/logs"))).searchParams.get("Filter"), 'severity == 3 && search == "boom"');
  const missing = await universe.handler(z.object(universe.spec.inputSchema).parse({ op: "logs" }));
  assert.equal(missing.isError, true);
 } finally {
  globalThis.fetch = saved.fetch;
  for (const key of ["ROBLOX_API_KEY", "ROBLOX_USER_ID", "ROBLOX_UNIVERSE_ID", "ROBLOX_PLACE_ID"]) {
   if (saved.env[key] === undefined) delete process.env[key]; else process.env[key] = saved.env[key];
  }
 }
 process.stdout.write("universe servers and logs: ok\n");
}

// console: a structured log's context is shown under its line.
{
 const consoleTool = registered.get("console");
 context.bridge.call = async () => ({ items: [{ level: "info", message: "Bob leveled up", context: "{\"player\":\"Bob\"}" }], total: 1, dropped: 0, nextCursor: "c" });
 const result = await consoleTool.handler(z.object(consoleTool.spec.inputSchema).parse({}));
 assert.match(result.content[0].text, /\[info\] Bob leveled up\n    context: \{"player":"Bob"\}/);
 process.stdout.write("console structured context: ok\n");
}

// universe products/sell: lists both kinds, refuses a duplicate name, needs confirm.
{
 const universe = registered.get("universe");
 const saved = { fetch: globalThis.fetch, env: { ...process.env } };
 Object.assign(process.env, { ROBLOX_API_KEY: "test-key", ROBLOX_USER_ID: "1", ROBLOX_UNIVERSE_ID: "10", ROBLOX_PLACE_ID: "20" });
 context.bridge.call = async () => ({ placeId: 20 });
 const sent = [];
 globalThis.fetch = async (url, init) => {
  const href = String(url);
  sent.push({ href, method: init?.method ?? "GET", body: init?.body });
  if (href.includes("/universes/v1/places/")) return new Response(JSON.stringify({ universeId: 10 }), { status: 200 });
  if (href.includes("developer-products/creator")) return new Response(JSON.stringify({ developerProducts: [{ productId: 5, name: "100 Coins", isForSale: true, priceInformation: { defaultPriceInRobux: 25 } }] }), { status: 200 });
  if (href.includes("game-passes/creator")) return new Response(JSON.stringify({ gamePasses: [{ gamePassId: 7, name: "VIP", isForSale: false }] }), { status: 200 });
  if (init?.method === "POST") return new Response(JSON.stringify({ productId: 6, name: "500 Coins", isForSale: true, priceInformation: { defaultPriceInRobux: 99 } }), { status: 200 });
  return new Response("", { status: 200 });
 };
 const parse = (args) => z.object(universe.spec.inputSchema).parse(args);
 try {
  const list = (await universe.handler(parse({ op: "products" }))).content[0].text;
  assert.match(list, /product \| 5 \| 100 Coins \| 25 \| true/);
  assert.match(list, /pass \| 7 \| VIP \|  \| false/);
  const unconfirmed = await universe.handler(parse({ op: "sell", kind: "product", name: "500 Coins", price: 99 }));
  assert.match(unconfirmed.content[0].text, /NEEDS_CONFIRM/);
  const duplicate = await universe.handler(parse({ op: "sell", kind: "product", name: "100 coins", price: 25, confirm: true }));
  assert.match(duplicate.content[0].text, /ALREADY_EXISTS\].*id 5/);
  const created = await universe.handler(parse({ op: "sell", kind: "product", name: "500 Coins", price: 99, forSale: true, confirm: true }));
  assert.match(created.content[0].text, /"id": ?6/);
  const post = sent.find((entry) => entry.method === "POST");
  assert.ok(post.href.endsWith("/developer-products/v2/universes/10/developer-products"));
  assert.equal(post.body.get("price"), "99");
  assert.equal(post.body.get("isForSale"), "true");
  const updated = await universe.handler(parse({ op: "sell", kind: "pass", itemId: "7", price: 150, confirm: true }));
  assert.match(updated.content[0].text, /"action": ?"updated"/);
  assert.ok(sent.some((entry) => entry.method === "PATCH" && entry.href.endsWith("/game-passes/v1/universes/10/game-passes/7")));
 } finally {
  globalThis.fetch = saved.fetch;
  for (const key of ["ROBLOX_API_KEY", "ROBLOX_USER_ID", "ROBLOX_UNIVERSE_ID", "ROBLOX_PLACE_ID"]) {
   if (saved.env[key] === undefined) delete process.env[key]; else process.env[key] = saved.env[key];
  }
 }
 process.stdout.write("universe products and sell: ok\n");
}

// datastore live set: keeps the entry's users and attributes, and sends its etag.
{
 const { registerDataTools } = await import("../dist/tools/data.js");
 registerDataTools(context);
 const datastore = registered.get("datastore");
 const saved = { fetch: globalThis.fetch, env: { ...process.env } };
 Object.assign(process.env, { ROBLOX_API_KEY: "test-key", ROBLOX_USER_ID: "1", ROBLOX_UNIVERSE_ID: "10", ROBLOX_PLACE_ID: "20" });
 context.bridge.call = async () => ({ placeId: 20 });
 let patched;
 globalThis.fetch = async (url, init) => {
  const href = String(url);
  if (href.includes("/universes/v1/places/")) return new Response(JSON.stringify({ universeId: 10 }), { status: 200 });
  if ((init?.method ?? "GET") === "GET") return new Response(JSON.stringify({ value: { coins: 1 }, users: ["users/42"], attributes: { lock: "s1" }, etag: "e1" }), { status: 200 });
  patched = JSON.parse(init.body);
  return new Response(JSON.stringify({ revisionId: "r2" }), { status: 200 });
 };
 try {
  const result = await datastore.handler(z.object(datastore.spec.inputSchema).parse({ target: "live", op: "set", store: "Players", key: "42", value: "{\"coins\":5}", confirm: true }));
  assert.ok(!result.isError, result.content[0].text);
  assert.deepEqual(patched, { value: { coins: 5 }, users: ["users/42"], attributes: { lock: "s1" }, etag: "e1" });
 } finally {
  globalThis.fetch = saved.fetch;
  for (const key of ["ROBLOX_API_KEY", "ROBLOX_USER_ID", "ROBLOX_UNIVERSE_ID", "ROBLOX_PLACE_ID"]) {
   if (saved.env[key] === undefined) delete process.env[key]; else process.env[key] = saved.env[key];
  }
 }
 process.stdout.write("datastore live set keeps users and attributes: ok\n");
}
