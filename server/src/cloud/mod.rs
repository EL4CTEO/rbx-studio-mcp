//! One HTTP client for every Open Cloud call.
//!
//! Roblox answers a missing scope, a stale IP allowlist and a revoked key with
//! the same 403; the scope each call needed is named in the error so the fix
//! is one sentence.

pub mod assets;
pub mod credentials;
pub mod data;
pub mod live;
pub mod luau;
pub mod ops;
pub mod permissions;

use crate::bridge::StudioBridge;
use crate::errors::{Result, ToolError};
use credentials::Credentials;
use parking_lot::Mutex;
use serde_json::{Value, json};
use std::collections::HashMap;
use std::sync::{Arc, LazyLock};
use std::time::Duration;

const BASE: &str = "https://apis.roblox.com";
const MAX_RETRIES: u32 = 2;
const MAX_RETRY_WAIT_MS: u64 = 8_000;

pub fn client() -> &'static reqwest::Client {
    static CLIENT: LazyLock<reqwest::Client> = LazyLock::new(|| {
        reqwest::Client::builder()
            .user_agent(concat!("rbx-studio-mcp/", env!("RBX_PACKAGE_VERSION")))
            .build()
            .expect("http client")
    });
    &CLIENT
}

pub enum Body {
    None,
    Json(Value),
    Raw { bytes: Vec<u8>, content_type: String },
    /// Rebuilt per attempt: a multipart form is consumed by sending it.
    Form(Arc<dyn Fn() -> reqwest::multipart::Form + Send + Sync>),
}

pub struct Call {
    pub method: reqwest::Method,
    pub path: String,
    pub query: Vec<(String, String)>,
    pub body: Body,
    pub scope: &'static str,
    pub timeout_ms: u64,
}

impl Call {
    pub fn get(path: impl Into<String>, scope: &'static str) -> Self {
        Self { method: reqwest::Method::GET, path: path.into(), query: vec![], body: Body::None, scope, timeout_ms: 60_000 }
    }
    pub fn method(mut self, method: reqwest::Method) -> Self {
        self.method = method;
        self
    }
    pub fn post(path: impl Into<String>, scope: &'static str) -> Self {
        Self::get(path, scope).method(reqwest::Method::POST)
    }
    pub fn patch(path: impl Into<String>, scope: &'static str) -> Self {
        Self::get(path, scope).method(reqwest::Method::PATCH)
    }
    pub fn delete(path: impl Into<String>, scope: &'static str) -> Self {
        Self::get(path, scope).method(reqwest::Method::DELETE)
    }
    pub fn query(mut self, key: &str, value: impl ToString) -> Self {
        self.query.push((key.into(), value.to_string()));
        self
    }
    pub fn query_opt(self, key: &str, value: Option<impl ToString>) -> Self {
        match value {
            Some(v) => self.query(key, v),
            None => self,
        }
    }
    pub fn json(mut self, body: Value) -> Self {
        self.body = Body::Json(body);
        self
    }
    pub fn raw(mut self, bytes: Vec<u8>, content_type: &str) -> Self {
        self.body = Body::Raw { bytes, content_type: content_type.into() };
        self
    }
    pub fn form(mut self, build: impl Fn() -> reqwest::multipart::Form + Send + Sync + 'static) -> Self {
        self.body = Body::Form(Arc::new(build));
        self
    }
    pub fn timeout(mut self, ms: u64) -> Self {
        self.timeout_ms = ms;
        self
    }
}

pub fn enc(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for b in s.bytes() {
        if b.is_ascii_alphanumeric() || b"-_.!~*'()".contains(&b) {
            out.push(b as char);
        } else {
            out.push_str(&format!("%{b:02X}"));
        }
    }
    out
}

/// The credentials, or an error explaining exactly what is missing.
pub async fn require_credentials() -> Result<Credentials> {
    credentials::load().await.ok_or_else(|| {
        ToolError::hint(
            "NO_CREDENTIALS",
            "No Open Cloud API key is set up, so this cannot run.",
            "The user sets it once by typing `cloud` in the Studio panel — it walks through \
             creating the key and storing it safely. Never ask them to paste a key into this conversation.",
        )
    })
}

/// Turns a place id into its universe. Unauthenticated and best effort.
pub async fn universe_for_place(place_id: &str) -> Option<String> {
    let response = client()
        .get(format!("{BASE}/universes/v1/places/{}/universe", enc(place_id)))
        .timeout(Duration::from_secs(10))
        .send()
        .await
        .ok()?;
    if !response.status().is_success() {
        return None;
    }
    let body: Value = response.json().await.ok()?;
    match body.get("universeId")? {
        Value::Number(n) => Some(n.to_string()),
        Value::String(s) => Some(s.clone()),
        _ => None,
    }
}

