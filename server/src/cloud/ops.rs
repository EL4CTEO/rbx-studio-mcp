//! Analytics, developer products / game passes, and scheduled events.

use super::credentials::Credentials;
use super::{Call, call, enc};
use crate::errors::{Result, ToolError, poll_delay_ms};
use crate::format::{prune, to_flat};
use crate::tool::report_progress;
use serde_json::{Value, json};
use std::time::{Duration, Instant};

// --- analytics ---------------------------------------------------------------------

const ANALYTICS_SCOPE: &str = "universe.analytics:read";

pub struct MetricQuery {
    pub universe: String,
    pub metric: String,
    pub granularity: String,
    pub start: String,
    pub end: String,
    pub breakdown: Option<Vec<String>>,
    pub filter: Option<Vec<Value>>,
    pub limit: Option<u32>,
}

/// `Platform=Phone,Tablet;Country=US` as the API's filter list.
pub fn parse_filter(text: &str) -> Result<Vec<Value>> {
    let mut filters = Vec::new();
    for part in text.split(';').filter(|p| !p.trim().is_empty()) {
        let (dimension, values) = match part.split_once('=') {
            Some((d, v)) => (d.trim(), v.split(',').map(str::trim).filter(|v| !v.is_empty()).collect::<Vec<_>>()),
            None => ("", vec![]),
        };
        if dimension.is_empty() || values.is_empty() {
            return Err(ToolError::hint(
                "BAD_PARAMS",
                format!("\"{}\" is not a filter.", part.trim()),
                "Write one as Dimension=value1,value2 and separate several with `;`, e.g. Platform=Phone,Tablet;Country=US.",
            ));
        }
        filters.push(json!({ "dimension": dimension, "values": values, "operation": "In" }));
    }
    Ok(filters)
}

/// Whole UTC days ending at the start of today: today's bucket is still filling.
pub fn last_days(days: u32) -> (String, String) {
    let now = crate::protocol::now_ms();
    let end = now - now % 86_400_000;
    let start = end - days as u64 * 86_400_000;
    let iso = |ms: u64| crate::tools::iso(ms).replace(".000Z", "Z");
    (iso(start), iso(end))
}

pub async fn query_metric(credentials: &Credentials, q: &MetricQuery) -> Result<Value> {
    let mut body = json!({ "metric": q.metric, "granularity": q.granularity, "startTime": q.start, "endTime": q.end });
    if let Some(b) = q.breakdown.as_ref().filter(|b| !b.is_empty()) {
        body["breakdown"] = json!(b);
        if let Some(l) = q.limit {
            body["limit"] = json!(l);
        }
    }
    if let Some(f) = q.filter.as_ref().filter(|f| !f.is_empty()) {
        body["filter"] = json!(f);
    }
    let outcome = async {
        let mut op = call(credentials, &Call::post(format!("/analytics-query-api/v1/universes/{}/metrics", enc(&q.universe)), ANALYTICS_SCOPE).json(body)).await?;
        let deadline = Instant::now() + Duration::from_secs(90);
        let mut attempt = 0;
        while op.get("done").and_then(Value::as_bool) != Some(true) {
            if op.get("error").is_some_and(|e| !e.is_null()) {
                break;
            }
            let Some(path) = op.get("path").and_then(Value::as_str).map(|p| p.trim_start_matches('/').to_string()) else {
                return Err(ToolError::new("NO_OPERATION", "Roblox did not say where to read this query's result."));
            };
            if Instant::now() >= deadline {
                return Err(ToolError::hint(
                    "STILL_PROCESSING",
                    "The query was still running after 90s.",
                    "Ask for a shorter range, a coarser granularity, or fewer breakdown series.",
                ));
            }
            report_progress("Roblox is still computing the query");
            tokio::time::sleep(Duration::from_millis(poll_delay_ms(attempt, 2_000, 500))).await;
            attempt += 1;
            op = call(credentials, &Call::get(format!("/analytics-query-api/{path}"), ANALYTICS_SCOPE)).await?;
        }
        Ok(op)
    }
    .await;
    let op = match outcome {
        Err(e) if e.code == "RATE_LIMITED" && e.message.to_lowercase().contains("budget") => {
            return Err(ToolError::hint(
                "TOO_MUCH_DATA",
                "That query would return more data points than Roblox allows in one answer.",
                "Ask for a shorter range, a coarser granularity (OneWeek instead of OneDay), or cap the breakdown with `limit`.",
            ));
        }
        other => other?,
    };
    if let Some(err) = op.get("error").filter(|e| !e.is_null()) {
        let why = err.get("message").and_then(Value::as_str).map(str::to_string).or_else(|| err.get("code").map(to_flat)).unwrap_or_else(|| "no reason given".into());
        return Err(ToolError::hint(
            "QUERY_FAILED",
            format!("Roblox could not answer the query: {why}"),
            "Check the metric name, and that it supports this granularity and these breakdown dimensions.",
        ));
    }
    Ok(op)
}

