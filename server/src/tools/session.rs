//! studio_status, list_studios, set_active_studio.

use super::{STUDIO_DOC, str_of};
use crate::format::{ToolResult, json, text};
use crate::protocol::{StudioSession, plugin_staleness_notice, plugin_staleness_warning, protocol_mismatch_warning};
use crate::tool::{Tool, define, spec};
use schemars::JsonSchema;
use serde::Deserialize;
use serde_json::{Map, Value, json};
use std::collections::BTreeSet;

#[derive(Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
struct StatusArgs {
    /// Target a specific Studio instance. Omit to use the active one (see list_studios / set_active_studio).
    studio_id: Option<String>,
}

#[derive(Deserialize, JsonSchema)]
struct NoArgs {}

#[derive(Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
struct SetActiveArgs {
    /// A studioId from list_studios.
    #[schemars(length(min = 1))]
    studio_id: String,
}

/// What to tell the agent when a listing leaves no default target.
fn listing_hint(sessions: &[StudioSession], active: Option<&str>) -> Option<String> {
    if active.is_some() || sessions.len() <= 1 {
        return None;
    }
    Some(if crate::bridge::one_editor(sessions.iter().map(|s| &s.identity)) {
        "This is one place with a playtest running, not two places — do not ask the user which they mean. \
         Pass `studioId` explicitly: the *edit* session for anything that must outlive the playtest, the \
         *playtest* session for the running game. A playtest server with a different placeId is a teleport \
         destination inside the same test."
            .into()
    } else {
        "Several places are open and none is selected. Ask the user which one they mean, then call set_active_studio.".into()
    })
}

