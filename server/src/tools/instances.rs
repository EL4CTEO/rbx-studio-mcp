//! create, modify, delete, move.

use super::{arr_of, call, str_of};
use crate::apidump;
use crate::errors::{Result, ToolError};
use crate::format::{PageMeta, ToolResult, table};
use crate::tool::{Ctx, Tool, define, spec};
use schemars::{JsonSchema, Schema, SchemaGenerator, json_schema};
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value, json};
use std::collections::{BTreeSet, HashMap};
use std::sync::Arc;

pub const PROPERTY_DOC: &str = "Properties to set, as name → value. Values are written the way Studio's Properties panel \
shows them: \"12, 0, 5\" for a Vector3, \"0.2, 0.6, 1\" for a Color3, \"Neon\" or \"Enum.Material.Neon\" for an enum, \
true/false for a bool.";

pub fn property_bag(_: &mut SchemaGenerator) -> Schema {
    json_schema!({
        "type": "object",
        "additionalProperties": { "type": ["string", "number", "boolean"] },
        "description": PROPERTY_DOC,
    })
}

const ATTRIBUTE_TYPES: [&str; 15] = [
    "string", "boolean", "number", "BrickColor", "CFrame", "Color3", "ColorSequence", "Font", "NumberRange",
    "NumberSequence", "Rect", "UDim", "UDim2", "Vector2", "Vector3",
];

pub fn attribute_bag(_: &mut SchemaGenerator) -> Schema {
    json_schema!({
        "type": "object",
        "additionalProperties": {
            "anyOf": [
                { "type": ["string", "number", "boolean"] },
                {
                    "type": "object",
                    "properties": {
                        "type": {
                            "type": "string",
                            "enum": ATTRIBUTE_TYPES,
                            "description": "Roblox type to store the attribute as. Needed for anything but a plain string, number or boolean — a bare string stays a string."
                        },
                        "value": {
                            "type": ["string", "number", "boolean"],
                            "description": "The value, written as the Properties panel shows it: \"0, 5, 0\"."
                        }
                    },
                    "required": ["type", "value"]
                }
            ]
        },
        "description": "Attributes to set, as name → value. A bare string, number or boolean is stored as-is; for any other type pass { type, value }, e.g. { type: \"Vector3\", value: \"0, 5, 0\" }. An empty string removes an attribute.",
    })
}

#[derive(Deserialize, Serialize, JsonSchema, Clone, Default)]
pub struct Tags {
    /// CollectionService tags to add.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub add: Option<Vec<String>>,
    /// Tags to remove.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub remove: Option<Vec<String>>,
}

/// Resolves each property to its declared type, refusing unknown ones with suggestions.
pub async fn resolve_properties(class: &str, properties: Option<&Map<String, Value>>, where_: &str) -> Result<Option<Value>> {
    let Some(properties) = properties.filter(|p| !p.is_empty()) else { return Ok(None) };
    let known = apidump::properties_of(class).await;
    // No dump: passing values through untyped beats refusing unverifiable work.
    if known.is_empty() {
        return Ok(None);
    }
    let by_name: HashMap<&str, &apidump::PropertyInfo> = known.iter().map(|p| (p.name.as_str(), p)).collect();
    let restricted = apidump::restrictions_of(class).await;
    let mut resolved = Map::new();
    for (name, value) in properties {
        let type_name = match by_name.get(name.as_str()) {
            Some(info) => {
                if info.category == "Enum" && info.value_type == "Font" { "Enum.Font".to_string() } else { info.value_type.clone() }
            }
            None => match restricted.get(name) {
                Some(r) if !r.writable => {
                    return Err(ToolError::hint(
                        "RESTRICTED_PROPERTY",
                        format!("{class}.{name} exists but is {} ({where_}).", apidump::describe_restriction(r)),
                        "Change it in Studio's Properties panel (or Game Settings) instead.",
                    ));
                }
                Some(r) => r.value_type.clone(),
                None => {
                    let near = apidump::suggest_property(class, name).await;
                    return Err(ToolError::hint(
                        "UNKNOWN_PROPERTY",
                        format!("{class} has no property \"{name}\" ({where_})."),
                        if near.is_empty() {
                            format!("Call `inspect` with detail \"full\" on an existing {class} to see its properties.")
                        } else {
                            format!("Did you mean: {}?", near.join(", "))
                        },
                    ));
                }
            },
        };
        resolved.insert(name.clone(), json!({ "value": value, "type": type_name }));
    }
    Ok(Some(Value::Object(resolved)))
}

