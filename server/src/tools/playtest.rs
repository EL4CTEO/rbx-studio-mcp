//! playtest and debug.

use super::{ReadSide, ReadTarget, arr_of, call, read_call, str_of, u64_of};
use crate::errors::{Result, ToolError};
use crate::format::{ToolResult, error_text, json, text, to_flat};
use crate::tool::{Ctx, Tool, define, spec};
use schemars::JsonSchema;
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value, json};
use std::collections::HashSet;
use std::sync::Arc;
use std::time::{Duration, Instant};

/// The studioId of the running playtest's server session, or None.
pub async fn find_playtest_session(ctx: &Ctx, exclude: &HashSet<String>) -> Result<Option<String>> {
    let sessions = ctx.bridge.sessions().await?.list;
    let is_playtest = |c: &str| c.contains("playtest") && !c.contains("client");
    if let Some(s) = sessions
        .iter()
        .find(|s| !exclude.contains(&s.identity.studio_id) && s.identity.context.as_deref().is_some_and(is_playtest))
    {
        return Ok(Some(s.identity.studio_id.clone()));
    }
    let unknown: Vec<String> = sessions
        .iter()
        .filter(|s| !exclude.contains(&s.identity.studio_id) && s.identity.context.is_none())
        .map(|s| s.identity.studio_id.clone())
        .collect();
    let probed = futures::future::join_all(unknown.into_iter().map(|id| {
        let bridge = ctx.bridge.clone();
        async move {
            let status = bridge.call("studio.status", json!({}), Some(&id), Some(3_000.0)).await.ok()?;
            let context = str_of(&status, "context").map(str::to_string);
            bridge.note_place_name(&id, str_of(&status, "placeName").unwrap_or(""), context.as_deref()).await;
            context.as_deref().is_some_and(is_playtest).then_some(id)
        }
    }))
    .await;
    Ok(probed.into_iter().flatten().next())
}

const HEAVY_STOP_WAIT: Duration = Duration::from_secs(120);

fn thousands(v: &Value) -> String {
    let n = v.as_f64().unwrap_or(0.0) as i64;
    let digits = n.abs().to_string();
    let mut out = String::new();
    for (i, c) in digits.chars().enumerate() {
        if i > 0 && (digits.len() - i).is_multiple_of(3) {
            out.push(',');
        }
        out.push(c);
    }
    if n < 0 { format!("-{out}") } else { out }
}

/// Explains a stop that is about to freeze Studio, or one that just did.
pub fn heavy_stop_note(heavy: &Value, stopping: bool) -> String {
    let biggest: Vec<String> = arr_of(heavy, "heaviest")
        .iter()
        .map(|e| format!("{} ({})", str_of(e, "path").unwrap_or(""), thousands(e.get("instances").unwrap_or(&json!(0)))))
        .collect();
    let anim = heavy
        .get("animSavesInstances")
        .filter(|v| v.as_f64().unwrap_or(0.0) > 0.0)
        .map(|v| {
            format!(
                " {} are inside AnimSaves (saved Animation Editor clips), the usual cause; moving them out of Workspace, e.g. to ServerStorage, removes the freeze.",
                thousands(v)
            )
        })
        .unwrap_or_default();
    format!(
        "Workspace holds {} instances. Studio {} can freeze for a minute or more while a playtest of a place this size stops (a known Roblox regression, not a crash). Largest: {}.{anim}{}",
        thousands(heavy.get("instances").unwrap_or(&json!(0))),
        heavy.get("build").map(to_flat).unwrap_or_default(),
        biggest.join(", "),
        if stopping { " Waited up to 2 minutes for the stop." } else { " Warn the user before stopping it." }
    )
}

#[derive(Deserialize, Serialize, JsonSchema, PartialEq, Clone, Copy)]
#[serde(rename_all = "camelCase")]
enum PlayOp {
    Play,
    Run,
    Multiplayer,
    AddPlayers,
    Stop,
    State,
}

