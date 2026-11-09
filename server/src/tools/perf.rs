//! console and performance.

use super::{ReadSide, ReadTarget, arr_of, call, d, read_call, str_of, u64_of};
use crate::errors::{Result, ToolError};
use crate::format::{PageMeta, ToolResult, json, table, text, to_flat};
use crate::tool::{Ctx, Tool, define, spec};
use schemars::JsonSchema;
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value, json};
use std::sync::Arc;

/// `String(value)` as JavaScript prints it: strings bare, numbers without `.0`.
fn num(v: &Value, key: &str) -> String {
    super::disp(v.get(key))
}

fn f64_of(v: &Value, key: &str) -> f64 {
    v.get(key).and_then(Value::as_f64).unwrap_or(0.0)
}

#[derive(Deserialize, Serialize, JsonSchema, Default, PartialEq, Clone, Copy)]
#[serde(rename_all = "lowercase")]
enum TailMode {
    #[default]
    Tail,
    Drain,
}

#[derive(Deserialize, Serialize, JsonSchema, Clone, Copy)]
#[serde(rename_all = "lowercase")]
enum Level {
    Print,
    Info,
    Warning,
    Error,
}

#[derive(Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
struct ConsoleArgs {
    /// Output source; client requires a running playtest server studioId.
    #[serde(default)]
    target: ReadSide,
    /// Client only: player name, required when multiple players are present.
    player: Option<String>,
    /// Opaque nextCursor from a previous console response; return only newer matching lines.
    since: Option<String>,
    /// 'tail': the newest matches, cursor at the end of the log. 'drain': the oldest unread matches, cursor at the first one not shown, so a loop reads every line once.
    #[serde(default)]
    mode: TailMode,
    /// Collapse identical lines into one row with a count and first/last times.
    #[serde(default)]
    group: bool,
    /// Only this severity. Omit for everything.
    level: Option<Level>,
    /// Lua pattern the message must match, e.g. "Combat" or "^%[Server%]". Lua patterns escape with %, not backslash.
    pattern: Option<String>,
    #[serde(default = "d::page")]
    #[schemars(schema_with = "super::page_limit_schema")]
    limit: u32,
    /// Target Studio; omit for the active one.
    studio_id: Option<String>,
}

async fn console(ctx: Arc<Ctx>, a: ConsoleArgs) -> Result<ToolResult> {
    let client = a.target == ReadSide::Client;
    let r = call(
        &ctx,
        "perf.console",
        json!({
            "level": a.level, "pattern": a.pattern, "limit": a.limit, "target": a.target, "player": a.player,
            "since": a.since, "mode": a.mode, "group": a.group,
        }),
        a.studio_id.as_deref(),
        None,
    )
    .await?;
    let items = arr_of(&r, "items");
    let next = num(&r, "nextCursor");
    let evicted = u64_of(&r, "evicted");
    if items.is_empty() {
        let window = match (a.since.is_none(), r.get("recordingSeconds").filter(|v| !v.is_null())) {
            (true, Some(s)) => format!(
                " This session has been recording for {}s, since its plugin loaded; anything logged before that is not recoverable.",
                to_flat(s)
            ),
            _ => String::new(),
        };
        let lead = if a.level.is_some() || a.pattern.is_some() {
            "No output matched. Try dropping the filter, or run a playtest first."
        } else if a.since.is_some() {
            "No newer output matched."
        } else {
            "Nothing has been logged in this session."
        };
        return Ok(text(format!(
            "{lead}{window}{}{}\n[nextCursor: {next}]",
            if client && r.get("capturing") == Some(&Value::Bool(false)) { " The client diagnostic relay is still connecting." } else { "" },
            if evicted > 0 { format!(" {evicted} older lines were evicted.") } else { String::new() },
        )));
    }

    let mut lines: Vec<String> = items
        .iter()
        .map(|e| {
            let when = match (client, e.get("timestamp").and_then(Value::as_f64)) {
                (true, Some(ts)) if ts != 0.0 => format!(" {}", crate::tools::iso((ts * 1000.0) as u64)),
                _ => String::new(),
            };
            let count = e.get("count").and_then(Value::as_u64).filter(|c| *c > 1).map(|c| format!("  (x{c})")).unwrap_or_default();
            let context = str_of(e, "context").filter(|c| !c.is_empty()).map(|c| format!("\n    context: {c}")).unwrap_or_default();
            let head = format!(
                "[{}{}{when}] {}{count}{context}",
                str_of(e, "level").unwrap_or(""),
                if e.get("updated") == Some(&Value::Bool(true)) { " update" } else { "" },
                str_of(e, "message").unwrap_or("")
            );
            let origin = str_of(e, "source").filter(|s| !s.is_empty()).map(|s| format!("\n    in {s}")).unwrap_or_default();
            let trace: Vec<String> = str_of(e, "stack")
                .unwrap_or("")
                .split('\n')
                .map(str::trim)
                .filter(|l| !l.is_empty())
                .map(|l| format!("    at {l}"))
                .collect();
            if trace.is_empty() { format!("{head}{origin}") } else { format!("{head}{origin}\n{}", trace.join("\n")) }
        })
        .collect();
    let mut notes: Vec<String> = Vec::new();
    // Newest complete entries under budget; never while draining (the cursor counts them read).
    let mut omitted = 0;
    let mut size: usize = lines.iter().map(|l| l.len() + 1).sum();
    while a.mode != TailMode::Drain && lines.len() > 1 && size > 20_000 {
        size -= lines.remove(0).len() + 1;
        omitted += 1;
    }
    if lines.len() == 1 && lines[0].len() > 20_000 {
        lines[0] = format!("{}… [entry truncated]", crate::format::clip_chars(&lines[0], 19_900));
    }
    if omitted > 0 {
        notes.push(format!("{omitted} older matching lines omitted to fit the response"));
    }
    if r.get("hasMore") == Some(&Value::Bool(true)) {
        notes.push("more unread lines: call again with this cursor and the same filters".into());
    }
    if u64_of(&r, "dropped") > 0 {
        notes.push(format!("showing the newest {} of {} matching lines", items.len(), num(&r, "total")));
    }
    if evicted > 0 {
        notes.push(format!("{evicted} older lines have fallen out of the buffer and cannot be recovered"));
    }
    let lead = if notes.is_empty() { String::new() } else { format!("{}; ", notes.join("; ")) };
    Ok(text(format!("{}\n\n[{lead}nextCursor: {next}]", lines.join("\n"))))
}

