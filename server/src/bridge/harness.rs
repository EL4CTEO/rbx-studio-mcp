//! Runs a coding agent on the console panel's behalf.
//!
//! Free text typed into the panel goes to a headless agent CLI, which connects
//! back to this bridge as an ordinary MCP client and drives the same Studio.
//! Its output streams into the console line by line. A registry rather than one
//! integration: adding a CLI is a table entry.

use regex::Regex;
use serde::Serialize;
use serde_json::{Map, Value};
use std::path::PathBuf;
use std::process::Stdio;
use std::sync::{Arc, LazyLock, OnceLock};
use tokio::io::{AsyncBufReadExt, AsyncReadExt, BufReader};
use tokio::sync::{oneshot, watch};

#[derive(Debug, Clone, Serialize)]
pub struct Line {
    pub level: &'static str,
    pub message: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub detail: Option<String>,
}

impl Line {
    pub fn new(level: &'static str, message: impl Into<String>) -> Self {
        Self { level, message: message.into(), detail: None }
    }
    pub fn with(level: &'static str, message: impl Into<String>, detail: impl Into<String>) -> Self {
        Self { level, message: message.into(), detail: Some(detail.into()) }
    }
    pub fn opt(level: &'static str, message: impl Into<String>, detail: Option<String>) -> Self {
        Self { level, message: message.into(), detail }
    }
}

#[derive(Default)]
pub struct Reading {
    pub lines: Vec<Line>,
    pub session: Option<String>,
}

fn reading(lines: Vec<Line>, session: Option<String>) -> Reading {
    Reading { lines, session }
}

type Argv = fn(&str, Option<&str>) -> Vec<String>;
type Reader = fn(&str) -> Reading;

#[derive(Clone, Copy)]
pub enum Mcp {
    None,
    /// `<flag> <path to JSON config>`, appended.
    Config(&'static str),
}

pub struct Harness {
    pub id: &'static str,
    pub label: &'static str,
    pub bin: &'static str,
    pub mcp: Mcp,
    pub argv: Argv,
    pub read: Reader,
}

const OWN_SERVER: &str = "rbx-studio";

fn parse(line: &str) -> Option<Value> {
    let t = line.trim();
    if !(t.starts_with('{') || t.starts_with('[')) {
        return None;
    }
    serde_json::from_str(t).ok()
}

fn unparsed(line: &str) -> Reading {
    let t = line.trim();
    if t.is_empty() { Reading::default() } else { reading(vec![Line::new("dim", t)], None) }
}

fn read_prose(line: &str) -> Reading {
    let t = line.trim();
    if t.is_empty() { Reading::default() } else { reading(vec![Line::new("reply", t)], None) }
}

static OWN_PREFIX: LazyLock<Regex> = LazyLock::new(|| Regex::new(&format!("^{OWN_SERVER}[_-]")).unwrap());
static OWN_STRIP: LazyLock<Regex> = LazyLock::new(|| Regex::new(&format!("^{OWN_SERVER}[_-]+")).unwrap());
static MCP_PREFIX: LazyLock<Regex> = LazyLock::new(|| Regex::new("^mcp__[^_]+__").unwrap());
static SPACE: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"\s+").unwrap());

fn shorten(name: &str) -> String {
    let a = MCP_PREFIX.replace(name, "");
    let b = a.strip_prefix("mcp__").unwrap_or(&a);
    OWN_STRIP.replace(b, "").into_owned()
}

fn is_own_tool(name: &str) -> bool {
    name.starts_with(&format!("mcp__{OWN_SERVER}__")) || OWN_PREFIX.is_match(name)
}

/// Rows for one tool call; none for this server's own tools, which Studio logs itself.
fn tool_lines(name: &str, input: Option<&Value>) -> Vec<Line> {
    // Ours are logged by Studio; ToolSearch is the agent loading its tool list,
    // which happens every turn and tells the reader nothing.
    if is_own_tool(name) || shorten(name).eq_ignore_ascii_case("toolsearch") {
        return vec![];
    }
    vec![Line::new("call", friendly_tool(name, input))]
}

/// An agent's own tool call as a short phrase, never raw `key=value` arguments.
fn friendly_tool(name: &str, input: Option<&Value>) -> String {
    let arg = |keys: &[&str]| {
        input.and_then(|v| keys.iter().find_map(|k| v.get(*k).and_then(Value::as_str))).map(|s| {
            let s = SPACE.replace_all(s, " ");
            // A path reads best as its last part.
            let s = s.rsplit(['/', '\\']).next().unwrap_or(&s).to_string();
            if s.chars().count() > 40 { format!("{}…", s.chars().take(39).collect::<String>()) } else { s }
        })
    };
    let with = |verb: &str, keys: &[&str]| match arg(keys) {
        Some(subject) if !subject.is_empty() => format!("{verb} {subject}"),
        _ => verb.to_string(),
    };
    let lower = shorten(name).to_ascii_lowercase();
    match lower.as_str() {
        "toolsearch" => "Loading tools".into(),
        "read" | "read_file" | "view" => with("Reading", &["file_path", "path"]),
        "edit" | "multiedit" | "write" | "write_file" | "str_replace_editor" => with("Editing", &["file_path", "path"]),
        "bash" | "shell" | "powershell" | "run_shell_command" => "Running a command".into(),
        "grep" | "glob" | "search" => with("Searching", &["pattern"]),
        "webfetch" | "websearch" | "web_search" => "Searching the web".into(),
        "todowrite" | "update_plan" => "Updating its plan".into(),
        "task" | "agent" => "Starting a helper".into(),
        _ => shorten(name),
    }
}

