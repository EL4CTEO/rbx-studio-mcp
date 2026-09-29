/** Regression checks for v0.8.5's budgets, search rendering and session routing. */
import assert from "node:assert/strict";
import { z } from "zod";
import { CHARACTER_LIMIT, decodeCursor, json, page, table } from "../dist/lib/format.js";
import { ToolError } from "../dist/lib/errors.js";
import { registerPlaytestTools } from "../dist/tools/playtest.js";
import { registerScriptTools } from "../dist/tools/scripts.js";
const output = result => result.content.filter(c => c.type === "text").map(c => c.text).join("\n");
const rows = Array.from({length: 20}, (_, i) => ({path: "P" + i, data: "x".repeat(4000)}));
for (const result of [table(["path", "data"], rows, {offset: 10, total: 30}), page(rows, {offset: 10, total: 30})]) {
 const rendered = output(result);
 assert.ok(rendered.length <= CHARACTER_LIMIT);
 const cursor = rendered.match(/cursor: "([^"]+)"/)?.[1];
 const next = decodeCursor(cursor);
 assert.ok(next > 10 && next < 30, "budget cursor must not skip unseen rows");
 assert.ok(rendered.includes("P" + (next - 11)) && !rendered.includes("P" + (next - 10)));
}
for (const value of [{data: "\u0000".repeat(100000)}, Array.from({length: 5000}, () => ({nested: {data: "x".repeat(10000)}}))]) {
 const rendered = output(json(value));
 assert.ok(rendered.length <= CHARACTER_LIMIT);
 assert.equal(JSON.parse(rendered).truncated, true, "large JSON must stay valid");
}
const registered = new Map();
const context = {server: {registerTool: (name, spec, handler) => registered.set(name, {spec, handler})}, bridge: {}};
registerPlaytestTools(context); registerScriptTools(context);
const call = (name, args) => {const tool = registered.get(name); return tool.handler(z.object(tool.spec.inputSchema).parse(args));};
context.bridge.call = async (op, params) => {
 assert.equal(op, "script.grep"); assert.deepEqual(params.patterns, ["alpha", "beta"]);
 return {searched: 1, total: 2, offset: 0, items: [
  {path: "Script", revision: "r1", line: 2, text: "alpha", before: ["one"], after: ["beta", "four"], needles: [1]},
  {path: "Script", revision: "r1", line: 3, text: "beta", before: ["one", "alpha"], after: ["four"], needles: [2]},
 ]};
};
const grep = output(await call("script_grep", {patterns: ["alpha", "beta"], contextLines: 2}));
assert.equal(grep.match(/rev=r1/g).length, 1);
assert.equal(grep.match(/alpha/g).length, 1); assert.equal(grep.match(/beta/g).length, 1);
assert.equal(grep.match(/four/g).length, 1);
context.bridge.call = async () => ({searched: 1, total: 20, offset: 0, items: Array.from({length: 20}, (_, i) => ({path: "Big", line: i + 1, text: "x".repeat(4000)}))});
const clipped = output(await call("script_grep", {pattern: "x"}));
assert.ok(clipped.length <= CHARACTER_LIMIT && clipped.includes("cursor:"));
assert.ok(decodeCursor(clipped.match(/cursor: "([^"]+)"/)[1]) < 20);

const editorA = {studioId: "editor-A", context: "edit", placeId: 10};
const editorB = {studioId: "editor-B", context: "edit", placeId: 10};
const runtimeA = {studioId: "runtime-A", editorStudioId: "editor-A", context: "playtest server", placeId: 10};
const runtimeB = {studioId: "runtime-B", editorStudioId: "editor-B", context: "playtest server", placeId: 10};
let sessions = [editorB, runtimeB, editorA, runtimeA];
context.bridge.sessions = async () => ({list: sessions});
const sent = [];
context.bridge.call = async (_, params, options) => {
 sent.push({op: params.op, id: options.studioId});
 if (params.op === "endTest") {assert.equal(options.studioId, "runtime-A"); sessions = [editorA, editorB, runtimeB]; throw new ToolError("DISCONNECTED", "teardown");}
 assert.equal(options.studioId, "editor-A", "verify against the originating editor");
 return {changed:false, state:{isEdit:true, isRunning:false, editModeActive:true, testPending:false, playerCount:0, lastResult: "passed"}};
};
const stopped = JSON.parse(output(await call("playtest", {op:"stop", studioId:"editor-A"})));
assert.equal(stopped.lifecycle, "completed"); assert.equal(stopped.editorStudioId, "editor-A"); assert.equal(stopped.lastResult, "passed");
assert.ok(sent.every(s => s.id.endsWith("-A")));
sessions = [editorA, editorB, {...runtimeA, editorStudioId:undefined}, {...runtimeB, editorStudioId:undefined}];
sent.length = 0;
const ambiguous = await call("playtest", {op:"stop", studioId:"editor-A"});
assert.equal(ambiguous.isError, true); assert.match(output(ambiguous), /AMBIGUOUS_PLAYTEST/); assert.equal(sent.length, 0);
sessions = [editorA, runtimeA];
context.bridge.call = async (_, params, options) => {
 assert.equal(options.studioId, "runtime-A");
 return {changed:false,state:{isEdit:false,isRunning:true,editModeActive:false,playerCount:1,diagnosticsReady:false,testPending:false}};
};
const pending = JSON.parse(output(await call("playtest", {op:"state", studioId:"runtime-A", waitFor:"ready", waitSeconds:0})));
assert.equal(pending.ready, false); assert.equal(pending.waitTimedOut, true); assert.equal(pending.runtimeStudioId, "runtime-A");
context.bridge.call = async (_, params, options) => {
 assert.equal(options.studioId, "editor-A");
 return {changed:false,state:{isEdit:true,isRunning:false,editModeActive:true,testPending:false,playerCount:0,lastResult:{success:true}}};
};
const finished = JSON.parse(output(await call("playtest", {op:"state", studioId:"runtime-A", waitFor:"completed", waitSeconds:0})));
assert.equal(finished.lifecycle, "completed"); assert.deepEqual(finished.lastResult, {success:true});
console.log("release behavior: budgets, merged search context, pairing, readiness and completion pass");
