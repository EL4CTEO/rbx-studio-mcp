//! api and audio.

use super::{call, u64_of};
use crate::apidump;
use crate::errors::{Result, ToolError};
use crate::format::{ToolResult, error_text, json, text, to_flat};
use crate::tool::{Ctx, Tool, define, spec};
use schemars::JsonSchema;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::sync::Arc;

#[derive(Deserialize, JsonSchema, Default, PartialEq, Clone, Copy)]
#[serde(rename_all = "lowercase")]
enum ApiOp {
    #[default]
    Describe,
    Classes,
}

#[derive(Deserialize, Serialize, JsonSchema, Clone, Copy)]
#[serde(rename_all = "lowercase")]
enum MemberKind {
    Properties,
    Methods,
    Events,
}

#[derive(Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
struct ApiArgs {
    /// 'describe' details one class, 'classes' searches class names.
    #[serde(default)]
    op: ApiOp,
    /// describe only: the class, e.g. "TweenService", "ProximityPrompt", "Humanoid". Case-sensitive.
    class_name: Option<String>,
    /// classes only: substring to match, case-insensitive, e.g. "constraint" or "gui". Omit to list everything.
    contains: Option<String>,
    /// describe only: which member kinds to return. Defaults to all three; narrow it when you only need one and the class is large.
    include: Option<Vec<MemberKind>>,
    /// describe only: include members inherited from Instance and Object. Off by default because they swamp the answer — ProximityPrompt has 2 methods of its own and 42 inherited, and the two you want are not the ones you already know. The inherited count is reported either way.
    #[serde(default)]
    inherited: bool,
    /// Target Studio; omit for the active one.
    studio_id: Option<String>,
}

async fn api(ctx: Arc<Ctx>, a: ApiArgs) -> Result<ToolResult> {
    let studio = a.studio_id.as_deref();
    if a.op == ApiOp::Classes {
        let r = call(&ctx, "api.classes", json!({ "contains": a.contains }), studio, None).await?;
        let matched = u64_of(&r, "matched");
        if matched == 0 {
            return Ok(text(format!(
                "No class name contains {}.\nThe match is a plain substring, case-insensitive — try a shorter one.",
                to_flat(&json!(a.contains.unwrap_or_default()))
            )));
        }
        let truncated = u64_of(&r, "truncated");
        let note = if truncated > 0 {
            format!("{matched} matched; {truncated} not shown. Narrow with `contains`.")
        } else {
            format!("{matched} matched.")
        };
        return Ok(json(r.get("classes").unwrap_or(&json!([])), Some(&note)));
    }
    let Some(wanted) = a.class_name.filter(|c| !c.is_empty()) else {
        return Ok(error_text("describe needs a `className`. Use `op: \"classes\"` to search for one."));
    };
    match call(&ctx, "api.describe", json!({ "className": wanted, "include": a.include, "inherited": a.inherited }), studio, None).await {
        Ok(r) => Ok(json(&r, None)),
        Err(e) if e.code == "NO_SUCH_CLASS" => {
            let near = apidump::suggest_class(&wanted).await;
            // In the dump but not this engine: a beta flag, or an older Studio.
            if near.contains(&wanted) {
                return Err(ToolError::hint(
                    "CLASS_NOT_ENABLED",
                    format!("\"{wanted}\" is in Roblox's API dump, but this Studio does not expose it."),
                    "It is probably behind a Studio beta or early-access program that is not enabled here (File > Beta Features), or this Studio is older than the dump.",
                ));
            }
            if !near.is_empty() {
                return Err(ToolError::hint(
                    e.code,
                    format!("The engine has no class called \"{wanted}\"."),
                    format!("Did you mean: {}? Class names are case-sensitive.", near.join(", ")),
                ));
            }
            Err(e)
        }
        Err(e) => Err(e),
    }
}

#[derive(Deserialize, JsonSchema, Default, PartialEq, Clone, Copy)]
#[serde(rename_all = "lowercase")]
enum AudioOp {
    #[default]
    Graph,
    Wire,
    Inspect,
    Speech,
}

