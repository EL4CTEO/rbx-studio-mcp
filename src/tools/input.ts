import { z } from "zod";
import { json, type ToolResult } from "../lib/format.js";
import { defineTool, type ToolContext } from "../lib/tool.js";

interface InputResponse {
  delivered: boolean;
  steps: number;
  player: string;
  performed?: string[];
}

export function registerInputTools(context: ToolContext): void {
  const { bridge } = context;

  defineTool(
    context,
    {
      name: "input",
      title: "Send keyboard and mouse input",
      description:
        "Sends real keyboard and mouse input to a running playtest — the same " +
        "events a person pressing the keys would produce.\n\n" +
        "This is how to test what `character` cannot reach. `character` drives " +
        "the Humanoid directly, which answers 'can it get to the door'; this " +
        "answers 'does pressing E open it', 'does the sprint key work', 'does " +
        "the menu close on Escape' — anything bound to input rather than to " +
        "movement. Use `character` for going places and this for controls.\n\n" +
        "Steps run in order, so a sequence is one call: tap E, wait, click at a " +
        "point, type a name. `hold` is how long a key or button stays down, " +
        "`after` is how long to wait before the next step — a jump held for a " +
        "second is a different test from a tapped one.\n\n" +
        "REQUIRES A RUNNING PLAYTEST, and must be addressed to the playtest's " +
        "studioId from `list_studios`, not the editor's.\n\n" +
        "How it works, because it explains the one thing that will surprise " +
        "you: input belongs to the data model that creates it, and the " +
        "character is driven by the CLIENT. Sending from the playtest's server " +
        "succeeds and moves nothing. So this parents a short script into the " +
        "player's PlayerGui, which runs on their client, and that reports back " +
        "when the input has actually been delivered. Nothing is reported as " +
        "sent until the client confirms it. If confirmation never arrives you " +
        "get an error, not a success — check where things really are with " +
        "`character op=\"state\"`.\n\n" +
        "Mouse coordinates are viewport pixels from the top-left, so pair this " +
        "with `screenshot` to see what is where before clicking it.",
      inputSchema: {
        steps: z
          .array(
            z
              .object({
                kind: z
                  .enum(["key", "click", "move", "text"])
                  .default("key")
                  .describe(
                    "'key' presses a keyboard key, 'click' a mouse button at a " +
                      "point, 'move' just moves the pointer, 'text' types a string.",
                  ),
                key: z
                  .string()
                  .optional()
                  .describe(
                    'key only: an Enum.KeyCode name — "W", "Space", "E", "LeftShift", "Escape".',
                  ),
                action: z
                  .enum(["tap", "press", "release"])
                  .optional()
                  .describe(
                    "'tap' presses and releases (the default), 'press' holds it " +
                      "down until a later 'release', 'release' lets go. Use " +
                      "press/release across steps to hold a key while doing " +
                      "something else.",
                  ),
                button: z
                  .enum(["MouseButton1", "MouseButton2", "MouseButton3"])
                  .optional()
                  .describe("click only: which button. Defaults to left."),
                x: z.number().optional().describe("click/move only: viewport pixels from the left."),
                y: z.number().optional().describe("click/move only: viewport pixels from the top."),
                text: z.string().optional().describe("text only: the string to type."),
                hold: z
                  .number()
                  .min(0)
                  .max(10)
                  .optional()
                  .describe("Seconds to hold the key or button down before releasing it."),
                after: z
                  .number()
                  .min(0)
                  .max(10)
                  .optional()
                  .describe("Seconds to wait after this step before the next one."),
              })
              .strict(),
          )
          .min(1)
          .max(40)
          .describe("Input steps, delivered in order."),
        player: z
          .string()
          .optional()
          .describe("Which player, by name. Omit for the only one; needed in a multiplayer test."),
        studioId: z
          .string()
          .optional()
          .describe("The PLAYTEST session's id — not the editor's. See list_studios."),
      },
      readOnly: false,
      destructive: false,
    },
    async (args): Promise<ToolResult> => {
      const response = await bridge.call<InputResponse>(
        "input.send",
        { steps: args.steps, player: args.player },
        // The plugin waits for the client's acknowledgement, and the steps
        // themselves can hold keys for seconds, so the deadline must outlast both.
        { studioId: args.studioId, timeoutMs: 90_000 },
      );

      return json(response, "Delivered on the client and confirmed back. Read the result with `character op=\"state\"`, `console`, or `screenshot`.");
    },
  );
}
