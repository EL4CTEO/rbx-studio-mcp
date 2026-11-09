//! datastore: the game's saved data, through Studio or straight from Roblox.

use super::{arr_of, call, str_of};
use crate::cloud::{self, Target, live};
use crate::errors::{Result, ToolError};
use crate::format::{PageMeta, ToolResult, json, table, text};
use crate::tool::{Ctx, Tool, define, spec};
use schemars::JsonSchema;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::sync::Arc;

#[derive(Deserialize, JsonSchema, Default, PartialEq, Clone, Copy)]
#[serde(rename_all = "lowercase")]
enum Where {
    #[default]
    Studio,
    Live,
}

#[derive(Deserialize, Serialize, JsonSchema, Default, PartialEq, Clone, Copy)]
#[serde(rename_all = "lowercase")]
enum Op {
    #[default]
    List,
    Get,
    Versions,
    Set,
    Remove,
    Increment,
    Snapshot,
}

#[derive(Deserialize, Serialize, JsonSchema, Default, PartialEq, Clone, Copy)]
#[serde(rename_all = "lowercase")]
enum Kind {
    #[default]
    Data,
    Memory,
    Ordered,
}

#[derive(Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
struct Args {
    /// 'studio' reads through the connected Studio — right while building. 'live' goes to Roblox over Open Cloud and sees what the published game's servers see — right for a bug report.
    #[serde(default)]
    target: Where,
    /// live only: which game. Omit to use the one set with `cloud universe <id>` in the panel.
    universe_id: Option<String>,
    /// live increment only: how much to add. Negative subtracts. Safer than get-then-set for currency, which loses whatever the player earned in between.
    amount: Option<f64>,
    /// live set only: allow writing a key that does not exist yet. Off by default — Open Cloud separates create from update, and a typo'd key silently creating a second empty save beside the real one is exactly what looks like a player's data resetting.
    create: Option<bool>,
    /// 'list' shows stores (no `store`) or a store's keys (with one). 'versions' is DataStore only and is how you see a key's history.
    #[serde(default)]
    op: Op,
    /// 'data' = DataStoreService, permanent and versioned. 'memory' = MemoryStoreService, shared and expiring. They are separate storage — a key in one is not in the other.
    #[serde(default)]
    kind: Kind,
    /// Data store name, or the sorted map's name for memory. Omit on `list` to see which stores exist.
    store: Option<String>,
    /// DataStore scope, if the game uses them. Omit for the default — but if a store reads as empty and you expected data, a scope is the usual reason.
    scope: Option<String>,
    /// The key. Usually the player's UserId as a string.
    key: Option<String>,
    /// set only: the new value as JSON — {"coins":10}, 42, or a bare string. Read the key first and edit what comes back rather than writing a value from scratch: a save is usually a whole table and writing part of one deletes the rest.
    value: Option<String>,
    /// get only: read this exact version instead of the current value. From `versions`.
    version: Option<String>,
    /// get only: read the version that was current at this Unix time in MILLISECONDS. Use when the player says when it broke but no version id is known.
    at: Option<f64>,
    /// memory set only: seconds before the value expires. Defaults to an hour.
    #[schemars(range(min = 1, max = 3888000))]
    ttl: Option<u32>,
    /// list only: only names starting with this.
    prefix: Option<String>,
    /// list only: continue from a previous call's cursor.
    cursor: Option<String>,
    /// list/versions only: rows to return. Defaults to 50.
    #[schemars(range(min = 1, max = 200))]
    limit: Option<usize>,
    /// Required for set and remove on kind="data". This is real player data and nothing here can put it back.
    confirm: Option<bool>,
    /// Target Studio; omit for the active one.
    studio_id: Option<String>,
}

fn op_name(op: Op) -> &'static str {
    match op {
        Op::List => "list",
        Op::Get => "get",
        Op::Versions => "versions",
        Op::Set => "set",
        Op::Remove => "remove",
        Op::Increment => "increment",
        Op::Snapshot => "snapshot",
    }
}

