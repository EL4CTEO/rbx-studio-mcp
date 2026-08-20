#!/usr/bin/env node
/**
 * Measures round-trip latency against a connected Studio, per transport.
 *
 * This exists because the README's central claim -- that pushing over SSE beats
 * the long-polling every other Studio MCP server uses -- was written from first
 * principles and never measured. A performance claim nobody has timed is a
 * guess with a confident tone, which is exactly what this project criticises
 * other servers for.
 *
 * Method: send `studio.ping` N times sequentially against whichever transport
 * the plugin currently holds, and report the distribution. Sequential rather
 * than concurrent on purpose -- an agent waits for each answer before deciding
 * what to ask next, so serial round trips are the number that matters, and
 * running them in parallel would measure throughput instead.
 *
 * To compare transports, run it once while the plugin is streaming and once
 * while it has fallen back to polling. `list_studios` reports which is in use.
 *
 * Usage: node scripts/latency.mjs [--port 44755] [--count 50]
 */

const args = process.argv.slice(2);

function flag(name, fallback) {
  const at = args.indexOf(`--${name}`);
  return at === -1 ? fallback : args[at + 1];
}

const port = Number.parseInt(flag("port", "44755"), 10);
const count = Number.parseInt(flag("count", "50"), 10);
const base = `http://127.0.0.1:${port}`;

/** Percentile from a sorted array, nearest-rank. */
function percentile(sorted, fraction) {
  if (sorted.length === 0) return 0;
  const rank = Math.max(0, Math.ceil(fraction * sorted.length) - 1);
  return sorted[rank];
}

async function main() {
  // The bridge exposes no HTTP surface for tools, so this drives the same MCP
  // server the agent does, over stdio, and times the calls it makes.
  const { startBridgeServer } = await import("../dist/bridge/server.js");
  const server = await startBridgeServer({ port });
  const { bridge } = server;

  const deadline = Date.now() + 30_000;
  let studios = [];
  while (Date.now() < deadline) {
    studios = bridge.list();
    if (studios.length > 0) break;
    await new Promise((resolve) => setTimeout(resolve, 250));
  }

  if (studios.length === 0) {
    await server.close();
    // Written to stderr and exited non-zero: this is a measurement tool, and
    // reporting "0ms" for a run that never happened would be worse than failing.
    process.stderr.write(
      `No Studio connected on port ${port} within 30s.\n` +
        "Open Studio with the plugin installed, then run this again.\n",
    );
    process.exit(1);
  }

  const target = studios[0];
  const samples = [];

  // One warm-up that is not recorded: the first call after an idle period pays
  // for TCP and stream wake-up, which is real but is not what an agent's tenth
  // call costs, and including it would flatter or penalise nothing usefully.
  await bridge.call("studio.ping", {}, { studioId: target.studioId });

  for (let index = 0; index < count; index += 1) {
    const started = process.hrtime.bigint();
    await bridge.call("studio.ping", {}, { studioId: target.studioId });
    samples.push(Number(process.hrtime.bigint() - started) / 1e6);
  }

  await server.close();

  const sorted = [...samples].sort((a, b) => a - b);
  const mean = samples.reduce((sum, value) => sum + value, 0) / samples.length;

  const report = {
    transport: target.transport,
    place: target.placeName,
    samples: samples.length,
    meanMs: Number(mean.toFixed(2)),
    medianMs: Number(percentile(sorted, 0.5).toFixed(2)),
    p95Ms: Number(percentile(sorted, 0.95).toFixed(2)),
    minMs: Number(sorted[0].toFixed(2)),
    maxMs: Number(sorted[sorted.length - 1].toFixed(2)),
  };

  process.stdout.write(`${JSON.stringify(report, null, 2)}\n`);
}

main().catch((cause) => {
  process.stderr.write(`${cause instanceof Error ? cause.stack : String(cause)}\n`);
  process.exit(1);
});
