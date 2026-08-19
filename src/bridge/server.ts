import { createServer, type IncomingMessage, type Server, type ServerResponse } from "node:http";
import { CLIENT_HEADER, PROTOCOL_VERSION } from "../lib/protocol.js";
import type { CommandResult, StudioIdentity } from "../lib/protocol.js";
import { Bridge } from "./rpc.js";

/** Default loopback port. Deliberately not 58741 — that is drgost1's server. */
export const DEFAULT_PORT = 44755;

/** SSE comment cadence. Keeps intermediaries and Studio from reaping an idle stream. */
const HEARTBEAT_MS = 15_000;

/** Largest body we accept from the plugin (script sources and screenshots are big). */
const MAX_BODY_BYTES = 32 * 1024 * 1024;

export interface BridgeServerOptions {
  port?: number;
  bridge?: Bridge;
}

export interface BridgeServer {
  bridge: Bridge;
  port: number;
  close: () => Promise<void>;
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
 */
export function startBridgeServer(
  options: BridgeServerOptions = {},
): Promise<BridgeServer> {
  const bridge = options.bridge ?? new Bridge();
  const port = options.port ?? DEFAULT_PORT;

  const server = createServer((req, res) => {
    void handle(bridge, req, res);
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
        reject(
          new Error(
            `Port ${port} is already in use — another roblox-studio-mcp is probably ` +
              `running. Stop it, or start this one with --port <other> and set the ` +
              `matching port in the Studio plugin widget.`,
          ),
        );
        return;
      }
      reject(cause);
    });
    // Loopback only: nothing on the network should be able to drive Studio.
    server.listen(port, "127.0.0.1", () => {
      server.removeListener("error", reject);
      resolve({
        bridge,
        port,
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
  send(res, 200, command ? { command } : { idle: true });
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
