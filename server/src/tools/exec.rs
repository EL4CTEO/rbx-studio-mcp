//! execute_luau and viewport.

use super::{ReadSide, ReadTarget, arr_of, call, read_call, str_of, u64_of};
use crate::cloud::{self, Target};
use crate::errors::{Result, ToolError};
use crate::format::{PageMeta, ToolResult, error_text, json, stringify, table, text, to_flat};
use crate::tool::{Ctx, Tool, define, spec};
use parking_lot::Mutex;
use schemars::JsonSchema;
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value, json};
use std::collections::{BTreeSet, HashMap};
use std::sync::{Arc, LazyLock};

#[derive(Deserialize, JsonSchema, Default, PartialEq, Clone, Copy, Serialize)]
#[serde(rename_all = "lowercase")]
enum ExecTarget {
    #[default]
    Studio,
    Live,
    Client,
}

fn d25() -> u32 {
    25
}

#[derive(Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
struct ExecArgs {
    /// Retrieve a retained result without rerunning source. Keep its original target/player/studioId.
    result_id: Option<String>,
    /// Retained result path, default [returned,1]. Use [] for its root; [output,1,message] for a log string.
    #[schemars(length(max = 20))]
    result_path: Option<Vec<PathKey>>,
    /// Result page offset; use nextOffset from the previous page. String offsets are UTF-8 bytes.
    #[serde(default)]
    result_offset: u32,
    /// Retained table entries per page.
    #[serde(default = "d25")]
    #[schemars(range(min = 1, max = 100))]
    result_limit: u32,
    /// Project these fields on retained table rows.
    #[schemars(length(max = 16))]
    result_fields: Option<Vec<String>>,
    /// Luau to run. In an editor session this has plugin permissions, so `game`, `workspace` and plugin-only APIs are all reachable.
    #[schemars(length(min = 1))]
    source: Option<String>,
    /// 'studio' runs in the connected Studio, with plugin permissions. 'live' runs on Roblox's servers against the published place — production, with no undo. 'client' runs in a player's playtest client VM.
    #[serde(default)]
    target: ExecTarget,
    /// client only: player name; required with multiple players.
    player: Option<String>,
    /// live only: which game. Omit to use `cloud universe`.
    universe_id: Option<String>,
    /// live only: which place. Omit to use `cloud place`.
    place_id: Option<String>,
    /// live/client only: timeout in seconds. Defaults to 30.
    #[schemars(range(min = 1, max = 300))]
    timeout_seconds: Option<u32>,
    /// Required for target="live". This runs against the game people are playing and nothing here can undo it.
    confirm: Option<bool>,
    /// Target Studio; omit for the active one.
    studio_id: Option<String>,
}

#[derive(Deserialize, Serialize, JsonSchema)]
#[serde(untagged)]
enum PathKey {
    Key(String),
    Index(i64),
}

