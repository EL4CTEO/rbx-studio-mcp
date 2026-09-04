import { zstdDecompressSync } from "node:zlib";
import { z } from "zod";
import type { StudioBridge } from "../bridge/api.js";
import { ToolError } from "../lib/errors.js";
import { image, type ToolResult } from "../lib/format.js";
import { encodePng } from "../lib/png.js";
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
  /** True when every pixel came back black; see the note built below. */
  black?: boolean;
  /** Set when Studio is emulating a device, which is why the shape is unusual. */
  device?: string;
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
  const rgb = zstdDecompressSync(Buffer.from(response.data, "base64"));
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
    { contentId, width, context: "playtest client" },
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
            "Width to scale the image down to, in pixels; height follows the " +
              "viewport's aspect ratio. Larger is sharper and costs more — raise " +
              "it only when you need to read small text.",
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
          ? await playtestShot(bridge, target, list, args.width)
          : await bridge.call<ScreenshotResponse>(
              "capture.screenshot",
              { width: args.width },
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
       * A capture that came back entirely black is almost never the game.
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
        ? " WARNING: every pixel in this capture is black, which usually means Studio was not" +
          " rendering when it was taken rather than that the scene is dark — the window being" +
          " minimised, fully covered by another window, or on a virtual desktop that is not" +
          " on screen will all do it. Ask the user to bring Studio to the front and take it" +
          " again before drawing any conclusion from what is in this image."
        : "";

      return image(
        png,
        `Studio viewport (${response.context}), ${response.width}x${response.height}` +
          ` scaled from ${response.sourceWidth}x${response.sourceHeight}.${emulating}${blank}`,
      );
    },
  );
}
