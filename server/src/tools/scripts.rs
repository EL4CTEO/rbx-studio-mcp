//! script_read, script_edit, script_grep, script_create.

use super::{arr_of, call, d, str_of, u64_of};
use crate::cloud::{self, Target, live};
use crate::errors::{Result, ToolError};
use crate::format::{CHARACTER_LIMIT, PageMeta, ToolResult, body, clip_chars, decode_cursor, encode_cursor, error_text, json, table, text};
use crate::tool::{Ctx, Tool, define, spec};
use schemars::JsonSchema;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::collections::{BTreeMap, BTreeSet, HashMap, HashSet};
use std::sync::Arc;

#[derive(Deserialize, JsonSchema, Default, PartialEq, Clone, Copy)]
#[serde(rename_all = "lowercase")]
enum ReadOp {
    #[default]
    Read,
    Open,
}

#[derive(Deserialize, JsonSchema, Default, PartialEq, Clone, Copy)]
#[serde(rename_all = "lowercase")]
enum Where {
    #[default]
    Studio,
    Live,
}

#[derive(Deserialize, Serialize, JsonSchema, Clone)]
#[serde(untagged)]
enum ReadPath {
    /// A script path, read in full.
    Whole(String),
    Window {
        /// The script to read.
        path: String,
        /// First line of the window for this script, 1-based and inclusive.
        #[serde(rename = "startLine", skip_serializing_if = "Option::is_none")]
        #[schemars(range(min = 1))]
        start_line: Option<u32>,
        /// Last line of the window for this script, inclusive.
        #[serde(rename = "endLine", skip_serializing_if = "Option::is_none")]
        #[schemars(range(min = 1))]
        end_line: Option<u32>,
    },
}

impl ReadPath {
    fn path(&self) -> &str {
        match self {
            ReadPath::Whole(p) => p,
            ReadPath::Window { path, .. } => path,
        }
    }
}

#[derive(Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
struct ReadArgs {
    /// 'read' returns source. 'open' opens the first path in the user's Studio editor at `line` and returns nothing to read.
    #[serde(default)]
    op: ReadOp,
    /// open only: line to put the cursor on.
    #[schemars(range(min = 1))]
    line: Option<u32>,
    /// 'studio' reads the open place. 'live' reads the published place over Open Cloud, Folders and scripts only.
    #[serde(default)]
    target: Where,
    /// live only: list what is under the first path instead of reading it. Pass `paths: [""]` to see the top level.
    list: Option<bool>,
    /// live only: omit to use `cloud universe`.
    universe_id: Option<String>,
    /// live only: omit to use `cloud place`.
    place_id: Option<String>,
    /// Scripts to read, e.g. ["ServerScriptService.Systems.Combat"] or [{ path: "...Combat", startLine: 120, endLine: 180 }].
    #[schemars(length(min = 1, max = 20))]
    paths: Vec<ReadPath>,
    /// Default first line for entries without their own, 1-based and inclusive. Omit to start at the top.
    #[schemars(range(min = 1))]
    start_line: Option<u32>,
    /// Default last line for entries without their own, inclusive. Omit to read to the end.
    #[schemars(range(min = 1))]
    end_line: Option<u32>,
    /// Target Studio; omit for the active one.
    studio_id: Option<String>,
}

#[derive(Deserialize, Serialize, JsonSchema, Clone)]
#[serde(rename_all = "camelCase")]
struct EditSpec {
    /// Script to edit, e.g. "ServerScriptService.Systems.Combat".
    path: String,
    /// Exact text to replace, whitespace included. Literal, not a regex or Lua pattern.
    #[serde(skip_serializing_if = "Option::is_none")]
    find: Option<String>,
    /// Text to put in its place. Required with `find`; empty string deletes.
    #[serde(skip_serializing_if = "Option::is_none")]
    replace: Option<String>,
    /// Replace every occurrence. Without this a non-unique `find` is refused rather than guessing which one you meant.
    #[serde(skip_serializing_if = "Option::is_none")]
    replace_all: Option<bool>,
    /// First line to replace, 1-based and inclusive.
    #[serde(skip_serializing_if = "Option::is_none")]
    #[schemars(range(min = 1))]
    start_line: Option<u32>,
    /// Last line to replace, inclusive. Defaults to `startLine`. Set it one below `startLine` to insert without replacing anything.
    #[serde(skip_serializing_if = "Option::is_none")]
    end_line: Option<u32>,
    /// New text for that line range. Required with `startLine`.
    #[serde(skip_serializing_if = "Option::is_none")]
    replacement: Option<String>,
    /// Complete new source for the script, replacing everything.
    #[serde(skip_serializing_if = "Option::is_none")]
    source: Option<String>,
    /// The `rev` value script_read printed for this file. Pass it and the edit is refused if the script changed since you read it, instead of being applied to source you have not seen. Required for line-range and `source` edits.
    #[serde(skip_serializing_if = "Option::is_none")]
    revision: Option<String>,
}