async fn execute_luau(ctx: Arc<Ctx>, a: ExecArgs) -> Result<ToolResult> {
    let studio = a.studio_id.as_deref();
    if let Some(id) = &a.result_id {
        if a.source.is_some() || a.target == ExecTarget::Live {
            return Err(ToolError::bad_params("Result retrieval requires source to be omitted and target studio or client."));
        }
        let result = call(
            &ctx,
            "exec.result",
            json!({
                "resultId": id, "resultPath": a.result_path, "resultOffset": a.result_offset,
                "resultLimit": a.result_limit, "resultFields": a.result_fields, "target": a.target, "player": a.player,
            }),
            studio,
            None,
        )
        .await?;
        return Ok(json(&result, None));
    }
    let Some(source) = a.source.as_deref() else {
        return Err(ToolError::bad_params("Provide source to execute, or resultId to retrieve retained output."));
    };
    if a.target == ExecTarget::Live {
        if a.confirm != Some(true) {
            return Err(ToolError::hint(
                "NEEDS_CONFIRM",
                "This would run against the published game, where people are playing.",
                "There is no undo and no recording. Read the script once more, then pass confirm: true.",
            ));
        }
        let credentials = cloud::require_credentials().await?;
        let universe = cloud::require_universe(a.universe_id.as_deref()).await?;
        let place = cloud::require_place(a.place_id.as_deref()).await?;
        cloud::assert_targets_open_place(
            &ctx.bridge,
            Target {
                universe_id: Some(&universe),
                place_id: Some(&place),
                explicit: a.universe_id.is_some() || a.place_id.is_some(),
                studio_id: studio,
            },
        )
        .await?;
        let result = cloud::luau::run(&credentials, &universe, &place, source, a.timeout_seconds.unwrap_or(30) as u64).await?;
        return Ok(json(&result, None));
    }

    let timeout = if a.target == ExecTarget::Client { (a.timeout_seconds.unwrap_or(30) as f64 + 10.0) * 1000.0 } else { 60_000.0 };
    let r = call(
        &ctx,
        "exec.run",
        json!({ "source": source, "target": a.target, "player": a.player, "timeoutSeconds": a.timeout_seconds }),
        studio,
        Some(timeout),
    )
    .await?;

    let ok = r.get("ok").and_then(Value::as_bool).unwrap_or(false);
    let mut parts: Vec<String> = Vec::new();
    let output = arr_of(&r, "output");
    if !output.is_empty() {
        let lines: Vec<String> = output
            .iter()
            .map(|l| format!("  [{}] {}", str_of(l, "level").unwrap_or(""), str_of(l, "message").unwrap_or("")))
            .collect();
        parts.push(format!("Output:\n{}", lines.join("\n")));
    }
    if ok {
        let returned = arr_of(&r, "returned");
        if !returned.is_empty() {
            let single = if returned.len() == 1 { returned[0].clone() } else { Value::Array(returned.to_vec()) };
            parts.push(format!("Returned:\n{}", stringify(&single)));
        }
        if parts.is_empty() {
            parts.push("Ran successfully. Nothing was printed or returned.".into());
        }
    } else {
        parts.push(format!("Error: {}", str_of(&r, "error").unwrap_or("unknown")));
    }
    if let Some(context) = str_of(&r, "context") {
        let vm = str_of(&r, "vm").map(str::to_string).or_else(|| (context == "client").then(|| "client".to_string()));
        let identity = str_of(&r, "identity").map(str::to_string).or_else(|| match vm.as_deref() {
            Some("client") => Some("script".into()),
            other => other.map(str::to_string),
        });
        parts.push(format!(
            "Context: {context}{}{}",
            str_of(&r, "player").map(|p| format!(" ({p})")).unwrap_or_default(),
            match vm {
                Some(vm) => format!("; VM={vm}, identity={}.", identity.unwrap_or_default()),
                None => ".".into(),
            }
        ));
    }
    if let Some(id) = str_of(&r, "resultId") {
        let mut line = format!(
            "Preview truncated. Retained resultId=\"{id}\" for 120s. Retrieve with source omitted; resultPath defaults to [\"returned\",1]."
        );
        if r.get("retainedTruncated") == Some(&Value::Bool(true)) {
            line.push_str(&format!(" Retention limit reached at: {}.", to_flat(r.get("omittedPaths").unwrap_or(&Value::Null))));
        }
        let not_retained = u64_of(&r, "outputNotRetained");
        if not_retained > 0 {
            line.push_str(&format!(" {not_retained} printed lines were not retained."));
        }
        parts.push(line);
    }
    if let Some(note) = str_of(&r, "note") {
        parts.push(format!("Note: {note}"));
    }
    let dropped = u64_of(&r, "outputDropped");
    if dropped > 0 {
        parts.push(format!("[{dropped} more printed lines left out; print less, or return a summary]"));
    }
    let returns = u64_of(&r, "returnsDropped");
    if returns > 0 {
        parts.push(format!("[{returns} more return values left out]"));
    }
    parts.push(format!("({}ms)", r.get("milliseconds").map(to_flat).unwrap_or_else(|| "0".into())));
    let body = parts.join("\n\n");
    Ok(if ok { text(body) } else { error_text(body) })
}