fn tool_lines_str(name: &str, input: &str) -> Vec<Line> {
    // A shell command arrives as a bare string; JS treated non-objects as no detail.
    let _ = input;
    tool_lines(name, None)
}

fn say(text: &str) -> Vec<Line> {
    text.split('\n').map(str::trim).filter(|p| !p.is_empty()).map(|p| Line::new("reply", p)).collect()
}

fn s<'a>(v: &'a Value, key: &str) -> Option<&'a str> {
    v.get(key).and_then(Value::as_str)
}

fn st(v: &Value, key: &str) -> Option<String> {
    s(v, key).map(str::to_string)
}

/// `String(x)` for a JSON value the way JS would print it in a message.
fn js_string(v: Option<&Value>, fallback: &str) -> String {
    match v {
        None | Some(Value::Null) => fallback.to_string(),
        Some(Value::String(s)) => s.clone(),
        Some(Value::Object(_)) => "[object Object]".into(),
        Some(other) => other.to_string(),
    }
}

fn first<'a>(v: &'a Value, keys: &[&str]) -> Option<&'a Value> {
    keys.iter().filter_map(|k| v.get(*k)).find(|x| !x.is_null())
}

fn done_line(failed: bool) -> Line {
    if failed { Line::new("error", "Failed") } else { Line::new("ok", "Done") }
}

// --- adapters --------------------------------------------------------------

fn read_anthropic(line: &str) -> Reading {
    let Some(event) = parse(line) else { return unparsed(line) };
    let kind = s(&event, "type").unwrap_or("");
    if kind == "system" && s(&event, "subtype") == Some("init") {
        return reading(vec![], st(&event, "session_id"));
    }
    if kind == "assistant" {
        let mut lines = vec![];
        for part in event.pointer("/message/content").and_then(Value::as_array).into_iter().flatten() {
            match s(part, "type") {
                Some("text") => {
                    let text = js_string(part.get("text"), "");
                    if !text.trim().is_empty() {
                        lines.extend(say(&text));
                    }
                }
                Some("tool_use") => lines.extend(tool_lines(s(part, "name").unwrap_or(""), part.get("input"))),
                _ => {}
            }
        }
        return reading(lines, st(&event, "session_id"));
    }
    if kind == "result" {
        return reading(vec![done_line(event.get("is_error") == Some(&Value::Bool(true)))], st(&event, "session_id"));
    }
    Reading::default()
}

fn read_claude(line: &str) -> Reading {
    let Some(event) = parse(line) else { return unparsed(line) };
    if s(&event, "type") == Some("result") {
        let took = event.get("duration_ms").and_then(Value::as_f64).map(|d| format!("{:.1} s", d / 1000.0)).unwrap_or_default();
        let failed = event.get("is_error") == Some(&Value::Bool(true));
        // One line: "Done · 35.6 s". No cost: it is noise in a build log.
        let message = [if failed { "Failed" } else { "Done" }.to_string(), took]
            .into_iter()
            .filter(|p| !p.is_empty())
            .collect::<Vec<_>>()
            .join(" · ");
        return reading(vec![Line::new(if failed { "error" } else { "ok" }, message)], st(&event, "session_id"));
    }
    read_anthropic(line)
}

fn read_codex(line: &str) -> Reading {
    let Some(event) = parse(line) else { return unparsed(line) };
    let kind = s(&event, "type").unwrap_or("");
    if kind == "thread.started" {
        return reading(vec![], st(&event, "thread_id"));
    }
    if kind == "turn.completed" {
        return reading(vec![Line::new("ok", "Done")], None);
    }
    if kind == "turn.failed" || kind == "error" {
        let message = event.pointer("/error/message").or_else(|| event.get("message"));
        return reading(vec![Line::new("error", js_string(message, "Failed"))], None);
    }
    let Some(item) = event.get("item") else { return Reading::default() };
    let item_type = s(item, "type").unwrap_or("");
    if item_type == "agent_message" && kind == "item.completed" {
        return reading(say(&js_string(item.get("text"), "")), None);
    }
    if kind == "item.started" {
        if item_type == "mcp_tool_call" {
            if s(item, "server") == Some(OWN_SERVER) {
                return Reading::default();
            }
            return reading(tool_lines(&js_string(item.get("tool"), "tool"), item.get("arguments")), None);
        }
        if item_type == "command_execution" {
            return reading(tool_lines_str("shell", s(item, "command").unwrap_or("")), None);
        }
    }
    if item_type == "error" && kind == "item.completed" {
        return reading(vec![Line::new("error", js_string(item.get("message"), "Failed"))], None);
    }
    Reading::default()
}

fn read_opencode(line: &str) -> Reading {
    let Some(event) = parse(line) else { return unparsed(line) };
    let session = st(&event, "sessionID");
    let kind = s(&event, "type").unwrap_or("");
    let empty = Value::Object(Map::new());
    let part = event.get("part").unwrap_or(&empty);
    if kind == "text"
        && let Some(text) = s(part, "text") {
            return reading(say(text), session);
        }
    if kind == "tool_use"
        && let Some(tool) = s(part, "tool") {
            return reading(tool_lines(tool, part.pointer("/state/input")), session);
        }
    if kind == "error" {
        let message = event.get("error").or_else(|| part.get("error"));
        return reading(vec![Line::new("error", js_string(message, "Failed"))], session);
    }
    reading(vec![], session)
}