#[derive(Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
struct EditArgs {
    /// 'studio' edits the open place. 'live' rewrites a script in the published place over Open Cloud — one file, whole source, no undo.
    #[serde(default)]
    target: Where,
    /// live only: the script, e.g. "ServerScriptService.Main".
    path: Option<String>,
    /// live only: the complete new source.
    source: Option<String>,
    /// live only, required: the `rev` `script_read target="live"` printed. The write is refused if the published script changed since.
    revision: Option<String>,
    /// live only: omit to use `cloud universe`.
    universe_id: Option<String>,
    /// live only: omit to use `cloud place`.
    place_id: Option<String>,
    /// Required for target="live".
    confirm: Option<bool>,
    /// Edits to apply together as one undoable step. Required unless target is "live". The result carries each script's new `rev`, so a follow-up edit needs no re-read.
    #[schemars(length(max = 50))]
    edits: Option<Vec<EditSpec>>,
    /// Target Studio; omit for the active one.
    studio_id: Option<String>,
}

#[derive(Deserialize, JsonSchema, Default, PartialEq, Clone, Copy, Serialize)]
#[serde(rename_all = "lowercase")]
enum GrepMode {
    #[default]
    Lines,
    Files,
    Counts,
}

fn ctx0() -> u32 {
    0
}

#[derive(Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
struct GrepArgs {
    /// Lua pattern, or exact text when `literal` is set, e.g. "PlayerAdded".
    #[schemars(length(min = 1))]
    pattern: Option<String>,
    /// Several literal strings searched in one pass, instead of `pattern`.
    #[schemars(length(min = 1, max = 16))]
    patterns: Option<Vec<String>>,
    /// 'lines': matching lines. 'files': one row per matching script. 'counts': matching-line counts per pattern.
    #[serde(default)]
    mode: GrepMode,
    /// Limit to this subtree, e.g. "ServerScriptService". Omit to search everywhere.
    path: Option<String>,
    /// Treat `pattern` as plain text rather than a Lua pattern.
    #[serde(default)]
    literal: bool,
    /// Case-insensitive. Both sides are lowercased, so pattern classes like %u stop being meaningful — combine with `literal`.
    #[serde(default)]
    ignore_case: bool,
    /// Lines of context to show either side of each match.
    #[serde(default = "ctx0")]
    #[schemars(range(min = 0, max = 10))]
    context_lines: u32,
    /// Restrict to one script class: "Script", "LocalScript" or "ModuleScript".
    class_name: Option<String>,
    #[serde(default = "d::page")]
    #[schemars(schema_with = "super::page_limit_schema")]
    limit: u32,
    /// Opaque cursor from a previous call's `nextCursor`. Omit for the first page.
    cursor: Option<String>,
    /// Target Studio; omit for the active one.
    studio_id: Option<String>,
}

#[derive(Deserialize, Serialize, JsonSchema)]
enum ScriptClass {
    Script,
    LocalScript,
    ModuleScript,
}

#[derive(Deserialize, Serialize, JsonSchema)]
enum RunContext {
    Legacy,
    Server,
    Client,
}

#[derive(Deserialize, Serialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
struct NewScript {
    /// Path of the parent instance, e.g. "ServerScriptService.Systems".
    parent: String,
    /// Name for the new script.
    name: String,
    /// Which kind of script to create.
    class_name: ScriptClass,
    /// Initial Luau source. Omit for Roblox's default stub.
    #[serde(skip_serializing_if = "Option::is_none")]
    source: Option<String>,
    /// Where a `Script` runs. 'Legacy' means server-only and only under a server container. Ignored for the other classes.
    #[serde(skip_serializing_if = "Option::is_none")]
    run_context: Option<RunContext>,
    /// Create it disabled, so it does not run on the next playtest.
    #[serde(skip_serializing_if = "Option::is_none")]
    disabled: Option<bool>,
}

