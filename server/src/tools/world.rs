//! geometry, assets, undo, collision.

use super::{arr_of, call, disp, str_of, u64_of};
use crate::cloud::{self, credentials, live};
use crate::errors::{Result, ToolError};
use crate::format::{PageMeta, ToolResult, error_text, json, table, text};
use crate::tool::{Ctx, Tool, define, spec};
use schemars::JsonSchema;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::sync::Arc;
use std::time::Duration;

// --- geometry --------------------------------------------------------------------

#[derive(Deserialize, Serialize, JsonSchema, PartialEq, Clone, Copy)]
#[serde(rename_all = "lowercase")]
enum GeoOp {
    Union,
    Subtract,
    Intersect,
    Fragment,
    Sweep,
    Segment,
    Mesh,
    Mirror,
}

#[derive(Deserialize, Serialize, JsonSchema, Clone, Copy)]
enum Schema5 {
    Body1,
    Car5,
}

#[derive(Deserialize, Serialize, JsonSchema, Default, Clone, Copy)]
enum Fidelity {
    #[default]
    Default,
    Hull,
    Box,
    PreciseConvexDecomposition,
    Tunable,
}

fn d8() -> u32 {
    8
}
fn d12() -> u32 {
    12
}
fn half() -> f64 {
    0.5
}

#[derive(Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
struct GeoArgs {
    /// 'union' merges, 'subtract' cuts `with` out of `path`, 'intersect' keeps only the overlap, 'fragment' shatters into debris, 'sweep' builds a motion volume, 'segment' cuts a mesh into named parts, 'mesh' reads triangle counts, 'mirror' flips instances across a plane.
    op: GeoOp,
    /// The part being operated on - the one cut from, for subtract. Required for every op except mesh and mirror, which take `paths`.
    path: Option<String>,
    /// mirror only: the plane position, e.g. "0, 0, 0". Defaults to the middle of what is being mirrored, which flips it in place.
    about: Option<String>,
    /// mirror only: leave the originals and add mirrored copies. True by default — that is what builds a symmetrical structure from half of one. False flips the originals in place.
    copy: Option<bool>,
    /// The other parts. Required for union, subtract and intersect.
    #[schemars(length(max = 50))]
    with: Option<Vec<String>>,
    /// fragment only: roughly how many pieces to break into.
    #[serde(default = "d8")]
    #[schemars(range(min = 2, max = 100))]
    pieces: u32,
    /// segment only: the part names to cut into, e.g. ["body", "lid"]. Overrides `schema`.
    #[schemars(length(max = 16))]
    groups: Option<Vec<String>>,
    /// segment only: a built-in split. 'Car5' gives a body and four wheels under fixed names; 'Body1' gives one mesh. Ignored when `groups` is set.
    schema: Option<Schema5>,
    /// segment only: leave the source MeshPart in place instead of replacing it.
    #[serde(default)]
    keep_original: bool,
    /// sweep only: slide to this position, e.g. "0, 10, 0".
    to: Option<String>,
    /// sweep only: rotate this many degrees. Use with `pivot` for a hinge.
    spin: Option<f64>,
    /// sweep: axis to spin around, e.g. "0, 1, 0" (defaults to up). mirror: which axis to flip across — "X", "Y" or "Z", defaulting to X.
    axis: Option<String>,
    /// sweep only: the hinge point. Defaults to the part's own centre, which spins it in place - a door needs its hinge edge here.
    pivot: Option<String>,
    /// sweep only: an explicit path of positions to sweep along.
    #[schemars(length(max = 64))]
    positions: Option<Vec<String>>,
    /// sweep only: how many samples along the motion. Too few cuts corners off an arc.
    #[serde(default = "d12")]
    #[schemars(range(min = 2, max = 64))]
    steps: u32,
    /// sweep only: report what the volume overlaps. An empty array checks against everything; a list checks only those.
    #[schemars(length(max = 50))]
    check_against: Option<Vec<String>>,
    /// sweep only: leave the volume as a part. Off measures and cleans up.
    #[serde(default = "super::d::t")]
    keep: bool,
    /// sweep only: how see-through the volume is.
    #[serde(default = "half")]
    #[schemars(range(min = 0, max = 1))]
    transparency: f64,
    /// Name for the result. Defaults to the original's.
    name: Option<String>,
    /// Where to put the result. Defaults to the original's parent.
    parent: Option<String>,
    /// segment only: where to place the result. Defaults to where the source was.
    position: Option<String>,
    /// segment only: scale so the longest side is this many studs.
    #[schemars(range(min = 0.000001))]
    scale_to: Option<f64>,
    /// segment only: anchor every part.
    #[serde(default = "super::d::t")]
    anchor: bool,
    /// Leave the input parts in place instead of consuming them.
    #[serde(default)]
    keep_originals: bool,
    /// How exactly the result collides. Precise is expensive - raise it only for a surface players walk on. Tunable picks a precision from the size and handles thin details better; adjust it afterwards with `modify` on CollisionPrecision.
    #[serde(default)]
    collision_fidelity: Fidelity,
    /// Return disconnected chunks as separate parts rather than one.
    #[serde(default)]
    split_apart: bool,
    /// mesh and mirror: the instances to read or flip.
    #[schemars(length(max = 50))]
    paths: Option<Vec<String>>,
    /// Target Studio; omit for the active one.
    studio_id: Option<String>,
}

fn undo_line(r: &Value) -> Option<String> {
    (r.get("undoable") != Some(&Value::Bool(true))).then(|| "Studio would not open an undo recording, so this is not one Ctrl+Z.".to_string())
}

fn strs(v: &Value, key: &str) -> Vec<String> {
    arr_of(v, key).iter().map(|x| disp(Some(x))).collect()
}

