//! sync: scripts mirrored with files on disk.

use crate::errors::Result;
use crate::format::{ToolResult, json, text};
use crate::sync::plan::{Direction, Prefer};
use crate::sync::{self, SyncOptions, SyncReport};
use crate::tool::{Ctx, Tool, define, spec};
use schemars::JsonSchema;
use serde::Deserialize;
use serde_json::{Map, Value, json};
use std::sync::Arc;

const LINE_LIMIT: usize = 60;

#[derive(Deserialize, JsonSchema, PartialEq, Clone, Copy)]
#[serde(rename_all = "lowercase")]
enum Op {
    Status,
    Sync,
    Pull,
    Push,
    Watch,
    Stop,
    Export,
    Build,
}

#[derive(Deserialize, JsonSchema, Clone, Copy)]
#[serde(rename_all = "lowercase")]
enum Side {
    Studio,
    Disk,
}

#[derive(Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
struct Args {
    /// 'status': dry run. 'sync': both ways. 'pull': Studio -> disk. 'push': disk -> Studio. 'watch'/'stop': continuous two-way sync. 'export': instance trees -> build files. 'build': build files -> instance trees.
    op: Op,
    /// Sync folder, relative to the working directory. Default "studio".
    dir: Option<String>,
    /// Studio paths to sync, e.g. ["ServerScriptService", "ReplicatedStorage.Shared"]. Default: every service scripts are authored in. Remembered for the folder once given.
    roots: Option<Vec<String>>,
    /// Settle conflicts in favour of one side instead of reporting them.
    prefer: Option<Side>,
    /// export: instances to write as build files, e.g. ["StarterGui.Shop"].
    paths: Option<Vec<String>>,
    /// build: build files to apply, relative to the folder. Default: those changed since last built.
    files: Option<Vec<String>>,
    /// Allow a run that deletes most of what the folder tracks. Check `status` first.
    confirm_deletes: Option<bool>,
    /// Let a folder synced with one place follow a different place. Almost never what you want.
    rebind: Option<bool>,
    /// Target Studio; omit for the active one.
    studio_id: Option<String>,
}

fn render(report: &SyncReport, heading: &str) -> String {
    let mut out = vec![format!("{heading}: {}  ({} <-> {})", sync::summarise(report), report.place, report.dir)];
    if let Some(step) = &report.undo_step {
        out.push(format!("Studio changes are one undo step, \"{step}\"."));
    }
    if !report.lines.is_empty() {
        out.push(String::new());
        out.extend(report.lines.iter().take(LINE_LIMIT).cloned());
    }
    if report.lines.len() > LINE_LIMIT {
        out.push(format!("… and {} more", report.lines.len() - LINE_LIMIT));
    }
    if !report.conflicts.is_empty() {
        out.push(String::new());
        out.push("Conflicts (nothing was written for these):".into());
        out.extend(report.conflicts.iter().take(LINE_LIMIT).map(|c| format!("  {}: {}", c.file, c.reason)));
        out.push("Settle them by editing one side to match the other, or rerun with prefer: \"studio\" or \"disk\" to let one side win.".into());
    }
    if !report.held.is_empty() {
        out.push(String::new());
        out.push(format!("Held back by the direction ({}):", report.held.len()));
        out.extend(report.held.iter().take(20).map(|h| format!("  {h}")));
    }
    if !report.failures.is_empty() {
        out.push(String::new());
        out.push("Failed:".into());
        out.extend(report.failures.iter().take(LINE_LIMIT).map(|(f, r)| format!("  {f}: {r}")));
    }
    if !report.builds.is_empty() {
        out.push(String::new());
        out.push(if report.dry_run { "Build files that would rebuild:" } else { "Rebuilt from build files:" }.into());
        out.extend(report.builds.iter().map(|b| format!("  {b}")));
    }
    if !report.file_synced.is_empty() {
        out.push(String::new());
        out.push(format!("{} script(s) left alone: Studio's own Script Sync already binds them to files.", report.file_synced.len()));
    }
    out.join("\n")
}

