//! screenshot: the viewport as an image the model can look at.

use super::{call, str_of, u64_of};
use crate::errors::{Result, ToolError};
use crate::format::{ToolResult, image};
use crate::png;
use crate::protocol::StudioSession;
use crate::tool::{Ctx, Tool, define, spec};
use base64::Engine;
use base64::engine::general_purpose::STANDARD;
use schemars::JsonSchema;
use serde::Deserialize;
use serde_json::{Value, json};
use std::sync::Arc;

const MIN_ZOOM_SIDE: usize = 480;
const SINGLE_WIDTH: u32 = 800;
const SHEET_WIDTH: u32 = 1200;
const SHEET_GAP: usize = 4;

fn d250() -> u32 {
    250
}

fn d1() -> u32 {
    1
}

#[derive(Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
struct ShotArgs {
    /// Largest width of the image, in pixels (default 800; 1200 for a frame sequence, shared by its frames); height follows the aspect ratio. Never scales up. To read small text, zoom with `path` or `rect` rather than raising this.
    #[schemars(range(min = 160, max = 1600))]
    width: Option<u32>,
    /// Take this many shots, `intervalMs` apart, returned as one contact sheet read left to right, top to bottom. Use it to check motion — a tween, an animation, a door, a projectile — which one still cannot show. Things only move in a playtest or Run mode.
    #[serde(default = "d1")]
    #[schemars(range(min = 1, max = 12))]
    frames: u32,
    /// With `frames`: time between shots in milliseconds. A shot takes ~0.5 s in the editor, so shorter intervals stretch to that; the caption gives the real times.
    #[serde(default = "d250")]
    #[schemars(range(min = 30, max = 2000))]
    interval_ms: u32,
    /// Zoom to this instance at full resolution: a GUI element, a part, a model, or a folder of parts. Also resolves client-only instances in playtests; it must be on screen.
    path: Option<String>,
    /// Zoom to "x, y, width, height" in viewport pixels. Read them off an earlier screenshot using the scale its caption states.
    rect: Option<String>,
    /// Target Studio; omit for the active one.
    studio_id: Option<String>,
    /// Playtest only: whose screen to capture. Required when the test has several players.
    player: Option<String>,
}

struct Pixels {
    png: String,
    width: usize,
    height: usize,
    enlarged: Option<usize>,
}

/// One frame of a sequence as raw RGB, scaled but never enlarged.
fn frame_rgb(r: &Value) -> Result<(Vec<u8>, usize, usize)> {
    if str_of(r, "encoding") != Some("zstd-rgb") {
        return Err(ToolError::hint(
            "FRAMES_UNSUPPORTED",
            "This Studio build sends screenshots without EncodingService, so frames cannot be combined.",
            "Update Studio, or take single screenshots.",
        ));
    }
    let (w, h) = (u64_of(r, "width") as usize, u64_of(r, "height") as usize);
    let compressed = STANDARD.decode(str_of(r, "data").unwrap_or("")).map_err(|e| ToolError::internal(format!("bad screenshot payload: {e}")))?;
    let rgb = png::zstd_decode(&compressed).map_err(|e| ToolError::internal(format!("bad screenshot payload: {e}")))?;
    if rgb.len() < w * h * 3 {
        return Err(ToolError::internal(format!("screenshot frame is {} bytes, short of {w}x{h}", rgb.len())));
    }
    match r.get("scaleTo").and_then(Value::as_u64).map(|s| s as usize).filter(|to| w > *to) {
        Some(to) => Ok(png::box_resample(&rgb, w, h, to)),
        None => Ok((rgb, w, h)),
    }
}

/// Columns for a contact sheet of `n` frames: as square as possible, wider than tall.
fn sheet_columns(n: usize) -> usize {
    (n as f64).sqrt().ceil().max(1.0) as usize
}

/// Width each frame is captured at so the sheet comes out `sheet` wide.
fn frame_width(sheet: u32, n: usize) -> u32 {
    let cols = sheet_columns(n) as u32;
    ((sheet.saturating_sub(SHEET_GAP as u32 * (cols - 1))) / cols).max(160)
}

