/**
 * Black-box tests for the native (Rust) server.
 *
 * Drives the binary the way real clients do: the official MCP SDK over stdio,
 * and a fake Studio plugin speaking the bridge's HTTP/SSE protocol. Nothing
 * here imports server internals, so it holds for any implementation.
 *
 * Usage: node scripts/test-native.mjs [path-to-binary]
 */
import assert from "node:assert/strict";
import { spawn, spawnSync } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import { createServer } from "node:net";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const exe = process.platform === "win32" ? ".exe" : "";
const binary =
  process.argv[2] ??
  [join(root, "server", "target", "release", `rbx-studio-mcp${exe}`), join(root, "server", "target", "debug", `rbx-studio-mcp${exe}`)].find(existsSync);
assert.ok(binary && existsSync(binary), "build the server first: cargo build --manifest-path server/Cargo.toml");
const version = JSON.parse(readFileSync(join(root, "package.json"), "utf8")).version;
const HEADER = { "x-roblox-studio-mcp": "test" };

const freePort = () =>
  new Promise((done, fail) => {
    const s = createServer();
    s.once("error", fail);
    s.listen(0, "127.0.0.1", () => {
      const { port } = s.address();
      s.close(() => done(port));
    });
  });

const sleep = (ms) => new Promise((done) => setTimeout(done, ms));

async function step(name, body) {
  const started = performance.now();
  await body();
  process.stdout.write(`  ok  ${name} (${Math.round(performance.now() - started)}ms)\n`);
}

/** A fake plugin holding an SSE stream and answering commands with `answer`. */
async function fakeStudio(port, identity, answer) {
  const controller = new AbortController();
  const response = await fetch(`http://127.0.0.1:${port}/events`, {
    method: "POST",
    headers: { ...HEADER, "content-type": "application/json" },
    body: JSON.stringify({ protocolVersion: 1, pluginVersion: version, buildId: "test", ...identity }),
    signal: controller.signal,
  });
  assert.equal(response.status, 200);
  const frames = [];
  const reader = response.body.getReader();
  const decoder = new TextDecoder();
  let buffer = "";
  const pump = (async () => {
    try {
      for (;;) {
        const { value, done } = await reader.read();
        if (done) return;
        buffer += decoder.decode(value, { stream: true });
        let cut;
        while ((cut = buffer.indexOf("\n\n")) !== -1) {
          const block = buffer.slice(0, cut);
          buffer = buffer.slice(cut + 2);
          if (!block.startsWith("data: ")) continue;
          const frame = JSON.parse(block.slice(6));
          frames.push(frame);
          if (typeof frame.id === "string" && typeof frame.op === "string") {
            const reply = await answer(frame);
            await fetch(`http://127.0.0.1:${port}/result?studioId=${identity.studioId}`, {
              method: "POST",
              headers: { ...HEADER, "content-type": "application/json" },
              body: JSON.stringify({ id: frame.id, ...reply }),
            });
          }
        }
      }
    } catch {
      /* aborted */
    }
  })();
  return { frames, close: () => (controller.abort(), pump) };
}

async function mcp(port, extraEnv = {}) {
  const transport = new StdioClientTransport({
    command: binary,
    args: ["--port", String(port)],
    cwd: root,
    stderr: "pipe",
    env: { ...process.env, ...extraEnv },
  });
  const client = new Client({ name: "native-test", version: "1.0.0" });
  await client.connect(transport);
  return client;
}

const textOf = (result) => result.content.filter((c) => c.type === "text").map((c) => c.text).join("\n");

process.stdout.write(`native server: ${binary}\n`);

await step("rejects bad --port values", async () => {
  for (const args of [["doctor", "--port"], ["doctor", "--port", "44755oops"], ["doctor", "--port", "12.5"]]) {
    const r = spawnSync(binary, args, { encoding: "utf8", timeout: 10_000 });
    assert.equal(r.status, 1, `${args.join(" ")} must fail`);
    assert.match(r.stderr, /failed to start: (Invalid port|Missing value for --port)/);
  }
});

