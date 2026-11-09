//! `sync`: scripts mirrored between Studio and a folder on disk.
//!
//! `plan` decides what should move; this moves it. Every write into Studio is
//! conditional on the revision the last sync saw, every write to disk on the
//! file's last hash. Nothing is deleted on a first sync, disk deletions go to a
//! trash folder, and a folder remembers which place it belongs to.

pub mod plan;
mod watch;

pub use watch::{start_watch, stop_all_watches, stop_watch, watch_state};

use crate::bridge::StudioBridge;
use crate::errors::{Result, ToolError};
use crate::protocol::StudioSession;
use crate::tools::instances::{CreateNode, type_create_tree};
use parking_lot::Mutex;
use plan::{Action, BuildEntry, ConflictMemory, Direction, Layout, Manifest, ManifestEntry, Prefer, ScanResult};
use serde::Deserialize;
use serde_json::{Map, Value, json};
use sha2::{Digest, Sha256};
use std::collections::{BTreeMap, HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::sync::{Arc, LazyLock};
use std::time::SystemTime;

const STATE_DIR: &str = ".rbx-sync";
const MANIFEST: &str = "manifest.json";
pub const BUILD_SUFFIX: &str = ".build.json";
const SOURCEMAP: &str = "sourcemap.json";
const MASS_DELETE: usize = 10;
const BATCH_BYTES: usize = 1_500_000;
const BATCH_PATHS: usize = 200;

#[derive(Clone)]
pub struct SyncOptions {
    pub dir: PathBuf,
    pub roots: Option<Vec<String>>,
    pub studio_id: Option<String>,
    pub direction: Direction,
    pub prefer: Option<Prefer>,
    pub dry_run: bool,
    pub confirm_deletes: bool,
    pub rebind: bool,
    pub quiet: bool,
    pub builds: bool,
}

#[derive(Default, Clone)]
pub struct Conflict {
    pub file: String,
    #[allow(dead_code)] // kept for callers that report where a conflict lives
    pub path: Option<String>,
    pub reason: String,
}

#[derive(Default)]
pub struct SyncReport {
    pub dir: String,
    pub place: String,
    pub dry_run: bool,
    pub lines: Vec<String>,
    pub counts: BTreeMap<String, usize>,
    pub conflicts: Vec<Conflict>,
    pub held: Vec<String>,
    pub failures: Vec<(String, String)>,
    pub file_synced: Vec<String>,
    pub builds: Vec<String>,
    pub undo_step: Option<String>,
    pub new_conflicts: Vec<String>,
    pub build_conflicts: BTreeMap<String, (String, String, String)>,
}

impl SyncReport {
    fn new(dir: &Path, place: &str) -> Self {
        Self { dir: dir.display().to_string(), place: place.into(), ..Default::default() }
    }

    fn fail(&mut self, file: &str, reason: impl Into<String>) {
        self.failures.push((file.into(), reason.into()));
    }

    fn tally(&mut self, action: &Action) {
        *self.counts.entry(action.kind().into()).or_default() += 1;
        self.lines.push(action.describe());
    }
}

pub fn hash_of(text: &str) -> String {
    let digest = Sha256::digest(plan::normalise(text).as_bytes());
    digest.iter().map(|b| format!("{b:02x}")).collect()
}

fn absolute(dir: &Path, relative: &str) -> PathBuf {
    relative.split('/').fold(dir.to_path_buf(), |p, s| p.join(s))
}

fn posix(relative: &Path) -> String {
    relative.components().map(|c| c.as_os_str().to_string_lossy()).collect::<Vec<_>>().join("/")
}

pub fn resolve_dir(dir: Option<&str>) -> PathBuf {
    let cwd = std::env::current_dir().unwrap_or_default();
    let joined = cwd.join(dir.unwrap_or("studio"));
    std::path::absolute(&joined).unwrap_or(joined)
}

// --- target ------------------------------------------------------------------------

fn is_playtest(s: &StudioSession) -> bool {
    s.identity.context.as_deref().is_some_and(|c| c.starts_with("playtest"))
}

/// The edit session a sync runs against: named, active, or the only one.
pub async fn target_session(bridge: &Arc<StudioBridge>, studio_id: Option<&str>) -> Result<StudioSession> {
    let view = bridge.sessions().await?;
    let session = match (studio_id, &view.active_id) {
        (Some(id), _) => view.list.iter().find(|s| s.identity.studio_id == id).cloned(),
        (None, Some(active)) => view.list.iter().find(|s| &s.identity.studio_id == active).cloned(),
        (None, None) => {
            let edits: Vec<&StudioSession> = view.list.iter().filter(|s| !is_playtest(s)).collect();
            (edits.len() == 1).then(|| edits[0].clone())
        }
    };
    let Some(session) = session else {
        if view.list.is_empty() {
            return Err(ToolError::hint("NO_STUDIO", "No Studio is connected.", "Open Studio with the plugin enabled."));
        }
        return Err(ToolError::hint(
            "AMBIGUOUS_STUDIO",
            "Several Studio windows are connected and none is chosen.",
            "Pass `studioId` (see list_studios) or call set_active_studio.",
        ));
    };
    if is_playtest(&session) {
        return Err(ToolError::hint(
            "WRONG_CONTEXT",
            "That is a running playtest; anything synced into it is discarded on Stop.",
            "Pass the edit session's studioId (see list_studios).",
        ));
    }
    Ok(session)
}

// --- disk ----------------------------------------------------------------------------

/// Hashes by path, reused while a file's size and mtime have not moved.
type HashCache = HashMap<PathBuf, (u64, SystemTime, String)>;
static HASH_CACHE: LazyLock<Mutex<HashCache>> = LazyLock::new(Default::default);

#[derive(Default)]
pub struct DiskState {
    pub scripts: HashMap<String, String>,
    pub builds: HashMap<String, String>,
}

/// Every script and build file under `dir`; dot-folders, node_modules and symlinks skipped.
async fn scan_disk(dir: &Path) -> Result<DiskState> {
    let dir = dir.to_path_buf();
    tokio::task::spawn_blocking(move || {
        let mut state = DiskState::default();
        let mut stack = vec![dir.clone()];
        while let Some(folder) = stack.pop() {
            let entries = match std::fs::read_dir(&folder) {
                Ok(e) => e,
                Err(e) if e.kind() == std::io::ErrorKind::NotFound => continue,
                Err(e) => return Err(ToolError::from(e)),
            };
            for entry in entries.flatten() {
                let name = entry.file_name().to_string_lossy().into_owned();
                let Ok(kind) = entry.file_type() else { continue };
                if name.starts_with('.') || name == "node_modules" || kind.is_symlink() {
                    continue;
                }
                let full = entry.path();
                if kind.is_dir() {
                    stack.push(full);
                    continue;
                }
                if !kind.is_file() {
                    continue;
                }
                let build = name.ends_with(BUILD_SUFFIX);
                if !build && plan::class_from_file(&name).is_none() {
                    continue;
                }
                let Ok(meta) = entry.metadata() else { continue };
                let (len, mtime) = (meta.len(), meta.modified().unwrap_or(SystemTime::UNIX_EPOCH));
                let cached = HASH_CACHE.lock().get(&full).filter(|c| c.0 == len && c.1 == mtime).map(|c| c.2.clone());
                let hash = match cached {
                    Some(h) => h,
                    None => {
                        let Ok(text) = std::fs::read_to_string(&full) else { continue };
                        let h = hash_of(&text);
                        HASH_CACHE.lock().insert(full.clone(), (len, mtime, h.clone()));
                        h
                    }
                };
                let rel = posix(full.strip_prefix(&dir).unwrap_or(&full));
                if build { state.builds.insert(rel, hash) } else { state.scripts.insert(rel, hash) };
            }
        }
        Ok(state)
    })
    .await
    .map_err(ToolError::internal)?
}

async fn read_text(dir: &Path, relative: &str) -> std::io::Result<String> {
    Ok(plan::normalise(&tokio::fs::read_to_string(absolute(dir, relative)).await?))
}

/// Writes through a staging file, so a crash never leaves half a script.
async fn write_text(dir: &Path, relative: &str, text: &str) -> std::io::Result<()> {
    let target = absolute(dir, relative);
    if let Some(parent) = target.parent() {
        tokio::fs::create_dir_all(parent).await?;
    }
    let staging = PathBuf::from(format!("{}.{}.tmp", target.display(), std::process::id()));
    tokio::fs::write(&staging, text).await?;
    tokio::fs::rename(&staging, &target).await?;
    HASH_CACHE.lock().remove(&target);
    Ok(())
}

async fn trash(dir: &Path, relative: &str, run: &str) -> std::io::Result<()> {
    let from = absolute(dir, relative);
    let to = absolute(&dir.join(STATE_DIR).join("trash").join(run), relative);
    if let Some(parent) = to.parent() {
        tokio::fs::create_dir_all(parent).await?;
    }
    tokio::fs::rename(&from, &to).await?;
    HASH_CACHE.lock().remove(&from);
    Ok(())
}

async fn prune_empty(dir: &Path, relatives: &[String]) {
    let mut folders: HashSet<PathBuf> = HashSet::new();
    for rel in relatives {
        let mut folder = absolute(dir, rel).parent().map(Path::to_path_buf);
        while let Some(f) = folder {
            if !f.starts_with(dir) || f == dir {
                break;
            }
            folder = f.parent().map(Path::to_path_buf);
            folders.insert(f);
        }
    }
    let mut ordered: Vec<PathBuf> = folders.into_iter().collect();
    ordered.sort_by_key(|f| std::cmp::Reverse(f.as_os_str().len()));
    for f in ordered {
        if let Ok(mut entries) = tokio::fs::read_dir(&f).await
            && entries.next_entry().await.ok().flatten().is_none() {
                let _ = tokio::fs::remove_dir(&f).await;
            }
    }
}

pub async fn load_manifest(dir: &Path) -> Option<Manifest> {
    let bytes = tokio::fs::read(dir.join(STATE_DIR).join(MANIFEST)).await.ok()?;
    let m: Manifest = serde_json::from_slice(&bytes).ok()?;
    (m.version == 1).then_some(m)
}

async fn save_manifest(dir: &Path, manifest: &Manifest) -> std::io::Result<()> {
    let folder = dir.join(STATE_DIR);
    tokio::fs::create_dir_all(&folder).await?;
    // This machine's view of one Studio session; wrong anywhere else, so not committed.
    tokio::fs::write(folder.join(".gitignore"), "*\n").await?;
    let target = folder.join(MANIFEST);
    let staging = folder.join(format!("{MANIFEST}.tmp"));
    let mut text = serde_json::to_string_pretty(manifest).unwrap_or_default();
    text.push('\n');
    tokio::fs::write(&staging, text).await?;
    tokio::fs::rename(&staging, &target).await
}

/// A Rojo-style sourcemap so luau-lsp can follow requires between synced scripts.
async fn write_sourcemap(dir: &Path, manifest: &Manifest, scan: &ScanResult) {
    #[derive(serde::Serialize)]
    #[serde(rename_all = "camelCase")]
    struct Node {
        name: String,
        class_name: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        file_paths: Option<Vec<String>>,
        #[serde(skip_serializing_if = "Vec::is_empty")]
        children: Vec<Node>,
    }
    let class_of: HashMap<&str, &str> = scan.nodes.iter().map(|n| (n.path.as_str(), n.class_name.as_str())).collect();
    let mut root = Node { name: "Game".into(), class_name: "DataModel".into(), file_paths: None, children: vec![] };
    let base = dir.parent().unwrap_or(dir);
    static SUFFIX: LazyLock<regex::Regex> = LazyLock::new(|| regex::Regex::new(r"~\d+$").unwrap());
    for (file, entry) in &manifest.files {
        let mut parts: Vec<&str> = file.split('/').collect();
        let leaf = parts.pop().unwrap_or("");
        let Some(parsed) = plan::class_from_file(leaf) else { continue };
        let mut chain: Vec<String> = parts.iter().map(|s| s.to_string()).collect();
        if !parsed.init {
            chain.push(parsed.stem.clone());
        }
        let mut node = &mut root;
        let mut studio_path = String::new();
        let n = chain.len();
        for (i, segment) in chain.iter().enumerate() {
            let name = plan::decode_name(&SUFFIX.replace(segment, ""));
            studio_path = if studio_path.is_empty() { name.clone() } else { format!("{studio_path}.{name}") };
            let last = i == n - 1;
            let pos = node.children.iter().position(|c| c.name == name && (!last || c.file_paths.is_none()));
            let idx = match pos {
                Some(p) => p,
                None => {
                    let class = if last {
                        entry.class_name.clone()
                    } else if i == 0 {
                        name.clone()
                    } else {
                        class_of.get(studio_path.as_str()).copied().unwrap_or("Folder").to_string()
                    };
                    node.children.push(Node { name: name.clone(), class_name: class, file_paths: None, children: vec![] });
                    node.children.len() - 1
                }
            };
            let child = &mut node.children[idx];
            if last {
                child.class_name = entry.class_name.clone();
                let full = absolute(dir, file);
                child.file_paths = Some(vec![posix(full.strip_prefix(base).unwrap_or(&full))]);
            }
            node = child;
        }
    }
    let mut text = serde_json::to_string(&root).unwrap_or_default();
    text.push('\n');
    let current = tokio::fs::read_to_string(dir.join(SOURCEMAP)).await.ok();
    if current.as_deref() != Some(text.as_str()) {
        let _ = write_text(dir, SOURCEMAP, &text).await;
    }
}

// --- the run -------------------------------------------------------------------------

static LOCKS: LazyLock<Mutex<HashMap<PathBuf, Arc<tokio::sync::Mutex<()>>>>> = LazyLock::new(Default::default);

/// One run at a time per folder, so `watch` and a manual call never interleave.
fn lock_for(dir: &Path) -> Arc<tokio::sync::Mutex<()>> {
    LOCKS.lock().entry(dir.to_path_buf()).or_default().clone()
}

#[derive(Deserialize, Default)]
struct ReadItem {
    path: String,
    source: Option<String>,
    revision: Option<String>,
    #[serde(rename = "className")]
    class_name: Option<String>,
    message: Option<String>,
}

#[derive(Deserialize, Default)]
struct ApplyResult {
    #[serde(default)]
    ok: bool,
    path: Option<String>,
    revision: Option<String>,
    code: Option<String>,
    message: Option<String>,
}

impl ApplyResult {
    fn reason(&self) -> String {
        format!("{}: {}", self.code.as_deref().unwrap_or("undefined"), self.message.as_deref().unwrap_or("undefined"))
    }
}

#[derive(Deserialize, Default)]
#[serde(rename_all = "camelCase")]
struct ApplyResponse {
    #[serde(default)]
    writes: Vec<ApplyResult>,
    #[serde(default)]
    creates: Vec<ApplyResult>,
    #[serde(default)]
    deletes: Vec<ApplyResult>,
    #[serde(default)]
    moves: Vec<ApplyResult>,
    undo_step: Option<String>,
}

async fn read_studio(bridge: &Arc<StudioBridge>, studio: &str, paths: &[String], quiet: bool) -> Result<HashMap<String, ReadItem>> {
    let mut out = HashMap::new();
    for chunk in paths.chunks(BATCH_PATHS) {
        let r = bridge.call("sync.read", json!({ "paths": chunk, "quiet": quiet }), Some(studio), Some(60_000.0)).await?;
        let items: Vec<ReadItem> = serde_json::from_value(r.get("items").cloned().unwrap_or(json!([]))).unwrap_or_default();
        for item in items {
            out.insert(item.path.clone(), item);
        }
    }
    Ok(out)
}

fn assert_place(options: &SyncOptions, manifest: &Manifest, session: &StudioSession) -> Result<()> {
    let (Some(stored), place) = (manifest.place_id.filter(|p| *p != 0), session.identity.place_id) else { return Ok(()) };
    if place != 0 && stored != place && !options.rebind {
        return Err(ToolError::hint(
            "PLACE_MISMATCH",
            format!(
                "{} is synced with place {stored} ({}), not {place} ({}).",
                options.dir.display(),
                manifest.place_name.as_deref().unwrap_or("unnamed"),
                session.identity.place_name
            ),
            "Use a different `dir` for this place. Pass `rebind: true` only if this folder really should follow the new place.",
        ));
    }
    Ok(())
}

async fn scan_studio(bridge: &Arc<StudioBridge>, studio: &str, roots: Option<&Vec<String>>, revisions: bool, quiet: bool) -> Result<ScanResult> {
    let r = bridge
        .call("sync.scan", json!({ "roots": roots, "revisions": revisions, "quiet": quiet }), Some(studio), Some(120_000.0))
        .await?;
    serde_json::from_value(r).map_err(|e| ToolError::new("PLUGIN_ERROR", format!("Unexpected sync.scan reply: {e}")))
}

/// One sync: scan both sides, plan, read what the plan needs, apply (or report).
pub async fn run_sync(bridge: &Arc<StudioBridge>, options: &SyncOptions) -> Result<SyncReport> {
    let lock = lock_for(&options.dir);
    let _guard = lock.lock().await;
    sync_once(bridge, options).await
}

const LABELS: [(&str, &str); 9] = [
    ("push", "written to Studio"),
    ("pull", "written to disk"),
    ("create-studio", "created in Studio"),
    ("create-disk", "created on disk"),
    ("delete-studio", "deleted in Studio"),
    ("delete-disk", "moved to .rbx-sync/trash"),
    ("move-studio", "moved in Studio"),
    ("move-disk", "moved on disk"),
    ("export", "build files updated from Studio"),
];

fn label(kind: &str) -> Option<&'static str> {
    LABELS.iter().find(|(k, _)| *k == kind).map(|(_, l)| *l)
}

