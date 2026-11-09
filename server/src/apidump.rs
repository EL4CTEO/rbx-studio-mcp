//! Live Roblox API reflection from the official API dump.
//!
//! Downloaded once a day and cached on disk as a compact index (only the
//! fields used here), so property enumeration, validation and "did you mean"
//! track the engine the user actually runs. No dump is a supported state:
//! callers fall back to what the plugin reports.

use parking_lot::{Mutex, RwLock};
use serde::{Deserialize, Serialize};
use std::collections::{HashMap, HashSet};
use std::path::PathBuf;
use std::sync::{Arc, LazyLock};
use std::time::Duration;
use tokio::sync::Mutex as AsyncMutex;

const DUMP_URL: &str = "https://raw.githubusercontent.com/MaximumADHD/Roblox-Client-Tracker/roblox/API-Dump.json";
const CACHE_TTL_MS: u64 = 24 * 60 * 60 * 1000;
const RETRY_AFTER_MS: u64 = 60_000;

// --- the raw dump, read once and reduced -------------------------------------

#[derive(Deserialize)]
#[serde(rename_all = "PascalCase")]
struct RawDump {
    classes: Vec<RawClass>,
}

#[derive(Deserialize)]
#[serde(rename_all = "PascalCase")]
struct RawClass {
    name: String,
    #[serde(default)]
    superclass: String,
    #[serde(default)]
    members: Vec<RawMember>,
}

#[derive(Deserialize)]
#[serde(rename_all = "PascalCase")]
struct RawMember {
    member_type: String,
    name: String,
    value_type: Option<RawType>,
    security: Option<RawSecurity>,
    #[serde(default)]
    tags: Vec<serde_json::Value>,
}

#[derive(Deserialize)]
#[serde(rename_all = "PascalCase")]
struct RawType {
    name: String,
    #[serde(default)]
    category: String,
}

#[derive(Deserialize)]
#[serde(untagged)]
enum RawSecurity {
    Both(String),
    Split {
        #[serde(rename = "Read")]
        read: String,
        #[serde(rename = "Write")]
        write: String,
    },
}

// --- the compact index -------------------------------------------------------

const NOT_SCRIPTABLE: u8 = 1;
const READ_ONLY: u8 = 2;
const DEPRECATED: u8 = 4;
const HIDDEN: u8 = 8;

#[derive(Serialize, Deserialize, Clone)]
struct Prop {
    n: String,
    t: String,
    c: String,
    r: String,
    w: String,
    f: u8,
}

#[derive(Serialize, Deserialize)]
struct Class {
    s: String,
    p: Vec<Prop>,
}

#[derive(Serialize, Deserialize)]
struct CacheFile {
    #[serde(rename = "fetchedAt")]
    fetched_at: u64,
    classes: HashMap<String, Class>,
}

#[derive(Clone, Debug)]
pub struct PropertyInfo {
    pub name: String,
    pub value_type: String,
    pub category: String,
    pub declared_by: String,
    pub read_only: bool,
    pub deprecated: bool,
}

#[derive(Clone, Debug)]
pub struct PropertyRestriction {
    pub name: String,
    #[allow(dead_code)] // part of the restriction's identity, kept for diagnostics
    pub declared_by: String,
    pub value_type: String,
    pub capability: String,
    /// "read", "write" or "read or write".
    pub blocked: &'static str,
    pub not_scriptable: bool,
    pub writable: bool,
}

pub struct Index {
    classes: HashMap<String, Class>,
    properties: Mutex<HashMap<String, Arc<Vec<PropertyInfo>>>>,
    restrictions: Mutex<HashMap<String, Arc<HashMap<String, PropertyRestriction>>>>,
}

impl Index {
    fn new(classes: HashMap<String, Class>) -> Self {
        Self { classes, properties: Default::default(), restrictions: Default::default() }
    }

    /// Walks the inheritance chain, most-derived first, each name once.
    fn chain(&self, class: &str) -> impl Iterator<Item = (&str, &Prop)> {
        let mut out = Vec::new();
        let mut seen = HashSet::new();
        let mut current = self.classes.get_key_value(class);
        let mut guard = 0;
        while let Some((name, c)) = current {
            for p in &c.p {
                if seen.insert(p.n.as_str()) {
                    out.push((name.as_str(), p));
                }
            }
            guard += 1;
            current = if c.s.is_empty() || guard > 64 { None } else { self.classes.get_key_value(&c.s) };
        }
        out.into_iter()
    }
}