#[derive(Deserialize, JsonSchema, Default, PartialEq, Clone, Copy)]
#[serde(rename_all = "lowercase")]
enum PerfOp {
    #[default]
    Snapshot,
    Profile,
    Microprofile,
    Coverage,
    Scene,
    Audit,
}

#[derive(Deserialize, Serialize, JsonSchema, Clone, Copy)]
#[serde(rename_all = "camelCase")]
enum Section {
    Composition,
    Triangles,
    ScriptMemory,
    AnimationMemory,
    AudioMemory,
    Unparented,
}

#[derive(Deserialize, Serialize, JsonSchema, Default, Clone, Copy)]
#[serde(rename_all = "lowercase")]
enum SortBy {
    #[default]
    #[serde(rename = "self")]
    SelfTime,
    Total,
}

fn d5() -> u32 {
    5
}
fn d1000() -> u32 {
    1000
}
fn d64() -> u32 {
    64
}
fn d20() -> u32 {
    20
}

#[derive(Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
struct PerfArgs {
    #[serde(flatten)]
    read: ReadTarget,
    /// 'snapshot' reads counters now; 'profile' samples running scripts; 'microprofile' captures MicroProfiler frames (engine scopes on every thread); 'coverage' reports which lines have executed; 'scene' breaks the place down by what it is made of; 'audit' finds broken asset references and other silent faults.
    #[serde(default)]
    op: PerfOp,
    /// scene only: return just one section instead of all six.
    section: Option<Section>,
    /// coverage only: scripts to start measuring. Remembered for this place and switched on by every session that loads afterwards, so a playtest instruments them before its scripts run. An empty array stops instrumenting.
    enable: Option<Vec<String>>,
    /// profile only: how long to sample. The call blocks for this long.
    #[serde(default = "d5")]
    #[schemars(range(min = 1, max = 30))]
    seconds: u32,
    /// profile only: samples per second. Higher is more precise and costlier.
    #[serde(default = "d1000")]
    #[schemars(range(min = 100, max = 10000))]
    frequency: u32,
    /// profile only: include Studio plugins in the results. Off by default — an idle Studio is mostly plugin activity, which buries the place's own scripts.
    #[serde(default)]
    include_plugins: bool,
    /// microprofile only: how many recent frames to capture.
    #[serde(default = "d64")]
    #[schemars(range(min = 4, max = 256))]
    frames: u32,
    /// microprofile only: scopes to list.
    #[serde(default = "d20")]
    #[schemars(range(min = 1, max = 60))]
    top: u32,
    /// microprofile only: keep scopes whose name or group contains this, e.g. "Physics" or "Script".
    filter: Option<String>,
    /// microprofile only: walk only threads whose name contains this, e.g. "RBX Main".
    thread: Option<String>,
    /// microprofile only: rank by self time (where work happened) or total (including children).
    #[serde(default)]
    sort: SortBy,
    /// microprofile only: keep Sleep/Wait scopes, hidden by default because they are the absence of work.
    #[serde(default)]
    include_idle: bool,
    /// microprofile only: also save the capture as an .x.html file and return its path.
    #[serde(default)]
    export: bool,
    /// microprofile only: leave the MicroProfiler on afterwards instead of switching it off.
    #[serde(default)]
    keep_running: bool,
    /// Target Studio; omit for the active one.
    studio_id: Option<String>,
}

