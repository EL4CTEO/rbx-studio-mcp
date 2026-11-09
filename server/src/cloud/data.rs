//! Data stores of the PUBLISHED game over Open Cloud: exactly what live servers see.

use super::credentials::Credentials;
use super::{Call, call, enc, paged};
use crate::errors::{Result, ToolError};
use crate::format::prune;
use serde_json::{Value, json};

fn entries_path(universe: &str, store: &str, scope: Option<&str>) -> String {
    let base = format!("/cloud/v2/universes/{}/data-stores/{}", enc(universe), enc(store));
    // No scope means "all scopes", not "the default one".
    match scope.filter(|s| !s.is_empty()) {
        Some(s) => format!("{base}/scopes/{}/entries", enc(s)),
        None => format!("{base}/entries"),
    }
}

fn id_of(path: Option<&Value>) -> String {
    let p = path.and_then(Value::as_str).unwrap_or("");
    let last = p.rsplit('/').next().unwrap_or("");
    percent_decode(last)
}

fn percent_decode(s: &str) -> String {
    let bytes = s.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' && i + 2 < bytes.len()
            && let Ok(b) = u8::from_str_radix(&s[i + 1..i + 3], 16) {
                out.push(b);
                i += 3;
                continue;
            }
        out.push(bytes[i]);
        i += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

pub struct Args<'a> {
    pub op: &'a str,
    pub ordered: bool,
    pub universe: &'a str,
    pub store: Option<&'a str>,
    pub scope: Option<&'a str>,
    pub key: Option<&'a str>,
    pub value: Option<&'a str>,
    pub amount: Option<f64>,
    pub limit: usize,
    pub cursor: Option<&'a str>,
    pub create: bool,
}

/// JSON if it parses; otherwise the bare string the caller meant.
fn parse_value(raw: Option<&str>) -> Result<Value> {
    let raw = raw.ok_or_else(|| ToolError::bad_params("set needs a `value`."))?;
    Ok(serde_json::from_str(raw).unwrap_or_else(|_| Value::String(raw.to_string())))
}

pub async fn run(credentials: &Credentials, a: Args<'_>) -> Result<Value> {
    if a.ordered {
        return ordered(credentials, a).await;
    }
    let with_cursor = |c: Call| c.query_opt("pageToken", a.cursor);
    let Some(store) = a.store.filter(|s| !s.is_empty()) else {
        if a.op != "list" {
            return Err(ToolError::bad_params(format!("live {} needs a `store`.", a.op)));
        }
        let page = paged(
            credentials,
            with_cursor(Call::get(format!("/cloud/v2/universes/{}/data-stores", enc(a.universe)), "universe-datastores.control:list")),
            "dataStores",
            a.limit,
        )
        .await?;
        let items: Vec<Value> = page
            .items
            .iter()
            .map(|s| prune(json!({ "store": id_of(s.get("path")), "created": s.get("createTime"), "state": s.get("state") })))
            .collect();
        let count = items.len();
        return Ok(json!({ "target": "live", "universe": a.universe, "items": items, "count": count, "truncated": page.truncated }));
    };
    let base = entries_path(a.universe, store, a.scope);
    if a.op == "list" {
        let page = paged(credentials, with_cursor(Call::get(base, "universe-datastores.objects:list")), "dataStoreEntries", a.limit).await?;
        let items: Vec<Value> = page.items.iter().map(|e| prune(json!({ "key": id_of(e.get("path")), "state": e.get("state") }))).collect();
        let count = items.len();
        return Ok(json!({ "target": "live", "store": store, "items": items, "count": count, "truncated": page.truncated }));
    }
    let key = a.key.filter(|k| !k.is_empty()).ok_or_else(|| ToolError::bad_params(format!("live {} needs a `key`.", a.op)))?;
    let entry = format!("{base}/{}", enc(key));
    match a.op {
        "versions" => {
            let page = paged(
                credentials,
                with_cursor(Call::get(format!("{entry}:listRevisions"), "universe-datastores.versions:list")),
                "dataStoreEntries",
                a.limit,
            )
            .await?;
            let items: Vec<Value> = page
                .items
                .iter()
                .map(|r| {
                    prune(json!({
                        "version": r.get("revisionId"),
                        "created": r.get("revisionCreateTime"),
                        "deleted": r.get("state").and_then(Value::as_str) == Some("DELETED"),
                    }))
                })
                .collect();
            let count = items.len();
            Ok(json!({ "target": "live", "store": store, "key": key, "items": items, "count": count, "truncated": page.truncated }))
        }
        "get" => {
            let found = call(credentials, &Call::get(entry, "universe-datastores.objects:read")).await?;
            Ok(prune(json!({
                "target": "live", "store": store, "key": key, "exists": true, "value": found.get("value"),
                "version": found.get("revisionId"), "updated": found.get("revisionCreateTime"), "etag": found.get("etag"),
            })))
        }
        "remove" => {
            call(credentials, &Call::delete(entry, "universe-datastores.objects:delete")).await?;
            Ok(json!({ "target": "live", "store": store, "key": key, "removed": true }))
        }
        "increment" => {
            let amount = a.amount.ok_or_else(|| ToolError::bad_params("increment needs an `amount`."))?;
            let r = call(credentials, &Call::post(format!("{entry}:increment"), "universe-datastores.objects:update").json(json!({ "amount": amount }))).await?;
            Ok(prune(json!({ "target": "live", "store": store, "key": key, "value": r.get("value"), "version": r.get("revisionId") })))
        }
        _ => {
            // No partial update: carry users, attributes and the etag forward.
            let current = match call(credentials, &Call::get(entry.clone(), "universe-datastores.objects:read")).await {
                Ok(v) => Some(v),
                Err(e) if e.code == "NOT_FOUND" => None,
                Err(e) => return Err(e),
            };
            let mut body = json!({ "value": parse_value(a.value)? });
            if let Some(cur) = &current {
                for k in ["users", "attributes", "etag"] {
                    if let Some(v) = cur.get(k).filter(|v| !v.is_null()) {
                        body[k] = v.clone();
                    }
                }
            }
            let written = call(
                credentials,
                &Call::patch(entry, "universe-datastores.objects:update").query_opt("allowMissing", a.create.then_some("true")).json(body),
            )
            .await?;
            Ok(prune(json!({ "target": "live", "store": store, "key": key, "written": true, "version": written.get("revisionId") })))
        }
    }
}