#[derive(Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
struct PlayArgs {
    /// 'play' starts a playtest with a character, 'run' runs scripts with no player, 'multiplayer' starts a several-player test, 'addPlayers' joins more to a running multiplayer test, 'stop' ends it and discards its changes, 'state' only reports.
    op: PlayOp,
    /// multiplayer: how many players to start (default 2). addPlayers: how many to add (default 1).
    #[schemars(range(min = 1, max = 8))]
    players: Option<u32>,
    /// Value handed to the test, readable inside it with `StudioTestService:GetTestArgs()`. Use it to tell a test which case to exercise.
    args: Option<String>,
    /// Target Studio; omit for the active one.
    studio_id: Option<String>,
}

fn state_of(r: &Value) -> &Value {
    static EMPTY: std::sync::LazyLock<Value> = std::sync::LazyLock::new(|| json!({}));
    r.get("state").unwrap_or(&EMPTY)
}

fn settled(r: Option<&Value>) -> bool {
    r.is_some_and(|r| {
        let s = state_of(r);
        s.get("editModeActive") != Some(&Value::Bool(false)) && s.get("testPending") != Some(&Value::Bool(true))
    })
}

fn merge(state: &Value, extra: Map<String, Value>) -> Value {
    let mut out = state.as_object().cloned().unwrap_or_default();
    out.extend(extra);
    Value::Object(out)
}