async fn geometry(ctx: Arc<Ctx>, a: GeoArgs) -> Result<ToolResult> {
    let studio = a.studio_id.as_deref();
    let targets = || a.paths.clone().unwrap_or_else(|| a.path.clone().into_iter().collect());
    match a.op {
        GeoOp::Mirror => {
            let paths = targets();
            if paths.is_empty() {
                return Ok(error_text("mirror needs `paths` — the instances to flip."));
            }
            let r = call(&ctx, "geometry.mirror", json!({ "paths": paths, "axis": a.axis, "about": a.about, "copy": a.copy }), studio, Some(60_000.0)).await?;
            return Ok(json(&r, None));
        }
        GeoOp::Mesh => {
            let paths = targets();
            if paths.is_empty() {
                return Ok(error_text("mesh needs `paths` — the MeshParts to read, e.g. [\"Workspace.Tree\"]."));
            }
            // Each part is a separate download-and-open.
            let r = call(&ctx, "geometry.mesh", json!({ "paths": paths }), studio, Some(120_000.0)).await?;
            let items = arr_of(&r, "items");
            let failures = strs(&r, "failures");
            if items.is_empty() {
                return Ok(text(if failures.is_empty() {
                    "No MeshParts in that list.".to_string()
                } else {
                    format!("Nothing readable:\n  {}", failures.join("\n  "))
                }));
            }
            let rendered = table(
                &["name", "triangles", "vertices", "meshSize", "partSize", "renderFidelity", "collisionFidelity"],
                items,
                PageMeta { more: Some(format!("{} triangles across {} part(s)", disp(r.get("totalTriangles")), items.len())), ..Default::default() },
            )
            .text_of();
            return Ok(text(if failures.is_empty() { rendered } else { format!("{rendered}\n\nSkipped:\n  {}", failures.join("\n  ")) }));
        }
        _ => {}
    }
    let Some(path) = a.path.clone().filter(|p| !p.is_empty()) else {
        let name = serde_json::to_value(a.op)?.as_str().unwrap_or("").to_string();
        return Err(ToolError::bad_params(format!("{name} needs `path` — the part to operate on.")));
    };
    match a.op {
        GeoOp::Segment => {
            let r = call(
                &ctx,
                "generate.segment",
                json!({
                    "path": path, "groups": a.groups, "schema": a.schema.unwrap_or(Schema5::Body1),
                    "keepOriginal": a.keep_original, "name": a.name, "parent": a.parent, "position": a.position,
                    "scaleTo": a.scale_to, "anchor": a.anchor,
                }),
                studio,
                Some(240_000.0),
            )
            .await?;
            let mut lines = vec![
                format!("{}  ({}, {} studs)", disp(r.get("path")), disp(r.get("schema")), disp(r.get("size"))),
                format!("Parts: {}", strs(&r, "parts").join(", ")),
            ];
            if let Some(removed) = str_of(&r, "removed") {
                lines.push(format!("Replaced {removed}."));
            }
            if r.get("steps").and_then(Value::as_u64) == Some(2) {
                lines.push("Two undo steps: the placement, then removing the original.".into());
            }
            Ok(text(lines.join("\n")))
        }
        GeoOp::Sweep => {
            let r = call(
                &ctx,
                "geometry.sweep",
                json!({
                    "path": path, "to": a.to, "spin": a.spin, "axis": a.axis, "pivot": a.pivot, "positions": a.positions,
                    "steps": a.steps, "checkAgainst": a.check_against, "keep": a.keep, "transparency": a.transparency,
                    "name": a.name, "parent": a.parent, "collisionFidelity": a.collision_fidelity,
                }),
                studio,
                Some(120_000.0),
            )
            .await?;
            let frames = disp(r.get("frames"));
            let mut lines = vec![if r.get("kept") == Some(&Value::Bool(true)) {
                format!("{}  (swept through {frames} positions)", strs(&r, "created").first().cloned().unwrap_or_default())
            } else {
                format!("Measured a sweep through {frames} positions; the volume was not kept.")
            }];
            if r.get("checked") == Some(&Value::Bool(true)) {
                let hits = strs(&r, "hits");
                lines.push(if hits.is_empty() { "Clear - the motion hits nothing.".into() } else { format!("Hits {}: {}", hits.len(), hits.join(", ")) });
            }
            lines.extend(undo_line(&r));
            Ok(text(lines.join("\n")))
        }
        op => {
            let fragment = op == GeoOp::Fragment;
            // Solid modelling on a complex mesh is genuinely slow.
            let r = call(
                &ctx,
                if fragment { "geometry.fragment" } else { "geometry.combine" },
                json!({
                    "op": op, "path": path, "with": a.with, "pieces": a.pieces, "name": a.name, "parent": a.parent,
                    "keepOriginals": a.keep_originals, "collisionFidelity": a.collision_fidelity, "splitApart": a.split_apart,
                }),
                studio,
                Some(120_000.0),
            )
            .await?;
            let mut notes = Vec::new();
            let removed = strs(&r, "removed");
            if !removed.is_empty() {
                notes.push(format!("Consumed: {}.", removed.join(", ")));
            }
            notes.extend(undo_line(&r));
            let note = (!notes.is_empty()).then(|| notes.join(" "));
            Ok(json(r.get("created").unwrap_or(&json!([])), note.as_deref()))
        }
    }
}

// --- assets ------------------------------------------------------------------------

const TOOLBOX_SEARCH: &str = "https://apis.roblox.com/toolbox-service/v1/marketplace";
const TOOLBOX_DETAILS: &str = "https://apis.roblox.com/toolbox-service/v1/items/details";
const MAX_PAGES: usize = 4;

#[derive(Default)]
struct StoreFilters {
    exclude_scripts: bool,
    max_triangles: Option<u64>,
    verified_only: bool,
    free_only: bool,
    min_votes: Option<u64>,
}

struct Found {
    items: Vec<Value>,
    scanned: usize,
    total: Option<u64>,
}

/// Creator Store search; filtering and ranking happen here because the API ignores its own.
async fn search_store(keyword: &str, category: &str, limit: usize, f: &StoreFilters) -> Result<Found> {
    let category_id = match category {
        "decal" => 13,
        "mesh" => 40,
        "audio" => 3,
        _ => 10,
    };
    let client = cloud::client();
    let mut kept: Vec<Value> = Vec::new();
    let mut cursor = String::new();
    let mut scanned = 0;
    let mut total = None;
    for _ in 0..MAX_PAGES {
        if kept.len() >= limit {
            break;
        }
        let mut request = client.get(format!("{TOOLBOX_SEARCH}/{category_id}")).query(&[("keyword", keyword), ("limit", "30")]);
        if !cursor.is_empty() {
            request = request.query(&[("cursor", &cursor)]);
        }
        let found = request.timeout(Duration::from_secs(15)).send().await.map_err(ToolError::internal)?;
        if !found.status().is_success() {
            return Err(ToolError::internal(format!(
                "Creator Store search failed ({}). Roblox may be rate-limiting.",
                found.status().as_u16()
            )));
        }
        let results: Value = found.json().await.map_err(ToolError::internal)?;
        total = total.or_else(|| results.get("totalResults").and_then(Value::as_u64));
        let ids: Vec<String> = arr_of(&results, "data").iter().filter_map(|d| d.get("id")).map(|id| disp(Some(id))).collect();
        if ids.is_empty() {
            break;
        }
        scanned += ids.len();
        let detailed = client
            .get(TOOLBOX_DETAILS)
            .query(&[("assetIds", ids.join(","))])
            .timeout(Duration::from_secs(15))
            .send()
            .await
            .map_err(ToolError::internal)?;
        if !detailed.status().is_success() {
            return Err(ToolError::internal(format!("Could not read asset details ({}).", detailed.status().as_u16())));
        }
        let payload: Value = detailed.json().await.map_err(ToolError::internal)?;
        for entry in arr_of(&payload, "data") {
            let b = |p: &str| entry.pointer(p).and_then(Value::as_bool);
            if f.exclude_scripts && b("/asset/hasScripts") == Some(true) {
                continue;
            }
            if f.verified_only && b("/creator/isVerifiedCreator") != Some(true) {
                continue;
            }
            if f.free_only && b("/fiatProduct/isFree") == Some(false) {
                continue;
            }
            if let Some(min) = f.min_votes
                && entry.pointer("/voting/voteCount").and_then(Value::as_u64).unwrap_or(0) < min {
                    continue;
                }
            if let Some(max) = f.max_triangles
                && entry.pointer("/asset/modelTechnicalDetails/objectMeshSummary/triangles").and_then(Value::as_u64).is_some_and(|t| t > max) {
                    continue;
                }
            kept.push(entry.clone());
        }
        cursor = str_of(&results, "nextPageCursor").unwrap_or("").to_string();
        if cursor.is_empty() {
            break;
        }
    }
    // Approval weighted by votes: 100% of two voters must not outrank 82% of five thousand.
    let score = |e: &Value| {
        let percent = e.pointer("/voting/upVotePercent").and_then(Value::as_f64).unwrap_or(50.0);
        let votes = e.pointer("/voting/voteCount").and_then(Value::as_f64).unwrap_or(0.0);
        50.0 + (percent - 50.0) * (votes / (votes + 50.0))
    };
    kept.sort_by(|x, y| score(y).total_cmp(&score(x)));
    kept.truncate(limit);
    Ok(Found { items: kept, scanned, total })
}