fn read_generic(line: &str) -> Reading {
    unparsed(line)
}

fn read_gemini(line: &str) -> Reading {
    let Some(event) = parse(line) else { return unparsed(line) };
    match s(&event, "type").unwrap_or("") {
        "init" => reading(vec![], st(&event, "session_id").or_else(|| st(&event, "sessionId"))),
        "message" => {
            if s(&event, "role") == Some("user") {
                return Reading::default();
            }
            reading(say(&js_string(first(&event, &["content", "text"]), "")), None)
        }
        "tool_use" => reading(
            tool_lines(&js_string(first(&event, &["name", "tool"]), "tool"), first(&event, &["args", "input"])),
            None,
        ),
        "error" => reading(vec![Line::new("error", js_string(event.get("message"), "Failed"))], None),
        "result" => reading(vec![Line::new("ok", "Done")], None),
        _ => Reading::default(),
    }
}

fn read_cursor(line: &str) -> Reading {
    let Some(event) = parse(line) else { return unparsed(line) };
    let session = st(&event, "session_id");
    let kind = s(&event, "type").unwrap_or("");
    if kind == "assistant" {
        let text: String = event
            .pointer("/message/content")
            .and_then(Value::as_array)
            .map(|parts| parts.iter().filter(|p| s(p, "type") == Some("text")).map(|p| js_string(p.get("text"), "")).collect())
            .unwrap_or_default();
        return reading(say(&text), session);
    }
    if kind == "tool_call" && s(&event, "subtype") == Some("started") {
        let call = event.get("tool_call").and_then(Value::as_object);
        let named = call.and_then(|c| c.keys().next().cloned()).unwrap_or_else(|| "tool".into());
        let inner = call.and_then(|c| c.get(&named));
        let name = inner.and_then(|i| s(i, "name")).map(str::to_string).unwrap_or(named);
        return reading(tool_lines(&name, inner.and_then(|i| i.get("args"))), session);
    }
    if kind == "result" {
        return reading(vec![done_line(event.get("is_error") == Some(&Value::Bool(true)))], session);
    }
    if kind == "error" {
        return reading(vec![Line::new("error", js_string(event.get("message"), "Failed"))], session);
    }
    reading(vec![], session)
}

fn read_droid(line: &str) -> Reading {
    let Some(event) = parse(line) else { return unparsed(line) };
    let text = first(&event, &["result", "output", "message", "text"]);
    let session = first(&event, &["session_id", "sessionId"]).and_then(Value::as_str).map(str::to_string);
    match text.and_then(Value::as_str) {
        Some(t) if !t.trim().is_empty() => reading(say(t), session),
        _ => reading(vec![], session),
    }
}

fn read_goose(line: &str) -> Reading {
    let Some(event) = parse(line) else { return unparsed(line) };
    let session = first(&event, &["session_id", "session", "name"]).and_then(Value::as_str).map(str::to_string);
    let kind = s(&event, "type").unwrap_or("");
    if matches!(kind, "text" | "message" | "assistant") {
        let text = first(&event, &["text", "content"]).or_else(|| event.pointer("/message/content"));
        if let Some(t) = text.and_then(Value::as_str) {
            return reading(say(t), session);
        }
    }
    if matches!(kind, "tool_use" | "tool_request") {
        return reading(tool_lines(&js_string(first(&event, &["name", "tool"]), "tool"), event.get("input")), session);
    }
    if kind == "error" {
        return reading(vec![Line::new("error", js_string(event.get("message"), "Failed"))], session);
    }
    reading(vec![], session)
}

const SESSION_KEYS: [&str; 7] = ["session_id", "sessionId", "sessionID", "thread_id", "threadId", "conversation_id", "conversationId"];

fn session_of(event: &Value) -> Option<String> {
    SESSION_KEYS.iter().filter_map(|k| s(event, k)).find(|v| !v.is_empty()).map(str::to_string)
}

fn text_of(value: Option<&Value>) -> String {
    match value {
        Some(Value::String(s)) => s.clone(),
        Some(Value::Array(parts)) => parts
            .iter()
            .map(|part| match part {
                Value::String(s) => s.clone(),
                _ => match s(part, "type") {
                    Some("text") | None => js_string(part.get("text"), ""),
                    _ => String::new(),
                },
            })
            .collect(),
        _ => String::new(),
    }
}

fn args_of(value: Option<&Value>) -> Option<Value> {
    match value {
        Some(Value::String(s)) => serde_json::from_str(s).ok(),
        other => other.cloned(),
    }
}

