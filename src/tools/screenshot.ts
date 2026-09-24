import { zstdDecompressSync } from "node:zlib";
import { z } from "zod";
import type { StudioBridge } from "../bridge/api.js";
import { ToolError } from "../lib/errors.js";
import { image, type ToolResult } from "../lib/format.js";
import { boxResample, encodePng, upscaleNearest } from "../lib/png.js";

/** Long side a small zoomed crop is enlarged toward. */
const MIN_ZOOM_SIDE = 480;
import type { StudioSession } from "../lib/protocol.js";
import { defineTool, type ToolContext } from "../lib/tool.js";

interface ScreenshotResponse {
  /** "zstd-rgb" when the plugin sent pixels; "png" from a Studio without EncodingService. */
  encoding?: "zstd-rgb" | "png";
  data: string;
  width: number;
  height: number;
  sourceWidth: number;
  sourceHeight: number;
  rawBytes?: number;
  bytes: number;
  context: string;
  /** True when the whole image is one flat colour; see the note built below. */
  black?: boolean;
  /** Set when Studio is emulating a device, which is why the shape is unusual. */
  device?: string;
  /** Width to box-filter down to here; set when the plugin sent full-resolution pixels. */
  scaleTo?: number;
  /** The crop that was kept, in full-resolution capture pixels. */
  region?: { x: number; y: number; width: number; height: number };
  /** Set here, not by the plugin: how many times a small crop was enlarged. */
  enlarged?: number;
}

/**
 * Turns whatever the plugin sent into base64 PNG.
 *
 * Two shapes arrive because the plugin cannot always produce the good one.
 * Where `EncodingService` exists it sends Zstd-compressed raw RGB, and the PNG
 * is built here with real deflate. Where it does not, it falls back to the
 * hand-written Luau encoder, whose output is a valid PNG carrying uncompressed
 * stored blocks — larger, but a picture either way.
 */
function toPngBase64(response: ScreenshotResponse): string {
  if (response.encoding !== "zstd-rgb") {
    return response.data;
  }
  let rgb: Buffer = zstdDecompressSync(Buffer.from(response.data, "base64"));
  // A plugin that sent full resolution leaves the scaling to this side, which
  // averages every pixel instead of sampling a few. See boxResample.
  if (response.scaleTo !== undefined && response.width > response.scaleTo) {
    const scaled = boxResample(rgb, response.width, response.height, response.scaleTo);
    rgb = scaled.rgb;
    response.width = scaled.width;
    response.height = scaled.height;
  }
  // A small zoomed crop is enlarged so a vision model sees more than a few
  // patches of it. Whole factors only, and never past the requested width.
  if (response.region !== undefined && response.scaleTo !== undefined) {
    const factor = Math.min(
      4,
      Math.floor(response.scaleTo / response.width),
      Math.floor(MIN_ZOOM_SIDE / Math.max(response.width, response.height)),
    );
    if (factor > 1) {
      const bigger = upscaleNearest(rgb, response.width, response.height, factor);
      rgb = bigger.rgb;
      response.width = bigger.width;
      response.height = bigger.height;
      response.enlarged = factor;
    }
  }
  return encodePng(rgb, response.width, response.height).toString("base64");
}

const isPlaytest = (session: StudioSession): boolean =>
  (session.context ?? "").startsWith("playtest");

/** Which session this call will land on, when that can be told from here. */
function targetOf(sessions: StudioSession[], activeId: string | null, wanted?: string) {
  if (wanted !== undefined) return sessions.find((session) => session.studioId === wanted);
  if (activeId !== null) return sessions.find((session) => session.studioId === activeId);
  return sessions.length === 1 ? sessions[0] : undefined;
}

/**
 * A playtest screenshot, which takes two sessions.
 *
 * The client is the only thing that can take the picture, and it cannot read
 * it back: `CaptureService` returns a temporary texture id and
 * `CreateEditableImageAsync` refuses those at script identity. The id names a
 * texture in the Studio *process*, though, so the editor session's plugin —
 * same process, plugin identity — opens it without complaint. This is the only
 * place that can see both sessions at once, so the pairing lives here.
 */
async function playtestShot(
  bridge: StudioBridge,
  playtest: StudioSession,
  sessions: StudioSession[],
  width: number,
  rect?: string,
): Promise<ScreenshotResponse> {
  const editor = sessions.find(
    (session) => session.placeId === playtest.placeId && !isPlaytest(session),
  );
  if (editor === undefined) {
    throw new ToolError(
      "NO_EDITOR_SESSION",
      "The playtest is connected but its editor session is not, and reading the " +
        "captured image needs the editor's plugin identity.",
      "The editor window must stay connected while the playtest runs. Check " +
        "`list_studios` — there should be two entries for this place.",
    );
  }

  const { contentId } = await bridge.call<{ contentId: string }>(
    "capture.playtestId",
    {},
    { studioId: playtest.studioId, timeoutMs: 40_000 },
  );

  // Straight on, with no await in between: the texture is temporary and there
  // is no promise about how long Studio keeps one nobody has opened yet.
  return bridge.call<ScreenshotResponse>(
    "capture.decode",
    { contentId, width, rect, context: "playtest client" },
    { studioId: editor.studioId, timeoutMs: 60_000 },
  );
}

