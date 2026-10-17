/** Required edit revisions, UI snapshot diffs and the heavy-playtest stop. */
import assert from "node:assert/strict";
import { z } from "zod";
import { registerExecTools } from "../dist/tools/exec.js";
import { heavyStopNote, registerPlaytestTools } from "../dist/tools/playtest.js";
import { registerScriptTools } from "../dist/tools/scripts.js";
import { clearSnapshots, diffSnapshots, renderDiff } from "../dist/lib/uisnap.js";

const tools = new Map();
const calls = [];
let respond = () => ({});
let sessions = { activeId: "edit", list: [{ studioId: "edit", placeId: 1, context: "edit" }] };
const context = {
  server: { registerTool: (name, spec, handler) => tools.set(name, { spec, handler }) },
  bridge: {
    call: async (op, params, options) => {
      calls.push({ op, params, options });
      return respond(op, params, options);
    },
    sessions: async () => sessions,
    notePlaceName: async () => {},
  },
};
for (const register of [registerExecTools, registerPlaytestTools, registerScriptTools]) register(context);
const call = (name, args) => {
  const tool = tools.get(name);
  return tool.handler(z.object(tool.spec.inputSchema).parse(args));
};
const text = (result) => result.content.filter((part) => part.type === "text").map((part) => part.text).join("\n");

// script_edit: blind line-range and whole-source edits are refused before Studio is asked.
respond = () => ({ items: [] });
calls.length = 0;
let result = await call("script_edit", { edits: [{ path: "S.A", startLine: 1, replacement: "x" }] });
assert(result.isError); assert.match(text(result), /NEEDS_REVISION/); assert.match(text(result), /S\.A/);
result = await call("script_edit", { edits: [{ path: "S.A", source: "return 1" }] });
assert(result.isError); assert.match(text(result), /NEEDS_REVISION/);
assert.equal(calls.length, 0, "a refused edit never reaches Studio");
// find/replace needs none; one revision covers every edit to that script in the batch.
await call("script_edit", { edits: [{ path: "S.A", find: "a", replace: "b" }] });
await call("script_edit", { edits: [{ path: "S.A", find: "a", replace: "b", revision: "r1" }, { path: "S.A", startLine: 3, replacement: "y" }] });
assert.equal(calls.length, 2);
result = await call("script_edit", { edits: [{ path: "S.A", source: "x", revision: "r1" }, { path: "S.B", startLine: 1, replacement: "y" }] });
assert(result.isError); assert.match(text(result), /S\.B/); assert.doesNotMatch(text(result).split("\n")[0], /S\.A/);
// live: confirm first, then revision.
assert.match(text(await call("script_edit", { target: "live", path: "S.A", source: "x" })), /NEEDS_CONFIRM/);
assert.match(text(await call("script_edit", { target: "live", path: "S.A", source: "x", confirm: true })), /NEEDS_REVISION/);

// UI snapshots: the diff names what moved, what appeared and what went.
const base = {
  root: "StarterGui", screen: "800x600",
  elements: [
    { path: "StarterGui.Hud", className: "ScreenGui", props: { Enabled: true } },
    { path: "StarterGui.Hud.Play", className: "TextButton", props: { Text: "Play", TextSize: 14, BackgroundColor3: "1, 0, 0" } },
    { path: "StarterGui.Hud.Old", className: "Frame", props: { Visible: true } },
  ],
};
const next = {
  root: "StarterGui", screen: "800x600",
  elements: [
    { path: "StarterGui.Hud", className: "ScreenGui", props: { Enabled: true } },
    { path: "StarterGui.Hud.Play", className: "TextButton", props: { Text: "Start", TextSize: 14, BackgroundColor3: "0, 1, 0", FontFace: "Gotham" } },
    { path: "StarterGui.Hud.New", className: "UICorner", props: { CornerRadius: "{0, 8}" } },
  ],
};
const diff = diffSnapshots(base, next);
assert.equal(diff.unchanged, 1);
assert.deepEqual(diff.added.map((element) => element.path), ["StarterGui.Hud.New"]);
assert.deepEqual(diff.removed.map((element) => element.path), ["StarterGui.Hud.Old"]);
assert.deepEqual(diff.changed[0].changes.map((change) => change.property), ["BackgroundColor3", "FontFace", "Text"]);
const rendered = renderDiff(diff);
assert.match(rendered, /Text: "Play" -> "Start"/); assert.match(rendered, /FontFace: \(none\) -> "Gotham"/);
// A class change at the same path is a replacement, not an edit.
const swapped = diffSnapshots(base, { ...base, elements: [base.elements[0], { ...base.elements[1], className: "TextLabel" }, base.elements[2]] });
assert.equal(swapped.added.length, 1); assert.equal(swapped.removed.length, 1); assert.equal(swapped.changed.length, 0);