#[derive(Deserialize, Serialize, JsonSchema, PartialEq, Clone, Copy)]
#[serde(rename_all = "lowercase")]
enum AssetOp {
    Search,
    Peek,
    Insert,
    Bake,
    Upload,
    Grant,
    Publish,
    Quota,
}

#[derive(Deserialize, Serialize, JsonSchema, Clone, Copy)]
enum UploadType {
    Audio,
    Decal,
    Model,
    Video,
}

#[derive(Deserialize, Serialize, JsonSchema, Clone, Copy, PartialEq)]
enum Subject {
    Universe,
    User,
    Group,
}

#[derive(Deserialize, Serialize, JsonSchema, Default, Clone, Copy, PartialEq)]
#[serde(rename_all = "lowercase")]
enum Category {
    #[default]
    Model,
    Decal,
    Mesh,
    Audio,
}

#[derive(Deserialize, Serialize, JsonSchema, Default, Clone, Copy)]
enum AudioType {
    #[default]
    SoundEffect,
    Music,
}

fn d8u() -> usize {
    8
}

#[derive(Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
struct AssetArgs {
    /// 'search' finds assets, 'peek' shows what is inside one without inserting it, 'insert' adds one to the place, 'bake' makes in-memory mesh and image data replicate, 'upload' sends a local file to Roblox, 'grant' shares one you own with another game or person, 'publish' pushes a place file live.
    op: AssetOp,
    /// upload/publish: path to the file on disk. Omit on `upload` to check whether the credentials are set up without sending anything.
    file: Option<String>,
    /// upload only: public description. Moderated.
    description: Option<String>,
    /// upload only: override the type derived from the extension. Rarely right — Roblox validates the type against the file's real content.
    asset_type: Option<UploadType>,
    /// upload only: put the finished asset in the place at this parent path once it is approved. Decals and Models only — an audio id belongs in an AudioPlayer, so use `audio op="graph"` with the id this returns.
    insert_as: Option<String>,
    /// grant only: the assets to share. You must own them.
    #[schemars(length(max = 50))]
    asset_ids: Option<Vec<i64>>,
    /// grant only: who gets access. 'Universe' is a game and is the usual one. Defaults to 'Universe'.
    subject_type: Option<Subject>,
    /// grant only: the universe, user or group id. Omit for a Universe grant to use the one set with `cloud universe <id>`.
    subject_id: Option<String>,
    /// publish only: which game. Omit to use `cloud universe`.
    universe_id: Option<String>,
    /// publish only: which place. Omit to use `cloud place`.
    place_id: Option<String>,
    /// publish only: also roll live servers onto the new version. Without this, players already in a server keep running the old code until it empties.
    restart: Option<bool>,
    /// insert only: delete every Script, LocalScript and ModuleScript from the asset on the way in. The safe way to take geometry from a free model without taking whatever its scripts do.
    strip_scripts: Option<bool>,
    /// Required to make a `publish` go live rather than only save, and required for `grant`, whose effect Roblox cannot undo.
    confirm: Option<bool>,
    /// search only: what to look for, e.g. "medieval door".
    keyword: Option<String>,
    /// search only: what kind of asset. Only models insert as instances.
    #[serde(default)]
    category: Category,
    /// search only: how many results.
    #[serde(default = "d8u")]
    #[schemars(range(min = 1, max = 20))]
    limit: usize,
    /// search only: drop every result that contains scripts. The single safest filter — a free model's scripts run with your game's full permissions.
    #[serde(default)]
    exclude_scripts: bool,
    /// search only: drop models heavier than this. A prop you place fifty times wants to be in the hundreds, not the tens of thousands.
    #[schemars(range(min = 1))]
    max_triangles: Option<u64>,
    /// search only: only results from verified creators.
    #[serde(default)]
    verified_only: bool,
    /// search only: drop paid assets, which cannot just be inserted.
    #[serde(default)]
    free_only: bool,
    /// search only: require at least this many votes. Filters out models with a perfect score from three people.
    min_votes: Option<u64>,
    /// audio search only: shortest clip to return, in seconds.
    #[schemars(range(min = 0))]
    min_duration: Option<f64>,
    /// audio search only: longest clip to return, in seconds. Set it to 3 or so for effects — otherwise full-length music dominates the results.
    #[schemars(range(min = 0))]
    max_duration: Option<f64>,
    /// audio search only. Defaults to SoundEffect, which is what a noise in a game is. Ask for "Music" only when you want a track — the engine's own default is Music, and it makes "footstep" return three-minute ambient songs with footsteps in the title.
    #[serde(default)]
    audio_type: AudioType,
    /// insert and peek only: the asset id.
    #[schemars(range(min = 1))]
    asset_id: Option<u64>,
    /// insert only: where to put it. Defaults to Workspace.
    parent: Option<String>,
    /// insert only: where to place it, e.g. "0, 10, 0". Defaults to wherever it was saved.
    position: Option<String>,
    /// insert only: rename it on the way in.
    name: Option<String>,
    /// bake only: MeshParts to convert, or models containing them.
    #[schemars(length(max = 200))]
    paths: Option<Vec<String>>,
    /// Target Studio; omit for the active one.
    studio_id: Option<String>,
}

