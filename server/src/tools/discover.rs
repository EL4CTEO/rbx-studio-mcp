//! tree, inspect, find.

use super::{Detail, ReadTarget, arr_of, d, join_notes, read_call, str_of, u64_of};
use crate::apidump;
use crate::errors::Result;
use crate::format::{PageMeta, ToolResult, decode_cursor, encode_cursor, error_text, json, page, table, text};
use crate::tool::{Tool, define, spec};
use schemars::JsonSchema;
use serde::Deserialize;
use serde_json::{Map, Value, json};
use std::collections::BTreeSet;

fn depth2() -> u32 {
    2
}

#[derive(Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
struct TreeArgs {
    /// Dot-notation root, e.g. "Workspace.Map". Omit to list services from the root.
    path: Option<String>,
    /// Levels below `path` to walk. Keep low; each level multiplies the result.
    #[serde(default = "depth2")]
    #[schemars(range(min = 1, max = 10))]
    depth: u32,
    /// Only include instances of this class or a subclass, e.g. "BasePart".
    class_name: Option<String>,
    /// Only include instances whose name contains this text (case-insensitive).
    name_contains: Option<String>,
    #[serde(default)]
    detail: Detail,
    #[serde(default = "d::page")]
    #[schemars(schema_with = "super::page_limit_schema")]
    limit: u32,
    /// Opaque cursor from a previous call's `nextCursor`. Omit for the first page.
    cursor: Option<String>,
    #[serde(flatten)]
    read: ReadTarget,
    /// Include bounded session handles usable in place of paths. Survive rename/reparent; refuse expired references.
    #[serde(default)]
    handles: bool,
    /// Target Studio; omit for the active one.
    studio_id: Option<String>,
}

#[derive(Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
struct InspectArgs {
    /// Instance paths, e.g. ["Workspace.Baseplate", "Lighting"].
    #[schemars(length(min = 1, max = 50))]
    paths: Vec<String>,
    #[serde(default)]
    detail: Detail,
    /// Read exactly these properties instead of the detail-level default. Use when you want one specific value across many instances.
    properties: Option<Vec<String>>,
    /// Also report mass, density, assembly root and centre of mass for any BasePart. Mass appears nowhere in Studio — it is computed from volume and material — so this is the only way to answer 'why does this fall over', 'why does it sink', or 'why did half the model stay behind when I moved it'.
    #[serde(default)]
    physics: bool,
    /// Include a name/class listing of direct children.
    #[serde(default = "d::t")]
    include_children: bool,
    #[serde(flatten)]
    read: ReadTarget,
    /// Include bounded session handles usable in place of paths. Survive rename/reparent; refuse expired references.
    #[serde(default)]
    handles: bool,
    /// Target Studio; omit for the active one.
    studio_id: Option<String>,
}

#[derive(Deserialize, JsonSchema, Default, PartialEq)]
#[serde(rename_all = "lowercase")]
enum FindOp {
    #[default]
    Find,
    Tags,
}

#[derive(Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
struct FindArgs {
    /// 'find' searches for instances. 'tags' lists which CollectionService tags exist in the place, with counts — use it when you do not know the tag names yet.
    #[serde(default)]
    op: FindOp,
    /// Limit the search to this subtree, e.g. "Workspace.Map". Omit for everything.
    path: Option<String>,
    /// Substring of the instance name, case-insensitive.
    name_contains: Option<String>,
    /// Class or superclass, e.g. "BasePart", "Script".
    class_name: Option<String>,
    /// CollectionService tag the instance must carry.
    tag: Option<String>,
    /// Engine query selector, matched inside Studio. Supports a class name ("Part", superclasses included), "#ExactName", "[Anchored=true]", either-or with "Part, Model", direct children with "Model > Part" and descendants with "Model >> Part". No substring names and no < > comparisons — use nameContains and propertyValue for those. Combines with the other filters.
    selector: Option<String>,
    /// Property that must exist, e.g. "Anchored". Combine with propertyValue.
    property_name: Option<String>,
    /// Project just these properties on matching rows, avoiding a second inspect call. Unreadable names are reported.
    #[schemars(length(max = 16))]
    properties: Option<Vec<String>>,
    /// Required value of `propertyName`, compared as text — "true", "0, 5, 0", "Enum.Material.Neon". Omit to match any instance that has the property.
    property_value: Option<String>,
    #[serde(default)]
    detail: Detail,
    #[serde(default = "d::page")]
    #[schemars(schema_with = "super::page_limit_schema")]
    limit: u32,
    /// Opaque cursor from a previous call's `nextCursor`. Omit for the first page.
    cursor: Option<String>,
    #[serde(flatten)]
    read: ReadTarget,
    /// Include bounded session handles usable in place of paths. Survive rename/reparent; refuse expired references.
    #[serde(default)]
    handles: bool,
    /// Target Studio; omit for the active one.
    studio_id: Option<String>,
}