/// Plugin frames: `IsPlugin` marks only the root, so the source prefix decides.
fn is_plugin_frame(entry: &Value) -> bool {
    entry.get("IsPlugin") == Some(&Value::Bool(true))
        || str_of(entry, "Source").is_some_and(|s| s.starts_with("cloud_") || s.starts_with("user_") || s.starts_with("builtin_"))
}

async fn coverage(ctx: &Ctx, a: &PerfArgs) -> Result<ToolResult> {
    let r = call(ctx, "perf.coverage", json!({ "enable": a.enable }), a.studio_id.as_deref(), None).await?;
    if let Some(raw) = r.get("raw").filter(|v| !v.is_null()) {
        return Ok(json(
            raw,
            Some("Coverage came back in an unrecognised shape, so it is shown as Studio returned it rather than summarised into numbers that might be wrong."),
        ));
    }
    let strings = |key: &str| -> Vec<String> { arr_of(&r, key).iter().filter_map(Value::as_str).map(str::to_string).collect() };
    let stopping = a.enable.as_ref().is_some_and(Vec::is_empty);
    let scripts = arr_of(&r, "scripts");
    if scripts.is_empty() {
        let enabled = strings("enabled");
        let pending = strings("remembered");
        let lead = if !enabled.is_empty() {
            format!(
                "Coverage is on for {} script(s): {}.\nNothing has been recorded yet, which is expected — instrumentation only \
                 collects while the code runs. Start the playtest, then read coverage back from the PLAYTEST's studioId; \
                 this editor session never runs that code.",
                enabled.len(),
                enabled.join(", ")
            )
        } else {
            format!(
                "No coverage recorded in this session.\n{}A script that starts with the place can never be measured by the \
                 session that loaded it. Modules required later can be: enable them, start the playtest, then read from \
                 the playtest's studioId.",
                if pending.is_empty() {
                    "Nothing is instrumented for this place. Pass `enable` with the scripts you want measured.\n".to_string()
                } else {
                    format!(
                        "Instrumentation is remembered for: {}.\nAn empty result means either that this code has not run yet, or \
                         that it was already compiled when instrumentation was switched on — Luau binds coverage at first \
                         compile and keeps that bytecode. The two look identical from here.\n",
                        pending.join(", ")
                    )
                }
            )
        };
        let stopped = if stopping {
            "\nInstrumentation is now off for this place: no future session will switch it on. Scripts already \
             instrumented in a running session keep reporting until it ends."
        } else {
            ""
        };
        let carried = strings("carriedOver");
        let carried = if carried.is_empty() { String::new() } else { format!("\nThis session instrumented at load: {}.", carried.join(", ")) };
        let failed: Vec<String> = arr_of(&r, "carriedFailed")
            .iter()
            .map(|e| format!("{} ({})", str_of(e, "path").unwrap_or(""), str_of(e, "error").unwrap_or("")))
            .collect();
        let failed = if failed.is_empty() { String::new() } else { format!("\nFailed to instrument: {}.", failed.join("; ")) };
        return Ok(text(format!("{lead}{stopped}{carried}{failed}")));
    }
    let summary = table(
        &["path", "coveredLines", "instrumentedLines", "percent"],
        scripts,
        PageMeta { more: Some("instrumented lines only; blanks, comments and `end` are excluded".into()), ..Default::default() },
    )
    .text_of();
    let mut sections = vec![summary];
    if stopping {
        sections.push(
            "Coverage will not be switched on for this place again. The figures above are from scripts this session \
             already instrumented, which keep reporting until it ends — instrumentation is fixed at first compile and \
             cannot be removed."
                .into(),
        );
    }
    let misses: Vec<String> = scripts
        .iter()
        .filter_map(|e| {
            let lines = arr_of(e, "uncoveredLines");
            (!lines.is_empty()).then(|| {
                format!("  {}: {}", str_of(e, "path").unwrap_or(""), lines.iter().map(to_flat).collect::<Vec<_>>().join(", "))
            })
        })
        .collect();
    if !misses.is_empty() {
        sections.push(format!("Lines never executed:\n{}", misses.join("\n")));
    }
    let unmeasured: Vec<&str> =
        scripts.iter().filter(|e| e.get("notMeasurable") == Some(&Value::Bool(true))).filter_map(|e| str_of(e, "path")).collect();
    if !unmeasured.is_empty() {
        sections.push(format!(
            "Not measurable, reported as 0 lines: {}.\nStudio holds a coverage record for these but instrumented no line of \
             them, so nothing about them was measured. Read it as no data, never as dead code — 0 of 0 lines is not 0 of \
             many. If you need them covered, enable them and start a fresh playtest so they are instrumented before they \
             first compile.",
            unmeasured.join(", ")
        ));
    }
    Ok(text(sections.join("\n\n")))
}