pub fn tools() -> Vec<Tool> {
    let _ = STUDIO_DOC;
    vec![
        define(
            spec("studio_status", "Studio status").read_only(),
            "One-call snapshot of the connected Roblox Studio: place name and id, whether it is in edit / run / play \
             mode, the current selection, which scripts are open in the editor, and how big the data model is.\n\n\
             Call this FIRST in any Studio session, and again whenever a tool reports NO_STUDIO or TIMEOUT — it is \
             the cheapest way to tell a disconnected plugin apart from a genuinely failing request. Also call it \
             before and after `playtest`, because most tools behave differently in run mode.\n\n\
             `openScripts` is what the user is actually working on: for each open tab it gives the script's path, \
             the cursor line, any selected text, and which lines are on screen. Use it whenever a request is \
             deictic — 'this function', 'the script I'm in', 'fix this' — instead of searching the place or asking \
             which file they mean. Studio exposes no focused-tab API, so with several open, prefer the one holding \
             a selection and otherwise ask.\n\n\
             Returns JSON. Selection is capped at 50 entries and selected text at 400 characters; use `find` or \
             `script_read` for more.",
            |ctx, args: StatusArgs| async move {
                let studio = args.studio_id.as_deref();
                // Independent reads, so they run together.
                let (status, view) = tokio::join!(
                    ctx.bridge.call("studio.status", json!({}), studio, None),
                    ctx.bridge.sessions()
                );
                let status = status?;
                let view = view?;
                let target = args.studio_id.clone().or(view.active_id.clone());
                if let Some(id) = target.clone() {
                    let bridge = ctx.bridge.clone();
                    let name = str_of(&status, "placeName").unwrap_or("").to_string();
                    let context = str_of(&status, "context").map(str::to_string);
                    tokio::spawn(async move { bridge.note_place_name(&id, &name, context.as_deref()).await });
                }
                let session = view.list.iter().find(|s| Some(&s.identity.studio_id) == target.as_ref());
                let warnings: Vec<String> = [
                    plugin_staleness_notice(session.map(|s| s.identity.build_id.as_str())),
                    session.and_then(|s| protocol_mismatch_warning(s.identity.protocol_version)),
                ]
                .into_iter()
                .flatten()
                .collect();
                let note = (!warnings.is_empty()).then(|| format!("WARNING: {}", warnings.join(" ")));
                Ok(json(&status, note.as_deref()))
            },
        ),
        define(
            spec("list_studios", "List connected Studios").read_only(),
            "Lists every Roblox Studio window currently connected to this server, with its studioId, place name, \
             transport (sse or poll), when it connected, and which one is active.\n\n\
             Call this whenever a tool reports AMBIGUOUS_STUDIO, and whenever the user refers to 'the other place' \
             or 'my other window'. With a single Studio open every other tool targets it automatically, so you can \
             skip it then.\n\n\
             Nothing is targeted by default when several are connected: pick one with `set_active_studio`, or pass \
             `studioId` to a single tool call to act on one place without changing the default.\n\n\
             Each Studio is queried live, so `placeName` is the published name the user would recognise. A place \
             never saved to Roblox has no published name and falls back to its data model name ('Place1').\n\n\
             `context` matters more than it looks. Pressing Play adds a second entry for the playtest's server — \
             same place, same name, same id as the editor session. Instances created or changed in a 'playtest' \
             context are thrown away the moment the user stops, so building there looks like it worked and then \
             vanishes. Target 'edit' unless the user specifically wants to inspect or affect the running game.",
            |ctx, _: NoArgs| async move { list_studios(&ctx).await },
        ),
        define(
            spec("set_active_studio", "Set active Studio").destructive(false).idempotent(true),
            "Chooses which connected Studio window every other tool targets by default. Use it after list_studios \
             when several places are open, and again whenever the user says to switch to another place.\n\n\
             The choice persists until it is changed or that Studio disconnects. While several Studios are connected \
             and none has been chosen, tools refuse with AMBIGUOUS_STUDIO rather than guessing.\n\n\
             The choice belongs to this MCP connection alone. Several agents can share one Studio, and each keeps its \
             own target, so calling this never moves another client's — two editors, or two sessions, can work on \
             two places at once.\n\n\
             SUBAGENTS SHARE THEIR PARENT'S CONNECTION, and therefore its target. A subagent calling this retargets \
             its parent and every sibling, and the damage is silent: later calls that name no studioId still \
             succeed, just against the wrong place — and if that place is a playtest, everything written there is \
             discarded when it stops. Inside a subagent, pass `studioId` on each call instead of calling this.",
            |ctx, args: SetActiveArgs| async move {
                ctx.bridge.set_active(&args.studio_id).await?;
                let sessions = ctx.bridge.sessions().await?;
                let session = sessions.list.iter().find(|s| s.identity.studio_id == args.studio_id);
                let status = ctx.bridge.call("studio.status", json!({}), Some(&args.studio_id), Some(3_000.0)).await.ok();
                let context = status.as_ref().and_then(|s| str_of(s, "context")).filter(|c| *c != "edit");
                let name = status
                    .as_ref()
                    .and_then(|s| str_of(s, "placeName"))
                    .map(str::to_string)
                    .or_else(|| session.map(|s| s.identity.place_name.clone()))
                    .unwrap_or_else(|| args.studio_id.clone());
                let mut out = format!(
                    "Active Studio is now \"{name}\"{}.",
                    context.map(|c| format!(" ({c})")).unwrap_or_default()
                );
                if context.is_some() {
                    out.push_str("\nThis is a running playtest, not the editor. Changes made here are discarded when the user stops it.");
                }
                Ok(text(out))
            },
        ),
    ]
}

