//! The decisions behind `sync`, free of I/O: file names, the disk layout, and
//! the three-way plan (manifest = common ancestor, Studio now, disk now).

use regex::Regex;
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, HashMap, HashSet};
use std::sync::LazyLock;

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct StudioNode {
    pub path: String,
    pub name: String,
    pub class_name: String,
    /// Position of the parent in the same list, 1-based; 0 is the DataModel.
    pub parent: usize,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ScanItem {
    pub node: usize,
    pub revision: Option<String>,
    #[serde(default)]
    pub file_synced: bool,
}

#[derive(Debug, Clone, Deserialize, Default)]
pub struct ScanResult {
    #[serde(default)]
    pub nodes: Vec<StudioNode>,
    #[serde(default)]
    pub items: Vec<ScanItem>,
    #[serde(default)]
    pub roots: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct ManifestEntry {
    pub path: String,
    pub class_name: String,
    pub revision: String,
    pub hash: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BuildEntry {
    pub path: String,
    pub parent: String,
    pub hash: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub studio: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ConflictMemory {
    pub studio: String,
    pub disk: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Manifest {
    pub version: u32,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub place_id: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub place_name: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub roots: Option<Vec<String>>,
    #[serde(default)]
    pub files: BTreeMap<String, ManifestEntry>,
    #[serde(default)]
    pub builds: BTreeMap<String, BuildEntry>,
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub conflicts: BTreeMap<String, ConflictMemory>,
}

impl Default for Manifest {
    fn default() -> Self {
        Self { version: 1, place_id: None, place_name: None, roots: None, files: BTreeMap::new(), builds: BTreeMap::new(), conflicts: BTreeMap::new() }
    }
}

// --- names -----------------------------------------------------------------------

pub fn extension_of(class: &str) -> &'static str {
    match class {
        "Script" => ".server.luau",
        "LocalScript" => ".client.luau",
        _ => ".luau",
    }
}

pub struct FileClass {
    pub stem: String,
    pub class_name: &'static str,
    pub init: bool,
}

static FILE_RE: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"(?i)^(.*?)(\.server|\.client)?\.luau?$").unwrap());
static RESERVED: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"(?i)^(con|prn|aux|nul|com[1-9]|lpt[1-9])(\..*)?$").unwrap());
static SUFFIX: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"~\d+$").unwrap());

/// What a file name says about the script in it; `.lua` is read, never written.
pub fn class_from_file(name: &str) -> Option<FileClass> {
    let caps = FILE_RE.captures(name)?;
    let stem = caps.get(1)?.as_str().to_string();
    let class_name = match caps.get(2).map(|m| m.as_str().to_lowercase()).as_deref() {
        Some(".server") => "Script",
        Some(".client") => "LocalScript",
        _ => "ModuleScript",
    };
    let init = stem.eq_ignore_ascii_case("init");
    Some(FileClass { stem, class_name, init })
}

fn escape(c: char) -> String {
    format!("%{:02X}", c as u32)
}

/// An instance name as a file name every OS accepts, decoding back exactly.
pub fn encode_name(name: &str, script: bool) -> String {
    if name.is_empty() {
        return "%00".into();
    }
    let mut out = String::with_capacity(name.len());
    for c in name.chars() {
        let code = c as u32;
        if code < 0x20 || code == 0x7f || "<>:\"/\\|?*%".contains(c) || (script && c == '.') {
            out.push_str(&escape(c));
        } else {
            out.push(c);
        }
    }
    if out.chars().all(|c| c == '.') {
        out = out.replace('.', "%2E");
    }
    if let Some(last) = out.chars().last().filter(|c| *c == '.' || *c == ' ') {
        out.pop();
        out.push_str(&escape(last));
    }
    if RESERVED.is_match(&out) || (script && out.eq_ignore_ascii_case("init")) {
        let first = out.chars().next().unwrap();
        out = format!("{}{}", escape(first), &out[first.len_utf8()..]);
    }
    out
}

