//! The loopback HTTP endpoint the Studio plugin (and proxying peers) talk to.
//!
//! Routes:
//!   POST /connect   handshake; body is a StudioIdentity
//!   POST /events    SSE stream, server -> plugin commands (preferred path)
//!   GET  /poll      long-poll fallback
//!   POST /result    plugin -> server command results
//!   POST /bye       clean disconnect on plugin unload
//!   GET  /latency   times N round trips to a connected plugin
//!   peer routes     /identity /call /sessions /active /place-name /hello /goodbye
//!   POST /console   a line typed into a Studio console panel

use super::rpc::{Bridge, ClientAbout, POLL_HOLD_MS, sse_frame};
use super::{anyhow_like, console};
use crate::protocol::{CLIENT_HEADER, CommandResult, PEER_HEADER, PROTOCOL_VERSION, parse_identity};
use axum::body::{Body, Bytes};
use axum::extract::{Request, State};
use axum::http::{HeaderMap, HeaderValue, Method, StatusCode, header};
use axum::response::Response;
use futures::Stream;
use serde_json::{Value, json};
use std::collections::HashMap;
use std::pin::Pin;
use std::sync::{Arc, LazyLock};
use std::task::{Context, Poll};
use std::time::{Duration, Instant};
use tokio::sync::mpsc;
use tokio::task::JoinHandle;

const HEARTBEAT: Duration = Duration::from_secs(15);
const MAX_BODY_BYTES: usize = 32 * 1024 * 1024;
const INTERNAL_CLIENT: &str = "bridge-internal";

/// What winning the port hands back.
pub struct Claimed {
    pub bridge: Arc<Bridge>,
    tasks: Vec<JoinHandle<()>>,
}

impl Claimed {
    pub fn close(self) {
        for task in &self.tasks {
            task.abort();
        }
        for session in self.bridge.list() {
            self.bridge.detach(&session.identity.studio_id);
        }
    }
}

#[derive(Clone)]
struct App {
    bridge: Arc<Bridge>,
    port: u16,
}

/// Binds the port, or returns None when it is taken. Binding is the whole test.
pub async fn claim_port(port: u16, seed: Option<Arc<Bridge>>) -> anyhow_like::Result<Option<Claimed>> {
    let listener = match tokio::net::TcpListener::bind(("127.0.0.1", port)).await {
        Ok(listener) => listener,
        Err(e) if e.kind() == std::io::ErrorKind::AddrInUse => return Ok(None),
        // Windows reports a port another socket holds exclusively as access denied.
        Err(e) if e.kind() == std::io::ErrorKind::PermissionDenied => return Ok(None),
        Err(e) => return Err(e.into()),
    };
    let bridge = seed.unwrap_or_else(Bridge::new);
    announce_clients(&bridge);

    let app = App { bridge: bridge.clone(), port };
    let router = axum::Router::new().fallback(handle).with_state(app);
    let serve = tokio::spawn(async move {
        let listener = NoDelay(listener);
        let _ = axum::serve(listener, router).await;
    });
    let reaper_bridge = bridge.clone();
    let reaper = tokio::spawn(async move {
        let mut tick = tokio::time::interval(Duration::from_secs(30));
        tick.tick().await;
        loop {
            tick.tick().await;
            reaper_bridge.reap_stale();
        }
    });
    Ok(Some(Claimed { bridge, tasks: vec![serve, reaper] }))
}

/// No Nagle on the command channel: every frame is small and urgent.
struct NoDelay(tokio::net::TcpListener);

impl axum::serve::Listener for NoDelay {
    type Io = tokio::net::TcpStream;
    type Addr = std::net::SocketAddr;

    async fn accept(&mut self) -> (Self::Io, Self::Addr) {
        loop {
            match self.0.accept().await {
                Ok((stream, addr)) => {
                    let _ = stream.set_nodelay(true);
                    return (stream, addr);
                }
                Err(_) => tokio::time::sleep(Duration::from_millis(10)).await,
            }
        }
    }

    fn local_addr(&self) -> std::io::Result<Self::Addr> {
        self.0.local_addr()
    }
}

/// Tells every streaming plugin how many agents share it, and when one leaves.
fn announce_clients(bridge: &Arc<Bridge>) {
    let known = parking_lot::Mutex::new(bridge.client_count());
    bridge.watch_clients(move |bridge, count, list| {
        let mut known = known.lock();
        let left = count < *known;
        *known = count;
        bridge.broadcast(&json!({ "event": "clients", "count": count, "list": list }));
        if left {
            bridge.broadcast(&json!({ "event": "agent", "state": "finished" }));
        }
    });
}

