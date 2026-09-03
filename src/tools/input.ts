import { z } from "zod";
import { json, type ToolResult } from "../lib/format.js";
import { defineTool, type ToolContext } from "../lib/tool.js";

interface InputResponse {
  /**
   * Present only while a device is emulated; see the note built below.
   *
   * `resolution` is optional because the plugin's is: every
   * StudioDeviceSimulatorService read is guarded separately and each one can
   * come back nil on its own, so a device can be known while its size is not.
   */
  emulation?: { id: string; resolution?: string; orientation?: string };
  /** Where the client read the last click, against where it was aimed. */
  landed?: { sent: { x: number; y: number }; seen: { x: number; y: number } };
  delivered: boolean;
  steps: number;
  player: string;
  performed?: string[];
  /** Steps that were delivered and still did nothing, in the client's words. */
  notes?: string[];
}

/**
 * The gap between where a click was aimed and where the client read it.
 *
 * Returned rather than corrected because it cannot be predicted. Measured
 * against a live playtest, sending (300,300):
 *
 *   Galaxy S25 Ultra, landscape  viewport 685x338  read at (253,242)
 *   iPhone 16, portrait          viewport 391x758  read at (300,183)
 *   no device emulated                             read at (300,242)
 *
 * A constant translation in every case, never a scale -- four points spanning
 * the viewport gave the same delta to the pixel. But the translation changes
 * with the device and the orientation, and fits no formula over resolution,
 * viewport and GUI inset that holds for both phones: the horizontal term is
 * (device - viewport) / 2 and the vertical term is not.
 *
 * An earlier version of this file claimed the error was the ratio between the
 * device resolution and the screenshot's, which is wrong, and wrong in a way
 * that happens to land close to correct in the middle of the screen where it
 * was first observed.
 *
 * Applying it automatically was tried and reverted. The translation is real
 * with nothing emulated -- (0,-58), which is exactly GuiService:GetGuiInset()
 * -- and on an iPhone 16 in portrait, measured equal at two points 215px apart.
 * On the SAME phone in LandscapeRight it is not a translation at all: the
 * horizontal term inverts and scales (seen.x fitted 919 - 1.4 * sent.x), so
 * subtracting the measured constant moved the aim from 187px out to 449px out.
 *
 * Nor can a better fit be sampled. Synthetic MOVES report no position --
 * InputChanged never fires for SendMousePosition -- so the map is observable
 * only by clicking, and probe clicks press whatever they land on. Aim once,
 * read the delta, correct.
 */
function landingNote(landed: NonNullable<InputResponse["landed"]>): string {
  const dx = landed.seen.x - landed.sent.x;
  const dy = landed.seen.y - landed.sent.y;
  if (dx === 0 && dy === 0) {
    return ` The last click was aimed at (${landed.sent.x}, ${landed.sent.y}) and the client read it there, so screen coordinates are landing exactly.`;
  }
  return (
    ` COORDINATES ARE OFFSET: the last click was aimed at (${landed.sent.x}, ${landed.sent.y}) and the client read it at (${landed.seen.x}, ${landed.seen.y}) — ` +
    `off by (${dx}, ${dy}). Add (${-dx}, ${-dy}) to coordinates taken from a \`screenshot\` to hit what you are aiming at. ` +
    "That correction is a constant translation with no device emulated and in portrait, but NOT in landscape emulation, where the horizontal term inverts — " +
    "so under an emulated device treat it as one sample: click, read this field again, and correct from the newest one rather than reusing an earlier value."
  );
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
        "A pointer is drawn on screen and travels to each target before the " +
        "click, so the user can see what you are aiming at. Turn it off with " +
        "`cursor: false`.\n\n" +
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
        "with `screenshot` to see what is where before clicking it. The client " +
        "reads them at an offset the reply reports as `landed` — aim once, read " +
        "where it actually landed, then correct. Under an emulated device that " +
        "offset is large and stops being a simple translation, so re-read it " +
        "after each click rather than reusing an earlier one.\n\n" +
        "A `text` step types into the FOCUSED TextBox. Click the box in the same " +
        "call, one step before the text, and the focus is taken for you; with no " +
        "box to type into the step is reported as having done nothing rather " +
        "than as delivered.",
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
                text: z
                  .string()
                  .optional()
                  .describe(
                    "text only: the string to type. Goes to the focused TextBox — click it first, in the same call.",
                  ),
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
        cursor: z
          .boolean()
          .default(true)
          .describe(
            "Draw a pointer on screen that travels to each target before the " +
              "click, with a ripple where it lands. On by default: synthetic " +
              "input is otherwise invisible, so the user watching sees effects " +
              "with no cause, and a click that misses looks identical to one " +
              "that hit. Turn it off only when recording something where the " +
              "pointer would be in the way.",
          ),
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
        { steps: args.steps, player: args.player, cursor: args.cursor },
        // The plugin waits for the client's acknowledgement, and the steps
        // themselves can hold keys for seconds, so the deadline must outlast both.
        { studioId: args.studioId, timeoutMs: 90_000 },
      );

      /*
       * A click can be delivered and still hit nothing, so the two things that
       * explain it are said here rather than left to be discovered: what the
       * viewport is pretending to be, and where the click was actually read.
       *
       * Keys are never affected. They carry no coordinates, which is what made
       * this look like a GUI fault rather than an input one.
       */
      const emulated = response.emulation;
      const parts = ["Delivered on the client and confirmed back."];
      if (emulated) {
        parts.push(
          `NOTE: ${emulated.id} is being emulated` +
            (emulated.resolution ? ` at ${emulated.resolution}` : "") +
            '. `device op="stop"` returns the viewport to normal.',
        );
      }
      if (response.landed) {
        parts.push(landingNote(response.landed).trim());
      } else if (response.performed?.some((kind) => kind === "click")) {
        // A click went out and the client reported reading no pointer event at
        // all. That is the loud case -- it means the click did not register,
        // not that it landed somewhere unhelpful.
        parts.push(
          "WARNING: a click was sent but the client read no pointer event for it, " +
            "so it did not register at all. Check that a playtest is actually in " +
            "focus and that nothing is covering the target.",
        );
      } else {
        parts.push('Read the result with `character op="state"`, `console`, or `screenshot`.');
      }
      /*
       * A step that ran and changed nothing is the failure this whole file
       * exists to avoid reporting as success, so the client's own words about
       * it go at the front where they cannot be skimmed past.
       */
      if (Array.isArray(response.notes)) {
        for (const line of response.notes) {
          parts.unshift(`WARNING: ${line}`);
        }
      }
      const note = parts.join(" ");
      return json(response, note);
    },
  );
}