fn reachable(security: &str) -> bool {
    security == "None" || security == "PluginSecurity"
}

fn reduce(raw: RawDump) -> HashMap<String, Class> {
    raw.classes
        .into_iter()
        .map(|c| {
            let props = c
                .members
                .into_iter()
                .filter(|m| m.member_type == "Property")
                .map(|m| {
                    let (r, w) = match m.security {
                        Some(RawSecurity::Both(s)) => (s.clone(), s),
                        Some(RawSecurity::Split { read, write }) => (read, write),
                        None => ("None".into(), "None".into()),
                    };
                    let mut f = 0;
                    for tag in m.tags.iter().filter_map(|t| t.as_str()) {
                        f |= match tag {
                            "NotScriptable" => NOT_SCRIPTABLE,
                            "ReadOnly" => READ_ONLY,
                            "Deprecated" => DEPRECATED,
                            "Hidden" => HIDDEN,
                            _ => 0,
                        };
                    }
                    let (t, cat) = m.value_type.map(|v| (v.name, v.category)).unwrap_or(("unknown".into(), "unknown".into()));
                    Prop { n: m.name, t, c: cat, r, w, f }
                })
                .collect();
            (c.name, Class { s: c.superclass, p: props })
        })
        .collect()
}

// --- loading -----------------------------------------------------------------------

struct Loader {
    index: RwLock<Option<Arc<Index>>>,
    refresh_at: Mutex<u64>,
    retry_after: Mutex<u64>,
    load: AsyncMutex<()>,
}

static LOADER: LazyLock<Loader> = LazyLock::new(|| Loader {
    index: RwLock::new(None),
    refresh_at: Mutex::new(0),
    retry_after: Mutex::new(0),
    load: AsyncMutex::new(()),
});

fn cache_path() -> PathBuf {
    std::env::temp_dir().join("roblox-studio-mcp").join("api-index.v2.json")
}

fn now() -> u64 {
    crate::protocol::now_ms()
}

async fn read_cache() -> Option<(HashMap<String, Class>, u64)> {
    let path = cache_path();
    let parsed = tokio::task::spawn_blocking(move || {
        let bytes = std::fs::read(path).ok()?;
        serde_json::from_slice::<CacheFile>(&bytes).ok()
    })
    .await
    .ok()??;
    (!parsed.classes.is_empty()).then_some((parsed.classes, parsed.fetched_at))
}

async fn download() -> Option<HashMap<String, Class>> {
    let response = reqwest::Client::new().get(DUMP_URL).timeout(Duration::from_secs(15)).send().await.ok()?;
    if !response.status().is_success() {
        return None;
    }
    let bytes = response.bytes().await.ok()?;
    tokio::task::spawn_blocking(move || {
        let raw: RawDump = serde_json::from_slice(&bytes).ok()?;
        let classes = reduce(raw);
        // Written beside the real file and renamed over it: processes share it.
        let path = cache_path();
        let staging = path.with_extension(format!("{}.tmp", std::process::id()));
        let file = CacheFile { fetched_at: now(), classes };
        let written = std::fs::create_dir_all(path.parent()?)
            .and_then(|_| std::fs::write(&staging, serde_json::to_vec(&file).unwrap_or_default()))
            .and_then(|_| std::fs::rename(&staging, &path));
        if written.is_err() {
            let _ = std::fs::remove_file(&staging);
        }
        Some(file.classes)
    })
    .await
    .ok()?
}

fn install(classes: HashMap<String, Class>, fetched_at: u64) -> Arc<Index> {
    let index = Arc::new(Index::new(classes));
    *LOADER.index.write() = Some(index.clone());
    *LOADER.refresh_at.lock() = fetched_at + CACHE_TTL_MS;
    index
}

/// Swaps a newer dump in behind the calls already being served.
fn refresh_in_background() {
    tokio::spawn(async {
        let Ok(_guard) = LOADER.load.try_lock() else { return };
        match download().await {
            Some(classes) => {
                install(classes, now());
            }
            None => *LOADER.refresh_at.lock() = now() + RETRY_AFTER_MS,
        }
    });
}