async fn assert_creatable(class: &str) -> Result<()> {
    if !apidump::properties_of(class).await.is_empty() {
        return Ok(());
    }
    let near = apidump::suggest_class(class).await;
    if near.is_empty() {
        return Ok(());
    }
    Err(ToolError::hint("UNKNOWN_CLASS", format!("\"{class}\" is not a Roblox class."), format!("Did you mean: {}?", near.join(", "))))
}

// One create entry as advertised: `children` as plain objects, because a
// recursive `$ref` makes some clients (Gemini, Vertex) reject the tool list.
#[derive(Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct CreateNode {
    /// Where to put it, e.g. "Workspace". Required at the top level only.
    parent: Option<String>,
    /// Concrete class to create, e.g. "Part", "Folder", "Model", "SpawnLocation".
    class_name: String,
    /// Name for the new instance.
    name: Option<String>,
    #[serde(default)]
    #[schemars(schema_with = "property_bag")]
    properties: Option<Map<String, Value>>,
    #[serde(default)]
    #[schemars(schema_with = "attribute_bag")]
    attributes: Option<Map<String, Value>>,
    /// CollectionService tags to add or remove.
    tags: Option<Tags>,
    /// Instances to create inside this one. Each takes the same fields as this entry (className, name, properties, attributes, tags, children), nested as deep as needed. Build a whole model in one call rather than creating a parent and then addressing it by a path you have to guess.
    children: Option<Vec<Map<String, Value>>>,
}

/// Checks and types the whole tree, naming the exact field that is wrong.
pub fn type_create_tree<'a>(node: CreateNode, where_: String) -> futures::future::BoxFuture<'a, Result<Value>> {
    Box::pin(async move {
        assert_creatable(&node.class_name).await?;
        let properties = resolve_properties(&node.class_name, node.properties.as_ref(), &where_).await?;
        let mut children = Vec::new();
        for (i, raw) in node.children.unwrap_or_default().into_iter().enumerate() {
            let path = format!("{where_} > {}.children[{i}]", node.class_name);
            let child: CreateNode = serde_json::from_value(Value::Object(raw)).map_err(|e| {
                ToolError::hint(
                    "BAD_PARAMS",
                    format!("{path}: {e}."),
                    "Every entry in `children` takes the same fields as a top-level entry, and needs its own `className`.",
                )
            })?;
            children.push(type_create_tree(child, path).await?);
        }
        let mut out = Map::new();
        if let Some(p) = node.parent {
            out.insert("parent".into(), json!(p));
        }
        out.insert("className".into(), json!(node.class_name));
        if let Some(n) = node.name {
            out.insert("name".into(), json!(n));
        }
        if let Some(p) = properties {
            out.insert("properties".into(), p);
        }
        if let Some(a) = node.attributes {
            out.insert("attributes".into(), Value::Object(a));
        }
        if let Some(t) = node.tags {
            out.insert("tags".into(), serde_json::to_value(t)?);
        }
        if !children.is_empty() {
            out.insert("children".into(), Value::Array(children));
        }
        Ok(Value::Object(out))
    })
}

pub fn undo_note(response: &Value) -> String {
    match str_of(response, "undoStep") {
        Some(step) => format!("one undo step, \"{step}\""),
        None => "Studio would not open an undo recording, so this is not undoable as one step".into(),
    }
}

#[derive(Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
struct CreateArgs {
    /// Instances to create together as one undoable step.
    #[schemars(length(min = 1, max = 100))]
    instances: Vec<CreateNode>,
    /// Target Studio; omit for the active one.
    studio_id: Option<String>,
}

