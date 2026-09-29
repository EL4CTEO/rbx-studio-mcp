/**
 * The API dump: its cache, how a long-lived server keeps it current, and what
 * the discovery tools say from it.
 *
 * Run against a tiny fixture in a private temp directory, so nothing here reads
 * the real cache or touches the network -- and so it cannot pass or fail on
 * whether Roblox happened to be reachable.
 *
 * Usage: node scripts/test-apidump.mjs
 */
import assert from "node:assert/strict";
import { mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

// Redirected before anything is imported: the cache path is built from
// os.tmpdir() at call time, and this keeps every read and write in the sandbox.
const sandbox = mkdtempSync(join(tmpdir(), "rbx-apidump-test-"));
for (const name of ["TMPDIR", "TEMP", "TMP"]) process.env[name] = sandbox;
const cacheDir = join(sandbox, "roblox-studio-mcp");
const cacheFile = join(cacheDir, "api-dump.json");

const property = (name, type, extra = {}) => ({
  MemberType: "Property",
  Name: name,
  ValueType: { Name: type, Category: "Primitive" },
  ...extra,
});
const dumpOf = (extraClasses = []) => ({
  Classes: [
    { Name: "Instance", Superclass: "", Members: [property("Name", "string"), property("Archivable", "bool")] },
    { Name: "Model", Superclass: "Instance", Members: [property("PrimaryPart", "BasePart")] },
    {
      Name: "Part",
      Superclass: "Instance",
      Members: [
        property("Size", "Vector3"),
        property("Anchored", "bool"),
        // Above plugin identity: present in the dump, not reachable from here.
        property("Secret", "string", { Security: { Read: "RobloxScriptSecurity", Write: "RobloxScriptSecurity" } }),
      ],
    },
    ...extraClasses,
  ],
  Enums: [],
});
const widget = { Name: "Widget", Superclass: "Instance", Members: [property("Gizmo", "number")] };
const seed = (dump, fetchedAt = Date.now()) => {
  mkdirSync(cacheDir, { recursive: true });
  writeFileSync(cacheFile, JSON.stringify({ fetchedAt, dump }));
};
const until = async (test, what) => {
  for (let attempt = 0; attempt < 100; attempt += 1) {
    if (await test()) return;
    await new Promise((resolve) => setTimeout(resolve, 20));
  }
  assert.fail(`timed out waiting for ${what}`);
};

const realFetch = globalThis.fetch;
const realNow = Date.now;
try {
  // ---- what the dump answers ----------------------------------------------------
  seed(dumpOf());
  const dump = await import("../dist/lib/apidump.js");
  const names = (await dump.propertiesOf("Part")).map((entry) => entry.name);
  assert.deepEqual([...names].sort(), ["Anchored", "Archivable", "Name", "Size"], "own and inherited, nothing above plugin identity");
  assert.ok((await dump.restrictionsOf("Part")).has("Secret"), "a restricted property is known about, separately");
  assert.deepEqual(await dump.suggestProperty("Part", "size"), ["Size"], "a wrong-case name is suggested");
  assert.deepEqual(await dump.suggestClass("Prat"), ["Part"], "a mistyped class is suggested");

  // ---- what the tools say from it ----------------------------------------------------
  const { z } = await import("zod");
  const { registerDiscoverTools } = await import("../dist/tools/discover.js");
  const registered = new Map();
  const replies = {};
  registerDiscoverTools({
    server: { registerTool: (name, spec, handler) => registered.set(name, { spec, handler }) },
    bridge: {
      sessions: async () => ({ list: [], activeId: null, activeIsChosen: false }),
      call: async (op) => replies[op],
      notePlaceName: async () => {},
    },
  });
  const run = (name, args) => {
    const tool = registered.get(name);
    return tool.handler(z.object(tool.spec.inputSchema).parse(args));
  };
  const textOf = (result) => result.content.map((part) => part.text ?? "").join("\n");

  replies["discover.inspect"] = {
    items: [{ path: "Workspace.P", className: "Part", childCount: 0, properties: { Name: "P", Size: "1, 1, 1" } }],
    failures: [],
  };
  const inspected = textOf(await run("inspect", {
    paths: ["Workspace.P"],
    properties: ["Name", "Size", "Sizee", "Anchored", "Secret"],
  }));
  assert.match(inspected, /Requested but not returned:/);
  assert.match(inspected, /Sizee \(not a property of Part; did you mean Size\?\)/, "a typo is named as one");
  assert.match(inspected, /Anchored \(unset, or not readable in this session\)/, "a real property with no value is not called a typo");
  assert.match(inspected, /Secret \(exists, but a plugin cannot read it\)/, "a restricted one says so");
  assert.doesNotMatch(inspected.split("Requested but not returned:")[1], /\bName\b|\bSize \(/, "what did come back is not listed");

  const complete = textOf(await run("inspect", { paths: ["Workspace.P"], properties: ["Name", "Size"] }));
  assert.doesNotMatch(complete, /Requested but not returned/, "nothing to say when everything came back");

  replies["discover.find"] = { items: [], total: 0, offset: 0, searched: 12 };
  const misspelt = textOf(await run("find", { className: "Prat" }));
  assert.match(misspelt, /"Prat" is not a Roblox class/);
  assert.match(misspelt, /Did you mean: Part\?/);
  const genuine = textOf(await run("find", { className: "Part" }));
  assert.doesNotMatch(genuine, /is not a Roblox class/, "a real class that simply matched nothing is not accused");
  const bare = textOf(await run("find", { nameContains: "zzz" }));
  assert.doesNotMatch(bare, /is not a Roblox class/);

  replies["discover.tree"] = { items: [], total: 0, offset: 0 };
  assert.match(textOf(await run("tree", { className: "Prat" })), /"Prat" is not a Roblox class/);

  // ---- a stale cache is served at once, then replaced in the running process ------------
  // Each case gets its own copy of the module: the state under test is per process.
  const fresh = (tag) => import(`../dist/lib/apidump.js?${tag}`);
  const dayMs = 24 * 60 * 60 * 1000;
  let downloads = 0;
  const serve = (value) => {
    globalThis.fetch = async () => {
      downloads += 1;
      return { ok: true, json: async () => value };
    };
  };

  seed(dumpOf(), Date.now() - 3 * dayMs);
  serve(dumpOf([widget]));
  const stale = await fresh("stale");
  assert.equal((await stale.propertiesOf("Widget")).length, 0, "the stale copy is what answers first");
  await until(async () => (await stale.propertiesOf("Widget")).length > 0, "the refreshed dump to replace the stale one");
  assert.equal(downloads, 1, "one download, however many calls were made meanwhile");
  assert.ok((await stale.propertiesOf("Widget")).some((entry) => entry.name === "Gizmo"), "and the answers come from the new one");
  assert.deepEqual(readdirSync(cacheDir), ["api-dump.json"], "the cache was replaced whole, leaving no staging file behind");
  assert.ok(Date.now() - JSON.parse(readFileSync(cacheFile, "utf8")).fetchedAt < dayMs, "and is stamped as fresh");

  // A fresh cache is not refreshed... until the process outlives it.
  seed(dumpOf());
  downloads = 0;
  serve(dumpOf([widget]));
  const longLived = await fresh("long-lived");
  assert.equal((await longLived.propertiesOf("Widget")).length, 0);
  assert.equal(downloads, 0, "a fresh cache needs no download");
  Date.now = () => realNow() + 2 * dayMs;
  await longLived.loadApiDump();
  await until(async () => (await longLived.propertiesOf("Widget")).length > 0, "a process that outlived the cache to refresh it");
  Date.now = realNow;
  assert.equal(downloads, 1);

  // A failed refresh leaves the old dump answering rather than emptying it.
  seed(dumpOf(), Date.now() - 3 * dayMs);
  globalThis.fetch = async () => {
    throw new Error("offline");
  };
  const offline = await fresh("offline");
  assert.ok((await offline.propertiesOf("Part")).length > 0, "no network, still answers from the stale copy");
  await new Promise((resolve) => setTimeout(resolve, 50));
  assert.ok((await offline.propertiesOf("Part")).length > 0, "and still does after the refresh failed");

  process.stdout.write("apidump: ok\n");
} finally {
  globalThis.fetch = realFetch;
  Date.now = realNow;
  rmSync(sandbox, { recursive: true, force: true });
}
