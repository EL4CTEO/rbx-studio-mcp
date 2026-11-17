//! Luau check: runs luau-lsp (or, failing that, luau-analyze) over synced files
//! before they reach Studio, so a syntax error never lands in the place and type
//! or API mistakes come back in the same reply.
//!
//! luau-lsp gets Roblox's types (its definitions file, cached for a week) and the
//! folder's sourcemap, so requires and DataModel paths resolve. The analysis runs
//! strict, but by default only the type errors that are almost always real bugs
//! (a member that does not exist, an unknown global) are kept for scripts that
//! do not opt into --!strict themselves; the lints Studio turns off stay off.

use regex::Regex;
use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::sync::LazyLock;
use std::time::Duration;

const DEFS_URL: &str = "https://raw.githubusercontent.com/JohnnyMorganz/luau-lsp/main/scripts/globalTypes.PluginSecurity.d.luau";
const DEFS_TTL_MS: u64 = 7 * 24 * 3600 * 1000;
const RUN_TIMEOUT: Duration = Duration::from_secs(90);
/// Windows caps a command line near 32k characters.
const ARGV_BUDGET: usize = 24_000;
/// Lints Studio switches off; the rest match Script Analysis.
const STUDIO_OFF_LINTS: [&str; 6] = ["LocalShadow", "SameLineStatement", "LocalUnused", "FunctionUnused", "ImportUnused", "ImplicitReturn"];

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Mode {
    Off,
    Default,
    Strict,
}

#[derive(Clone, Debug)]
pub struct Diagnostic {
    pub file: String,
    pub line: u32,
    pub col: u32,
    /// Last column, inclusive; the start column when unknown.
    pub end_col: u32,
    pub rule: String,
    pub message: String,
    /// A create.roblox.com page about it.
    pub href: Option<String>,
}

impl Diagnostic {
    pub fn is_syntax(&self) -> bool {
        self.rule == "SyntaxError"
    }

    pub fn describe(&self) -> String {
        format!("{}:{}:{} {}: {}", self.file, self.line, self.col, self.rule, self.message)
    }
}

#[derive(Clone, Debug, Default)]
pub struct CheckResult {
    /// What ran, e.g. "luau-lsp 1.70.1, Roblox types".
    pub tool: String,
    pub files: usize,
    pub diagnostics: Vec<Diagnostic>,
    /// Why the check was partial or skipped.
    pub note: Option<String>,
    /// The text each file had when checked.
    pub sources: HashMap<String, String>,
    /// Files that opt into --!strict, whose type errors Studio shows itself.
    pub strict_files: HashSet<String>,
}

impl CheckResult {
    pub fn syntax_errors(&self) -> HashMap<&str, &Diagnostic> {
        let mut out = HashMap::new();
        for d in self.diagnostics.iter().filter(|d| d.is_syntax()) {
            out.entry(d.file.as_str()).or_insert(d);
        }
        out
    }
}

enum Checker {
    Lsp(PathBuf),
    Analyze(PathBuf),
}

fn exe(name: &str) -> String {
    if cfg!(windows) { format!("{name}.exe") } else { name.to_string() }
}

fn on_path(name: &str) -> Option<PathBuf> {
    let file = exe(name);
    std::env::split_paths(&std::env::var_os("PATH")?).map(|d| d.join(&file)).find(|p| p.is_file())
}

fn find_checker() -> Option<Checker> {
    if let Some(p) = std::env::var_os("RBX_STUDIO_MCP_LUAU_LSP").map(PathBuf::from).filter(|p| p.is_file()) {
        return Some(Checker::Lsp(p));
    }
    if let Some(p) = on_path("luau-lsp") {
        return Some(Checker::Lsp(p));
    }
    let local = std::env::current_dir().ok().map(|d| d.join("tools").join(exe("luau-analyze"))).filter(|p| p.is_file());
    on_path("luau-analyze").or(local).map(Checker::Analyze)
}

fn cache_dir() -> PathBuf {
    std::env::temp_dir().join("roblox-studio-mcp").join("luau")
}

static DEFS_LOCK: LazyLock<tokio::sync::Mutex<()>> = LazyLock::new(Default::default);

fn age_ms(path: &Path) -> Option<u64> {
    let modified = std::fs::metadata(path).ok()?.modified().ok()?;
    Some(modified.elapsed().map(|d| d.as_millis() as u64).unwrap_or(0))
}

