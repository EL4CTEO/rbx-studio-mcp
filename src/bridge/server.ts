import { createServer, type IncomingMessage, type Server, type ServerResponse } from "node:http";
import { CLIENT_HEADER, PROTOCOL_VERSION } from "../lib/protocol.js";
import { PEER_HEADER } from "./remote.js";
import { toToolError } from "../lib/errors.js";
import type { CommandResult, StudioIdentity } from "../lib/protocol.js";
import { Bridge } from "./rpc.js";
import { LocalBridge, type StudioBridge } from "./api.js";
import { probeOwner, RemoteBridge } from "./remote.js";

/** Default loopback port. Deliberately not 58741 — that is drgost1's server. */
export const DEFAULT_PORT = 44755;

/** SSE comment cadence. Keeps intermediaries and Studio from reaping an idle stream. */
const HEARTBEAT_MS = 15_000;

/** Largest body we accept from the plugin (script sources and screenshots are big). */
const MAX_BODY_BYTES = 32 * 1024 * 1024;

// The bridge's own diagnostic calls. They always name a studioId outright, so
// this never resolves anything -- it exists so they cannot inherit, or become,
// some agent's chosen target.
const INTERNAL_CLIENT = "bridge-internal";

export interface BridgeServerOptions {
  port?: number;
  bridge?: Bridge;
}

export interface BridgeServer {
  bridge: StudioBridge;
  port: number;
  close: () => Promise<void>;
  /** False when another instance owns the port and this one proxies to it. */
  owner: boolean;
}

/**
 * Starts the loopback HTTP endpoint the Studio plugin talks to.
 *
 * Routes:
 *   POST /connect  handshake; body is a StudioIdentity, answers with server info
 *   POST /events   SSE stream, server -> plugin commands (preferred path)
 *   GET  /poll     long-poll fallback for Studio builds without web streams
 *   POST /result   plugin -> server command results
 *   POST /bye      clean disconnect on plugin unload
 *   GET  /latency  times N round trips to a connected plugin; measurement only
 */
export function startBridgeServer(
  options: BridgeServerOptions = {},
): Promise<BridgeServer> {
  const bridge = options.bridge ?? new Bridge();
  const port = options.port ?? DEFAULT_PORT;

  const server = createServer((req, res) => {
    void handle(bridge, req, res);
  });

  /**
   * No Nagle on the command channel.
   *
   * Every frame this server pushes is a couple of hundred bytes written to an
   * otherwise idle socket, which is precisely the shape Nagle holds back
   * waiting for more to send. The whole claim of this transport is that a
   * command reaches Studio the instant it is issued, and it was being left to
   * the kernel's discretion.
   */
  server.on("connection", (socket) => socket.setNoDelay(true));

  /**
   * Tells every streaming plugin how many agents now share it, and says so
   * plainly when one leaves.
   *
   * The departure is the only moment this server can state that a session
   * ended rather than paused, so it is the only thing it phrases as a fact.
   */
  let knownClients = bridge.clientCount();
  bridge.watchClients((count) => {
    const left = count < knownClients;
    knownClients = count;
    bridge.broadcast({ event: "clients", count });
    if (left) bridge.broadcast({ event: "agent", state: "finished" });
  });

  // Long-poll requests park for POLL_HOLD_MS; Node's 2-minute default would be
  // fine, but SSE streams must never be reaped by the server itself.
  server.headersTimeout = 0;
  server.requestTimeout = 0;
  server.keepAliveTimeout = 0;

  const reaper = setInterval(() => bridge.reapStale(), 30_000);
  reaper.unref();

  return new Promise((resolve, reject) => {
    server.once("error", (cause: NodeJS.ErrnoException) => {
      // Overwhelmingly the cause is a second copy of this server (a stale
      // process, or the same server configured in two MCP clients). Both would
      // fight over the plugin's connection, so say so plainly instead of
      // surfacing a bare EADDRINUSE.
      if (cause.code === "EADDRINUSE") {
        // Almost always another copy of this server, which is not a failure:
        // the plugin can only connect to one port, so the right answer is to
        // share that one connection rather than fight for it. Any number of MCP
        // clients can then drive one Studio.
        void probeOwner(port).then((existing) => {
          if (existing) {
            clearInterval(reaper);
            const remote = new RemoteBridge(port, existing);
            resolve({
              bridge: remote,
              port,
              owner: false,
              // The owner is a different process and outlives this one, so
              // saying goodbye is the only way it learns this agent has gone.
              close: async () => {
                clearInterval(reaper);
                await remote.goodbye();
              },
            });
            return;
          }
          reject(
            new Error(
              `Port ${port} is in use by something that is not roblox-studio-mcp. ` +
                `Stop it, or start this one with --port <other> and set the matching ` +
                `port in the Studio plugin widget.`,
            ),
          );
        });
        return;
      }
      reject(cause);
    });
    // Loopback only: nothing on the network should be able to drive Studio.
    server.listen(port, "127.0.0.1", () => {
      server.removeListener("error", reject);
      resolve({
        bridge: new LocalBridge(bridge),
        port,
        owner: true,
        close: () => closeServer(server, reaper),
      });
    });
  });
}

