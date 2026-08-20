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
        "`stop` returns Studio to the normal editor viewport. Do that when you " +
        "are finished: a left-over emulated device makes every later screenshot " +
        "the wrong shape, and nothing on screen obviously says why.",
      inputSchema: {
        op: z
          .enum(["list", "set", "stop", "state"])
          .default("state")
          .describe(
            "'list' shows the available devices, 'set' switches to one, 'stop' " +
              "returns to the normal viewport, 'state' only reports.",
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
          ? "Take a `screenshot` to see it. Call `device op=\"stop\"` when finished, or every later screenshot stays this shape."
          : undefined,
      );
    },
  );
}