async fn playtest(ctx: Arc<Ctx>, a: PlayArgs) -> Result<ToolResult> {
    // Stop is routed: only EndTest from the playtest's server session ends a test.
    if a.op == PlayOp::Stop
        && let Some(playtest) = find_playtest_session(&ctx, &HashSet::new()).await? {
            let ended = call(&ctx, "playtest.control", json!({ "op": "endTest", "value": a.args }), Some(&playtest), Some(10_000.0)).await.ok();
            let heavy = ended.as_ref().and_then(|e| e.get("heavyWorkspace")).filter(|h| !h.is_null()).cloned();
            let survivor = ctx.bridge.sessions().await?.list.into_iter().find(|s| s.identity.studio_id != playtest);
            if let Some(survivor) = survivor {
                // Waited for, not sampled: teardown is deferred so the reply can leave first.
                let deadline = Instant::now() + if heavy.is_some() { HEAVY_STOP_WAIT } else { Duration::from_secs(10) };
                let mut after: Option<Value> = None;
                loop {
                    if let Ok(r) = call(
                        &ctx,
                        "playtest.control",
                        json!({ "op": "state", "waitingForStop": true }),
                        Some(&survivor.identity.studio_id),
                        Some(10_000.0),
                    )
                    .await
                    {
                        after = Some(r);
                    }
                    if settled(after.as_ref()) || Instant::now() >= deadline {
                        break;
                    }
                    tokio::time::sleep(Duration::from_millis(if heavy.is_some() { 1_000 } else { 400 })).await;
                }
                let mut notes = Vec::new();
                if let Some(h) = &heavy {
                    notes.push(heavy_stop_note(h, true));
                }
                if !settled(after.as_ref()) {
                    notes.push(if heavy.is_some() {
                        "Studio is still tearing the test down. Check `playtest op=\"state\"` again in a minute.".to_string()
                    } else {
                        "The stop was sent but Studio is still in a test. Check whether something inside it is holding the session open.".to_string()
                    });
                }
                let body = after.as_ref().map(|r| state_of(r).clone()).unwrap_or_else(|| json!({ "stopping": true }));
                let note = (!notes.is_empty()).then(|| notes.join("\n"));
                return Ok(json(&body, note.as_deref()));
            }
        }

    // AddPlayers only works from the test's server; wait until the clients are in.
    if a.op == PlayOp::AddPlayers {
        let Some(playtest) = find_playtest_session(&ctx, &HashSet::new()).await? else {
            return Ok(error_text("No playtest is running. Start one with `playtest op=\"multiplayer\"` first."));
        };
        let adding = a.players.unwrap_or(1) as u64;
        let started = call(&ctx, "playtest.control", json!({ "op": "addPlayers", "players": adding }), Some(&playtest), Some(10_000.0)).await?;
        let target = u64_of(state_of(&started), "playerCount") + adding;
        let deadline = Instant::now() + Duration::from_secs(20);
        let mut after = started;
        while u64_of(state_of(&after), "playerCount") < target && Instant::now() < deadline {
            tokio::time::sleep(Duration::from_millis(500)).await;
            after = call(&ctx, "playtest.control", json!({ "op": "state" }), Some(&playtest), Some(5_000.0)).await?;
        }
        let have = u64_of(state_of(&after), "playerCount");
        let mut extra = Map::new();
        extra.insert("studioId".into(), json!(playtest));
        let note = (have < target).then(|| {
            format!("{} of {adding} new players had not joined after 20s. Check `state` again shortly.", target - have)
        });
        return Ok(json(&merge(state_of(&after), extra), note.as_deref()));
    }

    let starting = matches!(a.op, PlayOp::Play | PlayOp::Multiplayer);
    let before: HashSet<String> = if starting {
        ctx.bridge.sessions().await?.list.into_iter().map(|s| s.identity.studio_id).collect()
    } else {
        HashSet::new()
    };
    let r = call(
        &ctx,
        "playtest.control",
        json!({ "op": a.op, "players": a.players, "args": a.args }),
        a.studio_id.as_deref(),
        Some(30_000.0),
    )
    .await?;
    let changed = r.get("changed") == Some(&Value::Bool(true));
    let mut notes = Vec::new();
    if starting
        && let Some(h) = r.get("heavyWorkspace").filter(|h| !h.is_null()) {
            notes.push(heavy_stop_note(h, false));
        }
    if a.op != PlayOp::State && !changed {
        notes.push(str_of(&r, "reason").unwrap_or("Studio accepted the call but nothing changed.").to_string());
    } else if let Some(reason) = str_of(&r, "reason") {
        notes.push(reason.to_string());
    }

    // The running game is a different session; hand its id back.
    let mut runtime: Option<(String, Option<Value>)> = None;
    if starting && changed && state_of(&r).get("testPending") == Some(&Value::Bool(true)) {
        let deadline = Instant::now() + Duration::from_secs(6);
        let wanted = if a.op == PlayOp::Multiplayer { a.players.unwrap_or(2) as usize } else { 1 };
        loop {
            let id = match &runtime {
                Some((id, _)) => Some(id.clone()),
                None => find_playtest_session(&ctx, &before).await?,
            };
            if let Some(id) = id {
                let players = call(&ctx, "playtest.control", json!({ "op": "state" }), Some(&id), Some(2_000.0))
                    .await
                    .ok()
                    .and_then(|s| state_of(&s).get("players").cloned());
                let count = players.as_ref().and_then(Value::as_array).map(Vec::len).unwrap_or(0);
                let known = runtime.as_ref().and_then(|(_, p)| p.clone());
                runtime = Some((id, players.or(known)));
                if count >= wanted {
                    break;
                }
            }
            if Instant::now() >= deadline {
                break;
            }
            tokio::time::sleep(Duration::from_millis(300)).await;
        }
        match &runtime {
            None => notes.push("The playtest server has not connected yet. Use list_studios later to find its studioId.".into()),
            Some((_, p)) if p.as_ref().and_then(Value::as_array).is_none_or(Vec::is_empty) => {
                notes.push("The playtest server connected, but players are still joining. Query playtest state later for names.".into())
            }
            _ => {}
        }
    }
    let body = match runtime {
        Some((id, players)) => {
            let mut extra = Map::new();
            extra.insert("studioId".into(), json!(id));
            if let Some(p) = players {
                extra.insert("players".into(), p);
            }
            merge(state_of(&r), extra)
        }
        None => state_of(&r).clone(),
    };
    let note = (!notes.is_empty()).then(|| notes.join("\n"));
    Ok(json(&body, note.as_deref()))
}

// --- debug ----------------------------------------------------------------------------

#[derive(Deserialize, JsonSchema, PartialEq, Clone, Copy)]
#[serde(rename_all = "lowercase")]
enum DebugOp {
    Set,
    Clear,
    Snapshots,
    Exceptions,
    Remotes,
    Watch,
    Collisions,
}

