#!/usr/bin/env node
/**
 * `sync` at scale, against a real Studio: thousands of scripts, same-named
 * siblings, a source past the `.Source` limit -- timed, so a slowdown shows up
 * as a number rather than as a watch that "feels laggy".
 *
 * Builds ServerStorage.__mcp_sync_scale and a temp folder, and removes both.
 *
 * Usage: node scripts/test-live-sync-scale.mjs [--scripts 2000] [--port 44755] [--studio-id ID]
 */
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const args = process.argv.slice(2);
const flag = (name, fallback) => {
  const at = args.indexOf(`--${name}`);
  return at === -1 ? fallback : args[at + 1];
};
const COUNT = Number(flag("scripts", "2000"));
const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const FIXTURE = "ServerStorage.__mcp_sync_scale";
const dir = mkdtempSync(join(tmpdir(), "rbx-sync-scale-"));
const file = (relative) => join(dir, "ServerStorage", "__mcp_sync_scale", ...relative.split("/"));
const studioId = flag("studio-id");

const client = new Client({ name: "test-live-sync-scale", version: "0" });
await client.connect(
  new StdioClientTransport({
    command: process.execPath,
    args: [join(root, "dist", "index.js"), ...(flag("port") ? ["--port", flag("port")] : [])],
    stderr: "inherit",
  }),
);

let failures = 0;
const timings = [];
async function call(name, params = {}) {
  const started = performance.now();
  const result = await client.callTool({ name, arguments: { ...(studioId ? { studioId } : {}), ...params } }, undefined, { timeout: 600_000 });
  const text = (result.content ?? []).filter((part) => part.type === "text").map((part) => part.text).join("\n");
  return { text, isError: result.isError === true, ms: Math.round(performance.now() - started) };
}
function report(label, good, detail = "") {
  if (!good) failures += 1;
  process.stdout.write(`${good ? "ok  " : "FAIL"}  ${label.padEnd(48)} ${detail.replace(/\s+/g, " ").slice(0, good ? 100 : 400)}\n`);
}
async function timed(label, name, params, expect = /./) {
  const reply = await call(name, params);
  timings.push([label, reply.ms]);
  report(label, !reply.isError && expect.test(reply.text), `${reply.ms}ms  ${reply.text}`);
  return reply;
}
const luau = async (source) => {
  const reply = await call("execute_luau", { source });
  if (reply.isError) throw new Error(reply.text);
  return reply.text;
};
const sync = (op, extra = {}) => ({ op, dir, roots: [FIXTURE], ...extra });
const until = async (probe, seconds = 10) => {
  const started = Date.now();
  for (;;) {
    if (await probe()) return Date.now() - started;
    if (Date.now() - started > seconds * 1000) return -1;
    await new Promise((resolve) => setTimeout(resolve, 50));
  }
};

