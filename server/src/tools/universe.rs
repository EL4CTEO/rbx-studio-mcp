//! universe: operate the PUBLISHED game and the people in it.

use crate::cloud::{self, Target, live, ops};
use crate::errors::{Result, ToolError};
use crate::format::{PageMeta, ToolResult, json, table, text};
use crate::tool::{Ctx, Tool, define, spec};
use schemars::JsonSchema;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::sync::Arc;

#[derive(Deserialize, Serialize, JsonSchema, PartialEq, Clone, Copy)]
#[serde(rename_all = "lowercase")]
enum Op {
    Restart,
    Message,
    Ban,
    Unban,
    Bans,
    User,
    Inventory,
    Servers,
    Logs,
    Products,
    Sell,
    Analytics,
    Events,
    Schedule,
    Cancel,
}

#[derive(Deserialize, Serialize, JsonSchema, Clone, Copy)]
#[serde(rename_all = "lowercase")]
enum Severity {
    Error,
    Warning,
}

#[derive(Deserialize, Serialize, JsonSchema, Clone, Copy)]
#[serde(rename_all = "lowercase")]
enum Kind {
    Product,
    Pass,
}

#[derive(Deserialize, Serialize, JsonSchema, Clone, Copy)]
enum Granularity {
    OneMinute,
    HalfHour,
    OneHour,
    OneDay,
    OneWeek,
    OneMonth,
    None,
}

fn d50() -> usize {
    50
}

#[derive(Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
struct Args {
    /// 'restart' rolls servers onto the new version, 'message' publishes to MessagingService, 'ban'/'unban'/'bans' manage player access, 'user' and 'inventory' look someone up, 'servers' and 'logs' read live servers, 'products' and 'sell' manage products and passes, 'analytics' reads metrics, 'events'/'schedule'/'cancel' manage scheduled events.
    op: Op,
    /// Which game. Omit to use the one set with `cloud universe <id>`.
    universe_id: Option<String>,
    /// ban/unban: restrict to this place only, instead of the whole experience. restart: only restart this place's servers. servers/logs: which place, defaulting to `cloud place`.
    place_id: Option<String>,
    /// logs only: the server, as listed by `servers`.
    job_id: Option<String>,
    /// logs only: just this level. Omit for both.
    severity: Option<Severity>,
    /// logs only: case-insensitive text to find in the message, stack trace or context.
    search: Option<String>,
    /// message only: the MessagingService topic.
    topic: Option<String>,
    /// message only: the payload, as a string.
    message: Option<String>,
    /// ban/unban/user/inventory: the player's user id.
    user_id: Option<String>,
    /// ban only: how long, in seconds. OMIT THIS AND THE BAN IS PERMANENT — say so to the user before you do it.
    #[schemars(range(min = 1))]
    duration_seconds: Option<u64>,
    /// ban only: shown to the player when they are turned away.
    #[schemars(length(max = 400))]
    display_reason: Option<String>,
    /// ban only: your own record. The player never sees it.
    #[schemars(length(max = 1000))]
    private_reason: Option<String>,
    /// ban only: if true, the ban applies to this account alone rather than to alts Roblox links to it. Defaults to false.
    exclude_alt_accounts: Option<bool>,
    /// restart only: minutes to let existing servers drain. 0 shuts them down immediately, moving players mid-game. Defaults to 10.
    #[schemars(range(min = 0, max = 60))]
    bleed_off_minutes: Option<u32>,
    /// inventory: an Open Cloud filter, e.g. `gamePassIds=123` or `assetIds=456`, to ask about specific items rather than listing everything. servers: a CEL filter over the server fields, e.g. `occupancy > 0`. analytics: Dimension=a,b;Dimension=c, e.g. `Platform=Phone,Tablet;Country=US`.
    filter: Option<String>,
    /// bans/inventory/servers/logs/events: how many rows to return. analytics: most breakdown series.
    #[serde(default = "d50")]
    #[schemars(range(min = 1, max = 200))]
    limit: usize,
    /// Required for restart, message, ban, unban, sell, schedule and cancel. Each of these is visible to players the moment it runs and none can be undone from here.
    confirm: Option<bool>,
    /// products/sell: 'product' is a developer product (bought again and again: currency, boosts), 'pass' a game pass (bought once: VIP, perks). products lists both when omitted; sell needs it.
    kind: Option<Kind>,
    /// sell only: the product or pass to change. Omit to create a new one.
    item_id: Option<String>,
    /// sell only: the item's name. Required to create.
    name: Option<String>,
    /// sell/schedule: the item's or event's description.
    description: Option<String>,
    /// sell only: price in Robux.
    #[schemars(range(min = 1))]
    price: Option<u64>,
    /// sell only: whether players can buy it. Say it explicitly when creating.
    for_sale: Option<bool>,
    /// sell only: path to a local .png/.jpg/.bmp/.tga icon.
    image: Option<String>,
    /// analytics only: the metric, e.g. DailyActiveUsers.
    metric: Option<String>,
    /// analytics only: size of each time bucket. Default OneDay. Which a metric allows varies.
    granularity: Option<Granularity>,
    /// analytics only: dimensions to split by, e.g. ["Platform"].
    #[schemars(length(max = 3))]
    breakdown: Option<Vec<String>>,
    /// analytics only: the last N whole UTC days, not counting today. Default 7.
    #[schemars(range(min = 1, max = 730))]
    days: Option<u32>,
    /// analytics/schedule: ISO 8601 UTC start, e.g. 2026-11-07T18:00:00Z. analytics: inclusive.
    start_time: Option<String>,
    /// analytics/schedule: ISO 8601 UTC end. analytics: exclusive.
    end_time: Option<String>,
    /// events/schedule/cancel: the event, as listed by `events`.
    event_id: Option<String>,
    /// schedule only: the event's title.
    #[schemars(length(max = 100))]
    title: Option<String>,
    /// schedule only: a line under the title.
    #[schemars(length(max = 200))]
    subtitle: Option<String>,
    /// schedule only: e.g. public.
    visibility: Option<String>,
}