async fn audit(ctx: &Ctx, a: &PerfArgs) -> Result<ToolResult> {
    // Every asset is fetched before it can be judged.
    let f = call(ctx, "perf.audit", json!({}), a.studio_id.as_deref(), Some(120_000.0)).await?;
    let mut blocks = Vec::new();
    let dead = arr_of(&f, "dead");
    if !dead.is_empty() {
        let rows: Vec<String> = dead
            .iter()
            .map(|r| format!("  {}.{} = {}", str_of(r, "path").unwrap_or(""), str_of(r, "property").unwrap_or(""), num(r, "id")))
            .collect();
        blocks.push(format!("DEAD ASSET IDS ({}) — these point at nothing and fail silently\n{}", num(&f, "deadCount"), rows.join("\n")));
    }
    let unset = arr_of(&f, "unset");
    if !unset.is_empty() {
        let rows: Vec<String> =
            unset.iter().take(20).map(|r| format!("  {}.{}", str_of(r, "path").unwrap_or(""), str_of(r, "property").unwrap_or(""))).collect();
        blocks.push(format!(
            "BLANK IDS ({})\n{}{}",
            num(&f, "unsetCount"),
            rows.join("\n"),
            if unset.len() > 20 { format!("\n  …and {} more", unset.len() - 20) } else { String::new() }
        ));
    }
    let disabled: Vec<&str> = arr_of(&f, "disabledScripts").iter().filter_map(Value::as_str).collect();
    if !disabled.is_empty() {
        blocks.push(format!("DISABLED SCRIPTS ({})\n  {}", disabled.len(), disabled.join("\n  ")));
    }
    let dupes: Vec<&str> = arr_of(&f, "duplicateNames").iter().filter_map(Value::as_str).collect();
    if !dupes.is_empty() {
        blocks.push(format!(
            "SAME-NAMED SIBLINGS ({}) — scripts, remotes or GUI that code looks up by name; WaitForChild picks one at random\n  {}",
            dupes.len(),
            dupes.join("\n  ")
        ));
    }
    let tail = format!(
        "{} asset reference(s) found; {} fetched and tested.{}{}",
        num(&f, "scanned"),
        num(&f, "checked"),
        if f.get("truncated") == Some(&Value::Bool(true)) { " Stopped at the cap — there are more in this place." } else { "" },
        if f.get("incomplete") == Some(&Value::Bool(true)) {
            " The fetch did not finish in time, so assets that had not arrived were left out rather than called broken — a clean result here is not proof."
        } else {
            ""
        }
    );
    Ok(text(if blocks.is_empty() { format!("Nothing broken found. {tail}") } else { format!("{}\n\n{tail}", blocks.join("\n\n")) }))
}

const SCENE_ORDER: [&str; 6] = ["composition", "triangles", "scriptMemory", "animationMemory", "audioMemory", "unparented"];

fn count(value: &Value, unit: &str) -> String {
    let v = to_flat(value);
    let unit = if value.as_f64() == Some(1.0) { unit.strip_suffix('s').unwrap_or(unit) } else { unit };
    format!("{v} {unit}")
}