try {
  // A place-shaped tree: 40 folders of modules with realistic bodies, two
  // same-named siblings, and one script too long for `.Source`.
  await luau(`
    local old = game.ServerStorage:FindFirstChild("__mcp_sync_scale")
    if old then old:Destroy() end
    local fixture = Instance.new("Folder"); fixture.Name = "__mcp_sync_scale"
    local body = string.rep("local value = math.random() * 100 -- padding to look like real code\\n", 30)
    for f = 1, 40 do
      local folder = Instance.new("Folder"); folder.Name = "Feature" .. f; folder.Parent = fixture
      for s = 1, math.floor(${COUNT} / 40) do
        local module = Instance.new("ModuleScript"); module.Name = "Module" .. s
        module.Source = "-- " .. f .. "/" .. s .. "\\n" .. body .. "return {}\\n"
        module.Parent = folder
      end
    end
    local a = Instance.new("ModuleScript"); a.Name = "Dup"; a.Source = "return 'first'\\n"; a:SetAttribute("Which", "first"); a.Parent = fixture
    local b = Instance.new("ModuleScript"); b.Name = "Dup"; b.Source = "return 'second'\\n"; b:SetAttribute("Which", "second"); b.Parent = fixture
    fixture.Parent = game.ServerStorage
    local big = Instance.new("ModuleScript"); big.Name = "Big"; big.Parent = fixture
    game:GetService("ScriptEditorService"):UpdateSourceAsync(big, function() return string.rep("-- a long generated table row\\n", 12000) .. "return {}\\n" end)
    return "ok"`);

  await timed(`pull ${COUNT + 3} scripts`, "sync", sync("pull"), new RegExp(`${COUNT + 3} created on disk`));
  await timed("no-op sync (nothing changed)", "sync", sync("sync"), /nothing to do/);
  await timed("no-op sync again (revision cache warm)", "sync", sync("sync"), /nothing to do/);

  writeFileSync(file("Feature7/Module3.luau"), "return 'edited'\n");
  await timed("one file edited", "sync", sync("sync"), /1 written to Studio/);
  const edited = await luau(`return game.ServerStorage.__mcp_sync_scale.Feature7.Module3.Source`);
  report("the right script took it", edited.includes("edited"), edited);

  // Same-named siblings: two files, each bound to its own script.
  report("duplicate names get two files", existsSync(file("Dup.luau")) && existsSync(file("Dup~2.luau")));
  const second = readFileSync(file("Dup~2.luau"), "utf8").includes("second") ? "Dup~2.luau" : "Dup.luau";
  writeFileSync(file(second), "return 'second, edited'\n");
  await timed("edit one of two same-named scripts", "sync", sync("sync"), /1 written to Studio/);
  const which = await luau(`
    for _, s in game.ServerStorage.__mcp_sync_scale:GetChildren() do
      if s.Name == "Dup" and string.find(s.Source, "edited") then return s:GetAttribute("Which") end
    end
    return "none"`);
  report("edit landed on the matching duplicate", which.includes("second"), which);

  // Past the .Source limit: round trip through the editor path.
  const big = readFileSync(file("Big.luau"), "utf8");
  report("large script pulled whole", big.length > 300_000, `${big.length} chars`);
  writeFileSync(file("Big.luau"), `${big}-- appended\n`);
  await timed("push a 360KB script", "sync", sync("sync"), /1 written to Studio/);
  const tail = await luau(`local s = game.ServerStorage.__mcp_sync_scale.Big.Source return string.sub(s, -12)`);
  report("large script edit landed", tail.includes("appended"), tail);

  // Watch latency at this size.
  await timed("watch start", "sync", sync("watch"), /Watching|Already/);
  writeFileSync(file("Feature20/Module5.luau"), "return 'watched'\n");
  const toStudio = await until(async () => (await luau(`return game.ServerStorage.__mcp_sync_scale.Feature20.Module5.Source`)).includes("watched"));
  timings.push(["watch: file -> Studio", toStudio]);
  report("watch: file edit reached Studio", toStudio >= 0, `${toStudio}ms`);
  await luau(`game:GetService("ScriptEditorService"):UpdateSourceAsync(game.ServerStorage.__mcp_sync_scale.Feature21.Module6, function() return "return 'from studio'\\n" end) return 1`);
  const toDisk = await until(() => readFileSync(file("Feature21/Module6.luau"), "utf8").includes("from studio"));
  timings.push(["watch: Studio -> file", toDisk]);
  report("watch: Studio edit reached the file", toDisk >= 0, `${toDisk}ms`);
  await new Promise((resolve) => setTimeout(resolve, 3_000));
  const status = await call("sync", sync("status"));
  report("watch settles: echoes skipped, not re-synced", /echo/.test(status.text), status.text.split("\n").slice(-1)[0]);
  await call("sync", sync("stop"));
} catch (cause) {
  report("run", false, String(cause?.stack ?? cause));
} finally {
  await call("sync", { op: "stop", dir }).catch(() => undefined);
  await luau(`local f = game.ServerStorage:FindFirstChild("__mcp_sync_scale") if f then f:Destroy() end return 1`).catch(() => undefined);
  rmSync(dir, { recursive: true, force: true });
  await client.close();
}

process.stdout.write("\ntimings\n");
for (const [label, ms] of timings) process.stdout.write(`  ${label.padEnd(44)} ${ms}ms\n`);
process.stdout.write(failures === 0 ? "\nlive sync scale: ok\n" : `\nlive sync scale: ${failures} failure(s)\n`);
process.exit(failures === 0 ? 0 : 1);