function closeServer(server: Server, reaper: NodeJS.Timeout): Promise<void> {
  clearInterval(reaper);
  return new Promise((resolve) => {
    server.closeAllConnections();
    server.close(() => resolve());
  });
}

async function handle(
  bridge: Bridge,
  req: IncomingMessage,
  res: ServerResponse,
): Promise<void> {
  // A browser cannot set CLIENT_HEADER cross-origin without a preflight we never
  // answer, and same-origin means it is already local. Together with the Origin
  // rejection below this is what blocks DNS-rebinding attacks on the bridge.
  if (req.headers.origin !== undefined) return send(res, 403, { error: "origin not allowed" });
  if (req.headers[CLIENT_HEADER] === undefined) {
    return send(res, 403, { error: `missing ${CLIENT_HEADER} header` });
  }

  const url = new URL(req.url ?? "/", "http://127.0.0.1");

  try {
    switch (`${req.method} ${url.pathname}`) {
      case "POST /connect":
        return await handleConnect(bridge, req, res);
      case "POST /events":
        return await handleEvents(bridge, req, res);
      case "GET /poll":
        return await handlePoll(bridge, url, res);
      case "POST /result":
        return await handleResult(bridge, url, req, res);
      case "GET /latency":
        return await handleLatency(bridge, url, res);
      case "POST /transport":
        return await handleTransport(bridge, url, res);
      case "GET /identity":
        // Answered so a second instance can tell us apart from whatever else
        // might be squatting on the port. See probeOwner.
        return send(res, 200, {
          server: "roblox-studio-mcp",
          protocolVersion: PROTOCOL_VERSION,
          pid: process.pid,
        });
      case "POST /call":
        return await handlePeerCall(bridge, req, res);
      case "GET /sessions": {
        const clientId = peerId(req);
        bridge.noteClient(clientId);
        return send(res, 200, {
          list: bridge.list(),
          activeId: bridge.activeId(clientId),
          activeIsChosen: bridge.activeIsChosen(clientId),
        });
      }
      case "POST /active":
        return await handlePeerActive(bridge, req, res);
      case "POST /place-name":
        return await handlePeerPlaceName(bridge, req, res);
      case "POST /hello":
        // Registers a peer, and refreshes one already known. Peers call this on
        // startup and on a keepalive, so it must be idempotent.
        bridge.noteClient(peerId(req));
        return send(res, 200, { ok: true, clients: bridge.clientCount() });
      case "POST /goodbye":
        bridge.forgetClient(peerId(req));
        return send(res, 200, { ok: true, clients: bridge.clientCount() });
      case "POST /bye":
        bridge.detach(url.searchParams.get("studioId") ?? "");
        return send(res, 200, { ok: true });
      default:
        return send(res, 404, { error: "unknown route" });
    }
  } catch (cause) {
    const message = cause instanceof Error ? cause.message : String(cause);
    if (!res.headersSent) send(res, 400, { error: message });
    else res.end();
  }
}