fn number_text(v: Option<&Value>) -> String {
    match v {
        Some(Value::Number(n)) => {
            let f = n.as_f64().unwrap_or(0.0);
            if f.fract() == 0.0 { format!("{}", f as i64) } else { trim_float(&format!("{:.*e}", 4, f)) }
        }
        Some(Value::String(s)) => s.clone(),
        Some(Value::Null) | None => String::new(),
        Some(other) => to_flat(other),
    }
}

/// Five significant digits, printed the way JavaScript's Number(x.toPrecision(5)) would.
fn trim_float(sci: &str) -> String {
    sci.parse::<f64>().map(|f| to_flat(&json!(f))).unwrap_or_else(|_| sci.to_string())
}

fn num_f(f: f64) -> String {
    number_text(Some(&json!(f)))
}

/// One query as text: a summary per series, then the points.
pub fn render_series(q: &MetricQuery, op: &Value) -> String {
    let series = op.pointer("/response/values").and_then(Value::as_array).cloned().unwrap_or_default();
    let filtered = q
        .filter
        .as_ref()
        .filter(|f| !f.is_empty())
        .map(|f| {
            let parts: Vec<String> = f
                .iter()
                .map(|x| {
                    let values: Vec<String> = x.get("values").and_then(Value::as_array).map(|v| v.iter().map(|s| number_text(Some(s))).collect()).unwrap_or_default();
                    format!("{}={}", number_text(x.get("dimension")), values.join("|"))
                })
                .collect();
            format!(", filtered by {}", parts.join(", "))
        })
        .unwrap_or_default();
    let heading = format!(
        "{}, {}, {} to {} (end exclusive, UTC){filtered}",
        q.metric,
        q.granularity,
        q.start.chars().take(10).collect::<String>(),
        q.end.chars().take(10).collect::<String>()
    );
    let points_of = |s: &Value| s.get("dataPoints").and_then(Value::as_array).cloned().unwrap_or_default();
    if series.is_empty() || series.iter().all(|s| points_of(s).is_empty()) {
        return format!(
            "{heading}\n\nNo data for that range. A metric with no traffic, a range before the game had players, or a metric that does not apply to this game all read like this."
        );
    }
    let blocks: Vec<String> = series
        .iter()
        .map(|s| {
            let label: Vec<String> = s
                .get("breakdowns")
                .and_then(Value::as_array)
                .map(|b| {
                    b.iter()
                        .map(|item| match item.get("value") {
                            Some(v) => format!("{}={}", item.get("dimension").map(|d| number_text(Some(d))).unwrap_or_else(|| "?".into()), number_text(Some(v))),
                            None => to_flat(item),
                        })
                        .collect()
                })
                .unwrap_or_default();
            let points = points_of(s);
            let numbers: Vec<f64> = points
                .iter()
                .filter_map(|p| match p.get("value") {
                    Some(Value::Number(n)) => n.as_f64(),
                    Some(Value::String(t)) => t.parse::<f64>().ok(),
                    _ => None,
                })
                .filter(|f| f.is_finite())
                .collect();
            let summary = if numbers.is_empty() {
                format!("{} point(s)", points.len())
            } else {
                let min = numbers.iter().cloned().fold(f64::INFINITY, f64::min);
                let max = numbers.iter().cloned().fold(f64::NEG_INFINITY, f64::max);
                let mean = numbers.iter().sum::<f64>() / numbers.len() as f64;
                format!(
                    "{} point(s): latest {}, min {}, max {}, mean {}",
                    points.len(),
                    number_text(points.last().and_then(|p| p.get("value"))),
                    num_f(min),
                    num_f(max),
                    num_f(mean)
                )
            };
            let shown = &points[points.len().saturating_sub(60)..];
            let mut lines = vec![if label.is_empty() { summary } else { format!("[{}] {summary}", label.join(", ")) }];
            if points.len() > shown.len() {
                lines.push(format!("(latest {} shown; the summary covers all {})", shown.len(), points.len()));
            }
            for p in shown {
                let time = p.get("time").and_then(Value::as_str).unwrap_or("");
                lines.push(format!("{}  {}", time.strip_suffix("T00:00:00Z").unwrap_or(time), number_text(p.get("value"))));
            }
            lines.join("\n")
        })
        .collect();
    format!("{heading}\n\n{}", blocks.join("\n\n"))
}

