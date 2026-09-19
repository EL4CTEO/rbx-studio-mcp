/**
 * Checks that agents sharing one bridge do not share one target.
 *
 * This exists because the bug it covers is invisible from inside either agent:
 * a call with no studioId succeeds either way, and the only symptom of getting
 * it wrong is edits landing in a place nobody asked for. Two Claude sessions
 * pointed at two places is the shipping claim, so it gets a test rather than a
 * paragraph.
 *
 * Runs against the real Bridge with fake Studio sessions -- no Studio, no
 * sockets -- so it is fast enough to sit in `npm test`.
 */
import assert from "node:assert/strict";
import { Bridge } from "../dist/bridge/rpc.js";
import { LocalBridge } from "../dist/bridge/api.js";

const identity = (studioId, placeId) => ({
  studioId,
  placeName: `Place ${placeId}`,
  placeId,
  pluginVersion: "test",
  buildId: "test",
  protocolVersion: 1,
  transport: "poll",
  context: "edit",
});

function twoStudios() {
  const bridge = new Bridge();
  bridge.attach(identity("studio-a", 111), null);
  bridge.attach(identity("studio-b", 222), null);
  return bridge;
}

// A client that chose nothing has no target, and one that chose has its own.
{
  const bridge = twoStudios();
  const alice = new LocalBridge(bridge);
  const bob = new LocalBridge(bridge);

  assert.equal((await alice.sessions()).activeId, null, "unchosen client has no target");
  assert.equal((await bob.sessions()).activeId, null, "unchosen client has no target");

  await alice.setActive("studio-a");

  assert.equal((await alice.sessions()).activeId, "studio-a", "chooser sees its choice");
  assert.equal((await alice.sessions()).activeIsChosen, true);

  // The whole point: Alice choosing must not move Bob.
  assert.equal((await bob.sessions()).activeId, null, "another client is unaffected");
  assert.equal((await bob.sessions()).activeIsChosen, false);

  await bob.setActive("studio-b");
  assert.equal((await alice.sessions()).activeId, "studio-a", "choices do not overwrite");
  assert.equal((await bob.sessions()).activeId, "studio-b");
}

// An un-addressed call goes to this client's own choice, not to another's.
{
  const bridge = twoStudios();
  const alice = new LocalBridge(bridge);
  const bob = new LocalBridge(bridge);
  await alice.setActive("studio-a");
  await bob.setActive("studio-b");

  const target = (client) =>
    new Promise((resolve) => {
      // Every session is poll-transport with no waiter, so the command lands on
      // a queue; whichever queue grew is where it was routed.
      void client.call("studio.ping", {}, { timeoutMs: 50 }).catch(() => {});
      setTimeout(() => {
        for (const studioId of ["studio-a", "studio-b"]) {
          const session = bridge.sessions.get(studioId);
          if (session.queue.length > 0) {
            session.queue.length = 0;
            resolve(studioId);
            return;
          }
        }
        resolve(null);
      }, 10);
    });

  assert.equal(await target(alice), "studio-a", "alice's call follows alice's choice");
  assert.equal(await target(bob), "studio-b", "bob's call follows bob's choice");
}

// A lone Studio needs no choice, and losing a chosen one goes ambiguous again
// rather than silently promoting the survivor.
{
  const bridge = new Bridge();
  bridge.attach(identity("only", 111), null);
  const alice = new LocalBridge(bridge);
  assert.equal((await alice.sessions()).activeId, "only", "one Studio is never ambiguous");
  assert.equal((await alice.sessions()).activeIsChosen, false, "and was not chosen");

  bridge.attach(identity("second", 222), null);
  assert.equal((await alice.sessions()).activeId, null, "a second Studio makes it ambiguous");

  await alice.setActive("second");
  bridge.detach("second");
  assert.equal((await alice.sessions()).activeId, "only", "one left is unambiguous again");
  assert.equal(
    (await alice.sessions()).activeIsChosen,
    false,
    "but the survivor was never chosen",
  );
}