// --- UI snapshots ------------------------------------------------------------------

const MAX_SNAPSHOTS: usize = 20;
const SNAPSHOT_TTL_MS: u64 = 60 * 60 * 1000;

struct Snapshot {
    id: String,
    taken_at: u64,
    scope: String,
    root: String,
    screen: String,
    device: Option<String>,
    elements: Vec<Value>,
}

struct Snapshots {
    order: Vec<String>,
    map: HashMap<String, Arc<Snapshot>>,
    counter: u64,
}

static SNAPSHOTS: LazyLock<Mutex<Snapshots>> =
    LazyLock::new(|| Mutex::new(Snapshots { order: vec![], map: HashMap::new(), counter: 0 }));

fn store_snapshot(response: &Value, scope: String) -> Arc<Snapshot> {
    let now = crate::protocol::now_ms();
    let mut s = SNAPSHOTS.lock();
    let expired: Vec<String> = s.map.values().filter(|x| now - x.taken_at > SNAPSHOT_TTL_MS).map(|x| x.id.clone()).collect();
    for id in expired {
        s.map.remove(&id);
        s.order.retain(|o| o != &id);
    }
    while s.order.len() >= MAX_SNAPSHOTS {
        let oldest = s.order.remove(0);
        s.map.remove(&oldest);
    }
    s.counter += 1;
    let snapshot = Arc::new(Snapshot {
        id: format!("ui{}", s.counter),
        taken_at: now,
        scope,
        root: str_of(response, "root").unwrap_or("").into(),
        screen: str_of(response, "screen").unwrap_or("").into(),
        device: str_of(response, "device").map(str::to_string),
        elements: arr_of(response, "elements").to_vec(),
    });
    s.order.push(snapshot.id.clone());
    s.map.insert(snapshot.id.clone(), snapshot.clone());
    snapshot
}

struct UiChange {
    path: String,
    class: String,
    changes: Vec<(String, Option<Value>, Option<Value>)>,
}

struct UiDiff<'a> {
    added: Vec<&'a Value>,
    removed: Vec<&'a Value>,
    changed: Vec<UiChange>,
    unchanged: usize,
}

fn diff_snapshots<'a>(before: &'a Snapshot, after: &'a Snapshot) -> UiDiff<'a> {
    let old: HashMap<&str, &Value> = before.elements.iter().map(|e| (str_of(e, "path").unwrap_or(""), e)).collect();
    let mut seen = BTreeSet::new();
    let mut diff = UiDiff { added: vec![], removed: vec![], changed: vec![], unchanged: 0 };
    let empty = Map::new();
    for element in &after.elements {
        let path = str_of(element, "path").unwrap_or("");
        let class = str_of(element, "className").unwrap_or("");
        let Some(prev) = old.get(path).filter(|p| str_of(p, "className") == Some(class)) else {
            diff.added.push(element);
            continue;
        };
        seen.insert(path);
        let a = prev.get("props").and_then(Value::as_object).unwrap_or(&empty);
        let b = element.get("props").and_then(Value::as_object).unwrap_or(&empty);
        let names: BTreeSet<&String> = a.keys().chain(b.keys()).collect();
        let changes: Vec<(String, Option<Value>, Option<Value>)> = names
            .into_iter()
            .filter(|n| a.get(*n) != b.get(*n))
            .map(|n| ((*n).clone(), a.get(n).cloned(), b.get(n).cloned()))
            .collect();
        if changes.is_empty() {
            diff.unchanged += 1;
        } else {
            diff.changed.push(UiChange { path: path.into(), class: class.into(), changes });
        }
    }
    diff.removed = before.elements.iter().filter(|e| !seen.contains(str_of(e, "path").unwrap_or(""))).collect();
    diff
}

fn show(v: &Option<Value>) -> String {
    match v {
        None => "(none)".into(),
        Some(v @ (Value::Object(_) | Value::Array(_) | Value::String(_))) => to_flat(v),
        Some(v) => to_flat(v),
    }
}

