//! character: drive the player in a running playtest.

use super::{arr_of, call, disp, str_of};
use crate::errors::Result;
use crate::format::{PageMeta, ToolResult, json, table, text};
use crate::tool::{Ctx, Tool, define, spec};
use schemars::JsonSchema;
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value, json};
use std::sync::Arc;

#[derive(Deserialize, JsonSchema, PartialEq, Clone, Copy)]
#[serde(rename_all = "camelCase")]
enum CharOp {
    MoveTo,
    Path,
    Act,
    State,
}

#[derive(Deserialize, Serialize, JsonSchema, Clone, Copy)]
#[serde(rename_all = "lowercase")]
enum Action {
    Jump,
    Stop,
    Sit,
    Stand,
    Respawn,
    Kill,
    Teleport,
    Equip,
    Activate,
    Unequip,
}

#[derive(Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
struct CharArgs {
    /// 'moveTo' walks somewhere, 'path' checks a route without walking it, 'act' performs an action, 'state' only reports.
    op: CharOp,
    /// Target position, e.g. "25, 5, -10". Used by moveTo and by teleport.
    to: Option<String>,
    /// moveTo only: walk to this instance instead of a coordinate.
    path: Option<String>,
    /// path only: where the route starts, e.g. "0, 5, 0". Defaults to the character.
    from: Option<String>,
    /// path only: an instance to start from, e.g. "Workspace.SpawnLocation".
    from_path: Option<String>,
    /// path only: an instance to end at instead of `to`.
    to_path: Option<String>,
    /// How wide the walker is, in studs. Defaults to 2 — a standard character. Raise it to ask whether a bigger NPC fits through the same gaps a player does.
    #[schemars(range(min = 0.1, max = 50))]
    agent_radius: Option<f64>,
    /// How tall the walker is. Defaults to 5, a standard character.
    #[schemars(range(min = 0.1, max = 100))]
    agent_height: Option<f64>,
    /// Whether it may climb truss. Off by default.
    can_climb: Option<bool>,
    /// Studs between waypoints, default 4. Tighter follows the geometry more closely; wider is a coarser route.
    #[schemars(range(min = 0.1, max = 100))]
    spacing: Option<f64>,
    /// Material or PathfindingModifier label → cost, e.g. { "Water": 20 } to avoid swimming. Higher is more avoided; the route chosen is the cheapest total, not the shortest.
    costs: Option<Map<String, Value>>,
    /// moveTo only: walk straight at the target without pathfinding. Use when a route is reported unreachable but you want to see what happens.
    #[serde(default)]
    direct: bool,
    /// moveTo only: allow the path to include jumps.
    #[serde(default = "super::d::t")]
    can_jump: bool,
    /// act only: what to do. 'equip' takes a Tool from the Backpack or StarterPack, 'activate' uses it (what a mouse click triggers).
    action: Option<Action>,
    /// equip only: the Tool's name.
    tool: Option<String>,
    /// Which player, by name. Omit for the only one; needed in a multiplayer test.
    player: Option<String>,
    /// The PLAYTEST session's id — not the editor's. See list_studios.
    studio_id: Option<String>,
}

