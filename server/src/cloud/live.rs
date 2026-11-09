//! Operating the published experience over Open Cloud: its scripts, servers,
//! players and saved data. No undo stack, and the audience is real.

use super::credentials::Credentials;
use super::{Call, call, enc, paged};
use crate::errors::{Result, ToolError, poll_delay_ms};
use crate::format::prune;
use crate::tool::report_progress;
use serde_json::{Map, Value, json};
use std::time::{Duration, Instant};

const OPERATION_CEILING_MS: u64 = 1_000;
const OPERATION_TIMEOUT: Duration = Duration::from_secs(60);
const INSTANCE_READ: &str = "universe.place.instance:read";
const INSTANCE_WRITE: &str = "universe.place.instance:write";
const MAX_CHILD_PAGES: usize = 10;

/// Polls an Open Cloud long-running Operation to completion.
async fn await_operation(credentials: &Credentials, started: Value, scope: &'static str) -> Result<Value> {
    let mut operation = started;
    let deadline = Instant::now() + OPERATION_TIMEOUT;
    let mut attempt = 0;
    while operation.get("done").and_then(Value::as_bool) != Some(true) {
        let Some(path) = operation.get("path").and_then(Value::as_str).map(str::to_string) else {
            return Err(ToolError::new("NO_OPERATION", "Roblox did not say where to track this request."));
        };
        if Instant::now() >= deadline {
            return Err(ToolError::new("TIMEOUT", "Roblox did not finish this request in time."));
        }
        report_progress("waiting for Roblox to finish the operation");
        tokio::time::sleep(Duration::from_millis(poll_delay_ms(attempt, OPERATION_CEILING_MS, 250))).await;
        attempt += 1;
        operation = call(credentials, &Call::get(format!("/cloud/v2/{path}"), scope)).await?;
    }
    if let Some(error) = operation.get("error").filter(|e| !e.is_null()) {
        if error.get("code").and_then(Value::as_i64) == Some(422) {
            return Err(ToolError::hint(
                "TOO_LARGE",
                "The response was over Roblox's 500,000-byte limit for this API.",
                "Ask for a smaller piece: fewer children at a time, or one script rather than a folder.",
            ));
        }
        let why = error
            .get("message")
            .and_then(Value::as_str)
            .map(str::to_string)
            .or_else(|| error.get("code").map(|c| c.to_string()))
            .unwrap_or_else(|| "no reason given".into());
        return Err(ToolError::new("OPERATION_FAILED", format!("Roblox refused: {why}")));
    }
    Ok(operation.get("response").cloned().unwrap_or_else(|| json!({})))
}

fn instance_path(universe: &str, place: &str, instance: &str) -> String {
    format!("/cloud/v2/universes/{}/places/{}/instances/{}", enc(universe), enc(place), enc(instance))
}

/// Flattens one cloud instance into the shape the script tools speak.
fn describe(entry: &Value) -> Value {
    let engine = entry.get("engineInstance").cloned().unwrap_or_default();
    let details = engine.get("Details").and_then(Value::as_object).cloned().unwrap_or_default();
    let class = details.keys().next().cloned().unwrap_or_else(|| "Instance".into());
    let body = details.get(&class).cloned().unwrap_or_default();
    let mut out = Map::new();
    out.insert("id".into(), engine.get("Id").cloned().unwrap_or(Value::Null));
    out.insert("name".into(), engine.get("Name").cloned().unwrap_or(Value::Null));
    out.insert("className".into(), Value::String(class));
    out.insert("hasChildren".into(), Value::Bool(entry.get("hasChildren").and_then(Value::as_bool).unwrap_or(false)));
    for (from, to) in [("Source", "source"), ("Enabled", "enabled"), ("RunContext", "runContext")] {
        if let Some(v) = body.get(from) {
            out.insert(to.into(), v.clone());
        }
    }
    Value::Object(out)
}

