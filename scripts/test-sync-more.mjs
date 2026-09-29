/**
 * `sync`, offline, part two: conflicts that remember themselves, build files
 * both ways, and `watch` -- echo suppression and notices on the next reply.
 *
 * Build files go through the real create-spec typing, which reads the API
 * dump, so the dump is a small fixture in a sandboxed temp dir and the network
 * is refused: the run is the same on every machine.
 *
 * Usage: node scripts/test-sync-more.mjs   (after `npm run build`)
 */
import assert from "node:assert/strict";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";

const sandbox = mkdtempSync(path.join(tmpdir(), "rbx-sync-more-"));
for (const name of ["TMPDIR", "TEMP", "TMP"]) process.env[name] = sandbox;
globalThis.fetch = async () => {
  throw new Error("offline");
};
const property = (name, type) => ({ MemberType: "Property", Name: name, ValueType: { Name: type, Category: "Primitive" } });
mkdirSync(path.join(sandbox, "roblox-studio-mcp"), { recursive: true });
writeFileSync(
  path.join(sandbox, "roblox-studio-mcp", "api-dump.json"),
  JSON.stringify({
    fetchedAt: Date.now(),
    dump: {
      Classes: [
        { Name: "Instance", Superclass: "", Members: [property("Name", "string")] },
        { Name: "ScreenGui", Superclass: "Instance", Members: [property("ResetOnSpawn", "bool")] },
        { Name: "Frame", Superclass: "Instance", Members: [property("BackgroundTransparency", "float")] },
        { Name: "TextLabel", Superclass: "Instance", Members: [property("Text", "string")] },
      ],
      Enums: [],
    },
  }),
);

const { runBuild, runExport, runSync, startWatch, stopAllWatches, stopWatch, watchState } = await import("../dist/lib/sync.js");
const { takeNotices } = await import("../dist/lib/notices.js");
const { fakeStudio } = await import("./sync-fake.mjs");

const dir = path.join(sandbox, "work");
const file = (relative) => path.join(dir, ...relative.split("/"));
const read = (relative) => readFileSync(file(relative), "utf8");
const until = async (probe, ms = 5_000) => {
  const deadline = Date.now() + ms;
  while (!(await probe())) {
    if (Date.now() > deadline) return false;
    await new Promise((resolve) => setTimeout(resolve, 50));
  }
  return true;
};