async fn scene(ctx: &Ctx, a: &PerfArgs) -> Result<ToolResult> {
    let r = call(ctx, "perf.scene", json!({ "section": a.section }), a.studio_id.as_deref(), Some(45_000.0)).await?;
    let Some(map) = r.as_object() else { return Ok(json(&r, None)) };
    let mut ordered: Vec<(&String, &Value)> = map.iter().collect();
    ordered.sort_by_key(|(k, _)| SCENE_ORDER.iter().position(|o| o == k).map(|p| p as i64).unwrap_or(-1));
    let mut blocks = Vec::new();
    for (name, section) in ordered {
        if let Some(err) = section.get("error").filter(|e| !e.is_null()) {
            blocks.push(format!("{name}: unavailable ({})", err.as_str().map(str::to_string).unwrap_or_else(|| to_flat(err))));
            continue;
        }
        let unit = str_of(section, "unit").unwrap_or("");
        let total = section.get("total").cloned().unwrap_or(json!(0));
        let measured = match section.get("totals").and_then(Value::as_object) {
            Some(totals) => format!("{name} — {}", totals.iter().map(|(k, v)| count(v, &k.to_lowercase())).collect::<Vec<_>>().join(", ")),
            None => format!("{name} — {}", count(&total, unit)),
        };
        let heading = if name == "triangles" {
            format!("{measured}  — for what the camera can currently see, not the whole place; frame it with `viewport op=\"focus\"` first")
        } else {
            measured
        };
        let entries = arr_of(section, "entries");
        if entries.is_empty() {
            blocks.push(format!(
                "{heading}\n  {}",
                if total.as_f64().unwrap_or(0.0) > 0.0 { "(counted, but the engine did not break it down)" } else { "(nothing)" }
            ));
            continue;
        }
        let shown = &entries[..entries.len().min(120)];
        let depth = |e: &Value| e.get("depth").and_then(Value::as_u64).unwrap_or(0);
        let has = |e: &Value, k: &str| e.get(k).is_some_and(|v| !v.is_null());
        let render = |e: &Value| -> String {
            let indent = "  ".repeat(depth(e) as usize);
            let size = if has(e, "size") {
                format!(" — {}", count(&e["size"], unit))
            } else if has(e, "triangles") {
                format!(" — {}, {}", count(&e["triangles"], "triangles"), count(e.get("drawcalls").unwrap_or(&json!(0)), "draw calls"))
            } else {
                String::new()
            };
            let owners: Vec<&str> = arr_of(e, "owners").iter().filter_map(Value::as_str).take(3).collect();
            let owners = if owners.is_empty() { String::new() } else { format!("\n{indent}    used by {}", owners.join(", ")) };
            format!("{indent}{}{size}{owners}", str_of(e, "name").unwrap_or(""))
        };
        let bare = |e: &Value, parent: &Value| depth(e) == depth(parent) + 1 && has(e, "size") && !has(e, "owners") && !has(e, "triangles");
        let mut lines = Vec::new();
        let mut index = 0;
        while index < shown.len() {
            let entry = &shown[index];
            let mut end = index + 1;
            while end < shown.len() && bare(&shown[end], entry) {
                end += 1;
            }
            let closed = end == shown.len() || depth(&shown[end]) <= depth(entry);
            if has(entry, "size") && end > index + 1 && closed {
                let kids: Vec<String> =
                    shown[index + 1..end].iter().map(|c| format!("{} {}", str_of(c, "name").unwrap_or(""), to_flat(&c["size"]))).collect();
                lines.push(format!("{}: {}", render(entry), kids.join(", ")));
                index = end;
                continue;
            }
            lines.push(render(entry));
            index += 1;
        }
        let dropped = entries.len() - shown.len();
        blocks.push(format!("{heading}\n{}{}", lines.join("\n"), if dropped > 0 { format!("\n  ({dropped} more)") } else { String::new() }));
    }
    Ok(text(blocks.join("\n\n")))
}