/// Roblox's type definitions, fetched once a week; a stale copy beats none.
async fn definitions() -> Option<PathBuf> {
    let _guard = DEFS_LOCK.lock().await;
    let path = cache_dir().join("globalTypes.d.luau");
    let age = age_ms(&path);
    if age.is_some_and(|a| a < DEFS_TTL_MS) {
        return Some(path);
    }
    let fetched = async {
        let response = reqwest::Client::new().get(DEFS_URL).timeout(Duration::from_secs(30)).send().await.ok()?;
        if !response.status().is_success() {
            return None;
        }
        let bytes = response.bytes().await.ok()?;
        (bytes.len() > 10_000).then_some(bytes)
    }
    .await;
    if let Some(bytes) = fetched {
        let staging = path.with_extension(format!("{}.tmp", std::process::id()));
        let written = tokio::fs::create_dir_all(cache_dir()).await.is_ok()
            && tokio::fs::write(&staging, &bytes).await.is_ok()
            && tokio::fs::rename(&staging, &path).await.is_ok();
        if !written {
            let _ = tokio::fs::remove_file(&staging).await;
        }
    }
    age_ms(&path).map(|_| path)
}

async fn base_luaurc() -> Option<PathBuf> {
    let path = cache_dir().join("base.luaurc");
    let lint: serde_json::Map<String, serde_json::Value> = STUDIO_OFF_LINTS.iter().map(|l| (l.to_string(), false.into())).collect();
    let text = serde_json::json!({ "languageMode": "strict", "lint": lint }).to_string();
    if tokio::fs::read_to_string(&path).await.ok().as_deref() != Some(text.as_str()) {
        tokio::fs::create_dir_all(cache_dir()).await.ok()?;
        tokio::fs::write(&path, text).await.ok()?;
    }
    Some(path)
}

static LINE: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"^(.+?)(?: \[[^\]]*\])?:(\d+):(\d+)(?:-(\d+))?: \(\w+\) (\w+): (.*)$").unwrap());

fn key(path: &str) -> String {
    path.replace('\\', "/").to_lowercase()
}

/// Parses the plain formatter; lines that are not a diagnostic continue the one before.
fn parse(output: &str, cwd: &Path, by_key: &HashMap<String, String>) -> Vec<Diagnostic> {
    let mut out: Vec<Diagnostic> = Vec::new();
    let mut last_kept = false;
    for raw in output.lines() {
        let line = raw.trim_end();
        if line.is_empty() || line.starts_with("[INFO]") || line.starts_with("[WARN]") || line.starts_with("[ERROR]") {
            continue;
        }
        let Some(c) = LINE.captures(line) else {
            if last_kept && let Some(d) = out.last_mut() {
                d.message.push('\n');
                d.message.push_str(line);
            }
            continue;
        };
        let reported = Path::new(&c[1]);
        let absolute = if reported.is_absolute() { reported.to_path_buf() } else { cwd.join(reported) };
        let Some(file) = by_key.get(&key(&absolute.to_string_lossy())) else {
            last_kept = false;
            continue;
        };
        let col = c[3].parse().unwrap_or(0);
        out.push(Diagnostic {
            file: file.clone(),
            line: c[2].parse().unwrap_or(0),
            col,
            end_col: c.get(4).and_then(|m| m.as_str().parse().ok()).unwrap_or(col),
            rule: c[5].to_string(),
            message: c[6].to_string(),
            href: None,
        });
        last_kept = true;
    }
    out
}

static KEPT_TYPE_ERRORS: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"^(Key '[^']*' not found in (external type|class|table)|Unknown global|Unknown type|Argument count mismatch|Cannot call a value of type)").unwrap()
});

fn opts_into_strict(text: &str) -> bool {
    text.lines().take_while(|l| l.trim_start().starts_with("--") || l.trim().is_empty()).any(|l| l.trim() == "--!strict")
}