#[derive(Deserialize, Serialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
struct Breakpoint {
    /// Script path, e.g. "ServerScriptService.Combat".
    path: String,
    /// Line to break on.
    #[schemars(range(min = 1))]
    line: u32,
    /// Luau expression; the breakpoint only fires when it is true, evaluated in scope at that line, e.g. "count > 100".
    #[serde(skip_serializing_if = "Option::is_none")]
    condition: Option<String>,
    /// Write this to the output when hit, instead of capturing a snapshot.
    #[serde(skip_serializing_if = "Option::is_none")]
    log_message: Option<String>,
}

#[derive(Deserialize, Serialize, JsonSchema, Clone, Copy)]
enum ExceptionMode {
    Never,
    Always,
    Unhandled,
}

fn d10() -> u32 {
    10
}

#[derive(Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
struct DebugArgs {
    /// client: read the actual player's playtest VM. Use the playtest server studioId.
    #[serde(default)]
    target: ReadSide,
    /// watch: properties to observe.
    #[schemars(length(max = 16))]
    properties: Option<Vec<String>>,
    /// watch: attribute names; omit for all, [] for none.
    #[schemars(length(max = 16))]
    attributes: Option<Vec<String>>,
    /// watch: include direct child additions/removals.
    #[serde(default = "super::d::t")]
    children: bool,
    /// 'set' adds breakpoints, 'clear' removes one or all, 'snapshots' reads what has been captured, 'exceptions' controls breaking on errors, 'remotes' traces RemoteEvents.
    op: DebugOp,
    /// collisions: ignore contacts that hit softer than this, in studs/s along the contact normal.
    #[schemars(range(min = 0))]
    min_speed: Option<f64>,
    /// watch/remotes/collisions: bounded capture seconds, default 5. Pair watch with concurrent input to observe a reaction.
    #[schemars(range(min = 1, max = 15))]
    seconds: Option<f64>,
    /// watch client/remotes: player name; required with multiple players.
    player: Option<String>,
    /// set only: breakpoints to add.
    #[schemars(length(max = 50))]
    breakpoints: Option<Vec<Breakpoint>>,
    /// clear: script to clear. remotes: remote or subtree path, default game. Narrow this if discovery is truncated. watch: instance. collisions: part, model or folder.
    path: Option<String>,
    /// clear only: which line to remove.
    #[schemars(range(min = 1))]
    line: Option<u32>,
    /// exceptions only: break on every error, only unhandled ones, or never. Defaults to Unhandled.
    mode: Option<ExceptionMode>,
    /// snapshots only: how many of the most recent to return.
    #[serde(default = "d10")]
    #[schemars(range(min = 1, max = 40))]
    limit: u32,
    /// snapshots only: discard what is returned, so the next read starts fresh.
    #[serde(default)]
    clear: bool,
    /// Target Studio; omit for the active one.
    studio_id: Option<String>,
}

const AMBIENT_LOCALS: [&str; 4] = ["_G", "shared", "script", "..."];

fn briefly(value: &str) -> String {
    let single = value.split_whitespace().collect::<Vec<_>>().join(" ");
    if single.chars().count() > 160 { format!("{}…", single.chars().take(159).collect::<String>()) } else { single }
}

fn frame_label(frame: Option<&Value>) -> String {
    let Some(f) = frame else { return "(unknown)".into() };
    let where_ = format!("{}:{}", str_of(f, "ScriptPath").unwrap_or("?"), f.get("Line").map(to_flat).unwrap_or_else(|| "?".into()));
    match str_of(f, "Name").filter(|n| !n.is_empty()) {
        Some(name) => format!("{where_} in {name}"),
        None => where_,
    }
}

