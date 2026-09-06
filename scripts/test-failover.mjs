/**
 * Checks that the bridge port outlives the process that happened to bind it.
 *
 * Exactly one process can hold the port the Studio plugin dials; every other
 * MCP client that starts this server proxies through it. The bug this covers is
 * what used to happen when the holder exited: the peers kept posting to a socket
 * nobody was listening on, so every tool call failed and the plugin's console
 * sat on "Nothing is listening on port 44755" -- with a healthy server process
 * still running that could have taken over. Reported by a user whose agent said
 * it was connected while the console showed the opposite.
 *
 * Runs against real sockets on a spare loopback port, because the thing being
 * tested is the bind race itself and a fake would test the fake.
 *
 * Usage: node scripts/test-failover.mjs
 */
import assert from "node:assert/strict";
import { createServer } from "node:http";
import { startBridgeServer } from "../dist/bridge/server.js";
import { CLIENT_HEADER } from "../dist/lib/protocol.js";
import { PEER_HEADER } from "../dist/bridge/remote.js";

const PORT = 44799;

/** Waits for `check` to hold, or gives up loudly rather than hanging the suite. */
async function until(check, what, timeoutMs = 20_000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (await check()) return;
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  assert.fail(`timed out waiting for ${what}`);
}

function handshake(port, studioId) {
  return fetch(`http://127.0.0.1:${port}/connect`, {
    method: "POST",
    headers: { [CLIENT_HEADER]: "test", "Content-Type": "application/json" },
    body: JSON.stringify({
      studioId,
      placeName: "Test place",
      placeId: 1,
      pluginVersion: "test",
      buildId: "test",
      protocolVersion: 1,
      transport: "poll",
      context: "edit",
    }),
  });
}

// A peer takes the port over when the owner exits, and really serves on it.
{
  const owner = await startBridgeServer({ port: PORT });
  assert.equal(owner.owner, true, "the first instance owns the port");

  const peer = await startBridgeServer({ port: PORT });
  assert.equal(peer.owner, false, "the second instance proxies");

  // Both see the same Studio, because there is only one bridge.
  await handshake(PORT, "studio-a");
  assert.equal((await peer.bridge.sessions()).list.length, 1, "the peer sees the owner's session");

  await owner.close();
  await until(() => peer.owner, "the peer to take the port over");

  // Owning the port is not the claim; serving on it is. The plugin reconnects
  // after a handover, so a fresh handshake has to land on the new owner.
  const response = await handshake(PORT, "studio-b");
  assert.equal(response.status, 200, "the new owner answers the plugin");
  const sessions = await peer.bridge.sessions();
  assert.deepEqual(
    sessions.list.map((session) => session.studioId),
    ["studio-b"],
    "the new owner serves its own bridge",
  );

  await peer.bridge.goodbye();
  await peer.close();
}

// A stranger on the port is still refused rather than proxied to.
{
  const stranger = createServer((_req, res) => {
    res.writeHead(404).end();
  });
  await new Promise((resolve) => stranger.listen(PORT, "127.0.0.1", resolve));
  await assert.rejects(
    () => startBridgeServer({ port: PORT }),
    /is in use by something that is not roblox-studio-mcp/,
    "posting Luau at an unknown server is never the right move",
  );
  await new Promise((resolve) => stranger.close(resolve));
}

//[[ Reading the roster does not join it.
//
// `GET /sessions` used to register whoever asked, so a one-shot read put a
// nameless client on the roster for the 90 seconds until the reaper swept it.
// `doctor` does exactly that read, which meant running a health check made the
// console say "2 MCP clients connected" and name one of them "unknown" with
// pid 0 -- indistinguishable from an agent the user had already closed, and
// duly reported as a bug.
//]]
{
  const owner = await startBridgeServer({ port: PORT });

  // The count comes back on /hello, so the whole check runs over the wire --
  // which is the only place the bug ever existed.
  const hello = async () => {
    const sent = await fetch(`http://127.0.0.1:${PORT}/hello`, {
      method: "POST",
      headers: {
        [CLIENT_HEADER]: "test",
        [PEER_HEADER]: "peer-counted",
        "Content-Type": "application/json",
      },
      body: JSON.stringify({ name: "peer", version: "1", pid: 1234 }),
    });
    return (await sent.json()).clients;
  };

  const before = await hello();

  const read = await fetch(`http://127.0.0.1:${PORT}/sessions`, {
    headers: { [CLIENT_HEADER]: "doctor" },
  });
  assert.equal(read.status, 200, "the roster is still readable");
  await read.json();

  assert.equal(await hello(), before, "reading /sessions does not add a client");

  await owner.close();
}

process.stdout.write("failover: ok\n");
