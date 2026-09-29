#!/usr/bin/env node
/**
 * `sync` against a real Studio, through the real MCP layer.
 *
 * Everything happens inside ServerStorage.__mcp_live_sync and a temp folder;
 * both are removed before exit, pass or fail. Checks the things an offline fake
 * cannot: the plugin's scan, the editor write path, identity kept across a
 * rename, build files round-tripping real property values, and watch mode
 * reacting to real file and editor events.
 *
 * Usage: node scripts/test-live-sync.mjs [--port 44755] [--studio-id ID]
 */
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";
import { existsSync, mkdtempSync, readFileSync, renameSync, rmSync, unlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const args = process.argv.slice(2);
const flag = (name) => {
  const at = args.indexOf(`--${name}`);
  return at === -1 ? undefined : args[at + 1];
};
const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const FIXTURE = "ServerStorage.__mcp_live_sync";
const dir = mkdtempSync(join(tmpdir(), "rbx-live-sync-"));
const base = `ServerStorage/__mcp_live_sync`;
const file = (relative) => join(dir, ...`${base}/${relative}`.split("/"));

const client = new Client({ name: "test-live-sync", version: "0" });
await client.connect(
  new StdioClientTransport({
    command: process.execPath,
    args: [join(root, "dist", "index.js"), ...(flag("port") ? ["--port", flag("port")] : [])],
    stderr: "inherit",
  }),
);

let failures = 0;
const studioId = flag("studio-id");

async function call(name, params = {}) {
  const started = performance.now();
  try {
    const result = await client.callTool(
      { name, arguments: { ...(studioId ? { studioId } : {}), ...params } },
      undefined,
      { timeout: 180_000 },
    );
    const text = (result.content ?? []).filter((part) => part.type === "text").map((part) => part.text).join("\n");
    return { text, isError: result.isError === true, ms: Math.round(performance.now() - started) };
  } catch (cause) {
    return { text: cause.message, isError: true, ms: Math.round(performance.now() - started) };
  }
}

function report(label, good, detail = "") {
  if (!good) failures += 1;
  process.stdout.write(`${good ? "ok  " : "FAIL"}  ${label.padEnd(52)} ${detail.replace(/\s+/g, " ").slice(0, good ? 90 : 400)}\n`);
}

async function check(label, name, params, expect = /./) {
  const reply = await call(name, params);
  report(label, !reply.isError && expect.test(reply.text), `${reply.ms}ms ${reply.text}`);
  return reply.text;
}

/** Runs Luau in the edit session and returns what it returned, as text. */
async function luau(source) {
  const reply = await call("execute_luau", { source });
  if (reply.isError) throw new Error(reply.text);
  return reply.text;
}

const sync = (op, extra = {}) => ({ op, dir, roots: [FIXTURE], ...extra });
// The first lines that differ, for a readable failure.
const diffOf = (before, after) => {
  const a = before.split("\n");
  const b = after.split("\n");
  const at = a.findIndex((line, index) => line !== b[index]);
  return `line ${at + 1}: ${a[at]?.trim()}  ->  ${b[at]?.trim()}`;
};
const read = (relative) => readFileSync(file(relative), "utf8");
const until = async (probe, seconds = 8) => {
  const deadline = Date.now() + seconds * 1000;
  for (;;) {
    if (await probe()) return true;
    if (Date.now() > deadline) return false;
    await new Promise((resolve) => setTimeout(resolve, 250));
  }
};

try {
  await luau(`
    local old = game.ServerStorage:FindFirstChild("__mcp_live_sync")
    if old then old:Destroy() end
    local fixture = Instance.new("Folder"); fixture.Name = "__mcp_live_sync"
    local shared = Instance.new("Folder"); shared.Name = "Shared"; shared.Parent = fixture
    local util = Instance.new("ModuleScript"); util.Name = "Util"; util.Source = "return 1\\n"; util:SetAttribute("Marker", "util"); util.Parent = shared
    local main = Instance.new("Script"); main.Name = "Main"; main.Source = "print('main')\\n"; main.Parent = fixture
    local helper = Instance.new("ModuleScript"); helper.Name = "Helper"; helper.Source = "return 'helper'\\n"; helper.Parent = main
    local gui = Instance.new("ScreenGui"); gui.Name = "Gui"; gui.ResetOnSpawn = false; gui.Parent = fixture
    local panel = Instance.new("Frame"); panel.Name = "Panel"; panel.Size = UDim2.new(0, 200, 0, 100); panel.BackgroundColor3 = Color3.new(1, 0.5, 0); panel.Parent = gui
    local title = Instance.new("TextLabel"); title.Name = "Title"; title.Text = "Hello"; title.Parent = panel
    local client = Instance.new("LocalScript"); client.Name = "GuiClient"; client.Source = "-- gui\\n"; client:SetAttribute("Marker", "gui"); client.Parent = panel
    fixture.Parent = game.ServerStorage
    return "ready"`);

  // Pull: the tree lands on disk, Rojo-style.
  await check("pull: first sync writes every script", "sync", sync("pull"), /4 created on disk/);
  report("pull: script with children is a folder + init", existsSync(file("Main/init.server.luau")) && read("Main/Helper.luau") === "return 'helper'\n");
  report("pull: LocalScript and ModuleScript extensions", existsSync(file("Gui/Panel/GuiClient.client.luau")) && read("Shared/Util.luau") === "return 1\n");
  await check("status: nothing to do right after", "sync", sync("status"), /nothing to do/);

  // Push: a file edit reaches the editor buffer.
  writeFileSync(file("Shared/Util.luau"), "return 2\n");
  await check("push: edited file", "sync", sync("push"), /1 written to Studio/);
  await check("push: Studio has the new text", "script_read", { paths: [`${FIXTURE}.Shared.Util`] }, /return 2/);

  // Pull: an editor edit reaches the file.
  await check("studio edit through script_edit", "script_edit", { edits: [{ path: `${FIXTURE}.Main.Helper`, find: "'helper'", replace: "'studio'" }] });
  await check("sync: Studio edit comes back", "sync", sync("sync"), /1 written to disk/);
  report("file has the Studio edit", read("Main/Helper.luau") === "return 'studio'\n", read("Main/Helper.luau"));

  // New file in a new folder: a new script, under a new Folder.
  writeFileSync(file("Shared/New.luau"), "return 'new'\n");
  await check("new file becomes a script", "sync", sync("sync"), /1 created in Studio/);
  const created = await luau(`return game.ServerStorage.__mcp_live_sync.Shared.New.Source`);
  report("new script has the file's text", created.includes("return 'new'"), created);

  // Rename a file: the SAME script is renamed (its attribute survives).
  renameSync(file("Shared/Util.luau"), file("Shared/Tools.luau"));
  await check("renamed file moves the script", "sync", sync("sync"), /1 moved in Studio/);
  const marker = await luau(`local s = game.ServerStorage.__mcp_live_sync.Shared:FindFirstChild("Tools"); return if s then s:GetAttribute("Marker") else "missing"`);
  report("same instance: attribute kept across rename", marker.includes("util"), marker);

  // Both sides changed: a conflict that touches neither side.
  writeFileSync(file("Shared/Tools.luau"), "return 'disk'\n");
  await luau(`game:GetService("ScriptEditorService"):UpdateSourceAsync(game.ServerStorage.__mcp_live_sync.Shared.Tools, function() return "return 'editor'\\n" end) return 1`);
  await check("conflict is reported", "sync", sync("sync"), /Conflicts[\s\S]*Tools\.luau/);
  report("conflict left the file alone", read("Shared/Tools.luau") === "return 'disk'\n");
  await check("prefer disk settles it", "sync", sync("sync", { prefer: "disk" }), /1 written to Studio/);
  await check("Studio took the disk side", "script_read", { paths: [`${FIXTURE}.Shared.Tools`] }, /return 'disk'/);

  // Delete a file: the script is deleted (undoably).
  unlinkSync(file("Shared/New.luau"));
  await check("deleted file deletes the script", "sync", sync("sync"), /1 deleted in Studio[\s\S]*MCP sync/);
  const gone = await luau(`return game.ServerStorage.__mcp_live_sync.Shared:FindFirstChild("New") == nil`);
  report("script is gone", gone.includes("true"), gone);

  // Build files: export, edit, rebuild -- scripts carried across.
  await check("export a ScreenGui", "sync", { op: "export", dir, roots: [FIXTURE], paths: [`${FIXTURE}.Gui`] }, /Gui\.build\.json/);
  const spec = JSON.parse(read("Gui.build.json"));
  const title = spec.children[0].children.find((child) => child.name === "Title");
  report("export holds non-default values only", spec.properties?.ResetOnSpawn === false && title?.properties?.Text === "Hello" && !("Visible" in (title.properties ?? {})), JSON.stringify(spec).slice(0, 300));
  report("export leaves scripts out", !JSON.stringify(spec).includes("GuiClient"));
  title.properties.Text = "Rebuilt";
  writeFileSync(file("Gui.build.json"), `${JSON.stringify(spec, null, 2)}\n`);
  await check("build rebuilds from the edited file", "sync", { op: "build", dir, roots: [FIXTURE] }, /Gui\.build\.json/);
  const rebuilt = await luau(`
    local gui = game.ServerStorage.__mcp_live_sync.Gui
    local client = gui.Panel:FindFirstChild("GuiClient")
    return gui.Panel.Title.Text .. "|" .. tostring(client and client:GetAttribute("Marker")) .. "|" .. tostring(gui.Panel.BackgroundColor3)`);
  report("rebuilt text, same script, colour kept", rebuilt.includes("Rebuilt|gui|1, 0.5") || rebuilt.includes("Rebuilt|gui|1, 0.50"), rebuilt);

  // Build files must round-trip every kind of value exactly, and references
  // inside a rebuilt tree must point into the NEW tree, not the old one.
  await luau(`
    local fixture = game.ServerStorage.__mcp_live_sync
    local model = Instance.new("Model"); model.Name = "Rig"
    local a = Instance.new("Part"); a.Name = "A"; a.Anchored = true; a.Material = Enum.Material.Neon; a.BrickColor = BrickColor.new("Bright red")
    a.CFrame = CFrame.new(1, 2, 3) * CFrame.Angles(0, math.rad(45), 0); a.Size = Vector3.new(2, 3, 4); a.Parent = model
    local b = Instance.new("Part"); b.Name = "B"; b.Shape = Enum.PartType.Ball; b.Color = Color3.fromRGB(10, 200, 30); b.Position = Vector3.new(5, 2, 3); b.Parent = model
    local weld = Instance.new("WeldConstraint"); weld.Name = "Weld"; weld.Part0 = a; weld.Part1 = b; weld.Parent = model
    local pointer = Instance.new("ObjectValue"); pointer.Name = "Pointer"; pointer.Value = b; pointer.Parent = model
    model.PrimaryPart = a
    local gui = Instance.new("Frame"); gui.Name = "Card"; gui.Size = UDim2.new(0.5, 10, 0, 40); gui.Parent = model
    local corner = Instance.new("UICorner"); corner.CornerRadius = UDim.new(0, 12); corner.Parent = gui
    local gradient = Instance.new("UIGradient")
    gradient.Color = ColorSequence.new({ ColorSequenceKeypoint.new(0, Color3.new(1, 0, 0)), ColorSequenceKeypoint.new(1, Color3.new(0, 0, 1)) })
    gradient.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0), NumberSequenceKeypoint.new(1, 0.5) })
    gradient.Rotation = 90; gradient.Parent = gui
    local label = Instance.new("TextLabel"); label.Name = "Label"; label.Text = "Tag"; label.RichText = true
    label.FontFace = Font.new("rbxasset://fonts/families/GothamSSm.json", Enum.FontWeight.Bold, Enum.FontStyle.Italic); label.Parent = gui
    local image = Instance.new("ImageLabel"); image.Name = "Icon"; image.Image = "rbxassetid://123456"; image.ScaleType = Enum.ScaleType.Slice
    image.SliceCenter = Rect.new(4, 4, 12, 12); image.Parent = gui
    model.Parent = fixture
    return 1`);
  await check("export a tree of many value types", "sync", { op: "export", dir, roots: [FIXTURE], paths: [`${FIXTURE}.Rig`] }, /Rig\.build\.json/);
  const exportedRig = read("Rig.build.json");
  report(
    "references export as paths into the tree",
    exportedRig.includes(`"Part0": "${FIXTURE}.Rig.A"`) && exportedRig.includes(`"PrimaryPart": "${FIXTURE}.Rig.A"`),
    exportedRig.slice(0, 200),
  );
  const missing = ["FontFace", "\"Size\": \"2, 3, 4\"", "\"Shape\"", '"Color"', '"Transparency"', "SliceCenter", "CornerRadius", "Material", "CFrame", "Part0", "Part1", "RichText", "rbxassetid://123456"]
    .filter((needle) => !exportedRig.includes(needle));
  report("every value type made it into the file", missing.length === 0, missing.join(", "));
  // Rebuild from the untouched file, then export again: nothing may drift.
  await check("rebuild from the same file", "sync", { op: "build", dir, roots: [FIXTURE], files: [`${base}/Rig.build.json`], prefer: "disk" }, /Rig\.build\.json/);
  await check("export the rebuilt tree", "sync", { op: "export", dir, roots: [FIXTURE], paths: [`${FIXTURE}.Rig`] }, /Rig\.build\.json/);
  const again = read("Rig.build.json");
  report("round trip is lossless", again === exportedRig, again === exportedRig ? "" : diffOf(exportedRig, again));
  const wired = await luau(`
    local rig = game.ServerStorage.__mcp_live_sync.Rig
    local weld = rig.Weld
    return tostring(weld.Part0 == rig.A and weld.Part1 == rig.B and rig.Pointer.Value == rig.B and rig.PrimaryPart == rig.A)
      .. "|" .. tostring(#game.ServerStorage.__mcp_live_sync:GetChildren())`);
  report("references point into the new tree, old tree gone", wired.includes("true|4"), wired);

  // Watch: both directions within seconds, with no call in between.
  await check("watch starts", "sync", sync("watch"), /Watching/);
  writeFileSync(file("Main/Helper.luau"), "return 'watched'\n");
  const toStudio = await until(async () => (await luau(`return game.ServerStorage.__mcp_live_sync.Main.Helper.Source`)).includes("watched"));
  report("watch: file edit reaches Studio", toStudio);
  await luau(`game:GetService("ScriptEditorService"):UpdateSourceAsync(game.ServerStorage.__mcp_live_sync.Main.Helper, function() return "return 'from studio'\\n" end) return 1`);
  const toDisk = await until(async () => read("Main/Helper.luau") === "return 'from studio'\n");
  report("watch: Studio edit reaches the file", toDisk, read("Main/Helper.luau"));
  await check("watch: status shows it running", "sync", sync("status"), /Watching since/);
  await check("watch stops", "sync", sync("stop"), /Stopped watching/);
} catch (cause) {
  report("run", false, String(cause?.stack ?? cause));
} finally {
  await call("sync", { op: "stop", dir }).catch(() => undefined);
  await luau(`local f = game.ServerStorage:FindFirstChild("__mcp_live_sync") if f then f:Destroy() end return 1`).catch(() => undefined);
  rmSync(dir, { recursive: true, force: true });
  await client.close();
}

process.stdout.write(failures === 0 ? "\nlive sync: ok\n" : `\nlive sync: ${failures} failure(s)\n`);
process.exit(failures === 0 ? 0 : 1);