/// Reads whichever event-stream family a newer CLI copied, by its shape.
fn read_events(line: &str) -> Reading {
    let Some(event) = parse(line).filter(|e| !e.is_array()) else { return unparsed(line) };
    let session = session_of(&event);
    let kind = s(&event, "type").unwrap_or("");
    let role = s(&event, "role");
    let with_session = |r: Reading, session: &Option<String>| Reading { lines: r.lines, session: r.session.or_else(|| session.clone()) };

    if kind == "user" || matches!(role, Some("user" | "tool" | "system")) {
        return reading(vec![], session);
    }
    if matches!(kind, "tool_result" | "observation" | "hook_event" | "team_event") {
        return reading(vec![], session);
    }
    if (kind == "system" && s(&event, "subtype") == Some("init")) || (kind == "assistant" && event.get("message").is_some()) {
        return with_session(read_anthropic(line), &session);
    }
    if kind == "result" {
        let failed = event.get("is_error") == Some(&Value::Bool(true))
            || s(&event, "subtype") == Some("error")
            || s(&event, "status") == Some("error");
        if !failed {
            return reading(vec![Line::new("ok", "Done")], session);
        }
        let reason = match event.get("error") {
            Some(Value::String(e)) => Some(e.clone()),
            Some(e @ Value::Object(_)) => st(e, "message"),
            _ => st(&event, "result"),
        };
        return reading(vec![Line::opt("error", "Failed", reason.map(|r| r.chars().take(200).collect()))], session);
    }
    if event.get("item").is_some() && kind.starts_with("item.") {
        return with_session(read_codex(line), &session);
    }
    if kind == "run_result" {
        let reason = js_string(event.get("finishReason"), "");
        let mut lines = say(&text_of(event.get("text")));
        let lower = reason.to_lowercase();
        lines.push(if lower.contains("error") || lower.contains("fail") {
            Line::with("error", "Failed", reason)
        } else {
            Line::new("ok", "Done")
        });
        return reading(lines, session);
    }
    if kind == "run_aborted" {
        return reading(vec![Line::new("warn", js_string(first(&event, &["message", "reason"]), "agent stopped"))], session);
    }
    if kind == "agent_event" {
        let empty = Value::Object(Map::new());
        let inner = event.get("event").unwrap_or(&empty);
        if s(inner, "type") == Some("error") {
            return reading(vec![Line::new("error", js_string(first(inner, &["message", "error"]), "Failed"))], session);
        }
        let tool = s(inner, "toolName").or_else(|| s(inner, "tool_name")).or_else(|| {
            js_string(inner.get("contentType"), "").to_lowercase().contains("tool").then(|| s(inner, "name")).flatten()
        });
        if s(inner, "type") == Some("content_start")
            && let Some(tool) = tool {
                return reading(tool_lines(tool, args_of(first(inner, &["input", "args"])).as_ref()), session);
            }
        return reading(vec![], session);
    }
    if kind == "action" {
        let action = js_string(event.get("action"), "action");
        if action == "message" || action == "finish" {
            return reading(say(&text_of(first(&event, &["message", "content", "thought", "final_thought"]))), session);
        }
        let mut input = Map::new();
        if let Some(p) = event.get("path") {
            input.insert("path".into(), p.clone());
        }
        if let Some(c) = event.get("command") {
            input.insert("command".into(), c.clone());
        }
        return reading(tool_lines(&action, Some(&Value::Object(input))), session);
    }
    if role == Some("assistant") {
        let mut lines = say(&text_of(event.get("content")));
        for call in event.get("tool_calls").and_then(Value::as_array).into_iter().flatten() {
            let name = call.pointer("/function/name").and_then(Value::as_str).or_else(|| s(call, "name"));
            if let Some(name) = name {
                let args = args_of(call.pointer("/function/arguments").or_else(|| call.get("arguments")));
                lines.extend(tool_lines(name, args.as_ref()));
            }
        }
        return reading(lines, session);
    }
    let empty = Value::Object(Map::new());
    let part = event.get("part").unwrap_or(&empty);
    if kind == "text" || (kind == "message" && role != Some("user")) {
        return reading(say(&text_of(part.get("text").or_else(|| first(&event, &["text", "content"])))), session);
    }
    if matches!(kind, "tool_use" | "tool_call" | "tool_request") {
        let name = part.get("tool").or_else(|| first(&event, &["name", "tool", "tool_name"]));
        let args = args_of(part.pointer("/state/input").or_else(|| first(&event, &["input", "args", "arguments"])));
        return reading(tool_lines(&js_string(name, "tool"), args.as_ref()), session);
    }
    if matches!(kind, "init" | "step_start" | "step_finish") {
        return reading(vec![], session);
    }
    if kind == "error" || event.get("ok") == Some(&Value::Bool(false)) {
        let message = match event.get("error") {
            Some(Value::String(e)) => e.clone(),
            Some(e @ Value::Object(_)) => st(e, "message").unwrap_or_else(|| js_string(event.get("message"), "Failed")),
            _ => js_string(event.get("message"), "Failed"),
        };
        return reading(vec![Line::new("error", message)], session);
    }
    if let Some(payloads) = event.get("payloads").and_then(Value::as_array) {
        return reading(payloads.iter().flat_map(|p| say(&text_of(p.get("text")))).collect(), session);
    }
    reading(say(&text_of(first(&event, &["text", "content", "output", "result", "message"]))), session)
}

// --- registry ---------------------------------------------------------------

macro_rules! v {
    ($($x:expr),* $(,)?) => { vec![$(String::from($x)),*] };
}