#[derive(Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
struct CreateArgs {
    /// Scripts to create together as one undoable step.
    #[schemars(length(min = 1, max = 50))]
    scripts: Vec<NewScript>,
    /// Target Studio; omit for the active one.
    studio_id: Option<String>,
}

/// Line-range and whole-source edits must say which version they were written against.
fn require_blind_revisions(edits: &[EditSpec]) -> Result<()> {
    let pinned: HashSet<&str> = edits.iter().filter(|e| e.revision.is_some()).map(|e| e.path.as_str()).collect();
    let mut blind: Vec<&str> = Vec::new();
    for e in edits {
        if e.find.is_none() && (e.start_line.is_some() || e.source.is_some()) && !pinned.contains(e.path.as_str()) && !blind.contains(&e.path.as_str()) {
            blind.push(&e.path);
        }
    }
    if blind.is_empty() {
        return Ok(());
    }
    Err(ToolError::hint(
        "NEEDS_REVISION",
        format!("Line-range and whole-source edits need the script's `rev`: {}.", blind.join(", ")),
        "Pass the `rev` that `script_read` (or the previous `script_edit`) printed as `revision`, or use find/replace, which needs none.",
    ))
}

/// Each line prefixed with its number, which `script_edit` accepts back.
pub fn numbered(source: &str, start: u64) -> String {
    if source.is_empty() {
        return String::new();
    }
    let lines: Vec<&str> = source.split('\n').collect();
    let width = (start + lines.len() as u64 - 1).to_string().len();
    let mut out = String::with_capacity(source.len() + lines.len() * (width + 3));
    for (i, line) in lines.iter().enumerate() {
        if i > 0 {
            out.push('\n');
        }
        out.push_str(&format!("{:>width$}│ {line}", start + i as u64));
    }
    out
}

/// Joins listings, cutting a too-long one on a whole line and naming where to resume.
fn clip_listing(blocks: &[String], items: &[Value], failures: Option<&str>) -> String {
    let head = failures.map(|f| format!("{f}\n\n")).unwrap_or_default();
    let whole = format!("{head}{}", blocks.join("\n\n"));
    if whole.len() <= CHARACTER_LIMIT {
        return whole;
    }
    let budget = CHARACTER_LIMIT - 400;
    let mut shown = head;
    for (index, block) in blocks.iter().enumerate() {
        let sep = if index == 0 { "" } else { "\n\n" };
        if shown.len() + sep.len() + block.len() <= budget {
            shown.push_str(sep);
            shown.push_str(block);
            continue;
        }
        let room = budget.saturating_sub(shown.len() + sep.len());
        let kept = clip_chars(block, room);
        let kept = kept.rfind('\n').map(|cut| &block[..cut]).unwrap_or("");
        let item = items.get(index);
        let last_line = kept.rsplit('\n').next().and_then(|line| {
            let digits: String = line.trim_start().chars().take_while(char::is_ascii_digit).collect();
            (line.contains('│') && !digits.is_empty()).then_some(digits)
        });
        let untouched = blocks.len() - index - 1;
        let rest = if untouched > 0 { format!(" {untouched} more script(s) after it were not shown.") } else { String::new() };
        if !kept.is_empty() {
            shown.push_str(sep);
            shown.push_str(kept);
        }
        let path = item.and_then(|i| str_of(i, "path")).unwrap_or("The next script");
        let next = match (item, last_line) {
            (Some(item), Some(last)) => {
                let n: u64 = last.parse().unwrap_or(0);
                format!(
                    "{path} stops at line {last} of {}. Continue with {{ path: \"{path}\", startLine: {}{} }}.",
                    u64_of(item, "lineCount"),
                    n + 1,
                    item.get("endLine").and_then(Value::as_u64).map(|e| format!(", endLine: {e}")).unwrap_or_default()
                )
            }
            _ => format!("{path} was not shown."),
        };
        return format!("{shown}\n\n[clipped at {CHARACTER_LIMIT} characters: {next}{rest}]");
    }
    shown
}

