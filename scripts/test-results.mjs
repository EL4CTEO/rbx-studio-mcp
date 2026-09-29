/** Response budgets, cursors that survive clipping, and grouped grep rendering. */
import assert from "node:assert/strict";
import { z } from "zod";
import { CHARACTER_LIMIT, decodeCursor, json, page, table } from "../dist/lib/format.js";
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
registerScriptTools(context);
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

console.log("results: budgets, clipped cursors and merged search context pass");