fn with_session(mut argv: Vec<String>, flag: &[&str], session: Option<&str>, at_start: bool) -> Vec<String> {
    if let Some(sid) = session {
        let mut pre: Vec<String> = flag.iter().map(|s| s.to_string()).collect();
        pre.push(sid.to_string());
        if at_start {
            pre.extend(argv);
            return pre;
        }
        argv.extend(pre);
    }
    argv
}

pub static REGISTRY: LazyLock<Vec<Harness>> = LazyLock::new(|| {
    vec![
        Harness {
            id: "claude",
            label: "Claude Code",
            bin: "claude",
            mcp: Mcp::Config("--mcp-config"),
            argv: |p, sid| {
                let mut a = with_session(vec![], &["--resume"], sid, true);
                a.extend(v![
                    "--print", p, "--output-format", "stream-json", "--verbose",
                    // A prompt typed in Studio is not consent to edit the user's disk.
                    "--allowedTools", "mcp__rbx-studio", "--permission-mode", "dontAsk"
                ]);
                a
            },
            read: read_claude,
        },
        Harness {
            id: "codex",
            label: "Codex CLI",
            bin: "codex",
            mcp: Mcp::None,
            // Global flags must precede `resume`.
            argv: |p, sid| {
                let mut a = v!["exec", "--json", "--skip-git-repo-check"];
                if let Some(sid) = sid {
                    a.extend(v!["resume", sid]);
                }
                a.push(p.into());
                a
            },
            read: read_codex,
        },
        Harness {
            id: "opencode",
            label: "opencode",
            bin: "opencode",
            mcp: Mcp::None,
            argv: |p, sid| {
                let mut a = v!["run"];
                if let Some(sid) = sid {
                    a.extend(v!["--session", sid]);
                }
                a.extend(v!["--format", "json", p]);
                a
            },
            read: read_opencode,
        },
        Harness {
            id: "dsh",
            label: "DeepSeek Harness",
            bin: "dsh",
            mcp: Mcp::None,
            // `--patch` is a launcher option, so it must come before the prompt.
            argv: |p, _| v!["--profile", "headless", "--patch", dsh_overlay(), p],
            read: read_prose,
        },
        Harness { id: "gemini", label: "Gemini CLI", bin: "gemini", mcp: Mcp::None, argv: |p, _| v!["--output-format", "stream-json", "-p", p], read: read_gemini },
        Harness {
            id: "cursor",
            label: "Cursor Agent",
            bin: "cursor-agent",
            mcp: Mcp::None,
            argv: |p, sid| {
                let mut a = with_session(vec![], &["--resume"], sid, true);
                a.extend(v!["--output-format", "stream-json", "-p", p]);
                a
            },
            read: read_cursor,
        },
        Harness {
            id: "amp",
            label: "Amp",
            bin: "amp",
            mcp: Mcp::None,
            argv: |p, sid| match sid {
                None => v!["-x", "--stream-json", p],
                Some(sid) => v!["threads", "continue", sid, "-x", "--stream-json", p],
            },
            read: read_anthropic,
        },
        Harness { id: "qwen", label: "Qwen Code", bin: "qwen", mcp: Mcp::None, argv: |p, _| v!["--output-format", "stream-json", "-p", p], read: read_gemini },
        Harness {
            id: "droid",
            label: "Factory Droid",
            bin: "droid",
            mcp: Mcp::None,
            argv: |p, sid| {
                let mut a = v!["exec", "--output-format", "json", "--auto", "medium"];
                if let Some(sid) = sid {
                    a.extend(v!["--session-id", sid]);
                }
                a.push(p.into());
                a
            },
            read: read_droid,
        },
        Harness {
            id: "goose",
            label: "goose",
            bin: "goose",
            mcp: Mcp::None,
            argv: |p, sid| {
                let mut a = v!["run"];
                if let Some(sid) = sid {
                    a.extend(v!["--resume", "-n", sid]);
                }
                a.extend(v!["--output-format", "stream-json", "-t", p]);
                a
            },
            read: read_goose,
        },
        Harness {
            id: "copilot",
            label: "GitHub Copilot CLI",
            bin: "copilot",
            mcp: Mcp::None,
            argv: |p, _| v!["-p", p, "--no-ask-user", "--allow-tool", "rbx-studio", "--allow-tool", "roblox-studio"],
            read: read_prose,
        },
        Harness { id: "aider", label: "Aider", bin: "aider", mcp: Mcp::None, argv: |p, _| v!["--message", p, "--yes", "--no-pretty"], read: read_prose },
        Harness { id: "crush", label: "Crush", bin: "crush", mcp: Mcp::None, argv: |p, _| v!["run", p], read: read_prose },
        Harness {
            id: "kimi",
            label: "Kimi Code",
            bin: "kimi",
            mcp: Mcp::None,
            argv: |p, sid| {
                let mut a = with_session(vec![], &["--session"], sid, true);
                a.extend(v!["--output-format", "stream-json", "-p", p]);
                a
            },
            read: read_events,
        },
        Harness {
            id: "cline",
            label: "Cline",
            bin: "cline",
            mcp: Mcp::None,
            argv: |p, sid| {
                let mut a = with_session(vec![], &["--id"], sid, true);
                a.extend(v!["--json", p]);
                a
            },
            read: read_events,
        },
        Harness {
            id: "kilo",
            label: "Kilo Code",
            bin: "kilo",
            mcp: Mcp::None,
            argv: |p, sid| {
                let mut a = v!["run", "--auto"];
                if let Some(sid) = sid {
                    a.extend(v!["--session", sid]);
                }
                a.extend(v!["--format", "json", p]);
                a
            },
            read: read_events,
        },
        Harness { id: "auggie", label: "Auggie", bin: "auggie", mcp: Mcp::Config("--mcp-config"), argv: |p, _| v!["--print", "--mode", "json", p], read: read_events },
        Harness {
            id: "qoder",
            label: "Qoder CLI",
            bin: "qoder",
            mcp: Mcp::Config("--mcp-config"),
            argv: |p, sid| {
                let mut a = with_session(vec![], &["--session-id"], sid, true);
                a.extend(v!["-p", "-o", "stream-json", p]);
                a
            },
            read: read_events,
        },
        Harness { id: "continue", label: "Continue CLI", bin: "cn", mcp: Mcp::None, argv: |p, _| v!["-p", "--format", "json", p], read: read_events },
        Harness {
            id: "kiro",
            label: "Kiro CLI",
            bin: "kiro-cli",
            mcp: Mcp::None,
            argv: |p, sid| {
                let mut a = v!["chat", "--no-interactive", "--agent-engine", "v3", "--output-format", "stream-json"];
                if let Some(sid) = sid {
                    a.extend(v!["--resume-id", sid]);
                }
                a.push(p.into());
                a
            },
            read: read_events,
        },
        Harness {
            id: "vibe",
            label: "Mistral Vibe",
            bin: "vibe",
            mcp: Mcp::None,
            argv: |p, sid| {
                let mut a = with_session(vec![], &["--resume"], sid, true);
                a.extend(v!["--output", "streaming", "--prompt", p]);
                a
            },
            read: read_events,
        },
        Harness {
            id: "grok",
            label: "Grok CLI",
            bin: "grok",
            mcp: Mcp::None,
            argv: |p, sid| {
                let mut a = with_session(vec![], &["--session"], sid, true);
                a.extend(v!["--format", "json", "-p", p]);
                a
            },
            read: read_events,
        },
        Harness { id: "openhands", label: "OpenHands", bin: "openhands", mcp: Mcp::None, argv: |p, _| v!["--headless", "--json", "-t", p], read: read_events },
        Harness {
            id: "hermes",
            label: "Hermes Agent",
            bin: "hermes",
            mcp: Mcp::None,
            argv: |p, sid| {
                let mut a = v!["chat"];
                if let Some(sid) = sid {
                    a.extend(v!["--resume", sid]);
                }
                a.extend(v!["--format", "stream-json", "-q", p]);
                a
            },
            read: read_events,
        },
        Harness {
            id: "openclaw",
            label: "OpenClaw",
            bin: "openclaw",
            mcp: Mcp::None,
            argv: |p, sid| v!["agent", "--local", "--session-id", sid.unwrap_or("rbx-studio-panel"), "--json", "--message", p],
            read: read_events,
        },
        Harness { id: "oz", label: "Warp Oz", bin: "oz", mcp: Mcp::Config("--mcp"), argv: |p, _| v!["agent", "run", "--prompt", p], read: read_events },
        Harness {
            id: "rovodev",
            label: "Rovo Dev",
            bin: "acli",
            mcp: Mcp::None,
            argv: |p, sid| {
                let mut a = v!["rovodev", "run"];
                if let Some(sid) = sid {
                    a.extend(v!["--restore", sid]);
                }
                a.push(p.into());
                a
            },
            read: read_prose,
        },
        Harness {
            id: "forge",
            label: "Forge",
            bin: "forge",
            mcp: Mcp::None,
            argv: |p, sid| {
                let mut a = with_session(vec![], &["--conversation-id"], sid, true);
                a.extend(v!["-p", p]);
                a
            },
            read: read_prose,
        },
        Harness {
            id: "pi",
            label: "pi",
            bin: "pi",
            mcp: Mcp::None,
            argv: |p, sid| {
                let mut a = with_session(vec![], &["--session"], sid, true);
                a.extend(v!["-p", p]);
                a
            },
            read: read_prose,
        },
        Harness { id: "letta", label: "Letta Code", bin: "letta", mcp: Mcp::None, argv: |p, _| v!["-p", p], read: read_prose },
        Harness { id: "trae", label: "Trae Agent", bin: "trae-cli", mcp: Mcp::None, argv: |p, _| v!["run", p], read: read_prose },
    ]
});

