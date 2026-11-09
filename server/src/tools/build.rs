//! terrain and generate.

use super::{arr_of, call, str_of};
use crate::errors::Result;
use crate::format::{ToolResult, error_text, json, text};
use crate::tool::{Ctx, Tool, define, spec};
use schemars::JsonSchema;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::sync::Arc;

#[derive(Deserialize, JsonSchema, Default, PartialEq, Clone, Copy)]
#[serde(rename_all = "lowercase")]
enum TerrainOp {
    Fill,
    Replace,
    Clear,
    #[default]
    Stats,
    Materials,
}

#[derive(Deserialize, Serialize, JsonSchema, Default, Clone, Copy)]
#[serde(rename_all = "lowercase")]
enum Shape {
    #[default]
    Block,
    Ball,
    Cylinder,
    Wedge,
}

fn grass() -> String {
    "Grass".into()
}

#[derive(Deserialize, Serialize, JsonSchema)]
struct Solid {
    /// Which solid to fill.
    #[serde(default)]
    shape: Shape,
    /// Centre of the solid in studs, e.g. "0, 20, 0".
    position: String,
    /// block and wedge: extent in studs, e.g. "100, 20, 100".
    #[serde(skip_serializing_if = "Option::is_none")]
    size: Option<String>,
    /// ball and cylinder: radius in studs.
    #[serde(skip_serializing_if = "Option::is_none")]
    radius: Option<f64>,
    /// cylinder: height in studs.
    #[serde(skip_serializing_if = "Option::is_none")]
    height: Option<f64>,
    /// Rotation in degrees, e.g. "0, 45, 0". Omit for none.
    #[serde(skip_serializing_if = "Option::is_none")]
    orientation: Option<String>,
    /// Terrain material — Grass, Rock, Sand, Water, Snow, Basalt, Mud, LeafyGrass... Use "Air" to carve out existing terrain.
    #[serde(default = "grass")]
    material: String,
}

#[derive(Deserialize, Serialize, JsonSchema, Clone, Copy, PartialEq)]
#[serde(rename_all = "lowercase")]
enum SlotAction {
    List,
    Set,
    Reset,
}

#[derive(Deserialize, Serialize, JsonSchema)]
struct Slot {
    /// Slot 2-63. set: omit to take the first free slot.
    #[serde(skip_serializing_if = "Option::is_none")]
    #[schemars(range(min = 2, max = 63))]
    slot: Option<u32>,
    /// set: base material, e.g. Grass, Rock.
    #[serde(skip_serializing_if = "Option::is_none")]
    base: Option<String>,
    /// set: MaterialVariant name for custom textures.
    #[serde(skip_serializing_if = "Option::is_none")]
    variant: Option<String>,
    /// set: tint, "#7FA35B" or "r, g, b".
    #[serde(skip_serializing_if = "Option::is_none")]
    color: Option<String>,
}

#[derive(Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
struct TerrainArgs {
    /// 'fill' adds solids (use material Air to carve), 'replace' swaps a material in place, 'clear' empties a region or everything, 'stats' reports what is there.
    #[serde(default)]
    op: TerrainOp,
    /// fill only: the solids to apply, together, as one undo step.
    #[schemars(length(max = 100))]
    shapes: Option<Vec<Solid>>,
    /// replace and clear: centre of the region, e.g. "0, 0, 0".
    position: Option<String>,
    /// replace and clear: extent of the region in studs, e.g. "512, 256, 512".
    size: Option<String>,
    /// replace only: the material to look for.
    from: Option<String>,
    /// replace only: the material to write instead.
    to: Option<String>,
    /// clear only: required to empty ALL terrain. Omit it and give `position`/`size` to clear one region instead.
    confirm: Option<bool>,
    /// materials only: list the slots in use (default), set some, or reset some.
    action: Option<SlotAction>,
    /// materials set/reset: the slots to change.
    #[schemars(length(max = 62))]
    slots: Option<Vec<Slot>>,
    /// Target Studio; omit for the active one.
    studio_id: Option<String>,
}