/// Captured frames as a readable outline rather than the debugger's raw payload.
fn render_snapshots(items: &[Value]) -> String {
    let mut blocks = Vec::new();
    let mut dropped_ambient = false;
    for (index, item) in items.iter().enumerate() {
        let frames = arr_of(item, "frames");
        let stack = item.get("stack");
        let reason = item.pointer("/stopped/Reason").and_then(Value::as_str);
        let mut lines = Vec::new();
        let head = frame_label(frames.first().and_then(|f| f.get("frame")));
        let depth = stack.and_then(|s| s.get("TotalFrames")).and_then(Value::as_u64).unwrap_or(frames.len() as u64);
        lines.push(format!(
            "#{}  {head}{}{}",
            index + 1,
            if depth > 1 { format!("  ({depth} frames)") } else { String::new() },
            match reason {
                Some(r) if !r.ends_with("Breakpoint") => format!("  [{r}]"),
                _ => String::new(),
            }
        ));
        for entry in frames {
            if frames.len() > 1 {
                lines.push(format!("  {}", frame_label(entry.get("frame"))));
            }
            let vars: Vec<&Value> = entry.get("variables").and_then(Value::as_object).map(|m| m.values().collect()).unwrap_or_default();
            let shown: Vec<&&Value> = vars
                .iter()
                .filter(|v| match str_of(v, "Name") {
                    Some(n) if AMBIENT_LOCALS.contains(&n) => {
                        dropped_ambient = true;
                        false
                    }
                    _ => true,
                })
                .collect();
            if shown.is_empty() {
                lines.push("    (no locals in scope)".into());
                continue;
            }
            for v in shown {
                let ty = str_of(v, "Type").filter(|t| !t.is_empty()).map(|t| format!(" : {t}")).unwrap_or_default();
                lines.push(format!("    {} = {}{ty}", str_of(v, "Name").unwrap_or("?"), briefly(str_of(v, "Value").unwrap_or("nil"))));
            }
        }
        if let Some(stack_frames) = stack.and_then(|s| s.get("Frames")).and_then(Value::as_object)
            && frames.len() <= 1 && depth > 1 {
                for f in stack_frames.values().skip(1) {
                    lines.push(format!("  called from {}", frame_label(Some(f))));
                }
            }
        blocks.push(lines.join("\n"));
    }
    if dropped_ambient {
        blocks.push("(_G, shared, script and ... are omitted -- they are in scope everywhere.)".into());
    }
    blocks.join("\n\n")
}