pub fn decode_name(encoded: &str) -> String {
    if encoded == "%00" {
        return String::new();
    }
    let bytes = encoded.as_bytes();
    let mut out = String::with_capacity(encoded.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' && i + 2 < bytes.len()
            && let Ok(v) = u8::from_str_radix(&encoded[i + 1..i + 3], 16) {
                out.push(v as char);
                i += 3;
                continue;
            }
        let c = encoded[i..].chars().next().unwrap();
        out.push(c);
        i += c.len_utf8();
    }
    out
}

fn strip_suffix(encoded: &str) -> String {
    SUFFIX.replace(encoded, "").into_owned()
}

// --- layout ------------------------------------------------------------------------

#[derive(Default, Debug)]
pub struct Layout {
    pub file_of: HashMap<String, String>,
    pub path_of_dir: HashMap<String, String>,
    pub dir_of: HashMap<String, String>,
    pub scripts: HashMap<String, (String, Option<String>)>,
    pub file_synced: Vec<String>,
}

/// Where every scanned script goes on disk; deterministic, `~2` on collisions.
pub fn layout(scan: &ScanResult) -> Layout {
    let mut children: HashMap<usize, Vec<usize>> = HashMap::new();
    for (i, node) in scan.nodes.iter().enumerate() {
        children.entry(node.parent).or_default().push(i + 1);
    }
    let script_nodes: HashMap<usize, &ScanItem> = scan.items.iter().map(|i| (i.node, i)).collect();
    let mut result = Layout::default();

    struct Kid<'a> {
        index: usize,
        node: &'a StudioNode,
        as_dir: bool,
        base: String,
        ext: &'static str,
    }

    fn visit(
        parent: usize,
        parent_dir: &str,
        scan: &ScanResult,
        children: &HashMap<usize, Vec<usize>>,
        script_nodes: &HashMap<usize, &ScanItem>,
        out: &mut Layout,
    ) {
        let kids: Vec<Kid> = children
            .get(&parent)
            .map(|v| v.as_slice())
            .unwrap_or(&[])
            .iter()
            .map(|&index| {
                let node = &scan.nodes[index - 1];
                let is_script = script_nodes.contains_key(&index);
                let has_kids = children.get(&index).is_some_and(|c| !c.is_empty());
                let as_dir = !is_script || has_kids;
                Kid { index, node, as_dir, base: encode_name(&node.name, !as_dir), ext: if as_dir { "" } else { extension_of(&node.class_name) } }
            })
            .collect();
        let mut order: Vec<String> = Vec::new();
        let mut groups: HashMap<String, Vec<&Kid>> = HashMap::new();
        for kid in &kids {
            let key = format!("{}:{}{}", if kid.as_dir { "d" } else { "f" }, kid.base, kid.ext).to_lowercase();
            if !groups.contains_key(&key) {
                order.push(key.clone());
            }
            groups.entry(key).or_default().push(kid);
        }
        for key in order {
            let mut group = groups.remove(&key).unwrap();
            group.sort_by(|a, b| a.node.path.cmp(&b.node.path));
            for (position, kid) in group.into_iter().enumerate() {
                let stem = if position == 0 { kid.base.clone() } else { format!("{}~{}", kid.base, position + 1) };
                let entry = if parent_dir.is_empty() { format!("{stem}{}", kid.ext) } else { format!("{parent_dir}/{stem}{}", kid.ext) };
                if kid.as_dir {
                    out.path_of_dir.insert(entry.clone(), kid.node.path.clone());
                    out.dir_of.insert(kid.node.path.clone(), entry.clone());
                }
                if let Some(script) = script_nodes.get(&kid.index) {
                    if script.file_synced {
                        out.file_synced.push(kid.node.path.clone());
                    } else {
                        out.scripts.insert(kid.node.path.clone(), (kid.node.class_name.clone(), script.revision.clone()));
                        let file = if kid.as_dir { format!("{entry}/init{}", extension_of(&kid.node.class_name)) } else { entry.clone() };
                        out.file_of.insert(kid.node.path.clone(), file);
                    }
                }
                if kid.as_dir {
                    visit(kid.index, &entry, scan, children, script_nodes, out);
                }
            }
        }
    }
    visit(0, "", scan, &children, &script_nodes, &mut result);
    result
}