async fn live_path(ctx: &Ctx, a: &Args) -> Result<ToolResult> {
    if a.kind == Kind::Memory {
        return Err(ToolError::hint(
            "UNSUPPORTED",
            "MemoryStore over Open Cloud is not wired up here yet (target=\"live\").",
            "Use target=\"studio\" for now. Roblox does expose memory stores over Open Cloud (queues and sorted maps under \
             /cloud/v2/universes/.../memory-store), it simply has no route through this tool yet — so this is a gap \
             here, not a platform limit.",
        ));
    }
    let op = op_name(a.op);
    if matches!(a.op, Op::Set | Op::Remove | Op::Increment) && a.confirm != Some(true) {
        return Err(ToolError::hint(
            "NEEDS_CONFIRM",
            format!("A live {op} changes the data of players in the running game."),
            "Nothing here can undo it. Read the key first, then pass confirm: true.",
        ));
    }
    let credentials = cloud::require_credentials().await?;
    let universe = cloud::require_universe(a.universe_id.as_deref()).await?;
    cloud::assert_targets_open_place(
        &ctx.bridge,
        Target { universe_id: Some(&universe), place_id: None, explicit: a.universe_id.is_some(), studio_id: a.studio_id.as_deref() },
    )
    .await?;
    let ordered = a.kind == Kind::Ordered;
    let result = cloud::data::run(
        &credentials,
        cloud::data::Args {
            op,
            ordered,
            universe: &universe,
            store: a.store.as_deref(),
            scope: a.scope.as_deref(),
            key: a.key.as_deref(),
            value: a.value.as_deref(),
            amount: a.amount,
            limit: a.limit.unwrap_or(50),
            cursor: a.cursor.as_deref(),
            create: a.create == Some(true),
        },
    )
    .await?;
    if let Some(items) = result.get("items").and_then(Value::as_array) {
        if items.is_empty() {
            return Ok(text(if ordered {
                format!(
                    "{} has no entries in scope \"{}\". An ordered store written with no scope lands in \"global\"; one written with a scope is invisible from any other.",
                    a.store.as_deref().unwrap_or(""),
                    a.scope.as_deref().unwrap_or("global")
                )
            } else if a.store.is_none() {
                format!("Universe {universe} has no data stores.")
            } else {
                format!(
                    "Nothing in {}. Check the `scope` — keys written under one are invisible without it.",
                    a.store.as_deref().unwrap_or("")
                )
            }));
        }
        let columns: &[&str] = if ordered {
            &["rank", "key", "value"]
        } else if a.op == Op::Versions {
            &["version", "created", "deleted"]
        } else if a.store.is_none() {
            &["store", "created", "state"]
        } else {
            &["key", "state"]
        };
        let more = (result.get("truncated") == Some(&Value::Bool(true))).then(|| "more available — raise `limit`".to_string());
        return Ok(table(columns, items, PageMeta { more, ..Default::default() }));
    }
    Ok(json(&result, None))
}