/// One line for the whole run, e.g. "3 written to Studio, 1 created on disk".
pub fn summarise(report: &SyncReport) -> String {
    let mut parts: Vec<String> = LABELS
        .iter()
        .filter_map(|(kind, text)| report.counts.get(*kind).filter(|c| **c > 0).map(|c| format!("{c} {text}")))
        .collect();
    if !report.builds.is_empty() {
        parts.push(format!("{} {}", report.builds.len(), if report.dry_run { "to build" } else { "built" }));
    }
    if !report.conflicts.is_empty() {
        parts.push(format!("{} conflict{}", report.conflicts.len(), if report.conflicts.len() == 1 { "" } else { "s" }));
    }
    if !report.failures.is_empty() {
        parts.push(format!("{} failed", report.failures.len()));
    }
    if parts.is_empty() { "nothing to do".into() } else { parts.join(", ") }
}

fn run_stamp() -> String {
    crate::tools::iso(crate::protocol::now_ms()).replace([':', '.'], "-")
}

fn depth_of(file: &str) -> usize {
    file.split('/').count()
}

fn is_init(file: &str) -> bool {
    plan::class_from_file(file.rsplit('/').next().unwrap_or("")).is_some_and(|c| c.init)
}

async fn sync_once(bridge: &Arc<StudioBridge>, options: &SyncOptions) -> Result<SyncReport> {
    let dir = &options.dir;
    let (direction, prefer, quiet) = (options.direction, options.prefer, options.quiet);
    let session = target_session(bridge, options.studio_id.as_deref()).await?;
    let studio_id = session.identity.studio_id.clone();
    let mut manifest = load_manifest(dir).await.unwrap_or_default();
    assert_place(options, &manifest, &session)?;

    let roots = options.roots.clone().or(manifest.roots.clone());
    let scan = scan_studio(bridge, &studio_id, roots.as_ref(), true, quiet).await?;
    let studio = plan::layout(&scan);
    let mut disk = scan_disk(dir).await?;
    let in_scope = |p: &str| scan.roots.iter().any(|r| p == r || p.starts_with(&format!("{r}.")));
    // Files outside the roots are left alone, as scripts are.
    let root_dirs: Vec<String> = scan
        .roots
        .iter()
        .map(|r| studio.dir_of.get(r).cloned().unwrap_or_else(|| r.split('.').map(|n| plan::encode_name(n, false)).collect::<Vec<_>>().join("/")))
        .collect();
    let under_roots = |f: &str| root_dirs.iter().any(|r| f.starts_with(&format!("{r}/")));
    disk.scripts.retain(|f, _| under_roots(f));
    disk.builds.retain(|f, _| under_roots(f));

    let planned = plan::plan(plan::PlanInput { manifest: &manifest, studio: &studio, disk: &disk.scripts, in_scope: &in_scope, direction, prefer });
    let mut report = SyncReport::new(dir, &session.identity.place_name);
    report.dry_run = options.dry_run;
    report.held = planned.held.iter().map(Action::describe).collect();
    report.file_synced = studio.file_synced.clone();

    // A run deleting most of what it tracks is far likelier a wrong dir than intent.
    let deletions = planned.actions.iter().filter(|a| matches!(a, Action::DeleteDisk { .. } | Action::DeleteStudio { .. })).count();
    let tracked = manifest.files.len();
    if deletions > MASS_DELETE && deletions * 2 > tracked && !options.confirm_deletes && !options.dry_run {
        return Err(ToolError::hint(
            "MASS_DELETE",
            format!("This sync would delete {deletions} of the {tracked} scripts it tracks."),
            "Check `dir` and `roots` with op=\"status\". If the deletions are intended, pass `confirmDeletes: true`.",
        ));
    }

    // Content ---------------------------------------------------------------
    let mut move_source: HashMap<String, String> = HashMap::new();
    for a in planned.actions.iter().chain(&planned.held) {
        if let Action::MoveDisk { file, from_file, .. } = a {
            move_source.insert(file.clone(), from_file.clone());
        }
    }
    let mut disk_text: HashMap<String, String> = HashMap::new();
    macro_rules! read_disk {
        ($file:expr) => {{
            let file: &str = $file;
            if !disk_text.contains_key(file) {
                let source = move_source.get(file).cloned().unwrap_or_else(|| file.to_string());
                let text = read_text(dir, &source).await?;
                disk_text.insert(file.to_string(), text);
            }
            disk_text[file].clone()
        }};
    }

    let mut needs: Vec<String> = Vec::new();
    for a in &planned.actions {
        if let Action::Pull { path, .. } | Action::CreateDisk { path, .. } | Action::Merge { path, .. } | Action::Adopt { path, .. } = a
            && !needs.contains(path) {
                needs.push(path.clone());
            }
    }
    let studio_text = read_studio(bridge, &studio_id, &needs, quiet).await?;
    let remembered = manifest.conflicts.clone();
    let mut conflicts_now: BTreeMap<String, (String, String, String)> = BTreeMap::new();
    let mut disk_seen: HashMap<String, String> = HashMap::new();
    let mut settled: Vec<Action> = Vec::new();
    let mut recorded: Vec<(String, ManifestEntry)> = Vec::new();

    for action in planned.actions {
        let (file, path, class, adopt) = match &action {
            Action::Merge { file, path, class_name, .. } => (file.clone(), path.clone(), class_name.clone(), false),
            Action::Adopt { file, path, class_name, .. } => (file.clone(), path.clone(), class_name.clone(), true),
            _ => {
                settled.push(action);
                continue;
            }
        };
        let read = studio_text.get(&path);
        let Some(source) = read.and_then(|r| r.source.as_ref()) else {
            report.fail(&file, read.and_then(|r| r.message.clone()).unwrap_or_else(|| "could not be read from Studio".into()));
            continue;
        };
        let revision = read.and_then(|r| r.revision.clone()).unwrap_or_default();
        let on_disk = read_disk!(&file);
        let in_studio = plan::normalise(source);
        let memory = remembered.get(&file);
        let studio_moved = memory.is_some_and(|m| revision != m.studio);
        let disk_moved = memory.is_some_and(|m| hash_of(&on_disk) != m.disk);
        let push = Action::Push { file: file.clone(), path: path.clone(), revision: revision.clone(), class_name: class.clone() };
        let pull = Action::Pull { file: file.clone(), path: path.clone(), revision: revision.clone(), class_name: class.clone() };
        if on_disk == in_studio {
            recorded.push((file.clone(), ManifestEntry { path, class_name: class, revision, hash: hash_of(&on_disk) }));
        } else if memory.is_some() && disk_moved && !studio_moved && direction != Direction::Pull {
            settled.push(push);
        } else if direction != Direction::Push
            && ((memory.is_some() && studio_moved && !disk_moved) || prefer == Some(Prefer::Studio))
        {
            disk_seen.insert(file.clone(), hash_of(&on_disk));
            settled.push(pull);
        } else if prefer == Some(Prefer::Disk) && direction != Direction::Pull {
            settled.push(push);
        } else {
            conflicts_now.insert(file.clone(), (revision.clone(), hash_of(&on_disk), in_studio));
            settled.push(Action::Conflict {
                file: file.clone(),
                path: Some(path),
                reason: format!(
                    "{}. Studio's version: {STATE_DIR}/conflicts/{file}. Edit the file to the merged text (or fix it in Studio) and sync again.",
                    if adopt {
                        "exists in both places with different text, and sync has no record of either"
                    } else {
                        "changed in both Studio and on disk since the last sync"
                    }
                ),
            });
        }
    }
    for a in &settled {
        if let Action::Conflict { file, path, reason } = a {
            report.conflicts.push(Conflict { file: file.clone(), path: path.clone(), reason: reason.clone() });
        }
    }
    let work: Vec<Action> = settled.into_iter().filter(|a| !matches!(a, Action::Conflict { .. })).collect();

    if options.dry_run {
        for a in &work {
            report.tally(a);
        }
        if options.builds {
            sync_builds(bridge, &studio_id, &mut manifest, &disk, &studio, &mut report, options, None).await;
        }
        return Ok(report);
    }

    let run = run_stamp();
    let mut touched: Vec<String> = Vec::new();

    // 1. Files renamed on disk to follow Studio, first: later steps read them there.
    for a in &work {
        let Action::MoveDisk { file, from_file, path, revision, hash, class_name } = a else { continue };
        if tokio::fs::metadata(absolute(dir, file)).await.is_ok() {
            report.fail(file, format!("a file is already there, so {from_file} was not moved; sync again once it is gone"));
            continue;
        }
        let target = absolute(dir, file);
        let moved = async {
            if let Some(parent) = target.parent() {
                tokio::fs::create_dir_all(parent).await?;
            }
            tokio::fs::rename(absolute(dir, from_file), &target).await
        }
        .await;
        match moved {
            Ok(()) => {
                HASH_CACHE.lock().remove(&absolute(dir, from_file));
                move_source.remove(file);
                manifest.files.remove(from_file);
                manifest.files.insert(
                    file.clone(),
                    ManifestEntry { path: path.clone(), class_name: class_name.clone(), revision: revision.clone(), hash: hash.clone() },
                );
                touched.push(from_file.clone());
                report.tally(a);
            }
            Err(e) => report.fail(file, format!("could not move from {from_file}: {e}")),
        }
    }

    // 2. Studio: structure and text in batches, each checked against its revision.
    let init_class_of = |folder: &str| -> Option<&'static str> {
        disk.scripts.keys().find_map(|f| {
            let rest = f.strip_prefix(&format!("{folder}/"))?;
            if rest.contains('/') {
                return None;
            }
            plan::class_from_file(rest).filter(|c| c.init).map(|c| c.class_name)
        })
    };
    let mut placements: HashMap<String, std::result::Result<plan::Placement, String>> = HashMap::new();
    let mut creates: Vec<(Action, Value, String, &'static str)> = Vec::new();
    let mut moves: Vec<(Action, Value)> = Vec::new();
    let mut deletes: Vec<(Action, Value)> = Vec::new();
    let mut writes: Vec<(Action, Value, String)> = Vec::new();

    for a in &work {
        match a {
            Action::CreateStudio { file } | Action::MoveStudio { file, .. } => {
                let where_ = placements.entry(file.clone()).or_insert_with(|| plan::placement_of(file, &studio, &init_class_of)).clone();
                let where_ = match where_ {
                    Ok(w) => w,
                    Err(e) => {
                        report.fail(file, e);
                        continue;
                    }
                };
                let parents: Vec<Value> = where_.parents.iter().map(|(n, c)| json!({ "name": n, "className": c })).collect();
                let mut item = Map::new();
                if let Some(p) = &where_.parent_path {
                    item.insert("parentPath".into(), json!(p));
                }
                item.insert("parents".into(), json!(parents));
                item.insert("name".into(), json!(where_.name));
                if let Action::MoveStudio { path, revision, .. } = a {
                    item.insert("path".into(), json!(path));
                    item.insert("revision".into(), json!(revision));
                    moves.push((a.clone(), Value::Object(item)));
                } else {
                    let text = read_disk!(file);
                    item.insert("className".into(), json!(where_.class_name));
                    item.insert("source".into(), json!(text));
                    creates.push((a.clone(), Value::Object(item), text, where_.class_name));
                }
            }
            Action::DeleteStudio { path, revision, .. } => deletes.push((a.clone(), json!({ "path": path, "revision": revision }))),
            Action::Push { file, path, revision, .. } => {
                let text = read_disk!(file);
                writes.push((a.clone(), json!({ "path": path, "source": text, "revision": revision }), text));
            }
            _ => {}
        }
    }
    // Outer scripts first, so a new folder's init script exists before its children.
    creates.sort_by(|x, y| depth_of(x.0.file()).cmp(&depth_of(y.0.file())).then(is_init(y.0.file()).cmp(&is_init(x.0.file()))));

    if !creates.is_empty() || !moves.is_empty() || !deletes.is_empty() {
        let r = bridge
            .call(
                "sync.apply",
                json!({
                    "creates": creates.iter().map(|c| &c.1).collect::<Vec<_>>(),
                    "moves": moves.iter().map(|m| &m.1).collect::<Vec<_>>(),
                    "deletes": deletes.iter().map(|d| &d.1).collect::<Vec<_>>(),
                    "quiet": quiet,
                }),
                Some(&studio_id),
                Some(120_000.0),
            )
            .await?;
        let r: ApplyResponse = serde_json::from_value(r).unwrap_or_default();
        report.undo_step = r.undo_step.clone();
        for (result, (action, _, text, class)) in r.creates.iter().zip(&creates) {
            match (&result.path, result.ok) {
                (Some(path), true) => {
                    manifest.files.insert(
                        action.file().to_string(),
                        ManifestEntry { path: path.clone(), class_name: class.to_string(), revision: result.revision.clone().unwrap_or_default(), hash: hash_of(text) },
                    );
                    report.tally(action);
                }
                _ => report.fail(action.file(), result.reason()),
            }
        }
        for (result, (action, _)) in r.moves.iter().zip(&moves) {
            let Action::MoveStudio { file, from_file, revision, hash, class_name, .. } = action else { continue };
            match (&result.path, result.ok) {
                (Some(path), true) => {
                    manifest.files.remove(from_file);
                    manifest.files.insert(
                        file.clone(),
                        ManifestEntry { path: path.clone(), class_name: class_name.clone(), revision: revision.clone(), hash: hash.clone() },
                    );
                    report.tally(action);
                }
                _ => report.fail(file, result.reason()),
            }
        }
        for (result, (action, _)) in r.deletes.iter().zip(&deletes) {
            if result.ok {
                manifest.files.remove(action.file());
                report.tally(action);
            } else {
                report.fail(action.file(), result.reason());
            }
        }
    }

    // Writes, batched by size.
    let mut batch: Vec<&(Action, Value, String)> = Vec::new();
    let mut bytes = 0;
    let mut flush_points: Vec<Vec<&(Action, Value, String)>> = Vec::new();
    for w in &writes {
        if !batch.is_empty() && (bytes + w.2.len() > BATCH_BYTES || batch.len() >= BATCH_PATHS) {
            flush_points.push(std::mem::take(&mut batch));
            bytes = 0;
        }
        bytes += w.2.len();
        batch.push(w);
    }
    if !batch.is_empty() {
        flush_points.push(batch);
    }
    for chunk in flush_points {
        let items: Vec<&Value> = chunk.iter().map(|w| &w.1).collect();
        let r = bridge.call("sync.apply", json!({ "writes": items, "quiet": quiet }), Some(&studio_id), Some(120_000.0)).await?;
        let r: ApplyResponse = serde_json::from_value(r).unwrap_or_default();
        for (result, (action, _, text)) in r.writes.iter().zip(chunk) {
            let Action::Push { file, path, class_name, .. } = action else { continue };
            if !result.ok {
                if result.code.as_deref() == Some("STALE_SCRIPT") {
                    report.conflicts.push(Conflict { file: file.clone(), path: Some(path.clone()), reason: "changed in Studio while syncing".into() });
                } else {
                    report.fail(file, result.reason());
                }
                continue;
            }
            manifest.files.insert(
                file.clone(),
                ManifestEntry { path: path.clone(), class_name: class_name.clone(), revision: result.revision.clone().unwrap_or_default(), hash: hash_of(text) },
            );
            report.tally(action);
        }
    }

    // 3. Disk: Studio's text into files, checked against the hash the plan saw.
    for a in &work {
        let (file, path, class, create) = match a {
            Action::Pull { file, path, class_name, .. } => (file, path, class_name, false),
            Action::CreateDisk { file, path, class_name, .. } => (file, path, class_name, true),
            _ => continue,
        };
        let read = studio_text.get(path);
        let (Some(source), Some(revision)) = (read.and_then(|r| r.source.as_ref()), read.and_then(|r| r.revision.as_ref())) else {
            report.fail(file, read.and_then(|r| r.message.clone()).unwrap_or_else(|| "could not be read from Studio".into()));
            continue;
        };
        // Re-read now: an editor may have saved in between.
        let expected = disk_seen.get(file).cloned().or_else(|| (!create).then(|| manifest.files.get(file).map(|e| e.hash.clone())).flatten());
        let current = read_text(dir, file).await.ok().map(|t| hash_of(&t));
        let overwrites = if create { current.is_some() } else { current.is_some() && current != expected };
        if overwrites && prefer != Some(Prefer::Studio) {
            report.conflicts.push(Conflict { file: file.clone(), path: Some(path.clone()), reason: "changed on disk while syncing".into() });
            continue;
        }
        match write_text(dir, file, source).await {
            Ok(()) => {
                manifest.files.insert(
                    file.clone(),
                    ManifestEntry {
                        path: path.clone(),
                        class_name: read.and_then(|r| r.class_name.clone()).unwrap_or_else(|| class.clone()),
                        revision: revision.clone(),
                        hash: hash_of(source),
                    },
                );
                report.tally(a);
            }
            Err(e) => report.fail(file, e.to_string()),
        }
    }
    for (file, entry) in recorded {
        manifest.files.insert(file, entry);
    }
    for a in &work {
        match a {
            Action::DeleteDisk { file, .. } => match trash(dir, file, &run).await {
                Ok(()) => {
                    manifest.files.remove(file);
                    touched.push(file.clone());
                    report.tally(a);
                }
                Err(e) => report.fail(file, e.to_string()),
            },
            Action::Forget { file } => {
                manifest.files.remove(file);
            }
            _ => {}
        }
    }
    prune_empty(dir, &touched).await;

    // 4. Build files, both ways.
    if options.builds {
        sync_builds(bridge, &studio_id, &mut manifest, &disk, &studio, &mut report, options, None).await;
    }

    // 5. Conflicts: remember this run's with Studio's side beside them; forget settled ones.
    let state = dir.join(STATE_DIR);
    let mut new_conflicts: Vec<String> = conflicts_now.keys().filter(|f| !remembered.contains_key(*f)).cloned().collect();
    let mut next: BTreeMap<String, ConflictMemory> = BTreeMap::new();
    for (file, (studio_rev, disk_hash, text)) in &conflicts_now {
        next.insert(file.clone(), ConflictMemory { studio: studio_rev.clone(), disk: disk_hash.clone() });
        let _ = write_text(&state, &format!("conflicts/{file}"), text).await;
    }
    for (file, (studio_hash, disk_hash, text)) in &report.build_conflicts {
        next.insert(file.clone(), ConflictMemory { studio: studio_hash.clone(), disk: disk_hash.clone() });
        if !remembered.contains_key(file) {
            new_conflicts.push(file.clone());
        }
        let _ = write_text(&state, &format!("conflicts/{file}"), text).await;
    }
    if !options.builds {
        for (file, memory) in &remembered {
            if file.ends_with(BUILD_SUFFIX) {
                next.insert(file.clone(), memory.clone());
            }
        }
    }
    for file in remembered.keys() {
        if !next.contains_key(file) {
            let _ = tokio::fs::remove_file(absolute(&state.join("conflicts"), file)).await;
        }
    }
    manifest.conflicts = next;
    manifest.place_id = Some(session.identity.place_id);
    manifest.place_name = Some(session.identity.place_name.clone());
    if options.roots.is_some() {
        manifest.roots = options.roots.clone();
    }
    save_manifest(dir, &manifest).await?;
    write_sourcemap(dir, &manifest, &scan).await;

    let disk_side: Vec<String> = ["pull", "create-disk", "delete-disk", "move-disk"]
        .iter()
        .filter_map(|k| report.counts.get(*k).filter(|c| **c > 0).map(|c| format!("{c} {}", label(k).unwrap_or(k))))
        .collect();
    if !disk_side.is_empty() || !new_conflicts.is_empty() {
        let mut lines: Vec<Value> = Vec::new();
        if !disk_side.is_empty() {
            let base = dir.file_name().map(|f| f.to_string_lossy().into_owned()).unwrap_or_default();
            lines.push(json!({ "level": "ok", "message": format!("sync to files: {}", disk_side.join(", ")), "detail": base }));
        }
        // Once per conflict, not once per run.
        for c in report.conflicts.iter().filter(|c| new_conflicts.contains(&c.file)).take(5) {
            lines.push(json!({ "level": "warn", "message": format!("sync conflict: {}", c.file), "detail": "changed on both sides; see .rbx-sync/conflicts" }));
        }
        if !lines.is_empty() {
            let _ = bridge.call("sync.log", json!({ "lines": lines }), Some(&studio_id), Some(5_000.0)).await;
        }
    }
    report.new_conflicts = new_conflicts;
    Ok(report)
}