/**
 * Times sequential round trips to a connected Studio and returns the spread.
 *
 * This exists so the project's central performance claim -- that pushing over
 * SSE beats the long-polling every other Studio MCP server uses -- can be
 * checked by whoever doubts it, without them having to take the number on
 * trust. It lives on the bridge rather than only in a script because the bridge
 * owns the port: a standalone measurement tool has to bind 44755 itself, which
 * means shutting down the editor's own connection first, and a measurement that
 * costs you your session is one nobody runs twice.
 *
 * `studio.ping` is the payload because it is the smallest command the plugin
 * answers, so what is left is the transport. Sequential rather than concurrent
 * on purpose: an agent waits for each answer before choosing what to ask next,
 * so serial round trips are the figure that matters, and running them in
 * parallel would measure throughput instead.
 */
async function handleLatency(
  bridge: Bridge,
  url: URL,
  res: ServerResponse,
): Promise<void> {
  const count = Math.min(Math.max(Number(url.searchParams.get("count") ?? 50), 1), 500);
  const requested = url.searchParams.get("studioId") ?? undefined;
  const studios = bridge.list();
  const target = requested
    ? studios.find((entry) => entry.studioId === requested)
    : studios[0];

  if (target === undefined) {
    // Reporting zero for a run that never happened would be worse than failing.
    return send(res, 409, {
      error:
        studios.length === 0
          ? "No Studio is connected. Open Studio with the plugin installed."
          : `No connected Studio has id ${requested}.`,
    });
  }

  // One warm-up that is not recorded: the first call after an idle period pays
  // for stream wake-up, which is real but is not what the tenth call costs.
  await bridge.call("studio.ping", {}, { clientId: INTERNAL_CLIENT, studioId: target.studioId });

  const samples: number[] = [];
  for (let index = 0; index < count; index += 1) {
    const started = process.hrtime.bigint();
    await bridge.call("studio.ping", {}, { clientId: INTERNAL_CLIENT, studioId: target.studioId });
    samples.push(Number(process.hrtime.bigint() - started) / 1e6);
  }

  const sorted = [...samples].sort((a, b) => a - b);
  const at = (fraction: number) =>
    sorted[Math.max(0, Math.ceil(fraction * sorted.length) - 1)] ?? 0;
  const round = (value: number) => Number(value.toFixed(2));

  send(res, 200, {
    transport: target.transport,
    place: target.placeName,
    samples: samples.length,
    meanMs: round(samples.reduce((sum, value) => sum + value, 0) / samples.length),
    medianMs: round(at(0.5)),
    p95Ms: round(at(0.95)),
    minMs: round(sorted[0] ?? 0),
    maxMs: round(sorted[sorted.length - 1] ?? 0),
  });
}

/**
 * Moves a connected plugin between the push and long-poll transports.
 *
 * Paired with /latency so one command can measure both sides of the comparison
 * the README rests on, rather than only the side this project prefers.
 */
async function handleTransport(
  bridge: Bridge,
  url: URL,
  res: ServerResponse,
): Promise<void> {
  const mode = url.searchParams.get("mode");
  if (mode !== "sse" && mode !== "poll") {
    return send(res, 400, { error: 'mode must be "sse" or "poll"' });
  }
  const requested = url.searchParams.get("studioId") ?? undefined;
  const target = requested
    ? bridge.list().find((entry) => entry.studioId === requested)
    : bridge.list()[0];
  if (target === undefined) {
    return send(res, 409, { error: "No Studio is connected." });
  }

  const result = await bridge.call("studio.transport", { mode }, { clientId: INTERNAL_CLIENT, studioId: target.studioId });
  send(res, 200, result as Record<string, unknown>);
}