#[allow(dead_code)]
fn generic_reader() -> Reader {
    read_generic
}

pub fn known() -> &'static [Harness] {
    &REGISTRY
}

/// Whether an MCP client's self-reported name is this harness.
pub fn matches_client(harness: &Harness, client_name: &str) -> bool {
    let flat = |v: &str| v.to_lowercase().chars().filter(char::is_ascii_alphanumeric).collect::<String>();
    let id = flat(harness.id);
    let name = flat(client_name);
    !id.is_empty() && !name.is_empty() && (name.starts_with(&id) || id.starts_with(&name))
}

/// Where a binary is on PATH, found by looking rather than by running.
fn where_is(bin: &str) -> Option<PathBuf> {
    let path = std::env::var_os("PATH")?;
    let exts: Vec<String> = if cfg!(windows) {
        std::env::var("PATHEXT")
            .ok()
            .filter(|s| !s.is_empty())
            .unwrap_or_else(|| ".EXE;.CMD;.BAT".into())
            .split(';')
            .filter(|e| !e.is_empty())
            .map(str::to_string)
            .collect()
    } else {
        vec![String::new()]
    };
    for dir in std::env::split_paths(&path) {
        if dir.as_os_str().is_empty() {
            continue;
        }
        for ext in &exts {
            if ext.is_empty() {
                let candidate = dir.join(bin);
                if candidate.is_file() {
                    return Some(candidate);
                }
            } else {
                for e in [ext.clone(), ext.to_lowercase()] {
                    let candidate = dir.join(format!("{bin}{e}"));
                    if candidate.is_file() {
                        return Some(candidate);
                    }
                }
            }
        }
    }
    None
}

