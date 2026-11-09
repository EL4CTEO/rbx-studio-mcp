//! Answers "why is this not working" without anyone having to guess.
//! Every check ends in an instruction rather than a verdict.

use crate::bridge::{http_client, probe_owner};
use crate::protocol::{CLIENT_HEADER, EMBEDDED_BUILD_ID, PROTOCOL_VERSION, StudioSession, VERSION, expected_plugin_build_id};
use serde::Deserialize;
use std::path::PathBuf;
use std::time::Duration;

#[derive(Clone, Copy, PartialEq, Eq)]
pub enum Status {
    Ok,
    Warn,
    Bad,
}

pub struct Check {
    pub status: Status,
    pub title: String,
    pub detail: String,
}

fn check(status: Status, title: impl Into<String>, detail: impl Into<String>) -> Check {
    Check { status, title: title.into(), detail: detail.into() }
}

/// Studio's per-user plugin directory, which differs per platform.
pub fn plugins_dir() -> Option<PathBuf> {
    if cfg!(windows) {
        let local = std::env::var_os("LOCALAPPDATA")
            .map(PathBuf::from)
            .unwrap_or_else(|| dirs::home_dir().unwrap_or_default().join("AppData").join("Local"));
        return Some(local.join("Roblox").join("Plugins"));
    }
    if cfg!(target_os = "macos") {
        return Some(dirs::home_dir()?.join("Documents").join("Roblox").join("Plugins"));
    }
    None
}

/// The build id stamped into an installed plugin file, if it carries one.
fn installed_build_id(contents: &str) -> Option<String> {
    let start = contents.find("Config.BUILD_ID = \"")? + "Config.BUILD_ID = \"".len();
    let len = contents[start..].find('"')?;
    Some(contents[start..start + len].to_string())
}

fn check_plugin_file() -> Check {
    let Some(dir) = plugins_dir() else {
        return check(
            Status::Warn,
            "Studio plugin",
            "Roblox Studio does not run natively on this platform, so there is no plugins folder to check.",
        );
    };
    let file = dir.join("StudioMCP.rbxmx");
    let Ok(contents) = std::fs::read_to_string(&file) else {
        return check(
            Status::Bad,
            "Studio plugin",
            format!("Not installed. No file at {}.\n  Fix: npx -y @el4cteo/rbx-studio-mcp --install-plugin", file.display()),
        );
    };
    let expected = expected_plugin_build_id();
    match installed_build_id(&contents) {
        Some(id) if expected != "unknown" && id != expected => check(
            Status::Warn,
            "Studio plugin",
            format!(
                "Installed build {id} differs from this server's {expected}.\n  Fix: npx -y @el4cteo/rbx-studio-mcp --install-plugin, then restart Studio."
            ),
        ),
        _ => check(Status::Ok, "Studio plugin", format!("Installed at {}", file.display())),
    }
}

async fn check_port(port: u16) -> Check {
    match probe_owner(port).await {
        None => check(
            Status::Warn,
            format!("Bridge on 127.0.0.1:{port}"),
            "Nothing answering, or something that is not this server.\n  That is normal if no agent is \
             running: the server starts when your MCP client launches it.\n  If an agent IS running, \
             something else holds the port. Start with --port <other> and set the same port in the Studio panel.",
        ),
        Some(owner) => {
            let drift = if owner.protocol_version == PROTOCOL_VERSION {
                String::new()
            } else {
                format!("\n  Protocol {} vs this build's {PROTOCOL_VERSION}.", owner.protocol_version)
            };
            check(Status::Ok, format!("Bridge on 127.0.0.1:{port}"), format!("Answering, owned by pid {}.{drift}", owner.pid))
        }
    }
}

#[derive(Deserialize)]
struct Sessions {
    list: Vec<StudioSession>,
}

async fn check_studios(port: u16) -> Vec<Check> {
    let sessions = async {
        http_client()
            .get(format!("http://127.0.0.1:{port}/sessions"))
            .header(CLIENT_HEADER, "doctor")
            .timeout(Duration::from_secs(5))
            .send()
            .await
            .ok()?
            .json::<Sessions>()
            .await
            .ok()
    }
    .await;
    let Some(sessions) = sessions else { return vec![] };
    if sessions.list.is_empty() {
        return vec![check(
            Status::Bad,
            "Studio sessions",
            "The bridge is up but no Studio is connected.\n  Open Studio. If it is already open, click the \
             Studio MCP toolbar button and check the console panel; use its reconnect button.\n  If Studio \
             asked for permission to reach 127.0.0.1, it must be allowed.",
        )];
    }
    let built = expected_plugin_build_id();
    sessions
        .list
        .into_iter()
        .map(|s| {
            let stale = built != "unknown" && s.identity.build_id != built;
            check(
                if stale { Status::Warn } else { Status::Ok },
                format!("Studio: {}", s.identity.place_name),
                if stale {
                    format!(
                        "Plugin build {} does not match this package's {built}.\n  Fix: npx -y @el4cteo/rbx-studio-mcp --install-plugin, then restart Studio.",
                        s.identity.build_id
                    )
                } else {
                    format!(
                        "{}, over {}, plugin {}",
                        s.identity.context.as_deref().unwrap_or("edit"),
                        s.identity.transport,
                        s.identity.plugin_version
                    )
                },
            )
        })
        .collect()
}

pub async fn collect_checks(port: u16) -> Vec<Check> {
    let mut checks = vec![check(
        Status::Ok,
        "Server",
        format!("rbx-studio-mcp {VERSION} (native), plugin build {}", EMBEDDED_BUILD_ID.trim()),
    )];
    checks.push(check_plugin_file());
    checks.push(check_port(port).await);
    checks.extend(check_studios(port).await);
    checks
}

pub async fn run(port: u16) -> i32 {
    let checks = collect_checks(port).await;
    let mark = |s: Status| match s {
        Status::Ok => "PASS",
        Status::Warn => "WARN",
        Status::Bad => "FAIL",
    };
    let lines: Vec<String> = checks.iter().map(|c| format!("[{}] {}\n  {}", mark(c.status), c.title, c.detail)).collect();
    let bad = checks.iter().filter(|c| c.status == Status::Bad).count();
    let warn = checks.iter().filter(|c| c.status == Status::Warn).count();
    println!(
        "{}\n\n{} passed, {warn} warning(s), {bad} failure(s)",
        lines.join("\n\n"),
        checks.len() - bad - warn
    );
    if bad > 0 { 1 } else { 0 }
}

/// Writes the embedded plugin into Studio's plugins folder, atomically.
pub fn install_plugin() -> Result<PathBuf, String> {
    if crate::protocol::EMBEDDED_PLUGIN.is_empty() {
        return Err("This build has no embedded plugin.".into());
    }
    let dir = plugins_dir().ok_or(
        "Roblox Studio does not run natively on this platform; copy StudioMCP.rbxmx into your plugins folder by hand.",
    )?;
    std::fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
    let destination = dir.join("StudioMCP.rbxmx");
    let staged = dir.join("StudioMCP.rbxmx.incoming");
    // Renamed over the target so Studio's watcher never reads half a file.
    std::fs::write(&staged, crate::protocol::EMBEDDED_PLUGIN)
        .and_then(|_| std::fs::rename(&staged, &destination))
        .map_err(|e| {
            let _ = std::fs::remove_file(&staged);
            e.to_string()
        })?;
    Ok(destination)
}