/// Matches grouped per script, each line once, `:` for a match and `-` for context.
fn render_matches(matches: &[Value], tag_needles: bool) -> String {
    struct Group {
        header: String,
        lines: BTreeMap<i64, String>,
        hits: BTreeSet<i64>,
    }
    let mut order: Vec<String> = Vec::new();
    let mut groups: HashMap<String, Group> = HashMap::new();
    for m in matches {
        let path = str_of(m, "path").unwrap_or("").to_string();
        let group = groups.entry(path.clone()).or_insert_with(|| {
            order.push(path.clone());
            Group {
                header: match str_of(m, "revision") {
                    Some(rev) if !rev.is_empty() => format!("{path}  rev={rev}"),
                    _ => path.clone(),
                },
                lines: BTreeMap::new(),
                hits: BTreeSet::new(),
            }
        });
        let line = m.get("line").and_then(Value::as_i64).unwrap_or(0);
        let before = arr_of(m, "before");
        let first = line - before.len() as i64;
        for (i, l) in before.iter().enumerate() {
            let n = first + i as i64;
            if !group.hits.contains(&n) {
                group.lines.insert(n, l.as_str().unwrap_or("").to_string());
            }
        }
        group.hits.insert(line);
        let mut rendered = str_of(m, "text").unwrap_or("").to_string();
        if m.get("truncated") == Some(&Value::Bool(true)) {
            rendered.push_str("  [line cut; read it with script_read]");
        }
        if tag_needles
            && let Some(needles) = m.get("needles").and_then(Value::as_array) {
                let ids: Vec<String> = needles.iter().map(|n| n.to_string()).collect();
                rendered.push_str(&format!("  [patterns {}]", ids.join(",")));
            }
        group.lines.insert(line, rendered);
        for (i, l) in arr_of(m, "after").iter().enumerate() {
            let n = line + i as i64 + 1;
            if !group.hits.contains(&n) {
                group.lines.insert(n, l.as_str().unwrap_or("").to_string());
            }
        }
    }
    order
        .iter()
        .map(|path| {
            let g = &groups[path];
            let mut out = vec![g.header.clone()];
            out.extend(g.lines.iter().map(|(n, l)| format!("{n}{} {l}", if g.hits.contains(n) { ":" } else { "-" })));
            out.join("\n")
        })
        .collect::<Vec<_>>()
        .join("\n\n")
}

struct LiveTarget {
    credentials: cloud::credentials::Credentials,
    universe: String,
    place: String,
}

async fn live_target(ctx: &Arc<Ctx>, universe: Option<&str>, place: Option<&str>, studio: Option<&str>) -> Result<LiveTarget> {
    let credentials = cloud::require_credentials().await?;
    let u = cloud::require_universe(universe).await?;
    let p = cloud::require_place(place).await?;
    cloud::assert_targets_open_place(
        &ctx.bridge,
        Target { universe_id: Some(&u), place_id: Some(&p), explicit: universe.is_some() || place.is_some(), studio_id: studio },
    )
    .await?;
    Ok(LiveTarget { credentials, universe: u, place: p })
}