fn render_diff(diff: &UiDiff, limit: usize) -> String {
    let mut lines = Vec::new();
    let mut budget = limit;
    let mut take = |n: usize| {
        let shown = n.min(budget);
        budget -= shown;
        shown
    };
    if !diff.removed.is_empty() {
        lines.push(format!("REMOVED ({})", diff.removed.len()));
        for e in diff.removed.iter().take(take(diff.removed.len())) {
            lines.push(format!("  {} ({})", str_of(e, "path").unwrap_or(""), str_of(e, "className").unwrap_or("")));
        }
    }
    if !diff.added.is_empty() {
        lines.push(format!("ADDED ({})", diff.added.len()));
        for e in diff.added.iter().take(take(diff.added.len())) {
            lines.push(format!("  {} ({})", str_of(e, "path").unwrap_or(""), str_of(e, "className").unwrap_or("")));
        }
    }
    if !diff.changed.is_empty() {
        lines.push(format!("CHANGED ({})", diff.changed.len()));
        for c in diff.changed.iter().take(take(diff.changed.len())) {
            lines.push(format!("  {} ({})", c.path, c.class));
            for (prop, before, after) in &c.changes {
                lines.push(format!("    {prop}: {} -> {}", show(before), show(after)));
            }
        }
    }
    let total = diff.removed.len() + diff.added.len() + diff.changed.len();
    if total > limit {
        lines.push(format!("[{} more elements left out; narrow `path`.]", total - limit));
    }
    lines.join("\n")
}

// --- viewport ---------------------------------------------------------------------

#[derive(Deserialize, JsonSchema, PartialEq, Clone, Copy)]
#[serde(rename_all = "lowercase")]
enum ViewOp {
    Select,
    Raycast,
    Focus,
    Camera,
    Textbounds,
    Ui,
    Uisnap,
    Pick,
}

#[derive(Deserialize, Serialize, JsonSchema, Default, Clone, Copy)]
#[serde(rename_all = "lowercase")]
enum SelectMode {
    #[default]
    Set,
    Add,
    Remove,
}

fn pad15() -> f64 {
    1.5
}
fn d1000() -> f64 {
    1000.0
}

#[derive(Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
struct ViewArgs {
    /// 'focus' points the camera at something and frames it, 'camera' sets it explicitly, 'select' changes the Studio selection, 'textbounds' measures rendered text, 'raycast' queries the world, 'ui' audits an interface, 'uisnap' snapshots one and diffs it against an earlier snapshot.
    op: ViewOp,
    /// focus: the instance to look at. ui/uisnap: the UI root to read. textbounds: the label.
    path: Option<String>,
    /// focus only: look at this point instead of an instance, e.g. "0, 10, 0".
    at: Option<String>,
    /// focus only: direction to view from, e.g. "0, 1, 0" for directly above or "1, 0, 0" from the side. Defaults to a raised three-quarter view.
    from: Option<String>,
    /// focus only: how much room to leave around the subject. 1 is tight.
    #[serde(default = "pad15")]
    #[schemars(range(min = 1, max = 5))]
    padding: f64,
    /// camera only: where to put the camera, e.g. "0, 20, 30".
    position: Option<String>,
    /// camera only: the point to aim at.
    look_at: Option<String>,
    /// camera only: field of view in degrees. Lower is more zoomed in.
    #[schemars(range(min = 1, max = 120))]
    field_of_view: Option<f64>,
    /// select only: instances to select. An empty array clears the selection.
    paths: Option<Vec<String>>,
    /// select only: replace the selection, extend it, or remove from it.
    #[serde(default)]
    mode: SelectMode,
    /// raycast only: where the ray starts, e.g. "0, 50, 0".
    origin: Option<String>,
    /// raycast only: which way it points, e.g. "0, -1, 0" for straight down.
    direction: Option<String>,
    /// raycast only: how far to look, in studs.
    #[serde(default = "d1000")]
    #[schemars(range(min = 0.000001))]
    max_distance: f64,
    /// raycast only: instances the ray passes through.
    ignore: Option<Vec<String>>,
    /// textbounds only: the string to measure. Defaults to the label's own text.
    text: Option<String>,
    /// textbounds only: font size in pixels. Defaults to the label's.
    #[schemars(range(min = 1, max = 200))]
    text_size: Option<f64>,
    /// textbounds only: an Enum.Font name, e.g. "GothamMedium". Defaults to the label's.
    font: Option<String>,
    /// textbounds only: wrap at this width. 0 means do not wrap. Defaults to the label's width.
    #[schemars(range(min = 0))]
    wrap_width: Option<f64>,
    #[serde(flatten)]
    read: ReadTarget,
    /// pick: normalized X in the full uncropped viewport.
    #[schemars(range(min = 0, max = 1))]
    x: Option<f64>,
    /// pick: normalized Y in the full uncropped viewport.
    #[schemars(range(min = 0, max = 1))]
    y: Option<f64>,
    /// textbounds only: treat the text as rich text. Defaults to the label's setting.
    rich_text: Option<bool>,
    /// uisnap only: id of an earlier snapshot to diff the new one against.
    compare_to: Option<String>,
    /// Target Studio; omit for the active one.
    studio_id: Option<String>,
}