pub async fn require_universe(explicit: Option<&str>) -> Result<String> {
    if let Some(id) = explicit.map(str::trim).filter(|s| !s.is_empty()) {
        return Ok(id.into());
    }
    let found = credentials::load().await;
    if let Some(u) = found.as_ref().and_then(|c| c.universe_id.clone()) {
        return Ok(u);
    }
    // Fall back to stored ids even without a full credential set.
    let status = credentials::status().await;
    if let Some(u) = status.universe_id {
        return Ok(u);
    }
    if let Some(place) = found.and_then(|c| c.place_id).or(status.place_id)
        && let Some(derived) = universe_for_place(&place).await {
            return Ok(derived);
        }
    Err(ToolError::hint(
        "NO_UNIVERSE",
        "This needs a universe id and none is set.",
        "Ask the user to run `cloud universe <id>` in the Studio panel. They find it on the \
         Creator Dashboard: hover the game's thumbnail, click the ⋯ button, Copy Universe ID. \
         Or pass `universeId` to this call.",
    ))
}

pub async fn require_place(explicit: Option<&str>) -> Result<String> {
    if let Some(id) = explicit.map(str::trim).filter(|s| !s.is_empty()) {
        return Ok(id.into());
    }
    if let Some(p) = credentials::status().await.place_id {
        return Ok(p);
    }
    Err(ToolError::hint(
        "NO_PLACE",
        "This needs a place id and none is set.",
        "Ask the user to run `cloud place <id>` in the Studio panel, or pass `placeId`. \
         `studio_status` reports the placeId of the open place.",
    ))
}

static UNIVERSE_CACHE: LazyLock<Mutex<HashMap<String, String>>> = LazyLock::new(Default::default);

async fn universe_of(place: &str) -> Option<String> {
    if let Some(known) = UNIVERSE_CACHE.lock().get(place) {
        return Some(known.clone());
    }
    let found = universe_for_place(place).await?;
    UNIVERSE_CACHE.lock().insert(place.into(), found.clone());
    Some(found)
}

pub struct Target<'a> {
    pub universe_id: Option<&'a str>,
    pub place_id: Option<&'a str>,
    pub explicit: bool,
    pub studio_id: Option<&'a str>,
}

/// Refuses to act on a different game from the one open in Studio.
pub async fn assert_targets_open_place(bridge: &Arc<StudioBridge>, target: Target<'_>) -> Result<()> {
    if target.explicit {
        return Ok(());
    }
    let Ok(status) = bridge.call("studio.status", json!({}), target.studio_id, Some(5_000.0)).await else {
        return Ok(());
    };
    let open = match status.get("placeId").and_then(Value::as_f64) {
        Some(id) if id != 0.0 => (id as i64).to_string(),
        _ => return Ok(()),
    };
    if let Some(place) = target.place_id
        && place != open {
            return Err(ToolError::hint(
                "WRONG_PLACE",
                format!("This would act on place {place}, but Studio has {open} open."),
                format!(
                    "The stored `cloud place` is from another session. Run `cloud place {open}` in the \
                     Studio panel, or pass `placeId` to say you meant the other game on purpose."
                ),
            ));
        }
    if let Some(universe) = target.universe_id
        && let Some(open_universe) = universe_of(&open).await
            && open_universe != universe {
                return Err(ToolError::hint(
                    "WRONG_PLACE",
                    format!("This would act on universe {universe}, but Studio has a place from universe {open_universe} open."),
                    format!(
                        "Run `cloud place {open}` in the Studio panel to point at the open game, or pass \
                         `universeId` to say you meant the other one."
                    ),
                ));
            }
    Ok(())
}

fn detail_of(body: &str) -> String {
    let fallback = || body.chars().take(300).collect::<String>();
    let Ok(parsed) = serde_json::from_str::<Value>(body) else { return fallback() };
    if let Some(e) = parsed.get("error").and_then(Value::as_str) {
        return e.into();
    }
    parsed
        .get("message")
        .and_then(Value::as_str)
        .or_else(|| parsed.pointer("/error/message").and_then(Value::as_str))
        .or_else(|| parsed.pointer("/errors/0/message").and_then(Value::as_str))
        .map(str::to_string)
        .unwrap_or_else(fallback)
}

fn failure(status: u16, body: &str, scope: &str, retry_after: Option<&str>) -> ToolError {
    let detail = detail_of(body);
    match status {
        401 => ToolError::hint(
            "BAD_KEY",
            format!("Roblox rejected the API key (401): {detail}"),
            "The key is wrong or was revoked. `cloud test` in the Studio panel re-checks it.",
        ),
        403 => ToolError::hint(
            "FORBIDDEN",
            format!("Roblox refused the key (403): {detail}"),
            format!(
                "This call needs the `{scope}` permission. Three things cause a 403 and the message names \
                 none of them: the key is missing that scope, the key's IP allowlist no longer includes \
                 this machine, or the key was not granted access to this experience. Check them in that \
                 order on the Creator Dashboard."
            ),
        ),
        404 => ToolError::hint(
            "NOT_FOUND",
            format!("Roblox has no such thing (404): {detail}"),
            "Check the universe id, place id, and any data store or key name — Open Cloud does not \
             create parents implicitly.",
        ),
        429 => {
            let seconds = retry_after.and_then(|r| r.parse::<f64>().ok()).filter(|s| s.is_finite() && *s > 0.0);
            ToolError::hint(
                "RATE_LIMITED",
                format!("Rate limited by Roblox: {detail}"),
                match seconds {
                    Some(s) => format!("Roblox asks to wait {}s before retrying.", s.ceil() as u64),
                    None => "Wait and retry.".into(),
                },
            )
        }
        400 => ToolError::new("BAD_REQUEST", format!("Roblox refused the request (400): {detail}")),
        _ => ToolError::new("CLOUD_ERROR", format!("Roblox returned {status}: {detail}")),
    }
}

