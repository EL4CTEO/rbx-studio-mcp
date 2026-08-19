import { z } from "zod";
import { json, text, type ToolResult } from "../lib/format.js";
import { defineTool, type ToolContext } from "../lib/tool.js";

/** Snapshot the plugin returns for `studio.status`. */
interface StudioStatus {
  placeName: string;
  placeId: number;
  isRunning: boolean;
  isRunMode: boolean;
  isEdit: boolean;
  isServerView: boolean;
  selection: Array<{ path: string; className: string }>;
  descendantCount: number;
  scriptCount: number;
  studioVersion: string;
}

export function registerSessionTools(context: ToolContext): void {
  const { bridge } = context;

  defineTool(
    context,
    {
      name: "studio_status",
      title: "Studio status",
      description:
        "One-call snapshot of the connected Roblox Studio: place name and id, " +
        "whether it is in edit / run / play mode, the current selection, and how " +
        "big the data model is.\n\n" +
        "Call this FIRST in any Studio session, and again whenever a tool reports " +
        "NO_STUDIO or TIMEOUT — it is the cheapest way to tell a disconnected " +
        "plugin apart from a genuinely failing request. Also call it before and " +
        "after `playtest`, because most tools behave differently in run mode.\n\n" +
        "Returns JSON. Selection is capped at 50 entries; use `find` if you need " +
        "more than that.",
      inputSchema: {
        studioId: z
          .string()
          .optional()
          .describe(
            "Target a specific Studio instance. Omit to use the active one " +
              "(see list_studios / set_active_studio).",
          ),
      },
      readOnly: true,
    },
    async ({ studioId }): Promise<ToolResult> => {
      const status = await bridge.call<StudioStatus>("studio.status", {}, { studioId });
      return json(status);
    },
  );

  defineTool(
    context,
    {
      name: "list_studios",
      title: "List connected Studios",
      description:
        "Lists every Roblox Studio instance currently connected to this server, " +
        "with its id, place name, transport (sse or poll) and which one is active.\n\n" +
        "Only needed when the user has more than one place open, or when a tool " +
        "reports AMBIGUOUS_STUDIO. With a single Studio open, every other tool " +
        "targets it automatically and you can skip this.",
      inputSchema: {},
      readOnly: true,
    },
    async (): Promise<ToolResult> => {
      const sessions = bridge.list();
      if (sessions.length === 0) {
        return text(
          "No Studio instances are connected.\n" +
            "Open Roblox Studio and enable the Studio MCP plugin (Plugins tab -> " +
            "Studio MCP -> Connect), then call this again.",
        );
      }
      const active = bridge.activeId;
      return json(
        sessions.map((session) => ({
          studioId: session.studioId,
          placeName: session.placeName,
          placeId: session.placeId,
          transport: session.transport,
          pluginVersion: session.pluginVersion,
          active: session.studioId === active,
        })),
      );
    },
  );

  defineTool(
    context,
    {
      name: "set_active_studio",
      title: "Set active Studio",
      description:
        "Chooses which connected Studio instance every other tool targets by " +
        "default. Use it after list_studios when several places are open. The " +
        "choice persists for the rest of the session.",
      inputSchema: {
        studioId: z
          .string()
          .min(1)
          .describe("A studioId from list_studios."),
      },
      readOnly: false,
      destructive: false,
      idempotent: true,
    },
    async ({ studioId }): Promise<ToolResult> => {
      bridge.setActive(studioId);
      const session = bridge.list().find((s) => s.studioId === studioId);
      return text(`Active Studio is now "${session?.placeName ?? studioId}".`);
    },
  );
}