pub struct Place<'a> {
    pub universe: &'a str,
    pub place: &'a str,
}

pub async fn instance(credentials: &Credentials, at: &Place<'_>, id: &str) -> Result<Value> {
    let started = call(credentials, &Call::get(instance_path(at.universe, at.place, id), INSTANCE_READ)).await?;
    Ok(describe(&await_operation(credentials, started, INSTANCE_READ).await?))
}

pub struct Children {
    pub items: Vec<Value>,
    pub next_page_token: Option<String>,
}

pub async fn children(credentials: &Credentials, at: &Place<'_>, id: &str, limit: usize, token: Option<&str>) -> Result<Children> {
    let request = Call::get(format!("{}:listChildren", instance_path(at.universe, at.place, id)), INSTANCE_READ)
        .query("maxPageSize", limit.min(100))
        .query_opt("pageToken", token);
    let started = call(credentials, &request).await?;
    let done = await_operation(credentials, started, INSTANCE_READ).await?;
    let items = done.get("instances").and_then(Value::as_array).cloned().unwrap_or_default();
    Ok(Children {
        items: items.iter().take(limit).map(describe).collect(),
        next_page_token: done.get("nextPageToken").and_then(Value::as_str).filter(|t| !t.is_empty()).map(str::to_string),
    })
}

pub struct Resolved {
    pub id: String,
    pub class_name: String,
}

/// Resolves a dot path by walking from the root: one listChildren per segment.
pub async fn resolve_path(credentials: &Credentials, at: &Place<'_>, path: &str) -> Result<Resolved> {
    let segments: Vec<&str> = path.split('.').filter(|s| !s.is_empty()).collect();
    if segments.is_empty() {
        return Err(ToolError::bad_params("A live script path cannot be empty."));
    }
    let mut current = "root".to_string();
    let mut found: Option<Value> = None;
    for segment in segments {
        let mut first_page: Vec<Value> = Vec::new();
        let mut matched: Option<Value> = None;
        let mut token: Option<String> = None;
        for page in 0..MAX_CHILD_PAGES {
            let kids = children(credentials, at, &current, 100, token.as_deref()).await?;
            matched = kids.items.iter().find(|e| e.get("name").and_then(Value::as_str) == Some(segment)).cloned();
            if page == 0 {
                first_page = kids.items;
            }
            token = kids.next_page_token;
            if matched.is_some() || token.is_none() {
                break;
            }
        }
        let Some(hit) = matched else {
            let names: Vec<String> =
                first_page.iter().take(12).map(|e| e.get("name").and_then(Value::as_str).unwrap_or("").to_string()).collect();
            let where_ = if current == "root" { "the root".to_string() } else { current.clone() };
            return Err(ToolError::hint(
                "NOT_FOUND",
                format!("The published place has no \"{segment}\" under {where_}."),
                if names.is_empty() {
                    "Nothing is there. Note the Instance API only sees Folders and scripts, so a path through any other class cannot be walked.".to_string()
                } else {
                    format!(
                        "What is there: {}. The Instance API only sees Folders and scripts, so a path through a Model or a Part cannot be walked.",
                        names.join(", ")
                    )
                },
            ));
        };
        current = hit.get("id").and_then(Value::as_str).unwrap_or("").to_string();
        found = Some(hit);
    }
    Ok(Resolved {
        id: current,
        class_name: found.as_ref().and_then(|f| f.get("className")).and_then(Value::as_str).unwrap_or("Instance").to_string(),
    })
}

/// A short fingerprint of published source, compared only with itself.
pub fn revision(source: &str) -> String {
    use sha2::{Digest, Sha256};
    Sha256::digest(source.as_bytes()).iter().take(6).map(|b| format!("{b:02x}")).collect()
}

