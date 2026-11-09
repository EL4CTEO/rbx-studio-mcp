//! Keeps a folder and Studio in step until stopped.
//!
//! A sync runs only when something changed: the disk says so through a file
//! watcher, Studio through `sync.changes`. A slow shape check covers what
//! neither sees (a folder renamed in Studio). Most events are echoes of the
//! watch's own writes; each is checked against the manifest and dropped.

use super::{BUILD_SUFFIX, SOURCEMAP, STATE_DIR, SyncOptions, SyncReport, hash_of, load_manifest, plan, read_text, run_sync, summarise, target_session};
use crate::bridge::StudioBridge;
use crate::errors::{Result, ToolError};
use crate::tool::push_notice;
use notify::{RecursiveMode, Watcher};
use parking_lot::Mutex;
use serde_json::{Value, json};
use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::sync::{Arc, LazyLock};
use std::time::Duration;
use tokio::sync::Notify;
use tokio::task::JoinHandle;

#[derive(Clone, Default)]
pub struct WatchState {
    pub dir: String,
    pub studio_id: String,
    pub since: u64,
    pub cycles: u64,
    pub echoes: u64,
    pub last_cycle: Option<(u64, String, u64)>,
    pub last_error: Option<(u64, String)>,
}

#[derive(Default)]
struct Pending {
    files: HashSet<String>,
    dirty: HashSet<String>,
    structural: bool,
    builds_due: bool,
}

struct Watch {
    options: SyncOptions,
    state: Mutex<WatchState>,
    pending: Mutex<Pending>,
    token: Mutex<Option<String>>,
    shape: Mutex<String>,
    wake: Notify,
    tasks: Mutex<Vec<JoinHandle<()>>>,
    watcher: Mutex<Option<notify::RecommendedWatcher>>,
}

static WATCHES: LazyLock<Mutex<HashMap<PathBuf, Arc<Watch>>>> = LazyLock::new(Default::default);

impl Watch {
    fn studio(&self) -> String {
        self.state.lock().studio_id.clone()
    }

    fn record(&self, report: &SyncReport, ms: u64) {
        let mut st = self.state.lock();
        st.cycles += 1;
        if !report.lines.is_empty() || !report.conflicts.is_empty() {
            st.last_cycle = Some((crate::protocol::now_ms(), summarise(report), ms));
        }
        st.last_error = None;
        drop(st);
        for file in &report.new_conflicts {
            push_notice(format!(
                "conflict in {file}: changed on both sides; Studio's version is in {STATE_DIR}/conflicts/{file}. Merge into the file, or run sync with prefer."
            ));
        }
        for (file, reason) in report.failures.iter().take(3) {
            push_notice(format!("{file}: {reason}"));
        }
    }

    async fn fail(&self, bridge: &Arc<StudioBridge>, cause: &ToolError) {
        let message = format!("{}: {}", cause.code, cause.message);
        let repeated = self.state.lock().last_error.as_ref().is_some_and(|e| e.1 == message);
        if !repeated {
            push_notice(format!("stopped syncing for now: {message}. It retries on the next change."));
            let studio = self.studio();
            let _ = bridge
                .call("sync.log", json!({ "lines": [{ "level": "warn", "message": format!("sync watch: {message}") }] }), Some(&studio), Some(5_000.0))
                .await;
        }
        self.state.lock().last_error = Some((crate::protocol::now_ms(), message));
    }

    /// Studio restarted or the place reopened: follow the new session, same place only.
    async fn reattach(&self, bridge: &Arc<StudioBridge>, cause: &ToolError) -> bool {
        if !["UNKNOWN_STUDIO", "NO_STUDIO", "DISCONNECTED"].contains(&cause.code.as_str()) {
            return false;
        }
        let Some(manifest) = load_manifest(&self.options.dir).await else { return false };
        let Some(place) = manifest.place_id else { return false };
        let Ok(view) = bridge.sessions().await else { return false };
        let next = view.list.into_iter().find(|s| {
            !s.identity.context.as_deref().is_some_and(|c| c.starts_with("playtest")) && s.identity.place_id == place
        });
        let Some(next) = next.filter(|n| n.identity.studio_id != self.studio()) else { return false };
        {
            let mut st = self.state.lock();
            st.studio_id = next.identity.studio_id.clone();
            st.last_error = None;
        }
        *self.token.lock() = None;
        self.pending.lock().structural = true;
        push_notice(format!("reconnected to {} after Studio restarted.", next.identity.place_name));
        self.wake.notify_one();
        true
    }

