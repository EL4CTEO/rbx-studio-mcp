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
 * `--compare` measures both transports in one run: it times whichever is in
 * use, switches the plugin to the other, times that, and puts it back. Doing it
 * in one run matters -- the two numbers are only comparable if the same machine
 * measured them minutes apart rather than the favourable one being kept.
 *
 * Usage: node scripts/latency.mjs [--port 44755] [--count 50] [--compare]
 */

const args = process.argv.slice(2);

function flag(name, fallback) {
  const at = args.indexOf(`--${name}`);
  return at === -1 ? fallback : args[at + 1];
}

const port = Number.parseInt(flag("port", "44755"), 10);
const count = Number.parseInt(flag("count", "50"), 10);
const compare = args.includes("--compare");
const base = `http://127.0.0.1:${port}`;
const HEADERS = { "x-roblox-studio-mcp": "latency" };

/** Percentile from a sorted array, nearest-rank. */
function percentile(sorted, fraction) {
  if (sorted.length === 0) return 0;
  const rank = Math.max(0, Math.ceil(fraction * sorted.length) - 1);
  return sorted[rank];
}

/**
 * Asks a server that is already running to do the timing.
 *
 * The common case is that one is: the point of measuring is to check the claim
 * while actually using the thing, and the alternative -- shutting down the
 * editor's own connection so this script can take the port -- is a measurement
 * nobody runs twice. Returns null when nothing is listening, so the caller can
 * fall back to starting its own.
 */
async function askRunningServer() {
  let response;
  try {
    response = await fetch(`${base}/latency?count=${count}`, { headers: HEADERS });
  } catch {
    return null;
  }
  if (response.status === 404) {
    // Something is listening but has no /latency route, which means it is an
    // older build of this server still in memory. Worth naming, because the
    // 404 body says only "unknown route".
    process.stderr.write(
      `The server on port ${port} predates this script — it has no /latency route.\n` +
        "Restart it (in Claude Code, /mcp and reconnect) and run this again.\n",
    );
    process.exit(1);
  }
  if (!response.ok) {
    const body = await response.json().catch(() => ({}));
    process.stderr.write(
      `${body.error ?? `The server on port ${port} refused: HTTP ${response.status}.`}\n`,
    );
    process.exit(1);
  }
  return response.json();
}

/**
 * Moves the plugin to a transport and waits for it to actually get there.
 *
 * The switch is asynchronous by necessity -- the plugin answers first and then
 * tears its connection down, because replying over a stream it is about to
 * close would strand the answer. So this polls until a round trip succeeds on
 * the new transport rather than assuming a fixed delay is long enough.
 */
async function switchTransport(mode) {
  const response = await fetch(`${base}/transport?mode=${mode}`, {
    method: "POST",
    headers: HEADERS,
  });
  if (!response.ok) {
    const body = await response.json().catch(() => ({}));
    throw new Error(body.error ?? `switching to ${mode} failed: HTTP ${response.status}`);
  }

  const deadline = Date.now() + 30_000;
  while (Date.now() < deadline) {
    await new Promise((resolve) => setTimeout(resolve, 500));
    const probe = await fetch(`${base}/latency?count=1`, { headers: HEADERS });
    if (probe.ok) {
      const reading = await probe.json();
      if (reading.transport === mode) return;
    }
  }
  throw new Error(`the plugin did not reach ${mode} within 30s`);
}

async function main() {
  if (compare) {
    const first = await askRunningServer();
    if (first === null) {
      process.stderr.write(
        "--compare needs a server already running, since it drives the plugin " +
          "between transports.\n",
      );
      process.exit(1);
    }

    const other = first.transport === "sse" ? "poll" : "sse";
    await switchTransport(other);
    const second = await askRunningServer();
    // Put it back the way it was found. Leaving someone's editor on the slow
    // path as a side effect of measuring is not a trade this script gets to
    // make for them.
    await switchTransport(first.transport);

    const readings = { [first.transport]: first, [other]: second };
    process.stdout.write(`${JSON.stringify(readings, null, 2)}\n`);
    return;
  }

  const live = await askRunningServer();
  if (live !== null) {
    process.stdout.write(`${JSON.stringify(live, null, 2)}\n`);
    return;
  }

  // Nothing listening, so start the server ourselves and let it own the port.
  const { spawn } = await import("node:child_process");
  const { nativeBinary } = await import("./lib/native.mjs");
  const server = spawn(nativeBinary(), ["--port", String(port)], { stdio: ["pipe", "ignore", "inherit"] });
  try {
    const deadline = Date.now() + 30_000;
    while (Date.now() < deadline) {
      const measured = await askRunningServer();
      if (measured !== null) {
        process.stdout.write(`${JSON.stringify(measured, null, 2)}\n`);
        return;
      }
      await new Promise((resolve) => setTimeout(resolve, 500));
    }
    // A measurement tool must not report "0ms" for a run that never happened.
    process.stderr.write(
      `No Studio connected on port ${port} within 30s.\n` + "Open Studio with the plugin installed, then run this again.\n",
    );
    process.exitCode = 1;
  } finally {
    server.stdin.end();
    server.kill();
  }
}

main().catch((cause) => {
  process.stderr.write(`${cause instanceof Error ? cause.stack : String(cause)}\n`);
  process.exit(1);
});
