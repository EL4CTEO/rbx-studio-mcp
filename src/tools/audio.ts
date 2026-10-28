import { z } from "zod";
import { errorText, json, type ToolResult } from "../lib/format.js";
import { defineTool, type ToolContext } from "../lib/tool.js";

export function registerAudioTools(context: ToolContext): void {
  const { bridge } = context;

  defineTool(
    context,
    {
      name: "audio",
      title: "Wire up Roblox's audio graph",
      description:
        "Builds and inspects the modern audio API — AudioPlayer, emitters, " +
        "effects and the Wires between them.\n\n" +
        "Roblox's modern audio is a signal graph, not one instance with a Play " +
        "method. An `AudioPlayer` holds the asset, an `AudioEmitter` puts the " +
        "sound in the world or an `AudioDeviceOutput` sends it to the player's " +
        "speakers, effects sit in between, and NOTHING is connected until a " +
        "`Wire` joins two named pins. A place can hold a perfectly configured " +
        "AudioPlayer with the right asset and the right volume and be " +
        "completely silent, with no error anywhere, because the wire was never " +
        "made. That is what this tool is for: `create` can make each instance, " +
        "but the pin names, the direction and the choice of sink are where it " +
        "actually goes wrong.\n\n" +
        "`graph` is the one to reach for: it builds a whole working chain in " +
        "one undoable step. `kind=\"world\"` gives a sound that comes from a " +
        "part; `kind=\"ui\"` gives one with no position, for menus and music. " +
        "Add `effects` to splice reverb, EQ or a fader into the chain.\n\n" +
        "`speech` generates voice lines from text as real audio assets " +
        "(Studio beta: Text-to-Speech asset creation). Feed the returned " +
        "asset to `graph` to play it.\n\n" +
        "`wire` joins two instances you already have. `inspect` reads an " +
        "existing graph back and reports every connection — including the ones " +
        "that report Connected = false, which the Explorer does not show and " +
        "which are the usual reason for silence.\n\n" +
        "The old `Sound` instance still works and is still shorter for a plain " +
        "one-off noise; use `create` for that. Come here when the case needs " +
        "effects, per-listener mixing, or one emitter fed by several sources.",
      inputSchema: {
        op: z
          .enum(["graph", "wire", "inspect", "speech"])
          .default("graph")
          .describe(
            "'graph' builds a whole working chain, 'wire' joins two existing " +
              "instances, 'inspect' reads a graph back, 'speech' turns text " +
              "into voice-line audio assets.",
          ),
        lines: z
          .array(
            z.object({
              text: z.string().min(1).max(300).describe("What is said. 300 characters at most."),
              voiceId: z.string().optional().describe('AudioTextToSpeech VoiceId. Defaults to "1".'),
              pitch: z.number().min(-12).max(12).optional().describe("Semitones, -12 to 12."),
              speed: z.number().min(0.5).max(2).optional().describe("0.5 to 2."),
            }),
          )
          .min(1)
          .max(20)
          .optional()
          .describe(
            "speech only: voice lines to generate. Each becomes an audio asset " +
              "on your account that plays instantly, with no play-time rate limit.",
          ),
        kind: z
          .enum(["world", "ui"])
          .optional()
          .describe(
            "graph only: 'world' is a sound heard from a place — it needs a " +
              "part to come from. 'ui' has no position: menu clicks, music. " +
              "Defaults to 'world'.",
          ),
        parent: z
          .string()
          .optional()
          .describe(
            'graph only: where the graph goes. For kind="world" this is the ' +
              "part or attachment the sound comes from.",
          ),
        asset: z
          .string()
          .optional()
          .describe(
            'graph only: the audio id, e.g. "rbxassetid://1234". Find one with ' +
              '`assets op="search" category="audio"`. Leave it out to build the ' +
              "chain now and set the asset later.",
          ),
        name: z.string().optional().describe("graph only: name for the AudioPlayer."),
        effects: z
          .array(z.string())
          .optional()
          .describe(
            "graph only: effect classes to splice between the player and the " +
              'output, in order, e.g. ["AudioFader", "AudioReverb"]. Also ' +
              "accepts AudioEqualizer, AudioCompressor, AudioEcho, " +
              "AudioDistortion, AudioPitchShifter, AudioChorus, AudioFlanger " +
              "and AudioLimiter.",
          ),
        from: z.string().optional().describe("wire only: the instance sound comes OUT of."),
        to: z.string().optional().describe("wire only: the instance sound goes INTO."),
        fromPin: z
          .string()
          .optional()
          .describe(
            'wire only: the source\'s output pin. Defaults to "Output", which ' +
              "is right for everything but a channel splitter.",
          ),
        toPin: z
          .string()
          .optional()
          .describe(
            'wire only: the target\'s input pin. Defaults to "Input". A wrong ' +
              "pin name is accepted by the engine and produces silence, so the " +
              "name is checked against the instance before the wire is made.",
          ),
        path: z
          .string()
          .optional()
          .describe(
            "inspect only: where to look. Omit to walk the whole place, which " +
              "is the right call when tracking down silence of unknown origin.",
          ),
        studioId: z.string().optional().describe("Target Studio; omit for the active one."),
      },
    },
    async (args): Promise<ToolResult> => {
      const { op, studioId, ...rest } = args;
      if (op === "speech") {
        if (rest.lines === undefined) {
          return errorText('speech needs `lines`, e.g. [{ text: "Welcome to the obby!" }].');
        }
        // Each line is a generation plus an upload, a few seconds apiece.
        const response = await bridge.call<Record<string, unknown>>(
          "audio.speech",
          { lines: rest.lines },
          { studioId, timeoutMs: 30_000 + rest.lines.length * 20_000 },
        );
        return json(
          response,
          'Play one with `audio op="graph" asset=...`. The assets are named ' +
            "TTS_Asset_<id> on your account; Roblox does not take a name yet.",
        );
      }
      const response = await bridge.call<Record<string, unknown>>(
        op === "wire" ? "audio.wire" : op === "inspect" ? "audio.inspect" : "audio.graph",
        rest,
        { studioId, timeoutMs: 30_000 },
      );

      if (op === "graph") {
        return json(
          response,
          "Nothing plays on its own — call `AudioPlayer:Play()` from a script, " +
            "or set `Playing` with `modify`. Check the result's `note` and " +
            "`warnings` first: they are the difference between a graph that is " +
            "wired and one that is audible.",
        );
      }
      return json(response);
    },
  );
}