async fn debug(ctx: Arc<Ctx>, a: DebugArgs) -> Result<ToolResult> {
    let studio = a.studio_id.as_deref();
    let read = ReadTarget { target: a.target, player: a.player.clone() };
    let seconds = a.seconds.unwrap_or(5.0);
    match a.op {
        DebugOp::Watch => {
            let path = a.path.as_deref().ok_or_else(|| ToolError::bad_params("watch requires an instance path or handle."))?;
            let r = read_call(
                &ctx,
                "debug.watch",
                json!({ "path": path, "properties": a.properties, "attributes": a.attributes, "children": a.children, "seconds": seconds }),
                &read,
                studio,
                (seconds + 30.0) * 1000.0,
            )
            .await?;
            return Ok(json(&r, None));
        }
        DebugOp::Collisions => {
            let path = a.path.as_deref().ok_or_else(|| ToolError::bad_params("collisions requires a part, model or folder path."))?;
            let r = read_call(
                &ctx,
                "debug.collisions",
                json!({ "path": path, "minSpeed": a.min_speed, "seconds": seconds }),
                &read,
                studio,
                (seconds + 30.0) * 1000.0,
            )
            .await?;
            return Ok(json(&r, None));
        }
        _ => {}
    }
    if a.target == ReadSide::Client {
        return Err(ToolError::new(
            "BAD_TARGET",
            "Only debug watch and collisions support target=client; remotes already observes both directions.",
        ));
    }
    match a.op {
        DebugOp::Remotes => {
            let r = call(
                &ctx,
                "debug.remotes",
                json!({ "path": a.path, "player": a.player, "seconds": seconds }),
                studio,
                Some((seconds + 15.0) * 1000.0),
            )
            .await?;
            Ok(text(to_flat(&r)))
        }
        DebugOp::Snapshots => {
            let r = call(&ctx, "debug.snapshots", json!({ "limit": a.limit, "clear": a.clear }), studio, None).await?;
            let items = arr_of(&r, "items");
            if items.is_empty() {
                return Ok(text(
                    "No breakpoints have been hit.\nBreakpoints only catch code that runs after they are set, and they belong \
                     to one session — if the code runs in a playtest, set them before starting it and read them back from \
                     that playtest's studioId.",
                ));
            }
            let overflow = u64_of(&r, "overflow");
            let footer = format!(
                "{} of {} captured{}",
                items.len(),
                super::disp(r.get("total")),
                if overflow > 0 { format!(", {overflow} older snapshots were dropped") } else { String::new() }
            );
            Ok(text(format!("{}\n\n[{footer}]", render_snapshots(items))))
        }
        DebugOp::Set => {
            let Some(bps) = a.breakpoints.filter(|b| !b.is_empty()) else {
                return Ok(error_text("set needs a `breakpoints` array."));
            };
            let r = call(&ctx, "debug.set", json!({ "breakpoints": bps }), studio, None).await?;
            let failed: Vec<String> = arr_of(&r, "failed")
                .iter()
                .map(|f| format!("  {}:{} — {}", str_of(f, "path").unwrap_or(""), super::disp(f.get("line")), str_of(f, "error").unwrap_or("")))
                .collect();
            let note = (!failed.is_empty()).then(|| format!("Refused:\n{}", failed.join("\n")));
            Ok(json(r.get("added").unwrap_or(&json!([])), note.as_deref()))
        }
        DebugOp::Exceptions => {
            let r = call(&ctx, "debug.exceptions", json!({ "mode": a.mode.unwrap_or(ExceptionMode::Unhandled) }), studio, None).await?;
            Ok(text(format!("Breaking on exceptions: {}.", super::disp(r.get("mode")))))
        }
        _ => {
            let r = call(&ctx, "debug.clear", json!({ "path": a.path, "line": a.line }), studio, None).await?;
            Ok(json(&r, None))
        }
    }
}