clearSnapshots();
respond = () => base;
const first = text(await call("viewport", { op: "uisnap" }));
assert.match(first, /Snapshot ui1: 3 UI elements/); assert.equal(calls.at(-1).op, "viewport.uisnap");
respond = () => next;
const compared = text(await call("viewport", { op: "uisnap", compareTo: "ui1" }));
assert.match(compared, /ui1 -> ui2/); assert.match(compared, /1 changed, 1 added, 1 removed, 1 unchanged/);
assert.match(text(await call("viewport", { op: "uisnap", compareTo: "ui2" })), /No differences/);
assert.match(text(await call("viewport", { op: "uisnap", compareTo: "ui99" })), /NO_SNAPSHOT/);
await call("viewport", { op: "uisnap", target: "client", player: "Alice", path: "Players.Alice.PlayerGui" });
assert.equal(calls.at(-1).op, "client.read"); assert.equal(calls.at(-1).params.op, "viewport.uisnap");
respond = () => ({ ...next, screen: "390x844", device: "iPhone" });
assert.match(text(await call("viewport", { op: "uisnap", compareTo: "ui2" })), /The screen changed/);

// Playtest stop on a heavy place: waits through a frozen Studio and explains why.
const heavy = { instances: 223_849, heaviest: [{ path: "Workspace.Rig", instances: 220_000 }], animSavesInstances: 219_000, build: 743 };
assert.match(heavyStopNote(heavy, false), /223,849 instances.*Warn the user/s);
assert.match(heavyStopNote(heavy, true), /AnimSaves/);
sessions = { activeId: "edit", list: [{ studioId: "edit", placeId: 1, context: "edit" }, { studioId: "run", placeId: 1, context: "playtest" }] };
let polls = 0;
respond = (op, params, options) => {
  if (params.op === "endTest") return { changed: true, deferred: true, state: {}, heavyWorkspace: heavy };
  polls += 1;
  // The first polls time out while Studio is frozen; then it settles.
  if (polls <= 2) throw new Error("TIMEOUT");
  return { changed: false, state: { isEdit: true, editModeActive: true, testPending: false, playerCount: 0 } };
};
const stopped = await call("playtest", { op: "stop" });
assert(!stopped.isError, text(stopped)); assert.equal(polls, 3);
assert.match(text(stopped), /223,849 instances/); assert.doesNotMatch(text(stopped), /still/);
// Warned at the start too. Run mode has no separate DataModel to tear down, so only play and multiplayer.
respond = () => ({ changed: true, state: { testPending: false, isEdit: true, playerCount: 0 }, heavyWorkspace: heavy });
sessions = { activeId: "edit", list: [{ studioId: "edit", placeId: 1, context: "edit" }] };
assert.match(text(await call("playtest", { op: "play" })), /Warn the user before stopping/);
assert.doesNotMatch(text(await call("playtest", { op: "run" })), /Warn the user/);

console.log("edits and UI: required revisions, UI snapshot diffs and heavy playtest stops pass");
