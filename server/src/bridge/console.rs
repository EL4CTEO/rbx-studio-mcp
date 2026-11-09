//! The half of the console panel's command line that Studio cannot answer:
//! doctor, studio targeting, agents, and Open Cloud credentials. Answers come
//! back as console rows so the panel prints them like everything else.

use super::harness::{self, Harness, Line, Run};
use super::rpc::Bridge;
use crate::cloud::{self, credentials};
use crate::doctor::{self, Status};
use parking_lot::Mutex;
use serde_json::{Value, json};
use std::collections::HashMap;
use std::sync::{Arc, LazyLock};

pub struct ConsoleRequest {
    pub studio_id: String,
    pub command: String,
    pub args: Vec<String>,
    pub line: String,
}

/// One agent per Studio, because the panel shows one log.
#[derive(Default)]
struct AgentState {
    harness_id: Option<String>,
    session: Option<String>,
    active: Option<Arc<Run>>,
}

static AGENTS: LazyLock<Mutex<HashMap<String, AgentState>>> = LazyLock::new(Default::default);

pub fn agent_running(studio_id: &str) -> bool {
    AGENTS.lock().get(studio_id).is_some_and(|s| s.active.is_some())
}

fn render_checks(checks: Vec<doctor::Check>) -> Vec<Line> {
    let mut lines: Vec<Line> = checks
        .iter()
        .map(|c| {
            let level = match c.status {
                Status::Ok => "ok",
                Status::Warn => "warn",
                Status::Bad => "error",
            };
            Line::with(level, c.title.clone(), c.detail.split('\n').map(str::trim).collect::<Vec<_>>().join(" "))
        })
        .collect();
    let bad = checks.iter().filter(|c| c.status == Status::Bad).count();
    let warn = checks.iter().filter(|c| c.status == Status::Warn).count();
    lines.push(Line::new(
        if bad > 0 { "error" } else if warn > 0 { "warn" } else { "ok" },
        format!("{} passed, {warn} warning, {bad} failure", checks.len() - bad - warn),
    ));
    lines
}

fn render_studios(bridge: &Bridge, asking: &str) -> Vec<Line> {
    let sessions = bridge.list();
    if sessions.is_empty() {
        return vec![Line::new("dim", "no Studio is connected")];
    }
    let active = bridge.active_id("panel");
    let mut lines = vec![Line::new(
        "info",
        format!("{} Studio{} on this bridge", sessions.len(), if sessions.len() == 1 { "" } else { "s" }),
    )];
    for (i, s) in sessions.iter().enumerate() {
        let id = &s.identity;
        let here = if id.studio_id == asking { " (this panel)" } else { "" };
        lines.push(Line::with(
            if Some(&id.studio_id) == active.as_ref() { "ok" } else { "dim" },
            format!("  {}. {}{here}", i + 1, id.place_name),
            format!(
                "{}  {}  {}",
                id.context.as_deref().unwrap_or("edit"),
                id.transport,
                id.studio_id.chars().take(8).collect::<String>()
            ),
        ));
    }
    lines
}

fn resolve_studio(bridge: &Bridge, token: &str) -> Option<String> {
    let sessions = bridge.list();
    if let Ok(index) = token.parse::<usize>()
        && index >= 1 && index <= sessions.len() {
            return Some(sessions[index - 1].identity.studio_id.clone());
        }
    sessions.into_iter().find(|s| s.identity.studio_id.starts_with(token)).map(|s| s.identity.studio_id)
}

fn attached<'a>(bridge: &Bridge, available: &[&'a Harness]) -> Vec<&'a Harness> {
    let clients = bridge.client_list();
    available.iter().copied().filter(|h| clients.iter().any(|c| harness::matches_client(h, &c.name))).collect()
}