async fn microprofile(ctx: &Ctx, a: &PerfArgs) -> Result<ToolResult> {
    let r = call(
        ctx,
        "perf.microprofile",
        json!({
            "frames": a.frames, "top": a.top, "filter": a.filter, "thread": a.thread, "sort": a.sort,
            "includeIdle": a.include_idle, "export": a.export, "keepRunning": a.keep_running,
        }),
        a.studio_id.as_deref(),
        Some(90_000.0),
    )
    .await?;
    let empty = json!({});
    let f = r.get("frameMs").unwrap_or(&empty);
    let mut parts = vec![format!(
        "{} frames · frame ms avg {} · p50 {} · p95 {} · max {} (frame {}) · {}/{} CPU threads walked",
        num(&r, "frames"),
        num(f, "avg"),
        num(f, "p50"),
        num(f, "p95"),
        num(f, "max"),
        num(f, "worstFrame"),
        num(&r, "walkedThreads"),
        num(&r, "threads")
    )];
    let scopes = arr_of(&r, "scopes");
    if scopes.is_empty() {
        parts.push("\nNo scope matched. Loosen `filter`/`thread`, or pass `includeIdle`.".into());
    } else {
        let rows: Vec<Value> = scopes
            .iter()
            .map(|s| {
                json!({
                    "thread": s.get("thread"),
                    "scope": format!("{}/{}", str_of(s, "group").unwrap_or(""), str_of(s, "name").unwrap_or("")),
                    "selfMs": s.get("selfMs"), "totalMs": s.get("totalMs"), "avg/frame": s.get("avgMs"),
                    "peak": s.get("peakMs"), "calls": s.get("calls"),
                })
            })
            .collect();
        let idle = f64_of(&r, "idleMs");
        let more = format!(
            "ranked by {} time over the whole capture; {} scopes matched{}",
            str_of(&r, "sort").unwrap_or("self"),
            num(&r, "matched"),
            if idle > 0.0 { format!("; {} ms of Sleep/Wait hidden", num(&r, "idleMs")) } else { String::new() }
        );
        parts.push(format!(
            "\n{}",
            table(&["thread", "scope", "selfMs", "totalMs", "avg/frame", "peak", "calls"], &rows, PageMeta { more: Some(more), ..Default::default() })
                .text_of()
        ));
    }
    let worst = arr_of(&r, "worstFrameScopes");
    if !worst.is_empty() {
        let rows: Vec<String> = worst
            .iter()
            .map(|s| format!("  {} ms  {}  [{}]", num(s, "ms"), str_of(s, "name").unwrap_or(""), str_of(s, "thread").unwrap_or("")))
            .collect();
        parts.push(format!("\nWorst frame ({}, {} ms) was filled by:\n{}", num(f, "worstFrame"), num(f, "max"), rows.join("\n")));
    }
    if let Some(html) = str_of(&r, "html") {
        let dir = std::env::temp_dir().join("rbx-studio-mcp");
        tokio::fs::create_dir_all(&dir).await?;
        let stamp = crate::tools::iso(crate::protocol::now_ms()).replace([':', '.'], "-");
        let file = dir.join(format!("microprofile-{stamp}.x.html"));
        tokio::fs::write(&file, html).await?;
        parts.push(format!("\nSaved the capture for the MicroProfiler viewer: {}", file.display()));
    } else if r.get("exportFailed") == Some(&Value::Bool(true)) {
        parts.push("\n[Export failed: LibMP could not convert this capture to .x.html.]".into());
    }
    let mut notes = Vec::new();
    if r.get("libmpLoadMs").is_some_and(|v| !v.is_null()) {
        notes.push(format!("LibMP loaded in {} ms (once per session)", num(&r, "libmpLoadMs")));
    }
    if r.get("profilerLeftOn") == Some(&Value::Bool(true)) {
        notes.push("MicroProfiler left running".to_string());
    }
    if scopes.iter().any(|s| str_of(s, "name") == Some("Present")) {
        notes.push("Render/Present is mostly the main thread waiting on the GPU and vsync, not CPU work".into());
    }
    notes.push("the profiler is process-wide: in Studio this includes Studio's own UI and plugins".into());
    parts.push(format!("\n[{}]", notes.join("; ")));
    Ok(text(parts.join("\n")))
}

async fn profile(ctx: &Ctx, a: &PerfArgs) -> Result<ToolResult> {
    // The plugin blocks for the sample, so the deadline must outlast it.
    let r = call(
        ctx,
        "perf.profile",
        json!({ "seconds": a.seconds, "frequency": a.frequency }),
        a.studio_id.as_deref(),
        Some((a.seconds as f64 + 20.0) * 1000.0),
    )
    .await?;
    let functions = r.pointer("/data/Functions").and_then(Value::as_array).cloned().unwrap_or_default();
    if functions.is_empty() {
        return Ok(text(format!(
            "Nothing ran during the {}s sample.\nThe profiler only sees code that executes. Start a playtest, or profile while the behaviour you are investigating is happening.",
            num(&r, "seconds")
        )));
    }
    let mut sorted = functions;
    sorted.sort_by(|x, y| f64_of(y, "TotalDuration").total_cmp(&f64_of(x, "TotalDuration")));
    let ranked: Vec<Value> = sorted
        .iter()
        // Frames without a Source are per-script roots duplicating the frame under them.
        .filter(|e| e.get("Source").is_some_and(|s| !s.is_null()))
        .filter(|e| a.include_plugins || !is_plugin_frame(e))
        .take(25)
        .map(|e| {
            let line = e.get("Line").and_then(Value::as_f64).filter(|l| *l != 0.0).map(|l| json!(l as i64)).unwrap_or(json!(""));
            json!({
                "source": str_of(e, "Source").unwrap_or("(engine)"),
                "name": str_of(e, "Name").unwrap_or(""),
                "line": line,
                "ms": (f64_of(e, "TotalDuration") * 1_000_000.0).round() / 1000.0,
                "plugin": if is_plugin_frame(e) { "yes" } else { "" },
            })
        })
        .collect();
    if ranked.is_empty() {
        return Ok(text(format!(
            "Every sample in {}s came from Studio plugins, not from this place's scripts.\nNo game code consumed measurable CPU. Pass `includePlugins` to see the plugin activity anyway.",
            num(&r, "seconds")
        )));
    }
    Ok(table(
        &["source", "name", "line", "ms", "plugin"],
        &ranked,
        PageMeta {
            more: Some(format!(
                "sampled {}s at {}Hz, slowest first, ms is total time in that function",
                num(&r, "seconds"),
                num(&r, "frequency")
            )),
            ..Default::default()
        },
    ))
}

