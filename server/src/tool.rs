//! Tool registration: typed arguments, a schema derived from the same type,
//! validation against that schema, and one error boundary.

use std::sync::atomic::{AtomicBool, Ordering};
use crate::bridge::StudioBridge;
use crate::errors::{Result, ToolError};
use crate::format::{ToolResult, error_text};
use futures::future::BoxFuture;
use parking_lot::Mutex;
use schemars::JsonSchema;
use serde::de::DeserializeOwned;
use serde_json::{Map, Value, json};
use std::future::Future;
use std::sync::{Arc, LazyLock};

pub struct Ctx {
    pub bridge: Arc<StudioBridge>,
}

pub type Handler = Box<dyn Fn(Arc<Ctx>, Value) -> BoxFuture<'static, Result<ToolResult>> + Send + Sync>;

pub struct Tool {
    pub name: &'static str,
    pub title: &'static str,
    pub description: String,
    pub schema: Value,
    pub read_only: bool,
    pub destructive: bool,
    pub idempotent: bool,
    pub handler: Handler,
}

/// Annotations: read-only tools are idempotent and non-destructive by default.
#[derive(Clone, Copy)]
pub struct Spec {
    pub name: &'static str,
    pub title: &'static str,
    pub read_only: bool,
    pub destructive: Option<bool>,
    pub idempotent: Option<bool>,
}

pub const fn spec(name: &'static str, title: &'static str) -> Spec {
    Spec { name, title, read_only: false, destructive: None, idempotent: None }
}

impl Spec {
    pub const fn read_only(mut self) -> Self {
        self.read_only = true;
        self
    }
    pub const fn destructive(mut self, value: bool) -> Self {
        self.destructive = Some(value);
        self
    }
    pub const fn idempotent(mut self, value: bool) -> Self {
        self.idempotent = Some(value);
        self
    }
}

pub fn schema_for<A: JsonSchema>() -> Value {
    let settings = schemars::generate::SchemaSettings::draft2020_12().with(|s| {
        s.inline_subschemas = true;
    });
    let schema = settings.into_generator().into_root_schema_for::<A>();
    let mut value = serde_json::to_value(schema).unwrap_or_else(|_| json!({}));
    if let Some(map) = value.as_object_mut() {
        map.remove("$schema");
        map.remove("title");
        map.remove("description");
        map.entry("type").or_insert_with(|| json!("object"));
        map.entry("properties").or_insert_with(|| json!({}));
        clean(map);
    }
    value
}

/// Drops schemars noise agents do not need: `format` on integers, `null`
/// alternatives for optional fields, and empty requireds.
fn clean(map: &mut Map<String, Value>) {
    if let Some(Value::String(f)) = map.get("format")
        && (f.starts_with("uint") || f.starts_with("int") || f == "double" || f == "float") {
            map.remove("format");
        }
    if let Some(Value::Array(types)) = map.get("type") {
        let kept: Vec<Value> = types.iter().filter(|t| t.as_str() != Some("null")).cloned().collect();
        if kept.len() == 1 {
            map.insert("type".into(), kept[0].clone());
        } else {
            map.insert("type".into(), Value::Array(kept));
        }
    }
    for key in ["anyOf", "oneOf"] {
        if let Some(Value::Array(options)) = map.get(key) {
            let kept: Vec<Value> = options.iter().filter(|o| o.get("type").and_then(Value::as_str) != Some("null")).cloned().collect();
            if kept.len() == 1 && kept.len() != options.len() {
                map.remove(key);
                if let Value::Object(inner) = kept[0].clone() {
                    for (k, v) in inner {
                        map.entry(k).or_insert(v);
                    }
                }
            } else {
                map.insert(key.into(), Value::Array(kept));
            }
        }
    }
    if let Some(Value::Array(enums)) = map.get_mut("enum") {
        enums.retain(|v| !v.is_null());
    }
    if map.get("required").and_then(Value::as_array).is_some_and(Vec::is_empty) {
        map.remove("required");
    }
    for value in map.values_mut() {
        match value {
            Value::Object(child) => clean(child),
            Value::Array(items) => {
                for item in items {
                    if let Value::Object(child) = item {
                        clean(child);
                    }
                }
            }
            _ => {}
        }
    }
}

