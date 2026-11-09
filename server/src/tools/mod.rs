//! Every MCP tool, grouped by area. Shared argument types live here.

use crate::errors::Result;
use crate::format::{DEFAULT_PAGE_SIZE, MAX_PAGE_SIZE};
use crate::tool::{Ctx, Tool};
use schemars::JsonSchema;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

mod session;
mod discover;
mod scripts;
pub mod instances;
mod exec;
mod perf;
pub mod playtest;
mod screenshot;
mod controls;
mod reference;
mod build;
mod character;
mod world;
mod universe;
mod data;
mod sync;

pub fn all() -> Vec<Tool> {
    let mut tools = Vec::new();
    tools.extend(session::tools());
    tools.extend(discover::tools());
    tools.extend(scripts::tools());
    tools.extend(instances::tools());
    tools.extend(exec::tools());
    tools.extend(perf::tools());
    tools.extend(playtest::tools());
    tools.extend(screenshot::tools());
    tools.extend(controls::tools());
    tools.extend(reference::tools());
    tools.extend(build::tools());
    tools.extend(character::tools());
    tools.extend(world::tools());
    tools.extend(universe::tools());
    tools.extend(data::tools());
    tools.extend(sync::tools());
    tools
}

/// Default-value functions referenced by `#[serde(default = ...)]`.
pub mod d {
    pub fn t() -> bool {
        true
    }
    pub fn page() -> u32 {
        super::DEFAULT_PAGE_SIZE
    }
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Deserialize, Serialize, JsonSchema)]
#[serde(rename_all = "lowercase")]
#[schemars(description = "concise: compact identity. standard: selected facts. full: all readable properties for inspect; tree/find use the same columns as standard.")]
pub enum Detail {
    Concise,
    #[default]
    Standard,
    Full,
}


#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Deserialize, Serialize, JsonSchema)]
#[serde(rename_all = "lowercase")]
pub enum ReadSide {
    #[default]
    Studio,
    Client,
}

/// Where a read runs: the selected session, or the playtest's real client VM.
#[derive(Debug, Clone, Default, Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct ReadTarget {
    /// client: read the actual player's playtest VM. Use the playtest server studioId.
    #[serde(default)]
    pub target: ReadSide,
    /// client only: player name; required with multiple players.
    pub player: Option<String>,
}

impl ReadTarget {
    pub fn context(&self) -> Option<String> {
        (self.target == ReadSide::Client).then(|| match &self.player {
            Some(p) => format!("Read from the actual playtest client ({p})."),
            None => "Read from the actual playtest client.".into(),
        })
    }
}

pub fn page_limit_schema(generator: &mut schemars::SchemaGenerator) -> schemars::Schema {
    let _ = generator;
    schemars::json_schema!({
        "type": "integer",
        "minimum": 1,
        "maximum": MAX_PAGE_SIZE,
        "default": DEFAULT_PAGE_SIZE,
        "description": format!("Maximum items to return (1-{MAX_PAGE_SIZE}).")
    })
}

pub const STUDIO_DOC: &str = "Target Studio; omit for the active one.";

pub async fn call(ctx: &Ctx, op: &str, params: Value, studio: Option<&str>, timeout_ms: Option<f64>) -> Result<Value> {
    ctx.bridge.call(op, params, studio, timeout_ms).await
}

/// A read that can be pointed at the playtest client instead of the session.
pub async fn read_call(ctx: &Ctx, op: &str, params: Value, target: &ReadTarget, studio: Option<&str>, timeout_ms: f64) -> Result<Value> {
    if target.target == ReadSide::Client {
        call(ctx, "client.read", json!({ "op": op, "params": params, "player": target.player }), studio, Some(timeout_ms)).await
    } else {
        call(ctx, op, params, studio, Some(timeout_ms)).await
    }
}

/// Joins the non-empty notes with a separator, or None.
pub fn join_notes<I: IntoIterator<Item = Option<String>>>(parts: I, sep: &str) -> Option<String> {
    let kept: Vec<String> = parts.into_iter().flatten().filter(|s| !s.is_empty()).collect();
    (!kept.is_empty()).then(|| kept.join(sep))
}

pub fn str_of<'a>(v: &'a Value, key: &str) -> Option<&'a str> {
    v.get(key).and_then(Value::as_str)
}

pub fn u64_of(v: &Value, key: &str) -> u64 {
    v.get(key).and_then(Value::as_f64).map(|f| f.max(0.0) as u64).unwrap_or(0)
}

pub fn arr_of<'a>(v: &'a Value, key: &str) -> &'a [Value] {
    v.get(key).and_then(Value::as_array).map(Vec::as_slice).unwrap_or(&[])
}

/// Milliseconds since the epoch as an ISO 8601 UTC timestamp.
pub fn iso(ms: u64) -> String {
    let secs = (ms / 1000) as i64;
    let millis = ms % 1000;
    let days = secs.div_euclid(86_400);
    let rem = secs.rem_euclid(86_400);
    let (h, m, s) = (rem / 3600, (rem % 3600) / 60, rem % 60);
    // Civil from days (Howard Hinnant).
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z - era * 146_097;
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let mo = if mp < 10 { mp + 3 } else { mp - 9 };
    let y = if mo <= 2 { y + 1 } else { y };
    format!("{y:04}-{mo:02}-{d:02}T{h:02}:{m:02}:{s:02}.{millis:03}Z")
}


/// `String(value)` as JavaScript prints it: strings bare, numbers without `.0`.
pub fn disp(v: Option<&Value>) -> String {
    match v {
        None | Some(Value::Null) => "undefined".into(),
        Some(Value::String(s)) => s.clone(),
        Some(other) => crate::format::to_flat(other),
    }
}