/// Turns whatever the plugin sent into base64 PNG (off the async thread: it is CPU work).
fn to_png(r: &Value) -> Result<Pixels> {
    let width = u64_of(r, "width") as usize;
    let height = u64_of(r, "height") as usize;
    let data = str_of(r, "data").unwrap_or("");
    if str_of(r, "encoding") != Some("zstd-rgb") {
        return Ok(Pixels { png: data.to_string(), width, height, enlarged: None });
    }
    let compressed = STANDARD.decode(data).map_err(|e| ToolError::internal(format!("bad screenshot payload: {e}")))?;
    let mut rgb = png::zstd_decode(&compressed).map_err(|e| ToolError::internal(format!("bad screenshot payload: {e}")))?;
    let (mut w, mut h) = (width, height);
    let scale_to = r.get("scaleTo").and_then(Value::as_u64).map(|s| s as usize);
    if let Some(to) = scale_to.filter(|to| w > *to) {
        let (out, nw, nh) = png::box_resample(&rgb, w, h, to);
        (rgb, w, h) = (out, nw, nh);
    }
    let mut enlarged = None;
    if let (Some(_), Some(to)) = (r.get("region").filter(|v| !v.is_null()), scale_to) {
        let factor = 4.min(to / w.max(1)).min(MIN_ZOOM_SIDE / w.max(h).max(1));
        if factor > 1 {
            let (out, nw, nh) = png::upscale_nearest(&rgb, w, h, factor);
            (rgb, w, h) = (out, nw, nh);
            enlarged = Some(factor);
        }
    }
    let encoded = png::encode(&rgb, w, h).map_err(ToolError::internal)?;
    Ok(Pixels { png: STANDARD.encode(encoded), width: w, height: h, enlarged })
}

fn is_playtest(s: &StudioSession) -> bool {
    s.identity.context.as_deref().unwrap_or("").starts_with("playtest")
}

/// A playtest shot takes two sessions: the client captures, the editor decodes.
async fn playtest_shot(ctx: &Ctx, playtest: &StudioSession, sessions: &[StudioSession], a: &ShotArgs, width: u32) -> Result<Value> {
    let editor = sessions
        .iter()
        .find(|s| s.identity.place_id == playtest.identity.place_id && !is_playtest(s))
        .ok_or_else(|| {
            ToolError::hint(
                "NO_EDITOR_SESSION",
                "The playtest is connected but its editor session is not, and reading the captured image needs the editor's plugin identity.",
                "The editor window must stay connected while the playtest runs. Check `list_studios` — there should be two entries for this place.",
            )
        })?;
    let captured = call(
        ctx,
        "capture.playtestId",
        json!({
            "player": a.player, "path": a.path, "rect": a.rect,
            "frames": a.frames, "interval": a.interval_ms as f64 / 1000.0,
        }),
        Some(&playtest.identity.studio_id),
        Some(40_000.0 + sequence_ms(a)),
    )
    .await?;
    let ids = super::arr_of(&captured, "contentIds");
    if ids.len() > 1 {
        let times = super::arr_of(&captured, "times");
        let mut frames = Vec::with_capacity(ids.len());
        for (i, id) in ids.iter().enumerate() {
            let mut frame = call(
                ctx,
                "capture.decode",
                json!({ "contentId": id, "width": width, "rect": a.rect, "region": captured.get("region"), "context": "playtest client" }),
                Some(&editor.identity.studio_id),
                Some(60_000.0),
            )
            .await?;
            frame["t"] = times.get(i).cloned().unwrap_or(Value::Null);
            frames.push(frame);
        }
        return Ok(json!({ "frames": frames, "context": "playtest client" }));
    }
    // Straight on: the texture is temporary.
    let mut decoded = call(
        ctx,
        "capture.decode",
        json!({
            "contentId": captured.get("contentId"), "width": width, "rect": a.rect,
            "region": captured.get("region"), "context": "playtest client",
        }),
        Some(&editor.identity.studio_id),
        Some(60_000.0),
    )
    .await?;
    if let Some(obj) = decoded.as_object_mut() {
        for key in ["billboards", "billboardError"] {
            if let Some(v) = captured.get(key) {
                obj.insert(key.into(), v.clone());
            }
        }
    }
    Ok(decoded)
}