/// Ordered stores: the leaderboard backend. Numbers only, sorted, no history.
async fn ordered(credentials: &Credentials, a: Args<'_>) -> Result<Value> {
    const READ: &str = "universe.ordered-data-store.scope.entry:read";
    const WRITE: &str = "universe.ordered-data-store.scope.entry:write";
    let store = a.store.filter(|s| !s.is_empty()).ok_or_else(|| ToolError::bad_params("ordered stores need a `store`."))?;
    let scope = a.scope.filter(|s| !s.is_empty()).unwrap_or("global");
    let base = format!("/cloud/v2/universes/{}/ordered-data-stores/{}/scopes/{}/entries", enc(a.universe), enc(store), enc(scope));
    if a.op == "list" {
        let page = paged(credentials, Call::get(base, READ).query("orderBy", "value desc").query_opt("pageToken", a.cursor), "orderedDataStoreEntries", a.limit).await?;
        let items: Vec<Value> = page
            .items
            .iter()
            .enumerate()
            .map(|(i, e)| {
                let key = e.get("id").and_then(Value::as_str).map(str::to_string).unwrap_or_else(|| id_of(e.get("path")));
                prune(json!({ "rank": i + 1, "key": key, "value": e.get("value") }))
            })
            .collect();
        let count = items.len();
        return Ok(json!({ "target": "live", "kind": "ordered", "store": store, "scope": scope, "items": items, "count": count, "truncated": page.truncated }));
    }
    let key = a.key.filter(|k| !k.is_empty()).ok_or_else(|| ToolError::bad_params(format!("ordered {} needs a `key`.", a.op)))?;
    let entry = format!("{base}/{}", enc(key));
    match a.op {
        "get" => {
            let found = call(credentials, &Call::get(entry, READ)).await?;
            Ok(prune(json!({ "target": "live", "kind": "ordered", "store": store, "scope": scope, "key": key, "value": found.get("value") })))
        }
        "remove" => {
            call(credentials, &Call::delete(entry, WRITE)).await?;
            Ok(json!({ "target": "live", "kind": "ordered", "store": store, "key": key, "removed": true }))
        }
        "increment" => {
            let amount = a.amount.ok_or_else(|| ToolError::bad_params("increment needs an `amount`."))?;
            let r = call(credentials, &Call::post(format!("{entry}:increment"), WRITE).json(json!({ "amount": amount }))).await?;
            Ok(prune(json!({ "target": "live", "kind": "ordered", "store": store, "key": key, "value": r.get("value") })))
        }
        "versions" => Err(ToolError::hint(
            "UNSUPPORTED",
            "Ordered data stores keep no version history.",
            "Use kind=\"data\" for anything that needs to be recoverable.",
        )),
        _ => {
            let numeric = a.value.and_then(|v| v.trim().parse::<f64>().ok()).filter(|f| f.is_finite()).ok_or_else(|| {
                ToolError::bad_params(format!("An ordered data store holds numbers; \"{}\" is not one.", a.value.unwrap_or("undefined")))
            })?;
            // Update first, create on 404, so a typo'd key is not the default path to a new row.
            match call(credentials, &Call::patch(entry, WRITE).json(json!({ "value": numeric }))).await {
                Ok(p) => Ok(prune(json!({ "target": "live", "kind": "ordered", "store": store, "key": key, "value": p.get("value"), "created": false }))),
                Err(e) if e.code == "NOT_FOUND" => {
                    let made = call(credentials, &Call::post(base, WRITE).query("id", key).json(json!({ "value": numeric }))).await?;
                    Ok(prune(json!({ "target": "live", "kind": "ordered", "store": store, "key": key, "value": made.get("value"), "created": true })))
                }
                Err(e) => Err(e),
            }
        }
    }
}
