import { z } from "zod";
import { image, type ToolResult } from "../lib/format.js";
import { defineTool, type ToolContext } from "../lib/tool.js";

interface ScreenshotResponse {
  data: string;
  width: number;
  height: number;
  sourceWidth: number;
  sourceHeight: number;
  bytes: number;
  context: string;
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
        "NOT AVAILABLE WHILE A PLAYTEST IS RUNNING. Studio only lets a client " +
        "session capture the screen, and it forbids client sessions from making " +
        "HTTP requests, so no session that can be reached is allowed to take the " +
        "picture: the playtest server refuses outright and the editor session " +
        "times out, because the window is no longer rendering its data model. " +
        "Stop the playtest and screenshot in edit mode, or read the running game " +
        "through `character`, `console` and `find` instead.",
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
      const response = await bridge.call<ScreenshotResponse>(
        "capture.screenshot",
        { width: args.width },
        // Capturing, reading the pixels back and encoding a PNG in Luau all
        // happen before the reply, and none of them is instant on a big viewport.
        { studioId: args.studioId, timeoutMs: 60_000 },
      );

      return image(
        response.data,
        `Studio viewport (${response.context}), ${response.width}x${response.height}` +
          ` scaled from ${response.sourceWidth}x${response.sourceHeight}.`,
      );
    },
  );
}