async fn character(ctx: Arc<Ctx>, a: CharArgs) -> Result<ToolResult> {
    let studio = a.studio_id.as_deref();
    // One agent shape for both ops, so a route `path` approves is one `moveTo` walks.
    let agent = |mut m: Value| {
        for (k, v) in [
            ("agentRadius", json!(a.agent_radius)),
            ("agentHeight", json!(a.agent_height)),
            ("canJump", json!(a.can_jump)),
            ("canClimb", json!(a.can_climb)),
            ("spacing", json!(a.spacing)),
            ("costs", json!(a.costs)),
        ] {
            m[k] = v;
        }
        m
    };
    match a.op {
        CharOp::Path => {
            let r = call(
                &ctx,
                "character.path",
                agent(json!({ "from": a.from, "fromPath": a.from_path, "to": a.to, "toPath": a.to_path })),
                studio,
                Some(30_000.0),
            )
            .await?;
            if r.get("reachable") != Some(&Value::Bool(true)) {
                return Ok(text(format!(
                    "No route: {}.\n{} → {} is {} studs apart in a straight line, but nothing walkable connects them for an agent this size.\n\n{}",
                    disp(r.get("status")),
                    disp(r.get("from")),
                    disp(r.get("to")),
                    disp(r.get("straightLineDistance")),
                    disp(r.get("hint"))
                )));
            }
            let detour = r.get("detour").and_then(Value::as_f64).unwrap_or(0.0);
            let jumps = r.get("jumps").and_then(Value::as_f64).unwrap_or(0.0);
            let mut lines = vec![format!(
                "Reachable — {} studs walked vs {} straight (detour {}x), {} waypoints, {} jump(s).",
                disp(r.get("pathDistance")),
                disp(r.get("straightLineDistance")),
                disp(r.get("detour")),
                disp(r.get("waypointCount")),
                disp(r.get("jumps"))
            )];
            if detour > 2.0 {
                lines.push(String::new());
                lines.push(
                    "That is a long way round for the distance. Something between the two points is forcing a detour — worth a look if it was meant to be a direct route."
                        .into(),
                );
            }
            if jumps > 0.0 {
                lines.push(String::new());
                lines.push(format!(
                    "{} jump(s) on this route. Anything that cannot jump — a vehicle, an NPC with jumping disabled — cannot follow it.",
                    disp(r.get("jumps"))
                ));
            }
            lines.push(String::new());
            lines.push(
                table(
                    &["index", "action", "position", "label"],
                    arr_of(&r, "waypoints"),
                    PageMeta { more: Some("walking waypoints between these are omitted".into()), ..Default::default() },
                )
                .text_of(),
            );
            Ok(text(lines.join("\n")))
        }
        CharOp::MoveTo => {
            // The handler waits for each waypoint, so long routes are slow.
            let r = call(
                &ctx,
                "character.moveTo",
                agent(json!({ "to": a.to, "path": a.path, "direct": a.direct, "player": a.player })),
                studio,
                Some(60_000.0),
            )
            .await?;
            let mut notes = Vec::new();
            if let Some(n) = str_of(&r, "note") {
                notes.push(n.to_string());
            }
            if r.get("arrived") != Some(&Value::Bool(true))
                && r.get("note").is_none_or(Value::is_null)
                && str_of(&r, "pathStatus") == Some("Enum.PathStatus.Success")
            {
                notes.push(
                    "The path was valid but the character did not reach the end — something is physically in the way, or it fell. Take a `screenshot` to see where it stopped."
                        .into(),
                );
            }
            let note = (!notes.is_empty()).then(|| notes.join(" "));
            Ok(json(&r, note.as_deref()))
        }
        CharOp::Act => {
            let action = a.action.map(|x| serde_json::to_value(x).unwrap_or_default()).unwrap_or(json!("jump"));
            let r = call(&ctx, "character.act", json!({ "action": action, "to": a.to, "tool": a.tool, "player": a.player }), studio, None).await?;
            Ok(json(&r, None))
        }
        CharOp::State => {
            let r = call(&ctx, "character.state", json!({ "player": a.player }), studio, None).await?;
            Ok(json(&r, None))
        }
    }
}

pub fn tools() -> Vec<Tool> {
    vec![define(
        spec("character", "Drive the player during a playtest").destructive(false),
        "Moves and acts as the player character in a running playtest, so gameplay can be tested without asking the \
         user to play it.\n\n\
         `moveTo` walks to a position or to an instance, following a path computed around walls and gaps rather than a \
         straight line into them. It reports whether it ACTUALLY ARRIVED and how far short it stopped — a route blocked \
         by something you did not know about otherwise looks identical to a successful walk.\n\n\
         `act` does the one-shot things worth testing: jump, sit, stand, respawn, kill (to exercise the death and \
         respawn path), teleport, and `equip`/`activate` to use a Tool — which is how combat gets tested, since Activate \
         is exactly what a mouse click triggers. Note that teleport skips everything in between, so triggers and \
         collisions along the route do not fire — walk if you are testing those.\n\n\
         `state` reports position, health, walk speed and what the humanoid is doing. Call it before and after anything \
         else here.\n\n\
         This drives the Humanoid directly rather than simulating keystrokes, which is the right tool for going places: \
         pathfinding around a wall is one call here and a sequence of guessed key presses otherwise. For anything bound \
         to a control rather than to movement — does E open the door, does the sprint key work, does Escape close the \
         menu — use `input`, which sends real key and mouse events.\n\n\
         REQUIRES A RUNNING PLAYTEST, and the character lives in the playtest's data model — address these to the \
         playtest's studioId from `list_studios`, not the editor's. Run mode has no character at all; use `playtest \
         op=play`.",
        character,
    )]
}