async fn terrain(ctx: Arc<Ctx>, a: TerrainArgs) -> Result<ToolResult> {
    // The engine rebuilds the voxel mesh before it answers; large regions take seconds.
    let timeout = Some(60_000.0);
    let studio = a.studio_id.as_deref();
    match a.op {
        TerrainOp::Stats => {
            let r = call(&ctx, "terrain.stats", json!({}), studio, timeout).await?;
            let empty = r.get("cells").and_then(Value::as_f64) == Some(0.0);
            Ok(json(&r, empty.then_some("This place has no terrain yet. `fill` a block of Grass to start one.")))
        }
        TerrainOp::Fill => {
            let Some(shapes) = a.shapes.filter(|s| !s.is_empty()) else {
                return Ok(error_text(
                    "fill needs `shapes`, e.g. [{ shape: \"ball\", position: \"0, 10, 0\", radius: 24, material: \"Grass\" }].",
                ));
            };
            let r = call(&ctx, "terrain.fill", json!({ "shapes": shapes }), studio, timeout).await?;
            Ok(json(
                &r,
                Some("Terrain snaps to 4-stud voxels, so take a `screenshot` before building on top of this — the result is blockier than the numbers."),
            ))
        }
        TerrainOp::Replace => {
            let (Some(from), Some(to)) = (&a.from, &a.to) else {
                return Ok(error_text("replace needs `from` and `to`, e.g. from=\"Grass\" to=\"Snow\"."));
            };
            let r = call(&ctx, "terrain.replace", json!({ "position": a.position, "size": a.size, "from": from, "to": to }), studio, timeout).await?;
            Ok(json(&r, None))
        }
        TerrainOp::Materials => {
            let action = a.action.unwrap_or(SlotAction::List);
            let name = match action {
                SlotAction::List => "list",
                SlotAction::Set => "set",
                SlotAction::Reset => "reset",
            };
            if action != SlotAction::List && a.slots.as_ref().is_none_or(Vec::is_empty) {
                return Ok(error_text(format!("materials {name} needs `slots`, e.g. [{{ base: \"Grass\", color: \"#5E8C3A\" }}].")));
            }
            if action == SlotAction::Set && a.slots.as_ref().is_some_and(|s| s.iter().any(|x| x.base.is_none())) {
                return Ok(error_text("materials set needs a `base` material on every slot."));
            }
            let r = call(&ctx, "terrain.materials", json!({ "action": action, "slots": a.slots }), studio, timeout).await?;
            let quiet = action == SlotAction::List || str_of(&r, "expandedTerrain") == Some("Enabled");
            Ok(json(&r, (!quiet).then_some("Custom slots only render once Workspace.ExpandedTerrain is Enabled and the place is reopened.")))
        }
        TerrainOp::Clear => {
            let r = call(&ctx, "terrain.clear", json!({ "position": a.position, "size": a.size, "confirm": a.confirm }), studio, timeout).await?;
            Ok(json(&r, None))
        }
    }
}

#[derive(Deserialize, Serialize, JsonSchema, Default, Clone, Copy)]
enum GenSchema {
    #[default]
    Body1,
    Car5,
}

#[derive(Deserialize, Serialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
struct GenerateArgs {
    /// What to generate, e.g. "a weathered stone well".
    #[serde(skip_serializing_if = "Option::is_none")]
    prompt: Option<String>,
    /// How to split the result. Ignored when `groups` is given.
    #[serde(default)]
    schema: GenSchema,
    /// Custom part names to split into, e.g. ["body", "lid"]. Overrides `schema`.
    #[serde(skip_serializing_if = "Option::is_none")]
    #[schemars(length(max = 16))]
    groups: Option<Vec<String>>,
    /// An image asset id to condition the generation on.
    #[serde(skip_serializing_if = "Option::is_none")]
    #[schemars(range(min = 1))]
    image_asset_id: Option<u64>,
    /// Suggested size as "x, y, z". Approximate — use `scaleTo` for exact.
    #[serde(skip_serializing_if = "Option::is_none")]
    size: Option<String>,
    /// Cap the triangle count. Lower is more faceted. Default is about 10000.
    #[serde(skip_serializing_if = "Option::is_none")]
    #[schemars(range(min = 100, max = 100000))]
    max_triangles: Option<u32>,
    /// Generate textures. Off gives bare geometry.
    #[serde(default = "super::d::t")]
    textures: bool,
    /// Scale the result so its longest side is this many studs.
    #[serde(skip_serializing_if = "Option::is_none")]
    #[schemars(range(min = 0.000001))]
    scale_to: Option<f64>,
    /// Name for the model.
    #[serde(skip_serializing_if = "Option::is_none")]
    name: Option<String>,
    /// Where to put it. Defaults to Workspace.
    #[serde(skip_serializing_if = "Option::is_none")]
    parent: Option<String>,
    /// Where to place it, e.g. "0, 10, 0".
    #[serde(skip_serializing_if = "Option::is_none")]
    position: Option<String>,
    /// Anchor every part. Turn off only if physics should act on it.
    #[serde(default = "super::d::t")]
    anchor: bool,
    /// Target Studio; omit for the active one.
    #[serde(skip_serializing)]
    studio_id: Option<String>,
}