// --- products and passes --------------------------------------------------------------

struct Api {
    base: fn(&str) -> String,
    field: &'static str,
    read: &'static str,
    write: &'static str,
}

fn api(kind: &str) -> Api {
    if kind == "pass" {
        Api {
            base: |u| format!("/game-passes/v1/universes/{}/game-passes", enc(u)),
            field: "gamePasses",
            read: "game-pass:read",
            write: "game-pass:write",
        }
    } else {
        Api {
            base: |u| format!("/developer-products/v2/universes/{}/developer-products", enc(u)),
            field: "developerProducts",
            read: "developer-product:read",
            write: "developer-product:write",
        }
    }
}

fn item_row(kind: &str, item: &Value) -> Value {
    prune(json!({
        "kind": kind,
        "id": item.get("productId").or_else(|| item.get("gamePassId")),
        "name": item.get("name"),
        "price": item.pointer("/priceInformation/defaultPriceInRobux"),
        "forSale": item.get("isForSale").and_then(Value::as_bool).unwrap_or(false),
        "created": item.get("createdTimestamp").and_then(Value::as_str).map(|t| t.chars().take(10).collect::<String>()),
    }))
}

async fn list_kind(credentials: &Credentials, universe: &str, kind: &str) -> Result<Vec<Value>> {
    let a = api(kind);
    let mut found = Vec::new();
    let mut token: Option<String> = None;
    for _ in 0..20 {
        let r = call(
            credentials,
            &Call::get(format!("{}/creator", (a.base)(universe)), a.read).query("pageSize", 50).query_opt("pageToken", token.clone()),
        )
        .await?;
        for item in r.get(a.field).and_then(Value::as_array).into_iter().flatten() {
            found.push(item_row(kind, item));
        }
        token = r.get("nextPageToken").and_then(Value::as_str).filter(|t| !t.is_empty()).map(str::to_string);
        if token.is_none() {
            break;
        }
    }
    Ok(found)
}

pub async fn list_items(credentials: &Credentials, universe: &str, kind: Option<&str>) -> Result<Vec<Value>> {
    let kinds: Vec<&str> = kind.map(|k| vec![k]).unwrap_or_else(|| vec!["product", "pass"]);
    let lists = futures::future::try_join_all(kinds.iter().map(|k| list_kind(credentials, universe, k))).await?;
    Ok(lists.into_iter().flatten().collect())
}

pub struct SaveItem<'a> {
    pub universe: &'a str,
    pub kind: &'a str,
    pub id: Option<&'a str>,
    pub name: Option<&'a str>,
    pub description: Option<&'a str>,
    pub price: Option<u64>,
    pub for_sale: Option<bool>,
    pub image: Option<&'a str>,
}

