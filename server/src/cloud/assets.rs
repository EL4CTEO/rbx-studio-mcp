//! Putting local files into Roblox: upload, grant, publish.

use super::credentials::Credentials;
use super::{Call, call, enc};
use crate::errors::{Result, ToolError, poll_delay_ms};
use crate::format::prune;
use crate::tool::report_progress;
use serde_json::{Value, json};
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

const MAX_BYTES: u64 = 20 * 1024 * 1024;
const POLL_TIMEOUT: Duration = Duration::from_secs(90);
const POLL_CEILING_MS: u64 = 2_000;

/// Extension to (assetType, content type); derived from the file, not asked for.
const KINDS: [(&str, &str, &str); 14] = [
    (".mp3", "Audio", "audio/mpeg"),
    (".ogg", "Audio", "audio/ogg"),
    (".wav", "Audio", "audio/wav"),
    (".flac", "Audio", "audio/flac"),
    (".png", "Decal", "image/png"),
    (".jpg", "Decal", "image/jpeg"),
    (".jpeg", "Decal", "image/jpeg"),
    (".bmp", "Decal", "image/bmp"),
    (".tga", "Decal", "image/tga"),
    (".fbx", "Model", "model/fbx"),
    (".gltf", "Model", "model/gltf+json"),
    (".glb", "Model", "model/gltf-binary"),
    (".mp4", "Video", "video/mp4"),
    (".mov", "Video", "video/mov"),
];

struct Local {
    path: PathBuf,
    bytes: Vec<u8>,
    extension: String,
}

async fn read_local(file: &str, allowed: Option<&[&str]>) -> Result<Local> {
    let path = std::path::absolute(file).unwrap_or_else(|_| PathBuf::from(file));
    let meta = tokio::fs::metadata(&path).await.map_err(|_| {
        ToolError::hint(
            "NO_FILE",
            format!("There is no file at {}.", path.display()),
            "Give an absolute path, or one relative to where the server was started.",
        )
    })?;
    if meta.len() == 0 {
        return Err(ToolError::new("EMPTY_FILE", format!("{} is empty.", path.display())));
    }
    if meta.len() > MAX_BYTES {
        return Err(ToolError::new(
            "TOO_BIG",
            format!("{} is {:.1}MB; the limit is 20MB.", path.display(), meta.len() as f64 / 1024.0 / 1024.0),
        ));
    }
    let extension = path.extension().map(|e| format!(".{}", e.to_string_lossy().to_lowercase())).unwrap_or_default();
    if let Some(allowed) = allowed
        && !allowed.contains(&extension.as_str()) {
            return Err(ToolError::new(
                "WRONG_KIND",
                format!(
                    "This takes {}, not {}.",
                    allowed.join(" or "),
                    if extension.is_empty() { "a file with no extension" } else { &extension }
                ),
            ));
        }
    let bytes = tokio::fs::read(&path).await?;
    Ok(Local { path, bytes, extension })
}

fn stem(path: &Path) -> String {
    path.file_stem().map(|s| s.to_string_lossy().into_owned()).unwrap_or_default()
}

pub async fn upload(credentials: &Credentials, file: &str, name: Option<&str>, description: Option<&str>, asset_type: Option<&str>) -> Result<Value> {
    let local = read_local(file, None).await?;
    let Some((_, kind_type, content_type)) = KINDS.iter().find(|(ext, _, _)| *ext == local.extension) else {
        return Err(ToolError::hint(
            "WRONG_KIND",
            format!(
                "Roblox does not take {} through Open Cloud.",
                if local.extension.is_empty() { "files with no extension" } else { &local.extension }
            ),
            format!("It takes: {}.", KINDS.iter().map(|k| k.0).collect::<Vec<_>>().join(", ")),
        ));
    };
    let asset_type = asset_type.unwrap_or(kind_type).to_string();
    let request = json!({
        "assetType": asset_type,
        "displayName": name.map(str::to_string).unwrap_or_else(|| stem(&local.path)),
        "description": description.unwrap_or(""),
        "creationContext": { "creator": { credentials.creator_field: credentials.creator_id } },
    })
    .to_string();
    let file_name = local.path.file_name().map(|f| f.to_string_lossy().into_owned()).unwrap_or_default();
    let bytes = local.bytes.clone();
    let content_type = content_type.to_string();
    let started = call(
        credentials,
        &Call::post("/assets/v1/assets", "assets:write").form(move || {
            let part = reqwest::multipart::Part::bytes(bytes.clone())
                .file_name(file_name.clone())
                .mime_str(&content_type)
                .unwrap_or_else(|_| reqwest::multipart::Part::bytes(bytes.clone()));
            reqwest::multipart::Form::new().text("request", request.clone()).part("fileContent", part)
        }),
    )
    .await?;
    let Some(op_path) = started.get("path").and_then(Value::as_str) else {
        return Err(ToolError::hint(
            "NO_OPERATION",
            "Roblox accepted the upload but did not say where to track it.",
            "Check the Development Items tab on the Creator Dashboard.",
        ));
    };
    let finished = poll(credentials, op_path).await?;
    let asset_id = finished.pointer("/response/assetId").and_then(|v| v.as_str().map(str::to_string).or_else(|| v.as_u64().map(|n| n.to_string())));
    let Some(asset_id) = asset_id.filter(|_| finished.get("error").is_none_or(Value::is_null)) else {
        let why = finished
            .pointer("/error/message")
            .or_else(|| finished.get("message"))
            .and_then(Value::as_str)
            .unwrap_or("no reason given");
        return Err(ToolError::new("UPLOAD_REJECTED", format!("The upload failed moderation or validation: {why}")));
    };
    // Roblox spells the verdict two ways; both mean approved.
    let state = finished.pointer("/response/moderationResult/moderationState").and_then(Value::as_str).unwrap_or("unknown").to_string();
    Ok(prune(json!({
        "assetId": asset_id,
        "approved": state == "Approved" || state == "MODERATION_STATE_APPROVED",
        "assetType": asset_type,
        "uri": format!("rbxassetid://{asset_id}"),
        "name": finished.pointer("/response/displayName"),
        "moderation": state,
        "uploadedAs": format!("{} {}", credentials.creator_field, credentials.creator_id),
        "file": local.path.to_string_lossy(),
    })))
}