async fn generate(ctx: Arc<Ctx>, a: GenerateArgs) -> Result<ToolResult> {
    // Past what the service tolerates: a timeout should mean it gave up, not us.
    let r = call(&ctx, "generate.model", serde_json::to_value(&a)?, a.studio_id.as_deref(), Some(240_000.0)).await?;
    let parts: Vec<&str> = arr_of(&r, "parts").iter().filter_map(Value::as_str).collect();
    let mut lines = vec![
        format!(
            "{}  ({}, {} studs)",
            str_of(&r, "path").unwrap_or(""),
            str_of(&r, "schema").unwrap_or(""),
            str_of(&r, "size").unwrap_or("")
        ),
        if parts.is_empty() { "Parts: none".into() } else { format!("Parts: {}", parts.join(", ")) },
    ];
    if r.get("anchored") != Some(&Value::Bool(true)) {
        lines.push("Left unanchored, so physics will move it.".into());
    }
    if r.get("undoable") != Some(&Value::Bool(true)) {
        lines.push("Studio would not open an undo recording, so this is not one Ctrl+Z.".into());
    }
    if let Some(uuid) = str_of(&r, "uuid").filter(|u| !u.is_empty()) {
        lines.push(format!("Generation {uuid}."));
    }
    Ok(text(lines.join("\n")))
}

pub fn tools() -> Vec<Tool> {
    vec![
        define(
            spec("terrain", "Build and edit terrain").destructive(true),
            "Fills, repaints and clears Roblox terrain — hills, water, caves, roads.\n\n\
             Terrain is not made of instances, so none of the instance tools reach it: there is nothing to `create`, no \
             path for `find`, and no property for `modify`. This is the only way to shape it short of writing FillBall \
             calls by hand through `execute_luau`.\n\n\
             `fill` takes an ARRAY of solids and applies them as one undo step, which is how terrain is actually built: \
             a hill is several overlapping balls, a road is a row of blocks. Shapes are `block` (needs `size`), `ball` \
             (needs `radius`), `cylinder` (needs `radius` and `height`) and `wedge` (needs `size`).\n\n\
             To CARVE, fill with material `Air`. That is not a special mode — a cave is a ball of Air inside a hill, and \
             a tunnel is a row of them.\n\n\
             `replace` swaps one material for another inside a region and leaves the shape alone, which is how you turn \
             a grass hill to snow without rebuilding it. `clear` empties a region, or everything with confirm=true. \
             `stats` says whether the place uses terrain at all -- call it first in an unfamiliar place. It cannot say \
             WHERE the terrain is: Roblox exposes no bounding box for it. Take a `screenshot` to see the shape.\n\n\
             Positions are the centre of the solid, in studs, as \"x, y, z\". Terrain snaps to a 4-stud voxel grid, so \
             small features come out blockier than the numbers suggest; nothing thinner than about 4 studs survives.\n\n\
             `materials` manages the place's custom terrain materials: 64 slots, each a base material plus an optional \
             MaterialVariant and a tint. `action` list | set | reset. Slot writes are NOT undoable, so each result \
             reports the slot's `previous` value. Painting with a custom slot is done in the Terrain Editor; Roblox does \
             not let plugins fill by slot.",
            terrain,
        ),
        define(
            spec("generate", "Generate 3D models").destructive(true),
            "Makes 3D geometry from a text prompt, using Roblox's Cube model.\n\n\
             THE SCHEMA IS THE IMPORTANT ARGUMENT. It decides how the result is broken up, and it cannot be changed \
             afterwards without another generation:\n\
             - `Body1` — one MeshPart. Right for props: a crate, a tree, a lamp.\n\
             - `Car5` — a body and four wheels, under the fixed names `body`, `front left wheel`, `front right wheel`, \
             `rear left wheel`, `rear right wheel`. Right for anything that has to drive, because a script can find the \
             wheels by name.\n\
             - `groups` — your own list of part names, for a structure the two predefined schemas do not cover.\n\n\
             Asking for a car under `Body1` gives you a car-shaped rock. It looks right and nothing can be articulated. \
             If you only realise afterwards, `geometry op=\"segment\"` cuts an existing mesh into named parts without \
             generating it again.\n\n\
             Expect tens of seconds per call. The service is metered and moderated: a rejected prompt and a rate limit \
             both come back as a failure that says which, so read the hint before retrying.\n\n\
             `imageAssetId` conditions the generation on a picture — supply it with a prompt or instead of one. `size` \
             suggests proportions and `maxTriangles` caps the poly count (low values give a faceted, low-poly look). \
             Results are anchored on arrival, because a multi-part model dropped into the workspace unanchored falls \
             apart.\n\n\
             EDIT MODE ONLY, for now. A generated mesh does not survive into a playtest: inside one, its MeshContent and \
             TextureContent read as empty. `assets op=\"bake\"` does not fix this — the engine refuses to bake the kind \
             of content generation produces. So generate for building and greyboxing, and do not rely on a generated \
             mesh being visible in a test or after a reopen until it has been published as a real asset.",
            generate,
        ),
    ]
}
