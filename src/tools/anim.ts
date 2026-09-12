import { z } from "zod";
import { json, table, text, textOf, type ToolResult } from "../lib/format.js";
import { defineTool, type ToolContext } from "../lib/tool.js";

interface Pose {
  joint: string;
  cframe: string;
  weight: number;
  easing: string;
}

interface ReadResponse {
  assetId: string;
  name?: string;
  priority: string;
  looping: boolean;
  duration: number;
  keyframeCount: number;
  joints: string[];
  jointCount: number;
  jointsSampled?: boolean;
  keyframes: Array<{ index: number; time: number; name?: string; poseCount: number; poses?: Pose[] }>;
  endsWhereItStarted?: boolean;
  driftingJoints?: string[];
  rig: string;
  rigNote?: string;
  truncated: boolean;
}

/** Downloads go to Roblox's asset servers, which are not always quick. */
const TIMEOUT_MS = 45_000;

export function registerAnimTools(context: ToolContext): void {
  const { bridge } = context;

  defineTool(
    context,
    {
      name: "animation",
      title: "Read and build animations",
      description:
        "Reads an animation's actual keyframes, and builds new ones that play " +
        "immediately in the open Studio.\n\n" +
        "Animations are the one part of a place no other tool can see. " +
        "`inspect` on an Animation instance returns an asset id and stops there " +
        "— the poses live on Roblox's servers. `read` downloads them, so you can " +
        "answer 'how long is it', 'which joints does it move', and 'does it end " +
        "where it started' without opening the Animation Editor and scrubbing.\n\n" +
        "`read` takes an asset id, an rbxassetid:// string, or the path of an " +
        "Animation instance in the place — whichever you already have. It reports " +
        "which RIG the animation was made for, which is the thing most worth " +
        "knowing: an R15 animation on an R6 character does nothing at all — no " +
        "error, no movement — and the asset id gives no hint either way.\n\n" +
        "`build` goes the other way: give it keyframes and it returns a content " +
        "id you can put straight into an Animation's AnimationId. Nothing is " +
        "uploaded and nothing is moderated — the id works in this Studio session " +
        "and nowhere else, which makes it the right way to try an idea and the " +
        "wrong way to ship one.\n\n" +
        "`preview` puts an animation ONTO a rig in the open place and freezes it " +
        "at a chosen moment, so `screenshot` can show you the pose. It works in " +
        "edit mode — no playtest. Ask for several moments in turn to compare " +
        "poses across the animation; the rig stays posed until `stop`.\n\n" +
        "Poses are written the way a CFrame property is: \"0, 1, 0\" for a " +
        "position, \"0, 1, 0 | 0, 45, 0\" to rotate as well.\n\n" +
        "The id `build` returns is a bare hash, not an rbxassetid:// URL. Use it " +
        "exactly as given — prefixing it stops it working.",
      inputSchema: {
        op: z
          .enum(["read", "preview", "build", "stop"])
          .default("read")
          .describe(
            "'read' downloads an existing animation, 'preview' poses a rig at one " +
              "moment of it so you can screenshot it, 'build' makes a new one " +
              "playable here, 'stop' clears a preview.",
          ),
        assetId: z
          .union([z.number(), z.string()])
          .optional()
          .describe(
            'read only: animation asset id (12345), "rbxassetid://12345", or the ' +
              'path of an Animation instance ("Workspace.Rig.Animate.run").',
          ),
        keyframes: z
          .array(
            z.object({
              time: z.number().min(0).describe("Seconds from the start of the animation."),
              name: z.string().optional().describe('Keyframe name, e.g. "Start" or a marker name.'),
              poses: z
                .record(z.string(), z.string())
                .optional()
                .describe(
                  'Joint name → CFrame, e.g. { "Right Arm": "0, 0.5, 0 | 0, 0, 45" }. ' +
                    "Joint names must match the rig's parts.",
                ),
            }),
          )
          .max(200)
          .optional()
          .describe("build only: the keyframes, in any order — they are sorted by time."),
        name: z.string().optional().describe("build only: name for the sequence."),
        root: z
          .string()
          .optional()
          .describe(
            'build only: the rig part every pose hangs from. Defaults to "HumanoidRootPart", ' +
              "which is right for an R15 or R6 character.",
          ),
        priority: z
          .enum(["Idle", "Movement", "Action", "Core"])
          .optional()
          .describe("build only: which animations this one plays over."),
        loop: z.boolean().optional().describe("build only: whether it repeats."),
        rig: z
          .string()
          .optional()
          .describe(
            'The model, e.g. "Workspace.Dummy". For preview/stop it is the rig to ' +
              "pose, and needs a Humanoid or an AnimationController inside it. For " +
              "`build` it is optional and is read for its joint layout — pass it for " +
              "anything that is not a standard R6 or R15 character (a custom rig, a " +
              "weapon, a door, a Blender import), or the poses may be attached in the " +
              "wrong order and the animation will move nothing.",
          ),
        at: z
          .number()
          .min(0)
          .optional()
          .describe(
            "preview only: the moment to freeze on, in seconds. Ask for several " +
              "in turn to compare poses across the animation.",
          ),
        hold: z
          .boolean()
          .default(true)
          .describe(
            "preview only: freeze on that frame. Turn off to let it play, but then " +
              "a screenshot catches whatever pose it happens to be in.",
          ),
        studioId: z.string().optional().describe("Target Studio; omit for the active one."),
      },
      readOnly: false,
      destructive: false,
    },
    async (args): Promise<ToolResult> => {
      if (args.op === "preview" || args.op === "stop") {
        if (!args.rig) return text("preview needs a `rig` — the model to pose.");
        const posed = await bridge.call<Record<string, unknown>>(
          "anim.preview",
          { op: args.op, rig: args.rig, assetId: args.assetId, at: args.at, hold: args.hold },
          { studioId: args.studioId, timeoutMs: TIMEOUT_MS },
        );
        return json(posed);
      }

      if (args.op === "build") {
        if (!args.keyframes || args.keyframes.length === 0) {
          return text("build needs a non-empty `keyframes` array.");
        }
        const built = await bridge.call<Record<string, unknown>>(
          "anim.build",
          {
            keyframes: args.keyframes,
            name: args.name,
            root: args.root,
            rig: args.rig,
            priority: args.priority,
            loop: args.loop,
          },
          { studioId: args.studioId, timeoutMs: TIMEOUT_MS },
        );
        return json(
          built,
          "Set this as an Animation's AnimationId with `modify`, exactly as it appears " +
            "— it is a bare hash, and adding rbxassetid:// in front of it stops it " +
            "working. Local to this Studio session: not uploaded, gone on restart.\n\n" +
            "`hierarchy` says which joint layout the poses were nested against — the " +
            "rig you named, or the R6/R15 standard guessed from the joint names. " +
            "Anything in `unmatchedJoints` is a name that layout does not contain: " +
            "those poses were attached to the root and will almost certainly do " +
            "nothing. Pass `rig` to fix it.",
        );
      }

      if (args.assetId === undefined) {
        return text("read needs an `assetId` — a number, an rbxassetid:// string, or a path to an Animation.");
      }

      const found = await bridge.call<ReadResponse>(
        "anim.read",
        { assetId: args.assetId },
        { studioId: args.studioId, timeoutMs: TIMEOUT_MS },
      );

      /*
       * A summary first, then the timeline. The three facts at the top are what
       * the question was, and burying them under forty rows of keyframes would
       * make the tool technically complete and practically unreadable.
       */
      const lines = [
        `${found.name ?? found.assetId} — ${found.rig} rig, ${found.duration}s, ` +
          `${found.keyframeCount} keyframes, ${found.jointCount} joints moved`,
        `Priority ${found.priority}${found.looping ? ", loops" : ", does not loop"}` +
          (found.rigNote !== undefined ? ` — ${found.rigNote}` : ""),
        "",
        `Joints: ${found.joints.join(", ") || "none"}` +
          (found.jointsSampled ? ` … and ${found.jointCount - found.joints.length} more` : ""),
      ];

      if (found.rig === "R6" || found.rig === "R15") {
        lines.push(
          "",
          `This is an ${found.rig} animation. It will do NOTHING on an ${
            found.rig === "R6" ? "R15" : "R6"
          } character — no error, no movement, because the joint names do not exist ` +
            "on the other rig. Check the character's rig type before using it.",
        );
      }

      if (found.looping && found.endsWhereItStarted === false) {
        lines.push(
          "",
          "WARNING: this animation loops, but these joints do not end where they " +
            `started: ${(found.driftingJoints ?? []).join(", ")}. That is what a ` +
            "visible jump at the loop point looks like.",
        );
      }

      lines.push(
        "",
        textOf(
          table(
            ["index", "time", "name", "poseCount"],
            found.keyframes as unknown as Array<Record<string, unknown>>,
            {
              more: found.truncated
                ? `poses expanded for the first 40 keyframes only`
                : undefined,
            },
          ),
        ),
      );

      return text(lines.join("\n"));
    },
  );
}