fn name_of<T: Serialize>(v: T) -> String {
    serde_json::to_value(v).ok().and_then(|v| v.as_str().map(str::to_string)).unwrap_or_default()
}

async fn universe(ctx: Arc<Ctx>, a: Args) -> Result<ToolResult> {
    let credentials = cloud::require_credentials().await?;
    let universe = cloud::require_universe(a.universe_id.as_deref()).await?;
    cloud::assert_targets_open_place(
        &ctx.bridge,
        Target { universe_id: Some(&universe), place_id: None, explicit: a.universe_id.is_some(), studio_id: None },
    )
    .await?;
    let op_name = name_of(a.op);
    let needs_confirm = matches!(a.op, Op::Restart | Op::Message | Op::Ban | Op::Unban | Op::Sell | Op::Schedule | Op::Cancel);
    if needs_confirm && a.confirm != Some(true) {
        return Err(ToolError::hint(
            "NEEDS_CONFIRM",
            format!("`{op_name}` affects the live game and the people currently in it."),
            if a.op == Op::Ban && a.duration_seconds.is_none() {
                "This ban would be PERMANENT — no duration was given. Tell the user that in plain words, then pass confirm: true."
            } else {
                "Nothing here can undo it. Pass confirm: true once the user has agreed."
            },
        ));
    }
    match a.op {
        Op::Analytics => {
            let metric = a.metric.clone().ok_or_else(|| ToolError::bad_params("analytics needs a `metric`, e.g. DailyActiveUsers."))?;
            let (start, end) = match (&a.start_time, &a.end_time) {
                (Some(s), Some(e)) => (s.clone(), e.clone()),
                (None, None) => ops::last_days(a.days.unwrap_or(7)),
                _ => return Err(ToolError::bad_params("Give both `startTime` and `endTime`, or `days`.")),
            };
            let q = ops::MetricQuery {
                universe,
                metric,
                granularity: a.granularity.map(name_of).unwrap_or_else(|| "OneDay".into()),
                start,
                end,
                breakdown: a.breakdown.clone(),
                filter: a.filter.as_deref().map(ops::parse_filter).transpose()?,
                limit: Some(a.limit as u32),
            };
            let op = ops::query_metric(&credentials, &q).await?;
            Ok(text(ops::render_series(&q, &op)))
        }
        Op::Events => {
            if let Some(id) = &a.event_id {
                return Ok(json(&ops::get_event(&credentials, id).await?, None));
            }
            let (items, more) = ops::list_events(&credentials, &universe, a.limit).await?;
            if items.is_empty() {
                return Ok(text("This game has no scheduled events."));
            }
            Ok(table(
                &["id", "title", "start", "end", "visibility"],
                &items,
                PageMeta { more: more.then(|| "More events exist: raise `limit`.".into()), ..Default::default() },
            ))
        }
        Op::Schedule => {
            let saved = ops::save_event(
                &credentials,
                &universe,
                a.event_id.as_deref(),
                ops::EventFields {
                    title: a.title.as_deref(),
                    subtitle: a.subtitle.as_deref(),
                    description: a.description.as_deref(),
                    start: a.start_time.as_deref(),
                    end: a.end_time.as_deref(),
                    visibility: a.visibility.as_deref(),
                },
            )
            .await?;
            Ok(json(&saved, Some("Players can see this on the experience's page and RSVP to it.")))
        }
        Op::Cancel => {
            let id = a.event_id.as_deref().ok_or_else(|| ToolError::bad_params("cancel needs an `eventId`. List them with `op=\"events\"`."))?;
            Ok(json(&ops::cancel_event(&credentials, id).await?, None))
        }
        Op::Restart => {
            let places = a.place_id.as_ref().map(|p| vec![p.parse::<i64>().unwrap_or(0)]);
            Ok(json(&live::restart_servers(&credentials, &universe, places, a.bleed_off_minutes).await?, None))
        }
        Op::Message => {
            let (Some(topic), Some(message)) = (a.topic.as_deref().filter(|t| !t.is_empty()), a.message.as_deref()) else {
                return Err(ToolError::bad_params("message needs both `topic` and `message`."));
            };
            Ok(json(&live::publish_message(&credentials, &universe, topic, message).await?, None))
        }
        Op::Bans => {
            let found = live::list_restrictions(&credentials, &universe, a.limit).await?;
            let items = super::arr_of(&found, "items");
            if items.is_empty() {
                return Ok(text("Nobody is restricted in this experience."));
            }
            Ok(table(&["user", "active", "duration", "reason", "updated"], items, PageMeta::default()))
        }
        Op::Products => {
            let items = ops::list_items(&credentials, &universe, a.kind.map(name_of).as_deref()).await?;
            if items.is_empty() {
                return Ok(text("This game has no developer products or game passes yet."));
            }
            let more = format!(
                "{} item(s). A script sells a product with MarketplaceService:PromptProductPurchase and a pass with PromptGamePassPurchase.",
                items.len()
            );
            Ok(table(&["kind", "id", "name", "price", "forSale", "created"], &items, PageMeta { more: Some(more), ..Default::default() }))
        }
        Op::Sell => {
            let kind = a.kind.ok_or_else(|| ToolError::bad_params("sell needs a `kind`: \"product\" or \"pass\"."))?;
            let kind = name_of(kind);
            let saved = ops::save_item(
                &credentials,
                ops::SaveItem {
                    universe: &universe,
                    kind: &kind,
                    id: a.item_id.as_deref(),
                    name: a.name.as_deref(),
                    description: a.description.as_deref(),
                    price: a.price,
                    for_sale: a.for_sale,
                    image: a.image.as_deref(),
                },
            )
            .await?;
            Ok(json(
                &saved,
                Some(if kind == "product" {
                    "A developer product needs a ProcessReceipt callback on the server to grant what was bought, or purchases are charged and then refunded."
                } else {
                    "Check ownership with MarketplaceService:UserOwnsGamePassAsync."
                }),
            ))
        }
        Op::Servers => {
            let place = cloud::require_place(a.place_id.as_deref()).await?;
            let found = live::list_game_servers(&credentials, &live::Place { universe: &universe, place: &place }, a.limit, a.filter.clone()).await?;
            let items = super::arr_of(&found, "items");
            let partial = if found.get("partial") == Some(&Value::Bool(true)) { " Roblox returned a partial list; try again shortly." } else { "" };
            if items.is_empty() {
                return Ok(text(format!("No servers are running for place {place}.{partial}")));
            }
            let more = format!(
                "{} server(s){}. Read one with `op=\"logs\" jobId=...`.{partial}",
                items.len(),
                if found.get("more") == Some(&Value::Bool(true)) { ", more available — raise `limit`" } else { "" }
            );
            Ok(table(&["jobId", "status", "players", "uptime", "fps", "memoryMb", "version"], items, PageMeta { more: Some(more), ..Default::default() }))
        }
        Op::Logs => {
            let job = a.job_id.as_deref().ok_or_else(|| ToolError::bad_params("logs needs a `jobId`. List them with `op=\"servers\"`."))?;
            let place = cloud::require_place(a.place_id.as_deref()).await?;
            let severity = a.severity.map(name_of);
            let found = live::list_server_logs(
                &credentials,
                &live::Place { universe: &universe, place: &place },
                job,
                a.limit,
                severity.as_deref(),
                a.search.as_deref(),
            )
            .await?;
            let items = super::arr_of(&found, "items");
            if items.is_empty() {
                return Ok(text(format!(
                    "No {} logs for {job}{}. Logs arrive about three minutes after they are written, and a wrong `placeId` also reads as empty.",
                    severity.as_deref().unwrap_or("error or warning"),
                    a.search.as_ref().map(|s| format!(" matching \"{s}\"")).unwrap_or_default()
                )));
            }
            let d = |e: &Value, k: &str| super::disp(e.get(k));
            let lines: Vec<String> = items
                .iter()
                .map(|e| {
                    let mut block = vec![format!(
                        "{} [{}] {}{}",
                        d(e, "time"),
                        d(e, "level"),
                        d(e, "message"),
                        e.get("repeats").filter(|r| !r.is_null()).map(|r| format!("  (+{} similar)", super::disp(Some(r)))).unwrap_or_default()
                    )];
                    // Parsed frames name the script by its place path, ready for script_read.
                    if let Some(frames) = e.get("frames").and_then(Value::as_array) {
                        block.push(frames.iter().map(|f| format!("  at {}", super::disp(Some(f)))).collect::<Vec<_>>().join("\n"));
                    } else if let Some(stack) = super::str_of(e, "stack") {
                        block.push(format!("  {}", stack.trim().replace('\n', "\n  ")));
                    }
                    if let Some(c) = super::str_of(e, "context") {
                        block.push(format!("  context: {c}"));
                    }
                    block.join("\n")
                })
                .collect();
            Ok(text(format!(
                "{}{}",
                lines.join("\n"),
                if found.get("more") == Some(&Value::Bool(true)) { "\n\n[more available — raise `limit` or narrow with `search`]" } else { "" }
            )))
        }
        Op::User | Op::Inventory | Op::Ban | Op::Unban => {
            let user = a.user_id.as_deref().filter(|u| !u.is_empty()).ok_or_else(|| ToolError::bad_params(format!("{op_name} needs a `userId`.")))?;
            match a.op {
                Op::User => Ok(json(&live::get_user(&credentials, user).await?, None)),
                Op::Inventory => Ok(json(&live::get_inventory(&credentials, user, a.limit, a.filter.clone()).await?, None)),
                _ => Ok(json(
                    &live::set_restriction(
                        &credentials,
                        live::Restriction {
                            universe: &universe,
                            place: a.place_id.as_deref(),
                            user,
                            active: a.op == Op::Ban,
                            duration_seconds: a.duration_seconds,
                            display_reason: a.display_reason.as_deref(),
                            private_reason: a.private_reason.as_deref(),
                            exclude_alts: a.exclude_alt_accounts,
                        },
                    )
                    .await?,
                    None,
                )),
            }
        }
    }
}