/// Validates `value` against the subset of JSON Schema the tool schemas use.
pub fn validate(schema: &Value, value: &Value, path: &str, errors: &mut Vec<String>) {
    let at = if path.is_empty() { "input".to_string() } else { path.to_string() };
    if value.is_null() {
        return; // optional fields arrive absent or null; serde handles required ones
    }
    if let Some(options) = schema.get("anyOf").or_else(|| schema.get("oneOf")).and_then(Value::as_array) {
        let ok = options.iter().any(|o| {
            let mut e = Vec::new();
            validate(o, value, path, &mut e);
            e.is_empty()
        });
        if !ok {
            errors.push(format!("{at}: does not match any allowed shape"));
        }
        return;
    }
    if let Some(expected) = schema.get("const")
        && expected != value {
            errors.push(format!("{at}: must be {expected}"));
        }
    if let Some(allowed) = schema.get("enum").and_then(Value::as_array)
        && !allowed.contains(value) {
            let names: Vec<String> = allowed.iter().map(|v| v.to_string()).collect();
            errors.push(format!("{at}: must be one of {}", names.join(", ")));
            return;
        }
    let types: Vec<&str> = match schema.get("type") {
        Some(Value::String(t)) => vec![t.as_str()],
        Some(Value::Array(ts)) => ts.iter().filter_map(Value::as_str).collect(),
        _ => vec![],
    };
    if !types.is_empty() {
        let fits = types.iter().any(|t| match *t {
            "object" => value.is_object(),
            "array" => value.is_array(),
            "string" => value.is_string(),
            "boolean" => value.is_boolean(),
            "integer" => value.as_f64().is_some_and(|f| f.fract() == 0.0),
            "number" => value.is_number(),
            _ => true,
        });
        if !fits {
            errors.push(format!("{at}: expected {}", types.join(" or ")));
            return;
        }
    }
    if let Some(n) = value.as_f64() {
        if let Some(min) = schema.get("minimum").and_then(Value::as_f64)
            && n < min {
                errors.push(format!("{at}: must be >= {min}"));
            }
        if let Some(max) = schema.get("maximum").and_then(Value::as_f64)
            && n > max {
                errors.push(format!("{at}: must be <= {max}"));
            }
    }
    if let Some(s) = value.as_str() {
        let len = s.chars().count() as u64;
        if let Some(min) = schema.get("minLength").and_then(Value::as_u64)
            && len < min {
                errors.push(format!("{at}: must be at least {min} characters"));
            }
        if let Some(max) = schema.get("maxLength").and_then(Value::as_u64)
            && len > max {
                errors.push(format!("{at}: must be at most {max} characters"));
            }
    }
    if let Some(items) = value.as_array() {
        if let Some(min) = schema.get("minItems").and_then(Value::as_u64)
            && (items.len() as u64) < min {
                errors.push(format!("{at}: needs at least {min} item(s)"));
            }
        if let Some(max) = schema.get("maxItems").and_then(Value::as_u64)
            && items.len() as u64 > max {
                errors.push(format!("{at}: allows at most {max} item(s)"));
            }
        if let Some(item_schema) = schema.get("items") {
            for (i, item) in items.iter().enumerate() {
                validate(item_schema, item, &format!("{at}[{i}]"), errors);
            }
        }
    }
    if let Some(map) = value.as_object() {
        if let Some(props) = schema.get("properties").and_then(Value::as_object) {
            for (key, prop_schema) in props {
                if let Some(v) = map.get(key) {
                    let child = if path.is_empty() { key.clone() } else { format!("{path}.{key}") };
                    validate(prop_schema, v, &child, errors);
                }
            }
        }
        if let Some(required) = schema.get("required").and_then(Value::as_array) {
            for key in required.iter().filter_map(Value::as_str) {
                if map.get(key).is_none_or(Value::is_null) {
                    let child = if path.is_empty() { key.to_string() } else { format!("{path}.{key}") };
                    errors.push(format!("{child}: required"));
                }
            }
        }
        if let Some(extra) = schema.get("additionalProperties").filter(|a| a.is_object()) {
            let known = schema.get("properties").and_then(Value::as_object);
            for (key, v) in map {
                if known.is_none_or(|k| !k.contains_key(key)) {
                    validate(extra, v, &format!("{at}.{key}"), errors);
                }
            }
        }
    }
}