/// A hierarchy page as a table; `concise` drops the child count.
fn page_of(response: &Value, detail: Detail, more: Option<String>) -> ToolResult {
    let items = arr_of(response, "items");
    let mut columns = if detail == Detail::Concise { vec!["path", "className"] } else { vec!["path", "className", "childCount"] };
    if items.iter().any(|i| i.get("handle").is_some_and(|h| !h.is_null())) {
        columns.insert(1, "handle");
    }
    let offset = u64_of(response, "offset");
    let total = u64_of(response, "total");
    let next = offset + items.len() as u64;
    table(
        &columns,
        items,
        PageMeta {
            offset: Some(offset),
            total: Some(total),
            next_cursor: (next < total).then(|| encode_cursor(next)),
            more,
        },
    )
}

const RESTRICTED_SHOWN: usize = 10;

/// What `detail: "full"` could not read, named rather than silently omitted.
async fn restricted_note(classes: &BTreeSet<String>) -> Option<String> {
    let mut lines = Vec::new();
    for class in classes {
        let restrictions = apidump::restrictions_of(class).await;
        let mut hidden: Vec<&apidump::PropertyRestriction> = restrictions.values().filter(|r| r.blocked != "write").collect();
        if hidden.is_empty() {
            continue;
        }
        hidden.sort_by(|a, b| a.name.cmp(&b.name));
        let shown: Vec<String> = hidden
            .iter()
            .take(RESTRICTED_SHOWN)
            .map(|r| {
                let why = if r.not_scriptable { "NotScriptable".to_string() } else { r.capability.clone() };
                format!("{} ({why}{})", r.name, if r.writable { ", writable" } else { "" })
            })
            .collect();
        let rest = hidden.len() - shown.len();
        lines.push(format!(
            "  {class}: {}{}",
            shown.join(", "),
            if rest > 0 { format!(", and {rest} more") } else { String::new() }
        ));
    }
    (!lines.is_empty()).then(|| {
        format!(
            "Present but not readable at plugin identity, so absent above rather than unset. Unless marked writable \
             they cannot be set from here either — change those in Studio's Properties panel:\n{}",
            lines.join("\n")
        )
    })
}

const ABSENT_SHOWN: usize = 10;

/// Says why a property the caller named came back missing.
async fn absent_note(requested: &[String], items: &[Value]) -> Option<String> {
    let mut lines = Vec::new();
    for item in items {
        let props = item.get("properties").and_then(Value::as_object);
        let absent: Vec<&String> = requested.iter().filter(|n| props.is_none_or(|p| !p.contains_key(*n))).collect();
        if absent.is_empty() {
            continue;
        }
        let class = str_of(item, "className").unwrap_or("");
        let known = apidump::properties_of(class).await;
        let restricted = apidump::restrictions_of(class).await;
        let mut reasons = Vec::new();
        for name in absent {
            if known.iter().any(|p| &p.name == name) {
                reasons.push(format!("{name} (unset, or not readable in this session)"));
            } else if restricted.get(name).is_some_and(|r| r.blocked != "write") {
                reasons.push(format!("{name} (exists, but a plugin cannot read it)"));
            } else if !known.is_empty() {
                let near = apidump::suggest_property(class, name).await;
                reasons.push(format!(
                    "{name} (not a property of {class}{})",
                    if near.is_empty() { String::new() } else { format!("; did you mean {}?", near.join(", ")) }
                ));
            } else {
                reasons.push(name.clone());
            }
        }
        lines.push(format!("  {}: {}", str_of(item, "path").unwrap_or(""), reasons.join("; ")));
        if lines.len() >= ABSENT_SHOWN {
            break;
        }
    }
    (!lines.is_empty()).then(|| format!("Requested but not returned:\n{}", lines.join("\n")))
}