async fn screenshot(ctx: Arc<Ctx>, a: ShotArgs) -> Result<ToolResult> {
    let view = ctx.bridge.sessions().await?;
    let target = match (&a.studio_id, &view.active_id) {
        (Some(id), _) => view.list.iter().find(|s| &s.identity.studio_id == id),
        (None, Some(active)) => view.list.iter().find(|s| &s.identity.studio_id == active),
        (None, None) if view.list.len() == 1 => view.list.first(),
        _ => None,
    };
    let n = a.frames.clamp(1, 12) as usize;
    let width = if n > 1 { frame_width(a.width.unwrap_or(SHEET_WIDTH), n) } else { a.width.unwrap_or(SINGLE_WIDTH) };
    let r = match target.filter(|t| is_playtest(t)) {
        Some(t) => playtest_shot(&ctx, t, &view.list, &a, width).await?,
        None => {
            call(
                &ctx,
                "capture.screenshot",
                json!({
                    "width": width, "path": a.path, "rect": a.rect,
                    "frames": n, "interval": a.interval_ms as f64 / 1000.0,
                }),
                a.studio_id.as_deref(),
                Some(60_000.0 + sequence_ms(&a)),
            )
            .await?
        }
    };
    if let Some(frames) = r.get("frames").and_then(Value::as_array).filter(|f| f.len() > 1) {
        return sheet(frames.clone()).await;
    }
    let r = Arc::new(r);
    let decoded = {
        let r = r.clone();
        tokio::task::spawn_blocking(move || to_png(&r)).await.map_err(ToolError::internal)??
    };

    let context = str_of(&r, "context").unwrap_or("");
    let source_w = u64_of(&r, "sourceWidth");
    let source_h = u64_of(&r, "sourceHeight");
    let emulating = str_of(&r, "device")
        .map(|d| format!(" Emulating {d} — call `device op=\"stop\"` for the normal viewport."))
        .unwrap_or_default();
    let blank = if r.get("black") == Some(&Value::Bool(true)) {
        " WARNING: nothing was rendered into this capture — it is a single flat colour. The usual causes are that the \
         3D view is not the active tab — a script editor open in front of it returns the editor's background — or that \
         Studio was not rendering at all: minimised, fully covered by another window, or on a virtual desktop that is \
         not on screen. Ask the user to bring the 3D view to the front and take it again before drawing any conclusion \
         from what is in this image."
    } else {
        ""
    };
    let region = r.get("region").filter(|v| v.is_object());
    let shown = match region {
        Some(reg) => format!(
            " zoomed to {}: rect \"{}, {}, {}, {}\" of the {source_w}x{source_h} viewport",
            a.path.as_deref().unwrap_or("the rect"),
            super::disp(reg.get("x")),
            super::disp(reg.get("y")),
            super::disp(reg.get("width")),
            super::disp(reg.get("height"))
        ),
        None => format!(" of the {source_w}x{source_h} viewport"),
    };
    let base = region.and_then(|reg| reg.get("width")).and_then(Value::as_f64).unwrap_or(source_w as f64);
    let factor = base / decoded.width.max(1) as f64;
    let scale = match decoded.enlarged {
        Some(k) => format!(
            " (enlarged {k}x for viewing: each {k}x{k} block is one viewport px. For real detail, move the camera closer with `viewport op=\"focus\"` first)"
        ),
        None if factor > 1.001 => format!(" (1 image px = {factor:.2} viewport px)"),
        None => " (full resolution)".into(),
    };
    let billboards = r
        .get("billboards")
        .and_then(Value::as_u64)
        .map(|n| {
            format!(
                " {n} BillboardGui/ProximityPrompt{} redrawn onto the capture, which the engine leaves out; depth is not reproduced, so one hidden behind a wall still shows.",
                if n == 1 { "" } else { "s" }
            )
        })
        .unwrap_or_default();
    let redraw_failed = str_of(&r, "billboardError")
        .map(|e| format!(" BillboardGuis could not be redrawn ({e}), so any on screen are missing from this image."))
        .unwrap_or_default();
    let core_gui = if context == "playtest client" { " Roblox's top bar is never captured." } else { "" };
    Ok(image(
        decoded.png,
        format!(
            "Studio viewport ({context}), {}x{}{shown}{scale}.{billboards}{redraw_failed}{core_gui}{emulating}{blank}",
            decoded.width, decoded.height
        ),
        "image/png",
    ))
}

/// Extra time a frame sequence needs on top of a single shot.
fn sequence_ms(a: &ShotArgs) -> f64 {
    (a.frames.saturating_sub(1) * a.interval_ms) as f64 * 1.5
}