#[derive(Deserialize, Serialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
struct ModifyTarget {
    /// Instances to change, e.g. ["Workspace.Part[3]", "Workspace.Wall"].
    #[schemars(length(min = 1))]
    paths: Vec<String>,
    #[serde(default)]
    #[schemars(schema_with = "property_bag")]
    #[serde(skip_serializing_if = "Option::is_none")]
    properties: Option<Map<String, Value>>,
    #[serde(default)]
    #[schemars(schema_with = "attribute_bag")]
    #[serde(skip_serializing_if = "Option::is_none")]
    attributes: Option<Map<String, Value>>,
    /// CollectionService tags to add or remove.
    #[serde(skip_serializing_if = "Option::is_none")]
    tags: Option<Tags>,
}

#[derive(Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
struct ModifyArgs {
    /// Changes to apply together as one undoable step.
    #[schemars(length(min = 1, max = 100))]
    targets: Vec<ModifyTarget>,
    /// Target Studio; omit for the active one.
    studio_id: Option<String>,
}

#[derive(Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
struct DeleteArgs {
    /// Instances to destroy, e.g. ["Workspace.OldModel"].
    #[schemars(length(min = 1, max = 200))]
    paths: Vec<String>,
    /// Target Studio; omit for the active one.
    studio_id: Option<String>,
}

#[derive(Deserialize, Serialize, JsonSchema, Default)]
#[serde(rename_all = "lowercase")]
enum MoveMode {
    #[default]
    Move,
    Clone,
}

#[derive(Deserialize, Serialize, JsonSchema)]
struct MoveItem {
    /// Instance to move or clone.
    path: String,
    /// New parent's path.
    to: String,
    /// 'move' reparents the original; 'clone' leaves it and copies.
    #[serde(default)]
    mode: MoveMode,
    /// Rename it as part of the same step. Useful with clone.
    #[serde(skip_serializing_if = "Option::is_none")]
    name: Option<String>,
}

#[derive(Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
struct MoveArgs {
    /// Moves to apply together as one undoable step.
    #[schemars(length(min = 1, max = 200))]
    items: Vec<MoveItem>,
    /// Target Studio; omit for the active one.
    studio_id: Option<String>,
}

async fn create(ctx: Arc<Ctx>, a: CreateArgs) -> Result<ToolResult> {
    let specs = futures::future::try_join_all(
        a.instances.into_iter().enumerate().map(|(i, node)| type_create_tree(node, format!("instances[{i}]"))),
    )
    .await?;
    let response = call(&ctx, "instances.create", json!({ "instances": specs }), a.studio_id.as_deref(), Some(30_000.0)).await?;
    Ok(table(&["path", "className"], arr_of(&response, "items"), PageMeta { more: Some(undo_note(&response)), ..Default::default() }))
}

async fn modify(ctx: Arc<Ctx>, a: ModifyArgs) -> Result<ToolResult> {
    let studio = a.studio_id.as_deref();
    let needs_types = a.targets.iter().any(|t| t.properties.as_ref().is_some_and(|p| !p.is_empty()));
    let mut targets: Vec<Value> = Vec::with_capacity(a.targets.len());
    if needs_types {
        // Classes first, so properties can be typed: the same two passes as inspect.
        let mut unique: Vec<&str> = Vec::new();
        let mut seen = BTreeSet::new();
        for path in a.targets.iter().flat_map(|t| &t.paths) {
            if seen.insert(path.as_str()) {
                unique.push(path);
            }
        }
        let probe = call(&ctx, "discover.inspect", json!({ "paths": unique, "includeChildren": false, "probeOnly": true }), studio, None).await?;
        // Keyed on the path asked about, not the canonical one that came back.
        let class_of: HashMap<String, String> = arr_of(&probe, "items")
            .iter()
            .filter_map(|i| {
                let key = str_of(i, "requested").or_else(|| str_of(i, "path"))?;
                Some((key.to_string(), str_of(i, "className")?.to_string()))
            })
            .collect();
        for (index, target) in a.targets.into_iter().enumerate() {
            let mut value = serde_json::to_value(&target)?;
            if target.properties.is_some() {
                let classes: BTreeSet<&String> = target.paths.iter().filter_map(|p| class_of.get(p)).collect();
                if classes.is_empty() {
                    return Err(ToolError::hint(
                        "UNRESOLVED_TARGET",
                        format!("Could not read the class of any path in targets[{index}]."),
                        "Check the paths with `find` or `tree`. Properties are typed from the class, so nothing was changed rather than guessing.",
                    ));
                }
                let mut typed = None;
                for class in classes {
                    typed = resolve_properties(class, target.properties.as_ref(), &format!("targets[{index}]")).await?;
                }
                if let Some(t) = typed { value["properties"] = t }
            }
            targets.push(value);
        }
    } else {
        for target in &a.targets {
            targets.push(serde_json::to_value(target)?);
        }
    }
    let response = call(&ctx, "instances.modify", json!({ "targets": targets }), studio, Some(30_000.0)).await?;
    Ok(table(&["path", "className", "changed"], arr_of(&response, "items"), PageMeta { more: Some(undo_note(&response)), ..Default::default() }))
}