async fn assets(ctx: Arc<Ctx>, a: AssetArgs) -> Result<ToolResult> {
    let studio = a.studio_id.as_deref();
    match a.op {
        AssetOp::Peek => {
            let Some(id) = a.asset_id else { return Ok(error_text("peek needs an `assetId`.")) };
            let r = call(&ctx, "assets.peek", json!({ "assetId": id }), studio, Some(60_000.0)).await?;
            let scripts = strs(&r, "scripts");
            let count = u64_of(&r, "scriptCount");
            let mut lines = vec![
                format!("Asset {}: {} instances, nothing inserted.", disp(r.get("assetId")), disp(r.get("descendants"))),
                String::new(),
                format!("Top level: {}", strs(&r, "roots").join(", ")),
                String::new(),
                table(&["className", "count"], arr_of(&r, "classes"), PageMeta::default()).text_of(),
            ];
            lines.push(if count == 0 {
                "\nNo scripts — safe to insert.".into()
            } else {
                format!(
                    "\n{count} script(s), and inserting runs them:\n  {}\nRead them with `script_read` after inserting, or leave this asset alone.",
                    scripts.join("\n  ")
                )
            });
            Ok(text(lines.join("\n")))
        }
        AssetOp::Search if a.category == Category::Audio => {
            let Some(keyword) = &a.keyword else { return Ok(error_text("search needs a `keyword`.")) };
            let r = call(
                &ctx,
                "assets.audio",
                json!({
                    "keyword": keyword, "limit": a.limit, "minDuration": a.min_duration,
                    "maxDuration": a.max_duration, "audioType": a.audio_type,
                }),
                studio,
                Some(45_000.0),
            )
            .await?;
            let items = arr_of(&r, "items");
            if items.is_empty() {
                return Ok(text(format!(
                    "No audio matched \"{keyword}\".{}",
                    if a.min_duration.is_some() || a.max_duration.is_some() {
                        " The duration filter may be too narrow — try it without one."
                    } else {
                        ""
                    }
                )));
            }
            let kind = disp(r.get("audioType"));
            let more = format!(
                "{kind}s only; duration in seconds; use the assetId as a Sound's SoundId{}",
                if kind == "SoundEffect" { ". Pass audioType=\"Music\" for tracks." } else { "." }
            );
            Ok(table(&["assetId", "title", "artist", "duration", "audioType", "endorsed"], items, PageMeta { more: Some(more), ..Default::default() }))
        }
        AssetOp::Search => {
            let Some(keyword) = &a.keyword else { return Ok(error_text("search needs a `keyword`.")) };
            let category = serde_json::to_value(a.category)?.as_str().unwrap_or("model").to_string();
            let filters = StoreFilters {
                exclude_scripts: a.exclude_scripts,
                max_triangles: a.max_triangles,
                verified_only: a.verified_only,
                free_only: a.free_only,
                min_votes: a.min_votes,
            };
            let found = search_store(keyword, &category, a.limit, &filters).await?;
            if found.items.is_empty() {
                let filtered = a.exclude_scripts || a.verified_only || a.free_only || a.max_triangles.is_some() || a.min_votes.is_some_and(|v| v > 0);
                return Ok(text(format!(
                    "Nothing matched \"{keyword}\" in {category}s{}",
                    if filtered {
                        format!(". {} result(s) were checked and every one was filtered out — loosen a filter.", found.scanned)
                    } else {
                        ".".into()
                    }
                )));
            }
            let rows: Vec<Value> = found
                .items
                .iter()
                .map(|e| {
                    let p = |path: &str| e.pointer(path);
                    let has_scripts = p("/asset/hasScripts") == Some(&Value::Bool(true));
                    let kinds: Vec<String> = p("/asset/objectTypes").and_then(Value::as_array).map(|k| k.iter().map(|x| disp(Some(x))).collect()).unwrap_or_default();
                    json!({
                        "assetId": p("/asset/id").cloned().unwrap_or(json!(0)),
                        "name": p("/asset/name").and_then(Value::as_str).unwrap_or("?"),
                        "creator": format!(
                            "{}{}",
                            p("/creator/name").and_then(Value::as_str).unwrap_or("?"),
                            if p("/creator/isVerifiedCreator") == Some(&Value::Bool(true)) { " ✓" } else { "" }
                        ),
                        "approval": match p("/voting/upVotePercent").filter(|v| !v.is_null()) {
                            Some(pct) => format!("{}% ({})", disp(Some(pct)), p("/voting/voteCount").map(|c| disp(Some(c))).unwrap_or_else(|| "0".into())),
                            None => "—".into(),
                        },
                        "scripts": if has_scripts { p("/asset/scriptCount").cloned().filter(|v| !v.is_null()).unwrap_or(json!("yes")) } else { json!("no") },
                        "triangles": p("/asset/modelTechnicalDetails/objectMeshSummary/triangles").cloned().filter(|v| !v.is_null()).unwrap_or(json!("—")),
                        "free": if p("/fiatProduct/isFree") == Some(&Value::Bool(false)) { "PAID" } else { "free" },
                        "kind": if kinds.is_empty() { "—".to_string() } else { kinds.join("/") },
                    })
                })
                .collect();
            let names = |pred: &dyn Fn(&Value) -> bool| -> Vec<String> { rows.iter().filter(|r| pred(r)).map(|r| disp(r.get("name"))).collect() };
            let risky = names(&|r| r.get("scripts") != Some(&json!("no")));
            let paid = names(&|r| r.get("free") == Some(&json!("PAID")));
            let mut notes = vec![format!(
                "{} shown of {} checked{}; ranked by approval weighted by vote count.",
                found.items.len(),
                found.scanned,
                found.total.map(|t| format!(" ({t} exist)")).unwrap_or_default()
            )];
            notes.push(if risky.is_empty() {
                "None of these contain scripts.".into()
            } else {
                format!(
                    "{} contain scripts ({}). Inserting one runs whatever its author put in it — use `peek` to read them first, or pass excludeScripts.",
                    risky.len(),
                    risky.join(", ")
                )
            });
            if !paid.is_empty() {
                notes.push(format!("{} are PAID and cannot simply be inserted: {}.", paid.len(), paid.join(", ")));
            }
            let listing = table(&["assetId", "name", "creator", "approval", "scripts", "triangles", "free", "kind"], &rows, PageMeta::default()).text_of();
            Ok(text(format!("{listing}\n\n{}", notes.join("\n"))))
        }
        AssetOp::Quota => Ok(json(&live::asset_quotas(&cloud::require_credentials().await?).await?, None)),
        AssetOp::Upload => {
            let Some(file) = &a.file else {
                let status = credentials::status().await;
                if !status.has_key || status.creator_id.is_none() {
                    return Err(ToolError::hint(
                        "NO_CREDENTIALS",
                        "No Open Cloud key is set up, so nothing can be uploaded.",
                        "Ask the user to type `cloud` in the Studio panel — it walks through creating the key and stores it safely. Never ask them to paste a key into this conversation.",
                    ));
                }
                return Ok(text(format!(
                    "Ready to upload: key set, uploading as {} {}. Call again with `file`.",
                    status.creator_field.unwrap_or("userId"),
                    status.creator_id.unwrap_or_default()
                )));
            };
            let creds = cloud::require_credentials().await?;
            let kind = a.asset_type.map(|t| serde_json::to_value(t).unwrap_or_default());
            let mut uploaded = cloud::assets::upload(&creds, file, a.name.as_deref(), a.description.as_deref(), kind.as_ref().and_then(Value::as_str)).await?;
            let asset_id = disp(uploaded.get("assetId"));
            let approved = uploaded.get("approved") == Some(&Value::Bool(true));
            // Only inserted once approved: a rejected asset would point at nothing.
            if let (Some(parent), true) = (&a.insert_as, approved) {
                let inserted = match str_of(&uploaded, "assetType") {
                    Some("Audio") => {
                        uploaded["note"] = json!(format!(
                            "Audio is not inserted on its own — the id goes into an AudioPlayer. Build one with `audio op=\"graph\" asset=\"rbxassetid://{asset_id}\"`."
                        ));
                        json!(false)
                    }
                    Some("Decal") => {
                        call(
                            &ctx,
                            "instances.create",
                            json!({ "instances": [{
                                "className": "Decal",
                                "name": a.name.clone().unwrap_or_else(|| "Decal".into()),
                                "parent": parent,
                                "properties": { "Texture": { "value": format!("rbxassetid://{asset_id}"), "type": "ContentId" } },
                            }] }),
                            studio,
                            Some(30_000.0),
                        )
                        .await?
                    }
                    _ => call(&ctx, "assets.insert", json!({ "assetId": asset_id.parse::<u64>().unwrap_or(0), "parent": parent }), studio, Some(90_000.0)).await?,
                };
                uploaded["inserted"] = inserted;
            }
            let note = if approved {
                format!("Use it as rbxassetid://{asset_id}.")
            } else {
                format!("Moderation says {}. The id exists but may not load until review finishes.", disp(uploaded.get("moderation")))
            };
            Ok(json(&uploaded, Some(&note)))
        }
        AssetOp::Grant => {
            let ids = a.asset_ids.clone().filter(|i| !i.is_empty()).ok_or_else(|| ToolError::bad_params("grant needs `assetIds`."))?;
            let subject = a.subject_type.unwrap_or(Subject::Universe);
            let subject_name = serde_json::to_value(subject)?.as_str().unwrap_or("Universe").to_string();
            let subject_id = if subject == Subject::Universe {
                Some(cloud::require_universe(a.subject_id.as_deref()).await?)
            } else {
                a.subject_id.clone().filter(|s| !s.is_empty())
            };
            let Some(subject_id) = subject_id else {
                return Err(ToolError::bad_params(format!("grant to a {subject_name} needs a `subjectId`.")));
            };
            if a.confirm != Some(true) {
                return Err(ToolError::hint(
                    "NEEDS_CONFIRM",
                    "Granting a game access to an asset is permanent.",
                    "Roblox provides no way to revoke it. Pass confirm: true once you are sure of the asset ids and the subject.",
                ));
            }
            let creds = cloud::require_credentials().await?;
            Ok(json(&cloud::assets::grant(&creds, &ids, &subject_name, &subject_id).await?, None))
        }
        AssetOp::Publish => {
            let file = a.file.as_deref().ok_or_else(|| ToolError::bad_params("publish needs a `file` (.rbxl or .rbxlx)."))?;
            let creds = cloud::require_credentials().await?;
            let universe = cloud::require_universe(a.universe_id.as_deref()).await?;
            let place = cloud::require_place(a.place_id.as_deref()).await?;
            let live_now = a.confirm == Some(true);
            let mut published = cloud::assets::publish_place(&creds, file, &universe, &place, live_now).await?;
            // Restarting after a mere save would roll servers onto the PREVIOUS version.
            if a.restart == Some(true) {
                published["restart"] = if live_now {
                    live::restart_servers(&creds, &universe, Some(vec![place.parse().unwrap_or(0)]), None).await?
                } else {
                    json!("Not restarted: the file was only saved, not published. A restart now would roll servers onto the PREVIOUS version.")
                };
            }
            Ok(json(&published, None))
        }
        AssetOp::Bake => {
            let Some(paths) = a.paths.filter(|p| !p.is_empty()) else {
                return Ok(error_text("bake needs `paths` — the MeshParts or models to convert."));
            };
            let r = call(&ctx, "assets.bake", json!({ "paths": paths }), studio, Some(180_000.0)).await?;
            let converted = strs(&r, "converted");
            let skipped = arr_of(&r, "skipped").len();
            let failed = strs(&r, "failed");
            let opaque = u64_of(&r, "opaque");
            let mut lines = vec![format!("Examined {} MeshPart(s).", disp(r.get("examined")))];
            if !converted.is_empty() {
                lines.push(format!("Converted {}: {}", converted.len(), converted.join(", ")));
            }
            if skipped > 0 {
                lines.push(format!("Already replicating, left alone: {skipped}."));
            }
            if opaque > 0 {
                lines.push(format!(
                    "{opaque} hold opaque content, which the engine will not bake. That is what `generate` produces — those meshes are edit-mode only, and nothing here can change that yet."
                ));
            }
            if !failed.is_empty() {
                lines.push(format!("Refused: {}", failed.join("; ")));
            }
            if converted.is_empty() && failed.is_empty() && opaque == 0 {
                lines.push("Nothing needed baking — none of it was editable content.".into());
            }
            Ok(text(lines.join("\n")))
        }
        AssetOp::Insert => {
            let Some(id) = a.asset_id else {
                return Ok(error_text("insert needs an `assetId`. Use `op: \"search\"` to find one."));
            };
            let r = call(
                &ctx,
                "assets.insert",
                json!({ "assetId": id, "parent": a.parent, "position": a.position, "name": a.name, "stripScripts": a.strip_scripts }),
                studio,
                Some(90_000.0),
            )
            .await?;
            let mut notes = Vec::new();
            let count = u64_of(&r, "scriptCount");
            if count > 0 {
                notes.push(format!(
                    "WARNING: this asset contains {count} script(s): {}. They will run on the next playtest. Read them before playing, or delete them.",
                    strs(&r, "scripts").join(", ")
                ));
            }
            if r.get("undoable") != Some(&Value::Bool(true)) {
                notes.push("Not undoable as one step.".into());
            }
            let note = (!notes.is_empty()).then(|| notes.join("\n\n"));
            Ok(json(r.get("inserted").unwrap_or(&json!([])), note.as_deref()))
        }
    }
}

