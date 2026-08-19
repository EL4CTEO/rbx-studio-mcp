import { z } from "zod";
import { json, text, type ToolResult } from "../lib/format.js";
import { pluginStalenessWarning } from "../lib/pluginbuild.js";
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
  /** Scripts open in the editor, absent when none are. */
  openScripts?: Array<{
    path: string;
    className?: string;
    lineCount?: number;
    cursorLine?: number;
    cursorColumn?: number;
    selectedLines?: string;
    selectedText?: string;
    visibleLines?: string;
  }>;
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
        "whether it is in edit / run / play mode, the current selection, which " +
        "scripts are open in the editor, and how big the data model is.\n\n" +
        "Call this FIRST in any Studio session, and again whenever a tool reports " +
        "NO_STUDIO or TIMEOUT — it is the cheapest way to tell a disconnected " +
        "plugin apart from a genuinely failing request. Also call it before and " +
        "after `playtest`, because most tools behave differently in run mode.\n\n" +
        "`openScripts` is what the user is actually working on: for each open tab " +
        "it gives the script's path, the cursor line, any selected text, and which " +
        "lines are on screen. Use it whenever a request is deictic — 'this " +
        "function', 'the script I'm in', 'fix this' — instead of searching the " +
        "place or asking which file they mean. Studio exposes no focused-tab API, " +
        "so with several open, prefer the one holding a selection and otherwise " +
        "ask.\n\n" +
        "Returns JSON. Selection is capped at 50 entries and selected text at 400 " +
        "characters; use `find` or `script_read` for more.",
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

      // A stale plugin answers with older handlers and no other symptom, so the
      // warning rides along with the one call agents are told to make first.
      const session = bridge
        .list()
        .find((entry) => entry.studioId === (studioId ?? bridge.activeId));
      const warning = pluginStalenessWarning(session?.buildId);
      return json(status, warning ? `WARNING: ${warning}` : undefined);
    },
  );

  defineTool(
    context,
    {
      name: "list_studios",
      title: "List connected Studios",
      description:
        "Lists every Roblox Studio window currently connected to this server, " +
        "with its studioId, place name, transport (sse or poll), when it " +
        "connected, and which one is active.\n\n" +
        "Call this whenever a tool reports AMBIGUOUS_STUDIO, and whenever the " +
        "user refers to 'the other place' or 'my other window'. With a single " +
        "Studio open every other tool targets it automatically, so you can skip " +
        "it then.\n\n" +
        "Nothing is targeted by default when several are connected: pick one with " +
        "`set_active_studio`, or pass `studioId` to a single tool call to act on " +
        "one place without changing the default.\n\n" +
        "`placeName` is the data model's name — usually 'Place1', 'Place5' — not " +
        "the name on the Studio tab or the Creator Dashboard, so it often will not " +
        "match what the user calls the place. `placeId` is reliable and unique " +
        "per window. When the user names a place and the mapping is not obvious, " +
        "show them the list and ask rather than guessing which is which.",
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
      // A defaulted target is not reported as active: tools refuse to use it
      // while several are connected, so showing it as active would explain
      // neither the AMBIGUOUS_STUDIO that follows nor how to clear it.
      const active = bridge.activeIsChosen || sessions.length === 1 ? bridge.activeId : null;
      return json(
        {
          studios: sessions.map((session) => ({
            studioId: session.studioId,
            placeName: session.placeName,
            placeId: session.placeId,
            connectedAt: new Date(session.connectedAt).toISOString(),
            transport: session.transport,
            pluginVersion: session.pluginVersion,
            buildId: session.buildId,
            stale: pluginStalenessWarning(session.buildId) ?? false,
            active: session.studioId === active,
          })),
          activeStudioId: active,
        },
        active === null && sessions.length > 1
          ? "No place is selected. Ask the user which one they mean, then call " +
              "set_active_studio."
          : undefined,
      );
    },
  );

  defineTool(
    context,
    {
      name: "set_active_studio",
      title: "Set active Studio",
      description:
        "Chooses which connected Studio window every other tool targets by " +
        "default. Use it after list_studios when several places are open, and " +
        "again whenever the user says to switch to another place.\n\n" +
        "The choice persists until it is changed or that Studio disconnects. " +
        "While several Studios are connected and none has been chosen, tools " +
        "refuse with AMBIGUOUS_STUDIO rather than guessing.",
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
