//! The bridge between MCP clients and Studio.
//!
//! Exactly one process can hold the port the plugin dials; every other copy of
//! this server proxies through it. `StudioBridge` hides which one this process
//! is, and takes the port over if the owner exits.

pub mod console;
pub mod harness;
pub mod rpc;
pub mod server;

use crate::errors::{self, Result, ToolError};
use crate::protocol::{CLIENT_HEADER, PEER_HEADER, PROTOCOL_VERSION, StudioSession};
use parking_lot::{Mutex, RwLock};
use rpc::{Bridge, ClientAbout};
use serde::Deserialize;
use serde_json::{Value, json};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;

const KEEPALIVE: Duration = Duration::from_secs(30);
const WATCH: Duration = Duration::from_secs(3);

/// Whether this process serves an agent a console panel started.
pub fn spawned_by_panel() -> bool {
    std::env::var("RBX_STUDIO_MCP_SPAWNED").is_ok_and(|v| v == "1")
}

#[derive(Clone, Debug, Default)]
pub struct ClientDescription {
    pub name: String,
    pub version: String,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SessionsView {
    pub list: Vec<StudioSession>,
    pub active_id: Option<String>,
    #[serde(default)]
    pub active_is_chosen: bool,
}

#[derive(Debug, Clone, Deserialize)]
pub struct OwnerIdentity {
    pub server: String,
    #[serde(rename = "protocolVersion")]
    pub protocol_version: i64,
    pub pid: u32,
}

pub fn http_client() -> &'static reqwest::Client {
    static CLIENT: std::sync::LazyLock<reqwest::Client> = std::sync::LazyLock::new(|| {
        reqwest::Client::builder()
            .pool_max_idle_per_host(0)
            .tcp_nodelay(true)
            .no_proxy()
            .build()
            .expect("http client")
    });
    &CLIENT
}

/// Asks whatever holds `port` whether it is another copy of this server.
pub async fn probe_owner(port: u16) -> Option<OwnerIdentity> {
    let response = http_client()
        .get(format!("http://127.0.0.1:{port}/identity"))
        .header(CLIENT_HEADER, "peer")
        .timeout(Duration::from_secs(2))
        .send()
        .await
        .ok()?;
    if !response.status().is_success() {
        return None;
    }
    let body: OwnerIdentity = response.json().await.ok()?;
    (body.server == "roblox-studio-mcp" && body.protocol_version == PROTOCOL_VERSION).then_some(body)
}

enum Mode {
    Local(Arc<Bridge>),
    Remote { owner_pid: u32 },
}

/// What tools hold. Owner or peer, it answers the same way.
pub struct StudioBridge {
    mode: RwLock<Mode>,
    port: u16,
    client_id: String,
    about: Mutex<Option<ClientDescription>>,
    server: Mutex<Option<server::Claimed>>,
    stopped: AtomicBool,
    claiming: AtomicBool,
}

impl StudioBridge {
    /// Owns the port if it can; otherwise becomes a peer of the process that does.
    pub async fn start(port: u16) -> anyhow_like::Result<Arc<Self>> {
        if let Some(claimed) = server::claim_port(port, None).await? {
            let bridge = claimed.bridge.clone();
            let this = Arc::new(Self::new(Mode::Local(bridge), port));
            *this.server.lock() = Some(claimed);
            this.start_keepalive();
            this.note_self();
            return Ok(this);
        }
        let Some(owner) = probe_owner(port).await else {
            return Err(format!(
                "Port {port} is in use by something that is not roblox-studio-mcp. Stop it, or start \
                 this one with --port <other> and set the matching port in the Studio plugin widget."
            )
            .into());
        };
        let this = Arc::new(Self::new(Mode::Remote { owner_pid: owner.pid }, port));
        this.start_keepalive();
        this.start_watch();
        Ok(this)
    }

    fn new(mode: Mode, port: u16) -> Self {
        Self {
            mode: RwLock::new(mode),
            port,
            client_id: uuid::Uuid::new_v4().to_string(),
            about: Mutex::new(None),
            server: Mutex::new(None),
            stopped: AtomicBool::new(false),
            claiming: AtomicBool::new(false),
        }
    }

    pub fn is_owner(&self) -> bool {
        matches!(*self.mode.read(), Mode::Local(_))
    }

    fn local(&self) -> Option<Arc<Bridge>> {
        match &*self.mode.read() {
            Mode::Local(b) => Some(b.clone()),
            Mode::Remote { .. } => None,
        }
    }

    fn note_self(&self) {
        if let Some(bridge) = self.local() {
            let about = self.about.lock().clone();
            bridge.note_client(
                &self.client_id,
                ClientAbout {
                    name: about.as_ref().map(|a| a.name.clone()),
                    version: about.as_ref().map(|a| a.version.clone()),
                    pid: about.as_ref().map(|_| std::process::id()),
                    spawned: Some(spawned_by_panel()),
                },
            );
        }
    }