fn screen_label(screen: &str, device: Option<&str>) -> String {
    format!("{screen}{}", device.map(|d| format!(" {d}")).unwrap_or_default())
}

async fn viewport(ctx: Arc<Ctx>, a: ViewArgs) -> Result<ToolResult> {
    let studio = a.studio_id.as_deref();
    let client = a.read.target == ReadSide::Client;
    if client && !matches!(a.op, ViewOp::Ui | ViewOp::Uisnap | ViewOp::Raycast | ViewOp::Pick) {
        return Err(ToolError::new("BAD_TARGET", "Client viewport reads support ui, uisnap, raycast and pick."));
    }
    match a.op {
        ViewOp::Pick => {
            let (Some(x), Some(y)) = (a.x, a.y) else { return Err(ToolError::bad_params("pick requires normalized x and y.")) };
            let r = read_call(&ctx, "viewport.pick", json!({ "x": x, "y": y, "maxDistance": a.max_distance, "ignore": a.ignore }), &a.read, studio, 30_000.0).await?;
            Ok(json(&r, a.read.context().as_deref()))
        }
        ViewOp::Focus => {
            if a.path.is_none() && a.at.is_none() {
                return Ok(error_text("focus needs a `path` to look at, or an `at` position."));
            }
            let r = call(&ctx, "viewport.focus", json!({ "path": a.path, "at": a.at, "from": a.from, "padding": a.padding }), studio, None).await?;
            Ok(json(&r, Some("Take a `screenshot` to see it.")))
        }
        ViewOp::Camera => {
            let r = call(&ctx, "viewport.camera", json!({ "position": a.position, "lookAt": a.look_at, "fieldOfView": a.field_of_view }), studio, None).await?;
            Ok(json(&r, None))
        }
        ViewOp::Ui => {
            let audit = read_call(&ctx, "viewport.ui", json!({ "path": a.path }), &a.read, studio, 45_000.0).await?;
            let device = str_of(&audit, "device");
            let checked = u64_of(&audit, "checked");
            let where_ = format!(
                "{}{} on a {} screen{}",
                if client { "actual client: " } else { "" },
                str_of(&audit, "root").unwrap_or(""),
                str_of(&audit, "screen").unwrap_or(""),
                device.map(|d| format!(" (emulating {d})")).unwrap_or_default()
            );
            let findings = arr_of(&audit, "findings");
            if findings.is_empty() {
                return Ok(text(format!(
                    "No problems found — {checked} visible elements checked, {where_}.{}",
                    if device.is_none() {
                        "\n\nThis was the desktop viewport. Run it again after `device op=\"set\"` with a phone — most interface faults only appear on a small screen."
                    } else {
                        ""
                    }
                )));
            }
            // Grouped by issue: twenty findings of four kinds is four things to fix.
            let mut order: Vec<&str> = Vec::new();
            let mut groups: HashMap<&str, Vec<&Value>> = HashMap::new();
            for f in findings {
                let issue = str_of(f, "issue").unwrap_or("");
                if !groups.contains_key(issue) {
                    order.push(issue);
                }
                groups.entry(issue).or_default().push(f);
            }
            let blocks: Vec<String> = order
                .iter()
                .map(|issue| {
                    let rows = &groups[issue];
                    let lines: Vec<String> = rows
                        .iter()
                        .map(|r| format!("  {} — {}", str_of(r, "path").unwrap_or(""), str_of(r, "detail").unwrap_or("")))
                        .collect();
                    format!("{} ({})\n{}", issue.to_uppercase(), rows.len(), lines.join("\n"))
                })
                .collect();
            let mut notes = vec![format!("{checked} visible elements checked, {} hidden skipped, {where_}.", u64_of(&audit, "hidden"))];
            if device.is_none() {
                notes.push("Run again after `device op=\"set\"` with a phone — this is the desktop layout.".into());
            }
            let omitted = u64_of(&audit, "omitted");
            if omitted > 0 {
                notes.push(format!("{omitted} additional findings omitted; narrow path."));
            }
            if audit.get("overlapStopped") == Some(&Value::Bool(true)) {
                notes.push("Overlap checking stopped early; there were too many sibling pairs.".into());
            }
            Ok(text(format!("{}\n\n{}", blocks.join("\n\n"), notes.join(" "))))
        }
        ViewOp::Uisnap => {
            let before = match &a.compare_to {
                None => None,
                Some(id) => match SNAPSHOTS.lock().map.get(id).cloned() {
                    Some(s) => Some(s),
                    None => {
                        return Err(ToolError::hint(
                            "NO_SNAPSHOT",
                            format!("No UI snapshot {id}. Snapshots last an hour and only the latest 20 are kept."),
                            "Take a new one with `viewport op=\"uisnap\"`.",
                        ));
                    }
                },
            };
            let scope = format!(
                "{}|{}|{}",
                studio.unwrap_or("active"),
                if client { "client" } else { "studio" },
                a.read.player.as_deref().unwrap_or("")
            );
            let response = read_call(&ctx, "viewport.uisnap", json!({ "path": a.path }), &a.read, studio, 45_000.0).await?;
            let omitted_count = u64_of(&response, "omitted");
            let taken = store_snapshot(&response, scope.clone());
            let where_ = format!(
                "{} on a {} screen{}",
                taken.root,
                taken.screen,
                taken.device.as_ref().map(|d| format!(" (emulating {d})")).unwrap_or_default()
            );
            let omitted = if omitted_count > 0 {
                format!(" {omitted_count} more elements past the limit were not recorded; narrow `path`.")
            } else {
                String::new()
            };
            let Some(before) = before else {
                return Ok(text(format!(
                    "Snapshot {}: {} UI elements under {where_}.{omitted}\nAfter changing the UI, call `viewport op=\"uisnap\" compareTo=\"{}\"` to see what changed.",
                    taken.id,
                    taken.elements.len(),
                    taken.id
                )));
            };
            let mut notes = Vec::new();
            if before.scope != scope {
                notes.push(format!("{} was taken in a different session or client; paths may not line up.", before.id));
            }
            if before.root != taken.root {
                notes.push(format!("{} covered {}, this one {}.", before.id, before.root, taken.root));
            }
            if before.screen != taken.screen || before.device != taken.device {
                notes.push(format!(
                    "The screen changed ({} -> {}), so absolute positions and sizes move with it.",
                    screen_label(&before.screen, before.device.as_deref()),
                    screen_label(&taken.screen, taken.device.as_deref())
                ));
            }
            let diff = diff_snapshots(&before, &taken);
            let total = diff.changed.len() + diff.added.len() + diff.removed.len();
            let summary = format!(
                "{} -> {} ({where_}): {} changed, {} added, {} removed, {} unchanged.{omitted}",
                before.id,
                taken.id,
                diff.changed.len(),
                diff.added.len(),
                diff.removed.len(),
                diff.unchanged
            );
            let mut parts = vec![summary, if total == 0 { "No differences.".into() } else { render_diff(&diff, 60) }];
            parts.extend(notes);
            Ok(text(parts.join("\n\n")))
        }
        ViewOp::Textbounds => {
            let m = call(
                &ctx,
                "viewport.textbounds",
                json!({
                    "path": a.path, "text": a.text, "size": a.text_size, "font": a.font,
                    "width": a.wrap_width, "richText": a.rich_text,
                }),
                studio,
                None,
            )
            .await?;
            let n = |k: &str| m.get(k).map(to_flat).unwrap_or_else(|| "undefined".into());
            let mut lines = vec![format!("{} x {} px  ({}, {}px)", n("width"), n("height"), str_of(&m, "font").unwrap_or(""), n("size"))];
            if m.get("wrappedAt").and_then(Value::as_f64).is_some_and(|w| w != 0.0) {
                lines.push(format!("Wrapped at {}px.", n("wrappedAt")));
            }
            if let Some(b) = str_of(&m, "box") {
                lines.push(if m.get("fits") == Some(&Value::Bool(true)) {
                    format!("Fits inside {b}.")
                } else {
                    format!("DOES NOT FIT in {b} — over by {}px wide, {}px tall.", n("overflowX"), n("overflowY"))
                });
            }
            Ok(text(lines.join("\n")))
        }
        ViewOp::Raycast => {
            let (Some(origin), Some(direction)) = (&a.origin, &a.direction) else {
                return Ok(error_text(
                    "raycast needs `origin` and `direction`.\nFor example origin \"0, 100, 0\" and direction \"0, -1, 0\" to find the ground below a point.",
                ));
            };
            let r = read_call(
                &ctx,
                "viewport.raycast",
                json!({ "origin": origin, "direction": direction, "maxDistance": a.max_distance, "ignore": a.ignore }),
                &a.read,
                studio,
                30_000.0,
            )
            .await?;
            if r.get("hit") != Some(&Value::Bool(true)) {
                return Ok(text(format!(
                    "Nothing within {} studs along that ray.\nCheck the direction points the way you expect, or raise `maxDistance`.",
                    to_flat(&json!(a.max_distance))
                )));
            }
            Ok(json(&r, None))
        }
        ViewOp::Select => {
            let r = call(&ctx, "viewport.select", json!({ "paths": a.paths.unwrap_or_default(), "mode": a.mode }), studio, None).await?;
            let count = u64_of(&r, "count");
            if count == 0 {
                return Ok(text("Selection cleared."));
            }
            Ok(table(
                &["path", "className"],
                arr_of(&r, "items"),
                PageMeta { total: Some(count), more: Some(format!("{count} selected in Studio")), ..Default::default() },
            ))
        }
    }
}

