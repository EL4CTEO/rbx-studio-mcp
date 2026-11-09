//! input and device.

use super::{arr_of, call, str_of};
use crate::errors::{Result, normalize_timeout_ms};
use crate::format::{PageMeta, ToolResult, error_text, json, table, text, to_flat};
use crate::tool::{Ctx, Tool, define, spec};
use schemars::JsonSchema;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::sync::Arc;

#[derive(Deserialize, Serialize, JsonSchema, Default, Clone, Copy)]
#[serde(rename_all = "lowercase")]
enum StepKind {
    #[default]
    Key,
    Click,
    Move,
    Text,
}

#[derive(Deserialize, Serialize, JsonSchema, Clone, Copy)]
#[serde(rename_all = "lowercase")]
enum KeyAction {
    Tap,
    Press,
    Release,
}

#[derive(Deserialize, Serialize, JsonSchema, Clone, Copy)]
enum MouseButton {
    MouseButton1,
    MouseButton2,
    MouseButton3,
}

#[derive(Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
struct Step {
    /// 'key' presses a keyboard key, 'click' a mouse button at a point, 'move' just moves the pointer, 'text' types a string.
    #[serde(default)]
    kind: StepKind,
    /// key only: an Enum.KeyCode name — "W", "Space", "E", "LeftShift".
    #[serde(skip_serializing_if = "Option::is_none")]
    key: Option<String>,
    /// 'tap' presses and releases (the default), 'press' holds it down until a later 'release', 'release' lets go. Use press/release across steps to hold a key while doing something else.
    #[serde(skip_serializing_if = "Option::is_none")]
    action: Option<KeyAction>,
    /// click only: which button. Defaults to left.
    #[serde(skip_serializing_if = "Option::is_none")]
    button: Option<MouseButton>,
    /// click/text only: client GUI path, e.g. PlayerGui.HUD.BuyButton. Clicks its centre; focuses TextBoxes before typing.
    #[serde(skip_serializing_if = "Option::is_none")]
    #[schemars(length(min = 1))]
    target: Option<String>,
    /// click/move only: viewport pixels from the left.
    #[serde(skip_serializing_if = "Option::is_none")]
    x: Option<f64>,
    /// click/move only: viewport pixels from the top.
    #[serde(skip_serializing_if = "Option::is_none")]
    y: Option<f64>,
    /// text only: the string to type. Goes to the focused TextBox — click it first, in the same call.
    #[serde(skip_serializing_if = "Option::is_none")]
    text: Option<String>,
    /// Seconds to hold the key or button down before releasing it.
    #[serde(skip_serializing_if = "Option::is_none")]
    #[schemars(range(min = 0, max = 10))]
    hold: Option<f64>,
    /// Seconds to wait after this step before the next one.
    #[serde(skip_serializing_if = "Option::is_none")]
    #[schemars(range(min = 0, max = 10))]
    after: Option<f64>,
}

#[derive(Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
struct InputArgs {
    /// Input steps, delivered in order.
    #[schemars(length(min = 1, max = 40))]
    steps: Vec<Step>,
    /// Which player, by name. Omit for the only one; needed in a multiplayer test.
    player: Option<String>,
    /// Draw a pointer on screen that travels to each target before the click, with a ripple where it lands. On by default: synthetic input is otherwise invisible, so the user watching sees effects with no cause, and a click that misses looks identical to one that hit. Turn it off only when recording something where the pointer would be in the way.
    #[serde(default = "super::d::t")]
    cursor: bool,
    /// The PLAYTEST session's id — not the editor's. See list_studios.
    studio_id: Option<String>,
}