async fn datastore(ctx: Arc<Ctx>, a: Args) -> Result<ToolResult> {
    if a.op == Op::Snapshot {
        let universe = cloud::require_universe(a.universe_id.as_deref()).await?;
        cloud::assert_targets_open_place(
            &ctx.bridge,
            Target { universe_id: Some(&universe), place_id: None, explicit: a.universe_id.is_some(), studio_id: a.studio_id.as_deref() },
        )
        .await?;
        let creds = cloud::require_credentials().await?;
        return Ok(json(&live::snapshot_data_stores(&creds, &universe).await?, None));
    }
    if a.target == Where::Live {
        return live_path(&ctx, &a).await;
    }
    if a.kind == Kind::Ordered {
        return Err(ToolError::hint(
            "UNSUPPORTED",
            "kind=\"ordered\" only works with target=\"live\".",
            "Studio has no way to enumerate an OrderedDataStore; Open Cloud does.",
        ));
    }
    if a.op == Op::Increment {
        return Err(ToolError::hint(
            "UNSUPPORTED",
            "op=\"increment\" only works with target=\"live\".",
            "Read with `get` and write with `set` against Studio, or use target=\"live\".",
        ));
    }
    // Two network hops, the second to a throttled service, so the ceiling is generous.
    let r = call(
        &ctx,
        &format!("data.{}", op_name(a.op)),
        json!({
            "kind": a.kind, "store": a.store, "scope": a.scope, "key": a.key, "value": a.value, "version": a.version,
            "at": a.at, "ttl": a.ttl, "prefix": a.prefix, "cursor": a.cursor, "limit": a.limit, "confirm": a.confirm,
        }),
        a.studio_id.as_deref(),
        Some(45_000.0),
    )
    .await?;
    if matches!(a.op, Op::List | Op::Versions) {
        let items = arr_of(&r, "items");
        if items.is_empty() {
            return Ok(text(match &a.store {
                None => "No data stores in this place yet.".to_string(),
                Some(store) => format!(
                    "Nothing in {store}. If you expected data, check the `scope` — a game that used scopes keeps its keys under them, and the default scope looks empty."
                ),
            }));
        }
        let columns: &[&str] = if a.op == Op::Versions {
            &["version", "created", "deleted"]
        } else if a.store.is_none() {
            &["store", "created"]
        } else if a.kind == Kind::Memory {
            &["key", "value"]
        } else {
            &["key"]
        };
        let mut notes = Vec::new();
        if let Some(cursor) = str_of(&r, "cursor").filter(|c| !c.is_empty()) {
            notes.push(format!("more available — pass cursor=\"{cursor}\""));
        }
        if let Some(budget) = r.get("budget").filter(|b| b.is_number()) {
            notes.push(format!("{} requests left in budget", super::disp(Some(budget))));
        }
        if a.op == Op::Versions {
            notes.push("read one with op=\"get\" and its `version`".into());
        }
        let more = (!notes.is_empty()).then(|| notes.join("; "));
        return Ok(table(columns, items, PageMeta { more, ..Default::default() }));
    }
    if a.op == Op::Get && r.get("exists") == Some(&Value::Bool(false)) {
        return Ok(text(format!(
            "{} is not set in {}.\n{}",
            a.key.as_deref().unwrap_or("undefined"),
            a.store.as_deref().unwrap_or("undefined"),
            if a.kind == Kind::Memory {
                "MemoryStore entries expire on their own, so a key written earlier may simply have passed its TTL. There is no history to check."
            } else {
                "An empty key and a key that was never written look identical here. If a player should have data, check the `scope`, and try op=\"versions\" — a key that was removed still has history."
            }
        )));
    }
    Ok(json(&r, None))
}

pub fn tools() -> Vec<Tool> {
    vec![define(
        // Reads dominate, but the tool can write.
        spec("datastore", "Read and write saved data").destructive(true),
        "Reads and writes the game's saved data — DataStore and MemoryStore — from the connected Studio.\n\n\
         This is the only tool here that looks at anything outside the place file. Every other tool answers 'is the \
         instance right'; this one answers 'is what the player saved right', which is a different question and the one \
         behind most reports of lost progress, reset stats, or items that come back after a rejoin.\n\n\
         `kind=\"data\"` (the default) is DataStoreService: permanent, per-player, and version-tracked. `kind=\"memory\"` \
         is MemoryStoreService: a shared scratchpad that expires on its own — queues, locks, live leaderboards.\n\n\
         The workflow for a bug report is: `list` with no store to see what exists, `list` with one to see its keys, \
         `get` the player's key, and — the part worth knowing about — `versions` then `get` with a `version` to see what \
         that same key held BEFORE it broke. You cannot diagnose a bad save by looking only at the bad save.\n\n\
         Writes need `confirm: true` on `kind=\"data\"`, because nothing in this server can undo one: there is no \
         recording to cancel and no Ctrl+Z. Read the key first.\n\n\
         DataStore needs 'Enable Studio Access to API Services' ticked in Game Settings → Security, and a published \
         place. If it is off, this tool says so in those words rather than reporting the raw 502. MemoryStore needs \
         neither.\n\n\
         `target=\"live\"` is the other half of this tool and the one that answers a real bug report. It goes to Roblox \
         directly instead of through Studio, so it sees exactly what the running servers see — not what the place \
         happens to be connected to, and with no Studio API toggle involved. Use it whenever the question is about a \
         player who is actually playing. It needs an Open Cloud key and a universe id; the user sets both once with \
         `cloud` in the Studio panel.\n\n\
         `kind=\"ordered\"` (live only) is OrderedDataStoreService, the leaderboard backend: numbers only, always \
         sorted, no history. `list` returns it ranked highest first, which is the leaderboard itself.\n\n\
         `op=\"snapshot\"` is the safety net. It tells Roblox to snapshot every data store in the experience, so \
         support can roll them back. TAKE ONE BEFORE ANY LIVE WRITE. Roblox allows one per experience per UTC day, and \
         the result says whether this call actually took one — a second call the same day reports success while doing \
         nothing, and anything written since the first one is not covered.",
        datastore,
    )]
}