pub async fn script_write(
    credentials: &Credentials,
    at: &Place<'_>,
    id: &str,
    class_name: &str,
    source: &str,
    expected: Option<&str>,
) -> Result<Value> {
    let bytes = source.len();
    if bytes > 200_000 {
        return Err(ToolError::new(
            "TOO_LARGE",
            format!("That source is {bytes} bytes; Roblox accepts 200,000 for a cloud script edit."),
        ));
    }
    // The API has no etag, so re-read just before writing.
    if let Some(expected) = expected.filter(|e| !e.is_empty()) {
        let now = instance(credentials, at, id).await?;
        let found = revision(now.get("source").and_then(Value::as_str).unwrap_or(""));
        if found != expected {
            return Err(ToolError::hint(
                "STALE_SCRIPT",
                format!("The published script changed since it was read (expected rev {expected}, found {found})."),
                "Somebody published or edited it in the meantime. Read it again with `script_read target=\"live\"` and rebuild the edit against what is there now.",
            ));
        }
    }
    let mut details = Map::new();
    details.insert(class_name.into(), json!({ "Source": source }));
    let request = Call::patch(instance_path(at.universe, at.place, id), INSTANCE_WRITE)
        .json(json!({ "engineInstance": { "Details": details } }));
    let started = call(credentials, &request).await?;
    let done = await_operation(credentials, started, INSTANCE_WRITE).await?;
    let mut out = describe(&done).as_object().cloned().unwrap_or_default();
    out.insert("written".into(), json!(true));
    out.insert("bytes".into(), json!(bytes));
    out.insert("rev".into(), json!(revision(source)));
    out.insert(
        "note".into(),
        json!("This changed the SAVED place. Servers already running still have the old code — restart them with `universe op=\"restart\"`, or wait for them to cycle."),
    );
    Ok(Value::Object(out))
}

/// Rolls live servers onto the newly published version; bleed-off by default.
pub async fn restart_servers(credentials: &Credentials, universe: &str, place_ids: Option<Vec<i64>>, bleed_minutes: Option<u32>) -> Result<Value> {
    let bleed = bleed_minutes.unwrap_or(10);
    let mut body = json!({ "bleedOffServers": bleed > 0 });
    if let Some(ids) = place_ids {
        body["placeIds"] = json!(ids);
    }
    if bleed > 0 {
        body["bleedOffDurationMinutes"] = json!(bleed);
    }
    call(credentials, &Call::post(format!("/cloud/v2/universes/{}:restartServers", enc(universe)), "universe:write").json(body)).await?;
    Ok(json!({
        "restarted": true,
        "universeId": universe,
        "bleedOffMinutes": bleed,
        "note": if bleed > 0 {
            format!("Matchmaking to old servers has stopped; they shut down over the next {bleed} minutes so players can finish.")
        } else {
            "Servers are shutting down now. Anyone playing is being moved immediately.".to_string()
        },
    }))
}

pub async fn publish_message(credentials: &Credentials, universe: &str, topic: &str, message: &str) -> Result<Value> {
    call(
        credentials,
        &Call::post(format!("/cloud/v2/universes/{}:publishMessage", enc(universe)), "universe-messaging-service:publish")
            .json(json!({ "topic": topic, "message": message })),
    )
    .await?;
    Ok(json!({
        "published": true,
        "topic": topic,
        "note": "Delivered only to servers with a SubscribeAsync listener on this exact topic. Nothing reports whether anything was listening, so a silent success does not mean it was received.",
    }))
}

/// One data store snapshot per experience per UTC day; says whether one was taken.
pub async fn snapshot_data_stores(credentials: &Credentials, universe: &str) -> Result<Value> {
    let result = call(
        credentials,
        &Call::post(format!("/cloud/v2/universes/{}/data-stores:snapshot", enc(universe)), "universe-datastores.control:snapshot")
            .json(json!({})),
    )
    .await?;
    let taken = result.get("newSnapshotTaken").and_then(Value::as_bool) == Some(true);
    let latest = result.get("latestSnapshotTime").cloned().unwrap_or(Value::Null);
    Ok(json!({
        "newSnapshotTaken": taken,
        "latestSnapshotTime": latest,
        "note": if taken {
            "Snapshot taken. Safe to make the change.".to_string()
        } else {
            format!(
                "NO new snapshot was taken — Roblox allows one per experience per UTC day and one already exists ({}). Anything written since then is NOT covered.",
                latest.as_str().unwrap_or("unknown")
            )
        },
    }))
}