async fn script_read(ctx: Arc<Ctx>, a: ReadArgs) -> Result<ToolResult> {
    let studio = a.studio_id.as_deref();
    if a.target == Where::Live {
        let t = live_target(&ctx, a.universe_id.as_deref(), a.place_id.as_deref(), studio).await?;
        let at = live::Place { universe: &t.universe, place: &t.place };
        let wanted = a.paths.first().map(ReadPath::path).unwrap_or("");
        if a.list == Some(true) {
            let id = if wanted.is_empty() { "root".to_string() } else { live::resolve_path(&t.credentials, &at, wanted).await?.id };
            let kids = live::children(&t.credentials, &at, &id, 100, None).await?;
            if kids.items.is_empty() {
                return Ok(text(format!(
                    "Nothing under {} that the Instance API can see. It only reports Folders and scripts.",
                    if wanted.is_empty() { "the root" } else { wanted }
                )));
            }
            let listed = table(&["name", "className", "hasChildren"], &kids.items, PageMeta::default());
            return Ok(match kids.next_page_token {
                None => listed,
                Some(_) => text(format!(
                    "{}\n\nOnly the first {} are shown; there are more. Name a deeper path to reach the rest, or read one by its full path.",
                    listed.text_of(),
                    kids.items.len()
                )),
            });
        }
        if wanted.is_empty() {
            return Ok(error_text("live read needs a path in `paths`."));
        }
        let resolved = live::resolve_path(&t.credentials, &at, wanted).await?;
        let read = live::instance(&t.credentials, &at, &resolved.id).await?;
        let class = str_of(&read, "className").unwrap_or("Instance");
        return Ok(match str_of(&read, "source") {
            Some(source) => body(source, &format!("{wanted} ({class}, published place, rev {})", live::revision(source))),
            None => text(format!("{wanted} is a {class}, which holds no source. Use `list: true` to see what is inside it.")),
        });
    }

    if a.op == ReadOp::Open {
        let Some(first) = a.paths.first() else { return Ok(error_text("open needs a path.")) };
        let opened = call(&ctx, "script.open", json!({ "path": first.path(), "line": a.line }), studio, None).await?;
        return Ok(text(format!(
            "Opened {} in Studio{}{}",
            str_of(&opened, "path").unwrap_or(first.path()),
            opened.get("line").and_then(Value::as_u64).map(|l| format!(" at line {l}.")).unwrap_or_else(|| ".".into()),
            if a.paths.len() > 1 { format!(" ({} other path(s) ignored — open takes one.)", a.paths.len() - 1) } else { String::new() }
        )));
    }

    let response = call(
        &ctx,
        "script.read",
        json!({ "paths": a.paths, "startLine": a.start_line, "endLine": a.end_line }),
        studio,
        None,
    )
    .await?;
    let items = arr_of(&response, "items");
    let blocks: Vec<String> = items
        .iter()
        .map(|item| {
            let path = str_of(item, "path").unwrap_or("");
            let class = str_of(item, "className").unwrap_or("");
            let source = str_of(item, "source").unwrap_or("");
            let line_count = u64_of(item, "lineCount");
            let start = u64_of(item, "startLine").max(1);
            let end = item.get("endLine").and_then(Value::as_u64);
            let shown = if source.is_empty() { 0 } else { source.split('\n').count() as u64 };
            if shown == 0 {
                if line_count == 0 {
                    return format!("{path}  ({class}) is empty.");
                }
                let header = format!("{path}  ({class}, {line_count} lines)");
                if let Some(end) = end.filter(|e| *e < start) {
                    return format!(
                        "{header}\nNothing to read: endLine {end} is before startLine {start}. Ranges run forwards and include both ends."
                    );
                }
                let asked = match end {
                    Some(end) => format!("Lines {start}-{end}"),
                    None => format!("Line {start} onwards"),
                };
                return format!("{header}\n{asked} is empty — the file ends at line {line_count}.");
            }
            let range = if shown == line_count {
                format!("{line_count} lines")
            } else {
                format!("lines {start}-{} of {line_count}", start + shown - 1)
            };
            let stamp = str_of(item, "revision").map(|r| format!(", rev {r}")).unwrap_or_default();
            let synced = str_of(item, "fileSync")
                .map(|f| {
                    format!(
                        "\n! This script is synced from a file on disk ({f}). Editing it here is a race with whatever writes that file, and the loser leaves no error.\n"
                    )
                })
                .unwrap_or_default();
            format!("{path}  ({class}, {range}{stamp}){synced}\n{}", numbered(source, start))
        })
        .collect();
    let failures = arr_of(&response, "failures");
    let failures = (!failures.is_empty()).then(|| {
        let list: Vec<String> = failures.iter().map(|f| format!("  - {}", f.as_str().unwrap_or(&f.to_string()))).collect();
        format!("Could not read {} path(s):\n{}", failures.len(), list.join("\n"))
    });
    if blocks.is_empty() {
        return Ok(text(failures.unwrap_or_else(|| "No scripts read.".into())));
    }
    Ok(text(clip_listing(&blocks, items, failures.as_deref())))
}

