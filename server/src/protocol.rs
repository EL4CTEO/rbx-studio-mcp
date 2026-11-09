//! Wire protocol shared with the Studio plugin, plus the plugin build check.
//!
//! The server pushes `Command` frames down an SSE stream (or hands them out via
//! long-poll) and the plugin POSTs a matching `CommandResult` to /result.

use parking_lot::Mutex;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::HashSet;
use std::path::PathBuf;
use std::sync::LazyLock;
use std::time::{Duration, Instant};

pub const PROTOCOL_VERSION: i64 = 1;

/// Header every plugin request must carry; blocks DNS-rebinding from browsers.
pub const CLIENT_HEADER: &str = "x-roblox-studio-mcp";

/// Names a proxying peer, so its chosen Studio stays its own.
pub const PEER_HEADER: &str = "x-roblox-studio-mcp-peer";

pub const DEFAULT_PORT: u16 = 44755;

pub const VERSION: &str = env!("RBX_PACKAGE_VERSION");

#[derive(Debug, Clone, Serialize)]
pub struct Command {
    pub id: String,
    #[serde(rename = "timeoutMs")]
    pub timeout_ms: u64,
    pub op: String,
    pub params: Value,
}

#[derive(Debug, Clone, Deserialize)]
pub struct CommandError {
    #[serde(default)]
    pub code: String,
    #[serde(default)]
    pub message: String,
    pub hint: Option<String>,
}

#[derive(Debug, Deserialize)]
pub struct CommandResult {
    pub id: String,
    #[serde(default)]
    pub ok: bool,
    pub data: Option<Value>,
    pub error: Option<CommandError>,
}

/// What a plugin declares when it connects.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct StudioIdentity {
    pub studio_id: String,
    pub place_name: String,
    pub place_id: i64,
    pub plugin_version: String,
    pub build_id: String,
    pub protocol_version: i64,
    pub transport: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub context: Option<String>,
}

/// A listed session: identity plus timestamps (ms since epoch).
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct StudioSession {
    #[serde(flatten)]
    pub identity: StudioIdentity,
    pub connected_at: u64,
    pub last_seen_at: u64,
}

/// One MCP client as the console shows it.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ClientView {
    pub name: String,
    pub version: String,
    pub pid: u32,
    pub connected_at: u64,
}

pub fn now_ms() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}

/// Parses a handshake body: untrusted, so every field is typed and defaulted.
pub fn parse_identity(body: &[u8], transport: &str) -> Result<StudioIdentity, String> {
    let raw: Value = serde_json::from_slice(body).map_err(|e| e.to_string())?;
    let studio_id = raw
        .get("studioId")
        .and_then(Value::as_str)
        .filter(|s| !s.is_empty())
        .ok_or("handshake is missing studioId")?;
    let text = |key: &str, fallback: &str| -> String {
        raw.get(key).and_then(Value::as_str).filter(|s| !s.is_empty()).unwrap_or(fallback).to_string()
    };
    Ok(StudioIdentity {
        studio_id: studio_id.to_string(),
        place_name: text("placeName", "Unnamed place"),
        place_id: raw.get("placeId").and_then(Value::as_f64).filter(|f| f.is_finite()).map(|f| f as i64).unwrap_or(0),
        plugin_version: text("pluginVersion", "unknown"),
        build_id: text("buildId", "unknown"),
        protocol_version: raw.get("protocolVersion").and_then(Value::as_i64).unwrap_or(1),
        transport: match raw.get("transport").and_then(Value::as_str) {
            Some(t @ ("sse" | "poll")) => t.to_string(),
            _ => transport.to_string(),
        },
        context: raw.get("context").and_then(Value::as_str).map(str::to_string),
    })
}

pub fn protocol_mismatch_warning(reported: i64) -> Option<String> {
    if reported == PROTOCOL_VERSION {
        return None;
    }
    Some(if reported < PROTOCOL_VERSION {
        format!(
            "The connected Studio plugin speaks an older wire protocol (v{reported}) than this server \
             (v{PROTOCOL_VERSION}). Studio only reloads a plugin when its window next takes focus — click \
             into Studio, then retry. If that does not clear it, run `rbx-studio-mcp --install-plugin` and restart Studio."
        )
    } else {
        format!(
            "The connected Studio plugin speaks a newer wire protocol (v{reported}) than this server \
             (v{PROTOCOL_VERSION}) understands. Update the server: reinstall with \
             `npx -y @el4cteo/rbx-studio-mcp` (npx always fetches the latest)."
        )
    })
}

// --- plugin build fingerprint ---------------------------------------------

/// The plugin this binary embeds, built from `plugin/src` at compile time.
pub const EMBEDDED_PLUGIN: &[u8] = include_bytes!(concat!(env!("OUT_DIR"), "/StudioMCP.rbxmx"));
pub const EMBEDDED_BUILD_ID: &str = include_str!(concat!(env!("OUT_DIR"), "/plugin-build-id.txt"));