// --- build files ------------------------------------------------------------------------

/// Keys in a fixed order, so an unchanged tree exports to the same bytes.
fn canonical(value: &Value) -> Value {
    const ORDER: [&str; 6] = ["className", "name", "properties", "attributes", "tags", "children"];
    match value {
        Value::Array(items) => Value::Array(items.iter().map(canonical).collect()),
        Value::Object(map) => {
            let mut keys: Vec<&String> = map.keys().collect();
            keys.sort_by(|a, b| {
                let ai = ORDER.iter().position(|o| o == a);
                let bi = ORDER.iter().position(|o| o == b);
                match (ai, bi) {
                    (None, None) => a.cmp(b),
                    _ => ai.unwrap_or(99).cmp(&bi.unwrap_or(99)),
                }
            });
            Value::Object(keys.into_iter().map(|k| (k.clone(), canonical(&map[k]))).collect())
        }
        other => other.clone(),
    }
}

struct Exported {
    path: String,
    text: String,
    chain: Vec<Value>,
    instances: Value,
    scripts: Value,
    skipped: Vec<Value>,
}

static PROPERTY_LISTS: LazyLock<Mutex<HashMap<String, Value>>> = LazyLock::new(Default::default);

/// A tree as build-file text, or None when nothing is at that path any more.
async fn export_tree(bridge: &Arc<StudioBridge>, studio: &str, target: &str, quiet: bool) -> Result<Option<Exported>> {
    let listed = match bridge.call("sync.classes", json!({ "path": target, "quiet": quiet }), Some(studio), Some(30_000.0)).await {
        Ok(v) => v,
        Err(e) if e.code == "NOT_FOUND" => return Ok(None),
        Err(e) => return Err(e),
    };
    let mut properties = Map::new();
    for class in listed.get("classes").and_then(Value::as_array).into_iter().flatten().filter_map(Value::as_str) {
        let cached = PROPERTY_LISTS.lock().get(class).cloned();
        let list = match cached {
            Some(l) => l,
            None => {
                let l: Vec<Value> =
                    crate::apidump::buildable_properties(class).await.into_iter().map(|p| json!({ "name": p.name, "type": p.value_type })).collect();
                let l = Value::Array(l);
                PROPERTY_LISTS.lock().insert(class.to_string(), l.clone());
                l
            }
        };
        properties.insert(class.to_string(), list);
    }
    let path = listed.get("path").and_then(Value::as_str).unwrap_or(target).to_string();
    let exported = bridge.call("sync.export", json!({ "path": path, "properties": properties, "quiet": quiet }), Some(studio), Some(120_000.0)).await?;
    let mut text = serde_json::to_string_pretty(&canonical(exported.get("spec").unwrap_or(&Value::Null))).unwrap_or_default();
    text.push('\n');
    Ok(Some(Exported {
        path: exported.get("path").and_then(Value::as_str).unwrap_or(&path).to_string(),
        text,
        chain: listed.get("chain").and_then(Value::as_array).cloned().unwrap_or_default(),
        instances: exported.get("instances").cloned().unwrap_or(json!(0)),
        scripts: exported.get("scripts").cloned().unwrap_or(json!(0)),
        skipped: exported.get("skipped").and_then(Value::as_array).cloned().unwrap_or_default(),
    }))
}

