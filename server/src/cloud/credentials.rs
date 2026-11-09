//! Where the Open Cloud key lives. Treated as a password: never returned,
//! logged or put in a tool result. Environment wins over the file.

use serde::{Deserialize, Serialize};
use std::path::PathBuf;
use std::sync::LazyLock;
use std::time::Duration;

pub static DIRECTORY: LazyLock<PathBuf> =
    LazyLock::new(|| dirs::home_dir().unwrap_or_default().join(".rbx-studio-mcp"));
pub static FILE: LazyLock<PathBuf> = LazyLock::new(|| DIRECTORY.join("credentials.json"));

pub fn path_display() -> String {
    FILE.to_string_lossy().into_owned()
}

#[derive(Clone, Debug)]
pub struct Credentials {
    pub api_key: String,
    pub creator_id: String,
    /// "userId" or "groupId".
    pub creator_field: &'static str,
    pub universe_id: Option<String>,
    pub place_id: Option<String>,
    #[allow(dead_code)] // reported by `cloud status` through CredentialStatus
    pub source: &'static str,
}

#[derive(Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct Stored {
    #[serde(skip_serializing_if = "Option::is_none")]
    api_key: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    user_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    group_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    universe_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    place_id: Option<String>,
}

pub struct CredentialStatus {
    pub has_key: bool,
    pub key_hint: Option<String>,
    pub creator_id: Option<String>,
    pub creator_field: Option<&'static str>,
    pub universe_id: Option<String>,
    pub place_id: Option<String>,
    pub source: Option<&'static str>,
}

fn env(key: &str) -> Option<String> {
    std::env::var(key).ok().map(|v| v.trim().to_string()).filter(|v| !v.is_empty())
}

fn nonempty(v: Option<String>) -> Option<String> {
    v.filter(|s| !s.is_empty())
}

async fn read_stored() -> Stored {
    match tokio::fs::read(&*FILE).await {
        Ok(bytes) => serde_json::from_slice(&bytes).unwrap_or_default(),
        Err(_) => Stored::default(),
    }
}

async fn write_stored(next: &Stored) -> std::io::Result<()> {
    tokio::fs::create_dir_all(&*DIRECTORY).await?;
    let staging = FILE.with_extension(format!("json.{}.tmp", std::process::id()));
    let mut body = serde_json::to_vec_pretty(next).unwrap_or_default();
    body.push(b'\n');
    tokio::fs::write(&staging, body).await?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = tokio::fs::set_permissions(&*DIRECTORY, std::fs::Permissions::from_mode(0o700)).await;
        let _ = tokio::fs::set_permissions(&staging, std::fs::Permissions::from_mode(0o600)).await;
    }
    tokio::fs::rename(&staging, &*FILE).await
}

/// The credentials to upload with, or None when the setup is incomplete.
pub async fn load() -> Option<Credentials> {
    let stored = read_stored().await;
    let env_key = env("ROBLOX_API_KEY");
    let universe_id = env("ROBLOX_UNIVERSE_ID").or(nonempty(stored.universe_id));
    let place_id = env("ROBLOX_PLACE_ID").or(nonempty(stored.place_id));
    let from_env = env_key.is_some();
    let api_key = env_key.or(nonempty(stored.api_key))?;
    let (group, user) = if from_env {
        (env("ROBLOX_GROUP_ID"), env("ROBLOX_USER_ID"))
    } else {
        (nonempty(stored.group_id), nonempty(stored.user_id))
    };
    let (creator_id, creator_field) = match (group, user) {
        (Some(g), _) => (g, "groupId"),
        (None, Some(u)) => (u, "userId"),
        _ => return None,
    };
    Some(Credentials {
        api_key,
        creator_id,
        creator_field,
        universe_id,
        place_id,
        source: if from_env { "environment" } else { "file" },
    })
}

pub async fn status() -> CredentialStatus {
    let stored = read_stored().await;
    let env_key = env("ROBLOX_API_KEY");
    let from_env = env_key.is_some();
    let stored_key = nonempty(stored.api_key);
    let source = if from_env { Some("environment") } else if stored_key.is_some() { Some("file") } else { None };
    let api_key = env_key.or(stored_key);
    let (group, user) = if from_env {
        (env("ROBLOX_GROUP_ID"), env("ROBLOX_USER_ID"))
    } else {
        (nonempty(stored.group_id), nonempty(stored.user_id))
    };
    CredentialStatus {
        has_key: api_key.is_some(),
        key_hint: api_key.as_ref().map(|k| last_chars(k, 4)),
        creator_field: if group.is_some() { Some("groupId") } else if user.is_some() { Some("userId") } else { None },
        creator_id: group.or(user),
        universe_id: env("ROBLOX_UNIVERSE_ID").or(nonempty(stored.universe_id)),
        place_id: env("ROBLOX_PLACE_ID").or(nonempty(stored.place_id)),
        source,
    }
}

pub fn last_chars(s: &str, n: usize) -> String {
    let count = s.chars().count();
    s.chars().skip(count.saturating_sub(n)).collect()
}

pub async fn save_target(field: &str, id: &str) -> std::io::Result<()> {
    let mut stored = read_stored().await;
    match field {
        "universeId" => stored.universe_id = Some(id.into()),
        _ => stored.place_id = Some(id.into()),
    }
    write_stored(&stored).await
}

pub async fn save_api_key(key: &str) -> std::io::Result<()> {
    let mut stored = read_stored().await;
    stored.api_key = Some(key.into());
    write_stored(&stored).await
}

/// Sets the creator, clearing the other kind: one creator per upload.
pub async fn save_creator(field: &str, id: &str) -> std::io::Result<()> {
    let mut stored = read_stored().await;
    stored.user_id = None;
    stored.group_id = None;
    match field {
        "groupId" => stored.group_id = Some(id.into()),
        _ => stored.user_id = Some(id.into()),
    }
    write_stored(&stored).await
}

pub async fn forget() -> bool {
    tokio::fs::remove_file(&*FILE).await.is_ok()
}

/// Asks Roblox whether the key works, without uploading anything.
pub async fn test(api_key: &str) -> (bool, String) {
    let response = super::client()
        .get("https://apis.roblox.com/assets/v1/operations/0")
        .header("x-api-key", api_key)
        .timeout(Duration::from_secs(15))
        .send()
        .await;
    let response = match response {
        Ok(r) => r,
        Err(e) => return (false, format!("could not reach Roblox: {e}")),
    };
    match response.status().as_u16() {
        401 => (false, "Roblox rejected the key (401)".into()),
        403 => (
            false,
            "Roblox refused the key (403) — usually a missing `assets` permission, or your IP is not in the key's allowed list".into(),
        ),
        429 => (true, "the key works (rate limited right now)".into()),
        _ => (true, "the key works".into()),
    }
}