    fn start_keepalive(self: &Arc<Self>) {
        let weak = Arc::downgrade(self);
        tokio::spawn(async move {
            let mut tick = tokio::time::interval(KEEPALIVE);
            tick.tick().await;
            loop {
                tick.tick().await;
                let Some(this) = weak.upgrade() else { return };
                if this.stopped.load(Ordering::Relaxed) {
                    return;
                }
                if this.is_owner() {
                    this.note_self();
                } else {
                    this.hello().await;
                }
            }
        });
        if !self.is_owner() {
            let this = self.clone();
            tokio::spawn(async move { this.hello().await });
        }
    }

    fn start_watch(self: &Arc<Self>) {
        let weak = Arc::downgrade(self);
        tokio::spawn(async move {
            loop {
                tokio::time::sleep(WATCH).await;
                let Some(this) = weak.upgrade() else { return };
                if this.stopped.load(Ordering::Relaxed) || this.is_owner() {
                    return;
                }
                this.promote().await;
            }
        });
    }

    /// Takes the port if it is going spare. The bind attempt is the test.
    async fn promote(self: &Arc<Self>) {
        if self.stopped.load(Ordering::Relaxed) || self.is_owner() || self.claiming.swap(true, Ordering::AcqRel) {
            return;
        }
        if let Ok(Some(claimed)) = server::claim_port(self.port, None).await {
            if self.stopped.load(Ordering::Relaxed) {
                claimed.close();
            } else {
                // Stop the keepalive aimed at the old owner, best effort.
                self.post_raw("/goodbye", json!({}), 5_000).await.ok();
                *self.mode.write() = Mode::Local(claimed.bridge.clone());
                *self.server.lock() = Some(claimed);
                self.note_self();
                eprintln!("roblox-studio-mcp: the instance holding the bridge port exited; this one took it over.");
            }
        }
        self.claiming.store(false, Ordering::Release);
    }

    /// Puts a call the server refused before sending into the active Studio's
    /// panel, which otherwise never hears of it. Owner only; best effort.
    pub fn announce_refused(self: &Arc<Self>, title: &str, code: &str) {
        match self.local() {
            Some(bridge) => {
                if let Some(id) = bridge.active_id(&self.client_id) {
                    bridge.notify(&id, &json!({ "event": "refused", "title": title, "code": code }));
                }
            }
            // A peer hands it to the owner, which holds the Studio connection.
            None => {
                let this = self.clone();
                let body = json!({ "title": title, "code": code });
                tokio::spawn(async move {
                    let _ = this.post_raw("/refused", body, 5_000).await;
                });
            }
        }
    }

    pub fn describe(self: &Arc<Self>, about: ClientDescription) {
        *self.about.lock() = Some(about);
        if self.is_owner() {
            self.note_self();
        } else {
            let this = self.clone();
            tokio::spawn(async move { this.hello().await });
        }
    }

    /// Leaves the bridge cleanly, then shuts any listening socket.
    pub async fn shutdown(&self) {
        if self.stopped.swap(true, Ordering::AcqRel) {
            return;
        }
        match self.local() {
            Some(bridge) => {
                bridge.forget_client(&self.client_id);
            }
            None => {
                let _ = self.post_raw("/goodbye", json!({}), 5_000).await;
            }
        }
        if let Some(server) = self.server.lock().take() {
            server.close();
        }
    }

    pub async fn call(self: &Arc<Self>, op: &str, params: Value, studio_id: Option<&str>, timeout_ms: Option<f64>) -> Result<Value> {
        crate::tool::mark_sent();
        if let Some(bridge) = self.local() {
            bridge.note_client(&self.client_id, ClientAbout::default());
            return bridge.call(op, params, &self.client_id, studio_id, timeout_ms).await;
        }
        let timeout = errors::normalize_timeout_ms(timeout_ms.unwrap_or(rpc::DEFAULT_TIMEOUT_MS as f64), 0)?;
        let body = json!({ "op": op, "params": params, "studioId": studio_id, "timeoutMs": timeout });
        self.failing(self.post("/call", body, timeout).await)
    }

    /// A call that found the owner gone starts the handover itself.
    fn failing<T>(self: &Arc<Self>, outcome: Result<T>) -> Result<T> {
        if let Err(e) = &outcome
            && e.code == "OWNER_GONE" {
                let this = self.clone();
                tokio::spawn(async move { this.promote().await });
            }
        outcome
    }

    pub async fn sessions(self: &Arc<Self>) -> Result<SessionsView> {
        if let Some(bridge) = self.local() {
            bridge.note_client(&self.client_id, ClientAbout::default());
            return Ok(SessionsView {
                list: bridge.list(),
                active_id: bridge.active_id(&self.client_id),
                active_is_chosen: bridge.active_is_chosen(&self.client_id),
            });
        }
        let outcome = async {
            let response = http_client()
                .get(format!("http://127.0.0.1:{}/sessions", self.port))
                .header(CLIENT_HEADER, "peer")
                .header(PEER_HEADER, &self.client_id)
                .timeout(Duration::from_secs(5))
                .send()
                .await
                .map_err(|e| self.unreachable(e))?;
            let value: Value = response.json().await.map_err(|e| self.unreachable(e))?;
            if !value.get("list").is_some_and(Value::is_array) {
                return Err(peer_error(value.get("error")));
            }
            serde_json::from_value::<SessionsView>(value).map_err(ToolError::internal)
        }
        .await;
        self.failing(outcome)
    }