fn parent_of_build(file: &str, studio: &Layout) -> Option<String> {
    let folder = file.rsplit_once('/').map(|(f, _)| f).unwrap_or("");
    if folder.is_empty() {
        return None;
    }
    if let Some(known) = studio.path_of_dir.get(folder) {
        return Some(known.clone());
    }
    // A bare service folder with no scripts in it yet.
    (!folder.contains('/')).then(|| plan::decode_name(folder))
}

/// Replaces the tree at `parent` from a build file; returns the new tree's export.
async fn build_from(
    bridge: &Arc<StudioBridge>,
    studio: &str,
    dir: &Path,
    file: &str,
    parent: &str,
    quiet: bool,
    replaces: Option<&str>,
) -> Result<(String, Option<Exported>, Vec<Value>)> {
    let text = read_text(dir, file).await?;
    let raw: Value =
        serde_json::from_str(&text).map_err(|e| ToolError::hint("BAD_BUILD_FILE", format!("{file} is not valid JSON: {e}"), "Fix the file and sync again."))?;
    let node: CreateNode = serde_json::from_value(raw.clone()).map_err(|e| {
        ToolError::hint(
            "BAD_PARAMS",
            format!("instances[0]: {e}."),
            "Every entry in `children` takes the same fields as a top-level entry, and needs its own `className`.",
        )
    })?;
    let typed = type_create_tree(node, file.to_string()).await?;
    let r = bridge
        .call("sync.build", json!({ "parent": parent, "spec": typed, "replaces": replaces, "quiet": quiet }), Some(studio), Some(120_000.0))
        .await?;
    let built = r.get("path").and_then(Value::as_str).map(str::to_string).unwrap_or_else(|| {
        let name = raw.get("name").and_then(Value::as_str).or_else(|| raw.get("className").and_then(Value::as_str)).unwrap_or("");
        format!("{parent}.{name}")
    });
    let exported = export_tree(bridge, studio, &built, quiet).await?;
    Ok((built, exported, r.get("carried").and_then(Value::as_array).cloned().unwrap_or_default()))
}