pub struct Restriction<'a> {
    pub universe: &'a str,
    pub place: Option<&'a str>,
    pub user: &'a str,
    pub active: bool,
    pub duration_seconds: Option<u64>,
    pub display_reason: Option<&'a str>,
    pub private_reason: Option<&'a str>,
    pub exclude_alts: Option<bool>,
}

pub async fn set_restriction(credentials: &Credentials, r: Restriction<'_>) -> Result<Value> {
    let base = match r.place {
        Some(p) => format!("/cloud/v2/universes/{}/places/{}", enc(r.universe), enc(p)),
        None => format!("/cloud/v2/universes/{}", enc(r.universe)),
    };
    let mut restriction = json!({ "active": r.active });
    if r.active {
        if let Some(d) = r.duration_seconds.filter(|d| *d > 0) {
            restriction["duration"] = json!(format!("{d}s"));
        }
        restriction["displayReason"] = json!(r.display_reason.unwrap_or(""));
        restriction["privateReason"] = json!(r.private_reason.unwrap_or(""));
        restriction["excludeAltAccounts"] = json!(r.exclude_alts.unwrap_or(false));
    }
    let result = call(
        credentials,
        &Call::patch(format!("{base}/user-restrictions/{}", enc(r.user)), "universe.user-restriction:write")
            .json(json!({ "gameJoinRestriction": restriction })),
    )
    .await?;
    Ok(json!({
        "userId": r.user,
        "banned": r.active,
        "scope": match r.place { Some(p) => format!("place {p}"), None => format!("universe {}", r.universe) },
        "duration": match (r.duration_seconds.filter(|d| *d > 0), r.active) {
            (Some(d), _) => json!(format!("{d}s")),
            (None, true) => json!("permanent"),
            (None, false) => Value::Null,
        },
        "restriction": result.get("gameJoinRestriction"),
    }))
}

/// Server Management pages in PascalCase, so it has its own loop.
async fn server_pages(credentials: &Credentials, path: String, field: &str, limit: usize, query: Vec<(&str, Option<String>)>) -> Result<(Vec<Value>, bool, bool)> {
    let mut items = Vec::new();
    let mut token: Option<String> = None;
    let mut partial = false;
    loop {
        let mut request = Call::get(path.clone(), "universe:read").query("MaxPageSize", (limit - items.len()).min(100));
        for (k, v) in &query {
            request = request.query_opt(k, v.clone());
        }
        request = request.query_opt("PageToken", token.clone());
        let page = call(credentials, &request).await?;
        let batch = page.get(field).and_then(Value::as_array).cloned().unwrap_or_default();
        let empty = batch.is_empty();
        items.extend(batch);
        token = page.get("nextPageToken").and_then(Value::as_str).filter(|t| !t.is_empty()).map(str::to_string);
        partial |= page.get("activeServersFetchError") == Some(&Value::Bool(true))
            || page.get("shutdownServersFetchError") == Some(&Value::Bool(true));
        if token.is_none() || items.len() >= limit || empty {
            items.truncate(limit);
            return Ok((items, token.is_some() && !empty, partial));
        }
    }
}

