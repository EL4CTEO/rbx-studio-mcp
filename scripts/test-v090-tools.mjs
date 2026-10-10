/** MCP schemas and routing for the new existing-tool operations. */
import assert from "node:assert/strict";
import { z } from "zod";
import { registerDiscoverTools } from "../dist/tools/discover.js";
import { registerExecTools } from "../dist/tools/exec.js";
import { registerDebugTools } from "../dist/tools/debug.js";
import { registerPerfTools } from "../dist/tools/perf.js";
import { registerScreenshotTools } from "../dist/tools/screenshot.js";

const tools = new Map();
const calls = [];
let response = {};
const context = { server: {registerTool: (name, spec, handler) => tools.set(name, {spec, handler})}, bridge: {
  call: async (op, params, options) => { calls.push({op, params, options}); return response; },
  sessions: async () => ({activeId:"run",list:[{studioId:"edit",placeId:1,context:"edit"},{studioId:"run",placeId:1,context:"playtestserver"}]}),
}};
for (const register of [registerDiscoverTools, registerExecTools, registerDebugTools, registerPerfTools, registerScreenshotTools]) register(context);
const call = (name, args) => { const tool = tools.get(name); return tool.handler(z.object(tool.spec.inputSchema).parse(args)); };
const text = result => result.content.filter(part => part.type === "text").map(part => part.text).join("\n");
response = {items:[{path:"P",handle:"@mcp:test:1",className:"Part",childCount:0}],total:1,offset:0};
const tree = text(await call("tree", {target:"client",player:"Alice",handles:true}));
assert.match(tree,/handle/); assert.equal(calls.at(-1).op,"client.read"); assert.equal(calls.at(-1).params.op,"discover.tree");
assert.equal(calls.at(-1).params.params.handles,true);
await call("find",{target:"client",className:"Part"}); assert.equal(calls.at(-1).params.op,"discover.find");
response = {items:[{path:"P",handle:"@mcp:test:1",className:"Part",childCount:0,properties:{Name:"P"}}],failures:[]};
await call("inspect",{target:"client",paths:["P"],properties:["Name"],handles:true});
assert.equal(calls.at(-1).params.op,"discover.inspect"); assert.equal(calls.at(-1).params.params.handles,true);
response = {hit:true,path:"P",handle:"@mcp:test:1"};
assert.match(text(await call("viewport",{op:"pick",target:"client",x:0.5,y:0.5})),/@mcp/);
assert.equal(calls.at(-1).params.op,"viewport.pick");
assert((await call("viewport",{op:"focus",target:"client",path:"P"})).isError);
assert((await call("viewport",{op:"pick",x:0.5})).isError);
response = {path:"P",items:[],initial:{},seconds:1,dropped:0};
await call("debug",{op:"watch",target:"client",path:"P",properties:["Text"],seconds:1});
assert.equal(calls.at(-1).params.op,"debug.watch"); assert.deepEqual(calls.at(-1).params.params.properties,["Text"]);
assert((await call("debug",{op:"watch"})).isError);
response = {path:"P",observed:1,pairs:[],summaries:0,seconds:1};
await call("debug",{op:"collisions",target:"client",path:"P",minSpeed:5,seconds:2});
assert.equal(calls.at(-1).op,"client.read"); assert.equal(calls.at(-1).params.op,"debug.collisions"); assert.equal(calls.at(-1).params.params.minSpeed,5);
await call("debug",{op:"collisions",path:"P"}); assert.equal(calls.at(-1).op,"debug.collisions");
assert((await call("debug",{op:"collisions"})).isError);
assert((await call("performance",{op:"profile",target:"client"})).isError);
response = {kind:"table",items:[{key:1,value:"retained"}],resultId:"id"};
const retained = text(await call("execute_luau",{resultId:"id",target:"client",resultPath:["returned",1,"data"],resultOffset:3}));
assert.match(retained,/retained/); assert.equal(calls.at(-1).op,"exec.result");
assert.equal(calls.at(-1).params.source,undefined); assert.deepEqual(calls.at(-1).params.resultPath,["returned",1,"data"]);
assert((await call("execute_luau",{resultId:"id",source:"print('bad')"})).isError);
assert((await call("execute_luau",{resultId:"id",target:"live"})).isError);
assert((await call("execute_luau",{})).isError);
let first;
context.bridge.call = async (op, params) => {
  if (op === "capture.playtestId") { first = params; return {contentId:"texture",region:{x:1,y:2,width:3,height:4,viewportWidth:800}}; }
  assert.equal(op,"capture.decode"); assert.equal(params.region.viewportWidth,800);
  return {encoding:"png",data:"",width:100,height:100,sourceWidth:800,sourceHeight:800,bytes:0,context:"playtest client",region:params.region};
};
await call("screenshot",{path:"Players.Alice.PlayerGui.ClientOnly",player:"Alice"});
assert.equal(first.path,"Players.Alice.PlayerGui.ClientOnly"); assert.equal(first.player,"Alice");
console.log("v0.9.0 tools: client routing, handles, target guards, watch, snapshot retrieval and client crops pass");
