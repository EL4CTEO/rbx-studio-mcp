//! Studio's "Copy as JSON" clipboard format (Studio 0.748+).
//!
//! One flat object per instance: `ClassName`, properties written the way the
//! Properties panel shows them (`"4, 1, 2"`, `"true"`, `"Smooth"`), `$Name`
//! keys for attributes and `.Name` keys for tags. Descendants are not part of
//! the format yet, so neither side here nests.
//!
//! Studio's own `SerializationService:SerializeValue(…, Json)` would be the
//! natural source, but it answers "not yet enabled" to plugins, so the format
//! is produced and read here instead. Our property notation is already the
//! Properties panel's, so the two map onto each other directly.

use serde_json::{Map, Value, json};

/// The objects in a payload: a JSON string, an object, or an array of objects.
pub fn objects(payload: &Value) -> Result<Vec<Map<String, Value>>, String> {
    let parsed;
    let value = match payload {
        Value::String(s) => {
            parsed = serde_json::from_str::<Value>(s.trim()).map_err(|e| format!("not valid JSON: {e}"))?;
            &parsed
        }
        other => other,
    };
    let list: Vec<&Value> = match value {
        Value::Object(_) => vec![value],
        Value::Array(items) => items.iter().collect(),
        _ => return Err("expected an object or an array of objects".into()),
    };
    if list.is_empty() {
        return Err("the payload is an empty array".into());
    }
    list.into_iter()
        .enumerate()
        .map(|(i, v)| v.as_object().cloned().ok_or_else(|| format!("item {i} is not an object")))
        .collect()
}

/// What one Studio JSON object sets, split the way `create` and `modify` take it.
#[derive(Debug, Default, PartialEq)]
pub struct Parts {
    pub class_name: Option<String>,
    pub name: Option<String>,
    pub properties: Map<String, Value>,
    pub attributes: Map<String, Value>,
    pub tags_add: Vec<String>,
    pub tags_remove: Vec<String>,
}

/// Splits one object. `where_` names it in errors.
pub fn split(object: &Map<String, Value>, where_: &str) -> Result<Parts, String> {
    let mut parts = Parts::default();
    for (key, value) in object {
        if key == "ClassName" {
            parts.class_name = Some(value.as_str().ok_or_else(|| format!("{where_}: ClassName must be a string"))?.to_string());
        } else if key == "Name" {
            parts.name = Some(scalar_text(value).ok_or_else(|| format!("{where_}: Name must be a string"))?);
        } else if let Some(attr) = key.strip_prefix('$') {
            if !is_scalar(value) {
                return Err(format!("{where_}: attribute \"{attr}\" must be a string, number or boolean"));
            }
            parts.attributes.insert(attr.to_string(), value.clone());
        } else if let Some(tag) = key.strip_prefix('.') {
            match value {
                Value::Bool(false) => parts.tags_remove.push(tag.to_string()),
                Value::String(s) if s.eq_ignore_ascii_case("false") => parts.tags_remove.push(tag.to_string()),
                _ => parts.tags_add.push(tag.to_string()),
            }
        } else {
            if !is_scalar(value) {
                return Err(format!(
                    "{where_}: property \"{key}\" must be a string, number or boolean (Studio's JSON has no nested values)"
                ));
            }
            parts.properties.insert(key.clone(), value.clone());
        }
    }
    Ok(parts)
}

fn is_scalar(v: &Value) -> bool {
    matches!(v, Value::String(_) | Value::Number(_) | Value::Bool(_))
}

fn scalar_text(v: &Value) -> Option<String> {
    match v {
        Value::String(s) => Some(s.clone()),
        Value::Number(n) => Some(n.to_string()),
        _ => None,
    }
}

/// A `create` entry for one object, under `parent`.
pub fn create_entry(object: &Map<String, Value>, parent: &str, where_: &str) -> Result<Value, String> {
    let parts = split(object, where_)?;
    let class = parts.class_name.ok_or_else(|| format!("{where_}: has no ClassName, so there is nothing to create"))?;
    let mut out = Map::new();
    out.insert("parent".into(), json!(parent));
    out.insert("className".into(), json!(class));
    if let Some(n) = parts.name {
        out.insert("name".into(), json!(n));
    }
    if !parts.properties.is_empty() {
        out.insert("properties".into(), Value::Object(parts.properties));
    }
    if !parts.attributes.is_empty() {
        out.insert("attributes".into(), Value::Object(parts.attributes));
    }
    if !parts.tags_add.is_empty() {
        out.insert("tags".into(), json!({ "add": parts.tags_add }));
    }
    Ok(Value::Object(out))
}