#[derive(Debug, Clone)]
pub struct Placement {
    pub parent_path: Option<String>,
    pub parents: Vec<(String, String)>,
    pub name: String,
    pub class_name: &'static str,
}

/// A script's intended place in Studio, read from its file path.
pub fn placement_of(file: &str, known: &Layout, init_class_of: &dyn Fn(&str) -> Option<&'static str>) -> Result<Placement, String> {
    let mut parts: Vec<&str> = file.split('/').collect();
    let file_name = parts.pop().unwrap_or("");
    let parsed = class_from_file(file_name).ok_or("not a .luau file")?;
    if parts.is_empty() {
        return Err("scripts go inside a service folder, e.g. ServerScriptService/".into());
    }
    let (name, dirs): (String, Vec<&str>) = if parsed.init {
        let name = decode_name(&strip_suffix(parts[parts.len() - 1]));
        let dirs = parts[..parts.len() - 1].to_vec();
        if dirs.is_empty() {
            return Err("a service folder cannot hold an init file".into());
        }
        let joined = parts.join("/");
        if let Some(path) = known.path_of_dir.get(&joined)
            && !known.file_of.contains_key(path) {
                return Err("that folder is a non-script instance in Studio; an init file cannot turn it into a script".into());
            }
        (name, dirs)
    } else {
        (decode_name(&parsed.stem), parts.clone())
    };
    let mut depth = dirs.len();
    while depth > 0 && !known.path_of_dir.contains_key(&dirs[..depth].join("/")) {
        depth -= 1;
    }
    let parent_path = (depth > 0).then(|| known.path_of_dir[&dirs[..depth].join("/")].clone());
    let parents = dirs[depth..]
        .iter()
        .enumerate()
        .map(|(offset, segment)| {
            let dir = dirs[..depth + offset + 1].join("/");
            (decode_name(&strip_suffix(segment)), init_class_of(&dir).unwrap_or("Folder").to_string())
        })
        .collect();
    Ok(Placement { parent_path, parents, name, class_name: parsed.class_name })
}

// --- plan ---------------------------------------------------------------------------

#[derive(Debug, Clone, PartialEq)]
pub enum Action {
    Push { file: String, path: String, revision: String, class_name: String },
    Pull { file: String, path: String, revision: String, class_name: String },
    Merge { file: String, path: String, revision: String, class_name: String },
    Adopt { file: String, path: String, revision: String, class_name: String },
    CreateStudio { file: String },
    CreateDisk { file: String, path: String, revision: String, class_name: String },
    DeleteStudio { file: String, path: String, revision: String },
    DeleteDisk { file: String, path: String },
    MoveStudio { file: String, from_file: String, path: String, revision: String, hash: String, class_name: String },
    MoveDisk { file: String, from_file: String, path: String, revision: String, hash: String, class_name: String },
    Forget { file: String },
    Conflict { file: String, path: Option<String>, reason: String },
}

impl Action {
    pub fn file(&self) -> &str {
        match self {
            Action::Push { file, .. }
            | Action::Pull { file, .. }
            | Action::Merge { file, .. }
            | Action::Adopt { file, .. }
            | Action::CreateStudio { file }
            | Action::CreateDisk { file, .. }
            | Action::DeleteStudio { file, .. }
            | Action::DeleteDisk { file, .. }
            | Action::MoveStudio { file, .. }
            | Action::MoveDisk { file, .. }
            | Action::Forget { file }
            | Action::Conflict { file, .. } => file,
        }
    }

    fn studio_side(&self) -> bool {
        matches!(self, Action::Push { .. } | Action::CreateStudio { .. } | Action::DeleteStudio { .. } | Action::MoveStudio { .. })
    }