/// The gap between where a click was aimed and where the client read it.
fn landing_note(landed: &Value) -> String {
    let n = |p: &str| landed.pointer(p).and_then(Value::as_f64).unwrap_or(0.0);
    let (sx, sy, x, y) = (n("/sent/x"), n("/sent/y"), n("/seen/x"), n("/seen/y"));
    let f = |v: f64| to_flat(&json!(v));
    let (dx, dy) = (x - sx, y - sy);
    if dx == 0.0 && dy == 0.0 {
        return format!(
            "The last click was aimed at ({}, {}) and the client read it there, so screen coordinates are landing exactly.",
            f(sx),
            f(sy)
        );
    }
    if dx == 0.0 {
        return format!(
            "Aimed at ({}, {}), read by the client at ({}, {}) — the same point, {}px apart because a screenshot counts \
             from the top of the window and the game counts from below the topbar. Screenshot coordinates are what to \
             send, unchanged. The `seen` value is the one to compare against a GuiObject's AbsolutePosition.",
            f(sx),
            f(sy),
            f(x),
            f(y),
            f(-dy)
        );
    }
    format!(
        "COORDINATES ARE DISTORTED: aimed at ({}, {}), the client read ({}, {}) — off by ({}, {}), and the horizontal \
         term means this is not just the topbar inset. Emulated landscape does this, and there the map is not a \
         translation at all — so treat this as one sample: click, read this field again, and correct from the newest \
         one rather than reusing an earlier value.",
        f(sx),
        f(sy),
        f(x),
        f(y),
        f(dx),
        f(dy)
    )
}

async fn input(ctx: Arc<Ctx>, a: InputArgs) -> Result<ToolResult> {
    // Mirrors the plugin's budget (20s + holds + waits + 0.5s a step) with room for the round trip.
    let budget: f64 = 35.0 + a.steps.iter().map(|s| s.hold.unwrap_or(0.0) + s.after.unwrap_or(0.0) + 0.5).sum::<f64>();
    let timeout = normalize_timeout_ms(budget * 1000.0, 0)? as f64;
    let r = call(
        &ctx,
        "input.send",
        json!({ "steps": a.steps, "player": a.player, "cursor": a.cursor }),
        a.studio_id.as_deref(),
        Some(timeout),
    )
    .await?;
    let mut parts: Vec<String> = vec!["Delivered on the client and confirmed back.".into()];
    if let Some(e) = r.get("emulation").filter(|e| e.is_object()) {
        parts.push(format!(
            "NOTE: {} is being emulated{}. `device op=\"stop\"` returns the viewport to normal.",
            str_of(e, "id").unwrap_or(""),
            str_of(e, "resolution").map(|res| format!(" at {res}")).unwrap_or_default()
        ));
    }
    if let Some(landed) = r.get("landed").filter(|l| l.is_object()) {
        parts.push(landing_note(landed));
    } else if arr_of(&r, "performed").iter().any(|k| k.as_str() == Some("click")) {
        parts.push(
            "WARNING: a click was sent but the client read no pointer event for it, so it did not register at all. \
             Check that a playtest is actually in focus and that nothing is covering the target."
                .into(),
        );
    } else {
        parts.push("Read the result with `character op=\"state\"`, `console`, or `screenshot`.".into());
    }
    // A step that ran and changed nothing goes first, where it cannot be skimmed past.
    let warnings: Vec<String> = arr_of(&r, "notes").iter().filter_map(Value::as_str).map(|l| format!("WARNING: {l}")).collect();
    let note = warnings.into_iter().chain(parts).collect::<Vec<_>>().join(" ");
    Ok(json(&r, Some(&note)))
}

#[derive(Deserialize, JsonSchema, Default, PartialEq, Clone, Copy)]
#[serde(rename_all = "lowercase")]
enum DeviceOp {
    List,
    Set,
    Network,
    Stop,
    #[default]
    State,
}

#[derive(Deserialize, Serialize, JsonSchema, Clone, Copy)]
enum Orientation {
    LandscapeLeft,
    LandscapeRight,
    Portrait,
    Sensor,
}

#[derive(Deserialize, Serialize, JsonSchema, Clone, Copy, PartialEq)]
enum Form {
    Phone,
    Tablet,
    Console,
    Desktop,
    #[serde(rename = "VR")]
    Vr,
}

#[derive(Deserialize, Serialize, JsonSchema, Clone, Copy)]
#[serde(rename_all = "lowercase")]
enum Preset {
    Clear,
    Wifi,
    #[serde(rename = "4g")]
    G4,
    #[serde(rename = "3g")]
    G3,
    Poor,
}

#[derive(Deserialize, Serialize, JsonSchema, Clone, Copy)]
#[serde(rename_all = "lowercase")]
enum Direction {
    In,
    Out,
    Both,
}