/**
 * Counting the agents that share one bridge, and noticing when one leaves.
 *
 * The Studio console shows this count and announces the departure, so getting
 * it wrong is not a cosmetic fault -- it either claims a second agent is
 * editing the user's place when none is, or stays silent when one really has
 * gone. Both are the kind of wrong that is only visible from outside the
 * process, which is what this covers.
 */
{
  const bridge = new Bridge();
  const seen = [];
  bridge.watchClients((count) => seen.push(count));

  assert.equal(bridge.clientCount(), 0, "a fresh bridge has no clients");

  const alice = new LocalBridge(bridge);
  assert.equal(bridge.clientCount(), 1, "constructing a local bridge registers it");

  bridge.noteClient("peer-1");
  assert.equal(bridge.clientCount(), 2, "a peer counts too");

  bridge.noteClient("peer-1");
  assert.equal(bridge.clientCount(), 2, "and saying hello twice is not two peers");

  assert.deepEqual(seen, [1, 2], "only real changes are announced");

  assert.equal(bridge.forgetClient("peer-1"), true, "goodbye drops the peer");
  assert.equal(bridge.clientCount(), 1, "leaving one behind");
  assert.equal(
    bridge.forgetClient("peer-1"),
    false,
    "a repeated goodbye is not a second departure",
  );
  assert.deepEqual(seen, [1, 2, 1], "and is not announced twice");

  // A client's chosen Studio goes with it, which is the leak forgetClient was
  // written for and never called to fix.
  bridge.attach(identity("studio-a", 111), null);
  bridge.attach(identity("studio-b", 222), null);
  await alice.setActive("studio-b");
  assert.equal((await alice.sessions()).activeIsChosen, true, "alice chose one");
  alice.goodbye();
  assert.equal(bridge.clientCount(), 0, "and left");
  assert.equal(
    (await alice.sessions()).activeIsChosen,
    false,
    "taking her choice with her",
  );
}

/** A client killed rather than closed is swept by the reaper. */
{
  const bridge = new Bridge();
  bridge.noteClient("ghost");
  assert.equal(bridge.clientCount(), 1, "the ghost registered");

  bridge.reapStale();
  assert.equal(bridge.clientCount(), 1, "a fresh client survives a sweep");

  // Reach past the clock rather than wait ninety seconds for it.
  const original = Date.now;
  Date.now = () => original() + 120_000;
  try {
    bridge.reapStale();
  } finally {
    Date.now = original;
  }
  assert.equal(bridge.clientCount(), 0, "a silent one does not");
}

/**
 * The bridge must not sweep away the process it is running inside.
 *
 * It did. `LocalBridge` announced itself once at construction and nothing ever
 * refreshed it, so ninety seconds later the reaper -- which cannot tell an
 * absent client from a quiet one -- dropped the owner from its own client list
 * while it was actively serving. The count then read one short, and the drop
 * was broadcast to the Studio console as an agent having finished. Found by a
 * user asking why the panel said three clients when there was one.
 */
{
  const bridge = new Bridge();
  const owner = new LocalBridge(bridge);
  bridge.attach(identity("studio-a", 111), null);
  assert.equal(bridge.clientCount(), 1, "the owner counts as a client");

  const real = Date.now;
  Date.now = () => real() + 120_000;
  try {
    // Working is what proves it is here, and the owner works constantly.
    await owner.sessions();
    bridge.reapStale();
  } finally {
    Date.now = real;
  }
  assert.equal(bridge.clientCount(), 1, "an owner that is working is not stale");

  // And it still goes when it actually goes.
  owner.goodbye();
  assert.equal(bridge.clientCount(), 0, "goodbye still drops it");
}


/**
 * The console asks "who is connected", not just "how many".
 *
 * A bare count is the thing users bring to us asking whether something is
 * wrong -- three agents they started and three processes they forgot read
 * identically. The roster is what answers it, so the ordering, the naming and
 * the "connected at" all have to survive a keepalive.
 */
{
  const bridge = new Bridge();
  const alice = new LocalBridge(bridge);
  const bob = new LocalBridge(bridge);

  // Nameless until the MCP handshake lands, and honest about it.
  assert.deepEqual(
    bridge.clientList().map((client) => client.name),
    ["unknown", "unknown"],
    "a client that has not introduced itself is not guessed at",
  );

  alice.describe({ name: "claude-code", version: "2.0" });
  bob.describe({ name: "codex", version: "1.0" });

  const named = bridge.clientList();
  assert.deepEqual(
    named.map((client) => client.name),
    ["claude-code", "codex"],
    "the roster is ordered by arrival, not by name",
  );
  assert.equal(named[0].version, "2.0");
  assert.ok(named[0].pid > 0, "a client reports which process it is");

  // A keepalive proves a client is still here. It does not make it new.
  const arrived = bridge.clientList()[0].connectedAt;
  const real = Date.now;
  Date.now = () => real() + 60_000;
  try {
    await alice.sessions();
  } finally {
    Date.now = real;
  }
  assert.equal(bridge.clientList()[0].connectedAt, arrived, "working does not reset the clock");
  assert.equal(bridge.clientList()[0].name, "claude-code", "working does not forget the name");

  // Learning a name is news, so the plugin is told; a repeat is not.
  let announced = 0;
  bridge.watchClients(() => {
    announced += 1;
  });
  alice.describe({ name: "claude-code", version: "2.0" });
  assert.equal(announced, 0, "re-stating the same name announces nothing");
  alice.describe({ name: "cursor", version: "1.0" });
  assert.equal(announced, 1, "a client that changes its name is announced");
}

