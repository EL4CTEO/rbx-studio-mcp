/** v0.9.0 live regressions. Editor reads only; all fixtures are playtest-local. */
import assert from "node:assert/strict";
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { inflateSync } from "node:zlib";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";
import { resolve } from "node:path";

const version = JSON.parse(readFileSync(resolve("package.json"), "utf8")).version;
const requestedId = process.argv[process.argv.indexOf("--studio-id") + 1];
const client = new Client({ name: "test-live-v090", version });
await client.connect(new StdioClientTransport({ command: process.execPath, args: [resolve("dist/index.js")], stderr: "inherit" }));
const reports = [];
const fixture = "Workspace.__mcp_v090_test";
let runtimeId;
let editorId;
let startedHere = false;
let failures = 0;
function text(result) { return result.content.filter(part => part.type === "text").map(part => part.text).join("\n"); }
async function call(name, args = {}, wanted = runtimeId ?? editorId) {
  const result = await client.callTool({ name, arguments: { ...args, ...(wanted ? { studioId: wanted } : {}) } }, undefined, { timeout: 120000 });
  if (result.isError) throw new Error(text(result));
  return result;
}
const content = async (...args) => text(await call(...args));
async function check(name, run) {
  const started = Date.now();
  try {
    const details = await run(); reports.push({ name, ok: true, ms: Date.now() - started, details });
    console.log(`ok   ${name}`);
  } catch (error) {
    failures++; reports.push({ name, ok: false, error: error.message, ms: Date.now() - started });
    console.log(`FAIL ${name}: ${error.message}`);
  }
}
// These PNGs come from the server's RGB encoder, which uses unfiltered rows.
// Check the fixture's actual pixels, rather than merely accepting an image.
function assertFixturePixels(data, color) {
  const png = Buffer.from(data, "base64");
  const width = png.readUInt32BE(16), height = png.readUInt32BE(20);
  assert.equal(png[25], 2, "expected RGB PNG");
  const chunks = [];
  for (let offset = 8; offset < png.length;) {
    const length = png.readUInt32BE(offset);
    if (png.toString("ascii", offset + 4, offset + 8) === "IDAT") chunks.push(png.subarray(offset + 8, offset + 8 + length));
    offset += length + 12;
  }
  const raw = inflateSync(Buffer.concat(chunks));
  const stride = width * 3 + 1;
  let matches = 0;
  for (let y = 0; y < height; y++) {
    assert.equal(raw[y * stride], 0, "expected unfiltered PNG row");
    for (let x = 0; x < width; x++) {
      const offset = y * stride + x * 3 + 1;
      if (color.every((value, channel) => Math.abs(raw[offset + channel] - value) <= 2)) matches++;
    }
  }
  assert(matches / (width * height) > 0.65, `fixture occupies only ${(100 * matches / (width * height)).toFixed(1)}% of crop`);
}
try {
  const listing = JSON.parse((await content("list_studios", {}, null)).split("\n\nWARNING")[0]);
  const editors = listing.studios.filter(studio => studio.context === "edit");
  const editor = process.argv.includes("--studio-id")
    ? editors.find(studio => studio.studioId === requestedId)
    : editors.length === 1 ? editors[0] : undefined;
  assert(editor, "Connect one editor or choose one with --studio-id ID");
  assert.equal(editor.pluginVersion, version, "live checks require the new plugin");
  assert.equal(editor.stale, false, "live plugin must match this source build");
  editorId = editor.studioId;
  const state = JSON.parse((await content("playtest", { op: "state" }, editorId)).split("\n\n")[0]);
  const existingTest = listing.studios.some(studio =>
    studio.placeId === editor.placeId && studio.context?.includes("playtest"));
  assert(state.isEdit && !state.isRunning && !state.testPending && state.editModeActive !== false && !existingTest,
    "stop the existing playtest before running these checks");
  const baseline = await content("execute_luau", { source: "return game:GetAttributes(), #workspace:GetChildren()" }, editorId);
  startedHere = true;
  const started = await content("playtest", { op: "play" }, editorId);
  runtimeId = started.match(/"studioId"\s*:\s*"([^"]+)"/)?.[1];
  assert(runtimeId && runtimeId !== editorId, `No playtest session: ${started}`);
  await call("create", { instances: [{ className: "Folder", name: "__mcp_v090_test", parent: "Workspace" }] });

  await check("all basic write tools work during a playtest", async () => {
    await call("create", { instances: [
      { className: "Part", name: "Twin", parent: fixture, properties: { Anchored: true, Position: "0, 10000, -20", Size: "20, 20, 2" } },
      { className: "Part", name: "Twin", parent: fixture, properties: { Anchored: true, Position: "40, 10000, -20" } },
      { className: "Folder", name: "Dr. Who", parent: fixture },
    ] });
    await call("modify", { targets: [{ paths: [`${fixture}.Twin`], properties: { Color: "#FF8800" } }] });
    await call("create", { instances: [{ className: "Folder", name: "Moved", parent: fixture }] });
    await call("move", { items: [{ path: `${fixture}.Moved`, to: `${fixture}.Dr. Who` }] });
    assert.match(await content("inspect", { paths: [`${fixture}.Dr. Who.Moved`], detail: "concise" }), /Folder/);
    await call("delete", { paths: [`${fixture}.Dr. Who.Moved`] });
  });
  await check("Font enum and FontFace keep distinct conversion types", async () => {
    await call("create", { instances: [
      { className: "TextLabel", name: "EnumFont", parent: fixture, properties: { Font: "Code" } },
      { className: "TextLabel", name: "FaceFont", parent: fixture, properties: { FontFace: "Code" } },
    ] });
    assert.match(await content("inspect", { paths: [`${fixture}.EnumFont`], properties: ["Font"] }), /Enum.Font.Code/);
  });
  await check("script edits keep stale-revision protection during playtests", async () => {
    await call("create", { instances: [{ className: "ModuleScript", name: "EditFixture", parent: fixture, properties: { Source: "return {value=1}" } }] });
    const read = await content("script_read", {paths:[`${fixture}.EditFixture`]});
    const revision = read.match(/rev ([0-9a-f]+-[0-9a-f]+)/)?.[1]; assert(revision, read);
    await call("script_edit", {edits:[{path:`${fixture}.EditFixture`,find:"value=1",replace:"value=2",revision}]});
    assert.match(await content("script_read", {paths:[`${fixture}.EditFixture`]}),/value=2/);
    const stale = await client.callTool({name:"script_edit",arguments:{studioId:runtimeId,edits:[{path:`${fixture}.EditFixture`,source:"return {}",revision}]} });
    assert(stale.isError && text(stale).includes("STALE_SCRIPT"));
  });
  await check("handles survive rename and refuse deletion", async () => {
    const found = JSON.parse(await content("inspect", { paths: [`${fixture}.Twin[1]`], detail: "concise", handles: true }));
    const handle = found[0].handle;
    assert(handle);
    await call("modify", { targets: [{ paths: [handle], properties: { Name: "Renamed" } }] });
    assert.match(await content("inspect", { paths: [handle], properties: ["Name"] }), /Renamed/);
    await call("delete", { paths: [handle] });
    assert.match(await content("inspect", { paths: [handle], detail: "concise" }), /expired|destroyed/i);
  });
  await check("Studio results retrieve every row without rerunning mutations", async () => {
    const result = await content("execute_luau", { source: `local root = workspace.__mcp_v090_test; root:SetAttribute("Runs", (root:GetAttribute("Runs") or 0)+1); local rows={}; for i=1,140 do rows[i]={index=i, label="row"..i, extra=true} end; return rows` });
    const resultId = result.match(/resultId="([^"]+)"/)?.[1]; assert(resultId, result);
    let offset = 0; const indexes = [];
    do {
      const page = JSON.parse(await content("execute_luau", { resultId, resultOffset: offset, resultLimit: 40, resultFields: ["index"] }));
      assert.equal(page.retainedTruncated, false);
      for (const item of page.items) { indexes.push(item.value.index); assert.equal(item.value.extra, undefined); }
      offset = page.nextOffset;
    } while (offset !== undefined);
    assert.deepEqual(indexes, Array.from({ length: 140 }, (_, index) => index + 1));
    assert.match(await content("inspect", { paths: [fixture], detail: "concise" }), /"Runs":1/);
  });

  let player;
  await check("actual client executes and returns same-named siblings", async () => {
    const result = await content("execute_luau", { target: "client", source: `local Players=game:GetService("Players"); local gui=Players.LocalPlayer.PlayerGui; local screen=Instance.new("ScreenGui"); screen.Name="__mcp_v090_ui"; screen.IgnoreGuiInset=true; screen.DisplayOrder=10000000; screen.ResetOnSpawn=false; screen.Parent=gui; for i=1,2 do local label=Instance.new("TextLabel"); label.Name="Twin"; label.Text="client-only "..i; label.TextSize=24; label.Size=UDim2.fromOffset(260,80); label.Position=UDim2.new(0.5,-130,0.5,-40+(i-1)*100); label.BackgroundColor3=Color3.fromRGB(255,0,255); label.Parent=screen end; return Players.LocalPlayer.Name, screen:GetChildren()` });
    player = result.match(/Returned:\n\[\s*"([^"]+)"/)?.[1];
    assert(player, result);
    assert.match(result, /VM=client, identity=script/);
    assert.match(result, /Twin\[1\]/); assert.match(result, /Twin\[2\]/);
  });
  if (player) {
    const guiPath = `Players.${player}.PlayerGui.__mcp_v090_ui`;
    const clientArgs = { target: "client", player };
    await check("client tree/find/inspect see client-only UI and stable duplicates", async () => {
      assert.match(await content("tree", { ...clientArgs, path: guiPath, depth: 1, handles: true }), /Twin\[1\].*Twin\[2\]/s);
      const found = await content("find", { ...clientArgs, path: guiPath, className: "TextLabel", properties: ["Text"], handles: true });
      assert.match(found, /client-only 1/); assert.match(found, /client-only 2/);
      const inspection = JSON.parse((await content("inspect", { ...clientArgs, paths: [`${guiPath}.Twin[1]`], properties: ["Text", "AbsolutePosition"], handles: true })).split("\n\n")[0]);
      const reference = inspection[0].handle;
      assert(reference);
      const again = await content("inspect", { ...clientArgs, paths: [reference], properties: ["Text"] });
      assert.match(again, new RegExp(inspection[0].properties.Text));
      const wrong = await content("inspect", { paths: [reference], detail: "concise" });
      assert.match(wrong, /another session|another.*client/);
    });
    await check("runtime UI audit measures actual PlayerGui", async () => {
      const audit = await content("viewport", { ...clientArgs, op: "ui", path: guiPath });
      assert.match(audit, /actual client/); assert.match(audit, /2 visible elements checked/);
    });
    await check("client performance snapshot has actual rendering counters", async () => {
      const snapshot = await content("performance", { ...clientArgs, op: "snapshot" });
      assert.match(snapshot, /actual playtest client/);
      assert.match(snapshot, /frameTimeMs|renderCpuMs/);
      assert(!snapshot.includes("playtest server, which does not render"));
    });
    await check("playtest screenshot crops a client-only path", async () => {
      const screenshot = await call("screenshot", { player, path: `${guiPath}.Twin[1]`, width: 480 });
      assert(screenshot.content.some(part => part.type === "image"));
      const image = screenshot.content.find(part => part.type === "image");
      writeFileSync(resolve("build/live-v090-crop.png"), Buffer.from(image.data, "base64"));
      assertFixturePixels(image.data, [255, 0, 255]);
      assert.match(text(screenshot), /playtest client.*zoomed to.*Twin\[1\]/);
      assert(!text(screenshot).includes("single flat colour"));
      return { caption: text(screenshot) };
    });
    await check("client screenshot respects GUI insets", async () => {
      await content("execute_luau", { ...clientArgs, source: `local screen=Instance.new("ScreenGui"); screen.Name="__mcp_v090_inset"; screen.IgnoreGuiInset=false; screen.DisplayOrder=10000001; screen.Parent=game:GetService("Players").LocalPlayer.PlayerGui; local frame=Instance.new("Frame"); frame.Name="Inset"; frame.Size=UDim2.fromOffset(260,80); frame.Position=UDim2.new(0.5,-130,0.5,-40); frame.BackgroundColor3=Color3.fromRGB(0,255,255); frame.Parent=screen; return true` });
      const screenshot = await call("screenshot", { player, path: `Players.${player}.PlayerGui.__mcp_v090_inset.Inset`, width: 480 });
      const image = screenshot.content.find(part => part.type === "image");
      assert(image);
      assertFixturePixels(image.data, [0, 255, 255]);
      writeFileSync(resolve("build/live-v090-inset.png"), Buffer.from(image.data, "base64"));
      return { caption: text(screenshot) };
    });
    await check("viewport pick uses the actual client camera and returns a handle", async () => {
      await content("execute_luau", { ...clientArgs, source: `local camera=workspace.CurrentCamera; local size=camera.ViewportSize; local ray=camera:ViewportPointToRay(size.X/2,size.Y/2); local part=Instance.new("Part"); part.Name="ScreenCentre"; part.Anchored=true; part.CanCollide=false; part.Size=Vector3.new(24,24,2); part.CFrame=CFrame.lookAt(ray.Origin+ray.Direction*4,ray.Origin); part.Parent=workspace.__mcp_v090_test; return true` });
      const picked = JSON.parse((await content("viewport", { ...clientArgs, op: "pick", x: 0.5, y: 0.5 })).split("\n\n")[0]);
      assert(picked.hit && picked.handle && picked.path.includes("__mcp_v090_test.ScreenCentre"), JSON.stringify(picked));
      await call("inspect", { ...clientArgs, paths: [picked.handle], properties: ["Position"] });
    });
    await check("client result snapshots survive relay cleanup; long JSON strings paginate", async () => {
      const result = await content("execute_luau", { ...clientArgs, source: `local rows={}; for i=1,180 do rows[i]={index=i,label="item🙂"..i} end; return game:GetService("HttpService"):JSONEncode(rows)` });
      const resultId = result.match(/resultId="([^"]+)"/)?.[1]; assert(resultId, result);
      let offset = 0, recovered = "";
      do {
        const page = JSON.parse(await content("execute_luau", { ...clientArgs, resultId, resultOffset: offset }));
        recovered += page.value; offset = page.nextOffset;
      } while (offset !== undefined);
      const rows = JSON.parse(recovered); assert.equal(rows.length, 180); assert.equal(rows.at(-1).index, 180);
      assert.equal(rows.at(-1).label, "item🙂180");
    });
    await check("client property/attribute/child watch and cleanup", async () => {
      // Give the watch relay time to arm before the separate mutation call.
      const watch = call("debug", { ...clientArgs, op: "watch", path: `${guiPath}.Twin[1]`, properties: ["Text"], attributes: ["Phase"], seconds: 4 });
      await new Promise(resolve => setTimeout(resolve, 1800));
      await content("execute_luau", { ...clientArgs, source: `local label=game:GetService("Players").LocalPlayer.PlayerGui.__mcp_v090_ui:FindFirstChild("Twin"); label.Text="watched"; label:SetAttribute("Phase",1); local child=Instance.new("Folder"); child.Name="WatchChild"; child.Parent=label; task.wait(); child:Destroy(); return true` });
      const observed = JSON.parse(text(await watch));
      assert(observed.items.some(item => item.kind === "property"), JSON.stringify(observed));
      assert(observed.items.some(item => item.kind === "attribute"));
      assert(observed.items.some(item => item.kind === "ChildAdded"));
      assert(observed.items.some(item => item.kind === "ChildRemoved"));
      assert.equal(observed.dropped, 0);
    });
  }
  await content("playtest", { op: "stop" }, editorId);
  startedHere = false;
  runtimeId = undefined;
  const after = await content("execute_luau", { source: "return game:GetAttributes(), #workspace:GetChildren(), workspace:FindFirstChild('__mcp_v090_test') == nil" }, editorId);
  assert.match(after, /true/);
  assert.equal(baseline.match(/Returned:\n(.*)/)?.[1], after.match(/Returned:\n(.*)/)?.[1].replace(/,true\]$/, "]"), "editor attributes and Workspace child count changed");
  reports.push({ name: "editor runtime fixture absent after stop", ok: true, baseline, after });
} catch (error) {
  failures++;
  reports.push({ name: "live run setup/cleanup", ok: false, error: error.message });
  console.error(error.message);
} finally {
  if (startedHere && editorId) await call("playtest", { op: "stop" }, editorId).catch(error => { failures++; reports.push({name:"stop cleanup",ok:false,error:error.message}); });
  await client.close();
  mkdirSync(resolve("build"), { recursive: true });
  writeFileSync(resolve("build/live-v0.9.0.json"), JSON.stringify({ date: new Date().toISOString(), failures, reports }, null, 2));
}
console.log(`v0.9.0 live: ${failures} failures`);
process.exitCode = failures ? 1 : 0;
