import { z } from "zod";
import { json, text, type ToolResult } from "../lib/format.js";
import { pluginStalenessWarning } from "../lib/pluginbuild.js";
import { protocolMismatchWarning } from "../lib/protocol.js";
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
  /** "edit", "playtest server", "playtest (solo)" ... */
  context?: string;
  /** Data model name, present only when it differs from the published name. */
  dataModelName?: string;
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

      const view = await bridge.sessions();
      const targetId = studioId ?? view.activeId;
      if (targetId) await bridge.notePlaceName(targetId, status.placeName, status.context);

      // A stale plugin answers with older handlers and no other symptom, so the
      // warning rides along with the one call agents are told to make first.
      const session = view.list.find((entry) => entry.studioId === targetId);
      const warnings = [
        pluginStalenessWarning(session?.buildId),
        session ? protocolMismatchWarning(session.protocolVersion) : null,
      ].filter((warning): warning is string => warning !== null);
      return json(status, warnings.length > 0 ? `WARNING: ${warnings.join(" ")}` : undefined);
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
        "Each Studio is queried live, so `placeName` is the published name the " +
        "user would recognise. A place never saved to Roblox has no published " +
        "name and falls back to its data model name ('Place1').\n\n" +
        "`context` matters more than it looks. Pressing Play adds a second entry " +
        "for the playtest's server — same place, same name, same id as the editor " +
        "session. Instances created or changed in a 'playtest' context are thrown " +
        "away the moment the user stops, so building there looks like it worked " +
        "and then vanishes. Target 'edit' unless the user specifically wants to " +
        "inspect or affect the running game.",
      inputSchema: {},
      readOnly: true,
    },
    async (): Promise<ToolResult> => {
      const view = await bridge.sessions();
      const sessions = view.list;
      if (sessions.length === 0) {
        return text(
          "No Studio instances are connected.\n" +
            "Open Roblox Studio with the companion plugin installed — it connects " +
            "automatically on load — then call this again.",
        );
      }
      // A defaulted target is not reported as active: tools refuse to use it
      // while several are connected, so showing it as active would explain
      // neither the AMBIGUOUS_STUDIO that follows nor how to clear it.
      const active = view.activeIsChosen || sessions.length === 1 ? view.activeId : null;

      // The identity captured at connect only knows the data model's name. Each
      // Studio is asked live for the name the user would actually recognise,
      // plus what it has open — which is usually how someone identifies a window
      // ("the one with the intro script"). A Studio that does not answer still
      // gets listed, from the identity it announced.
      const detail = await Promise.all(
        sessions.map(async (session) => {
          try {
            const status = await bridge.call<StudioStatus>(
              "studio.status",
              {},
              { studioId: session.studioId, timeoutMs: 3_000 },
            );
            await bridge.notePlaceName(session.studioId, status.placeName, status.context);
            return {
              placeName: status.placeName,
              context: status.context,
              openScripts: (status.openScripts ?? []).map((script) => script.path),
            };
          } catch {
            return { placeName: session.placeName, unreachable: true };
          }
        }),
      );

      return json(
        {
          studios: sessions.map((session, index) => ({
            studioId: session.studioId,
            ...detail[index],
            placeId: session.placeId,
            connectedAt: new Date(session.connectedAt).toISOString(),
            transport: session.transport,
            pluginVersion: session.pluginVersion,
            buildId: session.buildId,
            stale: pluginStalenessWarning(session.buildId) ?? false,
            protocolMismatch: protocolMismatchWarning(session.protocolVersion) ?? false,
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
        "refuse with AMBIGUOUS_STUDIO rather than guessing.\n\n" +
        "The choice belongs to this MCP connection alone. Several agents can " +
        "share one Studio, and each keeps its own target, so calling this never " +
        "moves another client's — two editors, or two sessions, can work on two " +
        "places at once.\n\n" +
        "SUBAGENTS SHARE THEIR PARENT'S CONNECTION, and therefore its target. A " +
        "subagent calling this retargets its parent and every sibling, and the " +
        "damage is silent: later calls that name no studioId still succeed, just " +
        "against the wrong place — and if that place is a playtest, everything " +
        "written there is discarded when it stops. Inside a subagent, pass " +
        "`studioId` on each call instead of calling this.",
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
      await bridge.setActive(studioId);
      const session = (await bridge.sessions()).list.find((s) => s.studioId === studioId);

      // Confirmed with the session's context because two entries can share a
      // place name, and picking the playtest one means work that disappears
      // when the user presses stop.
      const status = await bridge
        .call<StudioStatus>("studio.status", {}, { studioId, timeoutMs: 3_000 })
        .catch(() => null);
      const where = status?.context && status.context !== "edit" ? ` (${status.context})` : "";

      return text(
        `Active Studio is now "${status?.placeName ?? session?.placeName ?? studioId}"${where}.` +
          (where
            ? "\nThis is a running playtest, not the editor. Changes made here are " +
              "discarded when the user stops it."
            : ""),
      );
    },
  );
}