    fn disk_side(&self) -> bool {
        matches!(self, Action::Pull { .. } | Action::CreateDisk { .. } | Action::DeleteDisk { .. } | Action::MoveDisk { .. })
    }

    pub fn kind(&self) -> &'static str {
        match self {
            Action::Push { .. } => "push",
            Action::Pull { .. } => "pull",
            Action::Merge { .. } => "merge",
            Action::Adopt { .. } => "adopt",
            Action::CreateStudio { .. } => "create-studio",
            Action::CreateDisk { .. } => "create-disk",
            Action::DeleteStudio { .. } => "delete-studio",
            Action::DeleteDisk { .. } => "delete-disk",
            Action::MoveStudio { .. } => "move-studio",
            Action::MoveDisk { .. } => "move-disk",
            Action::Forget { .. } => "forget",
            Action::Conflict { .. } => "conflict",
        }
    }

    /// One report line, e.g. "push          ServerScriptService/Main.server.luau".
    pub fn describe(&self) -> String {
        match self {
            Action::MoveDisk { from_file, file, .. } | Action::MoveStudio { from_file, file, .. } => {
                format!("{:<13} {from_file} -> {file}", self.kind())
            }
            Action::Conflict { file, reason, .. } => format!("conflict      {file}: {reason}"),
            other => format!("{:<13} {}", other.kind(), other.file()),
        }
    }
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Direction {
    Both,
    Pull,
    Push,
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Prefer {
    Studio,
    Disk,
}

pub struct PlanInput<'a> {
    pub manifest: &'a Manifest,
    pub studio: &'a Layout,
    pub disk: &'a HashMap<String, String>,
    pub in_scope: &'a dyn Fn(&str) -> bool,
    pub direction: Direction,
    pub prefer: Option<Prefer>,
}

#[derive(Default, Debug)]
pub struct Plan {
    pub actions: Vec<Action>,
    pub held: Vec<Action>,
}