pub async fn list_game_servers(credentials: &Credentials, at: &Place<'_>, limit: usize, filter: Option<String>) -> Result<Value> {
    let (items, more, partial) = server_pages(
        credentials,
        format!("/server-management/v1/universes/{}/places/{}/versions/-/game-servers", enc(at.universe), enc(at.place)),
        "gameServers",
        limit,
        vec![("Filter", filter), ("OrderBy", Some("uptime desc".into()))],
    )
    .await?;
    let rows: Vec<Value> = items
        .iter()
        .map(|s| {
            let occ = s.get("occupancy").and_then(Value::as_i64).unwrap_or(0);
            let max = s.get("maxOccupancy").and_then(Value::as_i64).map(|m| m.to_string()).unwrap_or_else(|| "?".into());
            prune(json!({
                "jobId": s.get("jobId"),
                "status": s.get("status"),
                "players": format!("{occ}/{max}"),
                "uptime": s.get("uptime"),
                "fps": s.get("frameRate").and_then(Value::as_f64).map(|f| f.round() as i64),
                "memoryMb": s.get("memoryUsageBytes").and_then(Value::as_f64).map(|b| (b / 1_048_576.0).round() as i64),
                "version": s.get("placeVersion"),
                "ended": s.get("terminationTime").filter(|t| !t.is_null()),
            }))
        })
        .collect();
    Ok(json!({ "items": rows, "more": more, "partial": partial }))
}

/// Frames as `Path.To.Script:line in fn`, the shape `script_read` can open.
pub fn frames_of(raw: Option<&Value>) -> Option<Vec<String>> {
    let parsed;
    let frames = match raw? {
        Value::String(s) => {
            parsed = serde_json::from_str::<Value>(s).ok()?;
            &parsed
        }
        other => other,
    };
    let frames = frames.as_array().filter(|f| !f.is_empty())?;
    let usable = frames.iter().all(|f| {
        f.get("scriptPath").and_then(Value::as_str).is_some_and(|p| !p.is_empty()) && f.get("line").is_some_and(Value::is_number)
    });
    if !usable {
        return None;
    }
    Some(
        frames
            .iter()
            .map(|f| {
                let path = f.get("scriptPath").and_then(Value::as_str).unwrap_or("?");
                let line = f.get("line").map(|l| l.to_string()).unwrap_or_else(|| "?".into());
                let func = f.get("functionName").and_then(Value::as_str).filter(|s| !s.is_empty()).map(|s| format!(" in {s}")).unwrap_or_default();
                let dynamic = if f.get("isDynamic") == Some(&Value::Bool(true)) { " (runtime clone)" } else { "" };
                format!("{path}:{line}{func}{dynamic}")
            })
            .collect(),
    )
}

const SEVERITY_NAMES: [&str; 4] = ["output", "info", "warning", "error"];

pub async fn list_server_logs(
    credentials: &Credentials,
    at: &Place<'_>,
    job: &str,
    limit: usize,
    severity: Option<&str>,
    search: Option<&str>,
) -> Result<Value> {
    let mut filters = Vec::new();
    if let Some(s) = severity {
        filters.push(format!("severity == {}", SEVERITY_NAMES.iter().position(|n| *n == s).map(|i| i as i64).unwrap_or(-1)));
    }
    if let Some(q) = search {
        filters.push(format!("search == {}", serde_json::to_string(q).unwrap_or_default()));
    }
    let (items, more, _) = server_pages(
        credentials,
        format!(
            "/server-management/v1/universes/{}/places/{}/versions/-/game-servers/{}/logs",
            enc(at.universe),
            enc(at.place),
            enc(job)
        ),
        "gameServerLogs",
        limit,
        vec![
            ("Filter", (!filters.is_empty()).then(|| filters.join(" && "))),
            ("OrderBy", Some("message_timestamp desc".into())),
        ],
    )
    .await?;
    let rows: Vec<Value> = items
        .iter()
        .map(|e| {
            let time = e
                .get("messageTimestampMs")
                .and_then(|t| t.as_str().and_then(|s| s.parse::<u64>().ok()).or_else(|| t.as_u64()))
                .map(crate::tools::iso);
            let level = e
                .get("severity")
                .and_then(Value::as_i64)
                .and_then(|i| SEVERITY_NAMES.get(i as usize).map(|s| s.to_string()))
                .unwrap_or_else(|| e.get("severity").map(|s| s.to_string()).unwrap_or_else(|| "undefined".into()));
            let repeats = e.get("skippedCount").and_then(Value::as_i64).unwrap_or(0) + e.get("rateLimitedCount").and_then(Value::as_i64).unwrap_or(0);
            prune(json!({
                "time": time,
                "level": level,
                "message": e.get("message"),
                "stack": e.get("stackTrace").and_then(Value::as_str).filter(|s| !s.is_empty()),
                "frames": frames_of(e.get("structuredStackTrace")),
                "context": e.get("context").and_then(Value::as_str).filter(|s| !s.is_empty()),
                "repeats": (repeats > 0).then_some(repeats),
            }))
        })
        .collect();
    Ok(json!({ "items": rows, "more": more }))
}