/// A frame sequence as one contact sheet, with when each frame was taken.
async fn sheet(frames: Vec<Value>) -> Result<ToolResult> {
    let first = frames[0].clone();
    let times: Vec<String> = frames.iter().map(|f| super::disp(f.get("t"))).collect();
    let blank = frames.iter().filter(|f| f.get("black") == Some(&Value::Bool(true))).count();
    let (encoded, w, h, fw, fh, cols) = tokio::task::spawn_blocking(move || -> Result<_> {
        let decoded: Vec<(Vec<u8>, usize, usize)> = frames.iter().map(frame_rgb).collect::<Result<_>>()?;
        let cols = sheet_columns(decoded.len());
        let (fw, fh) = (decoded[0].1, decoded[0].2);
        let (rgb, w, h) = png::contact_sheet(&decoded, cols, SHEET_GAP);
        let encoded = png::encode(&rgb, w, h).map_err(ToolError::internal)?;
        Ok((STANDARD.encode(encoded), w, h, fw, fh, cols))
    })
    .await
    .map_err(ToolError::internal)??;
    let n = times.len();
    let rows = n.div_ceil(cols);
    let context = str_of(&first, "context").unwrap_or("");
    let region = first.get("region").filter(|v| v.is_object()).map(|reg| {
        format!(
            ", zoomed to rect \"{}, {}, {}, {}\"",
            super::disp(reg.get("x")),
            super::disp(reg.get("y")),
            super::disp(reg.get("width")),
            super::disp(reg.get("height"))
        )
    });
    let blank_note = if blank > 0 {
        format!(" WARNING: {blank} of the frames are a single flat colour — Studio was not rendering the 3D view (another tab in front, minimised or covered).")
    } else {
        String::new()
    };
    let emulating = str_of(&first, "device")
        .map(|d| format!(" Emulating {d} — call `device op=\"stop\"` for the normal viewport."))
        .unwrap_or_default();
    Ok(image(
        encoded,
        format!(
            "Studio viewport ({context}), {n} frames as a {cols}x{rows} contact sheet ({w}x{h}), read left to right then top to bottom. \
             Each frame {fw}x{fh} of the {}x{} viewport{}. Taken at {} ms after the first.{blank_note}{emulating}",
            u64_of(&first, "sourceWidth"),
            u64_of(&first, "sourceHeight"),
            region.unwrap_or_default(),
            times.join(", "),
        ),
        "image/png",
    ))
}

pub fn tools() -> Vec<Tool> {
    vec![define(
        spec("screenshot", "See the Studio viewport").read_only(),
        "Takes a picture of the Studio viewport and returns it as an image you can actually look at.\n\n\
         Every other tool here reads the data model — names, properties, numbers — which answers 'is it there' but \
         never 'does it look right'. A part can be at the correct position, anchored, correctly sized, and still be \
         buried inside a wall, facing backwards, or hidden behind a GUI. Take a screenshot after building something \
         visual, and before reporting that it worked.\n\n\
         It captures the viewport as the user currently sees it, so it shows their camera angle, not a framing of your \
         choosing. Frame the subject with `viewport op=\"focus\"` first — that is what makes this tool worth calling.\n\n\
         Works during a playtest too — address it at the playtest's studioId and you get the player's own view, which \
         is the only way to check what a GUI actually looks like in front of the game. That one is taken on the client \
         and read back through the editor session, so it is a little slower and needs the editor window still \
         connected; the caption says `playtest client` when it came from there.\n\n\
         `frames` (2-12) takes a timed sequence, `intervalMs` apart, returned as one contact sheet: use it to check that \
         something moves, eases or animates the way it should. Start the motion first (a playtest, or `execute_luau` \
         in Run mode), then capture.",
        screenshot,
    )]
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sheet_layout_is_near_square() {
        assert_eq!(sheet_columns(1), 1);
        assert_eq!(sheet_columns(4), 2);
        assert_eq!(sheet_columns(6), 3);
        assert_eq!(sheet_columns(12), 4);
    }

    #[test]
    fn frame_width_fills_the_sheet() {
        assert_eq!(frame_width(1200, 4), 598);
        assert_eq!(frame_width(1200, 9), 397);
        assert_eq!(frame_width(160, 12), 160);
    }

    #[test]
    fn frames_default_to_one_shot() {
        let a: ShotArgs = serde_json::from_value(json!({})).unwrap();
        assert_eq!((a.frames, a.interval_ms, a.width), (1, 250, None));
        assert_eq!(sequence_ms(&a), 0.0);
    }
}