async fn run_one(program: &Path, args: &[String], cwd: &Path) -> std::result::Result<String, String> {
    let mut command = tokio::process::Command::new(program);
    command.args(args).current_dir(cwd).stdin(Stdio::null()).stdout(Stdio::piped()).stderr(Stdio::piped()).kill_on_drop(true);
    #[cfg(windows)]
    command.creation_flags(0x0800_0000); // CREATE_NO_WINDOW
    let child = command.spawn().map_err(|e| format!("could not start {}: {e}", program.display()))?;
    match tokio::time::timeout(RUN_TIMEOUT, child.wait_with_output()).await {
        Ok(Ok(o)) => Ok(format!("{}\n{}", String::from_utf8_lossy(&o.stdout), String::from_utf8_lossy(&o.stderr))),
        Ok(Err(e)) => Err(e.to_string()),
        Err(_) => Err(format!("timed out after {}s", RUN_TIMEOUT.as_secs())),
    }
}

async fn version(program: &Path) -> Option<String> {
    let out = run_one(program, &["--version".into()], Path::new(".")).await.ok()?;
    out.lines().map(str::trim).find(|l| !l.is_empty()).map(str::to_string)
}

/// Checks `files` (relative to `dir`, '/'-separated). None when there is nothing to do.
pub async fn check(dir: &Path, files: &[String], mode: Mode) -> Option<CheckResult> {
    if mode == Mode::Off || files.is_empty() {
        return None;
    }
    let Some(checker) = find_checker() else {
        return Some(CheckResult {
            note: Some("Luau check skipped: no luau-lsp on PATH. Install it (github.com/JohnnyMorganz/luau-lsp/releases) or set RBX_STUDIO_MCP_LUAU_LSP to its path.".into()),
            ..Default::default()
        });
    };
    // The sourcemap's paths are relative to the folder's parent.
    let cwd = dir.parent().unwrap_or(dir).to_path_buf();
    let prefix = dir.strip_prefix(&cwd).map(|p| p.to_string_lossy().replace('\\', "/")).unwrap_or_default();
    let relative = |f: &str| if prefix.is_empty() { f.to_string() } else { format!("{prefix}/{f}") };
    let by_key: HashMap<String, String> = files.iter().map(|f| (key(&cwd.join(relative(f)).to_string_lossy()), f.clone())).collect();

    let (program, base, tool, mut note, syntax_only) = match &checker {
        Checker::Lsp(p) => {
            let defs = definitions().await;
            let rc = base_luaurc().await;
            let mut args = vec!["analyze".to_string(), "--platform=roblox".into(), "--formatter=plain".into()];
            let sourcemap = dir.join("sourcemap.json");
            if sourcemap.is_file() {
                args.push(format!("--sourcemap={}", sourcemap.display()));
            }
            if let Some(rc) = rc {
                args.push(format!("--base-luaurc={}", rc.display()));
            }
            let name = version(p).await.map(|v| format!("luau-lsp {v}")).unwrap_or_else(|| "luau-lsp".into());
            match defs {
                Some(d) => {
                    args.push(format!("--definitions=@roblox={}", d.display()));
                    (p.clone(), args, format!("{name}, Roblox types"), None, false)
                }
                None => (p.clone(), args, name, Some("Roblox type definitions could not be downloaded, so only syntax was checked.".to_string()), true),
            }
        }
        Checker::Analyze(p) => (
            p.clone(),
            vec!["--formatter=plain".to_string()],
            "luau-analyze".to_string(),
            Some("Only syntax was checked: luau-analyze has no Roblox types. Install luau-lsp for type and API checks.".to_string()),
            true,
        ),
    };
    let mut diagnostics = Vec::new();
    let mut chunk: Vec<String> = Vec::new();
    let mut len = 0;
    let mut chunks: Vec<Vec<String>> = Vec::new();
    for f in files {
        let r = relative(f);
        if !chunk.is_empty() && len + r.len() + 3 > ARGV_BUDGET {
            chunks.push(std::mem::take(&mut chunk));
            len = 0;
        }
        len += r.len() + 3;
        chunk.push(r);
    }
    if !chunk.is_empty() {
        chunks.push(chunk);
    }
    for c in chunks {
        let args: Vec<String> = base.iter().cloned().chain(c).collect();
        match run_one(&program, &args, &cwd).await {
            Ok(output) => diagnostics.extend(parse(&output, &cwd, &by_key)),
            Err(e) => {
                note = Some(format!("Luau check failed: {e}"));
                break;
            }
        }
    }

    let mut sources: HashMap<String, String> = HashMap::new();
    for f in files {
        if let Ok(t) = tokio::fs::read_to_string(dir.join(f)).await {
            sources.insert(f.clone(), crate::sync::plan::normalise(&t));
        }
    }
    let strict_files: HashSet<String> = sources.iter().filter(|(_, t)| opts_into_strict(t)).map(|(f, _)| f.clone()).collect();
    let mut kept = Vec::new();
    for d in diagnostics {
        let keep = if syntax_only {
            d.is_syntax()
        } else {
            d.rule != "TypeError" || mode == Mode::Strict || KEPT_TYPE_ERRORS.is_match(&d.message) || strict_files.contains(&d.file)
        };
        if keep {
            kept.push(d);
        }
    }
    for d in &mut kept {
        explain_missing_member(d).await;
    }
    for f in files {
        if let Some(text) = sources.get(f) {
            kept.extend(deprecated_classes(f, text).await);
        }
    }
    // A file that does not parse only reports why.
    let unparsed: std::collections::HashSet<String> = kept.iter().filter(|d| d.is_syntax()).map(|d| d.file.clone()).collect();
    kept.retain(|d| d.is_syntax() || !unparsed.contains(&d.file));
    kept.sort_by(|a, b| (a.file.as_str(), a.line, a.col).cmp(&(b.file.as_str(), b.line, b.col)));
    kept.dedup_by(|a, b| a.file == b.file && a.line == b.line && a.col == b.col && a.rule == b.rule && a.message == b.message);
    Some(CheckResult { tool, files: files.len(), diagnostics: kept, note, sources, strict_files })
}