async fn script_edit(ctx: Arc<Ctx>, a: EditArgs) -> Result<ToolResult> {
    let studio = a.studio_id.as_deref();
    if a.target == Where::Live {
        let (Some(path), Some(source)) = (a.path.as_deref().filter(|p| !p.is_empty()), a.source.as_deref()) else {
            return Err(ToolError::bad_params("live edit needs `path` and `source`."));
        };
        if a.confirm != Some(true) {
            return Err(ToolError::hint(
                "NEEDS_CONFIRM",
                "This rewrites a script in the published place.",
                "There is no undo. Read it with `script_read target=\"live\"` first and send back the whole file with its `rev` as `revision`, then pass confirm: true.",
            ));
        }
        let Some(revision) = a.revision.as_deref() else {
            return Err(ToolError::hint(
                "NEEDS_REVISION",
                "A live edit replaces the whole published script, so it needs the `rev` it was written against.",
                "Read it with `script_read target=\"live\"` and pass the printed `rev` as `revision`.",
            ));
        };
        let t = live_target(&ctx, a.universe_id.as_deref(), a.place_id.as_deref(), studio).await?;
        let at = live::Place { universe: &t.universe, place: &t.place };
        let resolved = live::resolve_path(&t.credentials, &at, path).await?;
        if !matches!(resolved.class_name.as_str(), "Script" | "LocalScript" | "ModuleScript") {
            return Err(ToolError::new("WRONG_KIND", format!("{path} is a {}, which has no source to write.", resolved.class_name)));
        }
        let written = live::script_write(&t.credentials, &at, &resolved.id, &resolved.class_name, source, Some(revision)).await?;
        return Ok(json(&written, None));
    }
    let edits = a.edits.unwrap_or_default();
    if edits.is_empty() {
        return Err(ToolError::bad_params("script_edit needs at least one entry in `edits`."));
    }
    require_blind_revisions(&edits)?;
    let response = call(&ctx, "script.edit", json!({ "edits": edits }), studio, Some(30_000.0)).await?;
    Ok(table(&["path", "className", "edits", "lineCount", "lineDelta", "rev"], arr_of(&response, "items"), PageMeta::default()))
}

async fn script_grep(ctx: Arc<Ctx>, a: GrepArgs) -> Result<ToolResult> {
    if a.pattern.is_some() == a.patterns.is_some() {
        return Err(ToolError::bad_params("Pass either `pattern` or `patterns`, not both and not neither."));
    }
    let needles: Vec<String> = a.patterns.clone().unwrap_or_else(|| vec![a.pattern.clone().unwrap_or_default()]);
    let offset = decode_cursor(a.cursor.as_deref())?;
    let response = call(
        &ctx,
        "script.grep",
        json!({
            "pattern": a.pattern, "patterns": a.patterns, "mode": a.mode, "path": a.path, "literal": a.literal,
            "ignoreCase": a.ignore_case, "contextLines": a.context_lines, "className": a.class_name,
            "limit": a.limit, "offset": offset,
        }),
        a.studio_id.as_deref(),
        Some(30_000.0),
    )
    .await?;
    let searched = u64_of(&response, "searched");
    let total = u64_of(&response, "total");

    if a.mode == GrepMode::Counts {
        let counts = arr_of(&response, "counts");
        let rows: Vec<Value> = needles
            .iter()
            .enumerate()
            .map(|(i, p)| json!({ "pattern": p, "lines": counts.get(i).and_then(Value::as_u64).unwrap_or(0) }))
            .collect();
        return Ok(json(&json!({ "searched": searched, "matchedFiles": u64_of(&response, "matchedFiles"), "counts": rows }), None));
    }
    if total == 0 {
        if searched == 0 {
            return Ok(text(match &a.path {
                Some(p) => format!("No scripts under \"{p}\" to search."),
                None => "This place contains no scripts.".into(),
            }));
        }
        let literal = a.literal || a.patterns.is_some();
        let alternation = !literal && a.pattern.as_deref().unwrap_or("").contains('|');
        return Ok(text(format!(
            "No matches in {searched} script(s).\n{}",
            if alternation {
                "This pattern contains `|`, which Lua patterns do not support — there is no alternation, so `|` matched as a literal character. Pass the alternatives as `patterns` instead."
            } else if literal {
                "The match is literal and case-sensitive unless you set `ignoreCase`."
            } else {
                "Check case, and remember patterns are Lua patterns — set `literal` to search for the text exactly as written."
            }
        )));
    }
    let items = arr_of(&response, "items");
    if a.mode == GrepMode::Files {
        return Ok(table(
            &["path", "className", "revision", "matches"],
            items,
            PageMeta { offset: Some(offset), total: Some(total), more: Some(format!("searched {searched} scripts")), ..Default::default() },
        ));
    }
    // Clipped by whole matches, so the cursor resumes at the first one not shown.
    let tag = needles.len() > 1;
    let mut shown = items.len();
    let mut listing = render_matches(items, tag);
    let budget = CHARACTER_LIMIT - 500;
    if listing.len() > budget {
        let (mut low, mut high) = (1usize, shown);
        while low < high {
            let middle = (low + high).div_ceil(2);
            if render_matches(&items[..middle], tag).len() <= budget {
                low = middle;
            } else {
                high = middle - 1;
            }
        }
        shown = low;
        listing = render_matches(&items[..shown], tag);
        if listing.len() > budget {
            listing = format!("{} [cut; read the script with script_read]", clip_chars(&listing, budget - 60));
        }
    }
    let next = offset + shown as u64;
    let trailer = if next < total {
        format!("[showing {shown} of {total} matches, searched {searched} scripts — call again with cursor: \"{}\"]", encode_cursor(next))
    } else {
        format!("[{total} match{}, searched {searched} scripts]", if total == 1 { "" } else { "es" })
    };
    Ok(text(format!("{listing}\n\n{trailer}")))
}