async fn run(ctx: Arc<Ctx>, a: Args) -> Result<ToolResult> {
    let dir = sync::resolve_dir(a.dir.as_deref());
    let base = SyncOptions {
        dir: dir.clone(),
        roots: a.roots.clone(),
        studio_id: a.studio_id.clone(),
        direction: Direction::Both,
        prefer: a.prefer.map(|p| match p {
            Side::Studio => Prefer::Studio,
            Side::Disk => Prefer::Disk,
        }),
        dry_run: false,
        confirm_deletes: a.confirm_deletes == Some(true),
        rebind: a.rebind == Some(true),
        quiet: false,
        builds: true,
    };
    let bridge = &ctx.bridge;
    match a.op {
        Op::Status => {
            let report = sync::run_sync(bridge, &SyncOptions { dry_run: true, ..base }).await?;
            let mut lines = vec![render(&report, "Would sync")];
            if let Some(w) = sync::watch_state(&dir) {
                let mut line = format!(
                    "Watching since {}: {} sync(s), {} echo(es) skipped",
                    crate::tools::iso(w.since),
                    w.cycles,
                    w.echoes
                );
                if let Some((_, summary, ms)) = &w.last_cycle {
                    line.push_str(&format!("; last change: {summary} ({ms}ms)"));
                }
                if let Some((_, message)) = &w.last_error {
                    line.push_str(&format!("; last error: {message}"));
                }
                lines.push(String::new());
                lines.push(line);
            }
            Ok(text(lines.join("\n")))
        }
        Op::Sync | Op::Pull | Op::Push => {
            let (direction, heading) = match a.op {
                Op::Pull => (Direction::Pull, "Pulled"),
                Op::Push => (Direction::Push, "Pushed"),
                _ => (Direction::Both, "Synced"),
            };
            let report = sync::run_sync(bridge, &SyncOptions { direction, ..base }).await?;
            Ok(text(render(&report, heading)))
        }
        Op::Watch => {
            let (state, first, already) = sync::start_watch(bridge, base).await?;
            if already {
                return Ok(text(format!("Already watching {}. op=\"status\" shows how it is going.", state.dir)));
            }
            let head = if first.lines.is_empty() && first.conflicts.is_empty() { "Already in step.".to_string() } else { render(&first, "First sync") };
            Ok(text(format!(
                "{head}\n\nWatching {}: file edits reach Studio within a second, Studio edits reach the files. Conflicts are left alone and listed by op=\"status\". Stop with op=\"stop\".",
                state.dir
            )))
        }
        Op::Stop => Ok(text(match sync::stop_watch(bridge, &dir) {
            Some(state) => format!("Stopped watching {} after {} run(s).", dir.display(), state.cycles),
            None => format!("Nothing was watching {}.", dir.display()),
        })),
        Op::Export => {
            let Some(paths) = a.paths.filter(|p| !p.is_empty()) else {
                return Ok(text("export needs `paths`, e.g. [\"StarterGui.Shop\"]."));
            };
            let written = sync::run_export(bridge, &base, &paths).await?;
            let rows: Vec<Value> = written
                .into_iter()
                .map(|e| {
                    let mut row = Map::new();
                    row.insert("path".into(), json!(e.path));
                    row.insert("file".into(), json!(e.file));
                    row.insert("instances".into(), e.instances);
                    // Scripts are synced as files, not written into the build file.
                    row.insert("scriptsLeftAsFiles".into(), e.scripts);
                    if !e.skipped.is_empty() {
                        row.insert("propertiesNotExported".into(), Value::Array(e.skipped.into_iter().take(30).collect()));
                    }
                    Value::Object(row)
                })
                .collect();
            Ok(json(&Value::Array(rows), Some("Edit the file, then sync op=\"build\" (or any push) rebuilds the tree in one undo step.")))
        }
        Op::Build => {
            let report = sync::run_build(bridge, &SyncOptions { direction: Direction::Push, ..base }, a.files.clone()).await?;
            Ok(text(render(&report, "Built")))
        }
    }
}

pub fn tools() -> Vec<Tool> {
    vec![define(
        spec("sync", "Sync scripts with files on disk"),
        "Mirrors the place's scripts into a folder on disk, so you can work on code with your own file tools -- read a \
         window, search, edit in place, diff -- and then send it back to Studio in one call. Studio stays where the game \
         runs: use playtest, screenshot, console and input to check the result.\n\n\
         Layout mirrors the instance tree, Rojo-style: `ServerScriptService/Main.server.luau` is a Script, \
         `.client.luau` a LocalScript, `.luau` a ModuleScript, and a script with scripts inside is a folder holding \
         `init.server.luau` (or `init.client.luau`, `init.luau`). New files become new scripts, and a file moved or \
         renamed moves the script itself, keeping its identity.\n\n\
         Ops: `status` shows what would change without changing anything. `sync` goes both ways, `pull` only Studio -> \
         disk, `push` only disk -> Studio. `watch` keeps them in step until `stop`: edit files and Studio follows within \
         a second, and edits in Studio land on disk.\n\n\
         Nothing is overwritten blind. The last sync is remembered per file, so a file changed on both sides is a \
         conflict, reported and left alone -- settle it, or pass `prefer`. Deleting a file deletes the script (one \
         Ctrl+Z in Studio); a script deleted in Studio moves its file to `.rbx-sync/trash`. Nothing is deleted on a \
         first sync.\n\n\
         UI and other instance trees: `export` writes one as a build file (e.g. `StarterGui/Shop.build.json`, the same \
         fields `create` takes, only non-default properties). Edit it, then `build` -- or any sync -- rebuilds the tree \
         in one undo step, keeping the scripts inside it. Build files are two-way too: a tree edited in Studio is \
         written back to its file, and edits on both sides are a conflict rather than one silently undoing the other.\n\n\
         Conflicts leave Studio's version in `.rbx-sync/conflicts/`. Merge into the file (or fix Studio) and sync again: \
         whichever side changed since the conflict wins. While `watch` runs, new conflicts and errors are appended to \
         your next tool reply.",
        run,
    )]
}