/// Replacements the dump does not record, for the deprecations met most often.
const REPLACEMENTS: [(&str, &str); 10] = [
    ("BodyVelocity", "LinearVelocity"),
    ("BodyPosition", "AlignPosition"),
    ("BodyGyro", "AlignOrientation"),
    ("BodyAngularVelocity", "AngularVelocity"),
    ("BodyForce", "VectorForce"),
    ("BodyThrust", "VectorForce"),
    ("Velocity", "AssemblyLinearVelocity"),
    ("RotVelocity", "AssemblyAngularVelocity"),
    ("Hint", "a TextLabel in a ScreenGui"),
    ("Message", "a TextLabel in a ScreenGui"),
];

fn replacement(name: &str) -> String {
    REPLACEMENTS.iter().find(|(n, _)| *n == name).map(|(_, r)| format!(", use {r} instead")).unwrap_or_default()
}

fn docs_href(class: &str, member: Option<&str>) -> String {
    match member {
        Some(m) => format!("https://create.roblox.com/docs/reference/engine/classes/{class}#{m}"),
        None => format!("https://create.roblox.com/docs/reference/engine/classes/{class}"),
    }
}

static MISSING_MEMBER: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"^Key '(\w+)' not found in external type '(\w+)'").unwrap());

/// Roblox's type definitions leave deprecated properties out, so using one reads
/// as a typo. Says which it is: deprecated, or a likely misspelling.
async fn explain_missing_member(d: &mut Diagnostic) {
    if d.rule != "TypeError" {
        return;
    }
    let Some(c) = MISSING_MEMBER.captures(&d.message) else { return };
    let (member, class) = (c[1].to_string(), c[2].to_string());
    if crate::apidump::property_deprecated(&class, &member).await {
        d.rule = "DeprecatedApi".into();
        d.message = format!("Property '{class}.{member}' is deprecated{}", replacement(&member));
        d.href = Some(docs_href(&class, Some(&member)));
        return;
    }
    let close = crate::apidump::suggest_live_property(&class, &member).await;
    if let Some(best) = close.first() {
        d.message.push_str(&format!(" (did you mean '{best}'?)"));
    }
}