    async fn poll_studio(&self, bridge: &Arc<StudioBridge>, initial: bool) {
        let token = self.token.lock().clone();
        let studio = self.studio();
        match bridge.call("sync.changes", json!({ "token": token }), Some(&studio), Some(5_000.0)).await {
            Ok(changes) => {
                let new_token = changes.get("token").and_then(Value::as_str).map(str::to_string);
                let fresh = new_token != token;
                *self.token.lock() = new_token;
                if initial {
                    return;
                }
                let wake = {
                    let mut p = self.pending.lock();
                    // A new token means the plugin reloaded and forgot what it had seen.
                    if fresh || changes.get("structural") == Some(&Value::Bool(true)) {
                        p.structural = true;
                    }
                    for d in changes.get("dirty").and_then(Value::as_array).into_iter().flatten().filter_map(Value::as_str) {
                        p.dirty.insert(d.to_string());
                    }
                    p.structural || !p.dirty.is_empty()
                };
                if wake {
                    tokio::time::sleep(Duration::from_millis(150)).await;
                    self.wake.notify_one();
                }
            }
            Err(e) => {
                if !self.reattach(bridge, &e).await {
                    self.fail(bridge, &e).await;
                }
            }
        }
    }

    async fn check_shape(&self, bridge: &Arc<StudioBridge>) {
        let studio = self.studio();
        match bridge.call("sync.shape", json!({ "roots": self.options.roots }), Some(&studio), Some(30_000.0)).await {
            Ok(r) => {
                let shape = r.get("shape").and_then(Value::as_str).unwrap_or("").to_string();
                let mut known = self.shape.lock();
                if !known.is_empty() && *known != shape {
                    self.pending.lock().structural = true;
                    self.wake.notify_one();
                }
                *known = shape;
            }
            Err(e) => self.fail(bridge, &e).await,
        }
    }

    /// Whether anything queued is a real change rather than an echo; errs to yes.
    async fn worth_running(&self, bridge: &Arc<StudioBridge>, files: &[String], dirty: &[String], forced: bool) -> Result<bool> {
        if forced {
            return Ok(true);
        }
        let Some(manifest) = load_manifest(&self.options.dir).await else { return Ok(true) };
        for file in files {
            let hash = read_text(&self.options.dir, file).await.ok().map(|t| hash_of(&t));
            let known = manifest.files.get(file).map(|e| e.hash.clone()).or_else(|| manifest.builds.get(file).map(|b| b.hash.clone()));
            if hash != known {
                // A folder event names the folder; only a real file counts.
                let leaf = file.rsplit('/').next().unwrap_or("");
                if hash.is_some() || plan::class_from_file(leaf).is_some() || file.ends_with(BUILD_SUFFIX) {
                    return Ok(true);
                }
            }
        }
        if !dirty.is_empty() {
            let by_path: HashMap<&str, &str> = manifest.files.values().map(|e| (e.path.as_str(), e.revision.as_str())).collect();
            if dirty.iter().any(|p| !by_path.contains_key(p.as_str())) {
                return Ok(true);
            }
            let studio = self.studio();
            let r = bridge.call("sync.revisions", json!({ "paths": dirty }), Some(&studio), Some(10_000.0)).await?;
            let changed = r.get("items").and_then(Value::as_array).into_iter().flatten().any(|item| {
                item.get("missing") == Some(&Value::Bool(true))
                    || item.get("revision").and_then(Value::as_str) != item.get("path").and_then(Value::as_str).and_then(|p| by_path.get(p).copied())
            });
            if changed {
                return Ok(true);
            }
        }
        Ok(false)
    }

    async fn cycle(&self, bridge: &Arc<StudioBridge>) {
        let (files, dirty, forced, builds) = {
            let mut p = self.pending.lock();
            let files: Vec<String> = p.files.drain().collect();
            let dirty: Vec<String> = p.dirty.drain().collect();
            let forced = p.structural || p.builds_due;
            let builds = p.builds_due || files.iter().any(|f| f.ends_with(BUILD_SUFFIX));
            (files, dirty, forced, builds)
        };
        if files.is_empty() && dirty.is_empty() && !forced {
            return;
        }
        match self.worth_running(bridge, &files, &dirty, forced).await {
            Ok(false) => {
                self.state.lock().echoes += 1;
                return;
            }
            Ok(true) => {}
            Err(e) => {
                self.fail(bridge, &e).await;
                return;
            }
        }
        {
            let mut p = self.pending.lock();
            p.structural = false;
            p.builds_due = false;
        }
        let started = std::time::Instant::now();
        let options = SyncOptions { studio_id: Some(self.studio()), quiet: true, builds, ..self.options.clone() };
        match run_sync(bridge, &options).await {
            Ok(report) => self.record(&report, started.elapsed().as_millis() as u64),
            Err(e) => self.fail(bridge, &e).await,
        }
    }

    fn stop(&self, bridge: &Arc<StudioBridge>) {
        *self.watcher.lock() = None;
        for t in self.tasks.lock().drain(..) {
            t.abort();
        }
        let bridge = bridge.clone();
        let studio = self.studio();
        tokio::spawn(async move {
            let _ = bridge.call("sync.stop", json!({}), Some(&studio), Some(5_000.0)).await;
        });
    }
}

fn relative(dir: &Path, path: &Path) -> Option<String> {
    let rel = path.strip_prefix(dir).ok()?;
    Some(rel.components().map(|c| c.as_os_str().to_string_lossy()).collect::<Vec<_>>().join("/"))
}

