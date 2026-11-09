//! Rendering tool results within a response budget.
//!
//! Everything that can grow is paged rather than truncated silently, and every
//! clip says so, so an agent never mistakes part of an answer for all of it.

use crate::errors::{Result, ToolError};
use base64::Engine;
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use serde_json::{Map, Value};
use std::fmt::Write;

/// Hard ceiling on one tool response, in characters (~6k tokens).
pub const CHARACTER_LIMIT: usize = 25_000;
pub const DEFAULT_PAGE_SIZE: u32 = 100;
pub const MAX_PAGE_SIZE: u32 = 500;
const COMPACT_WIDTH: usize = 100;

#[derive(Debug, Clone, serde::Serialize)]
#[serde(tag = "type", rename_all = "lowercase")]
pub enum Content {
    Text { text: String },
    Image { data: String, #[serde(rename = "mimeType")] mime_type: String },
}

#[derive(Debug, Clone, Default)]
pub struct ToolResult {
    pub content: Vec<Content>,
    pub is_error: bool,
}

impl ToolResult {
    pub fn to_json(&self) -> Value {
        let mut out = Map::new();
        out.insert("content".into(), serde_json::to_value(&self.content).unwrap_or(Value::Null));
        if self.is_error {
            out.insert("isError".into(), Value::Bool(true));
        }
        Value::Object(out)
    }

    pub fn push_text(&mut self, body: impl Into<String>) {
        self.content.push(Content::Text { text: body.into() });
    }

