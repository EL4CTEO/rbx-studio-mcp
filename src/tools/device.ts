import { z } from "zod";
import { json, table, text, type ToolResult } from "../lib/format.js";
import { defineTool, type ToolContext } from "../lib/tool.js";

interface DeviceEntry {
  id: string;
  name?: string;
  form?: string;
  resolution?: string;
}

interface DeviceListResponse {
  devices: DeviceEntry[];
  count: number;
  current: Record<string, unknown>;
}

export function registerDeviceTools(context: ToolContext): void {
  const { bridge } = context;

  defineTool(
    context,
    {
      name: "device",
      title: "Emulate a phone, tablet or console",
      description:
        "Resizes the Studio viewport to a real device, so you can see what a " +
        "player on that device sees.\n\n" +
        "Most Roblox players are on a phone and most UI is built on a desktop " +
        "monitor, which is where interfaces break: a button under the notch, a " +
        "menu off the bottom of a 393-pixel-tall screen, text sized for a " +
        "display three times larger. None of that is visible in the data model " +
        "— every one of those instances has perfectly correct properties — so " +
        "this is the only way to find it short of owning the hardware.\n\n" +
        "The workflow is: `set` a device, `screenshot`, look. Pair it with " +
        "`playtest` to check a running game's HUD rather than the editor.\n\n" +
        "`list` gives the ids, each with its real name, form factor and " +
        "resolution — ids look like \"iphone_16\", \"ipad_a16\", " +
        "\"samsung_galaxy_s25_ultra\", \"xbox\", \"meta_quest_3\".\n\n" +
        "`network` degrades the connection on purpose — latency, jitter and " +
        "packet loss — which is the other half of what a phone player " +
        "actually gets. A menu that works at 0ms is not evidence that it works " +
        "at 300: the spinner that never stops, the button that fires twice, the " +
        "HUD that arrives after the round started are all invisible on a local " +
        "connection. Use a `preset` (`wifi`, `4g`, `3g`, `poor`, `clear`) or " +
        "set the numbers yourself, then `playtest` and watch.\n\n" +
        "`stop` returns Studio to the normal editor viewport AND clears the " +
        "network shaping. Do that when you are finished: a left-over emulated " +
        "device makes every later screenshot the wrong shape, a left-over 400ms " +
        "delay makes the whole place feel broken, and nothing on screen says " +
        "why in either case.",
      inputSchema: {
        op: z
          .enum(["list", "set", "network", "stop", "state"])
          .default("state")
          .describe(
            "'list' shows the available devices, 'set' switches to one, " +
              "'network' shapes the connection, 'stop' undoes both, 'state' " +
              "only reports.",
          ),
        device: z
          .string()
          .optional()
          .describe('set only: the device id, e.g. "iphone_16". See `list`.'),
        orientation: z
          .enum(["LandscapeLeft", "LandscapeRight", "Portrait", "Sensor"])
          .optional()
          .describe(
            "set only: which way up. Portrait is worth testing separately — " +
              "most mobile players hold the phone upright and most UI is only " +
              "ever checked in landscape.",
          ),
        form: z
          .enum(["Phone", "Tablet", "Console", "Desktop", "VR"])
          .optional()
          .describe("list only: show only devices of this form factor."),
        preset: z
          .enum(["clear", "wifi", "4g", "3g", "poor"])
          .optional()
          .describe(
            "network only: a whole connection in one word. clear=0ms (normal), " +
              "wifi=15ms, 4g=60ms/0.5% loss, 3g=150ms/2% loss, poor=400ms/8% " +
              "loss. Named fields below override whichever part you name.",
          ),
        latency: z
          .number()
          .min(0)
          .max(1000)
          .optional()
          .describe(
            "network only: minimum delay in milliseconds, up to 1000 — the " +
              "engine's own ceiling. 0 clears it.",
          ),
        jitter: z
          .number()
          .min(0)
          .max(1000)
          .optional()
          .describe(
            "network only: how much the delay varies, in milliseconds. Jitter " +
              "breaks things steady latency does not — it is what makes " +
              "replicated motion stutter rather than simply lag.",
          ),
        loss: z
          .number()
          .min(0)
          .max(50)
          .optional()
          .describe(
            "network only: percentage of packets thrown away, up to 50 — the " +
              "engine's own ceiling. The field that finds real bugs: latency " +
              "makes a game feel slow, loss makes it behave wrongly. 2-8% is a " +
              "bad mobile connection.",
          ),
        memory: z
          .number()
          .int()
          .min(0)
          .max(65536)
          .optional()
          .describe(
            "network only: pretend the machine has this many MB of memory. A " +
              "cheap phone is a small screen AND little memory; this is the " +
              "half that makes textures unload. 0 removes the cap.",
          ),
        direction: z
          .enum(["in", "out", "both"])
          .optional()
          .describe(
            "network only: which way to degrade. 'in' is the player with a bad " +
              "connection, 'out' is everyone else seeing that player late. " +
              "Defaults to both.",
          ),
        studioId: z.string().optional().describe("Target Studio; omit for the active one."),
      },
      readOnly: false,
      destructive: false,
    },
    async (args): Promise<ToolResult> => {
      if (args.op === "list") {
        const response = await bridge.call<DeviceListResponse>(
          "device.list",
          {},
          // One GetDeviceInfoAsync per device, and there are around forty.
          { studioId: args.studioId, timeoutMs: 45_000 },
        );
        const rows = response.devices.filter(
          (entry) => args.form === undefined || entry.form === args.form,
        );
        if (rows.length === 0) {
          return text(
            `No ${args.form} devices are available. Studio offers ${response.count} in total; ` +
              "call again without `form` to see them.",
          );
        }
        return table(
          ["id", "name", "form", "resolution"],
          rows as unknown as Array<Record<string, unknown>>,
          {
            more:
              `${rows.length} of ${response.count} devices; ` +
              `currently ${JSON.stringify(response.current["device"] ?? "default")}`,
          },
        );
      }

      if (args.op === "set" && (args.device === undefined || args.device === "")) {
        return text('set needs a `device` id. Call `device op="list"` to see them.');
      }

      if (args.op === "network") {
        const shaped = await bridge.call<Record<string, unknown>>(
          "device.network",
          {
            preset: args.preset,
            latency: args.latency,
            jitter: args.jitter,
            loss: args.loss,
            memory: args.memory,
            direction: args.direction,
          },
          { studioId: args.studioId, timeoutMs: 30_000 },
        );
        return json(
          shaped,
          shaped["shaping"] === true
            ? 'Traffic is degraded from now on, in edit and in playtest, until `device op="stop"` ' +
                "or `op=\"network\" preset=\"clear\"`. Nothing on screen says so — if the place " +
                "starts behaving strangely later, this is the first thing to rule out."
            : "The connection is back to normal.",
        );
      }

      const command =
        args.op === "set" ? "device.set" : args.op === "stop" ? "device.stop" : "device.state";
      const response = await bridge.call<Record<string, unknown>>(
        command,
        { device: args.device, orientation: args.orientation },
        { studioId: args.studioId, timeoutMs: 30_000 },
      );

      return json(
        response,
        args.op === "set"
          ? 'Take a `screenshot` to see it. Call `device op="stop"` when finished, or every later screenshot stays this shape.'
          : undefined,
      );
    },
  );
}