/// Creates (refusing a duplicate name) or updates a product or pass.
pub async fn save_item(credentials: &Credentials, s: SaveItem<'_>) -> Result<Value> {
    let a = api(s.kind);
    let label = if s.kind == "product" { "developer product" } else { "game pass" };
    if s.id.is_none() {
        let name = s.name.ok_or_else(|| ToolError::bad_params(format!("Creating a {label} needs a `name`.")))?;
        if let Some(existing) = list_kind(credentials, s.universe, s.kind)
            .await?
            .into_iter()
            .find(|i| i.get("name").and_then(Value::as_str).is_some_and(|n| n.to_lowercase() == name.to_lowercase()))
        {
            return Err(ToolError::hint(
                "ALREADY_EXISTS",
                format!(
                    "This game already has a {label} called \"{}\" (id {}).",
                    existing.get("name").and_then(Value::as_str).unwrap_or(""),
                    existing.get("id").map(to_flat).unwrap_or_default()
                ),
                "Pass that id as `itemId` to change it, or pick a different name.",
            ));
        }
    }
    let image = match s.image {
        None => None,
        Some(file) => {
            let path = std::path::absolute(file).unwrap_or_else(|_| file.into());
            let ext = path.extension().map(|e| e.to_string_lossy().to_lowercase()).unwrap_or_default();
            let mime = match ext.as_str() {
                "png" => "image/png",
                "jpg" | "jpeg" => "image/jpeg",
                "bmp" => "image/bmp",
                "tga" => "image/x-tga",
                _ => {
                    return Err(ToolError::bad_params(format!(
                        "`image` must be a .png, .jpg, .bmp or .tga file, not {}.",
                        path.file_name().map(|f| f.to_string_lossy().into_owned()).unwrap_or_default()
                    )));
                }
            };
            let bytes = tokio::fs::read(&path).await.map_err(|e| ToolError::bad_params(format!("Could not read {}: {e}", path.display())))?;
            Some((bytes, mime, path.file_name().map(|f| f.to_string_lossy().into_owned()).unwrap_or_default()))
        }
    };
    let (name, description) = (s.name.map(str::to_string), s.description.map(str::to_string));
    let (price, for_sale) = (s.price, s.for_sale);
    let form = move || {
        let mut f = reqwest::multipart::Form::new();
        if let Some(n) = &name {
            f = f.text("name", n.clone());
        }
        if let Some(d) = &description {
            f = f.text("description", d.clone());
        }
        if let Some(p) = price {
            f = f.text("price", p.to_string());
        }
        if let Some(fs) = for_sale {
            f = f.text("isForSale", fs.to_string());
        }
        if let Some((bytes, mime, file)) = &image {
            let part = reqwest::multipart::Part::bytes(bytes.clone()).file_name(file.clone()).mime_str(mime).unwrap_or_else(|_| reqwest::multipart::Part::bytes(bytes.clone()));
            f = f.part("imageFile", part);
        }
        f
    };
    let request = match s.id {
        None => Call::post((a.base)(s.universe), a.write),
        Some(id) => Call::patch(format!("{}/{}", (a.base)(s.universe), enc(id)), a.write),
    }
    .form(form);
    let saved = call(credentials, &request).await?;
    let mut row = item_row(s.kind, &saved);
    if row.get("id").is_none()
        && let Some(id) = s.id {
            row["id"] = id.parse::<i64>().map(|n| json!(n)).unwrap_or(json!(id));
        }
    row["action"] = json!(if s.id.is_none() { "created" } else { "updated" });
    Ok(row)
}

// --- scheduled events ------------------------------------------------------------------

const EVENTS: &str = "/virtual-events/v3";

fn event_row(e: &Value) -> Value {
    prune(json!({
        "id": e.get("id"),
        "title": e.get("title"),
        "start": e.get("startTime"),
        "end": e.get("endTime"),
        "visibility": match e.get("visibility") {
            Some(Value::String(s)) => Some(json!(s)),
            None | Some(Value::Null) => None,
            Some(other) => Some(json!(to_flat(other))),
        },
    }))
}