pub fn define<A, F, Fut>(spec: Spec, description: impl Into<String>, handler: F) -> Tool
where
    A: DeserializeOwned + JsonSchema + Send + 'static,
    F: Fn(Arc<Ctx>, A) -> Fut + Send + Sync + 'static,
    Fut: Future<Output = Result<ToolResult>> + Send + 'static,
{
    let schema = schema_for::<A>();
    let validator = schema.clone();
    let handler = Arc::new(handler);
    Tool {
        name: spec.name,
        title: spec.title,
        description: description.into(),
        schema,
        read_only: spec.read_only,
        destructive: spec.destructive.unwrap_or(!spec.read_only),
        idempotent: spec.idempotent.unwrap_or(spec.read_only),
        handler: Box::new(move |ctx, raw| {
            let handler = handler.clone();
            let mut errors = Vec::new();
            let raw = if raw.is_null() { json!({}) } else { raw };
            validate(&validator, &raw, "", &mut errors);
            Box::pin(async move {
                if !errors.is_empty() {
                    return Err(ToolError::new("BAD_PARAMS", format!("Invalid arguments: {}", errors.join("; "))));
                }
                let args: A = serde_json::from_value(raw)
                    .map_err(|e| ToolError::new("BAD_PARAMS", format!("Invalid arguments: {e}")))?;
                handler(ctx, args).await
            })
        }),
    }
}

impl Tool {
    pub fn listing(&self) -> Value {
        json!({
            "name": self.name,
            "title": self.title,
            "description": self.description,
            "inputSchema": self.schema,
            "annotations": {
                "title": self.title,
                "readOnlyHint": self.read_only,
                "destructiveHint": self.destructive,
                "idempotentHint": self.idempotent,
                "openWorldHint": true,
            }
        })
    }
}

/// Runs a tool, turning any failure into agent-readable error content and
/// attaching queued background notices.
pub async fn invoke(tool: &Tool, ctx: Arc<Ctx>, args: Value, progress: Arc<Mutex<Option<String>>>) -> ToolResult {
    let bridge = ctx.bridge.clone();
    let fut = (tool.handler)(ctx, args);
    let sent = Arc::new(AtomicBool::new(false));
    // Its own task, so a panicking tool costs one call rather than the bridge.
    let mut result = match tokio::spawn(SENT.scope(sent.clone(), PROGRESS.scope(progress, fut))).await {
        Ok(Ok(result)) => result,
        Ok(Err(e)) => {
            // Refused before it reached Studio: the panel never saw the call,
            // so tell it, or the failure is invisible there.
            if !sent.load(Ordering::Relaxed) && !matches!(e.code.as_str(), "NO_STUDIO" | "AMBIGUOUS_STUDIO" | "UNKNOWN_STUDIO" | "PLAYTEST_MOVED" | "PLAYTEST_GONE") {
                bridge.announce_refused(tool.title, &e.code);
            }
            error_text(e.render())
        }
        Err(join) => error_text(format!(
            "[INTERNAL] {}",
            if join.is_panic() { "the tool panicked; the server is still running" } else { "the call was cancelled" }
        )),
    };
    if let Some(notice) = take_notices() {
        result.push_text(notice);
    }
    result
}

// --- background notices ------------------------------------------------------

static NOTICES: LazyLock<Mutex<Vec<String>>> = LazyLock::new(Default::default);
const NOTICE_LIMIT: usize = 10;

/// Queues news (sync watch conflicts and errors) for the next tool reply.
pub fn push_notice(message: impl Into<String>) {
    let message = message.into();
    let mut queue = NOTICES.lock();
    if queue.contains(&message) {
        return;
    }
    queue.push(message);
    if queue.len() > NOTICE_LIMIT {
        queue.remove(0);
    }
}

pub fn take_notices() -> Option<String> {
    let mut queue = NOTICES.lock();
    if queue.is_empty() {
        return None;
    }
    let text = queue.iter().map(|l| format!("- {l}")).collect::<Vec<_>>().join("\n");
    queue.clear();
    Some(format!("[sync watch]\n{text}"))
}

// --- progress ----------------------------------------------------------------------

tokio::task_local! {
    pub static PROGRESS: Arc<Mutex<Option<String>>>;
    /// Set once the running call has sent anything to Studio.
    pub static SENT: Arc<AtomicBool>;
}

/// Records that the running call reached Studio.
pub fn mark_sent() {
    let _ = SENT.try_with(|flag| flag.store(true, Ordering::Relaxed));
}

/// Says what the running call is waiting on, for the next progress heartbeat.
pub fn report_progress(note: impl Into<String>) {
    let note = note.into();
    let _ = PROGRESS.try_with(|slot| *slot.lock() = Some(note));
}