    /// The rendered text, for stitching one helper's output into another.
    pub fn text_of(&self) -> String {
        self.content
            .iter()
            .filter_map(|part| match part {
                Content::Text { text } => Some(text.as_str()),
                _ => None,
            })
            .collect::<Vec<_>>()
            .join("\n")
    }
}

pub fn text(body: impl Into<String>) -> ToolResult {
    ToolResult { content: vec![Content::Text { text: body.into() }], is_error: false }
}

pub fn error_text(body: impl Into<String>) -> ToolResult {
    ToolResult { content: vec![Content::Text { text: body.into() }], is_error: true }
}

/// An image the model can look at, with the caption it cannot recover from pixels.
pub fn image(data: String, caption: impl Into<String>, mime_type: &str) -> ToolResult {
    ToolResult {
        content: vec![
            Content::Image { data, mime_type: mime_type.into() },
            Content::Text { text: caption.into() },
        ],
        is_error: false,
    }
}

pub fn encode_cursor(offset: u64) -> String {
    URL_SAFE_NO_PAD.encode(offset.to_string())
}

/// Decodes a page cursor, refusing one this server did not issue.
pub fn decode_cursor(cursor: Option<&str>) -> Result<u64> {
    let Some(cursor) = cursor.filter(|c| !c.is_empty()) else { return Ok(0) };
    let decoded = URL_SAFE_NO_PAD
        .decode(cursor.trim_end_matches('='))
        .ok()
        .and_then(|bytes| String::from_utf8(bytes).ok());
    match decoded.as_deref().map(str::trim).and_then(|s| s.parse::<u64>().ok().filter(|n| n.to_string() == s)) {
        Some(offset) => Ok(offset),
        None => Err(ToolError::hint(
            "BAD_CURSOR",
            format!("{} is not a cursor this server issued.", Value::String(cursor.into())),
            "Cursors are opaque — pass back the exact `nextCursor` string from the \
             previous page, or omit it to start from the beginning.",
        )),
    }
}

/// Writes a JSON number the way JavaScript prints it: whole floats without `.0`.
fn write_number(out: &mut String, n: &serde_json::Number) {
    if let Some(f) = n.as_f64().filter(|_| n.is_f64()) {
        if f.is_finite() && f.fract() == 0.0 && f.abs() < 1e21 {
            let _ = write!(out, "{}", f as i64);
            return;
        }
        if !f.is_finite() {
            out.push_str("null");
            return;
        }
    }
    let _ = write!(out, "{n}");
}

/// `JSON.stringify(value)` with no whitespace.
pub fn to_flat(value: &Value) -> String {
    let mut out = String::new();
    write_flat(value, &mut out);
    out
}

fn write_flat(value: &Value, out: &mut String) {
    match value {
        Value::Null => out.push_str("null"),
        Value::Bool(b) => out.push_str(if *b { "true" } else { "false" }),
        Value::Number(n) => write_number(out, n),
        Value::String(s) => write_str(out, s),
        Value::Array(items) => {
            out.push('[');
            for (i, item) in items.iter().enumerate() {
                if i > 0 {
                    out.push(',');
                }
                write_flat(item, out);
            }
            out.push(']');
        }
        Value::Object(map) => {
            out.push('{');
            for (i, (key, item)) in map.iter().enumerate() {
                if i > 0 {
                    out.push(',');
                }
                write_str(out, key);
                out.push(':');
                write_flat(item, out);
            }
            out.push('}');
        }
    }
}

fn write_str(out: &mut String, s: &str) {
    // serde_json escapes exactly JSON.stringify's set.
    out.push_str(&serde_json::to_string(s).unwrap_or_default());
}

/// JSON for an agent: valid, but a short object or array stays on one line.
pub fn stringify(value: &Value) -> String {
    let mut out = String::new();
    render(value, "", 0, &mut out);
    out
}

fn render(node: &Value, indent: &str, prefix: usize, out: &mut String) {
    let flat = to_flat(node);
    let compound = matches!(node, Value::Array(_) | Value::Object(_));
    if !compound || indent.len() + prefix + flat.len() <= COMPACT_WIDTH {
        out.push_str(&flat);
        return;
    }
    let inner = format!("{indent}  ");
    match node {
        Value::Array(items) => {
            if items.is_empty() {
                out.push_str("[]");
                return;
            }
            out.push_str("[\n");
            for (i, item) in items.iter().enumerate() {
                if i > 0 {
                    out.push_str(",\n");
                }
                out.push_str(&inner);
                render(item, &inner, 0, out);
            }
            out.push('\n');
            out.push_str(indent);
            out.push(']');
        }
        Value::Object(map) => {
            if map.is_empty() {
                out.push_str("{}");
                return;
            }
            out.push_str("{\n");
            for (i, (key, item)) in map.iter().enumerate() {
                if i > 0 {
                    out.push_str(",\n");
                }
                let mut name = String::new();
                write_str(&mut name, key);
                name.push_str(": ");
                out.push_str(&inner);
                out.push_str(&name);
                render(item, &inner, name.len(), out);
            }
            out.push('\n');
            out.push_str(indent);
            out.push('}');
        }
        _ => unreachable!(),
    }
}

#[derive(Default, Clone)]
pub struct PageMeta {
    pub offset: Option<u64>,
    pub total: Option<u64>,
    pub next_cursor: Option<String>,
    pub more: Option<String>,
}

fn continuation(meta: &PageMeta, shown: usize) -> Option<String> {
    if let (Some(offset), Some(total)) = (meta.offset, meta.total) {
        return (offset + (shown as u64) < total).then(|| encode_cursor(offset + shown as u64));
    }
    meta.next_cursor.clone()
}

/// A page of records as JSON plus a trailer saying what was left behind.
pub fn page(items: &[Value], meta: PageMeta) -> ToolResult {
    let budget = CHARACTER_LIMIT - 500;
    let mut parts = Vec::new();
    let mut body = stringify(&Value::Array(items.to_vec()));
    let mut shown = items.len();

    if body.len() > budget {
        let mut kept: Vec<Value> = Vec::new();
        let mut used = 2;
        for item in items {
            let cost = stringify(item).len() + 2;
            if used + cost > budget {
                break;
            }
            used += cost;
            kept.push(item.clone());
        }
        let mut truncated_item = false;
        if kept.is_empty() && !items.is_empty() {
            kept.push(bounded_value(&items[0]));
            truncated_item = true;
        }
        body = if truncated_item { to_flat(&Value::Array(kept.clone())) } else { stringify(&Value::Array(kept.clone())) };
        while body.len() > budget && kept.len() > 1 {
            kept.pop();
            body = stringify(&Value::Array(kept.clone()));
        }
        if body.len() > budget {
            body = to_flat(&Value::Array(vec![bounded_value(&kept[0])]));
            truncated_item = true;
        }
        shown = kept.len();
        parts.push(body);
        if truncated_item {
            parts.push("\n[first item truncated to fit the response budget; narrow properties or detail to retrieve it fully]".into());
        }
        parts.push(format!(
            "\n[{} of {} items dropped: the page exceeded the {CHARACTER_LIMIT}-character response limit. \
             Re-run with a smaller `limit`, or with `detail: \"concise\"` to fit more per page.]",
            items.len() - kept.len(),
            items.len()
        ));
    } else {
        parts.push(body);
    }

    if let Some(total) = meta.total.filter(|t| *t > shown as u64) {
        parts.push(format!("\n[showing {shown} of {total} matches]"));
    }
    if let Some(next) = continuation(&meta, shown) {
        parts.push(format!("\n[more results available — call again with cursor: \"{next}\"]"));
    }
    if let Some(more) = &meta.more {
        parts.push(format!("\n[{more}]"));
    }
    text(parts.concat())
}

fn format_cell(value: Option<&Value>) -> String {
    let cell = match value {
        None | Some(Value::Null) => return String::new(),
        Some(Value::String(s)) => s.clone(),
        Some(v @ (Value::Array(_) | Value::Object(_))) => to_flat(v),
        Some(v) => to_flat(v),
    };
    cell.replace('\n', "\\n").replace('\r', "\\r").replace('|', "\\|")
}

/// Uniform records as a pipe-delimited table: a quarter of the tokens of JSON.
pub fn table(columns: &[&str], rows: &[Value], meta: PageMeta) -> ToolResult {
    if rows.is_empty() {
        return text(meta.more.unwrap_or_else(|| "No matches.".into()));
    }
    let render_row = |row: &Value, clip: Option<usize>| -> String {
        columns
            .iter()
            .map(|c| {
                let cell = format_cell(row.get(*c));
                match clip {
                    Some(n) => cell.chars().take(n).collect(),
                    None => cell,
                }
            })
            .collect::<Vec<_>>()
            .join(" | ")
    };
    let mut lines = vec![columns.join(" | ")];
    let mut used = lines[0].len();
    let mut dropped = 0;
    for row in rows {
        let mut line = render_row(row, None);
        if lines.len() == 1 && line.len() > CHARACTER_LIMIT - 1000 {
            line = render_row(row, Some(1000)) + " [row truncated]";
        }
        if used + line.len() + 1 > CHARACTER_LIMIT - 500 {
            dropped = rows.len() - (lines.len() - 1);
            break;
        }
        used += line.len() + 1;
        lines.push(line);
    }
    let mut trailer = Vec::new();
    if dropped > 0 {
        trailer.push(format!(
            "[{dropped} rows dropped to stay under the {CHARACTER_LIMIT}-character response limit — re-run with a smaller `limit`]"
        ));
    }
    let shown = lines.len() - 1;
    if let Some(total) = meta.total.filter(|t| *t > shown as u64) {
        trailer.push(format!("[showing {shown} of {total} matches]"));
    }
    if let Some(next) = continuation(&meta, shown) {
        trailer.push(format!("[more results — call again with cursor: \"{next}\"]"));
    }
    if let Some(more) = &meta.more {
        trailer.push(format!("[{more}]"));
    }
    if !trailer.is_empty() {
        lines.push(String::new());
        lines.extend(trailer);
    }
    text(lines.join("\n"))
}

/// A plain text body, clipped at the limit with an explicit marker.
pub fn body(content: &str, advice: &str) -> ToolResult {
    if content.len() <= CHARACTER_LIMIT {
        return text(content);
    }
    text(format!(
        "{}\n\n[clipped at {CHARACTER_LIMIT} characters — {advice}]",
        clip_chars(content, CHARACTER_LIMIT - 500)
    ))
}

/// Structured data, clipped with a marker so a clip is never mistaken for the whole.
pub fn json(value: &Value, note: Option<&str>) -> ToolResult {
    let mut body = stringify(value);
    if body.len() > CHARACTER_LIMIT - 500 {
        let mut wrapped = Map::new();
        wrapped.insert("truncated".into(), Value::Bool(true));
        wrapped.insert("data".into(), bounded_value(value));
        body = to_flat(&Value::Object(wrapped));
    }
    match note {
        Some(note) if !note.is_empty() => text(format!("{body}\n\n{}", clip_chars(note, 450))),
        _ => text(body),
    }
}

/// Drops null-valued keys (JavaScript's `undefined`), recursively through objects.
pub fn prune(value: Value) -> Value {
    match value {
        Value::Object(map) => Value::Object(map.into_iter().filter(|(_, v)| !v.is_null()).map(|(k, v)| (k, prune(v))).collect()),
        Value::Array(items) => Value::Array(items.into_iter().map(prune).collect()),
        other => other,
    }
}

/// Byte-safe prefix of at most `max` bytes.
pub fn clip_chars(s: &str, max: usize) -> &str {
    if s.len() <= max {
        return s;
    }
    let mut end = max;
    while !s.is_char_boundary(end) {
        end -= 1;
    }
    &s[..end]
}

/// Valid JSON under one global byte/node budget, even for wide trees.
pub fn bounded_value(value: &Value) -> Value {
    struct Budget {
        remaining: i64,
        nodes: i64,
    }
    fn visit(node: &Value, depth: u32, b: &mut Budget) -> Value {
        b.nodes -= 1;
        if b.nodes < 0 || b.remaining < 100 || depth > 8 {
            return Value::String("<truncated>".into());
        }
        b.remaining -= 30;
        match node {
            Value::String(s) => {
                let quoted = to_flat(node).len() as i64;
                let result = if quoted <= b.remaining {
                    s.clone()
                } else {
                    let keep = (b.remaining - 20).max(0) as usize;
                    format!("{}<truncated>", clip_chars(s, keep.saturating_sub(20)))
                };
                b.remaining -= result.len() as i64 + 2;
                Value::String(result)
            }
            Value::Array(items) => {
                let mut out = Vec::new();
                for child in items {
                    if b.nodes <= 0 || b.remaining < 102 {
                        out.push(Value::String("<truncated>".into()));
                        break;
                    }
                    b.remaining -= 7;
                    out.push(visit(child, depth + 1, b));
                }
                Value::Array(out)
            }
            Value::Object(map) => {
                let mut out = Map::new();
                for (key, child) in map {
                    if b.nodes <= 0 || b.remaining < key.len() as i64 + 102 {
                        out.insert("...".into(), Value::String("<truncated>".into()));
                        break;
                    }
                    b.remaining -= key.len() as i64 + 7;
                    out.insert(key.clone(), visit(child, depth + 1, b));
                }
                Value::Object(out)
            }
            other => {
                b.remaining -= 30;
                other.clone()
            }
        }
    }
    let mut budget = Budget { remaining: (CHARACTER_LIMIT - 2000) as i64, nodes: 500 };
    visit(value, 0, &mut budget)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn compact_short_objects() {
        let v = json!({"a": [1, 2, 3], "b": {"c": 1.0}});
        assert_eq!(stringify(&v), r#"{"a":[1,2,3],"b":{"c":1}}"#);
    }

    #[test]
    fn wraps_wide_objects() {
        let long = "x".repeat(120);
        let v = json!({"a": long, "b": 1});
        let s = stringify(&v);
        assert!(s.starts_with("{\n  \"a\": "));
    }

    #[test]
    fn cursor_round_trip() {
        assert_eq!(decode_cursor(Some(&encode_cursor(150))).unwrap(), 150);
        assert!(decode_cursor(Some("garbage!")).is_err());
        assert_eq!(decode_cursor(None).unwrap(), 0);
    }
}