try {
  // Conflicts remember themselves -----------------------------------------
  {
    const studio = fakeStudio();
    studio.scripts.set("ServerScriptService.Mod", { className: "ModuleScript", source: "return 1\n" });
    const sync = (extra = {}) => runSync(studio, { dir, direction: "both", ...extra });
    await sync();

    writeFileSync(file("ServerScriptService/Mod.luau"), "return 'disk'\n");
    studio.scripts.get("ServerScriptService.Mod").source = "return 'studio'\n";
    let report = await sync();
    assert.equal(report.conflicts.length, 1);
    assert.equal(read(".rbx-sync/conflicts/ServerScriptService/Mod.luau"), "return 'studio'\n", "Studio's side is kept to merge from");
    report = await sync();
    assert.equal(report.conflicts.length, 1, "still a conflict while neither side moves");
    assert.deepEqual(report.newConflicts, [], "but it is not new");

    // Resolve on disk: the merged file wins, conditionally on Studio not having moved.
    writeFileSync(file("ServerScriptService/Mod.luau"), "return 'merged'\n");
    report = await sync();
    assert.equal(report.conflicts.length, 0);
    assert.equal(studio.scripts.get("ServerScriptService.Mod").source, "return 'merged'\n");
    assert.ok(!existsSync(file(".rbx-sync/conflicts/ServerScriptService/Mod.luau")), "the sidecar goes when settled");

    // Resolve in Studio instead.
    writeFileSync(file("ServerScriptService/Mod.luau"), "return 'disk 2'\n");
    studio.scripts.get("ServerScriptService.Mod").source = "return 'studio 2'\n";
    assert.equal((await sync()).conflicts.length, 1);
    studio.scripts.get("ServerScriptService.Mod").source = "return 'fixed in studio'\n";
    report = await sync();
    assert.equal(report.conflicts.length, 0);
    assert.equal(read("ServerScriptService/Mod.luau"), "return 'fixed in studio'\n");
    // A file outside the roots is not created (and so not re-created every run).
    mkdirSync(file("Workspace"), { recursive: true });
    writeFileSync(file("Workspace/Stray.luau"), "return 'stray'\n");
    report = await sync();
    assert.ok(![...studio.scripts.keys()].some((key) => key.startsWith("Workspace")), "outside the roots: left alone");
    assert.equal(report.failures.length, 0);
    rmSync(dir, { recursive: true, force: true });
    console.log("sync conflicts: Studio's side kept beside, reported once, settled by whichever side moves");
  }

  // Build files, both ways --------------------------------------------------
  {
    const studio = fakeStudio();
    studio.trees.set("StarterGui.Shop", {
      className: "ScreenGui",
      name: "Shop",
      properties: { ResetOnSpawn: false },
      children: [
        { className: "Frame", name: "Panel", properties: { BackgroundTransparency: 0.5 }, children: [{ className: "TextLabel", name: "Title", properties: { Text: "Hello" } }] },
      ],
    });
    const title = () => studio.trees.get("StarterGui.Shop").children[0].children[0].properties.Text;
    const setFileTitle = (text) => {
      const spec = JSON.parse(read("StarterGui/Shop.build.json"));
      spec.children[0].children[0].properties.Text = text;
      writeFileSync(file("StarterGui/Shop.build.json"), `${JSON.stringify(spec, null, 2)}\n`);
    };
    const setStudioTitle = (text) => {
      studio.trees.get("StarterGui.Shop").children[0].children[0].properties.Text = text;
    };
    const sync = (extra = {}) => runSync(studio, { dir, direction: "both", ...extra });

    const [exported] = await runExport(studio, { dir, direction: "both", paths: ["StarterGui.Shop"] });
    assert.equal(exported.file, "StarterGui/Shop.build.json");
    const first = read("StarterGui/Shop.build.json");
    assert.ok(first.indexOf('"className"') < first.indexOf('"name"') && first.includes('"Text": "Hello"'), "canonical key order");
    assert.equal((await sync()).lines.length, 0, "in step right after export");

    setFileTitle("From file");
    let report = await sync();
    assert.deepEqual(report.builds, ["StarterGui/Shop.build.json"]);
    assert.equal(title(), "From file", "file edit rebuilds the tree");
    assert.equal((await sync()).lines.length, 0, "and settles");

    setStudioTitle("From Studio");
    report = await sync();
    assert.equal(report.counts.export, 1);
    assert.ok(read("StarterGui/Shop.build.json").includes('"Text": "From Studio"'), "Studio edit is written back to the file");

    setFileTitle("Disk side");
    setStudioTitle("Studio side");
    report = await sync();
    assert.equal(report.conflicts.length, 1, "both sides edited: a conflict");
    assert.equal(title(), "Studio side", "the tree is not rebuilt over");
    assert.ok(read(".rbx-sync/conflicts/StarterGui/Shop.build.json").includes("Studio side"));
    // An explicit build refuses too, unless told the file wins.
    report = await runBuild(studio, { dir, direction: "push" , files: ["StarterGui/Shop.build.json"] });
    assert.equal(report.conflicts.length, 1);
    assert.equal(title(), "Studio side");

    setFileTitle("Merged");
    report = await sync();
    assert.equal(report.conflicts.length, 0);
    assert.equal(title(), "Merged", "the file that moved after the conflict wins");
    assert.ok(!existsSync(file(".rbx-sync/conflicts/StarterGui/Shop.build.json")));

    setStudioTitle("Studio again");
    report = await runBuild(studio, { dir, direction: "push", files: ["StarterGui/Shop.build.json"], prefer: "disk" });
    assert.equal(title(), "Merged", "prefer disk rebuilds over Studio's edit");

    // Renamed in the file: the old tree is replaced, not duplicated.
    const renamed = JSON.parse(read("StarterGui/Shop.build.json"));
    renamed.name = "Store";
    writeFileSync(file("StarterGui/Shop.build.json"), `${JSON.stringify(renamed, null, 2)}\n`);
    await sync({ prefer: "disk" });
    assert.ok(studio.trees.has("StarterGui.Store") && !studio.trees.has("StarterGui.Shop"), [...studio.trees.keys()].join(","));
    await sync();
    renamed.name = "Shop";
    writeFileSync(file("StarterGui/Shop.build.json"), `${JSON.stringify(renamed, null, 2)}\n`);
    await sync({ prefer: "disk" });
    assert.ok(studio.trees.has("StarterGui.Shop") && !studio.trees.has("StarterGui.Store"));
    await sync();

    // A tree deleted in Studio sends its unchanged file to the trash.
    studio.trees.delete("StarterGui.Shop");
    report = await sync();
    assert.ok(!existsSync(file("StarterGui/Shop.build.json")));
    const trash = readdirSync(file(".rbx-sync/trash"));
    assert.ok(existsSync(path.join(file(".rbx-sync/trash"), trash[0], "StarterGui", "Shop.build.json")));
    rmSync(dir, { recursive: true, force: true });
    console.log("sync builds: export, file -> tree, tree -> file, conflict with sidecar, settle, explicit build guard, delete");
  }

  // Watch ---------------------------------------------------------------------
  {
    const studio = fakeStudio();
    studio.scripts.set("ServerScriptService.Live", { className: "ModuleScript", source: "return 0\n" });
    const { state } = await startWatch(studio, { dir, direction: "both" });
    const scansAfterStart = studio.calls.filter((op) => op === "sync.scan").length;

    writeFileSync(file("ServerScriptService/Live.luau"), "return 1\n");
    assert.ok(await until(() => studio.scripts.get("ServerScriptService.Live").source === "return 1\n"), "file edit reaches Studio");
    // Sync's own write comes back as a Studio edit event: it must be recognised
    // as an echo, not answered with a second full sync.
    assert.ok(await until(() => state.echoes >= 1), "the echo is skipped");
    const cyclesAfterPush = state.cycles;

    studio.edit("ServerScriptService.Live", "return 2\n");
    assert.ok(await until(() => read("ServerScriptService/Live.luau") === "return 2\n"), "Studio edit reaches the file");
    await new Promise((resolve) => setTimeout(resolve, 1_500));
    assert.ok(state.cycles <= cyclesAfterPush + 2, `settles after a change (${state.cycles - cyclesAfterPush} syncs)`);
    const scans = studio.calls.filter((op) => op === "sync.scan").length - scansAfterStart;
    assert.ok(scans <= state.cycles, "Studio is scanned only when a sync runs");

    // Idle: no syncs at all.
    const idle = state.cycles;
    await new Promise((resolve) => setTimeout(resolve, 2_500));
    assert.equal(state.cycles, idle, "nothing changed, nothing ran");

    // Studio restarts on the same place: the watch follows it.
    studio.restart();
    writeFileSync(file("ServerScriptService/Live.luau"), "return 'after restart'\n");
    assert.ok(await until(() => studio.scripts.get("ServerScriptService.Live").source === "return 'after restart'\n"), "watch reattached");
    assert.ok(takeNotices()?.includes("reconnected"), "and said so");

    // A conflict while watching reaches the agent on its next reply.
    takeNotices();
    writeFileSync(file("ServerScriptService/Live.luau"), "return 'disk'\n");
    studio.edit("ServerScriptService.Live", "return 'studio'\n");
    assert.ok(await until(() => state.conflicts.length === 1), "conflict found");
    const notice = takeNotices();
    assert.ok(notice?.includes("conflict in ServerScriptService/Live.luau"), notice);
    assert.equal(takeNotices(), undefined, "said once");
    assert.ok(watchState(dir));
    stopWatch(dir);
    assert.equal(watchState(dir), null);
    console.log(`sync watch: both directions, echoes skipped (${state.echoes}), idle is silent, conflicts become notices`);
  }
} finally {
  stopAllWatches();
  rmSync(sandbox, { recursive: true, force: true });
}
