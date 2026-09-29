#!/usr/bin/env node
/**
 * Drives the tools through the real MCP layer against a connected Studio.
 *
 * `test-live.mjs` talks to the plugin over the bridge, which proves the transport
 * and the handlers. This starts an actual server, connects an MCP client to it and
 * calls tools the way an agent does -- so schema validation, output shaping and
 * the plugin are all in the path. It exists because that is where the last two
 * real faults hid: `execute_luau target="client"` had been broken for a release
 * because a module the relay needed was never copied to the client (every offline
 * test stubs that out), and `collision remove` answered "removed" for a group that
 * never existed. Neither shows in a unit test.
 *
 * Nothing here needs a place in any particular state. Everything it makes is under
 * Workspace.__mcp_live_tools and is deleted before it exits, pass or fail, and what
 * it moves (the camera, device emulation, network shaping, a playtest) is put back.
 *
 * The server it starts finds the bridge port taken and proxies to the running one,
 * so it appears in the Studio panel as one more MCP client for the length of a run.
 *
 * Usage: node scripts/test-live-tools.mjs [--port 44755] [--studio-id ID] [--playtest] [--no-camera]
 *   --playtest   also start a playtest and exercise character, input and the client tools
 *   --no-camera  leave the viewport camera alone (skips the focus and camera checks)
 */
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const args = process.argv.slice(2);
const flag = (name, fallback) => {
  const at = args.indexOf(`--${name}`);
  return at === -1 ? fallback : args[at + 1];
};
const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const FIXTURE = "Workspace.__mcp_live_tools";
const GROUP = "MCPLiveToolsGroup";
const TERRAIN_AT = "5000, 0, 5000";

const client = new Client({ name: "test-live-tools", version: "0" });
await client.connect(
  new StdioClientTransport({
    command: process.execPath,
    args: [join(root, "dist", "index.js"), ...(flag("port") ? ["--port", flag("port")] : [])],
    stderr: "inherit",
  }),
);

let failures = 0;
let studioId = flag("studio-id");

async function call(name, params = {}) {
  const started = performance.now();
  try {
    const result = await client.callTool(
      { name, arguments: { ...(studioId && !("studioId" in params) ? { studioId } : {}), ...params } },
      undefined,
      { timeout: 180_000 },
    );
    const text = (result.content ?? []).filter((part) => part.type === "text").map((part) => part.text).join("\n");
    return { text, isError: result.isError === true, ms: Math.round(performance.now() - started) };
  } catch (cause) {
    // Schema validation is a protocol error rather than an isError result.
    return { text: cause.message, isError: true, ms: Math.round(performance.now() - started) };
  }
}

function report(label, good, { text, ms }) {
  if (!good) failures += 1;
  const brief = text.replace(/\s+/g, " ").slice(0, good ? 84 : 360);
  process.stdout.write(`${good ? "ok  " : "FAIL"}  ${label.padEnd(50)} ${String(ms).padStart(5)}ms  ${brief}\n`);
}

/** `expect`: "ok" (any success), "refused" (any error), or a RegExp the reply must match. */
async function check(label, name, params, expect = "ok", { refused = false } = {}) {
  const reply = await call(name, params);
  const matched = expect instanceof RegExp ? expect.test(reply.text) : true;
  report(label, refused ? reply.isError && matched : !reply.isError && matched, reply);
  return reply.text;
}
const ok = (label, name, params, expect) => check(label, name, params, expect);
const refuses = (label, name, params, expect) => check(label, name, params, expect, { refused: true });
const section = (title) => process.stdout.write(`\n-- ${title}\n`);
const paths = (text) => text.split("\n").filter((line) => /^\S+ \| /.test(line) && !line.startsWith("path |")).map((line) => line.split(" | ")[0]);