// The console panel's `use` must route calls, not only studio_status -- and it
// must reach an agent that started after the user picked.
{
  const bridge = twoStudios();
  bridge.setActiveForAll("studio-b");
  const late = new LocalBridge(bridge);
  assert.equal((await late.sessions()).activeId, "studio-b");
  await late.call("studio.ping", {}, { timeoutMs: 50 }).catch((cause) => {
    assert.notEqual(cause.code, "AMBIGUOUS_STUDIO", "the user's pick routes the call");
  });
  assert.equal(bridge.sessions.get("studio-b").queue.length, 1, "the call went to the pick");

  await assert.rejects(
    async () => late.call("studio.ping", {}, { studioId: "gone", timeoutMs: 50 }),
    (cause) => cause.code === "UNKNOWN_STUDIO",
    "an unknown studioId is not reported as no Studio at all",
  );
}

// A stream that dies without /bye (a crashed Studio) removes its session, and a
// replaced stream closing late does not remove the session that replaced it.
{
  const { request } = await import("node:http");
  const { createServer } = await import("node:net");
  const { startBridgeServer } = await import("../dist/bridge/server.js");
  const port = await new Promise((resolve) => {
    const probe = createServer().listen(0, "127.0.0.1", () => {
      const { port: free } = probe.address();
      probe.close(() => resolve(free));
    });
  });
  const server = await startBridgeServer({ port });
  const open = () =>
    new Promise((resolve) => {
      const req = request(
        { host: "127.0.0.1", port, path: "/events", method: "POST", headers: { "x-roblox-studio-mcp": "test" } },
        (res) => {
          res.resume();
          resolve(req);
        },
      );
      req.end(JSON.stringify({ studioId: "crashy", placeName: "p", placeId: 1 }));
    });
  const count = async () =>
    (await (await fetch(`http://127.0.0.1:${port}/sessions`, { headers: { "x-roblox-studio-mcp": "test" } })).json())
      .list.length;
  const settle = () => new Promise((resolve) => setTimeout(resolve, 150));

  const first = await open();
  const second = await open();
  first.destroy();
  await settle();
  assert.equal(await count(), 1, "the old stream closing leaves the new session alone");
  second.destroy();
  await settle();
  assert.equal(await count(), 0, "a stream that dies without a goodbye is dropped");

  // A command far bigger than one socket read goes down the stream as ONE
  // event, and its answer comes back. The plugin half of this -- joining the
  // reads back together -- is covered by the frameReader cases in
  // tests/sseframes.luau; this pins the bridge half over real sockets.
  const source = "local x = 1\n".repeat(100_000);
  const events = [];
  const plugin = await new Promise((resolve) => {
    const req = request(
      { host: "127.0.0.1", port, path: "/events", method: "POST", headers: { "x-roblox-studio-mcp": "test" } },
      (res) => {
        let pending = "";
        res.setEncoding("utf8");
        res.on("data", (chunk) => {
          pending += chunk;
          let cut;
          while ((cut = pending.indexOf("\n\n")) !== -1) {
            const block = pending.slice(0, cut);
            pending = pending.slice(cut + 2);
            if (!block.startsWith("data: ")) continue;
            const frame = JSON.parse(block.slice(6));
            if (typeof frame.id !== "string") continue;
            events.push(frame);
            void fetch(`http://127.0.0.1:${port}/result?studioId=big`, {
              method: "POST",
              headers: { "x-roblox-studio-mcp": "test" },
              body: JSON.stringify({ id: frame.id, ok: true, data: { length: frame.params.source.length } }),
            });
          }
        });
        resolve(req);
      },
    );
    req.end(JSON.stringify({ studioId: "big", placeName: "p", placeId: 1 }));
  });
  const answer = await server.bridge.call("script.create", { source }, { studioId: "big" });
  assert.equal(answer.length, source.length, "a 1.2MB command arrives whole and is answered");
  assert.equal(events.length, 1, "as exactly one event");
  plugin.destroy();

  await server.close();
}

process.stdout.write("bridge: ok\n");