static INSTANCE_NEW: LazyLock<Regex> = LazyLock::new(|| Regex::new(r#"Instance\.new\(\s*["'](\w+)["']"#).unwrap());

/// `Instance.new("BodyVelocity")`: the type definitions keep deprecated classes unmarked.
async fn deprecated_classes(file: &str, text: &str) -> Vec<Diagnostic> {
    let mut out = Vec::new();
    for (i, line) in text.lines().enumerate() {
        let code = line.split("--").next().unwrap_or(line);
        for c in INSTANCE_NEW.captures_iter(code) {
            let name = c.get(1).unwrap();
            if crate::apidump::class_deprecated(name.as_str()).await != Some(true) {
                continue;
            }
            out.push(Diagnostic {
                file: file.to_string(),
                line: i as u32 + 1,
                col: name.start() as u32 + 1,
                end_col: name.end() as u32,
                rule: "DeprecatedApi".into(),
                message: format!("Class '{}' is deprecated{}", name.as_str(), replacement(name.as_str())),
                href: Some(docs_href(name.as_str(), None)),
            });
        }
    }
    out
}

/// What Studio's own Script Analysis does not already show: type errors in
/// scripts that are not --!strict, deprecated classes and deprecated globals
/// (`wait`, `spawn`). Studio flags deprecated members itself, and syntax errors
/// and the other lints would be duplicates too.
pub fn for_studio<'a>(result: &'a CheckResult, file: &str) -> Vec<&'a Diagnostic> {
    result
        .diagnostics
        .iter()
        .filter(|d| d.file == file)
        .filter(|d| match d.rule.as_str() {
            "DeprecatedApi" => d.message.starts_with("Class '") || d.message.starts_with("Function '"),
            "TypeError" => !result.strict_files.contains(file),
            _ => false,
        })
        .collect()
}

/// Lines for a reply: a heading, then up to `limit` diagnostics.
pub fn render(result: &CheckResult, limit: usize) -> Vec<String> {
    let mut out = Vec::new();
    if result.tool.is_empty() {
        out.extend(result.note.clone());
        return out;
    }
    let files_with: std::collections::HashSet<&str> = result.diagnostics.iter().map(|d| d.file.as_str()).collect();
    if result.diagnostics.is_empty() {
        out.push(format!("Luau check ({}): {} file(s), no problems.", result.tool, result.files));
    } else {
        out.push(format!(
            "Luau check ({}): {} problem(s) in {} of {} file(s):",
            result.tool,
            result.diagnostics.len(),
            files_with.len(),
            result.files
        ));
        for d in result.diagnostics.iter().take(limit) {
            out.push(format!("  {}", d.describe().replace('\n', "\n    ")));
        }
        if result.diagnostics.len() > limit {
            out.push(format!("  … and {} more", result.diagnostics.len() - limit));
        }
    }
    out.extend(result.note.clone());
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_absolute_and_relative_lines() {
        let cwd = std::env::temp_dir().join("work");
        let main = cwd.join("studio").join("SSS").join("Main.server.luau");
        let by_key: HashMap<String, String> = [(key(&main.to_string_lossy()), "SSS/Main.server.luau".to_string())].into_iter().collect();
        let abs = main.to_string_lossy();
        let out = format!(
            "[INFO] Loading definitions file\n\
             {abs} [game/SSS/Main]:3:1-8: (W0) TypeError: Key 'Colour' not found in external type 'Part'\n\
             studio/SSS/Main.server.luau:4:7-12: (W0) LocalUnused: Variable 'x' is never used\n\
             studio/Other.luau:1:1-2: (W0) SyntaxError: nope\n\
             {abs} [game/SSS/Main]:9:2-4: (W0) TypeError: Type 'a' could not be converted into 'b'\n\
             caused by: something"
        );
        let d = parse(&out, &cwd, &by_key);
        assert_eq!(d.len(), 3);
        assert_eq!((d[0].line, d[0].col, d[0].end_col, d[0].rule.as_str()), (3, 1, 8, "TypeError"));
        assert_eq!(d[1].rule, "LocalUnused");
        assert!(d[2].message.ends_with("caused by: something"));
    }

    #[test]
    fn strict_header() {
        assert!(opts_into_strict("--!strict\nlocal x = 1"));
        assert!(opts_into_strict("-- comment\n--!strict\n"));
        assert!(!opts_into_strict("local x = 1\n--!strict"));
    }

    #[test]
    fn kept_type_errors() {
        assert!(KEPT_TYPE_ERRORS.is_match("Key 'Colour' not found in external type 'Part'"));
        assert!(KEPT_TYPE_ERRORS.is_match("Unknown global 'foo'"));
        assert!(KEPT_TYPE_ERRORS.is_match("Key 'foo' not found in table 'M'"));
        assert!(!KEPT_TYPE_ERRORS.is_match("Type 'string' could not be converted into 'number'"));
    }
}