const cleanup = [];
try {
  // ---- which Studio ---------------------------------------------------------------
  const listed = JSON.parse((await call("list_studios")).text.split("\n\nWARNING")[0].split("\n\n")[0]);
  const edits = (listed.studios ?? []).filter((entry) => entry.context === "edit");
  if (studioId === undefined) {
    if (edits.length !== 1) {
      process.stderr.write(
        edits.length === 0
          ? "No Studio in edit mode is connected. Open one with the plugin, or stop the playtest.\n"
          : "Several edit sessions are connected: pass --studio-id.\n",
      );
      await client.close();
      process.exit(1);
    }
    studioId = edits[0].studioId;
  }
  process.stdout.write(`Studio: ${edits.find((entry) => entry.studioId === studioId)?.placeName ?? studioId}\n`);

  // ---- fixture ------------------------------------------------------------------------
  section("fixture");
  await ok("create: nested, typed, tagged", "create", { instances: [{ parent: "Workspace", className: "Folder", name: "__mcp_live_tools", children: [
    { className: "Part", name: "A", properties: { Anchored: true, Size: "4, 1, 2", Position: "0, 50, 0", Color: "#FF8800", Material: "Neon" },
      attributes: { hp: 5, pos: { type: "Vector3", value: "1, 2, 3" } }, tags: { add: ["MCPLive"] } },
    { className: "Part", name: "B", properties: { Anchored: true, Size: "4, 1, 2", Position: "1, 50, 0" } },
    { className: "Model", name: "M", children: [
      { className: "Part", name: "P1", properties: { Anchored: true, Position: "20, 50, 0" } },
      { className: "Part", name: "P2", properties: { Anchored: true, Position: "24, 50, 0" } } ] },
    { className: "Folder", name: "Rows", children: Array.from({ length: 7 }, (_, index) => (
      { className: "Part", name: `Row${index + 1}`, properties: { Anchored: true, Position: `${index * 6}, 70, 0` } })) },
    ...["U1:40", "U2:43", "S1:60", "S2:60", "I1:80", "I2:83", "F1:100", "W1:120"].map((entry) => {
      const [name, x] = entry.split(":");
      return { className: "Part", name, properties: { Anchored: true, Size: name === "W1" ? "1, 8, 8" : name === "S2" ? "4, 4, 4" : name === "S1" ? "8, 8, 8" : "6, 6, 6", Position: `${x}, 50, 0` } };
    }),
  ] }] }, /__mcp_live_tools/);
  await ok("script_create: a module and a disabled script", "script_create", { scripts: [
    { parent: FIXTURE, name: "Mod", className: "ModuleScript", source: "local M = {}\nfunction M.add(a, b)\n\treturn a + b\nend\nreturn M\n" },
    { parent: FIXTURE, name: "Srv", className: "Script", runContext: "Server", disabled: true, source: "print('x')\n" } ] }, /__mcp_live_tools\.Mod/);

  // ---- reading --------------------------------------------------------------------------
  section("reading");
  await ok("studio_status", "studio_status", {}, /"placeName"/);
  await ok("list_studios", "list_studios", {}, /studioId/);
  await ok("tree", "tree", { path: FIXTURE, depth: 2 }, /__mcp_live_tools\.M/);
  await ok("tree: concise", "tree", { path: FIXTURE, depth: 1, detail: "concise" }, /className/);
  await ok("find: by class", "find", { className: "BasePart", path: FIXTURE, limit: 5 }, /__mcp_live_tools\.A/);
  await ok("find: tags", "find", { op: "tags" }, /MCPLive/);
  await ok("find: selector", "find", { selector: "Part", path: FIXTURE, limit: 3 }, /Part/);
  await ok("find: nameContains", "find", { nameContains: "row", path: FIXTURE, limit: 3 }, /Row/);
  await ok("inspect: standard", "inspect", { paths: [`${FIXTURE}.A`] }, /Anchored/);
  await ok("inspect: full with physics", "inspect", { paths: [`${FIXTURE}.A`], detail: "full", physics: true }, /density/);
  await ok("inspect: concise", "inspect", { paths: [`${FIXTURE}.A`], detail: "concise" }, /attributes/);
  await ok("inspect: named properties", "inspect", { paths: [`${FIXTURE}.A`], properties: ["Name", "Position"] }, /Position/);
  await ok("script_read", "script_read", { paths: [`${FIXTURE}.Mod`] }, /rev [0-9a-f]+/);
  await ok("script_read: a window", "script_read", { paths: [{ path: `${FIXTURE}.Mod`, startLine: 2, endLine: 3 }] }, /lines 2-3 of 5/);
  await ok("script_grep", "script_grep", { pattern: "add", literal: true, path: FIXTURE }, /Mod:2/);
  await ok("api: describe", "api", { op: "describe", className: "Part" }, /superclass/);
  await ok("api: classes", "api", { op: "classes", contains: "Constraint" }, /HingeConstraint/);
  await ok("console", "console", { limit: 5 });
  await ok("performance: snapshot", "performance", { op: "snapshot" }, /frame/);
  await ok("performance: scene", "performance", { op: "scene", section: "composition" }, /composition/);
  await ok("performance: coverage", "performance", { op: "coverage" });
  await ok("device: list", "device", { op: "list", form: "Phone" }, /Phone/);
  await ok("device: state", "device", { op: "state" });
  await ok("collision: list", "collision", { action: "list" }, /Default/);
  await ok("terrain: stats", "terrain", { op: "stats" }, /cells/);
  await ok("undo: status", "undo", { action: "status" }, /canUndo/);
  await ok("viewport: raycast down onto the fixture", "viewport", { op: "raycast", origin: "0, 120, 0", direction: "0, -1, 0" }, /"hit": ?true/);
  await ok("viewport: textbounds", "viewport", { op: "textbounds", text: "Hello world", textSize: 20 }, /px/);
  await ok("viewport: ui audit", "viewport", { op: "ui" });
  await ok("screenshot", "screenshot", { width: 480 }, /Studio viewport/);
  await ok("screenshot: zoom to a rect", "screenshot", { width: 480, rect: "100, 100, 200, 100" }, /rect/);
  await refuses("screenshot: a bad rect", "screenshot", { rect: "not a rect" }, /BAD_PARAMS/);
  await ok("debug: snapshots", "debug", { op: "snapshots" });
  await ok("playtest: state", "playtest", { op: "state" }, /isEdit/);

  section("paging and cursors");
  const everyRow = paths(await ok("find: all rows", "find", { className: "BasePart", path: `${FIXTURE}.Rows`, limit: 500 }));
  const seen = [];
  let cursor;
  for (let page = 0; page < 10; page += 1) {
    const got = await call("find", { className: "BasePart", path: `${FIXTURE}.Rows`, limit: 3, ...(cursor ? { cursor } : {}) });
    seen.push(...paths(got.text));
    cursor = /cursor: "([^"]+)"/.exec(got.text)?.[1];
    if (!cursor) break;
  }
  const paged = everyRow.length === 7 && JSON.stringify(seen) === JSON.stringify(everyRow);
  if (!paged) failures += 1;
  process.stdout.write(`${paged ? "ok  " : "FAIL"}  paging returns every row once, in order (${seen.length} of ${everyRow.length})\n`);
  await refuses("find: a cursor this server did not issue", "find", { className: "Part", path: FIXTURE, cursor: "nope" }, /BAD_CURSOR/);
  const before = await call("console", { limit: 2 });
  const since = /nextCursor: ([^\]\s]+)/.exec(before.text)?.[1];
  await ok("execute_luau: print and warn", "execute_luau", { source: "print('live-tools-marker'); warn('live-tools-warning')" }, /live-tools-marker/);
  await ok("console: only what is newer than the cursor", "console", { since, limit: 50 }, /live-tools-marker/);
  await ok("console: filtered by level and pattern", "console", { level: "warning", pattern: "live%-tools", limit: 10 }, /live-tools-warning/);

  // ---- writing --------------------------------------------------------------------------------
  section("writing");
  await ok("modify: properties, attributes, tags", "modify", { targets: [{ paths: [`${FIXTURE}.A`], properties: { Transparency: 0.5, Color: "0.2, 0.6, 1" },
    attributes: { hp: "", note: "x" }, tags: { add: ["Extra"], remove: ["MCPLive"] } }] }, /one undo step/);
  await ok("find: the new tag", "find", { tag: "Extra" }, /__mcp_live_tools\.A/);
  await refuses("modify: a value that is not a number", "modify", { targets: [{ paths: [`${FIXTURE}.A`], properties: { Transparency: "nope" } }] }, /BAD_PROPERTY/);
  await ok("move: clone with a new name", "move", { items: [{ path: `${FIXTURE}.A`, to: `${FIXTURE}.M`, mode: "clone", name: "A2" }] }, /A2/);
  await ok("move: reparent", "move", { items: [{ path: `${FIXTURE}.B`, to: `${FIXTURE}.M` }] }, /M\.B/);
  await refuses("move: into itself", "move", { items: [{ path: `${FIXTURE}.M`, to: `${FIXTURE}.M.P1` }] }, /BAD_MOVE/);
  await refuses("create: a class that does not exist", "create", { instances: [{ parent: FIXTURE, className: "Nope" }] }, /UNKNOWN_CLASS/);
  await refuses("create: a property that does not exist", "create", { instances: [{ parent: FIXTURE, className: "Part", properties: { Sizee: "1, 1, 1" } }] }, /Did you mean: Size/);

  const revision = /rev ([0-9a-f-]+)/.exec(await call("script_read", { paths: [`${FIXTURE}.Mod`] }).then((reply) => reply.text))?.[1];
  await ok("script_edit: find and replace with a revision", "script_edit", { edits: [{ path: `${FIXTURE}.Mod`, find: "return a + b", replace: "return a + b + 0", revision }] });
  await ok("script_edit: a line range", "script_edit", { edits: [{ path: `${FIXTURE}.Mod`, startLine: 2, endLine: 2, replacement: "function M.add(a, b) -- edited" }] });
  await refuses("script_edit: a stale revision", "script_edit", { edits: [{ path: `${FIXTURE}.Mod`, source: "return {}", revision }] }, /STALE_SCRIPT/);
  await refuses("script_edit: text that is not there", "script_edit", { edits: [{ path: `${FIXTURE}.Mod`, find: "zzz-absent", replace: "x" }] }, /NO_MATCH/);
  await refuses("script_edit: a line past the end", "script_edit", { edits: [{ path: `${FIXTURE}.Mod`, startLine: 99, endLine: 99, replacement: "x" }] }, /BAD_RANGE/);
  await ok("script_read: sees the edit", "script_read", { paths: [`${FIXTURE}.Mod`] }, /edited/);

  await ok("geometry: union", "geometry", { op: "union", path: `${FIXTURE}.U1`, with: [`${FIXTURE}.U2`], name: "Unioned" }, /Unioned/);
  await ok("geometry: subtract", "geometry", { op: "subtract", path: `${FIXTURE}.S1`, with: [`${FIXTURE}.S2`], name: "Subtracted" }, /Subtracted/);
  await ok("geometry: intersect", "geometry", { op: "intersect", path: `${FIXTURE}.I1`, with: [`${FIXTURE}.I2`], name: "Intersected" }, /Intersected/);
  await ok("geometry: fragment", "geometry", { op: "fragment", path: `${FIXTURE}.F1`, pieces: 4 }, /F1_1/);
  await ok("geometry: sweep", "geometry", { op: "sweep", path: `${FIXTURE}.W1`, to: "120, 60, 0", steps: 4, keep: false, checkAgainst: [] }, /sweep/i);
  await ok("geometry: mirror", "geometry", { op: "mirror", paths: [`${FIXTURE}.A`], axis: "X", copy: true }, /copied/);

  cleanup.push(() => call("collision", { action: "remove", group: GROUP }));
  await ok("collision: create", "collision", { action: "create", group: GROUP }, /created/);
  await ok("collision: assign", "collision", { action: "assign", group: GROUP, paths: [`${FIXTURE}.A`] }, /assigned/);
  await ok("collision: pass through Default", "collision", { action: "collidable", group: GROUP, with: "Default", collidable: false }, /collidable/);
  await ok("collision: listed", "collision", { action: "list" }, new RegExp(GROUP));
  await ok("collision: cast", "collision", { action: "cast", from: "0, 120, 0", direction: "0, -1, 0", distance: 200 }, /hit/);
  await ok("collision: overlap a box", "collision", { action: "overlap", region: "box", at: "0, 50, 0", size: "10, 10, 10" }, /__mcp_live_tools/);
  await ok("collision: overlap a radius", "collision", { action: "overlap", region: "radius", at: "0, 50, 0", radius: 6 }, /__mcp_live_tools/);
  await ok("collision: remove", "collision", { action: "remove", group: GROUP }, /"removed": ?true/);

  cleanup.push(() => call("terrain", { op: "clear", position: TERRAIN_AT, size: "40, 40, 40" }));
  await ok("terrain: fill a ball", "terrain", { op: "fill", shapes: [{ shape: "ball", position: TERRAIN_AT, radius: 8, material: "Grass" }] }, /voxels/);
  await ok("terrain: replace a material", "terrain", { op: "replace", position: TERRAIN_AT, size: "40, 40, 40", from: "Grass", to: "Snow" }, /Snow/);
  await ok("terrain: clear the region", "terrain", { op: "clear", position: TERRAIN_AT, size: "40, 40, 40" }, /cleared/);

  await ok("viewport: select", "viewport", { op: "select", paths: [`${FIXTURE}.A`] }, /1 selected/);
  await ok("viewport: clear the selection", "viewport", { op: "select", paths: [] }, /cleared/i);
  await ok("audio: a whole graph", "audio", { op: "graph", kind: "ui", parent: FIXTURE, name: "LiveAudio", effects: ["AudioFader"] }, /LiveAudio/);
  await ok("audio: read it back", "audio", { op: "inspect", path: FIXTURE }, /LiveAudio/);
  // Breakpoints need "Debugger Luau API" (File > Beta Features), which is off by
  // default -- a setting of the machine, not a fault of the tool.
  const armed = await call("debug", { op: "set", breakpoints: [{ path: `${FIXTURE}.Mod`, line: 3 }] });
  if (/NO_DEBUGGER|NO_BREAKPOINTS_SET/.test(armed.text)) {
    process.stdout.write('skip  debug: "Debugger Luau API" is off in this Studio\n');
  } else {
    report("debug: set a breakpoint", !armed.isError && /Verified/.test(armed.text), armed);
    await ok("debug: clear it", "debug", { op: "clear", path: `${FIXTURE}.Mod` }, /removed/);
  }
  await ok("execute_luau: returns values", "execute_luau", { source: "return 1 + 1, {a = 1}" }, /Returned/);
  await refuses("execute_luau: a runtime error", "execute_luau", { source: "error('boom')" }, /boom/);
  await refuses("execute_luau: a syntax error", "execute_luau", { source: "local =" }, /COMPILE_ERROR/);
  await ok("assets: peek inside a model", "assets", { op: "peek", assetId: 6903238241 }, /nothing inserted/);
  await ok("assets: insert without its scripts", "assets", { op: "insert", assetId: 6903238241, parent: FIXTURE, stripScripts: true }, /Glass Door/);

  const undoable = await call("create", { instances: [{ parent: FIXTURE, className: "Part", name: "UndoMe" }] });
  if (/one undo step/.test(undoable.text)) {
    // Only when the create says it opened a recording: without one, `undo` would
    // reach past this run into somebody else's work.
    await ok("undo: takes the create back", "undo", { action: "undo", steps: 1 }, /"applied": ?1/);
    await ok("find: it is gone", "find", { nameContains: "UndoMe", path: FIXTURE }, /No matches/);
    await ok("redo: brings it back", "undo", { action: "redo", steps: 1 }, /"applied": ?1/);
    await ok("find: it is back", "find", { nameContains: "UndoMe", path: FIXTURE }, /UndoMe/);
  } else {
    process.stdout.write("skip  undo: the create opened no recording\n");
  }

  // ---- things that must be refused, or say plainly they did nothing ---------------------------------
  section("refusals");
  const GONE = "Workspace.__mcp_live_tools_absent";
  for (const [label, tool, params, expect] of [
    ["delete: a path that is not there", "delete", { paths: [GONE] }, /NOT_FOUND/],
    ["delete: a service", "delete", { paths: ["Workspace"] }, /PROTECTED/],
    ["modify: a path that is not there", "modify", { targets: [{ paths: [GONE], attributes: { a: 1 } }] }, /NOT_FOUND/],
    ["move: to a parent that is not there", "move", { items: [{ path: `${FIXTURE}.A`, to: GONE }] }, /NOT_FOUND/],
    ["create: under a parent that is not there", "create", { instances: [{ parent: GONE, className: "Part" }] }, /NOT_FOUND/],
    ["tree: a path that is not there", "tree", { path: GONE }, /NOT_FOUND/],
    ["script_edit: something that is not a script", "script_edit", { edits: [{ path: `${FIXTURE}.A`, find: "a", replace: "b" }] }, /NOT_A_SCRIPT/],
    ["viewport: select what is not there", "viewport", { op: "select", paths: [GONE] }, /NOT_FOUND/],
    ["device: a device that does not exist", "device", { op: "set", device: "no-such-device" }, /NO_SUCH_DEVICE/],
    ["terrain: clear everything without confirm", "terrain", { op: "clear" }, /CONFIRM_REQUIRED/],
    ["terrain: a material that does not exist", "terrain", { op: "fill", shapes: [{ shape: "ball", position: TERRAIN_AT, radius: 4, material: "NotAMaterial" }] }, /BAD_PARAMS/],
    ["collision: assign to a group that does not exist", "collision", { action: "assign", group: "NoSuchGroupZ", paths: [`${FIXTURE}.A`] }, /NO_SUCH_GROUP/],
    ["geometry: subtract with nothing to subtract", "geometry", { op: "subtract", path: `${FIXTURE}.A` }, /BAD_PARAMS/],
    ["character: needs a playtest", "character", { op: "state" }, /NOT_RUNNING/],
    ["input: needs a playtest", "input", { steps: [{ kind: "key", key: "E" }] }, /NOT_RUNNING/],
    ["execute_luau client: needs a playtest", "execute_luau", { source: "return 1", target: "client" }, /NOT_RUNNING/],
    ["playtest: add players to none", "playtest", { op: "addPlayers", players: 1 }, /No playtest is running/],
    ["universe: restart needs confirm", "universe", { op: "restart" }, /NEEDS_CONFIRM|NO_CREDENTIALS/],
    ["universe: a ban needs confirm", "universe", { op: "ban", userId: "1" }, /NEEDS_CONFIRM|NO_CREDENTIALS/],
    ["execute_luau live: needs confirm", "execute_luau", { source: "return 1", target: "live" }, /NEEDS_CONFIRM/],
    ["script_edit live: needs confirm", "script_edit", { target: "live", path: "ServerScriptService.X", source: "x" }, /NEEDS_CONFIRM/],
    ["datastore live: a write needs confirm", "datastore", { op: "set", target: "live", store: "s", key: "k", value: "1" }, /NEEDS_CONFIRM/],
    ["assets: publish needs a file", "assets", { op: "publish" }, /BAD_PARAMS/],
  ]) await refuses(label, tool, params, expect);
  await ok("inspect: says a path could not be resolved", "inspect", { paths: [GONE] }, /Could not resolve/);
  await ok("script_read: says a path could not be read", "script_read", { paths: [GONE] }, /Could not read/);
  await ok("collision: removing a missing group says so", "collision", { action: "remove", group: "NoSuchGroupZ" }, /"removed": ?false/);
  await ok("inspect: a mistyped property is named", "inspect", { paths: [`${FIXTURE}.A`], properties: ["Name", "Sizee"] }, /Sizee \(not a property of Part; did you mean Size\?\)/);
  await ok("find: a mistyped class is named", "find", { className: "Prat", path: FIXTURE }, /not a Roblox class/);

  section("zero-length and empty inputs");
  const rayGuard = await refuses("viewport raycast: a zero direction", "viewport", { op: "raycast", origin: "0, 100, 0", direction: "0, 0, 0" }, /BAD_PARAMS/);
  await refuses("collision cast: from a point to itself", "collision", { action: "cast", from: "0, 80, 0", to: "0, 80, 0" }, /no length/);
  await refuses("collision cast: distance 0", "collision", { action: "cast", from: "0, 80, 0", direction: "0, -1, 0", distance: 0 }, /no length/);
  await refuses("collision cast: a zero direction", "collision", { action: "cast", from: "0, 80, 0", direction: "0, 0, 0" }, /no length/);
  await refuses("collision overlap: a box with no volume", "collision", { action: "overlap", region: "box", at: "0, 80, 0", size: "0, 0, 0" }, /no volume/);
  await refuses("collision overlap: a radius of 0", "collision", { action: "overlap", region: "radius", at: "0, 80, 0", radius: 0 }, /no volume/);
  await refuses("terrain fill: a block with no size", "terrain", { op: "fill", shapes: [{ shape: "block", position: TERRAIN_AT, size: "0, 0, 0", material: "Grass" }] }, /empty/);
  await refuses("terrain replace: a region with no size", "terrain", { op: "replace", position: TERRAIN_AT, size: "0, 4, 4", from: "Grass", to: "Snow" }, /empty/);
  await refuses("debug: a line the script does not have", "debug", { op: "set", breakpoints: [{ path: `${FIXTURE}.Mod`, line: 999 }] }, /BAD_LINE/);

  // ---- the camera, which is the user's ----------------------------------------------------------------
  section("camera");
  if (args.includes("--no-camera")) {
    process.stdout.write("skip  --no-camera\n");
  } else if (!/BAD_PARAMS/.test(rayGuard)) {
    // Without the guard a zero `from` gives the camera a NaN position, so the
    // probes are not sent to a plugin that has not got it.
    failures += 1;
    process.stdout.write("FAIL  the plugin does not refuse zero-length input; camera checks skipped to protect the viewport\n");
  } else {
    const original = await call("viewport", { op: "camera" });
    let camera;
    try { camera = JSON.parse(original.text); } catch { camera = undefined; }
    cleanup.push(async () => {
      if (!camera) return;
      const [px, py, pz] = camera.position.split(",").map(Number);
      const [lx, ly, lz] = camera.lookVector.split(",").map(Number);
      await call("viewport", { op: "camera", position: camera.position, lookAt: `${px + lx}, ${py + ly}, ${pz + lz}`, fieldOfView: camera.fieldOfView });
    });
    await refuses("camera: position equal to lookAt", "viewport", { op: "camera", position: "0, 90, 0", lookAt: "0, 90, 0" }, /same point/);
    await refuses("focus: a zero `from`", "viewport", { op: "focus", path: FIXTURE, from: "0, 0, 0" }, /BAD_PARAMS/);
    const unmoved = (await call("viewport", { op: "camera" })).text === original.text;
    if (!unmoved) failures += 1;
    process.stdout.write(`${unmoved ? "ok  " : "FAIL"}  the refused requests left the camera where it was\n`);
    await ok("focus: on the fixture", "viewport", { op: "focus", path: FIXTURE }, /cameraPosition/);
    await ok("focus: from above", "viewport", { op: "focus", path: FIXTURE, from: "0, 1, 0" }, /cameraPosition/);
    await ok("camera: set it directly", "viewport", { op: "camera", position: "0, 90, 30", lookAt: "0, 50, 0", fieldOfView: 60 }, /position/);
  }

  // ---- emulation, put back --------------------------------------------------------------------------------
  section("device and network");
  cleanup.push(() => call("device", { op: "stop" }));
  const phone = /^(\S+) \| /m.exec((await call("device", { op: "list", form: "Phone" })).text.split("\n").slice(1).join("\n"))?.[1];
  if (phone) {
    await ok("device: emulate a phone", "device", { op: "set", device: phone });
    await ok("screenshot: through the emulation", "screenshot", { width: 320 }, /Emulating/);
    await ok("viewport ui: against the phone", "viewport", { op: "ui" }, /emulating/);
    await ok("device: stop", "device", { op: "stop" }, /"emulating": ?false/);
  }
  await ok("device: a 3g connection", "device", { op: "network", preset: "3g" }, /"shaping": ?true|shaping/);
  await ok("device: back to normal", "device", { op: "network", preset: "clear" }, /"shaping": ?false|normal/);

  // ---- a running game ---------------------------------------------------------------------------------------
  if (args.includes("--playtest")) {
    section("playtest");
    const started = await call("playtest", { op: "play" });
    const playing = /"studioId": "([^"]+)"/.exec(started.text)?.[1];
    const good = Boolean(playing);
    if (!good) failures += 1;
    process.stdout.write(`${good ? "ok  " : "FAIL"}  playtest: play returns the server's studioId  ${started.text.replace(/\s+/g, " ").slice(0, 100)}\n`);
    if (playing) {
      cleanup.push(() => call("playtest", { op: "stop", studioId }));
      await new Promise((resolve) => setTimeout(resolve, 3500));
      const on = (params) => ({ ...params, studioId: playing });
      await ok("character: state", "character", on({ op: "state" }), /Humanoid/);
      await ok("character: path to a point", "character", on({ op: "path", to: "20, 3, 20" }), /Reachable/);
      await ok("character: walk to a point", "character", on({ op: "moveTo", to: "10, 3, 10" }), /"arrived": ?true/);
      await ok("character: jump", "character", on({ op: "act", action: "jump" }), /jump/);
      await ok("input: keys", "input", on({ cursor: false, steps: [{ kind: "key", key: "W", hold: 0.3 }, { kind: "key", key: "Space" }] }), /delivered/);
      await ok("screenshot: the player's own view", "screenshot", on({ width: 480 }), /playtest client/);
      await ok("console: the server's log", "console", on({ limit: 5 }));
      await ok("console: the client's log", "console", on({ target: "client", limit: 5 }));
      await ok("performance: snapshot", "performance", on({ op: "snapshot" }), /frame/);
      await ok("execute_luau: in the client VM", "execute_luau", on({ target: "client", source: "return game:GetService('Players').LocalPlayer.Name" }), /Returned/);
      await ok("execute_luau: in the server VM", "execute_luau", on({ source: "return #game.Workspace:GetChildren()" }), /Returned/);
      await ok("debug: trace remote traffic", "debug", on({ op: "remotes", seconds: 1 }));
      await ok("playtest: stop", "playtest", { op: "stop" }, /editModeActive": ?true/);
    }
  }
} finally {
  // Reversed, so what was made last is undone first.
  for (const step of cleanup.reverse()) await step().catch(() => {});
  await call("delete", { paths: [FIXTURE] });
  const gone = await call("find", { nameContains: "__mcp_live_tools", path: "Workspace" });
  if (!/No matches/.test(gone.text)) {
    failures += 1;
    process.stderr.write(`cleanup left the fixture behind; delete ${FIXTURE} by hand\n`);
  }
  await client.close();
}

process.stdout.write(failures === 0 ? "\nlive tools: ok\n" : `\nlive tools: ${failures} failure(s)\n`);
process.exit(failures === 0 ? 0 : 1);