pub fn tools() -> Vec<Tool> {
    vec![
        define(
            spec("execute_luau", "Run Luau in Studio").destructive(true),
            "Runs Luau in Studio's plugin context and returns whatever it printed, returned, or threw.\n\n\
             This is the escape hatch. Reach for it only when no dedicated tool fits — `create`, `modify`, `delete`, \
             `move`, `script_edit` and `find` validate their input, type values from the live API dump, and wrap writes \
             in an undo recording. Code run here does none of that, so a typo becomes a runtime error instead of a \
             suggestion, and changes it makes may not be undoable as one step.\n\n\
             Good uses: reading something no tool exposes, a one-off calculation over many instances, or calling an \
             engine API the tools do not cover.\n\n\
             Output printed while it runs is captured and returned, so `print` is a reasonable way to get values out. \
             `return` works too, including returning a table — it comes back as a structure, not a summary. There is \
             no timeout for target=\"studio\": an infinite loop will hang Studio until it is force-quit.\n\n\
             Against a running playtest server, Studio disables `loadstring`, so the code is compiled through a \
             ModuleScript instead and runs at script identity — plugin-only APIs are unavailable there. When that \
             happens it is stated in the result rather than left to be inferred from a failure.\n\n\
             With target=\"studio\", do not use `require` to read live state out of a running game. This runs in the \
             plugin's own Luau VM with its own module cache, so `require` here returns a second, freshly-initialised \
             copy of the ModuleScript — its counters and caches read as empty while the real one is running fine, and a \
             zero is indistinguishable from a genuine zero. Read live state off the DataModel instead (instances, \
             attributes, properties), or have the game print it and read that with `console`. The result warns when a \
             call could have hit this.\n\n\
             `target=\"client\"` runs in the selected player's actual playtest client VM, including its live require \
             cache. Requires a running playtest server studioId. Output is capped at 200 lines, 10 returns, table depth \
             4 and 50 entries. The relay is removed on completion or timeout; non-yielding code can still stall the \
             client. Connections/hooks created by the temporary relay (such as Connect or RenderStepped) do not persist \
             after the call returns.\n\n\
             `target=\"live\"` runs the script on Roblox's servers against the PUBLISHED place instead, with no Studio \
             involved. That is how you read or repair production: a real player's data store entry, what the live game \
             actually holds, a migration over saved data. Everything the script prints comes back in `logs`.\n\n\
             BE CAREFUL WITH IT. The Studio path has an undo stack and a place nobody is playing. This one touches live \
             data and live players, and nothing here can put any of it back — so it needs `confirm: true` and you should \
             read before you write. Roblox queues it as a task, so expect seconds, not milliseconds, and a `state` of \
             COMPLETE or FAILED rather than a bare value.",
            execute_luau,
        ),
        define(
            spec("viewport", "Viewport and selection").destructive(false).idempotent(true),
            "Works with the 3D view and the Studio selection.\n\n\
             `select` sets, extends or shrinks what is highlighted in Studio. Select what you just built or changed — it \
             shows the user the result, and puts the instance under Studio's own move and scale handles. \
             `studio_status` reports the current selection; this sets it.\n\n\
             `focus` aims the Studio camera at an instance and frames it so the whole thing is on screen. This is what \
             makes `screenshot` worth having: a picture of wherever the camera happened to be answers nothing, while a \
             picture of the thing you just built answers 'does it look right', which no amount of reading properties \
             can. Build, focus, screenshot.\n\n\
             The distance is computed from the subject's size and the camera's field of view, so a doorway and a whole \
             map both arrive filling a similar share of the frame. `from` changes the angle you view it from, and \
             `padding` how tightly it is framed.\n\n\
             `camera` sets or reads the camera directly, for shots framing cannot express — standing inside a room, or \
             looking along a corridor.\n\n\
             `raycast` fires a ray through the world and reports the first thing it hits, with position, surface \
             normal, distance and material. This answers 'what occupies this space', which the data model alone cannot: \
             use it to find the ground under a spawn point, or check whether a gap is clear before placing something.\n\n\
             `ui` audits a whole interface for the faults that are invisible in the data model: elements off the side \
             of the screen, elements covering each other, zero-size elements, text too small to read, and text that \
             overflows its label. A button positioned off a phone screen has a perfectly correct Position and Size — \
             nothing about the instance is wrong, it is just somewhere nobody can reach.\n\n\
             It measures against whatever `device` is currently emulating, so the way to use it is twice: once as-is, \
             then `device op=\"set\"` a phone and again. Layout is live in edit mode — no playtest needed.\n\n\
             `textbounds` measures how big a piece of text actually renders. Point it at a TextLabel, TextButton or \
             TextBox with `path` and it reads that label's own text, font, size and width and answers whether the text \
             fits inside it. Give `text` and `size` directly and it just measures. There is no other honest way to \
             answer 'will this label overflow' — character counts ignore the font, and font size is not a width.\n\n\
             `uisnap` records every UI element under `path` (default StarterGui, or the PlayerGui with \
             target=\"client\"): layout, absolute position and size, colours, fonts, text, images, strokes, corners and \
             padding, and returns a snapshot id. Take one before restyling a UI, then call `uisnap` again with \
             `compareTo` set to that id: the reply lists what was added, removed and changed, property by property, \
             including what you did not mean to touch. Every call stores a new id, so passes chain.",
            viewport,
        ),
    ]
}