// --- undo ----------------------------------------------------------------------------

#[derive(Deserialize, Serialize, JsonSchema, Default, Clone, Copy)]
#[serde(rename_all = "lowercase")]
enum UndoAction {
    Undo,
    Redo,
    #[default]
    Status,
}

fn one() -> u32 {
    1
}

#[derive(Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
struct UndoArgs {
    /// 'status' reports what is available without changing anything.
    #[serde(default)]
    action: UndoAction,
    /// How many steps to take. Keep it to what you did yourself.
    #[serde(default = "one")]
    #[schemars(range(min = 1, max = 25))]
    steps: u32,
    /// Target Studio; omit for the active one.
    studio_id: Option<String>,
}

// --- collision -------------------------------------------------------------------------

#[derive(Deserialize, Serialize, JsonSchema, Default, Clone, Copy, PartialEq)]
#[serde(rename_all = "lowercase")]
enum CollisionAction {
    #[default]
    List,
    Create,
    Assign,
    Collidable,
    Remove,
    Cast,
    Overlap,
}

#[derive(Deserialize, Serialize, JsonSchema, Clone, Copy)]
#[serde(rename_all = "lowercase")]
enum CastShape {
    Ray,
    Block,
    Sphere,
    Part,
}

#[derive(Deserialize, Serialize, JsonSchema, Clone, Copy)]
#[serde(rename_all = "lowercase")]
enum Region {
    Box,
    Radius,
    Part,
}