/// Decides what each file needs. Deletions only ever follow a record, and a
/// rename is recognised by content so a moved script stays the same instance.
pub fn plan(input: PlanInput) -> Plan {
    let PlanInput { manifest, studio, disk, in_scope, direction, prefer } = input;
    let mut out = Plan::default();
    let mut emit = |a: Action| {
        let blocked = (direction == Direction::Pull && a.studio_side()) || (direction == Direction::Push && a.disk_side());
        if blocked { out.held.push(a) } else { out.actions.push(a) }
    };

    let entries: Vec<(String, ManifestEntry)> =
        manifest.files.iter().filter(|(_, e)| in_scope(&e.path)).map(|(f, e)| (f.clone(), e.clone())).collect();
    let by_path: HashMap<&str, &(String, ManifestEntry)> = entries.iter().map(|e| (e.1.path.as_str(), e)).collect();
    let mut claimed: HashSet<String> = entries.iter().map(|e| e.0.clone()).collect();

    let mut studio_new: Vec<String> = Vec::new();
    let mut studio_gone: Vec<&(String, ManifestEntry)> = Vec::new();
    let mut disk_gone: Vec<&(String, ManifestEntry)> = Vec::new();

    let mut scripts: Vec<(&String, &(String, Option<String>))> = studio.scripts.iter().collect();
    scripts.sort_by(|a, b| a.0.cmp(b.0));
    for (path, (class, revision)) in scripts {
        let Some(entry) = by_path.get(path.as_str()) else {
            studio_new.push(path.clone());
            continue;
        };
        let (entry_file, e) = (&entry.0, &entry.1);
        let target = &studio.file_of[path];
        let revision = revision.clone().unwrap_or_default();
        let studio_changed = revision != e.revision;
        let mut file = entry_file.clone();
        let hash = disk.get(entry_file);

        if &file != target && hash.is_some() {
            if disk.contains_key(target) && !claimed.contains(target) {
                emit(Action::Conflict {
                    file: target.clone(),
                    path: Some(path.clone()),
                    reason: format!("{path} should now be at {target}, but a different file is already there"),
                });
                continue;
            }
            emit(Action::MoveDisk {
                file: target.clone(),
                from_file: file.clone(),
                path: path.clone(),
                revision: e.revision.clone(),
                hash: e.hash.clone(),
                class_name: e.class_name.clone(),
            });
            claimed.insert(target.clone());
            file = target.clone();
        }

        let Some(hash) = hash else {
            if !studio_changed {
                disk_gone.push(entry);
            } else if prefer == Some(Prefer::Studio) {
                emit(Action::Pull { file: target.clone(), path: path.clone(), revision, class_name: class.clone() });
            } else if prefer == Some(Prefer::Disk) {
                emit(Action::DeleteStudio { file: entry_file.clone(), path: path.clone(), revision });
            } else {
                emit(Action::Conflict {
                    file: entry_file.clone(),
                    path: Some(path.clone()),
                    reason: "deleted on disk, but changed in Studio since the last sync".into(),
                });
            }
            continue;
        };
        let disk_changed = hash != &e.hash;
        if studio_changed && disk_changed {
            emit(Action::Merge { file, path: path.clone(), revision, class_name: class.clone() });
        } else if disk_changed {
            emit(Action::Push { file, path: path.clone(), revision: e.revision.clone(), class_name: e.class_name.clone() });
        } else if studio_changed {
            emit(Action::Pull { file, path: path.clone(), revision, class_name: class.clone() });
        }
    }

    for entry in &entries {
        let (file, e) = (&entry.0, &entry.1);
        if studio.scripts.contains_key(&e.path) {
            continue;
        }
        match disk.get(file) {
            None => emit(Action::Forget { file: file.clone() }),
            Some(h) if h == &e.hash => studio_gone.push(entry),
            Some(_) if prefer == Some(Prefer::Disk) => emit(Action::CreateStudio { file: file.clone() }),
            Some(_) if prefer == Some(Prefer::Studio) => emit(Action::DeleteDisk { file: file.clone(), path: e.path.clone() }),
            Some(_) => emit(Action::Conflict {
                file: file.clone(),
                path: Some(e.path.clone()),
                reason: "deleted in Studio, but edited on disk since the last sync".into(),
            }),
        }
    }

    let mut disk_new: Vec<String> = disk.keys().filter(|f| !claimed.contains(*f)).cloned().collect();
    disk_new.sort();
    let mut disk_new_set: HashSet<String> = disk_new.iter().cloned().collect();

    // Renamed or moved in Studio: the same text at a new path.
    for entry in studio_gone {
        let (file, e) = (&entry.0, &entry.1);
        let found = studio_new.iter().position(|p| {
            let (class, rev) = &studio.scripts[p];
            rev.as_deref().unwrap_or("") == e.revision && class == &e.class_name
        });
        let Some(index) = found else {
            emit(Action::DeleteDisk { file: file.clone(), path: e.path.clone() });
            continue;
        };
        let matched = studio_new.remove(index);
        let target = studio.file_of[&matched].clone();
        if disk_new_set.contains(&target) {
            emit(Action::Conflict {
                file: target,
                path: Some(matched.clone()),
                reason: format!("{matched} was moved in Studio, but a different file already exists at its new place"),
            });
            continue;
        }
        emit(Action::MoveDisk {
            file: target,
            from_file: file.clone(),
            path: matched,
            revision: e.revision.clone(),
            hash: e.hash.clone(),
            class_name: e.class_name.clone(),
        });
    }

    // Renamed or moved on disk: the same text in a new file.
    for entry in disk_gone {
        let (file, e) = (&entry.0, &entry.1);
        let matched = disk_new.iter().find(|f| {
            disk_new_set.contains(*f)
                && disk.get(*f) == Some(&e.hash)
                && class_from_file(f.rsplit('/').next().unwrap_or("")).is_some_and(|c| c.class_name == e.class_name)
        });
        let Some(matched) = matched.cloned() else {
            emit(Action::DeleteStudio { file: file.clone(), path: e.path.clone(), revision: e.revision.clone() });
            continue;
        };
        disk_new_set.remove(&matched);
        emit(Action::MoveStudio {
            file: matched,
            from_file: file.clone(),
            path: e.path.clone(),
            revision: e.revision.clone(),
            hash: e.hash.clone(),
            class_name: e.class_name.clone(),
        });
    }

    studio_new.sort();
    for path in studio_new {
        let target = studio.file_of[&path].clone();
        let (class, rev) = &studio.scripts[&path];
        let revision = rev.clone().unwrap_or_default();
        if disk_new_set.remove(&target) {
            emit(Action::Adopt { file: target, path, revision, class_name: class.clone() });
        } else {
            emit(Action::CreateDisk { file: target, path, revision, class_name: class.clone() });
        }
    }
    for file in disk_new {
        if disk_new_set.contains(&file) {
            emit(Action::CreateStudio { file });
        }
    }
    out
}