async fn snapshot(ctx: &Ctx, a: &PerfArgs) -> Result<ToolResult> {
    let s = read_call(ctx, "perf.snapshot", json!({}), &a.read, a.studio_id.as_deref(), 30_000.0).await?;
    let empty = json!({});
    let memory = s.get("memory").unwrap_or(&empty);
    let mut summary = Map::new();
    for key in ["frame", "scene", "network"] {
        summary.insert(key.into(), s.get(key).cloned().unwrap_or(Value::Null));
    }
    if let Some(total) = memory.get("totalMb").filter(|v| !v.is_null()) {
        summary.insert("totalMemoryMb".into(), total.clone());
    }
    let mut parts = vec![json(&Value::Object(summary), None).text_of()];
    let categories = arr_of(memory, "categories");
    let categories = &categories[..categories.len().min(15)];
    if !categories.is_empty() {
        parts.push(format!("\nMemory by category (MB):\n{}", table(&["category", "megabytes"], categories, PageMeta::default()).text_of()));
    } else if memory.get("trackingEnabled") == Some(&Value::Bool(false)) {
        parts.push("\n[No memory breakdown: Stats.MemoryTrackingEnabled is off in this session.]".into());
    } else {
        parts.push(format!("\n[No memory breakdown: {}]", str_of(memory, "problem").unwrap_or("Studio returned an empty one.")));
    }
    if s.get("renderless") == Some(&Value::Bool(true)) {
        parts.push(
            "\n[This is a playtest server, which does not render: frame time, draw calls and triangle counts read zero \
             because nothing measures them, not because the place is cheap. Physics, instance counts, network and memory \
             above are real. For rendering figures, snapshot the editor session instead.]"
                .into(),
        );
    }
    if let Some(c) = a.read.context() {
        parts.insert(0, c);
    }
    Ok(text(parts.join("\n")))
}

async fn performance(ctx: Arc<Ctx>, a: PerfArgs) -> Result<ToolResult> {
    if a.read.target == ReadSide::Client && a.op != PerfOp::Snapshot {
        return Err(ToolError::new("BAD_TARGET", "Only performance snapshot supports the actual client."));
    }
    match a.op {
        PerfOp::Coverage => coverage(&ctx, &a).await,
        PerfOp::Audit => audit(&ctx, &a).await,
        PerfOp::Scene => scene(&ctx, &a).await,
        PerfOp::Microprofile => microprofile(&ctx, &a).await,
        PerfOp::Profile => profile(&ctx, &a).await,
        PerfOp::Snapshot => snapshot(&ctx, &a).await,
    }
}