#[derive(Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
struct DeviceArgs {
    /// 'list' shows the available devices, 'set' switches to one, 'network' shapes the connection, 'stop' undoes both, 'state' only reports.
    #[serde(default)]
    op: DeviceOp,
    /// set only: the device id, e.g. "iphone_16". See `list`.
    device: Option<String>,
    /// set only: which way up. Portrait is worth testing separately — most mobile players hold the phone upright and most UI is only ever checked in landscape.
    orientation: Option<Orientation>,
    /// list only: show only devices of this form factor.
    form: Option<Form>,
    /// network only: a whole connection in one word. clear=0ms (normal), wifi=15ms, 4g=60ms/0.1% loss, 3g=150ms/0.3% loss, poor=400ms/0.5% loss. Named fields below override whichever part you name.
    preset: Option<Preset>,
    /// network only: minimum delay in milliseconds, up to 1000 — the engine's own ceiling. 0 clears it.
    #[schemars(range(min = 0, max = 1000))]
    latency: Option<f64>,
    /// network only: how much the delay varies, in milliseconds. Jitter breaks things steady latency does not — it is what makes replicated motion stutter rather than simply lag.
    #[schemars(range(min = 0, max = 1000))]
    jitter: Option<f64>,
    /// network only: percentage of packets thrown away, up to 0.5 — Roblox caps it there so the simulation does not fight congestion control. Latency makes a game feel slow; loss makes unreliable remotes arrive out of order or not at all.
    #[schemars(range(min = 0, max = 0.5))]
    loss: Option<f64>,
    /// network only: pretend the machine has this many MB of memory. A cheap phone is a small screen AND little memory; this is the half that makes textures unload. 0 removes the cap, restoring the real amount.
    #[schemars(range(min = 0, max = 65536))]
    memory: Option<u32>,
    /// network only: which way to degrade. 'in' is the player with a bad connection, 'out' is everyone else seeing that player late. Defaults to both.
    direction: Option<Direction>,
    /// Target Studio; omit for the active one.
    studio_id: Option<String>,
}

async fn device(ctx: Arc<Ctx>, a: DeviceArgs) -> Result<ToolResult> {
    let studio = a.studio_id.as_deref();
    match a.op {
        DeviceOp::List => {
            // One GetDeviceInfoAsync per device, and there are around forty.
            let r = call(&ctx, "device.list", json!({}), studio, Some(45_000.0)).await?;
            let form = a.form.map(|f| serde_json::to_value(f).unwrap_or_default());
            let rows: Vec<Value> = arr_of(&r, "devices").iter().filter(|d| form.as_ref().is_none_or(|f| d.get("form") == Some(f))).cloned().collect();
            let count = super::disp(r.get("count"));
            if rows.is_empty() {
                return Ok(text(format!(
                    "No {} devices are available. Studio offers {count} in total; call again without `form` to see them.",
                    form.as_ref().and_then(Value::as_str).unwrap_or("")
                )));
            }
            let current = r.pointer("/current/device").cloned().unwrap_or(json!("default"));
            Ok(table(
                &["id", "name", "form", "resolution"],
                &rows,
                PageMeta { more: Some(format!("{} of {count} devices; currently {}", rows.len(), to_flat(&current))), ..Default::default() },
            ))
        }
        DeviceOp::Set if a.device.as_deref().is_none_or(str::is_empty) => {
            Ok(error_text("set needs a `device` id. Call `device op=\"list\"` to see them."))
        }
        DeviceOp::Network => {
            let shaped = call(
                &ctx,
                "device.network",
                json!({
                    "preset": a.preset, "latency": a.latency, "jitter": a.jitter, "loss": a.loss,
                    "memory": a.memory, "direction": a.direction,
                }),
                studio,
                Some(30_000.0),
            )
            .await?;
            let note = if shaped.get("shaping") == Some(&Value::Bool(true)) {
                "Traffic is degraded from now on, in edit and in playtest, until `device op=\"stop\"` or `op=\"network\" \
                 preset=\"clear\"`. Nothing on screen says so — if the place starts behaving strangely later, this is the \
                 first thing to rule out."
            } else {
                "The connection is back to normal."
            };
            Ok(json(&shaped, Some(note)))
        }
        op => {
            let command = match op {
                DeviceOp::Set => "device.set",
                DeviceOp::Stop => "device.stop",
                _ => "device.state",
            };
            let r = call(&ctx, command, json!({ "device": a.device, "orientation": a.orientation }), studio, Some(30_000.0)).await?;
            Ok(json(
                &r,
                (op == DeviceOp::Set).then_some(
                    "Take a `screenshot` to see it. Call `device op=\"stop\"` when finished, or every later screenshot stays this shape.",
                ),
            ))
        }
    }
}