/// A class filter that names no Roblox class, when nothing matched.
async fn unknown_class_note(class: Option<&str>) -> Option<String> {
    let class = class.filter(|c| !c.is_empty())?;
    if !apidump::properties_of(class).await.is_empty() {
        return None;
    }
    let near = apidump::suggest_class(class).await;
    (!near.is_empty()).then(|| format!("\"{class}\" is not a Roblox class, which is why nothing matched. Did you mean: {}?", near.join(", ")))
}

/// Sorted property and attribute keys, so repeated inspects diff and cache cleanly.
fn with_sorted_properties(item: &Value) -> Value {
    let sort = |v: Option<&Value>| -> Option<Value> {
        let map = v?.as_object()?;
        let mut keys: Vec<&String> = map.keys().collect();
        keys.sort_by_key(|k| k.to_lowercase());
        Some(Value::Object(keys.into_iter().map(|k| (k.clone(), map[k].clone())).collect()))
    };
    let mut out = Map::new();
    let Some(obj) = item.as_object() else { return item.clone() };
    for (key, value) in obj {
        match key.as_str() {
            "requested" => {}
            "properties" => {
                out.insert(key.clone(), sort(Some(value)).unwrap_or_else(|| json!({})));
            }
            "attributes" => {
                if let Some(sorted) = sort(Some(value)) {
                    out.insert(key.clone(), sorted);
                }
            }
            "children" => {
                let names: Vec<Value> = value
                    .as_array()
                    .map(|children| {
                        children
                            .iter()
                            .map(|c| {
                                let name = str_of(c, "name").unwrap_or("");
                                let class = str_of(c, "className").unwrap_or("");
                                Value::String(if name == class { name.to_string() } else { format!("{name} ({class})") })
                            })
                            .collect()
                    })
                    .unwrap_or_default();
                out.insert(key.clone(), Value::Array(names));
            }
            _ => {
                out.insert(key.clone(), value.clone());
            }
        }
    }
    if !out.contains_key("properties") {
        out.insert("properties".into(), json!({}));
    }
    Value::Object(out)
}

pub fn tools() -> Vec<Tool> {
    vec![
        define(
            spec("tree", "Browse hierarchy").read_only(),
            "Lists the instance hierarchy under a path, breadth-first to a given depth. Returns a flat array of paths \
             — flat is both cheaper and easier to act on than nested JSON, since every entry is directly usable as a \
             path.\n\n\
             Use this to orient yourself in an unfamiliar place. Use `find` instead when you already know what you \
             are looking for; a deep `tree` over a whole place wastes context on instances you will never touch.\n\n\
             With `path` omitted it lists only the containers a place is authored in — Workspace, ReplicatedStorage, \
             ServerScriptService and friends. Roblox exposes ~120 services at the root, almost all engine internals; \
             those are hidden and the response says how many. Pass an explicit `path` to look inside one of them anyway.",
            |ctx, a: TreeArgs| async move {
                let response = read_call(
                    &ctx,
                    "discover.tree",
                    json!({
                        "path": a.path, "depth": a.depth, "className": a.class_name, "nameContains": a.name_contains,
                        "limit": a.limit, "offset": decode_cursor(a.cursor.as_deref())?, "handles": a.handles,
                    }),
                    &a.read,
                    a.studio_id.as_deref(),
                    30_000.0,
                )
                .await?;
                let hidden = u64_of(&response, "hiddenServices");
                let not_a_class = if arr_of(&response, "items").is_empty() { unknown_class_note(a.class_name.as_deref()).await } else { None };
                let more = join_notes(
                    [
                        (hidden > 0).then(|| format!("{hidden} engine services hidden — pass an explicit `path` to inspect one")),
                        not_a_class,
                        a.read.context(),
                    ],
                    "; ",
                );
                Ok(page_of(&response, a.detail, more))
            },
        ),
        define(
            spec("inspect", "Inspect instances").read_only(),
            "Reads properties, attributes, tags and children of one or more instances. Pass every path you care about \
             in a single call — batching costs one round trip instead of N.\n\n\
             Property selection comes from the live Roblox API dump for each instance's actual class, so it stays \
             correct across engine updates:\n  concise  — class and child count only\n  standard — the properties \
             that characterise the class (Part gets Size, Position, CFrame, Anchored, Material...)\n  full     — \
             every readable property; expensive, use on one or two instances at most\n\n\
             Bad paths do not fail the call: they come back under `failures` while the valid ones still return, so \
             one typo does not cost you the whole batch.",
            |ctx, a: InspectArgs| async move { inspect(&ctx, a).await },
        ),
        define(
            spec("find", "Find instances").read_only(),
            "Searches the data model by name, class, property value and/or tag. Every filter you supply must match, \
             so one call answers questions that would otherwise take several: \"anchored BaseParts under \
             Workspace.Map whose name contains door\" is a single request.\n\n\
             This replaces separate name / class / property / tag search tools. Prefer it over `tree` whenever you \
             know what you are looking for.\n\n\
             Tag searches are answered from CollectionService's index rather than by walking the tree, so they stay \
             fast on large places. Narrow with `path` if a search reports TOO_BROAD.\n\n\
             `op=\"tags\"` lists which tags the place actually USES, with counts and a few example paths. Call it \
             before filtering by tag on a place you do not know: a tag search that returns nothing looks the same \
             whether you spelled it wrong or nothing carries it, and the tag names are often the clearest description \
             of how a game is organised (Enemy, Checkpoint, Interactable say more than the folder layout does).\n\n\
             `selector` is the engine's own query language and is the fastest option of all — the matching happens \
             in C++ and only survivors come back. Reach for it when the shape of the tree is part of the question \
             (`Model > Part`) or when one call should answer two (`Part, Model`); the filters above still apply on \
             top of it.",
            |ctx, a: FindArgs| async move { find(&ctx, a).await },
        ),
    ]
}