fn retry_delay_ms(cause: &ToolError, method: &reqwest::Method, attempt: u32) -> Option<u64> {
    if cause.code == "RATE_LIMITED" && !cause.message.to_lowercase().contains("budget") {
        let asked = cause
            .hint
            .as_deref()
            .and_then(|h| h.split("wait ").nth(1))
            .and_then(|r| r.split('s').next())
            .and_then(|n| n.parse::<u64>().ok());
        let wait = asked.map(|a| a * 1000).unwrap_or(1_000 * 2u64.pow(attempt));
        return (wait <= MAX_RETRY_WAIT_MS).then_some(wait);
    }
    if method == reqwest::Method::GET
        && cause.code == "CLOUD_ERROR"
        && ["Roblox returned 502", "Roblox returned 503", "Roblox returned 504"].iter().any(|p| cause.message.starts_with(p))
    {
        return Some(500 * 2u64.pow(attempt));
    }
    None
}

/// One Open Cloud request, with short retries for 429 and read-only 5xx.
pub async fn call(credentials: &Credentials, options: &Call) -> Result<Value> {
    // The user's per-game choice, before anything leaves this machine.
    let universe = permissions::universe_in(&options.path, &options.query, credentials.universe_id.as_deref());
    permissions::check(options.scope, universe.as_deref()).await?;
    let mut attempt = 0;
    loop {
        match call_once(credentials, options).await {
            Ok(v) => return Ok(v),
            Err(e) => {
                let wait = (attempt < MAX_RETRIES).then(|| retry_delay_ms(&e, &options.method, attempt)).flatten();
                match wait {
                    Some(ms) => tokio::time::sleep(Duration::from_millis(ms)).await,
                    None => return Err(e),
                }
            }
        }
        attempt += 1;
    }
}

async fn call_once(credentials: &Credentials, options: &Call) -> Result<Value> {
    let url = if options.path.starts_with("http") { options.path.clone() } else { format!("{BASE}{}", options.path) };
    let mut request = client()
        .request(options.method.clone(), url)
        .header("x-api-key", &credentials.api_key)
        .timeout(Duration::from_millis(options.timeout_ms));
    if !options.query.is_empty() {
        request = request.query(&options.query);
    }
    request = match &options.body {
        Body::None => request,
        Body::Json(v) => request.header("content-type", "application/json").body(serde_json::to_vec(v)?),
        Body::Raw { bytes, content_type } => request.header("content-type", content_type).body(bytes.clone()),
        Body::Form(build) => request.multipart(build()),
    };
    let response = request.send().await.map_err(unreachable)?;
    let status = response.status();
    let retry_after = response.headers().get("retry-after").and_then(|v| v.to_str().ok()).map(str::to_string);
    let text = response.text().await.map_err(unreachable)?;
    if !status.is_success() {
        return Err(failure(status.as_u16(), &text, options.scope, retry_after.as_deref()));
    }
    if text.trim().is_empty() {
        return Ok(json!({}));
    }
    Ok(serde_json::from_str(&text).unwrap_or_else(|_| json!({ "raw": text })))
}

fn unreachable(e: reqwest::Error) -> ToolError {
    if e.is_timeout() {
        ToolError::new("CLOUD_UNREACHABLE", "Roblox did not answer in time.")
    } else {
        ToolError::new("CLOUD_UNREACHABLE", format!("Could not reach Roblox: {e}"))
    }
}

pub struct Paged {
    pub items: Vec<Value>,
    pub truncated: bool,
}

/// Walks a paged collection, returning at most `limit` items.
pub async fn paged(credentials: &Credentials, mut options: Call, field: &str, limit: usize) -> Result<Paged> {
    let mut items: Vec<Value> = Vec::new();
    let mut token = options.query.iter().find(|(k, _)| k == "pageToken").map(|(_, v)| v.clone());
    options.query.retain(|(k, _)| k != "pageToken" && k != "maxPageSize");
    let base_query = options.query.clone();
    loop {
        options.query = base_query.clone();
        options.query.push(("maxPageSize".into(), (limit - items.len()).min(100).to_string()));
        if let Some(t) = &token {
            options.query.push(("pageToken".into(), t.clone()));
        }
        let page = call(credentials, &options).await?;
        let batch = page.get(field).and_then(Value::as_array).cloned().unwrap_or_default();
        let empty = batch.is_empty();
        items.extend(batch);
        token = page.get("nextPageToken").and_then(Value::as_str).filter(|t| !t.is_empty()).map(str::to_string);
        if token.is_none() || items.len() >= limit || empty {
            items.truncate(limit);
            return Ok(Paged { items, truncated: token.is_some() });
        }
    }
}