    pub async fn set_active(self: &Arc<Self>, studio_id: &str) -> Result<()> {
        if let Some(bridge) = self.local() {
            return bridge.set_active(&self.client_id, studio_id);
        }
        self.post("/active", json!({ "studioId": studio_id }), 5_000).await.map(|_| ())
    }

    pub async fn note_place_name(self: &Arc<Self>, studio_id: &str, place_name: &str, context: Option<&str>) {
        if let Some(bridge) = self.local() {
            bridge.note_place_name(studio_id, place_name, context);
            return;
        }
        let _ = self
            .post_raw("/place-name", json!({ "studioId": studio_id, "placeName": place_name, "context": context }), 5_000)
            .await;
    }

    async fn hello(&self) {
        let about = self.about.lock().clone();
        let _ = self
            .post_raw(
                "/hello",
                json!({
                    "name": about.as_ref().map(|a| &a.name),
                    "version": about.as_ref().map(|a| &a.version),
                    "pid": std::process::id(),
                    "spawned": spawned_by_panel(),
                }),
                5_000,
            )
            .await;
    }

    fn unreachable(&self, cause: impl std::fmt::Display) -> ToolError {
        let pid = match &*self.mode.read() {
            Mode::Remote { owner_pid } => *owner_pid,
            Mode::Local(_) => std::process::id(),
        };
        ToolError::hint(
            "OWNER_GONE",
            format!(
                "The roblox-studio-mcp instance holding port {} (pid {pid}) stopped answering: {cause}",
                self.port
            ),
            "That process owns the Studio connection and this one borrows it. It has most likely \
             exited, in which case this server takes the port over within a few seconds — try the call again.",
        )
    }

    async fn post_raw(&self, path: &str, body: Value, timeout_ms: u64) -> Result<Value> {
        // Padded past the command's own deadline so the owner's timeout wins.
        let budget = errors::normalize_timeout_ms(timeout_ms as f64, 10_000)?;
        let response = http_client()
            .post(format!("http://127.0.0.1:{}{path}", self.port))
            .header(CLIENT_HEADER, "peer")
            .header(PEER_HEADER, &self.client_id)
            .header("content-type", "application/json")
            .body(serde_json::to_vec(&body)?)
            .timeout(Duration::from_millis(budget))
            .send()
            .await
            .map_err(|e| self.unreachable(e))?;
        response.json::<Value>().await.map_err(|e| self.unreachable(e))
    }

    async fn post(&self, path: &str, body: Value, timeout_ms: u64) -> Result<Value> {
        let payload = self.post_raw(path, body, timeout_ms).await?;
        if payload.get("ok").and_then(Value::as_bool) != Some(true) {
            return Err(peer_error(payload.get("error")));
        }
        Ok(payload.get("data").cloned().unwrap_or(Value::Null))
    }
}

/// Rebuilds the owner's refusal as a ToolError, whichever shape it came in.
fn peer_error(error: Option<&Value>) -> ToolError {
    match error {
        Some(Value::String(s)) => ToolError::new("PEER_ERROR", s.clone()),
        Some(Value::Object(map)) => match map.get("message").and_then(Value::as_str) {
            Some(message) => ToolError {
                code: map.get("code").and_then(Value::as_str).unwrap_or("PEER_ERROR").to_string(),
                message: message.to_string(),
                hint: map.get("hint").and_then(Value::as_str).map(str::to_string),
            },
            None => ToolError::new("PEER_ERROR", "the bridge owner refused the request"),
        },
        _ => ToolError::new("PEER_ERROR", "the bridge owner refused the request"),
    }
}

/// A minimal boxed error for startup paths, without pulling in anyhow.
pub mod anyhow_like {
    pub type Error = Box<dyn std::error::Error + Send + Sync>;
    pub type Result<T> = std::result::Result<T, Error>;
}

/// True when the connected sessions are one place's editor plus its playtest
/// servers. A Test Teleport adds a server for the destination place, which is
/// still the same test, so only editor sessions decide whether places differ.
pub fn one_editor<'a>(sessions: impl Iterator<Item = &'a crate::protocol::StudioIdentity>) -> bool {
    let all: Vec<&crate::protocol::StudioIdentity> = sessions.collect();
    let is_edit = |s: &&crate::protocol::StudioIdentity| s.context.as_deref().is_none_or(|c| c == "edit");
    let editors: std::collections::BTreeSet<i64> = all.iter().copied().filter(is_edit).map(|s| s.place_id).collect();
    match editors.len() {
        0 => all.windows(2).all(|w| w[0].place_id == w[1].place_id),
        1 => true,
        _ => false,
    }
}