pub fn tools() -> Vec<Tool> {
    vec![define(
        spec("universe", "Operate the live game").destructive(true),
        "Acts on the PUBLISHED experience and the people in it — not on the place open in Studio.\n\n\
         `restart` rolls live servers onto the version you just published. Publishing on its own changes nothing for \
         anyone already playing: they stay on their server, running the old code, until it empties. This is the step \
         people forget. By default it bleeds off over 10 minutes — matchmaking stops and players finish what they are \
         doing — rather than shutting servers down under them, which is what Roblox's own default does.\n\n\
         `message` publishes to MessagingService, reaching every live server at once. Only servers with a \
         `SubscribeAsync` listener on that exact topic receive it, and nothing reports whether anything was listening, so \
         success here does not mean delivery.\n\n\
         `ban` and `unban` set a player's game-join restriction. A ban with no `durationSeconds` is PERMANENT. \
         `displayReason` is shown to the player; `privateReason` is for your records. Scope it to one place with \
         `placeId`, or leave that out to cover the whole experience. `bans` lists who is currently restricted.\n\n\
         `user` looks up a user id — the name-to-id step most other calls need. `inventory` reports what someone owns: \
         passes, badges, assets.\n\n\
         `servers` lists the place's live servers — players, uptime, frame rate, memory, version — and `logs` reads one \
         server's errors and warnings by its `jobId`, with stack traces and structured-log context. That is where a \
         player's bug report actually happened; Studio only shows your own test. Roblox keeps warnings and errors only, \
         and they arrive about three minutes after they are written.\n\n\
         `products` lists the game's developer products and game passes with their ids and prices — the ids a purchase \
         script needs. `sell` creates one, or changes one given `itemId`. Creating checks the name first, so a retried \
         create cannot leave two \"100 Coins\" products.\n\n\
         `analytics` reads the game's own numbers over a date range: players, revenue, retention, crashes, frame rate, as \
         a time series, optionally split by a `breakdown` such as Platform or Country. Common metrics: DailyActiveUsers, \
         Visits, DailyRevenue, PayingUsers, ForwardD1Retention, AverageSessionLengthMinutes, PeakConcurrentPlayers, \
         ClientCrashCount, ClientFpsP50. Give `days` for the last N whole UTC days, or `startTime` and `endTime`.\n\n\
         `events` lists the game's scheduled events, or reads one by `eventId`. `schedule` creates one (`title`, \
         `startTime`, `endTime`) or changes one given `eventId`; `cancel` deletes it. Players see these on the \
         experience's page.\n\n\
         Everything here needs an Open Cloud key and a universe id. The user sets both once with `cloud` in the Studio \
         panel.",
        universe,
    )]
}