const port = await freePort();
const owner = await mcp(port);

await step("handshake reports the package version", async () => {
  assert.equal(owner.getServerVersion()?.version, version);
  assert.match(owner.getInstructions() ?? "", /studio_status/);
});

await step("lists all 35 tools with valid schemas", async () => {
  const { tools } = await owner.listTools();
  assert.equal(tools.length, 35);
  for (const tool of tools) {
    assert.equal(tool.inputSchema.type, "object", tool.name);
    assert.ok(!JSON.stringify(tool.inputSchema).includes("$ref"), `${tool.name} must not use $ref`);
    assert.ok(tool.description.length > 40, tool.name);
  }
});

await step("no Studio: tools fail with NO_STUDIO, not a protocol error", async () => {
  const r = await owner.callTool({ name: "studio_status", arguments: {} });
  assert.equal(r.isError, true);
  assert.match(textOf(r), /^\[NO_STUDIO\]/);
});

await step("arguments are validated against the schema", async () => {
  const r = await owner.callTool({ name: "tree", arguments: { depth: 99 } });
  assert.equal(r.isError, true);
  assert.match(textOf(r), /BAD_PARAMS.*depth/);
});

await step("bridge refuses foreign hosts, origins and missing headers", async () => {
  const base = `http://127.0.0.1:${port}/identity`;
  assert.equal((await fetch(base)).status, 403);
  assert.equal((await fetch(base, { headers: { ...HEADER, origin: "http://evil.example" } })).status, 403);
  const identity = await (await fetch(base, { headers: HEADER })).json();
  assert.equal(identity.server, "roblox-studio-mcp");
});

const calls = [];
const studio = await fakeStudio(port, { studioId: "studio-a", placeName: "Test Place", placeId: 42 }, async (frame) => {
  calls.push(frame);
  if (frame.op === "studio.status") return { ok: true, data: { placeName: "Test Place", placeId: 42, context: "edit", isEdit: true, selection: [] } };
  if (frame.op === "discover.tree")
    return { ok: true, data: { items: [{ path: "Workspace", className: "Workspace", childCount: 2 }], total: 1, offset: 0, hiddenServices: 3 } };
  if (frame.op === "script.read")
    return { ok: true, data: { items: [{ path: "ServerScriptService.Main", className: "Script", lineCount: 2, startLine: 1, source: "print(1)\nprint(2)", revision: "abc" }], failures: [] } };
  if (frame.op === "instances.delete") return { ok: false, error: { code: "PROTECTED", message: "Services cannot be deleted.", hint: "Pick a child." } };
  return { ok: true, data: {} };
});

await step("SSE: a tool call reaches the plugin and the reply comes back", async () => {
  const r = await owner.callTool({ name: "studio_status", arguments: {} });
  assert.ok(!r.isError, textOf(r));
  assert.match(textOf(r), /"placeName":"Test Place"/);
  assert.ok(calls.some((c) => c.op === "studio.status" && typeof c.timeoutMs === "number"));
});

await step("tables, notes and line numbers render as before", async () => {
  const tree = textOf(await owner.callTool({ name: "tree", arguments: {} }));
  assert.match(tree, /^path \| className \| childCount\nWorkspace \| Workspace \| 2/);
  assert.match(tree, /3 engine services hidden/);
  const read = textOf(await owner.callTool({ name: "script_read", arguments: { paths: ["ServerScriptService.Main"] } }));
  assert.match(read, /\(Script, 2 lines, rev abc\)\n1│ print\(1\)\n2│ print\(2\)/);
});

await step("plugin errors keep their code and hint", async () => {
  const r = await owner.callTool({ name: "delete", arguments: { paths: ["Workspace"] } });
  assert.equal(r.isError, true);
  assert.equal(textOf(r), "[PROTECTED] Services cannot be deleted.\nPick a child.");
});