pub async fn list_events(credentials: &Credentials, universe: &str, limit: usize) -> Result<(Vec<Value>, bool)> {
    let mut items = Vec::new();
    let mut token: Option<String> = None;
    for _ in 0..20 {
        let r = call(
            credentials,
            &Call::get(format!("{EVENTS}/universes/{}/game-events", enc(universe)), "universe.event:read")
                .query("pageSize", (limit - items.len()).min(100))
                .query_opt("pageToken", token.clone())
                .query("fields", "id,title,subtitle,startTime,endTime,visibility"),
        )
        .await?;
        items.extend(r.get("gameEvents").and_then(Value::as_array).into_iter().flatten().map(event_row));
        token = r.get("nextPageToken").and_then(Value::as_str).filter(|t| !t.is_empty()).map(str::to_string);
        if token.is_none() || items.len() >= limit {
            break;
        }
    }
    let more = token.is_some() || items.len() > limit;
    items.truncate(limit);
    Ok((items, more))
}

pub async fn get_event(credentials: &Credentials, id: &str) -> Result<Value> {
    call(credentials, &Call::get(format!("{EVENTS}/game-events/{}", enc(id)), "universe.event:read").query("fields", "*")).await
}

pub struct EventFields<'a> {
    pub title: Option<&'a str>,
    pub subtitle: Option<&'a str>,
    pub description: Option<&'a str>,
    pub start: Option<&'a str>,
    pub end: Option<&'a str>,
    pub visibility: Option<&'a str>,
}

pub async fn save_event(credentials: &Credentials, universe: &str, id: Option<&str>, f: EventFields<'_>) -> Result<Value> {
    let body = prune(json!({
        "title": f.title, "subtitle": f.subtitle, "description": f.description,
        "startTime": f.start, "endTime": f.end, "visibility": f.visibility,
    }));
    match id {
        None => {
            let missing: Vec<&str> = [("title", f.title), ("startTime", f.start), ("endTime", f.end)]
                .iter()
                .filter(|(_, v)| v.is_none())
                .map(|(n, _)| *n)
                .collect();
            if !missing.is_empty() {
                return Err(ToolError::hint(
                    "BAD_PARAMS",
                    format!("A new event needs {}.", missing.iter().map(|m| format!("`{m}`")).collect::<Vec<_>>().join(", ")),
                    "Times are ISO 8601 in UTC, e.g. 2026-11-07T18:00:00Z. Pass `eventId` instead to change an event that exists.",
                ));
            }
        }
        Some(_) if body.as_object().is_some_and(|b| b.is_empty()) => {
            return Err(ToolError::bad_params(
                "Nothing to change: pass at least one of title, subtitle, description, startTime, endTime, visibility.",
            ));
        }
        _ => {}
    }
    let request = match id {
        None => Call::post(format!("{EVENTS}/universes/{}/game-events", enc(universe)), "universe.event:write"),
        Some(id) => Call::patch(format!("{EVENTS}/game-events/{}", enc(id)), "universe.event:write"),
    }
    .json(body);
    let saved = call(credentials, &request).await?;
    let mut out = json!({ "action": if id.is_none() { "created" } else { "updated" } });
    if let Some(row) = event_row(&saved).as_object() {
        for (k, v) in row {
            out[k] = v.clone();
        }
    }
    if let Some(d) = saved.get("description").filter(|d| !d.is_null()) {
        out["description"] = d.clone();
    }
    Ok(out)
}

pub async fn cancel_event(credentials: &Credentials, id: &str) -> Result<Value> {
    call(credentials, &Call::delete(format!("{EVENTS}/game-events/{}", enc(id)), "universe.event:write")).await?;
    Ok(json!({ "action": "cancelled", "id": id }))
}

#[cfg(test)]
mod tests {
    #[test]
    fn filters_parse() {
        let f = super::parse_filter("Platform=Phone,Tablet;Country=US").unwrap();
        assert_eq!(f.len(), 2);
        assert!(super::parse_filter("nope").is_err());
    }

    #[test]
    fn numbers_print_like_js() {
        assert_eq!(super::num_f(1.0), "1");
        assert_eq!(super::num_f(1.234567), "1.2346");
    }
}