/// A source checkout the plugin can be rebuilt from, when this binary runs from one.
///
/// Developers edit `plugin/src` and reinstall the plugin mid-session; hashing the
/// live sources keeps the staleness check honest without a server rebuild.
/// Installed binaries have no checkout and use the embedded id.
fn live_source_dir() -> Option<PathBuf> {
    if let Ok(dir) = std::env::var("RBX_STUDIO_MCP_PLUGIN_SRC") {
        return Some(PathBuf::from(dir));
    }
    let exe = std::env::current_exe().ok()?;
    // server/target/{debug,release}/rbx-studio-mcp -> repo root
    let root = exe.parent()?.parent()?.parent()?.parent()?;
    let src = root.join("plugin").join("src");
    src.is_dir().then_some(src)
}

struct BuildCache {
    key: String,
    id: String,
    checked: Option<Instant>,
}

static BUILD: LazyLock<Mutex<BuildCache>> =
    LazyLock::new(|| Mutex::new(BuildCache { key: String::new(), id: String::new(), checked: None }));
static LIVE_DIR: LazyLock<Option<PathBuf>> = LazyLock::new(live_source_dir);

fn collect(dir: &std::path::Path, root: &std::path::Path, into: &mut Vec<(String, PathBuf)>) -> std::io::Result<()> {
    for entry in std::fs::read_dir(dir)? {
        let path = entry?.path();
        if path.is_dir() {
            collect(&path, root, into)?;
        } else if path.extension().is_some_and(|e| e == "luau") {
            let rel = path.strip_prefix(root).unwrap_or(&path).to_string_lossy().replace('\\', "/");
            into.push((rel, path));
        }
    }
    Ok(())
}

fn hash_sources(dir: &std::path::Path, cache: &mut BuildCache) -> std::io::Result<()> {
    use sha2::{Digest, Sha256};
    let mut files = Vec::new();
    collect(dir, dir, &mut files)?;
    files.sort_by(|a, b| a.0.cmp(&b.0));
    let mut key = String::new();
    for (name, path) in &files {
        let mtime = std::fs::metadata(path)?.modified()?.duration_since(std::time::UNIX_EPOCH).unwrap_or_default();
        key.push_str(&format!("{name}:{}|", mtime.as_nanos()));
    }
    if key == cache.key {
        return Ok(());
    }
    let mut hash = Sha256::new();
    for (name, path) in &files {
        hash.update(name.as_bytes());
        hash.update(b"\n");
        hash.update(std::fs::read_to_string(path)?.replace("\r\n", "\n").as_bytes());
        hash.update(b"\n");
    }
    let digest = hash.finalize();
    cache.id = digest.iter().take(6).map(|b| format!("{b:02x}")).collect();
    cache.key = key;
    Ok(())
}

/// Fingerprint of the plugin sources this server expects.
pub fn expected_plugin_build_id() -> String {
    let Some(dir) = LIVE_DIR.as_ref() else {
        return EMBEDDED_BUILD_ID.trim().to_string();
    };
    let mut cache = BUILD.lock();
    if cache.checked.is_some_and(|t| t.elapsed() < Duration::from_secs(2)) {
        return cache.id.clone();
    }
    cache.checked = Some(Instant::now());
    if hash_sources(dir, &mut cache).is_err() {
        cache.key = "missing".into();
        cache.id = "unknown".into();
    }
    cache.id.clone()
}

pub fn plugin_staleness_warning(reported: Option<&str>) -> Option<String> {
    let expected = expected_plugin_build_id();
    let reported = reported.filter(|r| !r.is_empty())?;
    if expected == "unknown" || reported == expected {
        return None;
    }
    if reported == "dev" {
        return Some(
            "The connected plugin was loaded from source rather than a build, so its \
             version cannot be verified against this server."
                .into(),
        );
    }
    Some(format!(
        "The connected Studio plugin was built from different sources than this server \
         (plugin {reported}, server {expected}). Studio only reloads a plugin when its window \
         next takes focus — click into Studio, then retry. If that does not clear it, run \
         `rbx-studio-mcp --install-plugin` and restart Studio."
    ))
}

static ANNOUNCED: LazyLock<Mutex<HashSet<String>>> = LazyLock::new(Default::default);

/// The staleness warning in full once per build id, then as a short tag.
pub fn plugin_staleness_notice(reported: Option<&str>) -> Option<String> {
    let warning = plugin_staleness_warning(reported)?;
    let key = reported.unwrap_or("unknown").to_string();
    let mut announced = ANNOUNCED.lock();
    if announced.contains(&key) {
        return Some(format!("Plugin is still the stale build {key} (already explained in this session)."));
    }
    announced.insert(key);
    Some(warning)
}