pub async fn list_restrictions(credentials: &Credentials, universe: &str, limit: usize) -> Result<Value> {
    let page = paged(
        credentials,
        Call::get(format!("/cloud/v2/universes/{}/user-restrictions", enc(universe)), "universe.user-restriction:read"),
        "userRestrictions",
        limit,
    )
    .await?;
    let rows: Vec<Value> = page
        .items
        .iter()
        .map(|e| {
            let r = e.get("gameJoinRestriction");
            prune(json!({
                "user": e.get("user").and_then(Value::as_str).map(|u| u.replace("users/", "")),
                "active": r.and_then(|r| r.get("active")).and_then(Value::as_bool).unwrap_or(false),
                "duration": r.and_then(|r| r.get("duration")).cloned().unwrap_or(json!("permanent")),
                "reason": r.and_then(|r| r.get("displayReason")),
                "updated": e.get("updateTime"),
            }))
        })
        .collect();
    let count = rows.len();
    Ok(json!({ "items": rows, "count": count }))
}

pub async fn get_user(credentials: &Credentials, user: &str) -> Result<Value> {
    call(credentials, &Call::get(format!("/cloud/v2/users/{}", enc(user)), "user.advanced:read")).await
}

pub async fn get_inventory(credentials: &Credentials, user: &str, limit: usize, filter: Option<String>) -> Result<Value> {
    let page = paged(
        credentials,
        Call::get(format!("/cloud/v2/users/{}/inventory-items", enc(user)), "user.inventory-item:read").query_opt("filter", filter),
        "inventoryItems",
        limit,
    )
    .await?;
    let count = page.items.len();
    Ok(json!({ "userId": user, "items": page.items, "count": count }))
}

/// Uploads left before Roblox starts refusing them.
pub async fn asset_quotas(credentials: &Credentials) -> Result<Value> {
    let page = paged(
        credentials,
        Call::get(format!("/cloud/v2/users/{}/asset-quotas", enc(&credentials.creator_id)), "assets:write"),
        "assetQuotas",
        50,
    )
    .await?;
    let rows: Vec<Value> = page
        .items
        .iter()
        .filter(|e| e.get("quotaType").and_then(Value::as_str) == Some("RATE_LIMIT_UPLOAD"))
        .map(|e| {
            let num = |v: Option<&Value>| v.and_then(|v| v.as_f64().or_else(|| v.as_str().and_then(|s| s.parse().ok())));
            let capacity = num(e.get("capacity"));
            let used = num(e.get("usage")).unwrap_or(0.0);
            prune(json!({
                "assetType": e.get("assetType"),
                "used": used as i64,
                "capacity": capacity.map(|c| c as i64),
                "remaining": capacity.map(|c| (c - used) as i64),
                "resets": e.get("expirationTime"),
            }))
        })
        .collect();
    Ok(json!({ "items": rows }))
}