pub fn tools() -> Vec<Tool> {
    vec![
        define(
            spec("playtest", "Run, pause and stop the simulation").destructive(true),
            "Starts and stops playtests, so scripts can be made to run and then observed without asking the user to \
             press anything.\n\n\
             `play` is the Play button: a character spawns and `Players.PlayerAdded` fires. `run` is Run mode, which \
             executes scripts with no player at all. `multiplayer` starts a test with several players for testing \
             replication. `addPlayers` joins more players to a running multiplayer test, for late joins and lobby \
             fill-up. `state` reports without changing anything.\n\n\
             Play and multiplayer return the playtest server's studioId once it connects. Use that ID directly for \
             `console`, `performance` and `execute_luau`; the editor session has a separate log. If connection takes too \
             long, the reply says so and `list_studios` can find it later.\n\n\
             A test does not block this call: it starts and the reply reports the state reached. Studio only ends it \
             when something inside calls `StudioTestService:EndTest(value)` or when `stop` is used here; whatever EndTest \
             passed comes back as `lastResult` on a later `state`. That makes a scripted check possible end to end: \
             `args` is readable inside the test via `StudioTestService:GetTestArgs()`, so a test can be told what to do \
             and report back what happened.\n\n\
             Stopping discards everything the playtest changed, exactly as pressing Stop does. Build in edit mode, then \
             play — not the other way round.\n\n\
             The reply says whether the mode actually moved, not merely that Studio accepted the request.\n\n\
             The panel's `playtests on` grants permission, never a requirement: obey AGENTS.md, CLAUDE.md, user \
             instructions and project guidance that prohibit playtesting even when ON. `playtests off` is a hard MCP \
             lock: play, run, multiplayer and addPlayers are refused regardless of instructions to test; state and stop \
             remain available. The lock only blocks starting simulation: screenshots, tree, inspect, script reads, \
             edit-mode execute_luau and UI inspection stay available. Continue using edit-mode tools and static \
             inspection where possible. Only the user can re-enable it with `playtests on` in the panel. Do not bypass \
             the lock through execute_luau, Studio APIs or another operation. Manual Studio Play is unaffected.",
            playtest,
        ),
        define(
            spec("debug", "Breakpoints and runtime inspection").destructive(false),
            "Sets breakpoints that record the stack and variables when they are hit, then reads back what they caught.\n\n\
             These are tracepoints, not a step debugger. A breakpoint fires, captures the call stack and the variables \
             in scope, and lets execution continue; `op: \"snapshots\"` returns what was captured. Studio's debugger has \
             to decide whether to resume the instant it stops, and cannot wait for a tool call to come back with an \
             answer, so stepping through code line by line is not possible this way — but 'what was this value when it \
             got here' is, which is usually the actual question.\n\n\
             `condition` is a Luau expression evaluated where the breakpoint sits, so a breakpoint can fire only on the \
             case that matters — `health < 0`, `player.Name == \"someone\"`.\n\n\
             `logMessage` is ALSO a Luau expression, not a template string: its value is printed when the breakpoint is \
             hit, so write `\"health=\" .. health` rather than `health={health}`. Prose is a syntax error. Read the lines \
             back with `console`.\n\n\
             Two things about it are measured, not assumed, and both waste your time otherwise. A breakpoint fires ONCE \
             PER RUN, not once per pass: on a five-iteration loop it printed a single line, for the first iteration \
             only. It is not a way to watch a value change inside a loop — to see every pass, have the code itself \
             print and read that with `console`. And a log expression CANNOT SEE THE LOOP CONTROL VARIABLE: on `for \
             index = 1, 5 do`, a breakpoint in the body read the body's own locals correctly and `index` as nil. Wrap \
             values in `tostring` so a nil prints as \"nil\" instead of throwing.\n\n\
             A log expression that throws is reported as \"Breakpoint ... ignored\" in `console`, NOT here — `set` still \
             returns Verified, because Studio only compiles the expression once the line is reached.\n\n\
             So the two kinds cost different things: a `logMessage` breakpoint never stops and gives you one line you \
             composed in advance, while one without it stops briefly and gives you the whole frame — every local and its \
             type, without having to guess beforehand which value would matter. Both give you that for one pass only. \
             Reach for the log when you know what to watch, the capture when you do not.\n\n\
             Only one breakpoint exists per line, so the same line cannot both log and capture.\n\n\
             Put the breakpoint on a line that does something. A `return`, an `end` or a bare declaration can verify \
             and then never fire — measured, not guessed: the same breakpoint moved from `return squared, tag` to the \
             assignment above it went from silent to firing on every pass. If one verifies but catches nothing, suspect \
             the line before suspecting the condition.\n\n\
             Breakpoints belong to the session that holds them. Set them in the editor session BEFORE starting a \
             playtest, since code that already ran cannot be caught retroactively.\n\n\
             Nothing here leaves a thread stopped waiting for you. A capture breakpoint stops for as long as it takes to \
             read the frame and then resumes itself, so a script with one mid-loop still runs to its last line, and the \
             user is never left with a frozen Studio to rescue.\n\n\
             `remotes` passively observes RemoteEvent traffic for one playtest player in both directions. Returns \
             counts, calls/sec and two short argument-shape samples per remote; no raw payload dumps or RemoteFunction \
             interception. Requires the playtest server studioId. Captures 5 seconds by default (max 15), at most 2000 \
             events and 40 rows within 12 KB; reports truncation when a limit is reached.\n\n\
             `collisions` watches a part, or every part under a model, with the engine's collision summaries and returns \
             one row per colliding pair, hardest impact first: contact point, surface normal, relative velocity, area, \
             impact speed along the normal and total speed. Use it to tune impact FX, sound and damage from real \
             numbers, or to find what a part keeps hitting. Needs physics running (a playtest); `target=client` reads \
             the client's own simulation. Resting contact reports every frame, so set `minSpeed` to keep impacts only; \
             it filters on impact speed, so sliding does not count.",
            debug,
        ),
    ]
}