async fn script_create(ctx: Arc<Ctx>, a: CreateArgs) -> Result<ToolResult> {
    let response = call(&ctx, "script.create", json!({ "scripts": a.scripts }), a.studio_id.as_deref(), Some(60_000.0)).await?;
    let more = match str_of(&response, "undoStep") {
        Some(step) => format!("undoable as one step, \"{step}\" — Ctrl+Z with focus outside the script editor"),
        None => "Studio would not open an undo recording, so this is not undoable as a single step".into(),
    };
    let listing = table(&["path", "className", "rev"], arr_of(&response, "items"), PageMeta { more: Some(more), ..Default::default() });
    let warnings: Vec<&str> = arr_of(&response, "warnings").iter().filter_map(Value::as_str).collect();
    if warnings.is_empty() {
        return Ok(listing);
    }
    Ok(text(format!("{}\n\nWARNING: {}", listing.text_of(), warnings.join("\n\n"))))
}

pub fn tools() -> Vec<Tool> {
    vec![
        define(
            // `open` moves the user's editor but changes nothing in the place.
            spec("script_read", "Read scripts").destructive(false),
            "Reads Luau source from one or more scripts, with line numbers that `script_edit` accepts back verbatim.\n\n\
             Source comes from the Studio script editor's live buffer, so anything the user has typed but not yet \
             saved is included. Reading the saved property instead would hand you stale code and you would 'fix' the \
             change they just made.\n\n\
             Pass every script you need in one call, including when you want a different part of each: an entry may \
             be a bare path for the whole file, or `{path, startLine, endLine}` for a window into that one script. The \
             top-level `startLine`/`endLine` are the default for entries that do not carry their own.\n\n\
             A script bound to a file on disk is flagged in the result. Editing one of those is a race: whatever writes \
             the file wins, and your change disappears the next time it does, with nothing anywhere reporting a failure.\n\n\
             `open` puts a script on the user's screen at a line, instead of telling them where to look. Ask for it \
             when you are pointing at something they should see; it is not automatic, and reading twenty scripts does \
             not rearrange their editor.\n\n\
             `target=\"live\"` reads the code of the PUBLISHED place instead, with no Studio involved — which is how you \
             check what is actually deployed rather than what is on someone's machine. Two limits are real and worth \
             knowing before you reach for it: Roblox's Instance API can only see Folders and scripts, so a path through \
             a Model or a Part cannot be walked at all; and it addresses things by GUID with no search, so each segment \
             of the path costs a round trip. Expect seconds. `list: true` shows what is under a path instead of reading \
             it, which is how you find your way down.",
            script_read,
        ),
        define(
            spec("script_edit", "Edit scripts").destructive(true),
            "Edits Luau source through the Studio script editor. This is the tool to use for any change to existing code.\n\n\
             Every edit in one call is all-or-nothing: the whole batch is resolved against current source before \
             anything is written, so if one edit cannot be applied nothing is. Batch related changes together, even \
             across different scripts.\n\n\
             Each edit picks exactly one mode:\n  find/replace — literal text, not a pattern. Preferred: it survives line \
             numbers shifting. Fails if the text is not unique, unless you set `replaceAll`, so include enough \
             surrounding lines to pin it down.\n  startLine/endLine + replacement — for line ranges from `script_read`. \
             Numbers refer to the file as you read it; several line edits to one script are applied bottom-up so they \
             do not shift each other.\n  source — replaces the whole script. Only for small files or a rewrite; it \
             discards anything the user changed since you read it.\n\n\
             Pass `revision` on every edit. `script_read` prints it as `rev` beside each file, and sending it back makes \
             the write conditional: if the script changed since you read it the batch is refused with STALE_SCRIPT and \
             nothing is written. Line-range and `source` edits REQUIRE it (NEEDS_REVISION otherwise), because they \
             cannot notice a change: a line range lands on whatever moved into those lines, and `source` discards the \
             other side's work. Another agent editing the same place, or the user typing in the editor, is enough. \
             find/replace works without it.\n\n\
             Writes go through `ScriptEditorService:UpdateSourceAsync`, so an open editor tab updates in place and \
             unsaved work is preserved. Undo for source changes is the script editor's own, per script — Ctrl+Z in a \
             script tab reverts that script, not the whole batch.\n\n\
             `target=\"live\"` edits the PUBLISHED place instead. It takes ONE edit, it replaces the whole `source` \
             rather than finding and replacing, and there is no undo of any kind — so read the script with \
             `script_read target=\"live\"` first and send back the whole thing, with its `rev` as `revision` so the \
             write is refused if someone published in between. Needs `confirm: true`.\n\n\
             It changes the SAVED place, not running servers: people already playing keep the old code until their \
             server empties. Follow it with `universe op=\"restart\"` to roll them over.",
            script_edit,
        ),
        define(
            spec("script_grep", "Search script source").read_only(),
            "Searches inside Luau source across the place and returns matching lines with their paths and line numbers.\n\n\
             Use this to find where something is defined or used before editing it — it is far cheaper than reading \
             whole scripts to look for one call.\n\n\
             Patterns are Lua patterns, which are not regular expressions: `%` escapes instead of backslash, there is \
             no alternation, and `-` means a lazy quantifier. Set `literal` to search for text exactly as written, \
             which is usually what you want for identifiers.\n\n\
             To look for several identifiers, pass them together as `patterns` (literal, up to 16): one pass over the \
             place instead of one per name, and each line says which of them it matched. `mode=\"files\"` lists \
             matching scripts only; `mode=\"counts\"` gives matching-line counts per pattern.\n\n\
             Results are grouped by script with its `rev`, which `script_edit` accepts as `revision`. Matches come from \
             the script editor's live buffer, so unsaved edits are searched too.",
            script_grep,
        ),
        define(
            spec("script_create", "Create scripts"),
            "Creates Script, LocalScript or ModuleScript instances with their source.\n\n\
             Batch related scripts into one call: they are created inside one ChangeHistoryService recording, so the \
             user can drop a whole generated system in a single undo. The response says whether that recording was \
             actually opened — Studio refuses while another one is in progress.\n\n\
             Prefer `Script` with `runContext: \"Client\"` over `LocalScript` in new work — a Script with an explicit \
             RunContext runs wherever you parent it, while LocalScript only runs under a player's character, backpack \
             or PlayerGui.\n\n\
             The exception is the starter containers — `StarterGui`, `StarterPack`, `StarterPlayerScripts`, \
             `StarterCharacterScripts`. They are COPIED into each player, so a Script with a non-Legacy RunContext \
             there runs once where it sits and again in every copy, while a Legacy one does not run at all. Use \
             `LocalScript` inside those. Creating one anyway comes back with a warning, because Studio's own warning \
             about it goes to its Output and never reaches `console`.\n\n\
             Use `script_edit` to change a script that already exists.",
            script_create,
        ),
    ]
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn numbers_lines() {
        assert_eq!(numbered("a\nb", 9), " 9│ a\n10│ b");
    }

    #[test]
    fn blind_edits_need_revisions() {
        let edit = |path: &str, rev: Option<&str>| EditSpec {
            path: path.into(),
            find: None,
            replace: None,
            replace_all: None,
            start_line: Some(1),
            end_line: None,
            replacement: Some("x".into()),
            source: None,
            revision: rev.map(str::to_string),
        };
        assert!(require_blind_revisions(&[edit("A", None)]).is_err());
        assert!(require_blind_revisions(&[edit("A", Some("r")), edit("A", None)]).is_ok());
    }
}
