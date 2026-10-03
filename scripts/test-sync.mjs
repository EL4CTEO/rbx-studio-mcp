/**
 * `sync`, offline: the planner on its own, then the whole engine against a
 * real temp folder and an in-memory Studio that behaves like the plugin's
 * sync handler (revisions, conditional writes, creates, moves, deletes).
 *
 * Usage: node scripts/test-sync.mjs   (after `npm run build`)
 */
import assert from "node:assert/strict";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, renameSync, rmSync, statSync, unlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import {
  classFromFile,
  decodeName,
  emptyManifest,
  encodeName,
  layout,
  placementOf,
  plan,
} from "../dist/lib/syncplan.js";
import { hashOf, runSync, stopAllWatches } from "../dist/lib/sync.js";
import { fakeStudio, scanOf } from "./sync-fake.mjs";

// Names -----------------------------------------------------------------------

for (const name of ["Main", "Dr. Who", "a/b\\c", "what?", "100%", "CON", "trailing.", "trailing ", "..", "", "init", "Config.server", "日本"]) {
  for (const kind of ["dir", "script"]) {
    const encoded = encodeName(name, kind);
    assert.ok(!/[<>:"/\\|?*]/.test(encoded), `${JSON.stringify(name)} -> ${encoded} is file-safe`);
    assert.ok(!/[. ]$/.test(encoded) && !/^(con|prn|aux|nul)$/i.test(encoded), `${encoded} is Windows-safe`);
    assert.equal(decodeName(encoded), name, `${JSON.stringify(name)} round-trips as ${kind}`);
  }
}
assert.equal(classFromFile(`${encodeName("Config.server", "script")}.luau`).className, "ModuleScript", "a dotted name keeps its class");
assert.equal(classFromFile(`${encodeName("init", "script")}.luau`).init, false, "a script named init is not an init file");
assert.deepEqual(classFromFile("Main.server.luau"), { stem: "Main", className: "Script", init: false });
assert.deepEqual(classFromFile("init.client.lua"), { stem: "init", className: "LocalScript", init: true });
assert.equal(classFromFile("notes.txt"), null);
console.log("sync names: encode/decode round trips, reserved and ambiguous names");

// Layout ----------------------------------------------------------------------

{
  const shape = layout(
    scanOf({
      "ServerScriptService.Main": { className: "Script", revision: "r1" },
      "ServerScriptService.Main.Helper": { className: "ModuleScript", revision: "r2" },
      "ReplicatedStorage.Shared.Util": { className: "ModuleScript", revision: "r3" },
      "ReplicatedStorage.Shared.util": { className: "LocalScript", revision: "r4" },
      "ReplicatedStorage.Shared.UTIL": { className: "ModuleScript", revision: "r5" },
      "StarterGui.Bound": { className: "LocalScript", revision: "r6", fileSynced: true },
    }),
  );
  assert.equal(shape.fileOf.get("ServerScriptService.Main"), "ServerScriptService/Main/init.server.luau");
  assert.equal(shape.fileOf.get("ServerScriptService.Main.Helper"), "ServerScriptService/Main/Helper.luau");
  assert.equal(shape.fileOf.get("ReplicatedStorage.Shared.UTIL"), "ReplicatedStorage/Shared/UTIL.luau");
  assert.equal(shape.fileOf.get("ReplicatedStorage.Shared.Util"), "ReplicatedStorage/Shared/Util~2.luau", "case collision suffixed");
  assert.equal(shape.fileOf.get("ReplicatedStorage.Shared.util"), "ReplicatedStorage/Shared/util.client.luau", "different extension, no collision");
  assert.deepEqual(shape.fileSynced, ["StarterGui.Bound"]);
  assert.equal(shape.pathOfDir.get("ReplicatedStorage/Shared"), "ReplicatedStorage.Shared");

  const place = placementOf("ReplicatedStorage/Shared/New/Thing.luau", shape, () => undefined);
  assert.deepEqual(place, { parentPath: "ReplicatedStorage.Shared", parents: [{ name: "New", className: "Folder" }], name: "Thing", className: "ModuleScript" });
  const init = placementOf("ServerScriptService/Svc/init.server.luau", shape, () => "Script");
  assert.deepEqual(init, { parentPath: "ServerScriptService", parents: [], name: "Svc", className: "Script" });
  assert.ok("error" in placementOf("Loose.luau", shape, () => undefined), "files must sit inside a service folder");
  console.log("sync layout: init folders, case collisions, Script Sync exclusions, placement");
}

// Plan ------------------------------------------------------------------------

{
  const scripts = { "ServerScriptService.A": { className: "Script", revision: "a1" }, "ServerScriptService.B": { className: "ModuleScript", revision: "b1" } };
  const studio = layout(scanOf(scripts));
  const inScope = () => true;
  const manifest = emptyManifest();
  const first = plan({ manifest, studio, disk: new Map(), inScope, direction: "both" });
  assert.deepEqual(first.actions.map((action) => action.kind).sort(), ["create-disk", "create-disk"], "first sync pulls everything, deletes nothing");

  manifest.files["ServerScriptService/A.server.luau"] = { path: "ServerScriptService.A", className: "Script", revision: "a1", hash: "ha" };
  manifest.files["ServerScriptService/B.luau"] = { path: "ServerScriptService.B", className: "ModuleScript", revision: "b1", hash: "hb" };
  const kinds = (input) => plan({ manifest, inScope, direction: "both", ...input }).actions.map((action) => `${action.kind} ${action.file}`).sort();

  const same = new Map([["ServerScriptService/A.server.luau", "ha"], ["ServerScriptService/B.luau", "hb"]]);
  assert.deepEqual(kinds({ studio, disk: same }), [], "in step: nothing to do");
  assert.deepEqual(kinds({ studio, disk: new Map([...same, ["ServerScriptService/A.server.luau", "ha2"]]) }), ["push ServerScriptService/A.server.luau"]);
  const edited = layout(scanOf({ ...scripts, "ServerScriptService.A": { className: "Script", revision: "a2" } }));
  assert.deepEqual(kinds({ studio: edited, disk: same }), ["pull ServerScriptService/A.server.luau"]);
  assert.deepEqual(kinds({ studio: edited, disk: new Map([...same, ["ServerScriptService/A.server.luau", "ha2"]]) }), ["merge ServerScriptService/A.server.luau"]);

  // Renamed on disk: same hash under a new name moves the script.
  const renamedOnDisk = new Map([["ServerScriptService/Alpha.server.luau", "ha"], ["ServerScriptService/B.luau", "hb"]]);
  assert.deepEqual(kinds({ studio, disk: renamedOnDisk }), ["move-studio ServerScriptService/Alpha.server.luau"]);
  // Renamed in Studio: same revision at a new path moves the file.
  const renamedInStudio = layout(scanOf({ "ServerScriptService.Alpha": { className: "Script", revision: "a1" }, "ServerScriptService.B": scripts["ServerScriptService.B"] }));
  assert.deepEqual(kinds({ studio: renamedInStudio, disk: same }), ["move-disk ServerScriptService/Alpha.server.luau"]);

  // Deleted on one side, untouched on the other: delete on the other.
  assert.deepEqual(kinds({ studio, disk: new Map([["ServerScriptService/B.luau", "hb"]]) }), ["delete-studio ServerScriptService/A.server.luau"]);
  const withoutA = layout(scanOf({ "ServerScriptService.B": scripts["ServerScriptService.B"] }));
  assert.deepEqual(kinds({ studio: withoutA, disk: same }), ["delete-disk ServerScriptService/A.server.luau"]);
  // Deleted on one side, edited on the other: conflict, unless told who wins.
  assert.deepEqual(kinds({ studio: withoutA, disk: new Map([...same, ["ServerScriptService/A.server.luau", "ha2"]]) }), ["conflict ServerScriptService/A.server.luau"]);
  assert.deepEqual(
    plan({ manifest, inScope, direction: "both", prefer: "disk", studio: withoutA, disk: new Map([...same, ["ServerScriptService/A.server.luau", "ha2"]]) }).actions.map((a) => a.kind),
    ["create-studio"],
  );
  // Gone from both: forget.
  assert.deepEqual(kinds({ studio: withoutA, disk: new Map([["ServerScriptService/B.luau", "hb"]]) }), ["forget ServerScriptService/A.server.luau"]);
  // Direction holds the other side's changes back rather than dropping them.
  const pushOnly = plan({ manifest, inScope, direction: "push", studio: edited, disk: same });
  assert.equal(pushOnly.actions.length, 0);
  assert.deepEqual(pushOnly.held.map((action) => action.kind), ["pull"]);
  // Out of scope entries are ignored, never deleted.
  assert.deepEqual(plan({ manifest, inScope: () => false, direction: "both", studio: layout(scanOf({})), disk: new Map() }).actions, []);
  console.log("sync plan: first sync, push, pull, merge, renames both ways, deletes, conflicts, direction, scope");
}

// Engine ----------------------------------------------------------------------

const dir = mkdtempSync(path.join(tmpdir(), "rbx-sync-test-"));
const file = (relative) => path.join(dir, ...relative.split("/"));
const read = (relative) => readFileSync(file(relative), "utf8");
const studio = fakeStudio();
studio.scripts.set("ServerScriptService.Main", { className: "Script", source: 'print("hi")\n' });
studio.scripts.set("ServerScriptService.Main.Helper", { className: "ModuleScript", source: "return {}\n" });
studio.scripts.set("StarterGui.Shop.Client", { className: "LocalScript", source: "-- client\n" });
const sync = (extra = {}) => runSync(studio, { dir, direction: "both", ...extra });

try {
  // First pull writes everything, the Rojo way.
  let report = await sync();
  assert.equal(report.counts["create-disk"], 3);
  assert.equal(read("ServerScriptService/Main/init.server.luau"), 'print("hi")\n');
  assert.equal(read("ServerScriptService/Main/Helper.luau"), "return {}\n");
  assert.equal(read("StarterGui/Shop/Client.client.luau"), "-- client\n");
  assert.ok(existsSync(file(".rbx-sync/manifest.json")) && read(".rbx-sync/.gitignore") === "*\n");
  assert.equal((await sync()).lines.length, 0, "a second run is a no-op");

  // A Rojo-style sourcemap for luau-lsp, paths relative to the folder above.
  const sourcemap = JSON.parse(read("sourcemap.json"));
  const service = sourcemap.children.find((child) => child.name === "ServerScriptService");
  const main = service.children.find((child) => child.name === "Main");
  const folder = path.basename(dir);
  assert.equal(sourcemap.className, "DataModel");
  assert.equal(service.className, "ServerScriptService");
  assert.deepEqual(main.filePaths, [`${folder}/ServerScriptService/Main/init.server.luau`]);
  assert.equal(main.className, "Script");
  assert.deepEqual(main.children.map((child) => [child.name, child.className]), [["Helper", "ModuleScript"]]);
  const stamp = statSync(file("sourcemap.json")).mtimeMs;
  await sync();
  assert.equal(statSync(file("sourcemap.json")).mtimeMs, stamp, "unchanged sourcemap is not rewritten");

  // Edit a file (with CRLF, as some editors save): it reaches Studio as LF.
  writeFileSync(file("ServerScriptService/Main/Helper.luau"), "return { answer = 42 }\r\n");
  report = await sync();
  assert.equal(report.counts.push, 1);
  assert.equal(studio.scripts.get("ServerScriptService.Main.Helper").source, "return { answer = 42 }\n");

  // Edit in Studio: it reaches the file.
  studio.scripts.get("StarterGui.Shop.Client").source = "-- client v2\n";
  report = await sync();
  assert.equal(report.counts.pull, 1);
  assert.equal(read("StarterGui/Shop/Client.client.luau"), "-- client v2\n");

  // New file on disk, in a new folder: created in Studio.
  mkdirSync(file("ReplicatedStorage/Shared"), { recursive: true });
  writeFileSync(file("ReplicatedStorage/Shared/Util.luau"), "return 1\n");
  report = await sync();
  assert.equal(report.counts["create-studio"], 1);
  assert.equal(studio.scripts.get("ReplicatedStorage.Shared.Util").source, "return 1\n");

  // Both sides edited: a conflict, and neither side is touched.
  writeFileSync(file("ReplicatedStorage/Shared/Util.luau"), "return 2\n");
  studio.scripts.get("ReplicatedStorage.Shared.Util").source = "return 3\n";
  report = await sync();
  assert.equal(report.conflicts.length, 1);
  assert.equal(read("ReplicatedStorage/Shared/Util.luau"), "return 2\n");
  assert.equal(studio.scripts.get("ReplicatedStorage.Shared.Util").source, "return 3\n");
  // ...and the same text on both sides settles it without asking.
  writeFileSync(file("ReplicatedStorage/Shared/Util.luau"), "return 3\n");
  report = await sync();
  assert.equal(report.conflicts.length, 0);
  assert.equal((await sync()).lines.length, 0);
  // prefer settles a real conflict in one direction.
  writeFileSync(file("ReplicatedStorage/Shared/Util.luau"), "return 4\n");
  studio.scripts.get("ReplicatedStorage.Shared.Util").source = "return 5\n";
  report = await sync({ prefer: "disk" });
  assert.equal(studio.scripts.get("ReplicatedStorage.Shared.Util").source, "return 4\n");

  // Rename on disk: the script moves, it is not recreated.
  const moved = studio.scripts.get("ReplicatedStorage.Shared.Util");
  renameSync(file("ReplicatedStorage/Shared/Util.luau"), file("ReplicatedStorage/Shared/Tools.luau"));
  report = await sync();
  assert.equal(report.counts["move-studio"], 1);
  assert.equal(studio.scripts.get("ReplicatedStorage.Shared.Tools"), moved, "same instance, new name");
  assert.ok(!studio.scripts.has("ReplicatedStorage.Shared.Util"));

  // Rename in Studio: the file moves.
  studio.scripts.set("StarterGui.Shop.ShopClient", studio.scripts.get("StarterGui.Shop.Client"));
  studio.scripts.delete("StarterGui.Shop.Client");
  report = await sync();
  assert.equal(report.counts["move-disk"], 1);
  assert.ok(existsSync(file("StarterGui/Shop/ShopClient.client.luau")) && !existsSync(file("StarterGui/Shop/Client.client.luau")));

  // Deleted in Studio: the file goes to the trash, not away.
  studio.scripts.delete("StarterGui.Shop.ShopClient");
  report = await sync();
  assert.equal(report.counts["delete-disk"], 1);
  assert.ok(!existsSync(file("StarterGui/Shop/ShopClient.client.luau")));
  assert.ok(!existsSync(file("StarterGui/Shop")), "emptied folders are pruned");
  const trashRuns = readdirSync(file(".rbx-sync/trash"));
  assert.equal(read(`.rbx-sync/trash/${trashRuns[0]}/StarterGui/Shop/ShopClient.client.luau`), "-- client v2\n");

  // Deleted on disk: the script is deleted in Studio.
  unlinkSync(file("ReplicatedStorage/Shared/Tools.luau"));
  report = await sync();
  assert.equal(report.counts["delete-studio"], 1);
  assert.ok(!studio.scripts.has("ReplicatedStorage.Shared.Tools"));

  // Push holds Studio's changes back and says so.
  studio.scripts.get("ServerScriptService.Main").source = 'print("studio")\n';
  report = await sync({ direction: "push" });
  assert.equal(report.held.length, 1);
  assert.equal(read("ServerScriptService/Main/init.server.luau"), 'print("hi")\n');
  await sync();
  assert.equal(read("ServerScriptService/Main/init.server.luau"), 'print("studio")\n');

  // Dry run changes nothing.
  writeFileSync(file("ServerScriptService/Main/Helper.luau"), "return 'dry'\n");
  report = await sync({ dryRun: true });
  assert.equal(report.counts.push, 1);
  assert.notEqual(studio.scripts.get("ServerScriptService.Main.Helper").source, "return 'dry'\n");
  await sync();

  // Another place is refused outright.
  const other = fakeStudio(2);
  await assert.rejects(runSync(other, { dir, direction: "both" }), /PLACE_MISMATCH|synced with place/);

  // Deleting most of what is tracked stops and asks.
  const big = mkdtempSync(path.join(tmpdir(), "rbx-sync-big-"));
  const bigStudio = fakeStudio(3);
  for (let index = 0; index < 20; index += 1) bigStudio.scripts.set(`ServerScriptService.S${index}`, { className: "ModuleScript", source: `return ${index}\n` });
  await runSync(bigStudio, { dir: big, direction: "both" });
  rmSync(path.join(big, "ServerScriptService"), { recursive: true });
  await assert.rejects(runSync(bigStudio, { dir: big, direction: "both" }), /would delete 20/);
  assert.equal(bigStudio.scripts.size, 20, "nothing was deleted");
  const confirmed = await runSync(bigStudio, { dir: big, direction: "both", confirmDeletes: true });
  assert.equal(confirmed.counts["delete-studio"], 20);
  rmSync(big, { recursive: true, force: true });

  assert.ok(studio.logged.some((line) => line.message.startsWith("sync to files")), "disk-side work is reported in the panel");
  console.log("sync engine: pull, push (CRLF), create, conflicts, prefer, renames, trash, prune, direction, dry run, place and mass-delete guards");
} finally {
  stopAllWatches();
  rmSync(dir, { recursive: true, force: true });
}

assert.equal(hashOf("a\r\nb"), hashOf("a\nb"));