pub fn tools() -> Vec<Tool> {
    vec![
        define(
            spec("create", "Create instances"),
            "Creates instances with their properties, attributes and tags set at creation, as one undoable step.\n\n\
             Nest with `children` to build a whole model in a single call. That is both faster and safer than creating \
             a parent and then addressing it: a new instance's path is not knowable until it exists, and same-named \
             siblings make guessing it unreliable.\n\n\
             Property names are checked against the live Roblox API dump before anything is sent to Studio, so a typo \
             comes back with the closest real names rather than an engine error.\n\n\
             Use `script_create` for Script, LocalScript and ModuleScript — it takes source directly.",
            create,
        ),
        define(
            spec("modify", "Modify instances").destructive(true),
            "Sets properties, attributes and tags on existing instances, as one undoable step.\n\n\
             Each entry takes a list of `paths`, so one entry can apply the same change to many instances — anchoring \
             200 parts is one entry, not 200. Combine with `find` to build the path list.\n\n\
             The batch is all-or-nothing: if any value is rejected the recording is cancelled and every instance \
             reverts, rather than leaving the place half-changed.\n\n\
             Values use the same notation the Properties panel shows — see the `properties` field. To change a \
             script's code use `script_edit`.",
            modify,
        ),
        define(
            spec("delete", "Delete instances").destructive(true),
            "Destroys instances and everything inside them, as one undoable step.\n\n\
             Deleting a container deletes its whole subtree, so the response reports how many descendants went with \
             each one — check it before telling the user what happened.\n\n\
             Services cannot be deleted and are refused. Paths shift when same-named siblings are removed, so read \
             fresh paths from `find` or `tree` before a second delete rather than reusing indexes from an earlier call.",
            |ctx, a: DeleteArgs| async move {
                let response = call(&ctx, "instances.delete", json!({ "paths": a.paths }), a.studio_id.as_deref(), Some(30_000.0)).await?;
                Ok(table(&["path", "className", "descendants"], arr_of(&response, "items"), PageMeta { more: Some(undo_note(&response)), ..Default::default() }))
            },
        ),
        define(
            spec("move", "Move or clone instances").destructive(true),
            "Reparents instances, or clones them into a new parent, as one undoable step.\n\n\
             Set `mode: \"clone\"` to copy instead of move — that is how to duplicate something, optionally renaming it \
             in the same call.\n\n\
             Moving an instance into itself or its own descendant is refused: it silently detaches the branch from the \
             data model and undo does not bring it back.",
            |ctx, a: MoveArgs| async move {
                let response = call(&ctx, "instances.move", json!({ "items": a.items }), a.studio_id.as_deref(), Some(30_000.0)).await?;
                Ok(table(&["path", "className", "cloned"], arr_of(&response, "items"), PageMeta { more: Some(undo_note(&response)), ..Default::default() }))
            },
        ),
    ]
}
