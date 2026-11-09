//! Running Luau against the PUBLISHED game over Open Cloud: a queued task,
//! polled to its end, with everything it printed.

use super::credentials::Credentials;
use super::{Call, call, enc};
use crate::errors::{Result, ToolError, poll_delay_ms};
use crate::format::prune;
use crate::tool::report_progress;
use serde_json::{Value, json};
use std::time::{Duration, Instant};

const POLL_CEILING_MS: u64 = 2_000;
const MAX_LOG_PAGES: usize = 5;
const SCOPE: &str = "universe.place.luau-execution-session:write";

pub async fn run(credentials: &Credentials, universe: &str, place: &str, source: &str, timeout_seconds: u64) -> Result<Value> {
    let started = call(
        credentials,
        &Call::post(format!("/cloud/v2/universes/{}/places/{}/luau-execution-session-tasks", enc(universe), enc(place)), SCOPE)
            .json(json!({ "script": source, "timeout": format!("{timeout_seconds}s") })),
    )
    .await?;
    let Some(path) = started.get("path").and_then(Value::as_str).map(str::to_string) else {
        return Err(ToolError::new("NO_TASK", "Roblox accepted the script but did not say where to track it."));
    };
    // The script's own timeout plus a margin for the queue.
    let deadline = Instant::now() + Duration::from_secs(timeout_seconds + 30);
    let mut task = started;
    let mut attempt = 0;
    let state = |t: &Value| t.get("state").and_then(Value::as_str).map(str::to_string);
    while matches!(state(&task).as_deref(), None | Some("QUEUED") | Some("PROCESSING")) {
        if Instant::now() >= deadline {
            return Ok(json!({
                "target": "live",
                "state": state(&task).unwrap_or_else(|| "UNKNOWN".into()),
                "task": path,
                "note": "Gave up waiting. The task may still be running on Roblox's side — it was not cancelled.",
            }));
        }
        report_progress(format!(
            "script is {} on Roblox's servers",
            state(&task).unwrap_or_else(|| "starting".into()).to_lowercase()
        ));
        tokio::time::sleep(Duration::from_millis(poll_delay_ms(attempt, POLL_CEILING_MS, 400))).await;
        attempt += 1;
        task = call(credentials, &Call::get(format!("/cloud/v2/{path}"), SCOPE).query("view", "FULL")).await?;
    }

    // Logs are a separate resource and hold everything the script printed.
    let mut logs: Vec<Value> = Vec::new();
    let mut cut = false;
    let mut token: Option<String> = None;
    for page in 0..MAX_LOG_PAGES {
        let request = Call::get(format!("/cloud/v2/{path}/logs"), SCOPE).query("maxPageSize", 100).query_opt("pageToken", token.clone());
        let Ok(body) = call(credentials, &request).await else { break };
        for entry in body.get("luauExecutionSessionTaskLogs").and_then(Value::as_array).into_iter().flatten() {
            logs.extend(entry.get("messages").and_then(Value::as_array).cloned().unwrap_or_default());
        }
        token = body.get("nextPageToken").and_then(Value::as_str).filter(|t| !t.is_empty()).map(str::to_string);
        if token.is_none() {
            break;
        }
        cut = page == MAX_LOG_PAGES - 1;
    }
    let error = task.get("error").filter(|e| !e.is_null()).map(|e| {
        format!(
            "{}: {}",
            e.get("code").and_then(Value::as_str).unwrap_or("error"),
            e.get("message").and_then(Value::as_str).unwrap_or("")
        )
    });
    Ok(prune(json!({
        "target": "live",
        "universeId": universe,
        "placeId": place,
        "state": task.get("state"),
        "results": task.pointer("/output/results"),
        "logs": logs,
        "logsCut": cut.then_some(true),
        "error": error,
    })))
}