/// Build files both ways, with the same three-way logic as scripts.
#[allow(clippy::too_many_arguments)]
async fn sync_builds(
    bridge: &Arc<StudioBridge>,
    studio_id: &str,
    manifest: &mut Manifest,
    disk: &DiskState,
    studio: &Layout,
    report: &mut SyncReport,
    options: &SyncOptions,
    only: Option<&[String]>,
) {
    let (dir, direction, prefer, dry, quiet) = (&options.dir, options.direction, options.prefer, options.dry_run, options.quiet);
    let remembered = manifest.conflicts.clone();
    let files: Vec<String> = match only {
        Some(o) => o.to_vec(),
        None => {
            let mut all: Vec<String> = manifest.builds.keys().cloned().chain(disk.builds.keys().cloned()).collect();
            all.sort();
            all.dedup();
            all
        }
    };
    let run = run_stamp();
    for file in files {
        let outcome: Result<()> = async {
            let entry = manifest.builds.get(&file).cloned();
            let Some(disk_hash) = disk.builds.get(&file).cloned() else {
                if only.is_some() {
                    report.fail(&file, "no such build file");
                } else if entry.is_some() && !dry {
                    manifest.builds.remove(&file);
                    report.lines.push(format!("forget        {file} (file deleted; the tree in Studio is left as it is)"));
                }
                return Ok(());
            };
            let Some(parent) = entry.as_ref().map(|e| e.parent.clone()).or_else(|| parent_of_build(&file, studio)) else {
                report.fail(&file, "its folder does not match an instance in Studio; export the tree to place it");
                return Ok(());
            };
            let target = match &entry {
                Some(e) => e.path.clone(),
                None => {
                    let raw: Value = serde_json::from_str(&read_text(dir, &file).await?).unwrap_or_default();
                    let name = raw.get("name").and_then(Value::as_str).or_else(|| raw.get("className").and_then(Value::as_str)).unwrap_or("");
                    format!("{parent}.{name}")
                }
            };
            let current = export_tree(bridge, studio_id, &target, quiet).await?;
            let studio_hash = current.as_ref().map(|c| hash_of(&c.text));
            let disk_text = read_text(dir, &file).await?;
            let disk_changed = entry.as_ref().is_none_or(|e| disk_hash != e.hash);
            let studio_changed = entry.as_ref().is_some_and(|e| e.studio.is_some() && studio_hash != e.studio);
            let memory = remembered.get(&file);

            enum Step {
                Build,
                Pull,
                Conflict(&'static str),
                Nothing,
            }
            let step = match &current {
                None => {
                    if entry.is_none() || disk_changed || prefer == Some(Prefer::Disk) {
                        Step::Build
                    } else {
                        if !dry && direction != Direction::Push {
                            trash(dir, &file, &run).await?;
                            manifest.builds.remove(&file);
                            report.lines.push(format!("delete-disk   {file} (the tree was deleted in Studio)"));
                        }
                        Step::Nothing
                    }
                }
                Some(_) if only.is_some() => {
                    if studio_changed && prefer != Some(Prefer::Disk) {
                        Step::Conflict("the tree was edited in Studio since the last sync; pass prefer: \"disk\" to rebuild over it")
                    } else {
                        Step::Build
                    }
                }
                Some(cur) => {
                    if plan::normalise(&cur.text) == disk_text {
                        if !dry {
                            manifest.builds.insert(file.clone(), BuildEntry { path: cur.path.clone(), parent: parent.clone(), hash: disk_hash.clone(), studio: studio_hash.clone() });
                        }
                        Step::Nothing
                    } else {
                        if let Some(e) = manifest.builds.get_mut(&file).filter(|e| e.studio.is_none() && !dry) {
                            e.studio = studio_hash.clone();
                        }
                        let studio_moved = memory.is_some_and(|m| studio_hash.as_deref() != Some(m.studio.as_str()));
                        let disk_moved = memory.is_some_and(|m| disk_hash != m.disk);
                        if memory.is_some() && disk_moved && !studio_moved {
                            Step::Build
                        } else if memory.is_some() && studio_moved && !disk_moved {
                            Step::Pull
                        } else if disk_changed && !studio_changed {
                            Step::Build
                        } else if studio_changed && !disk_changed {
                            Step::Pull
                        } else if !disk_changed && !studio_changed {
                            Step::Nothing
                        } else if prefer == Some(Prefer::Disk) {
                            Step::Build
                        } else if prefer == Some(Prefer::Studio) {
                            Step::Pull
                        } else if entry.is_none() {
                            Step::Conflict("the file and the tree in Studio differ, and sync has no record of either")
                        } else {
                            Step::Conflict("changed in both Studio and the file since the last sync")
                        }
                    }
                }
            };
            match step {
                Step::Nothing => {}
                Step::Build => {
                    if direction == Direction::Pull {
                        report.held.push(format!("build         {file}"));
                    } else if dry {
                        report.builds.push(file.clone());
                    } else {
                        let replaces = current.as_ref().map(|c| c.path.clone());
                        let (path, exported, carried) = build_from(bridge, studio_id, dir, &file, &parent, quiet, replaces.as_deref()).await?;
                        manifest.builds.insert(
                            file.clone(),
                            BuildEntry { path, parent: parent.clone(), hash: disk_hash.clone(), studio: exported.as_ref().map(|e| hash_of(&e.text)) },
                        );
                        report.builds.push(file.clone());
                        report.lines.push(format!("build         {file}"));
                        for moved in carried.iter().filter(|c| c.get("exact") != Some(&Value::Bool(true))) {
                            report.fail(
                                &file,
                                format!("{} kept, but its folder is gone from the new tree; it now sits at the root", crate::tools::disp(moved.get("path"))),
                            );
                        }
                    }
                }
                Step::Pull => {
                    let cur = current.as_ref().unwrap();
                    if direction == Direction::Push {
                        report.held.push(format!("export        {file}"));
                    } else if dry {
                        report.tally(&Action::Pull { file: file.clone(), path: cur.path.clone(), revision: String::new(), class_name: String::new() });
                    } else {
                        write_text(dir, &file, &cur.text).await?;
                        let h = hash_of(&cur.text);
                        manifest.builds.insert(file.clone(), BuildEntry { path: cur.path.clone(), parent: parent.clone(), hash: h.clone(), studio: Some(h) });
                        report.lines.push(format!("export        {file}"));
                        *report.counts.entry("export".into()).or_default() += 1;
                    }
                }
                Step::Conflict(reason) => {
                    report.conflicts.push(Conflict {
                        file: file.clone(),
                        path: Some(target.clone()),
                        reason: format!("{reason}. Studio's version: {STATE_DIR}/conflicts/{file}."),
                    });
                    if let Some(cur) = &current {
                        report.build_conflicts.insert(file.clone(), (studio_hash.clone().unwrap_or_default(), disk_hash.clone(), cur.text.clone()));
                    }
                }
            }
            Ok(())
        }
        .await;
        if let Err(e) = outcome {
            report.fail(&file, format!("{}: {}", e.code, e.message));
        }
    }
}

/// Rebuilds named build files now (default: every changed one).
pub async fn run_build(bridge: &Arc<StudioBridge>, options: &SyncOptions, files: Option<Vec<String>>) -> Result<SyncReport> {
    let lock = lock_for(&options.dir);
    let _guard = lock.lock().await;
    let session = target_session(bridge, options.studio_id.as_deref()).await?;
    let mut manifest = load_manifest(&options.dir).await.unwrap_or_default();
    assert_place(options, &manifest, &session)?;
    let disk = scan_disk(&options.dir).await?;
    let scan = scan_studio(bridge, &session.identity.studio_id, options.roots.as_ref().or(manifest.roots.as_ref()), false, false).await?;
    let mut report = SyncReport::new(&options.dir, &session.identity.place_name);
    let only: Option<Vec<String>> = files.map(|f| f.into_iter().map(|x| x.replace('\\', "/")).collect());
    let opts = SyncOptions { direction: Direction::Push, ..options.clone() };
    sync_builds(bridge, &session.identity.studio_id, &mut manifest, &disk, &plan::layout(&scan), &mut report, &opts, only.as_deref()).await;
    let state = options.dir.join(STATE_DIR);
    for (file, (studio_hash, disk_hash, text)) in &report.build_conflicts {
        manifest.conflicts.insert(file.clone(), ConflictMemory { studio: studio_hash.clone(), disk: disk_hash.clone() });
        let _ = write_text(&state, &format!("conflicts/{file}"), text).await;
    }
    if manifest.place_id.is_none_or(|p| p == 0) {
        manifest.place_id = Some(session.identity.place_id);
    }
    if manifest.place_name.as_deref().is_none_or(str::is_empty) {
        manifest.place_name = Some(session.identity.place_name.clone());
    }
    save_manifest(&options.dir, &manifest).await?;
    Ok(report)
}

pub struct ExportedFile {
    pub path: String,
    pub file: String,
    pub instances: Value,
    pub scripts: Value,
    pub skipped: Vec<Value>,
}

/// Writes instance trees as build files beside the synced scripts.
pub async fn run_export(bridge: &Arc<StudioBridge>, options: &SyncOptions, paths: &[String]) -> Result<Vec<ExportedFile>> {
    let lock = lock_for(&options.dir);
    let _guard = lock.lock().await;
    let session = target_session(bridge, options.studio_id.as_deref()).await?;
    let studio_id = session.identity.studio_id.clone();
    let mut manifest = load_manifest(&options.dir).await.unwrap_or_default();
    assert_place(options, &manifest, &session)?;
    let scan = scan_studio(bridge, &studio_id, options.roots.as_ref().or(manifest.roots.as_ref()), false, false).await?;
    let studio = plan::layout(&scan);
    let mut out = Vec::new();
    for wanted in paths {
        let exported = export_tree(bridge, &studio_id, wanted, false)
            .await?
            .ok_or_else(|| ToolError::hint("NOT_FOUND", format!("Nothing at {wanted}."), "Check the path with find or tree."))?;
        let chain = &exported.chain;
        if chain.len() < 2 {
            return Err(ToolError::hint(
                "BAD_PATH",
                format!("{} is a service; a build file replaces its tree, and a service cannot be replaced.", exported.path),
                "Export the instances inside it instead, e.g. StarterGui.Shop.",
            ));
        }
        let segment = |link: &Value| {
            let name = link.get("name").and_then(Value::as_str).unwrap_or("");
            let ordinal = link.get("ordinal").and_then(Value::as_u64).filter(|o| *o > 1);
            format!("{}{}", plan::encode_name(name, false), ordinal.map(|o| format!("~{o}")).unwrap_or_default())
        };
        let mut folders: Vec<String> = Vec::new();
        for link in &chain[..chain.len() - 1] {
            let path = link.get("path").and_then(Value::as_str).unwrap_or("");
            folders.push(match studio.dir_of.get(path) {
                Some(known) => known.rsplit('/').next().unwrap_or(known).to_string(),
                None => segment(link),
            });
        }
        let stem = segment(&chain[chain.len() - 1]);
        folders.push(format!("{stem}{BUILD_SUFFIX}"));
        let file = folders.join("/");
        write_text(&options.dir, &file, &exported.text).await?;
        let hash = hash_of(&exported.text);
        let parent = chain[chain.len() - 2].get("path").and_then(Value::as_str).unwrap_or("").to_string();
        manifest.builds.insert(file.clone(), BuildEntry { path: exported.path.clone(), parent, hash: hash.clone(), studio: Some(hash) });
        manifest.conflicts.remove(&file);
        out.push(ExportedFile { path: exported.path, file, instances: exported.instances, scripts: exported.scripts, skipped: exported.skipped });
    }
    if manifest.place_id.is_none_or(|p| p == 0) {
        manifest.place_id = Some(session.identity.place_id);
    }
    if manifest.place_name.as_deref().is_none_or(str::is_empty) {
        manifest.place_name = Some(session.identity.place_name.clone());
    }
    save_manifest(&options.dir, &manifest).await?;
    Ok(out)
}