pub fn tools() -> Vec<Tool> {
    vec![
        define(
            spec("input", "Send keyboard and mouse input").destructive(false),
            "Sends real keyboard and mouse input to a running playtest — the same events a person pressing the keys \
             would produce.\n\n\
             This is how to test what `character` cannot reach. `character` drives the Humanoid directly, which answers \
             'can it get to the door'; this answers 'does pressing E open it', 'does the sprint key work' — anything \
             bound to input rather than to movement. Use `character` for going places and this for controls.\n\n\
             Roblox reserves some keys for its own menus and refuses to send them — Escape, Tab, F9, and others \
             depending on the place (One is the backpack hotbar). A refused key comes back as a WARNING naming it; the \
             other steps still run.\n\n\
             Steps run in order, so a sequence is one call: tap E, wait, click at a point, type a name. `hold` is how \
             long a key or button stays down, `after` is how long to wait before the next step — a jump held for a \
             second is a different test from a tapped one.\n\n\
             REQUIRES A RUNNING PLAYTEST, and must be addressed to the playtest's studioId from `list_studios`, not the \
             editor's.\n\n\
             A pointer is drawn on screen and travels to each target before the click, so the user can see what you are \
             aiming at. Turn it off with `cursor: false`.\n\n\
             How it works, because it explains the one thing that will surprise you: input belongs to the data model \
             that creates it, and the character is driven by the CLIENT. Sending from the playtest's server succeeds and \
             moves nothing. So this parents a short script into the player's PlayerGui, which runs on their client, and \
             that reports back when the input has actually been delivered. Nothing is reported as sent until the client \
             confirms it. If confirmation never arrives you get an error, not a success — check where things really are \
             with `character op=\"state\"`.\n\n\
             Mouse coordinates are viewport pixels from the top-left, so pair this with `screenshot` to see what is \
             where before clicking it, and send what you read off the picture unchanged. The reply's `landed` shows the \
             same click in the game's own coordinates, which sit a topbar lower — that difference is two ways of \
             describing one point, not an error to correct for. Under an emulated device it is a real distortion \
             instead, and the reply says so; there, re-read it after each click rather than reusing an earlier one.\n\n\
             Take the screenshot immediately before clicking. The reply is measured against the viewport as it is NOW, \
             and a Studio window that changed size since the picture was taken moves everything in it — measured, a \
             window that went from 435 to 952 pixels wide between a screenshot and a click, where the click reported \
             success and hit nothing.\n\n\
             A `text` step types into the FOCUSED TextBox. Click the box in the same call, one step before the text, and \
             the focus is taken for you; with no box to type into the step is reported as having done nothing rather \
             than as delivered.",
            input,
        ),
        define(
            spec("device", "Emulate a phone, tablet or console").destructive(false),
            "Resizes the Studio viewport to a real device, so you can see what a player on that device sees.\n\n\
             Most Roblox players are on a phone and most UI is built on a desktop monitor, which is where interfaces \
             break: a button under the notch, a menu off the bottom of a 393-pixel-tall screen, text sized for a display \
             three times larger. None of that is visible in the data model — every one of those instances has perfectly \
             correct properties — so this is the only way to find it short of owning the hardware.\n\n\
             The workflow is: `set` a device, `screenshot`, look. Pair it with `playtest` to check a running game's HUD \
             rather than the editor.\n\n\
             `list` gives the ids, each with its real name, form factor and resolution — ids look like \"iphone_16\", \
             \"ipad_a16\", \"samsung_galaxy_s25_ultra\", \"xbox\", \"meta_quest_3\".\n\n\
             `network` degrades the connection on purpose — latency, jitter and packet loss — which is the other half of \
             what a phone player actually gets. A menu that works at 0ms is not evidence that it works at 300: the \
             spinner that never stops, the button that fires twice, the HUD that arrives after the round started are all \
             invisible on a local connection. Use a `preset` (`wifi`, `4g`, `3g`, `poor`, `clear`) or set the numbers \
             yourself, then `playtest` and watch.\n\n\
             `stop` returns Studio to the normal editor viewport AND clears the network shaping. Do that when you are \
             finished: a left-over emulated device makes every later screenshot the wrong shape, a left-over 400ms delay \
             makes the whole place feel broken, and nothing on screen says why in either case.",
            device,
        ),
    ]
}
