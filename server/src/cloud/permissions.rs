//! What agents may do through Open Cloud, chosen by the user per game.
//!
//! Every Open Cloud call names the scope it needs, so the scope decides which
//! group it falls in and the group decides whether it runs. Only reading is on
//! for a game until the user turns more on with `allow <group>` in the Studio
//! panel; an agent cannot change this, because the only way in is the panel.
//!
//! Stored per universe in `~/.rbx-studio-mcp/permissions.json`, next to the
//! credentials and never in the place file.

use super::credentials::DIRECTORY;
use crate::errors::{Result, ToolError};
use serde_json::{Map, Value};
use std::path::PathBuf;
use std::sync::LazyLock;

static FILE: LazyLock<PathBuf> = LazyLock::new(|| DIRECTORY.join("permissions.json"));

pub struct Group {
    pub id: &'static str,
    pub label: &'static str,
    /// Scope prefixes that belong to this group.
    scopes: &'static [&'static str],
    on_by_default: bool,
}

pub const GROUPS: &[Group] = &[
    Group {
        id: "read",
        label: "look at the game: settings, servers, analytics, events",
        scopes: &["universe:read", "universe.place.instance:read", "universe.analytics:", "universe.event:read"],
        on_by_default: true,
    },
    Group {
        id: "assets",
        label: "upload assets and share them",
        scopes: &["assets:", "asset-permissions:"],
        on_by_default: false,
    },
    Group {
        id: "data",
        label: "read and write data stores and ordered data stores",
        scopes: &["universe-datastores.", "universe.ordered-data-store."],
        on_by_default: false,
    },
    Group {
        id: "edit",
        label: "change settings, publish, restart servers, run live Luau, events, messaging",
        scopes: &[
            "universe:write",
            "universe-places:",
            "universe.place.instance:write",
            "universe.place.luau-execution-session:",
            "universe.event:write",
            "universe-messaging-service:",
        ],
        on_by_default: false,
    },
    Group {
        id: "money",
        label: "create and edit developer products and game passes",
        scopes: &["developer-product:", "game-pass:"],
        on_by_default: false,
    },
    Group {
        id: "players",
        label: "look up players and their inventories, ban and unban",
        scopes: &["universe.user-restriction:", "user."],
        on_by_default: false,
    },
];

pub fn find(id: &str) -> Option<&'static Group> {
    GROUPS.iter().find(|g| g.id.eq_ignore_ascii_case(id))
}

/// The group a scope belongs to. Anything unrecognised counts as `edit`, the
/// group that can change the live game, so a new scope is never quietly open.
pub fn group_of(scope: &str) -> &'static Group {
    GROUPS
        .iter()
        .find(|g| g.scopes.iter().any(|p| scope.starts_with(p)))
        .unwrap_or_else(|| find("edit").expect("edit group"))
}

async fn read_all() -> Map<String, Value> {
    match tokio::fs::read(&*FILE).await {
        Ok(bytes) => serde_json::from_slice::<Value>(&bytes).ok().and_then(|v| v.as_object().cloned()).unwrap_or_default(),
        Err(_) => Map::new(),
    }
}

/// Whether `group` is on for `universe`.
pub async fn allowed(universe: &str, group: &Group) -> bool {
    read_all()
        .await
        .get(universe)
        .and_then(|g| g.get(group.id))
        .and_then(Value::as_bool)
        .unwrap_or(group.on_by_default)
}

/// Every group with its state for `universe`, in display order.
pub async fn list(universe: &str) -> Vec<(&'static Group, bool)> {
    let all = read_all().await;
    let game = all.get(universe);
    GROUPS
        .iter()
        .map(|g| (g, game.and_then(|m| m.get(g.id)).and_then(Value::as_bool).unwrap_or(g.on_by_default)))
        .collect()
}

pub async fn set(universe: &str, group: &Group, on: bool) -> std::io::Result<()> {
    let mut all = read_all().await;
    let game = all.entry(universe.to_string()).or_insert_with(|| Value::Object(Map::new()));
    if let Some(map) = game.as_object_mut() {
        map.insert(group.id.into(), Value::Bool(on));
    }
    tokio::fs::create_dir_all(&*DIRECTORY).await?;
    let staging = FILE.with_extension(format!("json.{}.tmp", std::process::id()));
    let mut body = serde_json::to_vec_pretty(&Value::Object(all)).unwrap_or_default();
    body.push(b'\n');
    tokio::fs::write(&staging, body).await?;
    tokio::fs::rename(&staging, &*FILE).await
}

/// The universe a request acts on: named in its path, else the stored one.
pub fn universe_in(path: &str, query: &[(String, String)], stored: Option<&str>) -> Option<String> {
    if let Some(rest) = path.split("/universes/").nth(1) {
        let id: String = rest.chars().take_while(char::is_ascii_digit).collect();
        if !id.is_empty() {
            return Some(id);
        }
    }
    if let Some((_, v)) = query.iter().find(|(k, _)| k == "universeId") {
        return Some(v.clone());
    }
    stored.map(str::to_string)
}

/// Refuses a call whose group the user has not turned on for this game.
pub async fn check(scope: &str, universe: Option<&str>) -> Result<()> {
    let group = group_of(scope);
    let Some(universe) = universe else {
        if group.on_by_default {
            return Ok(());
        }
        return Err(ToolError::hint(
            "PERMISSION_OFF",
            format!("This needs the `{}` permission, and it is not known which game it is for.", group.id),
            "Permissions are set per game. Ask the user to run `cloud universe <id>` in the Studio panel, \
             then `allow <group>` there to turn it on for that game.",
        ));
    };
    if allowed(universe, group).await {
        return Ok(());
    }
    Err(ToolError::hint(
        "PERMISSION_OFF",
        format!("The user has not allowed `{}` for this game (universe {universe}): {}.", group.id, group.label),
        format!(
            "Only the user can turn it on: ask them to type `allow {}` in the Studio panel. Do not try to \
             reach the same result another way, such as through execute_luau.",
            group.id
        ),
    ))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_scope_in_use_lands_in_the_expected_group() {
        let cases = [
            ("universe:read", "read"),
            ("universe.analytics:read", "read"),
            ("universe.event:read", "read"),
            ("assets:write", "assets"),
            ("asset-permissions:write", "assets"),
            ("universe-datastores.objects:read", "data"),
            ("universe.ordered-data-store.scope.entry:write", "data"),
            ("universe:write", "edit"),
            ("universe-places:write", "edit"),
            ("universe.place.luau-execution-session:write", "edit"),
            ("universe.event:write", "edit"),
            ("developer-product:write", "money"),
            ("game-pass:read", "money"),
            ("universe.user-restriction:write", "players"),
            ("user.advanced:read", "players"),
            ("something-new:write", "edit"),
        ];
        for (scope, group) in cases {
            assert_eq!(group_of(scope).id, group, "{scope}");
        }
    }

    #[test]
    fn universe_comes_from_the_path_first() {
        assert_eq!(universe_in("/cloud/v2/universes/123/places/4", &[], Some("9")).as_deref(), Some("123"));
        assert_eq!(universe_in("/datastores/v1/universes/77/standard-datastores", &[], None).as_deref(), Some("77"));
        assert_eq!(universe_in("/assets/v1/assets", &[], Some("9")).as_deref(), Some("9"));
        assert_eq!(universe_in("/assets/v1/assets", &[], None), None);
    }
}