/// Text as compared and hashed: no BOM, `\n` line ends.
pub fn normalise(text: &str) -> String {
    let t = text.strip_prefix('\u{feff}').unwrap_or(text);
    t.replace("\r\n", "\n").replace('\r', "\n")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn names_round_trip() {
        for name in ["Config.server", "init", "CON", "a/b", "trail.", "%x", "", "..", "Shop"] {
            let enc = encode_name(name, true);
            assert_eq!(decode_name(&enc), name, "{name} -> {enc}");
        }
        assert_eq!(encode_name("init", true), "%69nit");
    }

    #[test]
    fn classifies_files() {
        assert_eq!(class_from_file("Main.server.luau").unwrap().class_name, "Script");
        assert_eq!(class_from_file("ui.client.lua").unwrap().class_name, "LocalScript");
        assert!(class_from_file("init.luau").unwrap().init);
        assert!(class_from_file("readme.md").is_none());
    }

    fn scan() -> ScanResult {
        serde_json::from_value(serde_json::json!({
            "nodes": [
                { "path": "ServerScriptService", "name": "ServerScriptService", "className": "ServerScriptService", "parent": 0 },
                { "path": "ServerScriptService.Main", "name": "Main", "className": "Script", "parent": 1 },
                { "path": "ServerScriptService.Main.Util", "name": "Util", "className": "ModuleScript", "parent": 2 }
            ],
            "items": [ { "node": 2, "revision": "r1" }, { "node": 3, "revision": "r2" } ],
            "roots": ["ServerScriptService"]
        }))
        .unwrap()
    }

    #[test]
    fn lays_out_scripts_with_children_as_folders() {
        let l = layout(&scan());
        assert_eq!(l.file_of["ServerScriptService.Main"], "ServerScriptService/Main/init.server.luau");
        assert_eq!(l.file_of["ServerScriptService.Main.Util"], "ServerScriptService/Main/Util.luau");
    }

    #[test]
    fn first_sync_creates_files_and_never_deletes() {
        let l = layout(&scan());
        let m = Manifest::default();
        let disk = HashMap::new();
        let p = plan(PlanInput { manifest: &m, studio: &l, disk: &disk, in_scope: &|_| true, direction: Direction::Both, prefer: None });
        assert_eq!(p.actions.len(), 2);
        assert!(p.actions.iter().all(|a| matches!(a, Action::CreateDisk { .. })));
    }

    #[test]
    fn both_changed_is_merge() {
        let l = layout(&scan());
        let mut m = Manifest::default();
        m.files.insert(
            "ServerScriptService/Main/Util.luau".into(),
            ManifestEntry { path: "ServerScriptService.Main.Util".into(), class_name: "ModuleScript".into(), revision: "old".into(), hash: "h0".into() },
        );
        let mut disk = HashMap::new();
        disk.insert("ServerScriptService/Main/Util.luau".to_string(), "h1".to_string());
        let p = plan(PlanInput { manifest: &m, studio: &l, disk: &disk, in_scope: &|_| true, direction: Direction::Both, prefer: None });
        assert!(p.actions.iter().any(|a| matches!(a, Action::Merge { .. })));
    }
}