pub async fn start_watch(bridge: &Arc<StudioBridge>, options: SyncOptions) -> Result<(WatchState, SyncReport, bool)> {
    if let Some(existing) = WATCHES.lock().get(&options.dir).cloned() {
        return Ok((existing.state.lock().clone(), SyncReport::new(&options.dir, ""), true));
    }
    let session = target_session(bridge, options.studio_id.as_deref()).await?;
    let options = SyncOptions { direction: plan::Direction::Both, ..options };
    let watch = Arc::new(Watch {
        state: Mutex::new(WatchState {
            dir: options.dir.display().to_string(),
            studio_id: session.identity.studio_id.clone(),
            since: crate::protocol::now_ms(),
            ..Default::default()
        }),
        options: options.clone(),
        pending: Mutex::new(Pending::default()),
        token: Mutex::new(None),
        shape: Mutex::new(String::new()),
        wake: Notify::new(),
        tasks: Mutex::new(Vec::new()),
        watcher: Mutex::new(None),
    });

    let first = run_sync(bridge, &SyncOptions { studio_id: Some(session.identity.studio_id.clone()), ..options.clone() }).await?;
    watch.record(&first, 0);
    // Take the tracking token now, so the first poll is not mistaken for a reload.
    watch.poll_studio(bridge, true).await;
    tokio::fs::create_dir_all(&options.dir).await?;

    // File events arrive on notify's thread; they only mark work and wake the loop.
    let dir = options.dir.clone();
    let weak = Arc::downgrade(&watch);
    let handle = tokio::runtime::Handle::current();
    let mut watcher = notify::recommended_watcher(move |event: notify::Result<notify::Event>| {
        let Some(w) = weak.upgrade() else { return };
        let Ok(event) = event else { return };
        let mut any = false;
        for path in &event.paths {
            let Some(rel) = relative(&dir, path) else { continue };
            if rel.is_empty() || rel.split('/').any(|p| p.starts_with('.')) || rel.ends_with(".tmp") || rel == SOURCEMAP {
                continue;
            }
            w.pending.lock().files.insert(rel);
            any = true;
        }
        if any {
            let w = w.clone();
            handle.spawn(async move {
                tokio::time::sleep(Duration::from_millis(250)).await;
                w.wake.notify_one();
            });
        }
    })
    .map_err(ToolError::internal)?;
    watcher.watch(&options.dir, RecursiveMode::Recursive).map_err(ToolError::internal)?;
    *watch.watcher.lock() = Some(watcher);

    let mut tasks = Vec::new();
    // The single runner: cycles never overlap, and a wake during one queues the next.
    {
        let (w, b) = (watch.clone(), bridge.clone());
        tasks.push(tokio::spawn(async move {
            loop {
                w.wake.notified().await;
                w.cycle(&b).await;
            }
        }));
    }
    {
        let (w, b) = (watch.clone(), bridge.clone());
        tasks.push(tokio::spawn(async move {
            let mut tick = tokio::time::interval(Duration::from_millis(500));
            tick.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
            loop {
                tick.tick().await;
                w.poll_studio(&b, false).await;
            }
        }));
    }
    {
        let (w, b) = (watch.clone(), bridge.clone());
        tasks.push(tokio::spawn(async move {
            let mut tick = tokio::time::interval(Duration::from_secs(5));
            tick.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
            loop {
                tick.tick().await;
                w.check_shape(&b).await;
            }
        }));
    }
    {
        let w = watch.clone();
        tasks.push(tokio::spawn(async move {
            let mut tick = tokio::time::interval(Duration::from_secs(10));
            tick.tick().await;
            loop {
                tick.tick().await;
                w.pending.lock().builds_due = true;
                w.wake.notify_one();
            }
        }));
    }
    *watch.tasks.lock() = tasks;
    let state = watch.state.lock().clone();
    WATCHES.lock().insert(options.dir.clone(), watch);
    Ok((state, first, false))
}

pub fn stop_watch(bridge: &Arc<StudioBridge>, dir: &Path) -> Option<WatchState> {
    let watch = WATCHES.lock().remove(dir)?;
    watch.stop(bridge);
    let state = watch.state.lock().clone();
    Some(state)
}

pub fn watch_state(dir: &Path) -> Option<WatchState> {
    WATCHES.lock().get(dir).map(|w| w.state.lock().clone())
}

/// Stops every watch; called on shutdown, before the bridge closes.
pub async fn stop_all_watches(bridge: &Arc<StudioBridge>) {
    let all: Vec<Arc<Watch>> = WATCHES.lock().drain().map(|(_, w)| w).collect();
    for w in all {
        *w.watcher.lock() = None;
        for t in w.tasks.lock().drain(..) {
            t.abort();
        }
        let studio = w.studio();
        let _ = tokio::time::timeout(Duration::from_secs(2), bridge.call("sync.stop", json!({}), Some(&studio), Some(2_000.0))).await;
    }
}