pub fn tools() -> Vec<Tool> {
    vec![
        define(
            spec("console", "Read Studio output").read_only(),
            "Reads Studio or playtest client output — prints, warnings and runtime errors, newest last.\n\n\
             This is how to find out what actually happened after a playtest or an `execute_luau` call. An error here \
             usually names the script and line, which `script_read` can then open directly.\n\n\
             Use `target=\"client\"` with the playtest server studioId to read continuously captured client output. In \
             multiplayer, select a player by name. Pass the returned `nextCursor` as `since` to read only newer lines; \
             cursors belong to one session and player. Evicted or limit-skipped lines are reported.\n\n\
             Filter with `level` to see only errors, or `pattern` to follow one subsystem's logging. Up to 2000 lines \
             are held, so prefer a filter over a large `limit`.\n\n\
             `mode=\"drain\"` reads a busy log without gaps: oldest unread matches first, and a cursor that stops at the \
             first one not shown. Keep the same filters while draining. `group` collapses identical lines into one with \
             a count. An error whose stack trace arrived late comes back once more, marked `update`.\n\n\
             Each connected session keeps its own log, recorded from the moment its plugin loaded — the editor session \
             and a running playtest server do not share one. To read what a playtest printed, target the playtest's \
             studioId (see `list_studios`); the editor's log will not have it. Nothing printed before the plugin or \
             client relay loaded is recoverable.\n\n\
             A quiet log is not proof nothing was said. Messages Studio itself emits — the ones the Output window \
             attributes to \"Studio\" rather than to a script — are inconsistent, and they arrive in the session that \
             RAISED them, which is not always the one you are looking at: the warning that a Script with a non-legacy \
             RunContext inside a starter container will run multiple times shows up in the playtest server's log, where \
             the script actually loads, and never in the editor's, where it was created. Do not read silence as an \
             all-clear — when a script misbehaves in a way nothing here explains, check the Output window yourself, or \
             ask the user what it says.",
            console,
        ),
        define(
            spec("performance", "Performance and memory").read_only(),
            "Reads the engine's own counters, and can run the script profiler.\n\n\
             `snapshot` returns what the Developer Console shows: frame, physics and render times in milliseconds, \
             instance and part counts, draw calls, network rates, and memory broken down by category. Use it to answer \
             'why is this place heavy' with numbers instead of guesses.\n\n\
             `profile` runs Studio's script profiler — the Script Performance window — for `seconds` and reports which \
             scripts consumed CPU. It blocks for that long, so keep it short. It only sees code that actually runs, so \
             start a playtest first; profiling an idle edit session returns nothing.\n\n\
             `microprofile` is the MicroProfiler: it captures the last `frames` frames and ranks the engine scopes that \
             filled them — physics, rendering, replication, GC, scripts — by self time, on every CPU thread, plus frame \
             time p50/p95/max and what filled the worst frame. Use it for a frame-time spike that `profile` cannot \
             explain, because most spikes are not Luau. The profiler is process-wide, so in Studio it includes Studio's \
             own UI work; play first to measure the game. `export` saves the capture as an .x.html file the \
             MicroProfiler viewer opens. Same frames, compared before and after a change, is the way to prove a fix.\n\n\
             `coverage` reports which lines of which scripts actually executed — dead code, untested branches, whether a \
             fix was even reached. Pass `enable` first, then play, then read the coverage back FROM THE PLAYTEST session, \
             not the editor: instrumenting is per data model, and the playtest is a different one. `enable` is \
             remembered for the place and re-applied by each new session as it loads. Pass an empty `enable` array to \
             stop.\n\n\
             What it can and cannot see: instrumentation is fixed when a script is first compiled, so it measures modules \
             required after that point — where most game logic lives — but never a script that starts with the place, \
             which the data model compiles before any plugin exists. Those report 0 lines and are named as unmeasurable \
             rather than counted as dead code.\n\n\
             `scene` breaks the place down by what it is actually made of: instances by category, triangles and draw \
             calls FOR WHAT THE CAMERA CAN SEE, and the assets holding script, animation and audio memory — each named, \
             so \"2.4GB of memory\" becomes \"this animation is 138KB and these are the Animators using it\". It also \
             reports UNPARENTED INSTANCES, which is the closest thing here to a leak detector: objects still alive with \
             nothing holding them in the tree, invisible to `find` and to `tree` because they are in neither.\n\n\
             The triangle and draw-call section is the one number here that depends on where the camera is pointing, \
             and it moves enormously: the same place measured 332 triangles looking at empty sky and 29,060 looking at \
             1,800 parts, seconds apart. So it answers \"how heavy is this view\", not \"how heavy is this place\" — \
             point the camera first with `viewport op=\"focus\"`, and compare two views only if both were framed the \
             same way.\n\n\
             `audit` is a health check rather than a performance one: it finds every reference in the place that points \
             at NOTHING. A Sound whose id was deleted or made private plays silence, a Decal shows nothing, an Animation \
             does nothing — none of them errors, none warns, and the instance looks perfectly healthy because the id is \
             still a string. The only other way to find them is to play the game and notice something missing. It also \
             reports ids left blank, scripts left Disabled, and same-named siblings, which is what makes WaitForChild \
             return the wrong one.\n\n\
             `audit` fetches the assets to test them, so Studio's Output window will show load errors for the dead ones. \
             That is the engine confirming the finding, not a fault in the tool.\n\n\
             Frame and network figures are only meaningful while something is running. Instance counts and memory are \
             useful in edit mode too.",
            performance,
        ),
    ]
}
