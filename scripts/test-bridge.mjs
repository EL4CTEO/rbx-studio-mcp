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