/// Which agent a prompt goes to, or None when several are attached and it cannot tell.
fn preferred(harness_id: Option<&str>, bridge: &Bridge, available: &[&'static Harness]) -> Option<&'static Harness> {
    if let Some(id) = harness_id {
        return harness::find(id);
    }
    if available.len() == 1 {
        return Some(available[0]);
    }
    let matched = attached(bridge, available);
    match matched.len() {
        1 => Some(matched[0]),
        0 => available.first().copied(),
        _ => None,
    }
}

fn render_agents(harness_id: Option<&str>, bridge: &Bridge) -> Vec<Line> {
    let available = harness::installed();
    if available.is_empty() {
        return vec![Line::with(
            "warn",
            "no coding agent found on PATH",
            format!(
                "Install any of {} supported agents (claude, codex, opencode, gemini, cursor-agent, kimi, cline, \
                 kilo, qoder...) and it will be picked up automatically. Commands still work without one.",
                harness::known().len()
            ),
        )];
    }
    let wanted = preferred(harness_id, bridge, &available);
    let connected = attached(bridge, &available);
    let mut lines = vec![Line::new(
        "info",
        format!("{} agent{} available", available.len(), if available.len() == 1 { "" } else { "s" }),
    )];
    for h in &available {
        let mut marks = vec![];
        if connected.iter().any(|c| c.id == h.id) {
            marks.push("connected");
        }
        let is_wanted = wanted.is_some_and(|w| w.id == h.id);
        if is_wanted {
            marks.push(if harness_id.is_none() { "would answer" } else { "in use" });
        }
        lines.push(Line::with(
            if is_wanted { "ok" } else { "dim" },
            format!("  {}", h.id),
            if marks.is_empty() { h.label.to_string() } else { format!("{}  ({})", h.label, marks.join(", ")) },
        ));
    }
    lines.push(match wanted {
        None => Line::new("warn", "several agents are connected -- `agent use <id>` to pick one"),
        Some(_) => Line::new("dim", "type anything that is not a command to send it to the agent"),
    });
    lines
}

fn ask_which_agent(bridge: &Bridge, available: &[&'static Harness]) -> Vec<Line> {
    let list = attached(bridge, available);
    let mut lines = vec![Line::new("warn", format!("{} agents are connected to this Studio -- which should answer?", list.len()))];
    lines.extend(list.iter().map(|h| Line::with("dim", format!("  agent use {}", h.id), h.label)));
    lines.push(Line::new("dim", "asked once; the choice is remembered until you change it"));
    lines
}

/// Says where the prompt came from, on the first turn of a conversation.
pub fn frame(prompt: &str) -> String {
    format!(
        "You are answering someone typing into a console panel docked inside Roblox Studio, with a place \
         open in front of them. The rbx-studio MCP tools are connected to that place: use them for anything \
         about the game -- `script_create` and `script_edit` for code, `create`/`modify` for instances, \
         `terrain` for terrain. \"A script\" means a Script instance in the place, not a file on disk. Reach \
         for the filesystem only if they clearly mean this MCP server's own source.\n\n{prompt}"
    )
}

fn start_agent(bridge: &Arc<Bridge>, studio_id: &str, prompt: &str) -> Vec<Line> {
    let mut agents = AGENTS.lock();
    let state = agents.entry(studio_id.to_string()).or_default();
    if state.active.is_some() {
        return vec![Line::with("warn", "an agent is already running", "press stop to cancel it")];
    }
    let available = harness::installed();
    if available.is_empty() {
        return render_agents(state.harness_id.as_deref(), bridge);
    }
    let Some(wanted) = preferred(state.harness_id.as_deref(), bridge, &available) else {
        return match &state.harness_id {
            None => ask_which_agent(bridge, &available),
            Some(id) => vec![Line::new("error", format!("unknown agent \"{id}\""))],
        };
    };
    let emit_bridge = bridge.clone();
    let emit_id = studio_id.to_string();
    let emit: Arc<dyn Fn(Line) + Send + Sync> = Arc::new(move |line: Line| {
        let mut frame = json!({ "event": "console", "level": line.level, "message": line.message });
        if let Some(d) = line.detail {
            frame["detail"] = Value::String(d);
        }
        emit_bridge.notify(&emit_id, &frame);
    });
    let fresh = state.session.is_none();
    let text = if fresh { frame(prompt) } else { prompt.to_string() };
    let cwd = std::env::current_dir().unwrap_or_default();
    let mut started = harness::run(wanted, &text, cwd, state.session.clone(), emit);
    let done = std::mem::replace(&mut started.done, tokio::sync::oneshot::channel().1);
    state.active = Some(Arc::new(started));

    let bridge = bridge.clone();
    let id = studio_id.to_string();
    tokio::spawn(async move {
        let session = done.await.ok().flatten();
        if let Some(state) = AGENTS.lock().get_mut(&id) {
            state.session = session;
            state.active = None;
        }
        bridge.notify(&id, &json!({ "event": "agent-run", "state": "idle" }));
    });
    // One readable status line, not a name with its state parked on the right.
    vec![Line::new("dim", format!("{} is {}…", wanted.label, if fresh { "starting" } else { "continuing" }))]
}

fn is_digits(s: &str) -> bool {
    !s.is_empty() && s.bytes().all(|b| b.is_ascii_digit())
}

async fn cloud_command(args: &[String]) -> Vec<Line> {
    let verb = args.first().map(|s| s.to_lowercase()).unwrap_or_else(|| "status".into());
    let path = credentials::path_display();
    match verb.as_str() {
        "status" => {
            let status = credentials::status().await;
            if !status.has_key {
                return vec![
                    Line::with("warn", "no Open Cloud key set", "uploads and live calls cannot run"),
                    Line::new("dim", "1. create.roblox.com/dashboard/credentials -> Create API Key"),
                    Line::new("dim", "2. Access Permissions -> add what you need, like `assets`, tick Read and Write"),
                    Line::new("dim", "3. add your IP, save, copy the key (it is shown once)"),
                    Line::with("dim", "4. cloud key <paste it>", "then: cloud user <your user id>"),
                ];
            }
            let mut lines = vec![Line::with(
                "ok",
                format!("key set (ends {})", status.key_hint.unwrap_or_default()),
                if status.source == Some("environment") { "from ROBLOX_API_KEY".to_string() } else { path },
            )];
            match status.creator_id {
                None => lines.push(Line::with(
                    "warn",
                    "no creator set, so uploads will fail",
                    "cloud user <id> — the number in your roblox.com/users/NNN/profile URL",
                )),
                Some(id) => lines.push(Line::new("dim", format!("uploading as {} {id}", status.creator_field.unwrap_or("userId")))),
            }
            lines.push(match status.universe_id {
                None => Line::with("dim", "no universe set", "cloud universe <id> — needed for live data stores and live Luau"),
                Some(u) => Line::new("dim", format!("universe {u}")),
            });
            if let Some(p) = status.place_id {
                lines.push(Line::new("dim", format!("place {p}")));
            }
            lines
        }
        "key" => {
            let Some(key) = args.get(1) else {
                return vec![
                    Line::new("dim", "usage: cloud key <your Open Cloud API key>"),
                    Line::new("dim", "the line is masked in the log and in history"),
                ];
            };
            if args.len() > 2 {
                return vec![Line::new("error", "that key has a space in it — paste it as one word")];
            }
            // Checked before it is written, so a mistyped key is never stored.
            let (ok, detail) = credentials::test(key).await;
            if !ok {
                return vec![Line::with("error", "not saved", detail)];
            }
            if let Err(e) = credentials::save_api_key(key).await {
                return vec![Line::with("error", "not saved", e.to_string())];
            }
            let mut lines = vec![
                Line::with("ok", format!("key saved (ends {})", credentials::last_chars(key, 4)), path),
                Line::new("dim", "stored for this machine only, readable by you alone"),
            ];
            if credentials::status().await.creator_id.is_none() {
                lines.push(Line::with("warn", "now set who to upload as", "cloud user <id>"));
            }
            lines
        }
        "user" | "group" => {
            let Some(id) = args.get(1).filter(|id| is_digits(id)) else {
                return vec![
                    Line::new("dim", format!("usage: cloud {verb} <numeric id>")),
                    Line::new(
                        "dim",
                        if verb == "user" {
                            "the number in your roblox.com/users/NNN/profile URL"
                        } else {
                            "the number in your roblox.com/groups/NNN/... URL"
                        },
                    ),
                ];
            };
            if let Err(e) = credentials::save_creator(if verb == "user" { "userId" } else { "groupId" }, id).await {
                return vec![Line::with("error", "not saved", e.to_string())];
            }
            vec![
                Line::new("ok", format!("uploads will be created by {verb} {id}")),
                Line::new("dim", "the other kind of creator was cleared"),
            ]
        }
        "universe" | "place" => {
            let Some(id) = args.get(1).filter(|id| is_digits(id)) else {
                return vec![
                    Line::new("dim", format!("usage: cloud {verb} <numeric id>")),
                    Line::new(
                        "dim",
                        if verb == "universe" {
                            "Creator Dashboard -> hover the game -> ⋯ -> Copy Universe ID"
                        } else {
                            "the number after /places/ in the place's configure URL"
                        },
                    ),
                ];
            };
            let field = if verb == "universe" { "universeId" } else { "placeId" };
            if let Err(e) = credentials::save_target(field, id).await {
                return vec![Line::with("error", "not saved", e.to_string())];
            }
            // A place says which game you mean, so the universe is derived once.
            if verb == "place" && credentials::status().await.universe_id.is_none()
                && let Some(derived) = cloud::universe_for_place(id).await {
                    let _ = credentials::save_target("universeId", &derived).await;
                    return vec![
                        Line::new("ok", format!("place set to {id}")),
                        Line::with("ok", format!("universe {derived}"), "worked out from the place"),
                    ];
                }
            vec![
                Line::new("ok", format!("{verb} set to {id}")),
                Line::new(
                    "dim",
                    if verb == "universe" {
                        "live data stores and live Luau now act on this game"
                    } else {
                        "place publishing and live Luau now act on this place"
                    },
                ),
            ]
        }
        "test" => {
            if !credentials::status().await.has_key {
                return vec![Line::with("warn", "no key set", "cloud key <k>")];
            }
            let Some(loaded) = credentials::load().await else {
                return vec![Line::with("warn", "key set but no creator", "cloud user <id>")];
            };
            let (ok, detail) = credentials::test(&loaded.api_key).await;
            vec![
                Line::new(if ok { "ok" } else { "error" }, detail),
                Line::new("dim", format!("uploading as {} {}", loaded.creator_field, loaded.creator_id)),
            ]
        }
        "forget" => {
            if credentials::forget().await {
                vec![
                    Line::with("ok", "stored credentials deleted", path),
                    Line::new("dim", "revoke the key itself on the Creator Dashboard too"),
                ]
            } else {
                vec![Line::new("dim", "there was nothing stored to delete")]
            }
        }
        _ => vec![Line::new("dim", "usage: cloud [key <k>|user <id>|group <id>|universe <id>|place <id>|test|forget]")],
    }
}

/// The game the asking Studio has open, as a universe id.
async fn open_universe(bridge: &Bridge, studio_id: &str) -> std::result::Result<String, Line> {
    let place = bridge.list().into_iter().find(|s| s.identity.studio_id == studio_id).map(|s| s.identity.place_id).unwrap_or(0);
    if place == 0 {
        // An unsaved place has no game yet; fall back to the one `cloud universe` names.
        return credentials::status().await.universe_id.ok_or_else(|| {
            Line::with("warn", "this place is not saved to Roblox, so it has no game yet", "save it, or run cloud universe <id>")
        });
    }
    cloud::universe_for_place(&place.to_string())
        .await
        .ok_or_else(|| Line::with("error", "could not work out this place's game", "check the connection, or run cloud universe <id>"))
}

/// `allow`, `allow <group>`, `allow <group> off`: what agents may do here.
async fn allow_command(bridge: &Bridge, studio_id: &str, args: &[String]) -> Vec<Line> {
    use cloud::permissions;
    let universe = match open_universe(bridge, studio_id).await {
        Ok(u) => u,
        Err(line) => return vec![line],
    };
    let Some(name) = args.first() else {
        let mut lines = vec![Line::new("info", format!("what agents may do in this game (universe {universe})"))];
        for (group, on) in permissions::list(&universe).await {
            lines.push(Line::with(if on { "ok" } else { "dim" }, format!("  {} {}", if on { "on " } else { "off" }, group.id), group.label));
        }
        lines.push(Line::new("dim", "allow <group> turns one on, allow <group> off turns it off"));
        return lines;
    };
    let Some(group) = permissions::find(name) else {
        let names: Vec<&str> = permissions::GROUPS.iter().map(|g| g.id).collect();
        return vec![Line::with("error", format!("no permission called \"{name}\""), names.join(", "))];
    };
    let on = match args.get(1).map(|s| s.to_lowercase()) {
        None => true,
        Some(v) if v == "on" => true,
        Some(v) if v == "off" => false,
        Some(v) => return vec![Line::new("error", format!("\"{v}\" is not on or off"))],
    };
    if let Err(e) = permissions::set(&universe, group, on).await {
        return vec![Line::with("error", "not saved", e.to_string())];
    }
    vec![Line::with(
        if on { "ok" } else { "warn" },
        format!("{} {} for this game", group.id, if on { "allowed" } else { "turned off" }),
        group.label,
    )]
}

/// Stops every detected playtest; the plugin already persisted the OFF setting.
async fn playtests_off(bridge: &Arc<Bridge>) -> Vec<Line> {
    let calls = bridge.list().into_iter().map(|session| {
        let bridge = bridge.clone();
        async move {
            let id = session.identity.studio_id.clone();
            let attempt = async {
                let before = bridge.call("playtest.control", json!({ "op": "state" }), "panel", Some(&id), Some(3000.0)).await?;
                let st = before.get("state").cloned().unwrap_or_default();
                let b = |k: &str| st.get(k).and_then(Value::as_bool);
                let is_edit = b("isEdit").unwrap_or(false);
                if is_edit && !b("isRunning").unwrap_or(false) && !b("testPending").unwrap_or(false) && b("editModeActive") != Some(false) {
                    return Ok(());
                }
                let op = if !is_edit && !b("isRunMode").unwrap_or(false) { "endTest" } else { "stop" };
                bridge.call("playtest.control", json!({ "op": op }), "panel", Some(&id), Some(5000.0)).await.map(|_| ())
            };
            match attempt.await {
                Ok(()) => None,
                Err(_) if bridge.has(&id) => {
                    Some(Line::new("warn", format!("Playtests remain OFF; could not confirm stop in {}.", session.identity.place_name)))
                }
                Err(_) => None,
            }
        }
    });
    futures::future::join_all(calls).await.into_iter().flatten().collect()
}

pub async fn handle(bridge: &Arc<Bridge>, port: u16, request: ConsoleRequest) -> Vec<Line> {
    let args = &request.args;
    match request.command.as_str() {
        "playtests" => {
            if args.len() != 1 || args[0] != "off" {
                return vec![Line::new("error", "Use playtests [on|off] in the Studio MCP panel.")];
            }
            playtests_off(bridge).await
        }
        "doctor" => render_checks(doctor::collect_checks(port).await),
        "studios" => render_studios(bridge, &request.studio_id),
        "use" => {
            let Some(token) = args.first() else {
                return vec![Line::with("dim", "usage: use <number|id>", "run studios to see them")];
            };
            let Some(target) = resolve_studio(bridge, token) else {
                return vec![Line::new("error", format!("no Studio matches \"{token}\""))];
            };
            if let Err(e) = bridge.set_active_for_all(&target) {
                return vec![Line::new("error", e.message)];
            }
            let name = bridge
                .list()
                .into_iter()
                .find(|s| s.identity.studio_id == target)
                .map(|s| s.identity.place_name)
                .unwrap_or(target);
            vec![Line::new("ok", format!("calls now target {name}"))]
        }
        "agent" => {
            let verb = args.first().map(String::as_str);
            let current = AGENTS.lock().get(&request.studio_id).and_then(|s| s.harness_id.clone());
            match verb {
                None | Some("list") => render_agents(current.as_deref(), bridge),
                Some("use") => {
                    let Some(id) = args.get(1) else { return vec![Line::new("dim", "usage: agent use <id>")] };
                    let Some(wanted) = harness::find(id) else {
                        return vec![Line::new("error", format!("unknown agent \"{id}\""))];
                    };
                    let mut agents = AGENTS.lock();
                    let state = agents.entry(request.studio_id.clone()).or_default();
                    state.harness_id = Some(wanted.id.to_string());
                    // A new harness cannot continue another's conversation.
                    state.session = None;
                    vec![Line::new("ok", format!("prompts now go to {}", wanted.label))]
                }
                Some("new") => {
                    AGENTS.lock().entry(request.studio_id.clone()).or_default().session = None;
                    vec![Line::new("ok", "next prompt starts a fresh conversation")]
                }
                _ => vec![Line::new("dim", "usage: agent [list|use <id>|new]")],
            }
        }
        "cloud" => cloud_command(args).await,
        "allow" => allow_command(bridge, &request.studio_id, args).await,
        "stop" => {
            let active = AGENTS.lock().get(&request.studio_id).and_then(|s| s.active.clone());
            match active {
                None => vec![Line::new("dim", "nothing is running")],
                Some(run) => {
                    run.cancel();
                    vec![Line::new("warn", "stopping the agent")]
                }
            }
        }
        "prompt" => {
            let prompt = request.line.trim();
            if prompt.is_empty() {
                return vec![];
            }
            start_agent(bridge, &request.studio_id, prompt)
        }
        other => vec![Line::with(
            "error",
            format!("this bridge does not know \"{other}\""),
            "the plugin and the server are probably different builds",
        )],
    }
}