async function handleConnect(
  bridge: Bridge,
  req: IncomingMessage,
  res: ServerResponse,
): Promise<void> {
  const identity = parseIdentity(await readBody(req));
  bridge.attach(identity, null);
  send(res, 200, {
    ok: true,
    protocolVersion: PROTOCOL_VERSION,
    pollHoldMs: 25_000,
    heartbeatMs: HEARTBEAT_MS,
  });
}

/**
 * Opens the push channel. The plugin reaches this through
 * `HttpService:CreateWebStreamClient`, which issues a normal POST and then
 * keeps the response body open, so identity rides in the request body.
 */
async function handleEvents(
  bridge: Bridge,
  req: IncomingMessage,
  res: ServerResponse,
): Promise<void> {
  const identity = parseIdentity(await readBody(req), "sse");

  res.writeHead(200, {
    "Content-Type": "text/event-stream",
    "Cache-Control": "no-cache, no-transform",
    Connection: "keep-alive",
    "X-Accel-Buffering": "no",
  });
  // Flush headers immediately so the plugin's Closed signal is meaningful.
  res.write(`: connected ${PROTOCOL_VERSION}\n\n`);

  const studioId = bridge.attach(identity, res);
  // Sent on connect, not only on change: a plugin that reconnects -- Studio
  // caps a stream at thirty minutes, so every long session does -- would
  // otherwise show a stale badge until the next agent came or went.
  res.write(`data: ${JSON.stringify({ event: "clients", count: bridge.clientCount() })}\n\n`);
  const heartbeat = setInterval(() => {
    if (res.writableEnded) return;
    res.write(": ping\n\n");
    bridge.touch(studioId);
  }, HEARTBEAT_MS);

  const teardown = (): void => {
    clearInterval(heartbeat);
    bridge.detach(studioId);
  };
  req.on("close", teardown);
  req.on("error", teardown);
}

async function handlePoll(
  bridge: Bridge,
  url: URL,
  res: ServerResponse,
): Promise<void> {
  const studioId = url.searchParams.get("studioId");
  if (!studioId || !bridge.has(studioId)) {
    // The plugin restarted the server, or we restarted under it. Either way it
    // must hand us its identity again before we can route commands to it.
    return send(res, 409, { error: "unknown studioId", reconnect: true });
  }
  const command = await bridge.waitForCommand(studioId);
  // Poll sessions cannot be pushed to, so the count rides on the answer they
  // were already waiting for. Sent every time rather than on change: the plugin
  // ignores repeats, and a session parked through a change would otherwise
  // never learn of it.
  const clients = bridge.clientCount();
  send(res, 200, command ? { command, clients } : { idle: true, clients });
}

async function handleResult(
  bridge: Bridge,
  url: URL,
  req: IncomingMessage,
  res: ServerResponse,
): Promise<void> {
  const studioId = url.searchParams.get("studioId") ?? "";
  const body = await readBody(req);
  const parsed = JSON.parse(body) as CommandResult;
  if (typeof parsed?.id !== "string") throw new Error("result is missing an id");
  bridge.settle(studioId, parsed);
  send(res, 200, { ok: true });
}

function parseIdentity(
  body: string,
  transport: "sse" | "poll" = "poll",
): StudioIdentity {
  const raw = JSON.parse(body) as Partial<StudioIdentity>;
  if (typeof raw.studioId !== "string" || raw.studioId.length === 0) {
    throw new Error("handshake is missing studioId");
  }
  return {
    studioId: raw.studioId,
    placeName: raw.placeName ?? "Unnamed place",
    placeId: raw.placeId ?? 0,
    pluginVersion: raw.pluginVersion ?? "unknown",
    buildId: raw.buildId ?? "unknown",
    // Absent on a plugin built before this field existed. 1 is both the
    // sentinel and the version that plugin actually speaks, so it reads as a
    // match rather than a false warning.
    protocolVersion: typeof raw.protocolVersion === "number" ? raw.protocolVersion : 1,
    transport: raw.transport ?? transport,
    // Optional, because a plugin older than this field still connects fine —
    // it simply lists without a context, as every session did before.
    context: raw.context,
  };
}