async fn list_studios(ctx: &crate::tool::Ctx) -> crate::errors::Result<ToolResult> {
    let view = ctx.bridge.sessions().await?;
    let sessions = view.list;
    if sessions.is_empty() {
        return Ok(text(
            "No Studio instances are connected.\nOpen Roblox Studio with the companion plugin installed — it \
             connects automatically on load — then call this again.",
        ));
    }
    let active = if view.active_is_chosen || sessions.len() == 1 { view.active_id.clone() } else { None };

    // Each Studio is asked live for its published name and open scripts.
    let detail = futures::future::join_all(sessions.iter().map(|s| {
        let bridge = ctx.bridge.clone();
        let id = s.identity.studio_id.clone();
        let fallback = s.identity.place_name.clone();
        async move {
            match bridge.call("studio.status", json!({}), Some(&id), Some(3_000.0)).await {
                Ok(status) => {
                    let name = str_of(&status, "placeName").unwrap_or("").to_string();
                    let context = str_of(&status, "context").map(str::to_string);
                    bridge.note_place_name(&id, &name, context.as_deref()).await;
                    let mut m = Map::new();
                    m.insert("placeName".into(), Value::String(name));
                    if let Some(c) = context {
                        m.insert("context".into(), Value::String(c));
                    }
                    let open: Vec<Value> = super::arr_of(&status, "openScripts")
                        .iter()
                        .filter_map(|s| s.get("path").cloned())
                        .collect();
                    m.insert("openScripts".into(), Value::Array(open));
                    m
                }
                Err(_) => {
                    let mut m = Map::new();
                    m.insert("placeName".into(), Value::String(fallback));
                    m.insert("unreachable".into(), Value::Bool(true));
                    m
                }
            }
        }
    }))
    .await;

    let builds: BTreeSet<&str> = sessions.iter().map(|s| s.identity.build_id.as_str()).collect();
    let notices: Vec<String> = builds
        .iter()
        .filter(|b| plugin_staleness_warning(Some(b)).is_some())
        .filter_map(|b| plugin_staleness_notice(Some(b)))
        .collect();
    let disagreement = (builds.len() > 1).then(|| {
        let parts: Vec<String> = sessions
            .iter()
            .zip(&detail)
            .map(|(s, d)| format!("{} {}", d.get("context").and_then(Value::as_str).unwrap_or("session"), s.identity.build_id))
            .collect();
        format!(
            "The connected sessions are running DIFFERENT plugin builds ({}). A playtest session keeps the plugin it \
             loaded when the test started, so the same call can behave differently depending on which you target. \
             Stop the playtest and start it again to bring them into line.",
            parts.join(", ")
        )
    });
    let note = super::join_notes(
        [
            (!notices.is_empty()).then(|| format!("WARNING: {}", notices.join(" "))),
            disagreement.map(|d| format!("WARNING: {d}")),
            listing_hint(&sessions, active.as_deref()),
        ],
        "\n\n",
    );

    let studios: Vec<Value> = sessions
        .iter()
        .zip(detail)
        .map(|(s, d)| {
            let id = &s.identity;
            let mut row = Map::new();
            row.insert("studioId".into(), json!(id.studio_id));
            row.extend(d);
            row.insert("placeId".into(), json!(id.place_id));
            row.insert("connectedAt".into(), json!(crate::tools::iso(s.connected_at)));
            row.insert("transport".into(), json!(id.transport));
            row.insert("pluginVersion".into(), json!(id.plugin_version));
            row.insert("buildId".into(), json!(id.build_id));
            row.insert("stale".into(), json!(plugin_staleness_warning(Some(&id.build_id)).is_some()));
            row.insert(
                "protocolMismatch".into(),
                protocol_mismatch_warning(id.protocol_version).map(Value::String).unwrap_or(Value::Bool(false)),
            );
            row.insert("active".into(), json!(Some(&id.studio_id) == active.as_ref()));
            Value::Object(row)
        })
        .collect();
    Ok(json(&json!({ "studios": studios, "activeStudioId": active }), note.as_deref()))
}

#[cfg(test)]
mod tests {
    #[test]
    fn iso_dates() {
        assert_eq!(crate::tools::iso(0), "1970-01-01T00:00:00.000Z");
        assert_eq!(crate::tools::iso(1_700_000_000_123), "2023-11-14T22:13:20.123Z");
    }
}