#[derive(Deserialize, Serialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
struct CollisionArgs {
    /// Groups: 'list' shows them and changes nothing, then 'create', 'assign', 'collidable', 'remove' (which unregisters a group entirely — not the same as un-assigning parts). Queries: 'cast' fires a shape and reports the first hit, 'overlap' lists what is inside a volume.
    #[serde(default)]
    action: CollisionAction,
    /// cast only: 'ray' is a line and the usual choice. 'block' and 'sphere' sweep a volume along the same path — use them when the thing moving has width, e.g. whether a character fits through a gap rather than whether a point does. 'part' sweeps the real shape of the part at `path` (meshes included); `from` and `size` override its start and size without moving it.
    #[serde(skip_serializing_if = "Option::is_none")]
    shape: Option<CastShape>,
    /// cast only: inflate the swept shape by this many studs on every side. On a ray it makes a sphere cast of that radius.
    #[serde(skip_serializing_if = "Option::is_none")]
    #[schemars(range(min = 0))]
    margin: Option<f64>,
    /// cast only: grow or shrink the shape along the cast. 0.5 ends 50% larger (a cone, e.g. vision checks), -0.5 at half size, -1 to nothing (a funnel).
    #[serde(skip_serializing_if = "Option::is_none")]
    #[schemars(range(min = -1))]
    size_gradient: Option<f64>,
    /// cast only: turn on Studio's shapecast overlay so the user sees the sweep (green hit, red miss). Stays on until switched off in Visualization Modes.
    #[serde(skip_serializing_if = "Option::is_none")]
    visualize: Option<bool>,
    /// cast only: where the cast starts, e.g. "12, 0, 5".
    #[serde(skip_serializing_if = "Option::is_none")]
    from: Option<String>,
    /// cast only: a point to aim at. Use this for sightlines — it saves working out a direction vector, which is where sign errors live.
    #[serde(skip_serializing_if = "Option::is_none")]
    to: Option<String>,
    /// cast only: which way to go, e.g. "0, -1, 0" for down. Used with `distance`.
    #[serde(skip_serializing_if = "Option::is_none")]
    direction: Option<String>,
    /// cast only: how far along `direction`. Defaults to 100.
    #[serde(skip_serializing_if = "Option::is_none")]
    distance: Option<f64>,
    /// cast shape="block" or overlap region="box": the volume size. Defaults to "1, 1, 1" for a cast and "4, 4, 4" for an overlap.
    #[serde(skip_serializing_if = "Option::is_none")]
    size: Option<String>,
    /// cast shape="sphere" or overlap region="radius": the radius. Defaults to 1 for a cast and 4 for an overlap.
    #[serde(skip_serializing_if = "Option::is_none")]
    radius: Option<f64>,
    /// overlap only: 'box' and 'radius' need `at`; 'part' takes `path` and reports what overlaps that part — the fastest way to find things clipping through each other. Defaults to 'box'.
    #[serde(skip_serializing_if = "Option::is_none")]
    region: Option<Region>,
    /// overlap only: the centre, for region "box" or "radius".
    #[serde(skip_serializing_if = "Option::is_none")]
    at: Option<String>,
    /// overlap region="part": the part to test against. cast shape="part": the part to sweep.
    #[serde(skip_serializing_if = "Option::is_none")]
    path: Option<String>,
    /// cast/overlap: consider ONLY these instances and their descendants.
    #[serde(skip_serializing_if = "Option::is_none")]
    only: Option<Vec<String>>,
    /// cast/overlap: skip these and their descendants. The usual case is the character doing the looking, which otherwise blocks its own cast at zero distance.
    #[serde(skip_serializing_if = "Option::is_none")]
    ignore: Option<Vec<String>>,
    /// cast/overlap: run the query as if from a part in this group. Required for a truthful answer in any place that uses groups.
    #[serde(skip_serializing_if = "Option::is_none")]
    collision_group: Option<String>,
    /// cast/overlap: skip parts with CanCollide off. Off by default, matching the engine — leave it off to ask what is there, turn it on to ask what would stop a player.
    #[serde(skip_serializing_if = "Option::is_none")]
    respect_can_collide: Option<bool>,
    /// cast only: pass through terrain water instead of hitting it.
    #[serde(skip_serializing_if = "Option::is_none")]
    ignore_water: Option<bool>,
    /// overlap only: how many parts to list. Defaults to 50.
    #[serde(skip_serializing_if = "Option::is_none")]
    #[schemars(range(min = 1, max = 500))]
    limit: Option<u32>,
    /// The group's name. Required for everything but list.
    #[serde(skip_serializing_if = "Option::is_none")]
    group: Option<String>,
    /// assign only: parts or models to put in the group.
    #[serde(skip_serializing_if = "Option::is_none")]
    #[schemars(length(max = 100))]
    paths: Option<Vec<String>>,
    /// collidable only: the other group.
    #[serde(skip_serializing_if = "Option::is_none")]
    with: Option<String>,
    /// collidable only: whether the two groups collide. False makes them pass through.
    #[serde(default = "super::d::t")]
    collidable: bool,
    /// Path to a WorldModel whose own collision groups this call is about, e.g. "StarterGui.Preview.Viewport.WorldModel". Omit for the Workspace, which is what you want unless the parts in question live inside a ViewportFrame.
    #[serde(skip_serializing_if = "Option::is_none")]
    world_model: Option<String>,
    /// Target Studio; omit for the active one.
    #[serde(skip_serializing)]
    studio_id: Option<String>,
}