/// Quotes one argument for a `cmd.exe /d /s /c "..."` command line.
pub fn cmd_quote(arg: &str) -> String {
    static QUOTE: LazyLock<Regex> = LazyLock::new(|| Regex::new(r#"(\\*)""#).unwrap());
    static TRAIL: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"(\\*)$").unwrap());
    static SPECIAL: LazyLock<Regex> = LazyLock::new(|| Regex::new(r#"[()\[\]%!^"`<>&|;, *?]"#).unwrap());
    let flat = arg.replace("\r\n", " ").replace('\n', " ");
    let inner = QUOTE.replace_all(&flat, r#"$1$1\""#);
    let inner = TRAIL.replace(&inner, "$1$1");
    let quoted = format!("\"{inner}\"");
    SPECIAL.replace_all(&quoted, "^$0").into_owned()
}

pub fn installed() -> Vec<&'static Harness> {
    REGISTRY.iter().filter(|h| where_is(h.bin).is_some()).collect()
}

pub fn find(id: &str) -> Option<&'static Harness> {
    REGISTRY.iter().find(|h| h.id == id || h.bin == id)
}

// --- scratch files -------------------------------------------------------------

struct Scratch(PathBuf);

impl Drop for Scratch {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

static SCRATCH: OnceLock<Scratch> = OnceLock::new();

fn scratch_dir() -> PathBuf {
    SCRATCH
        .get_or_init(|| {
            let dir = std::env::temp_dir().join(format!("rbx-studio-mcp-{}-{}", std::process::id(), uuid::Uuid::new_v4().simple()));
            let _ = std::fs::create_dir_all(&dir);
            Scratch(dir)
        })
        .0
        .clone()
}

/// Removes the scratch directory; called on shutdown (statics never drop).
pub fn cleanup() {
    if let Some(s) = SCRATCH.get() {
        let _ = std::fs::remove_dir_all(&s.0);
    }
}

fn self_exe() -> String {
    std::env::current_exe().map(|p| p.to_string_lossy().into_owned()).unwrap_or_else(|_| "rbx-studio-mcp".into())
}

/// An MCP config naming THIS binary, so the agent drives the same bridge version.
fn mcp_config() -> String {
    static PATH: OnceLock<String> = OnceLock::new();
    PATH.get_or_init(|| {
        let path = scratch_dir().join("mcp.json");
        let config = serde_json::json!({
            "mcpServers": { "rbx-studio": { "command": self_exe(), "args": [], "env": { "RBX_STUDIO_MCP_SPAWNED": "1" } } }
        });
        let _ = std::fs::write(&path, serde_json::to_vec(&config).unwrap_or_default());
        path.to_string_lossy().into_owned()
    })
    .clone()
}

/// The same server as the Cordis overlay row dsh reads.
fn dsh_overlay() -> String {
    static PATH: OnceLock<String> = OnceLock::new();
    PATH.get_or_init(|| {
        let path = scratch_dir().join("rbx-studio.cordis.yml");
        let exe = serde_json::to_string(&self_exe()).unwrap_or_default();
        let body = [
            "- insert:".to_string(),
            "    - id: mcp-rbx-studio".into(),
            "      name: '@deepseek-ai/dsh-mcp-client'".into(),
            "      config:".into(),
            "        serverName: rbx-studio".into(),
            "        transport: stdio".into(),
            format!("        command: {exe}"),
            "        args: []".into(),
            "        toolCallTimeoutMs: 60000".into(),
            "        failOnStartupError: false".into(),
            "        env:".into(),
            "          RBX_STUDIO_MCP_SPAWNED: '1'".into(),
            String::new(),
        ]
        .join("\n");
        let _ = std::fs::write(&path, body);
        path.to_string_lossy().into_owned()
    })
    .clone()
}

// --- running ---------------------------------------------------------------------

pub struct Run {
    cancel: watch::Sender<bool>,
    pub done: oneshot::Receiver<Option<String>>,
}

impl Run {
    pub fn cancel(&self) {
        let _ = self.cancel.send(true);
    }
}

/// Ends a run and everything it started: the tree, not just the launcher.
async fn kill_tree(child: &mut tokio::process::Child) {
    let Some(pid) = child.id() else { return };
    #[cfg(windows)]
    {
        let killed = tokio::process::Command::new("taskkill")
            .args(["/pid", &pid.to_string(), "/T", "/F"])
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status()
            .await;
        if killed.is_ok() {
            return;
        }
    }
    #[cfg(unix)]
    {
        // SAFETY: signalling the process group created at spawn.
        if unsafe { libc::kill(-(pid as i32), libc::SIGTERM) } == 0 {
            return;
        }
    }
    let _ = pid;
    let _ = child.start_kill();
}

/// Starts `harness` on `prompt`, reporting every row through `emit`.
pub fn run(harness: &'static Harness, prompt: &str, cwd: PathBuf, session: Option<String>, emit: Arc<dyn Fn(Line) + Send + Sync>) -> Run {
    let (cancel_tx, mut cancel_rx) = watch::channel(false);
    let (done_tx, done_rx) = oneshot::channel();

    let mut argv = (harness.argv)(prompt, session.as_deref());
    if let Mcp::Config(flag) = harness.mcp {
        argv.push(flag.into());
        argv.push(mcp_config());
    }

    let Some(executable) = where_is(harness.bin) else {
        emit(Line::new("error", format!("{} is not on PATH", harness.bin)));
        let _ = done_tx.send(None);
        return Run { cancel: cancel_tx, done: done_rx };
    };

    let via_cmd = cfg!(windows)
        && executable.extension().is_some_and(|e| e.eq_ignore_ascii_case("cmd") || e.eq_ignore_ascii_case("bat"));
    let mut command = if via_cmd {
        let comspec = std::env::var("ComSpec").unwrap_or_else(|_| "cmd.exe".into());
        let mut line = vec![cmd_quote(&executable.to_string_lossy())];
        line.extend(argv.iter().map(|a| cmd_quote(a)));
        let mut c = tokio::process::Command::new(comspec);
        #[cfg(windows)]
        {
            c.raw_arg("/d /s /c").raw_arg(format!("\"{}\"", line.join(" ")));
        }
        c
    } else {
        let mut c = tokio::process::Command::new(&executable);
        c.args(&argv);
        c
    };
    command
        .current_dir(cwd)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .env("RBX_STUDIO_MCP_SPAWNED", "1")
        .kill_on_drop(true);
    #[cfg(unix)]
    command.process_group(0);
    #[cfg(windows)]
    command.creation_flags(0x0800_0000); // CREATE_NO_WINDOW

    let mut child = match command.spawn() {
        Ok(child) => child,
        Err(e) => {
            emit(Line::with("error", format!("could not start {}", harness.bin), e.to_string()));
            let _ = done_tx.send(session);
            return Run { cancel: cancel_tx, done: done_rx };
        }
    };

    let stdout = child.stdout.take();
    let stderr = child.stderr.take();
    tokio::spawn(async move {
        let mut session = session;
        let complaint = Arc::new(parking_lot::Mutex::new(String::new()));
        let complaint_writer = complaint.clone();
        let err_task = tokio::spawn(async move {
            if let Some(mut stderr) = stderr {
                let mut buf = [0u8; 4096];
                while let Ok(n) = stderr.read(&mut buf).await {
                    if n == 0 {
                        break;
                    }
                    let mut c = complaint_writer.lock();
                    c.push_str(&String::from_utf8_lossy(&buf[..n]));
                    let len = c.chars().count();
                    if len > 400 {
                        *c = c.chars().skip(len - 400).collect();
                    }
                }
            }
        });

        let mut stopped = false;
        if let Some(stdout) = stdout {
            let mut lines = BufReader::new(stdout).lines();
            loop {
                tokio::select! {
                    line = lines.next_line() => match line {
                        Ok(Some(line)) => {
                            let r = std::panic::catch_unwind(|| (harness.read)(&line));
                            match r {
                                Ok(reading) => {
                                    if let Some(s) = reading.session.filter(|s| !s.is_empty()) {
                                        session = Some(s);
                                    }
                                    for row in reading.lines {
                                        emit(row);
                                    }
                                }
                                Err(_) if !line.trim().is_empty() => emit(Line::new("dim", line.chars().take(400).collect::<String>())),
                                Err(_) => {}
                            }
                        }
                        _ => break,
                    },
                    _ = cancel_rx.changed() => {
                        stopped = true;
                        kill_tree(&mut child).await;
                        break;
                    }
                }
            }
        }
        let status = child.wait().await;
        let _ = err_task.await;
        if stopped {
            emit(Line::new("warn", "agent stopped"));
        } else if let Ok(status) = status
            && let Some(code) = status.code().filter(|c| *c != 0) {
                let c = complaint.lock().trim().to_string();
                let tail: Vec<&str> = c.split('\n').collect();
                let tail = tail[tail.len().saturating_sub(2)..].join(" ");
                emit(Line::opt("error", format!("{} exited {code}", harness.label), (!tail.is_empty()).then_some(tail)));
            }
        let _ = done_tx.send(session);
    });

    Run { cancel: cancel_tx, done: done_rx }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cmd_quote_escapes() {
        assert_eq!(cmd_quote("a & b"), "^\"a^ ^&^ b^\"");
    }

    #[test]
    fn shortens_tool_names() {
        assert_eq!(shorten("mcp__rbx-studio__tree"), "tree");
        assert_eq!(shorten("rbx-studio_tree"), "tree");
        assert!(is_own_tool("rbx-studio_tree"));
        assert!(!is_own_tool("mcp__other__tree"));
    }

    #[test]
    fn matches_clients() {
        let claude = find("claude").unwrap();
        assert!(matches_client(claude, "claude-code"));
        assert!(!matches_client(claude, "codex"));
    }
}