async fn poll(credentials: &Credentials, operation_path: &str) -> Result<Value> {
    let id = operation_path.strip_prefix("operations/").unwrap_or(operation_path);
    let deadline = Instant::now() + POLL_TIMEOUT;
    let mut attempt = 0;
    loop {
        let op = call(credentials, &Call::get(format!("/assets/v1/operations/{id}"), "assets:write")).await?;
        if op.get("done").and_then(Value::as_bool) == Some(true) {
            return Ok(op);
        }
        if Instant::now() >= deadline {
            return Err(ToolError::hint(
                "STILL_PROCESSING",
                format!("Still processing after {}s. It has not failed — moderation can take longer.", POLL_TIMEOUT.as_secs()),
                "Check the Development Items tab on the Creator Dashboard in a minute.",
            ));
        }
        report_progress("waiting for Roblox to finish processing the asset");
        tokio::time::sleep(Duration::from_millis(poll_delay_ms(attempt, POLL_CEILING_MS, 600))).await;
        attempt += 1;
    }
}

/// Grants a game or person use of assets you own. Permanent for games.
pub async fn grant(credentials: &Credentials, asset_ids: &[i64], subject_type: &str, subject_id: &str) -> Result<Value> {
    let requests: Vec<Value> = asset_ids.iter().map(|id| json!({ "assetId": id })).collect();
    let result = call(
        credentials,
        &Call::patch("/asset-permissions-api/v1/assets/permissions", "asset-permissions:write").json(json!({
            "subjectType": subject_type,
            "subjectId": subject_id,
            "action": "Use",
            "requests": requests,
        })),
    )
    .await?;
    let granted = result.get("successAssetIds").cloned().unwrap_or(json!([]));
    let errors = result.get("errors").and_then(Value::as_array).cloned().unwrap_or_default();
    // AlreadyHasAccess is reported as an error and is not one.
    let already = |e: &Value| e.get("code").and_then(Value::as_str) == Some("AlreadyHasAccess");
    Ok(json!({
        "granted": granted,
        "grantedCount": granted.as_array().map(Vec::len).unwrap_or(0),
        "subject": format!("{subject_type} {subject_id}"),
        "failed": errors.iter().filter(|e| !already(e)).map(|e| prune(json!({ "assetId": e.get("assetId"), "reason": e.get("code") }))).collect::<Vec<_>>(),
        "alreadyHad": errors.iter().filter(|e| already(e)).filter_map(|e| e.get("assetId").cloned()).collect::<Vec<_>>(),
    }))
}

/// Publishes (or only saves) a .rbxl / .rbxlx from disk to a place.
pub async fn publish_place(credentials: &Credentials, file: &str, universe: &str, place: &str, publish: bool) -> Result<Value> {
    let local = read_local(file, Some(&[".rbxl", ".rbxlx"])).await?;
    let content_type = if local.extension == ".rbxlx" { "application/xml" } else { "application/octet-stream" };
    let result = call(
        credentials,
        &Call::post(format!("/universes/v1/{}/places/{}/versions", enc(universe), enc(place)), "universe-places:write")
            .query("versionType", if publish { "Published" } else { "Saved" })
            .raw(local.bytes, content_type)
            .timeout(180_000),
    )
    .await?;
    Ok(prune(json!({
        "placeId": place,
        "universeId": universe,
        "versionNumber": result.get("versionNumber"),
        "published": publish,
        "file": local.path.to_string_lossy(),
        "note": if publish {
            "This is live to players now."
        } else {
            "Saved as a new version but NOT live. Call `publish` again with confirm: true to release it."
        },
        "caveat": "Roblox's publishing API does not update EditableImage, EditableMesh, PartOperation, SurfaceAppearance or BaseWrap instances. If the place uses any of those, publish from Studio instead — this call reports success either way.",
    })))
}