async fn collision(ctx: Arc<Ctx>, a: CollisionArgs) -> Result<ToolResult> {
    let studio = a.studio_id.as_deref();
    if matches!(a.action, CollisionAction::Cast | CollisionAction::Overlap) {
        let cast = a.action == CollisionAction::Cast;
        let mut params = serde_json::to_value(&a)?;
        if let Some(obj) = params.as_object_mut() {
            for k in ["action", "group", "paths", "with", "collidable"] {
                obj.remove(k);
            }
        }
        let q = call(&ctx, if cast { "spatial.cast" } else { "spatial.overlap" }, params, studio, Some(30_000.0)).await?;
        if !cast
            && let Some(items) = q.get("items").and_then(Value::as_array) {
                let where_ = match str_of(&q, "region") {
                    Some("part") => format!("overlapping {}", q.get("path").map(|p| disp(Some(p))).unwrap_or_else(|| a.path.clone().unwrap_or_default())),
                    Some("radius") => format!("within {} of {}", disp(q.get("radius")), disp(q.get("at"))),
                    _ => format!("in box {} at {}", disp(q.get("size")), disp(q.get("at"))),
                };
                if items.is_empty() {
                    return Ok(text(format!("Nothing {where_}.")));
                }
                let summary = format!(
                    "{} part(s) {where_}, {}{}",
                    q.get("count").map(|c| disp(Some(c))).unwrap_or_else(|| items.len().to_string()),
                    str_of(&q, "world").unwrap_or("Workspace"),
                    if q.get("truncated") == Some(&Value::Bool(true)) { "; truncated — raise `limit` or narrow the region" } else { "" }
                );
                return Ok(table(&["path", "class", "position", "size", "canCollide", "collisionGroup"], items, PageMeta { more: Some(summary), ..Default::default() }));
            }
        if cast && q.get("hit") == Some(&Value::Bool(false)) {
            return Ok(json(
                &q,
                Some("Nothing was hit. If that is a surprise: a `direction` pointing the wrong way, a `distance` shorter than the gap, or an `only` filter excluding what you meant to find."),
            ));
        }
        return Ok(json(&q, None));
    }
    let r = call(
        &ctx,
        "world.collision",
        json!({ "action": a.action, "group": a.group, "paths": a.paths, "with": a.with, "collidable": a.collidable, "worldModel": a.world_model }),
        studio,
        None,
    )
    .await?;
    if a.action == CollisionAction::List {
        let groups = arr_of(&r, "groups");
        let world = str_of(&r, "world").unwrap_or("Workspace");
        if groups.is_empty() {
            return Ok(text(format!("No collision groups are registered in {world}.")));
        }
        let rows: Vec<Value> = groups
            .iter()
            .map(|g| json!({ "name": g.get("name"), "passes through": str_of(g, "passesThrough").unwrap_or("?"), "mask": g.get("mask") }))
            .collect();
        let more = match r.get("max").filter(|m| !m.is_null()) {
            None => world.to_string(),
            Some(max) => format!("{world}: {} of {} groups used", groups.len(), disp(Some(max))),
        };
        return Ok(table(&["name", "passes through", "mask"], &rows, PageMeta { more: Some(more), ..Default::default() }));
    }
    Ok(json(&r, None))
}