#[derive(Deserialize, Serialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
struct SpeechLine {
    /// What is said. 300 characters at most.
    #[schemars(length(min = 1, max = 300))]
    text: String,
    /// AudioTextToSpeech VoiceId. Defaults to "1".
    #[serde(skip_serializing_if = "Option::is_none")]
    voice_id: Option<String>,
    /// Semitones, -12 to 12.
    #[serde(skip_serializing_if = "Option::is_none")]
    #[schemars(range(min = -12, max = 12))]
    pitch: Option<f64>,
    /// 0.5 to 2.
    #[serde(skip_serializing_if = "Option::is_none")]
    #[schemars(range(min = 0.5, max = 2))]
    speed: Option<f64>,
}

#[derive(Deserialize, Serialize, JsonSchema, Clone, Copy)]
#[serde(rename_all = "lowercase")]
enum AudioKind {
    World,
    Ui,
}

#[derive(Deserialize, Serialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
struct AudioArgs {
    /// 'graph' builds a whole working chain, 'wire' joins two existing instances, 'inspect' reads a graph back, 'speech' turns text into voice-line audio assets.
    #[serde(default, skip_serializing)]
    op: AudioOp,
    /// speech only: voice lines to generate. Each becomes an audio asset on your account that plays instantly, with no play-time rate limit.
    #[serde(skip_serializing_if = "Option::is_none")]
    #[schemars(length(min = 1, max = 20))]
    lines: Option<Vec<SpeechLine>>,
    /// graph only: 'world' is a sound heard from a place — it needs a part to come from. 'ui' has no position: menu clicks, music. Defaults to 'world'.
    #[serde(skip_serializing_if = "Option::is_none")]
    kind: Option<AudioKind>,
    /// graph only: where the graph goes. For kind="world" this is the part or attachment the sound comes from.
    #[serde(skip_serializing_if = "Option::is_none")]
    parent: Option<String>,
    /// graph only: the audio id, e.g. "rbxassetid://1234". Find one with `assets op="search" category="audio"`. Leave it out to build the chain now and set the asset later.
    #[serde(skip_serializing_if = "Option::is_none")]
    asset: Option<String>,
    /// graph only: name for the AudioPlayer.
    #[serde(skip_serializing_if = "Option::is_none")]
    name: Option<String>,
    /// graph only: effect classes to splice between the player and the output, in order, e.g. ["AudioFader", "AudioReverb"]. Also accepts AudioEqualizer, AudioCompressor, AudioEcho, AudioDistortion, AudioPitchShifter, AudioChorus, AudioFlanger and AudioLimiter.
    #[serde(skip_serializing_if = "Option::is_none")]
    effects: Option<Vec<String>>,
    /// wire only: the instance sound comes OUT of.
    #[serde(skip_serializing_if = "Option::is_none")]
    from: Option<String>,
    /// wire only: the instance sound goes INTO.
    #[serde(skip_serializing_if = "Option::is_none")]
    to: Option<String>,
    /// wire only: the source's output pin. Defaults to "Output", which is right for everything but a channel splitter.
    #[serde(skip_serializing_if = "Option::is_none")]
    from_pin: Option<String>,
    /// wire only: the target's input pin. Defaults to "Input". A wrong pin name is accepted by the engine and produces silence, so the name is checked against the instance before the wire is made.
    #[serde(skip_serializing_if = "Option::is_none")]
    to_pin: Option<String>,
    /// inspect only: where to look. Omit to walk the whole place, which is the right call when tracking down silence of unknown origin.
    #[serde(skip_serializing_if = "Option::is_none")]
    path: Option<String>,
    /// Target Studio; omit for the active one.
    #[serde(skip_serializing)]
    studio_id: Option<String>,
}