function readBody(req: IncomingMessage): Promise<string> {
  return new Promise((resolve, reject) => {
    const chunks: Buffer[] = [];
    let size = 0;
    req.on("data", (chunk: Buffer) => {
      size += chunk.length;
      if (size > MAX_BODY_BYTES) {
        reject(new Error("request body too large"));
        req.destroy();
        return;
      }
      chunks.push(chunk);
    });
    req.on("end", () => resolve(Buffer.concat(chunks).toString("utf8")));
    req.on("error", reject);
  });
}

function send(res: ServerResponse, status: number, body: unknown): void {
  const payload = JSON.stringify(body);
  res.writeHead(status, {
    "Content-Type": "application/json",
    "Content-Length": Buffer.byteLength(payload),
  });
  res.end(payload);
}

/**
 * Runs a command on behalf of another instance of this server.
 *
 * The failure is returned as a body rather than an HTTP status, because the
 * code and hint are the useful part and a 500 would throw them away — the peer
 * rebuilds a ToolError from this and the agent sees the same text it would have
 * seen had this process been the one it was talking to.
 */
/**
 * Which peer is asking, so its chosen Studio does not become everyone's.
 *
 * A peer that sends no id is treated as one anonymous client rather than
 * rejected: an older instance proxying to a newer one still works, it simply
 * shares a target with any other peer that also predates the header.
 */
function peerId(req: IncomingMessage): string {
  const sent = req.headers[PEER_HEADER];
  const value = Array.isArray(sent) ? sent[0] : sent;
  return value && value.length > 0 ? value : "anonymous-peer";
}

async function handlePeerCall(
  bridge: Bridge,
  req: IncomingMessage,
  res: ServerResponse,
): Promise<void> {
  const body = JSON.parse(await readBody(req)) as {
    op?: string;
    params?: Record<string, unknown>;
    studioId?: string;
    timeoutMs?: number;
  };
  if (typeof body.op !== "string") return send(res, 400, { ok: false, error: { code: "BAD_PEER_CALL", message: "no op" } });

  // A peer that predates /hello still counts, and one whose keepalive was lost
  // in a restart re-registers itself simply by working.
  bridge.noteClient(peerId(req));

  try {
    const data = await bridge.call(body.op, body.params ?? {}, {
      clientId: peerId(req),
      studioId: body.studioId,
      timeoutMs: body.timeoutMs,
    });
    return send(res, 200, { ok: true, data });
  } catch (cause) {
    const error = toToolError(cause);
    return send(res, 200, { ok: false, error: { code: error.code, message: error.message } });
  }
}

async function handlePeerActive(
  bridge: Bridge,
  req: IncomingMessage,
  res: ServerResponse,
): Promise<void> {
  const body = JSON.parse(await readBody(req)) as { studioId?: string };
  bridge.noteClient(peerId(req));
  try {
    bridge.setActive(peerId(req), String(body.studioId ?? ""));
    return send(res, 200, { ok: true });
  } catch (cause) {
    const error = toToolError(cause);
    return send(res, 200, { ok: false, error: { code: error.code, message: error.message } });
  }
}

async function handlePeerPlaceName(
  bridge: Bridge,
  req: IncomingMessage,
  res: ServerResponse,
): Promise<void> {
  const body = JSON.parse(await readBody(req)) as {
    studioId?: string;
    placeName?: string;
    context?: string;
  };
  bridge.notePlaceName(String(body.studioId ?? ""), String(body.placeName ?? ""), body.context);
  return send(res, 200, { ok: true });
}