export function registerScreenshotTools(context: ToolContext): void {
  const { bridge } = context;

  defineTool(
    context,
    {
      name: "screenshot",
      title: "See the Studio viewport",
      description:
        "Takes a picture of the Studio viewport and returns it as an image you " +
        "can actually look at.\n\n" +
        "Every other tool here reads the data model — names, properties, " +
        "numbers — which answers 'is it there' but never 'does it look right'. " +
        "A part can be at the correct position, anchored, correctly sized, and " +
        "still be buried inside a wall, facing backwards, or hidden behind a " +
        "GUI. Take a screenshot after building something visual, and before " +
        "reporting that it worked.\n\n" +
        "It captures the viewport as the user currently sees it, so it shows " +
        "their camera angle, not a framing of your choosing. Frame the subject " +
        "with `viewport op=\"focus\"` first — that is what makes this tool " +
        "worth calling.\n\n" +
        "Works during a playtest too — address it at the playtest's studioId and " +
        "you get the player's own view, which is the only way to check what a GUI " +
        "actually looks like in front of the game. That one is taken on the client " +
        "and read back through the editor session, so it is a little slower and " +
        "needs the editor window still connected; the caption says `playtest " +
        "client` when it came from there.",
      inputSchema: {
        width: z
          .number()
          .int()
          .min(160)
          .max(1600)
          .default(800)
          .describe(
            "Largest width of the image, in pixels; height follows the aspect " +
              "ratio. Never scales up. To read small text, zoom with `path` or " +
              "`rect` rather than raising this.",
          ),
        path: z
          .string()
          .optional()
          .describe(
            "Zoom to this instance at full resolution: a GUI element, a part, a " +
              "model, or a folder of parts. Edit session only; it must be on screen.",
          ),
        rect: z
          .string()
          .optional()
          .describe(
            'Zoom to "x, y, width, height" in viewport pixels. Read them off an ' +
              "earlier screenshot using the scale its caption states.",
          ),
        studioId: z.string().optional().describe("Target Studio; omit for the active one."),
      },
      readOnly: true,
    },
    async (args): Promise<ToolResult> => {
      const { list, activeId } = await bridge.sessions();
      const target = targetOf(list, activeId, args.studioId);

      const response =
        target !== undefined && isPlaytest(target)
          ? await playtestShot(bridge, target, list, args.width, args.rect)
          : await bridge.call<ScreenshotResponse>(
              "capture.screenshot",
              { width: args.width, path: args.path, rect: args.rect },
              // Capturing, reading the pixels back and compressing them all happen
              // before the reply, and none is instant on a big viewport.
              { studioId: args.studioId, timeoutMs: 60_000 },
            );

      const png = toPngBase64(response);

      // The device is named in the caption rather than left to be inferred: an
      // emulated phone makes every screenshot tall and narrow until it is
      // switched off, and a caller who did not set it has no way to know why.
      const emulating = response.device
        ? ` Emulating ${response.device} — call \`device op="stop"\` for the normal viewport.`
        : "";

      /*
       * A capture that came back as one flat colour is almost never the game.
       *
       * It is a valid PNG of nothing, so nothing about the reply says it
       * failed, and the picture is the reply -- an agent looking at it reads a
       * dark room and reasons on from there, which is worse than an error
       * because it is confident. Studio produces this when the window is not
       * rendering: minimised, fully covered, or on another virtual desktop. The
       * possibility that the scene really is black is left open rather than
       * ruled out, because it is, occasionally.
       */
      const blank = response.black
        ? " WARNING: nothing was rendered into this capture — it is a single flat colour. The" +
          " usual causes are that the 3D view is not the active tab — a script editor open" +
          " in front of it returns the editor's background — or that Studio was not" +
          " rendering at all: minimised, fully covered by another window, or on a virtual" +
          " desktop that is not on screen. Ask the user to bring the 3D view to the front" +
          " and take it again before drawing any conclusion from what is in this image."
        : "";

      const shown = response.region
        ? ` zoomed to ${args.path ?? "the rect"}: rect "${response.region.x}, ${response.region.y}, ${response.region.width}, ${response.region.height}"` +
          ` of the ${response.sourceWidth}x${response.sourceHeight} viewport`
        : ` of the ${response.sourceWidth}x${response.sourceHeight} viewport`;
      // Stated so a follow-up `rect` can be read off this image: its pixels
      // times this factor are viewport pixels.
      const factor = (response.region?.width ?? response.sourceWidth) / response.width;
      const scale =
        response.enlarged !== undefined
          ? ` (enlarged ${response.enlarged}x for viewing: each ${response.enlarged}x${response.enlarged} block is one viewport px. ` +
            'For real detail, move the camera closer with `viewport op="focus"` first)'
          : factor > 1.001
            ? ` (1 image px = ${factor.toFixed(2)} viewport px)`
            : " (full resolution)";
      return image(
        png,
        `Studio viewport (${response.context}), ${response.width}x${response.height}${shown}${scale}.${emulating}${blank}`,
      );
    },
  );
}