/// One `inspect` item as Studio would put it on the clipboard.
///
/// Property values are written as text, the way Studio writes them
/// (`"Anchored": "true"`); attributes keep their JSON type, as in Studio's own
/// examples. `ClassName` goes last, matching Studio's output.
pub fn from_inspect(item: &Value) -> Value {
    let mut out = Map::new();
    if let Some(props) = item.get("properties").and_then(Value::as_object) {
        let mut names: Vec<&String> = props.keys().collect();
        // Name first so a reader sees what it is; the rest in a stable order.
        names.sort_by_key(|n| (n.as_str() != "Name", n.to_string()));
        for name in names {
            let value = &props[name];
            let text = match value {
                Value::String(s) => s.clone(),
                Value::Bool(b) => b.to_string(),
                Value::Number(n) => n.to_string(),
                Value::Null => continue,
                other => other.to_string(),
            };
            out.insert(name.clone(), json!(text));
        }
    }
    if let Some(attrs) = item.get("attributes").and_then(Value::as_object) {
        for (name, value) in attrs {
            out.insert(format!("${name}"), value.clone());
        }
    }
    if let Some(tags) = item.get("tags").and_then(Value::as_array) {
        for tag in tags.iter().filter_map(Value::as_str) {
            out.insert(format!(".{tag}"), json!(true));
        }
    }
    if let Some(class) = item.get("className") {
        out.insert("ClassName".into(), class.clone());
    }
    Value::Object(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_studio_announcement_example() {
        let payload = json!(r#"{"ClassName":"Part","Anchored":"true","Name":"Renamed","$Speed":1.5,".Interactable":true}"#);
        let list = objects(&payload).unwrap();
        assert_eq!(list.len(), 1);
        let parts = split(&list[0], "item 0").unwrap();
        assert_eq!(parts.class_name.as_deref(), Some("Part"));
        assert_eq!(parts.name.as_deref(), Some("Renamed"));
        assert_eq!(parts.properties.get("Anchored"), Some(&json!("true")));
        assert_eq!(parts.attributes.get("Speed"), Some(&json!(1.5)));
        assert_eq!(parts.tags_add, vec!["Interactable".to_string()]);
    }

    #[test]
    fn accepts_arrays_and_values_not_only_strings() {
        let list = objects(&json!([{ "ClassName": "Part" }, { "ClassName": "Folder" }])).unwrap();
        assert_eq!(list.len(), 2);
        assert!(objects(&json!("[]")).is_err());
        assert!(objects(&json!("not json")).is_err());
        assert!(objects(&json!([1])).is_err());
    }

    #[test]
    fn false_tag_removes_and_nested_values_are_refused() {
        let o = objects(&json!({ ".Old": false, ".New": "true" })).unwrap();
        let parts = split(&o[0], "x").unwrap();
        assert_eq!(parts.tags_remove, vec!["Old".to_string()]);
        assert_eq!(parts.tags_add, vec!["New".to_string()]);
        let bad = objects(&json!({ "Size": [1, 2, 3] })).unwrap();
        assert!(split(&bad[0], "x").unwrap_err().contains("Size"));
    }

    #[test]
    fn create_entry_needs_a_class() {
        let o = objects(&json!({ "Name": "X" })).unwrap();
        assert!(create_entry(&o[0], "Workspace", "item 0").unwrap_err().contains("ClassName"));
        let o = objects(&json!({ "ClassName": "Part", "Size": "4, 1, 2", ".A": true })).unwrap();
        let entry = create_entry(&o[0], "Workspace", "item 0").unwrap();
        assert_eq!(entry["parent"], "Workspace");
        assert_eq!(entry["properties"]["Size"], "4, 1, 2");
        assert_eq!(entry["tags"]["add"][0], "A");
    }

    #[test]
    fn round_trips_through_inspect_shape() {
        let item = json!({
            "className": "Part",
            "properties": { "Size": "4, 1, 2", "Anchored": true, "Transparency": 0.5, "Name": "Wall" },
            "attributes": { "Speed": 2 },
            "tags": ["Hit"],
        });
        let out = from_inspect(&item);
        let keys: Vec<&String> = out.as_object().unwrap().keys().collect();
        assert_eq!(keys.first().map(|k| k.as_str()), Some("Name"));
        assert_eq!(keys.last().map(|k| k.as_str()), Some("ClassName"));
        assert_eq!(out["Anchored"], "true");
        assert_eq!(out["Transparency"], "0.5");
        assert_eq!(out["$Speed"], 2);
        assert_eq!(out[".Hit"], true);
        let back = split(out.as_object().unwrap(), "x").unwrap();
        assert_eq!(back.class_name.as_deref(), Some("Part"));
        assert_eq!(back.name.as_deref(), Some("Wall"));
        assert_eq!(back.properties.len(), 3);
    }
}