await step("clients are announced to the plugin", async () => {
  assert.ok(studio.frames.some((f) => f.event === "clients" && f.count >= 1));
});

await step("latency route measures round trips", async () => {
  const r = await (await fetch(`http://127.0.0.1:${port}/latency?count=20`, { headers: HEADER })).json();
  assert.equal(r.samples, 20);
  assert.equal(r.transport, "sse");
  process.stdout.write(`        sse round trip: median ${r.medianMs}ms, p95 ${r.p95Ms}ms\n`);
});

const peer = await mcp(port);

await step("a second server proxies through the owner", async () => {
  const r = await peer.callTool({ name: "studio_status", arguments: {} });
  assert.ok(!r.isError, textOf(r));
  assert.match(textOf(r), /Test Place/);
});

await step("peer errors keep their hint across the proxy", async () => {
  const r = await peer.callTool({ name: "delete", arguments: { paths: ["Workspace"] } });
  assert.equal(textOf(r), "[PROTECTED] Services cannot be deleted.\nPick a child.");
});

await step("two places: ambiguity is refused, then a choice sticks per client", async () => {
  const second = await fakeStudio(port, { studioId: "studio-b", placeName: "Other", placeId: 7 }, async () => ({ ok: true, data: { placeName: "Other", placeId: 7 } }));
  await sleep(50);
  const r = await owner.callTool({ name: "studio_status", arguments: {} });
  assert.match(textOf(r), /AMBIGUOUS_STUDIO/);
  await owner.callTool({ name: "set_active_studio", arguments: { studioId: "studio-b" } });
  assert.match(textOf(await owner.callTool({ name: "studio_status", arguments: {} })), /Other/);
  // The peer never chose, so it is still ambiguous: choices are per client.
  assert.match(textOf(await peer.callTool({ name: "studio_status", arguments: {} })), /AMBIGUOUS_STUDIO/);
  await second.close();
  await fetch(`http://127.0.0.1:${port}/bye?studioId=studio-b`, { method: "POST", headers: HEADER });
});

await step("long-poll fallback delivers commands", async () => {
  await fetch(`http://127.0.0.1:${port}/connect`, {
    method: "POST",
    headers: { ...HEADER, "content-type": "application/json" },
    body: JSON.stringify({ studioId: "poller", placeName: "Polled", placeId: 9 }),
  });
  const pending = owner.callTool({ name: "studio_status", arguments: { studioId: "poller" } });
  const polled = await (await fetch(`http://127.0.0.1:${port}/poll?studioId=poller`, { headers: HEADER })).json();
  assert.equal(polled.command.op, "studio.status");
  await fetch(`http://127.0.0.1:${port}/result?studioId=poller`, {
    method: "POST",
    headers: { ...HEADER, "content-type": "application/json" },
    body: JSON.stringify({ id: polled.command.id, ok: true, data: { placeName: "Polled" } }),
  });
  assert.match(textOf(await pending), /Polled/);
  await fetch(`http://127.0.0.1:${port}/bye?studioId=poller`, { method: "POST", headers: HEADER });
});

await step("owner exit: the peer takes the port over", async () => {
  await owner.close();
  let identity = null;
  for (let i = 0; i < 40 && identity === null; i += 1) {
    await sleep(250);
    identity = await fetch(`http://127.0.0.1:${port}/identity`, { headers: HEADER }).then((r) => r.json(), () => null);
  }
  assert.ok(identity, "someone must hold the port again");
  // The plugin reconnects to the new owner the way the real one does.
  await studio.close();
  const again = await fakeStudio(port, { studioId: "studio-a", placeName: "Test Place", placeId: 42 }, async () => ({ ok: true, data: { placeName: "Test Place" } }));
  const r = await peer.callTool({ name: "studio_status", arguments: {} });
  assert.match(textOf(r), /Test Place/);
  await again.close();
});

await peer.close();
process.stdout.write("native server: ok\n");
process.exit(0);