/// The index, or None when no dump can be had (offline). Never blocks on a refresh.
pub async fn index() -> Option<Arc<Index>> {
    let refresh_at = *LOADER.refresh_at.lock();
    if let Some(index) = LOADER.index.read().clone() {
        if refresh_at != 0 && now() >= refresh_at {
            *LOADER.refresh_at.lock() = now() + RETRY_AFTER_MS;
            refresh_in_background();
        }
        return Some(index);
    }
    if now() < *LOADER.retry_after.lock() {
        return None;
    }
    let _guard = LOADER.load.lock().await;
    if let Some(index) = LOADER.index.read().clone() {
        return Some(index);
    }
    if let Some((classes, fetched_at)) = read_cache().await {
        let stale = now().saturating_sub(fetched_at) > CACHE_TTL_MS;
        let index = install(classes, fetched_at);
        if stale {
            *LOADER.refresh_at.lock() = now() + RETRY_AFTER_MS;
            drop(_guard);
            refresh_in_background();
        }
        return Some(index);
    }
    match download().await {
        Some(classes) => Some(install(classes, now())),
        None => {
            // Offline is not forever: try again after a minute.
            *LOADER.retry_after.lock() = now() + RETRY_AFTER_MS;
            None
        }
    }
}

pub async fn preload() {
    let _ = index().await;
}

// --- queries -------------------------------------------------------------------------

fn restriction_of(p: &Prop, declared_by: &str) -> Option<PropertyRestriction> {
    let not_scriptable = p.f & NOT_SCRIPTABLE != 0;
    let read_blocked = !reachable(&p.r);
    let write_blocked = !reachable(&p.w);
    if !not_scriptable && !read_blocked && !write_blocked {
        return None;
    }
    let capability = if write_blocked { &p.w } else if read_blocked { &p.r } else { "" };
    Some(PropertyRestriction {
        name: p.n.clone(),
        declared_by: declared_by.into(),
        value_type: p.t.clone(),
        capability: capability.strip_suffix("Security").unwrap_or(capability).to_string(),
        blocked: if not_scriptable || (read_blocked && write_blocked) {
            "read or write"
        } else if read_blocked {
            "read"
        } else {
            "write"
        },
        not_scriptable,
        writable: !not_scriptable && !write_blocked,
    })
}

/// Every property of a class plugin identity cannot fully use, by name.
pub async fn restrictions_of(class: &str) -> Arc<HashMap<String, PropertyRestriction>> {
    let Some(index) = index().await else { return Arc::default() };
    if let Some(hit) = index.restrictions.lock().get(class) {
        return hit.clone();
    }
    let found: HashMap<String, PropertyRestriction> =
        index.chain(class).filter_map(|(owner, p)| restriction_of(p, owner).map(|r| (p.n.clone(), r))).collect();
    let found = Arc::new(found);
    index.restrictions.lock().insert(class.into(), found.clone());
    found
}

pub fn describe_restriction(r: &PropertyRestriction) -> String {
    if r.not_scriptable {
        return "marked NotScriptable, so no script or plugin can set it".into();
    }
    format!(
        "restricted to {} identity, so no plugin can {}",
        r.capability,
        if r.blocked == "read" { "read it" } else { "set it" }
    )
}

/// Every readable property, most-derived class first.
pub async fn properties_of(class: &str) -> Arc<Vec<PropertyInfo>> {
    let Some(index) = index().await else { return Arc::default() };
    if let Some(hit) = index.properties.lock().get(class) {
        return hit.clone();
    }
    let list: Vec<PropertyInfo> = index
        .chain(class)
        .filter(|(_, p)| reachable(&p.r) && p.f & NOT_SCRIPTABLE == 0)
        .map(|(owner, p)| PropertyInfo {
            name: p.n.clone(),
            value_type: p.t.clone(),
            category: p.c.clone(),
            declared_by: owner.into(),
            read_only: p.f & READ_ONLY != 0,
            deprecated: p.f & DEPRECATED != 0,
        })
        .collect();
    let list = Arc::new(list);
    index.properties.lock().insert(class.into(), list.clone());
    list
}

const STRUCTURAL: [&str; 4] = ["Name", "Parent", "ClassName", "Archivable"];
const DERIVED: [&str; 17] = [
    "BrickColor", "Rotation", "Axis", "SecondaryAxis", "WorldAxis", "WorldSecondaryAxis", "WorldCFrame",
    "AssemblyLinearVelocity", "AssemblyAngularVelocity", "Jump", "Sit", "PlatformStand", "TargetPoint",
    "WalkToPart", "WalkToPoint", "ColorMap", "ColorMapContent",
];

