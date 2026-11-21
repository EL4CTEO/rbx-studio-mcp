#!/usr/bin/env node
/**
 * Live checks for Studio's Copy-as-JSON format and frame sequences, through the
 * real MCP layer against a connected Studio (edit session).
 *
 * Everything it makes is under Workspace.__mcp_live_json and is deleted before it
 * exits, pass or fail. The camera is not moved.
 *
 * Usage: node scripts/test-live-json-frames.mjs [--studio-id ID]
 *   RBX_MCP_BINARY=path  test a server build other than server/target/release
 */
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";
import { nativeBinary, root } from "./lib/native.mjs";

const args = process.argv.slice(2);
const at = args.indexOf("--studio-id");
const studioId = at === -1 ? undefined : args[at + 1];
const version = JSON.parse(readFileSync(resolve(root, "package.json"), "utf8")).version;
const client = new Client({ name: "test-live-json-frames", version });
await client.connect(new StdioClientTransport({ command: nativeBinary(), args: [], stderr: "inherit" }));

const FIXTURE = "Workspace.__mcp_live_json";
const text = (r) => r.content.filter((p) => p.type === "text").map((p) => p.text).join("\n");
async function call(name, args = {}) {
  const r = await client.callTool({ name, arguments: { ...args, ...(studioId ? { studioId } : {}) } }, undefined, { timeout: 120000 });
  if (r.isError) throw new Error(`${name}: ${text(r)}`);
  return r;
}

let failures = 0;
async function check(name, fn) {
  try {
    await fn();
    console.log(`ok   ${name}`);
  } catch (e) {
    failures++;
    console.log(`FAIL ${name}: ${e.message}`);
  }
}

try {
  await call("create", { instances: [{ parent: "Workspace", className: "Folder", name: "__mcp_live_json" }] });

  await check("create json= makes instances with properties, attributes and tags", async () => {
    await call("create", {
      parent: FIXTURE,
      json: JSON.stringify([
        { ClassName: "Part", Name: "Pasted", Anchored: "true", Size: "4, 1, 2", "$Speed": 1.5, ".Hit": true },
        { ClassName: "Folder", Name: "Box" },
      ]),
    });
    const r = JSON.parse(text(await call("inspect", { paths: [`${FIXTURE}.Pasted`], properties: ["Anchored", "Size"] })).split("\n\n")[0]);
    const item = r[0];
    assert.equal(item.properties.Anchored, true);
    assert.equal(item.properties.Size, "4, 1, 2");
    assert.equal(item.attributes.Speed, 1.5);
    assert.deepEqual(item.tags, ["Hit"]);
  });

  await check("inspect format=studio-json writes only non-defaults and round-trips", async () => {
    const out = text(await call("inspect", { paths: [`${FIXTURE}.Pasted`], format: "studio-json" }));
    const json = JSON.parse(out.slice(0, out.lastIndexOf("}") + 1));
    assert.equal(json.ClassName, "Part");
    assert.equal(json.Name, "Pasted");
    assert.equal(json.Anchored, "true");
    assert.equal(json["$Speed"], 1.5);
    assert.equal(json[".Hit"], true);
    assert.equal(json.CastShadow, undefined, "a default property was written");
    await call("create", { parent: FIXTURE, json: { ...json, Name: "Copy" } });
    const again = text(await call("inspect", { paths: [`${FIXTURE}.Copy`], format: "studio-json" }));
    const copy = JSON.parse(again.slice(0, again.lastIndexOf("}") + 1));
    assert.deepEqual({ ...copy, Name: "Pasted" }, json);
  });

  await check("modify json= pastes onto an existing instance", async () => {
    await call("modify", { targets: [{ paths: [`${FIXTURE}.Copy`], json: { ClassName: "Part", Transparency: "0.5", ".Hit": false } }] });
    const r = JSON.parse(text(await call("inspect", { paths: [`${FIXTURE}.Copy`], properties: ["Transparency"] })).split("\n\n")[0]);
    assert.equal(r[0].properties.Transparency, 0.5);
    assert.equal(r[0].tags, undefined);
  });

  await check("bad json is refused with a hint, nothing created", async () => {
    const r = await client.callTool({ name: "create", arguments: { parent: FIXTURE, json: "{not json" } });
    assert.ok(r.isError && /BAD_JSON|not valid JSON/.test(text(r)), text(r));
  });

  await check("screenshot frames=4 returns one contact sheet", async () => {
    const r = await call("screenshot", { frames: 4, intervalMs: 100 });
    const images = r.content.filter((p) => p.type === "image");
    assert.equal(images.length, 1);
    const png = Buffer.from(images[0].data, "base64");
    assert.equal(png.toString("ascii", 1, 4), "PNG");
    const caption = text(r);
    assert.match(caption, /4 frames as a 2x2 contact sheet/);
    console.log(`     ${caption}`);
  });

  await check("screenshot without frames is unchanged", async () => {
    const r = await call("screenshot", {});
    assert.match(text(r), /Studio viewport \(edit\), \d+x\d+/);
  });
} finally {
  await client.callTool({ name: "delete", arguments: { paths: [FIXTURE], ...(studioId ? { studioId } : {}) } }).catch(() => {});
  await client.close();
}
process.exit(failures ? 1 : 0);