fn send(status: StatusCode, body: &Value) -> Response {
    let payload = serde_json::to_vec(body).unwrap_or_default();
    Response::builder()
        .status(status)
        .header(header::CONTENT_TYPE, "application/json")
        .header(header::CONNECTION, "close")
        .body(Body::from(payload))
        .unwrap()
}

/// Whether the Host header names this loopback server: the check that ends DNS rebinding.
fn host_is_loopback(headers: &HeaderMap, port: u16) -> bool {
    let Some(host) = headers.get(header::HOST) else { return true };
    let value = host.to_str().unwrap_or("").to_ascii_lowercase();
    ["127.0.0.1", "localhost", "[::1]"].iter().any(|name| value == format!("{name}:{port}"))
}

fn query(req: &Request) -> HashMap<String, String> {
    req.uri()
        .query()
        .map(|q| {
            q.split('&')
                .map(|pair| {
                    let (k, v) = pair.split_once('=').unwrap_or((pair, ""));
                    (decode(k), decode(v))
                })
                .collect()
        })
        .unwrap_or_default()
}

fn decode(s: &str) -> String {
    let bytes = s.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        match bytes[i] {
            b'+' => out.push(b' '),
            b'%' if i + 2 < bytes.len() => {
                match u8::from_str_radix(std::str::from_utf8(&bytes[i + 1..i + 3]).unwrap_or("zz"), 16) {
                    Ok(b) => {
                        out.push(b);
                        i += 2;
                    }
                    Err(_) => out.push(b'%'),
                }
            }
            b => out.push(b),
        }
        i += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

fn peer_id(headers: &HeaderMap) -> String {
    headers
        .get(PEER_HEADER)
        .and_then(|v| v.to_str().ok())
        .filter(|v| !v.is_empty())
        .unwrap_or("anonymous-peer")
        .to_string()
}

async fn read_body(body: Body) -> Result<Bytes, String> {
    axum::body::to_bytes(body, MAX_BODY_BYTES).await.map_err(|_| "request body too large".to_string())
}

fn parse<T: serde::de::DeserializeOwned + Default>(bytes: &[u8]) -> T {
    serde_json::from_slice(bytes).unwrap_or_default()
}

async fn handle(State(app): State<App>, req: Request) -> Response {
    let headers = req.headers().clone();
    if !host_is_loopback(&headers, app.port) {
        return send(StatusCode::FORBIDDEN, &json!({ "error": "host not allowed" }));
    }
    if headers.contains_key(header::ORIGIN) {
        return send(StatusCode::FORBIDDEN, &json!({ "error": "origin not allowed" }));
    }
    if !headers.contains_key(CLIENT_HEADER) {
        return send(StatusCode::FORBIDDEN, &json!({ "error": format!("missing {CLIENT_HEADER} header") }));
    }
    let q = query(&req);
    let method = req.method().clone();
    let path = req.uri().path().to_string();
    let bridge = app.bridge.clone();

    let outcome: Result<Response, String> = async {
        Ok(match (method, path.as_str()) {
            (Method::POST, "/connect") => {
                let identity = parse_identity(&read_body(req.into_body()).await?, "poll")?;
                bridge.attach(identity, None);
                send(
                    StatusCode::OK,
                    &json!({ "ok": true, "protocolVersion": PROTOCOL_VERSION, "pollHoldMs": POLL_HOLD_MS, "heartbeatMs": HEARTBEAT.as_millis() as u64 }),
                )
            }
            (Method::POST, "/events") => {
                let identity = parse_identity(&read_body(req.into_body()).await?, "sse")?;
                events(bridge, identity)
            }
            (Method::GET, "/poll") => poll(bridge, q.get("studioId").cloned().unwrap_or_default()).await,
            (Method::POST, "/result") => {
                let body = read_body(req.into_body()).await?;
                let result: CommandResult = serde_json::from_slice(&body).map_err(|_| "result is missing an id".to_string())?;
                bridge.settle(q.get("studioId").map(String::as_str).unwrap_or(""), result);
                send(StatusCode::OK, &json!({ "ok": true }))
            }
            (Method::GET, "/latency") => latency(bridge, &q).await,
            (Method::POST, "/transport") => transport(bridge, &q).await,
            (Method::GET, "/vendor/libmp") => libmp(),
            (Method::GET, "/identity") => send(
                StatusCode::OK,
                &json!({ "server": "roblox-studio-mcp", "protocolVersion": PROTOCOL_VERSION, "pid": std::process::id() }),
            ),
            (Method::POST, "/call") => {
                let body: Value = parse(&read_body(req.into_body()).await?);
                peer_call(bridge, &headers, body).await
            }
            (Method::GET, "/sessions") => {
                let client = peer_id(&headers);
                send(
                    StatusCode::OK,
                    &json!({ "list": bridge.list(), "activeId": bridge.active_id(&client), "activeIsChosen": bridge.active_is_chosen(&client) }),
                )
            }
            (Method::POST, "/active") => {
                let body: Value = parse(&read_body(req.into_body()).await?);
                let client = peer_id(&headers);
                bridge.note_client(&client, ClientAbout::default());
                let id = body.get("studioId").and_then(Value::as_str).unwrap_or("");
                match bridge.set_active(&client, id) {
                    Ok(()) => send(StatusCode::OK, &json!({ "ok": true })),
                    Err(e) => send(StatusCode::OK, &json!({ "ok": false, "error": { "code": e.code, "message": e.message, "hint": e.hint } })),
                }
            }
            (Method::POST, "/place-name") => {
                let body: Value = parse(&read_body(req.into_body()).await?);
                let s = |k: &str| body.get(k).and_then(Value::as_str).unwrap_or("").to_string();
                bridge.note_place_name(&s("studioId"), &s("placeName"), body.get("context").and_then(Value::as_str));
                send(StatusCode::OK, &json!({ "ok": true }))
            }
            (Method::POST, "/hello") => {
                let about: Value = read_body(req.into_body()).await.ok().map(|b| parse(&b)).unwrap_or_default();
                let label = |k: &str| {
                    about.get(k).and_then(Value::as_str).filter(|s| !s.is_empty()).map(|s| s.chars().take(64).collect::<String>())
                };
                bridge.note_client(
                    &peer_id(&headers),
                    ClientAbout {
                        name: label("name"),
                        version: label("version"),
                        pid: Some(about.get("pid").and_then(Value::as_u64).unwrap_or(0) as u32),
                        spawned: Some(about.get("spawned").and_then(Value::as_bool) == Some(true)),
                    },
                );
                send(StatusCode::OK, &json!({ "ok": true, "clients": bridge.client_count() }))
            }
            (Method::POST, "/refused") => {
                // A peer's call was refused before it reached Studio: put it in
                // the panel of the Studio that peer is aimed at.
                let body: Value = parse(&read_body(req.into_body()).await?);
                let s = |k: &str| body.get(k).and_then(Value::as_str).unwrap_or("").to_string();
                if let Some(id) = bridge.active_id(&peer_id(&headers)) {
                    bridge.notify(&id, &json!({ "event": "refused", "title": s("title"), "code": s("code") }));
                }
                send(StatusCode::OK, &json!({ "ok": true }))
            }
            (Method::POST, "/goodbye") => {
                bridge.forget_client(&peer_id(&headers));
                send(StatusCode::OK, &json!({ "ok": true, "clients": bridge.client_count() }))
            }
            (Method::POST, "/console") => {
                let body: Value = parse(&read_body(req.into_body()).await?);
                let studio_id = body.get("studioId").and_then(Value::as_str).unwrap_or("").to_string();
                let request = console::ConsoleRequest {
                    studio_id: studio_id.clone(),
                    command: body.get("command").and_then(Value::as_str).unwrap_or("").to_string(),
                    args: body
                        .get("args")
                        .and_then(Value::as_array)
                        .map(|a| a.iter().filter_map(|v| v.as_str().map(str::to_string)).collect())
                        .unwrap_or_default(),
                    line: body.get("line").and_then(Value::as_str).unwrap_or("").to_string(),
                };
                let lines = console::handle(&bridge, app.port, request).await;
                send(StatusCode::OK, &json!({ "lines": lines, "running": console::agent_running(&studio_id) }))
            }
            (Method::POST, "/bye") => {
                bridge.detach(q.get("studioId").map(String::as_str).unwrap_or(""));
                send(StatusCode::OK, &json!({ "ok": true }))
            }
            _ => send(StatusCode::NOT_FOUND, &json!({ "error": "unknown route" })),
        })
    }
    .await;

    outcome.unwrap_or_else(|message| send(StatusCode::BAD_REQUEST, &json!({ "error": message })))
}

/// An SSE body that tells the bridge when the plugin hangs up.
struct EventStream {
    rx: mpsc::UnboundedReceiver<Bytes>,
    bridge: Arc<Bridge>,
    studio_id: String,
    stream_id: u64,
}

impl Stream for EventStream {
    type Item = Result<Bytes, std::convert::Infallible>;
    fn poll_next(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<Option<Self::Item>> {
        self.rx.poll_recv(cx).map(|item| item.map(Ok))
    }
}

impl Drop for EventStream {
    fn drop(&mut self) {
        self.bridge.detach_stream(&self.studio_id, self.stream_id);
    }
}

fn events(bridge: Arc<Bridge>, identity: crate::protocol::StudioIdentity) -> Response {
    let (tx, rx) = mpsc::unbounded_channel::<Bytes>();
    let studio_id = identity.studio_id.clone();
    let _ = tx.send(Bytes::from(format!(": connected {PROTOCOL_VERSION}\n\n")));
    let stream_id = bridge.attach(identity, Some(tx.clone()));
    // Sent on connect, not only on change: every long session reconnects.
    let _ = tx.send(sse_frame(&json!({ "event": "clients", "count": bridge.client_count(), "list": bridge.client_list() })));

    let heartbeat_bridge = bridge.clone();
    let heartbeat_id = studio_id.clone();
    tokio::spawn(async move {
        let mut tick = tokio::time::interval(HEARTBEAT);
        tick.tick().await;
        loop {
            tick.tick().await;
            if tx.send(Bytes::from_static(b": ping\n\n")).is_err() {
                return;
            }
            heartbeat_bridge.touch(&heartbeat_id);
        }
    });

    let body = Body::from_stream(EventStream { rx, bridge, studio_id, stream_id });
    let mut response = Response::new(body);
    let h = response.headers_mut();
    h.insert(header::CONTENT_TYPE, HeaderValue::from_static("text/event-stream"));
    h.insert(header::CACHE_CONTROL, HeaderValue::from_static("no-cache, no-transform"));
    h.insert(header::CONNECTION, HeaderValue::from_static("keep-alive"));
    h.insert("x-accel-buffering", HeaderValue::from_static("no"));
    response
}

async fn poll(bridge: Arc<Bridge>, studio_id: String) -> Response {
    if studio_id.is_empty() || !bridge.has(&studio_id) {
        return send(StatusCode::CONFLICT, &json!({ "error": "unknown studioId", "reconnect": true }));
    }
    // If the plugin hangs up while parked, hyper drops this future; a command
    // already taken is put back by the guard rather than lost.
    struct Requeue {
        bridge: Arc<Bridge>,
        studio_id: String,
        command: Option<crate::protocol::Command>,
    }
    impl Drop for Requeue {
        fn drop(&mut self) {
            if let Some(cmd) = self.command.take() {
                self.bridge.requeue(&self.studio_id, cmd);
            }
        }
    }
    let command = bridge.wait_for_command(&studio_id).await;
    let mut guard = Requeue { bridge: bridge.clone(), studio_id, command };
    let clients = bridge.client_count();
    let list = bridge.client_list();
    let body = match guard.command.take() {
        Some(cmd) => json!({ "command": cmd, "clients": clients, "clientList": list }),
        None => json!({ "idle": true, "clients": clients, "clientList": list }),
    };
    send(StatusCode::OK, &body)
}

fn target_of(bridge: &Bridge, q: &HashMap<String, String>) -> Option<crate::protocol::StudioSession> {
    let studios = bridge.list();
    match q.get("studioId") {
        Some(id) if !id.is_empty() => studios.into_iter().find(|s| &s.identity.studio_id == id),
        _ => studios.into_iter().next(),
    }
}

/// Times sequential round trips so the transport claim can be checked.
async fn latency(bridge: Arc<Bridge>, q: &HashMap<String, String>) -> Response {
    let count = q.get("count").and_then(|c| c.parse::<f64>().ok()).filter(|c| c.is_finite()).map(|c| c.trunc().clamp(1.0, 500.0) as usize).unwrap_or(50);
    let Some(target) = target_of(&bridge, q) else {
        let error = if bridge.list().is_empty() {
            "No Studio is connected. Open Studio with the plugin installed.".to_string()
        } else {
            format!("No connected Studio has id {}.", q.get("studioId").cloned().unwrap_or_default())
        };
        return send(StatusCode::CONFLICT, &json!({ "error": error }));
    };
    let id = target.identity.studio_id.clone();
    if let Err(e) = bridge.call("studio.ping", json!({}), INTERNAL_CLIENT, Some(&id), None).await {
        return send(StatusCode::BAD_REQUEST, &json!({ "error": e.message }));
    }
    let mut samples = Vec::with_capacity(count);
    for _ in 0..count {
        let started = Instant::now();
        if let Err(e) = bridge.call("studio.ping", json!({}), INTERNAL_CLIENT, Some(&id), None).await {
            return send(StatusCode::BAD_REQUEST, &json!({ "error": e.message }));
        }
        samples.push(started.elapsed().as_secs_f64() * 1000.0);
    }
    let mut sorted = samples.clone();
    sorted.sort_by(|a, b| a.total_cmp(b));
    let at = |f: f64| sorted[((f * sorted.len() as f64).ceil() as usize).max(1) - 1];
    let round = |v: f64| (v * 100.0).round() / 100.0;
    send(
        StatusCode::OK,
        &json!({
            "transport": target.identity.transport,
            "place": target.identity.place_name,
            "samples": samples.len(),
            "meanMs": round(samples.iter().sum::<f64>() / samples.len() as f64),
            "medianMs": round(at(0.5)),
            "p95Ms": round(at(0.95)),
            "minMs": round(sorted[0]),
            "maxMs": round(sorted[sorted.len() - 1]),
        }),
    )
}

async fn transport(bridge: Arc<Bridge>, q: &HashMap<String, String>) -> Response {
    let mode = q.get("mode").map(String::as_str).unwrap_or("");
    if mode != "sse" && mode != "poll" {
        return send(StatusCode::BAD_REQUEST, &json!({ "error": "mode must be \"sse\" or \"poll\"" }));
    }
    let Some(target) = target_of(&bridge, q) else {
        return send(StatusCode::CONFLICT, &json!({ "error": "No Studio is connected." }));
    };
    match bridge.call("studio.transport", json!({ "mode": mode }), INTERNAL_CLIENT, Some(&target.identity.studio_id), None).await {
        Ok(result) => send(StatusCode::OK, &result),
        Err(e) => send(StatusCode::BAD_REQUEST, &json!({ "error": e.message })),
    }
}

static LIBMP_DEFLATED: &[u8] = include_bytes!(concat!(env!("OUT_DIR"), "/LibMP.luau.deflate"));
static LIBMP: LazyLock<Bytes> = LazyLock::new(|| {
    use std::io::Read;
    let mut out = Vec::new();
    let _ = flate2::read::DeflateDecoder::new(LIBMP_DEFLATED).read_to_end(&mut out);
    Bytes::from(out)
});

/// Roblox's LibMP (MIT), for the plugin's MicroProfiler reader.
fn libmp() -> Response {
    if LIBMP.is_empty() {
        return send(StatusCode::NOT_FOUND, &json!({ "error": "LibMP is missing from this build" }));
    }
    Response::builder()
        .status(StatusCode::OK)
        .header(header::CONTENT_TYPE, "text/plain; charset=utf-8")
        .header(header::CONNECTION, "close")
        .body(Body::from(LIBMP.clone()))
        .unwrap()
}

/// Runs a command for another instance; failures come back as a body, hint included.
async fn peer_call(bridge: Arc<Bridge>, headers: &HeaderMap, body: Value) -> Response {
    let Some(op) = body.get("op").and_then(Value::as_str) else {
        return send(StatusCode::BAD_REQUEST, &json!({ "ok": false, "error": { "code": "BAD_PEER_CALL", "message": "no op" } }));
    };
    let client = peer_id(headers);
    bridge.note_client(&client, ClientAbout::default());
    let params = body.get("params").cloned().filter(|p| !p.is_null()).unwrap_or_else(|| json!({}));
    let studio = body.get("studioId").and_then(Value::as_str);
    let timeout = body.get("timeoutMs").and_then(Value::as_f64);
    match bridge.call(op, params, &client, studio, timeout).await {
        Ok(data) => send(StatusCode::OK, &json!({ "ok": true, "data": data })),
        Err(e) => send(StatusCode::OK, &json!({ "ok": false, "error": { "code": e.code, "message": e.message, "hint": e.hint } })),
    }
}