async fn audio(ctx: Arc<Ctx>, a: AudioArgs) -> Result<ToolResult> {
    let studio = a.studio_id.clone();
    if a.op == AudioOp::Speech {
        let Some(lines) = &a.lines else {
            return Ok(error_text("speech needs `lines`, e.g. [{ text: \"Welcome to the obby!\" }]."));
        };
        // Each line is a generation plus an upload, a few seconds apiece.
        let r = call(&ctx, "audio.speech", json!({ "lines": lines }), studio.as_deref(), Some(30_000.0 + lines.len() as f64 * 20_000.0)).await?;
        return Ok(json(
            &r,
            Some("Play one with `audio op=\"graph\" asset=...`. The assets are named TTS_Asset_<id> on your account; Roblox does not take a name yet."),
        ));
    }
    let op = match a.op {
        AudioOp::Wire => "audio.wire",
        AudioOp::Inspect => "audio.inspect",
        _ => "audio.graph",
    };
    let params: Value = serde_json::to_value(&a)?;
    let r = call(&ctx, op, params, studio.as_deref(), Some(30_000.0)).await?;
    if a.op == AudioOp::Graph {
        return Ok(json(
            &r,
            Some(
                "Nothing plays on its own — call `AudioPlayer:Play()` from a script, or set `Playing` with `modify`. Check the \
                 result's `note` and `warnings` first: they are the difference between a graph that is wired and one that is audible.",
            ),
        ));
    }
    Ok(json(&r, None))
}

pub fn tools() -> Vec<Tool> {
    vec![
        define(
            spec("api", "What a class can do").read_only(),
            "Lists the properties, methods and events of any Roblox class, read from the engine that is running.\n\n\
             Use it before writing Luau against a class you are not certain of. Guessing a method name costs a runtime \
             error and a round trip; this costs one call and is never out of date, because the answer comes from the \
             running binary rather than from a published dump or from training data. That matters most for exactly the \
             classes worth checking — new ones, and ones that changed recently.\n\n\
             Members come back as signatures rather than bare names — `AddAccessory(accessory: Instance)`, \
             `HoldDuration: number` — because a name tells you something exists and a signature tells you how to call \
             it, which is the actual question.\n\n\
             `describe` takes a class name and gives the members it declares itself, counting the inherited ones \
             separately. `classes` searches class names, which is how to find one whose exact spelling you do not have.\n\n\
             Deprecated members are never listed, only counted — `Instance` has eight, including `clone`, `remove` and \
             `getChildren`. They still run, so picking one from a list gives you working code and a deprecation warning \
             in the user's output. Members no script may use at all are counted with them.\n\n\
             This is not the same as `inspect`. `inspect` reads the values on an instance that exists; this reads the \
             shape of a class whether or not anything in the place is one — which is what you need when deciding what \
             to create in the first place.",
            api,
        ),
        define(
            spec("audio", "Wire up Roblox's audio graph"),
            "Builds and inspects the modern audio API — AudioPlayer, emitters, effects and the Wires between them.\n\n\
             Roblox's modern audio is a signal graph, not one instance with a Play method. An `AudioPlayer` holds the \
             asset, an `AudioEmitter` puts the sound in the world or an `AudioDeviceOutput` sends it to the player's \
             speakers, effects sit in between, and NOTHING is connected until a `Wire` joins two named pins. A place can \
             hold a perfectly configured AudioPlayer with the right asset and the right volume and be completely silent, \
             with no error anywhere, because the wire was never made. That is what this tool is for: `create` can make \
             each instance, but the pin names, the direction and the choice of sink are where it actually goes wrong.\n\n\
             `graph` is the one to reach for: it builds a whole working chain in one undoable step. `kind=\"world\"` \
             gives a sound that comes from a part; `kind=\"ui\"` gives one with no position, for menus and music. Add \
             `effects` to splice reverb, EQ or a fader into the chain.\n\n\
             `speech` generates voice lines from text as real audio assets (Studio beta: Text-to-Speech asset \
             creation). Feed the returned asset to `graph` to play it.\n\n\
             `wire` joins two instances you already have. `inspect` reads an existing graph back and reports every \
             connection — including the ones that report Connected = false, which the Explorer does not show and which \
             are the usual reason for silence.\n\n\
             The old `Sound` instance still works and is still shorter for a plain one-off noise; use `create` for that. \
             Come here when the case needs effects, per-listener mixing, or one emitter fed by several sources.",
            audio,
        ),
    ]
}