async fn inspect(ctx: &crate::tool::Ctx, a: InspectArgs) -> Result<ToolResult> {
    let studio = a.studio_id.as_deref();
    let mut requested = a.properties.clone();
    let mut probed = BTreeSet::new();

    // Classes are unknown until the plugin answers: probe, then read.
    if requested.is_none() && a.detail != Detail::Concise {
        let probe = read_call(
            ctx,
            "discover.inspect",
            json!({ "paths": a.paths, "includeChildren": false, "probeOnly": true }),
            &a.read,
            studio,
            30_000.0,
        )
        .await?;
        let mut names: Vec<String> = Vec::new();
        let mut seen = BTreeSet::new();
        let mut classes = BTreeSet::new();
        for item in arr_of(&probe, "items") {
            if let Some(class) = str_of(item, "className") {
                classes.insert(class.to_string());
            }
        }
        for class in &classes {
            let list: Vec<String> = if a.detail == Detail::Full {
                probed.insert(class.clone());
                apidump::properties_of(class).await.iter().filter(|p| !p.deprecated).map(|p| p.name.clone()).collect()
            } else {
                apidump::standard_properties(class).await
            };
            for name in list {
                if seen.insert(name.clone()) {
                    names.push(name);
                }
            }
        }
        requested = Some(names);
    }

    let response = read_call(
        ctx,
        "discover.inspect",
        json!({
            "paths": a.paths, "properties": requested, "includeChildren": a.include_children,
            "physics": a.physics, "handles": a.handles,
        }),
        &a.read,
        studio,
        30_000.0,
    )
    .await?;

    let mut notes: Vec<String> = a.read.context().into_iter().collect();
    let failures = arr_of(&response, "failures");
    if !failures.is_empty() {
        let list: Vec<String> = failures.iter().map(|f| format!("  - {}", f.as_str().unwrap_or(&f.to_string()))).collect();
        notes.push(format!("Could not resolve {} path(s):\n{}", failures.len(), list.join("\n")));
    }
    if let Some(r) = restricted_note(&probed).await {
        notes.push(r);
    }
    let items = arr_of(&response, "items");
    if let Some(props) = a.properties.as_ref().filter(|p| !p.is_empty())
        && let Some(absent) = absent_note(props, items).await {
            notes.push(absent);
        }
    let sorted: Vec<Value> = items.iter().map(with_sorted_properties).collect();
    let note = (!notes.is_empty()).then(|| notes.join("\n\n"));
    Ok(json(&Value::Array(sorted), note.as_deref()))
}