/// Properties worth writing into a build file.
pub async fn buildable_properties(class: &str) -> Vec<PropertyInfo> {
    let Some(index) = index().await else { return vec![] };
    index
        .chain(class)
        .filter(|(_, p)| {
            !STRUCTURAL.contains(&p.n.as_str())
                && reachable(&p.r)
                && reachable(&p.w)
                && p.f & (NOT_SCRIPTABLE | READ_ONLY | DEPRECATED | HIDDEN) == 0
                && !DERIVED.contains(&p.n.as_str())
        })
        .map(|(owner, p)| PropertyInfo {
            name: p.n.clone(),
            value_type: p.t.clone(),
            category: p.c.clone(),
            declared_by: owner.into(),
            read_only: false,
            deprecated: false,
        })
        .collect()
}

const GENERIC_BASES: [&str; 2] = ["Instance", "PVInstance"];
const STANDARD_LIMIT: usize = 25;
const PRIORITY: [&str; 25] = [
    "Size", "Position", "CFrame", "Orientation", "Anchored", "CanCollide", "Transparency", "Color", "BrickColor",
    "Material", "Shape", "Visible", "Enabled", "Disabled", "Text", "Value", "Source", "Image", "MeshId", "SoundId",
    "Health", "MaxHealth", "WalkSpeed", "PrimaryPart", "RunContext",
];
const STANDARD_NOISE: [&str; 11] = [
    "Rotation", "AssemblyLinearVelocity", "AssemblyAngularVelocity", "AudioCanCollide", "LocalTransparencyModifier",
    "BackSurface", "BottomSurface", "FrontSurface", "LeftSurface", "RightSurface", "TopSurface",
];

/// The properties worth showing at `detail: "standard"`.
pub async fn standard_properties(class: &str) -> Vec<String> {
    let all = properties_of(class).await;
    if all.is_empty() {
        return vec![];
    }
    let useful: Vec<&PropertyInfo> = all
        .iter()
        .filter(|p| {
            !GENERIC_BASES.contains(&p.declared_by.as_str()) && !p.deprecated && !p.read_only && !STANDARD_NOISE.contains(&p.name.as_str())
        })
        .collect();
    let chosen: Vec<&PropertyInfo> =
        if useful.is_empty() { all.iter().filter(|p| !p.deprecated && !p.read_only).collect() } else { useful };
    let mut ranked: Vec<&str> = chosen.iter().map(|p| p.name.as_str()).collect();
    // Stable sort: ties keep dump order, which is most-derived first.
    ranked.sort_by_key(|name| PRIORITY.iter().position(|p| p == name).unwrap_or(usize::MAX));
    let mut names = vec!["Name".to_string()];
    names.extend(ranked.into_iter().take(STANDARD_LIMIT).filter(|n| *n != "Name").map(str::to_string));
    names
}

fn close_matches<'a>(attempted: &str, candidates: impl Iterator<Item = &'a str>) -> Vec<String> {
    let target = attempted.to_lowercase();
    let limit = 2.max(target.chars().count() / 3);
    let mut scored: Vec<(usize, &str)> = candidates
        .map(|name| (edit_distance(&target, &name.to_lowercase()), name))
        .filter(|(d, _)| *d <= limit)
        .collect();
    scored.sort_by_key(|(d, _)| *d);
    scored.into_iter().take(5).map(|(_, n)| n.to_string()).collect()
}

pub async fn suggest_property(class: &str, attempted: &str) -> Vec<String> {
    let all = properties_of(class).await;
    close_matches(attempted, all.iter().map(|p| p.name.as_str()))
}

pub async fn suggest_class(attempted: &str) -> Vec<String> {
    let Some(index) = index().await else { return vec![] };
    let mut names: Vec<&str> = index.classes.keys().map(String::as_str).collect();
    names.sort_unstable();
    close_matches(attempted, names.into_iter())
}

fn edit_distance(a: &str, b: &str) -> usize {
    if a == b {
        return 0;
    }
    let a: Vec<char> = a.chars().collect();
    let b: Vec<char> = b.chars().collect();
    if a.is_empty() {
        return b.len();
    }
    if b.is_empty() {
        return a.len();
    }
    let mut prev: Vec<usize> = (0..=b.len()).collect();
    let mut cur = vec![0; b.len() + 1];
    for i in 1..=a.len() {
        cur[0] = i;
        for j in 1..=b.len() {
            let sub = prev[j - 1] + usize::from(a[i - 1] != b[j - 1]);
            cur[j] = sub.min(prev[j] + 1).min(cur[j - 1] + 1);
        }
        std::mem::swap(&mut prev, &mut cur);
    }
    prev[b.len()]
}

#[cfg(test)]
mod tests {
    #[test]
    fn distance() {
        assert_eq!(super::edit_distance("anchord", "anchored"), 1);
    }
}