pub fn tools() -> Vec<Tool> {
    vec![
        define(
            spec("geometry", "Mesh operations").destructive(true),
            "Every operation that reshapes solid geometry, in one place.\n\n\
             **Boolean** - `union` merges parts into one solid, `subtract` cuts the `with` parts out of `path`, \
             `intersect` keeps only the overlap. This is how to build a shape that is not a box without importing a mesh.\n\n\
             **Breaking apart** - `fragment` shatters a part into random debris, for destruction. `segment` is the \
             opposite kind of break: it cuts a MeshPart into parts you NAME, so a solid car mesh becomes a body and four \
             wheels a script can find and turn. Use `fragment` for rubble and `segment` for articulation.\n\n\
             **Motion** - `sweep` builds the volume a part passes through as it moves, which is the only real answer to \
             'does this door hit the wall when it opens'. Give `to` for a slide, or `spin` degrees with a `pivot` for a \
             hinge. Pass `checkAgainst` and it reports what the swept volume overlaps; with `keep: false` it measures and \
             cleans up after itself, leaving nothing behind.\n\n\
             `subtract` and `intersect` need the parts to actually overlap, and they fail differently when they do not. \
             `intersect` returns nothing, which comes back as an error rather than a silent no-op. `subtract` returns the \
             subject UNCHANGED - a full-size copy of it, reported as a created part - because cutting nothing out of \
             something legitimately leaves it whole. So a subtract that succeeds is not proof that anything was cut: \
             check the positions overlap with `inspect` first, or compare the result's size against the original.\n\n\
             Results keep the original's material, colour, texture and anchoring. Roblox returns bare grey MeshParts, so \
             a brick wall with a hole cut in it would otherwise come back as a grey slab - correct geometry that looks \
             like a mistake.\n\n\
             `mesh` reads the real triangle and vertex counts of MeshParts, which is the only way to tell a \
             40,000-triangle tree from a 400-triangle one — they are identical in the Explorer and in Properties, and the \
             difference is whether the place runs on a phone. It also reports mesh size against part size: the same \
             triangles stretched over a bigger object is the usual reason a model costs more than it looks like it \
             should.\n\n\
             `mesh` only works on meshes the signed-in Studio user or the experience owner OWNS. Roblox refuses to open \
             anyone else's, so a model inserted from the Creator Store cannot be measured this way — the tool says which \
             parts were skipped rather than failing the whole batch.\n\n\
             `mirror` flips instances across a plane and has no engine API behind it — Studio simply cannot do this, \
             which is why people ask for it. Mirroring about the middle of the selection is the default, because \
             mirroring a building at x=200 about the world origin puts it 400 studs away rather than flipping it in \
             place. It COPIES by default; pass `copy: false` to flip the originals. MeshParts move and rotate correctly \
             but their meshes are not remade, so an asymmetric mesh still reads the same way round.\n\n\
             `segment` runs Roblox's Cube model and takes tens of seconds; the rest are fast. Each call is one undo step.",
            geometry,
        ),
        define(
            // `publish` replaces the live place and `grant` cannot be revoked.
            spec("assets", "Creator Store").destructive(true),
            "Searches Roblox's Creator Store and inserts models into the place.\n\n\
             `search` looks through the same public index Studio's own asset browser uses. It reports script COUNT, \
             triangles, whether the creator is verified, whether the asset is free, and what Roblox thinks it is \
             (\"Door/Furniture\"). `insert` puts one into the place by id.\n\n\
             Results are ranked by approval WEIGHTED BY vote count, because the raw percentage lies: 100% from two voters \
             outranks 82% from five thousand unless the count is taken into account. The vote count is shown beside the \
             percentage for the same reason.\n\n\
             Filters — `excludeScripts`, `maxTriangles`, `verifiedOnly`, `freeOnly`, `minVotes` — are applied here, not \
             by Roblox, and several pages are fetched to fill the results. Roblox's own sort and creator filters are \
             accepted by the endpoint and silently ignored, so they are not offered.\n\n\
             ALWAYS check `hasScripts` before inserting. Free models carrying scripts are the oldest hazard on the \
             platform, and a model dropped into someone's game can run whatever it likes. The insert reports the script \
             count again, and names them, so it can still be undone.\n\n\
             `peek` is the safer half of that: it loads the asset in memory WITHOUT putting it in the place and tells you \
             exactly what is inside — every class, every script by name. Nothing is parented, so there is nothing to \
             undo. Use it whenever `hasScripts` says YES and the model still looks worth having.\n\n\
             Audio searches take a different path from everything else here. They go to the engine's own audio index, so \
             results carry duration, artist and whether the clip is music or a sound effect — the fields that actually \
             decide which sound you want. They return SOUND EFFECTS by default; pass `audioType: \"Music\"` for tracks. \
             Filter with `minDuration` / `maxDuration` — a footstep is under a second and a music bed is minutes.\n\n\
             Only public assets can be inserted. A private or deleted id fails with a message saying so rather than \
             inserting nothing quietly.\n\n\
             `bake` is unrelated to the Creator Store and does not upload anything. It turns EditableMesh and \
             EditableImage data into static content, which frees the editable memory budget and lets a mesh built at \
             runtime replicate from the server down to clients.\n\n\
             READ THIS BEFORE REACHING FOR IT. What it produces is scoped to the data model session it was made in. \
             Baking in edit mode therefore carries NOTHING into a playtest — a playtest is a new data model, and the \
             content reads as empty there. Measured, not assumed. Its real use is against a RUNNING playtest server \
             session: pass that `studioId`, and baking a mesh the game just built is what lets clients see it.\n\n\
             It does not help `generate` at all. Generated meshes hold opaque content, which the engine refuses to bake.\n\n\
             THE OTHER DIRECTION: `upload` sends a local file TO Roblox and gives you the asset id. Audio, an image, a 3D \
             model or a video, picked by extension — .mp3/.ogg/.wav/.flac, .png/.jpg/.bmp/.tga, .fbx/.gltf/.glb, \
             .mp4/.mov. This closes the one hole nothing else here covers: a sound effect sitting in a folder on disk \
             used to need Studio's import dialog before anything could reference it.\n\n\
             Uploads are moderated and count against a real monthly quota. Do not guess what it is — Roblox's own guide \
             and the live API disagree, and the account's verification level changes it. Ask `op=\"quota\"`. Do not \
             upload speculatively, and do not re-upload to retry: the first one probably worked.\n\n\
             `grant` gives a game or a person permission to use assets you own. You do NOT need this for your own assets \
             in your own game — those always work. It is for a collaborator's place, or a group game you do not own. A \
             grant to a game is PERMANENT; Roblox provides no way to revoke one, so it needs `confirm: true`.\n\n\
             `publish` sends a .rbxl or .rbxlx from disk to a place. It SAVES a new version by default and only goes live \
             with `confirm: true`. Note a real limitation: Roblox's publishing API does not update EditableImage, \
             EditableMesh, PartOperation, SurfaceAppearance or BaseWrap instances, and reports success anyway — publish \
             from Studio if the place uses any of those.\n\n\
             Publishing alone does NOT move anyone already playing — they stay on their server running the old code until \
             it empties. Pass `restart: true` to roll live servers onto the new version, which bleeds them off over 10 \
             minutes rather than dropping players.\n\n\
             `quota` reports how many uploads are left before Roblox starts refusing them, per asset type, read from the \
             account itself. Check it before a batch rather than discovering the ceiling halfway through.\n\n\
             All of these need an Open Cloud API key. The user sets it once by typing `cloud` in the Studio panel; never \
             ask them to paste a key into this conversation.",
            assets,
        ),
        define(
            spec("undo", "Undo and redo").destructive(true),
            "Steps Studio's undo history backwards or forwards.\n\n\
             Every write this server makes is already wrapped in an undo recording, so this reverses your own work as \
             cleanly as the user pressing Ctrl+Z — one tool call is one step. Use it when the user says an edit was \
             wrong, instead of trying to reconstruct the previous state by hand, which is guesswork and usually \
             incomplete.\n\n\
             It reports how many steps actually applied, which is not always what was asked: the stack runs out, and an \
             undo that did nothing otherwise looks exactly like one that worked.\n\n\
             Studio's history covers the whole session, including the user's own edits — undoing more steps than you made \
             will start reverting THEIR work. Undo only what you just did, and only when asked.",
            |ctx, a: UndoArgs| async move {
                let r = call(&ctx, "world.history", json!({ "action": a.action, "steps": a.steps }), a.studio_id.as_deref(), None).await?;
                let note = str_of(&r, "note").map(str::to_string);
                Ok(json(&r, note.as_deref()))
            },
        ),
        define(
            // `remove` unregisters a group, and group changes are not undoable.
            spec("collision", "Collision groups").destructive(true),
            "Controls which parts physically collide with which.\n\n\
             This is the right answer to 'these should pass through each other'. The alternative — turning CanCollide off \
             — disables collision against everything, so a ghost that should pass through walls also falls through the \
             floor.\n\n\
             The order is: `create` a group, `assign` parts to it, then set what it is `collidable` with. A group with \
             nothing assigned does nothing.\n\n\
             Assigning a Model assigns every part inside it, which is almost always what is meant.\n\n\
             Groups are not undoable and not scoped to a session: `remove` when one was created to try something and is \
             no longer wanted, rather than leaving it registered in the place indefinitely. The built-in \"Default\" \
             group cannot be removed.\n\n\
             Groups belong to a world, not to the place. The Workspace is the default and is what nearly every question \
             is about; a `WorldModel` inside a ViewportFrame keeps its own separate registry, so pass `worldModel` to \
             reach that one. A group of the same name in each is two different groups.\n\n\
             THE SAME TOOL ANSWERS WHAT IS ACTUALLY THERE. `cast` fires a ray, block, sphere or an existing part's own \
             shape and reports the first thing it meets — the part, the hit point, the surface normal, the material and \
             the distance. `overlap` lists everything inside a box, a radius, or overlapping an existing part.\n\n\
             That is the one question the Explorer cannot answer. A path tells you an instance exists and where its pivot \
             sits; it does not tell you the door frame is clipping into the wall, that the spawn is buried a stud inside \
             the floor, or that nothing stands between the turret and the player. Geometry wrong in exactly those ways \
             looks perfect in `inspect`.\n\n\
             The queries live here because they ARE collision queries: they honour the very groups the other half of \
             this tool manages. A cast run in the wrong `collisionGroup` reports a clear path through a wall the player \
             cannot walk through — a wrong answer indistinguishable from a right one. A miss comes back as `hit: false`, \
             which is a real answer and usually the one being checked for.",
            collision,
        ),
    ]
}