async fn find(ctx: &crate::tool::Ctx, a: FindArgs) -> Result<ToolResult> {
    let studio = a.studio_id.as_deref();
    if a.op == FindOp::Tags {
        let found = read_call(ctx, "discover.tags", json!({ "path": a.path }), &a.read, studio, 30_000.0).await?;
        let scope = str_of(&found, "scope").map(str::to_string);
        let studio_hidden = u64_of(&found, "studioTagsHidden");
        let tags = arr_of(&found, "tags");
        if tags.is_empty() {
            return Ok(text(format!(
                "{}{}",
                match &scope {
                    Some(s) => format!("Nothing under {s} carries a tag."),
                    None => "This place uses no tags.".into(),
                },
                if studio_hidden > 0 { format!(" ({studio_hidden} of Studio's own internal tags were hidden.)") } else { String::new() }
            )));
        }
        let used: Vec<&Value> = tags.iter().filter(|t| u64_of(t, "count") > 0).collect();
        let empty: Vec<&str> = tags.iter().filter(|t| u64_of(t, "count") == 0).filter_map(|t| str_of(t, "tag")).collect();
        let empty_note = if empty.is_empty() {
            String::new()
        } else {
            format!(
                "\n\nRegistered but carrying nothing: {}. These are usually left by Studio plugins or by something since deleted.",
                empty.join(", ")
            )
        };
        if used.is_empty() {
            return Ok(text(format!(
                "{}{empty_note}",
                match &scope {
                    Some(s) => format!("Nothing under {s} carries a tag."),
                    None => "Nothing in this place carries a tag.".into(),
                }
            )));
        }
        let rows: Vec<Value> = used
            .iter()
            .map(|t| {
                let sample: Vec<&str> = arr_of(t, "sample").iter().filter_map(Value::as_str).collect();
                json!({
                    "tag": t.get("tag"),
                    "count": t.get("count"),
                    "examples": if sample.is_empty() { "—".to_string() } else { sample.join(", ") },
                })
            })
            .collect();
        let more = format!(
            "{}{studio_hidden} of Studio's own tags hidden",
            scope.as_ref().map(|s| format!("within {s}; ")).unwrap_or_default()
        );
        let rendered = table(&["tag", "count", "examples"], &rows, PageMeta { more: Some(more), ..Default::default() });
        return Ok(text(format!("{}{empty_note}", rendered.text_of())));
    }

    if a.name_contains.is_none() && a.class_name.is_none() && a.tag.is_none() && a.property_name.is_none() && a.selector.is_none() {
        return Ok(error_text(
            "find needs at least one filter (nameContains, className, tag, propertyName or selector).\nTo list everything under a path, use `tree` instead.",
        ));
    }

    let response = read_call(
        ctx,
        "discover.find",
        json!({
            "path": a.path, "nameContains": a.name_contains, "className": a.class_name, "tag": a.tag,
            "selector": a.selector, "propertyName": a.property_name, "propertyValue": a.property_value,
            "properties": a.properties, "limit": a.limit, "offset": decode_cursor(a.cursor.as_deref())?,
            "handles": a.handles,
        }),
        &a.read,
        studio,
        30_000.0,
    )
    .await?;

    let searched = u64_of(&response, "searched");
    if u64_of(&response, "total") == 0 {
        let not_a_class = unknown_class_note(a.class_name.as_deref()).await;
        return Ok(text(format!(
            "No matches (searched {searched} instances).\n{}Check spelling and case — names and class names are \
             case-sensitive. {}Try a shorter `nameContains`, or drop a filter to widen the search.",
            not_a_class.map(|n| format!("{n}\n")).unwrap_or_default(),
            if a.property_name.is_some() {
                "`propertyValue` is compared as text: a Vector3 reads \"0, 5, 0\", an enum matches either \"Neon\" or \
                 \"Enum.Material.Neon\", and a property that is simply absent on a class never matches. "
            } else {
                ""
            }
        )));
    }
    let more = join_notes([Some(format!("searched {searched} instances")), a.read.context()], "; ");
    if a.properties.is_some() {
        return Ok(page(
            arr_of(&response, "items"),
            PageMeta {
                offset: Some(u64_of(&response, "offset")),
                total: Some(u64_of(&response, "total")),
                more,
                ..Default::default()
            },
        ));
    }
    Ok(page_of(&response, a.detail, more))
}
