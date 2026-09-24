import { z } from "zod";
import { errorText, body, CHARACTER_LIMIT, cursorSchema, decodeCursor, encodeCursor, json, limitSchema, table, text, type ToolResult } from "../lib/format.js";
import { ToolError } from "../lib/errors.js";
import { liveChildren, liveInstance, liveScriptWrite, resolveLivePath } from "../lib/liveops.js";
import {
  assertTargetsOpenPlace,
  requireCredentials,
  requirePlace,
  requireUniverse,
} from "../lib/opencloud.js";
import { defineTool, type ToolContext } from "../lib/tool.js";

interface ReadResponse {
  items: Array<{
    path: string;
    className: string;
    lineCount: number;
    startLine: number;
    /** The end line that was asked for, absent when the read ran to the end. */
    endLine?: number;
    source: string;
    /** Fingerprint of the whole file, handed back to script_edit. */
    revision?: string;
    /** Set when Studio has the script bound to a file outside it. */
    fileSync?: string;
  }>;
  failures: string[];
}

interface EditResponse {
  items: Array<{
    path: string;
    className: string;
    edits: number;
    lineCount: number;
    lineDelta: number;
    /** Revision of the source as written, for chaining a second edit. */
    rev?: string;
  }>;
}

interface GrepResponse {
  items: Array<{
    path: string;
    line: number;
    text: string;
    before?: string[];
    after?: string[];
  }>;
  total: number;
  offset: number;
  searched: number;
}

interface CreateResponse {
  items: Array<{ path: string; className: string }>;
  /** Absent when Studio refused to open a recording, so nothing claims an undo. */
  undoStep?: string;
  /** Problems with what was created that Studio only reports in its own Output. */
  warnings?: string[];
}

/**
 * Prefixes each line with its number, right-aligned to the widest one.
 *
 * The numbers are not decoration: `script_edit` addresses lines by these exact
 * values, so an agent that reads a window can write back to it without counting
 * newlines itself.
 */
export function numbered(source: string, startLine: number): string {
  const lines = source.length === 0 ? [] : source.split("\n");
  const width = String(startLine + lines.length - 1).length;
  return lines
    .map((line, index) => `${String(startLine + index).padStart(width)}│ ${line}`)
    .join("\n");
}

/**
 * Joins script listings, cutting a too-long one on a whole line.
 *
 * A generic clip at the character limit used to end mid-line with advice to
 * "narrow with startLine/endLine" -- without saying where the cut fell, so the
 * agent had to guess the next window of a big script. Here the cut lands after
 * the last complete line and the note names the exact entry to read next.
 * Failures go first, because a note about missing paths is short and must not
 * be the part that gets clipped away.
 */
export function clipListing(
  blocks: string[],
  items: ReadResponse["items"],
  failures: string | null,
): string {
  const head = failures !== null ? `${failures}\n\n` : "";
  const whole = head + blocks.join("\n\n");
  if (whole.length <= CHARACTER_LIMIT) return whole;

  const budget = CHARACTER_LIMIT - 400;
  let shown = head;
  for (const [index, block] of blocks.entries()) {
    const separator = index === 0 ? "" : "\n\n";
    if (shown.length + separator.length + block.length <= budget) {
      shown += separator + block;
      continue;
    }

    const room = budget - shown.length - separator.length;
    const cut = block.lastIndexOf("\n", room);
    const kept = cut > 0 ? block.slice(0, cut) : "";
    const item = items[index];
    const lastLine = /(\d+)│[^\n]*$/.exec(kept)?.[1];
    const untouched = blocks.length - index - 1;
    const rest = untouched > 0 ? ` ${untouched} more script(s) after it were not shown.` : "";

    if (kept !== "") shown += separator + kept;
    const next =
      item !== undefined && lastLine !== undefined
        ? `${item.path} stops at line ${lastLine} of ${item.lineCount}. Continue with ` +
          `{ path: "${item.path}", startLine: ${Number(lastLine) + 1}` +
          (item.endLine !== undefined ? `, endLine: ${item.endLine}` : "") +
          " }."
        : `${item?.path ?? "The next script"} was not shown.`;
    return `${shown}\n\n[clipped at ${CHARACTER_LIMIT} characters: ${next}${rest}]`;
  }
  return shown;
}

export function registerScriptTools(context: ToolContext): void {
  const { bridge } = context;

  defineTool(
    context,
    {
      name: "script_read",
      title: "Read scripts",
      description:
        "Reads Luau source from one or more scripts, with line numbers that " +
        "`script_edit` accepts back verbatim.\n\n" +
        "Source comes from the Studio script editor's live buffer, so anything the " +
        "user has typed but not yet saved is included. Reading the saved property " +
        "instead would hand you stale code and you would 'fix' the change they just " +
        "made.\n\n" +
        "Pass every script you need in one call, including when you want a " +
        "different part of each: an entry may be a bare path for the whole file, " +
        "or `{path, startLine, endLine}` for a window into that one script. The " +
        "top-level `startLine`/`endLine` are the default for entries that do not " +
        "carry their own.\n\n" +
        "A script bound to a file on disk is flagged in the result. Editing one " +
        "of those is a race: whatever writes the file wins, and your change " +
        "disappears the next time it does, with nothing anywhere reporting a " +
        "failure.\n\n" +
        "`open` puts a script on the user's screen at a line, instead of telling " +
        "them where to look. Ask for it when you are pointing at something they " +
        "should see; it is not automatic, and reading twenty scripts does not " +
        "rearrange their editor.\n\n" +
        "`target=\"live\"` reads the code of the PUBLISHED place instead, with " +
        "no Studio involved — which is how you check what is actually " +
        "deployed rather than what is on someone's machine. Two limits are " +
        "real and worth knowing before you reach for it: Roblox's Instance " +
        "API can only see Folders and scripts, so a path through a Model or " +
        "a Part cannot be walked at all; and it addresses things by GUID " +
        "with no search, so each segment of the path costs a round trip. " +
        "Expect seconds. `list: true` shows what is under a path instead of " +
        "reading it, which is how you find your way down.",
      inputSchema: {
        op: z
          .enum(["read", "open"])
          .default("read")
          .describe(
            "'read' returns source. 'open' opens the first path in the user's " +
              "Studio editor at `line` and returns nothing to read.",
          ),
        line: z
          .number()
          .int()
          .min(1)
          .optional()
          .describe("open only: line to put the cursor on."),
        target: z
          .enum(["studio", "live"])
          .default("studio")
          .describe(
            "'studio' reads the open place. 'live' reads the published " +
              "place over Open Cloud, Folders and scripts only.",
          ),
        list: z
          .boolean()
          .optional()
          .describe(
            "live only: list what is under the first path instead of reading " +
              "it. Pass `paths: [\"\"]` to see the top level.",
          ),
        universeId: z.string().optional().describe("live only: omit to use `cloud universe`."),
        placeId: z.string().optional().describe("live only: omit to use `cloud place`."),
        paths: z
          .array(
            z.union([
              z.string().describe("A script path, read in full."),
              z.object({
                path: z.string().describe("The script to read."),
                startLine: z
                  .number()
                  .int()
                  .min(1)
                  .optional()
                  .describe("First line of the window for this script, 1-based and inclusive."),
                endLine: z
                  .number()
                  .int()
                  .min(1)
                  .optional()
                  .describe("Last line of the window for this script, inclusive."),
              }),
            ]),
          )
          .min(1)
          .max(20)
          .describe(
            'Scripts to read, e.g. ["ServerScriptService.Systems.Combat"] or ' +
              '[{ path: "...Combat", startLine: 120, endLine: 180 }].',
          ),
        startLine: z
          .number()
          .int()
          .min(1)
          .optional()
          .describe(
            "Default first line for entries without their own, 1-based and " +
              "inclusive. Omit to start at the top.",
          ),
        endLine: z
          .number()
          .int()
          .min(1)
          .optional()
          .describe(
            "Default last line for entries without their own, inclusive. Omit to " +
              "read to the end.",
          ),
        studioId: z.string().optional().describe("Target Studio; omit for the active one."),
      },
      // `open` moves the user's editor, which is not a read — but it changes
      // nothing in the place, so it is not destructive either.
      readOnly: false,
      destructive: false,
    },
    async (args): Promise<ToolResult> => {
      if (args.target === "live") {
        const credentials = await requireCredentials();
        const universeId = await requireUniverse(args.universeId);
        const placeId = await requirePlace(args.placeId);
        await assertTargetsOpenPlace(bridge, {
          universeId,
          placeId,
          explicit: args.universeId !== undefined || args.placeId !== undefined,
          studioId: args.studioId,
        });
        const first = args.paths[0];
        const wanted = typeof first === "string" ? first : first?.path;

        if (args.list === true) {
          // An empty path means the root, which is how you start exploring a
          // place you have never walked from the outside.
          const at =
            wanted === undefined || wanted === ""
              ? { id: "root" }
              : await resolveLivePath(credentials, { universeId, placeId, path: wanted });
          const children = await liveChildren(credentials, {
            universeId,
            placeId,
            instanceId: at.id,
            limit: 100,
          });
          const items = children["items"] as Array<Record<string, unknown>>;
          if (items.length === 0) {
            return text(
              `Nothing under ${wanted ?? "the root"} that the Instance API can see. ` +
                "It only reports Folders and scripts.",
            );
          }
          return table(["name", "className", "hasChildren"], items);
        }

        if (wanted === undefined) return errorText('live read needs a path in `paths`.');
        const at = await resolveLivePath(credentials, { universeId, placeId, path: wanted });
        const read = await liveInstance(credentials, {
          universeId,
          placeId,
          instanceId: at.id,
        });
        const source = read["source"];
        if (typeof source !== "string") {
          return text(
            `${wanted} is a ${read["className"]}, which holds no source. ` +
              "Use `list: true` to see what is inside it.",
          );
        }
        return body(source, `${wanted} (${read["className"]}, published place)`);
      }

      if (args.op === "open") {
        /*
         * One path, not the batch. Opening is a thing that happens to the
         * user's screen, and doing it twenty times because the read call
         * happened to take twenty paths would be hostile.
         */
        const first = args.paths[0];
        if (first === undefined) return errorText("open needs a path.");
        const path = typeof first === "string" ? first : first.path;
        const opened = await bridge.call<{ path: string; className: string; line?: number }>(
          "script.open",
          { path, line: args.line },
          { studioId: args.studioId },
        );
        return text(
          `Opened ${opened.path} in Studio` +
            (opened.line !== undefined ? ` at line ${opened.line}.` : ".") +
            (args.paths.length > 1
              ? ` (${args.paths.length - 1} other path(s) ignored — open takes one.)`
              : ""),
        );
      }

      const response = await bridge.call<ReadResponse>(
        "script.read",
        { paths: args.paths, startLine: args.startLine, endLine: args.endLine },
        { studioId: args.studioId },
      );

      const blocks = response.items.map((item) => {
        const shown = item.source.length === 0 ? 0 : item.source.split("\n").length;

        // An empty window means the requested range sits past the end of the
        // file, or runs backwards. Reporting it as "lines 50-49 of 9" alongside
        // no content reads as a broken tool rather than a bad argument.
        if (shown === 0) {
          if (item.lineCount === 0) {
            return `${item.path}  (${item.className}) is empty.`;
          }
          const header = `${item.path}  (${item.className}, ${item.lineCount} lines)`;
          // The two causes want different advice, and "the file ends at line 8"
          // for a backwards range points at the file when the argument is what
          // is wrong.
          if (item.endLine !== undefined && item.endLine < item.startLine) {
            return (
              `${header}\n` +
              `Nothing to read: endLine ${item.endLine} is before startLine ` +
              `${item.startLine}. Ranges run forwards and include both ends.`
            );
          }
          const asked =
            item.endLine !== undefined
              ? `Lines ${item.startLine}-${item.endLine}`
              : `Line ${item.startLine} onwards`;
          return (
            `${header}\n` +
            `${asked} is empty — the file ends at line ${item.lineCount}.`
          );
        }

        const range =
          shown === item.lineCount
            ? `${item.lineCount} lines`
            : `lines ${item.startLine}-${item.startLine + shown - 1} of ${item.lineCount}`;
        // The revision rides in the header rather than in a block of its own, so
        // it is impossible to read the source without also being handed the
        // token that makes editing it safe.
        const stamp = item.revision !== undefined ? `, rev ${item.revision}` : "";
        /*
         * The sync warning goes above the source, not below it. Below, it is
         * one line after two hundred and will be skimmed past; the whole point
         * is to be read before an edit is written.
         */
        const synced =
          item.fileSync !== undefined
            ? `\n! This script is synced from a file on disk (${item.fileSync}). Editing it here ` +
              "is a race with whatever writes that file, and the loser leaves no error.\n"
            : "";
        return `${item.path}  (${item.className}, ${range}${stamp})${synced}\n${numbered(item.source, item.startLine)}`;
      });

      const failures =
        response.failures.length > 0
          ? `Could not read ${response.failures.length} path(s):\n` +
            response.failures.map((failure) => `  - ${failure}`).join("\n")
          : null;
      if (blocks.length === 0) return text(failures ?? "No scripts read.");

      return text(clipListing(blocks, response.items, failures));
    },
  );

  defineTool(
    context,
    {
      name: "script_edit",
      title: "Edit scripts",
      description:
        "Edits Luau source through the Studio script editor. This is the tool to " +
        "use for any change to existing code.\n\n" +
        "Every edit in one call is all-or-nothing: the whole batch is resolved " +
        "against current source before anything is written, so if one edit cannot " +
        "be applied nothing is. Batch related changes together, even across " +
        "different scripts.\n\n" +
        "Each edit picks exactly one mode:\n" +
        "  find/replace — literal text, not a pattern. Preferred: it survives line " +
        "numbers shifting. Fails if the text is not unique, unless you set " +
        "`replaceAll`, so include enough surrounding lines to pin it down.\n" +
        "  startLine/endLine + replacement — for line ranges from `script_read`. " +
        "Numbers refer to the file as you read it; several line edits to one script " +
        "are applied bottom-up so they do not shift each other.\n" +
        "  source — replaces the whole script. Only for small files or a rewrite; " +
        "it discards anything the user changed since you read it.\n\n" +
        "Pass `revision` on every edit. `script_read` prints it as `rev` beside " +
        "each file, and sending it back makes the write conditional: if the " +
        "script changed since you read it the batch is refused with " +
        "STALE_SCRIPT and nothing is written. Without it the edit is applied " +
        "blind, which matters most for the two modes that cannot notice: a line " +
        "range still applies cleanly to source somebody else moved, it just " +
        "lands on the wrong lines, and `source` discards their work entirely. " +
        "Another agent editing the same place, or the user typing in the " +
        "editor, is enough.\n\n" +
        "Writes go through `ScriptEditorService:UpdateSourceAsync`, so an open " +
        "editor tab updates in place and unsaved work is preserved. Undo for " +
        "source changes is the script editor's own, per script — Ctrl+Z in a " +
        "script tab reverts that script, not the whole batch.\n\n" +
        "`target=\"live\"` edits the PUBLISHED place instead. It takes ONE " +
        "edit, it replaces the whole `source` rather than finding and " +
        "replacing, and there is no undo of any kind — so read the script " +
        "with `script_read target=\"live\"` first and send back the whole " +
        "thing. Needs `confirm: true`.\n\n" +
        "It changes the SAVED place, not running servers: people already " +
        "playing keep the old code until their server empties. Follow it " +
        "with `universe op=\"restart\"` to roll them over.",
      inputSchema: {
        target: z
          .enum(["studio", "live"])
          .default("studio")
          .describe(
            "'studio' edits the open place. 'live' rewrites a script in the " +
              "published place over Open Cloud — one file, whole source, no " +
              "undo.",
          ),
        path: z.string().optional().describe('live only: the script, e.g. "ServerScriptService.Main".'),
        source: z.string().optional().describe("live only: the complete new source."),
        universeId: z.string().optional().describe("live only: omit to use `cloud universe`."),
        placeId: z.string().optional().describe("live only: omit to use `cloud place`."),
        confirm: z.boolean().optional().describe('Required for target="live".'),
        edits: z
          .array(
            z.object({
              path: z
                .string()
                .describe('Script to edit, e.g. "ServerScriptService.Systems.Combat".'),
              find: z
                .string()
                .optional()
                .describe(
                  "Exact text to replace, whitespace included. Literal, not a regex " +
                    "or Lua pattern.",
                ),
              replace: z
                .string()
                .optional()
                .describe("Text to put in its place. Required with `find`; empty string deletes."),
              replaceAll: z
                .boolean()
                .optional()
                .describe(
                  "Replace every occurrence. Without this a non-unique `find` is " +
                    "refused rather than guessing which one you meant.",
                ),
              startLine: z
                .number()
                .int()
                .min(1)
                .optional()
                .describe("First line to replace, 1-based and inclusive."),
              endLine: z
                .number()
                .int()
                .min(0)
                .optional()
                .describe(
                  "Last line to replace, inclusive. Defaults to `startLine`. Set it " +
                    "one below `startLine` to insert without replacing anything.",
                ),
              replacement: z
                .string()
                .optional()
                .describe("New text for that line range. Required with `startLine`."),
              source: z
                .string()
                .optional()
                .describe("Complete new source for the script, replacing everything."),
              revision: z
                .string()
                .optional()
                .describe(
                  "The `rev` value script_read printed for this file. Pass it and the " +
                    "edit is refused if the script changed since you read it, instead " +
                    "of being applied to source you have not seen.",
                ),
            }),
          )
          .max(50)
          .optional()
          .describe(
            "Edits to apply together as one undoable step. Required unless target is \"live\". " +
              "The result carries each script's new `rev`, so a follow-up edit needs no re-read.",
          ),
        studioId: z.string().optional().describe("Target Studio; omit for the active one."),
      },
      destructive: true,
    },
    async (args): Promise<ToolResult> => {
      if (args.target === "live") {
        if (!args.path || args.source === undefined) {
          throw new ToolError("BAD_PARAMS", 'live edit needs `path` and `source`.');
        }
        if (args.confirm !== true) {
          throw new ToolError(
            "NEEDS_CONFIRM",
            "This rewrites a script in the published place.",
            "There is no undo. Read it with `script_read target=\"live\"` first " +
              "and send back the whole file, then pass confirm: true.",
          );
        }
        const credentials = await requireCredentials();
        const universeId = await requireUniverse(args.universeId);
        const placeId = await requirePlace(args.placeId);
        await assertTargetsOpenPlace(bridge, {
          universeId,
          placeId,
          explicit: args.universeId !== undefined || args.placeId !== undefined,
          studioId: args.studioId,
        });
        const at = await resolveLivePath(credentials, { universeId, placeId, path: args.path });
        if (at.className !== "Script" && at.className !== "LocalScript" && at.className !== "ModuleScript") {
          throw new ToolError(
            "WRONG_KIND",
            `${args.path} is a ${at.className}, which has no source to write.`,
          );
        }
        return json(
          await liveScriptWrite(credentials, {
            universeId,
            placeId,
            instanceId: at.id,
            className: at.className,
            source: args.source,
          }),
        );
      }

      if (!args.edits || args.edits.length === 0) {
        throw new ToolError("BAD_PARAMS", "script_edit needs at least one entry in `edits`.");
      }
      const response = await bridge.call<EditResponse>(
        "script.edit",
        { edits: args.edits },
        { studioId: args.studioId, timeoutMs: 30_000 },
      );

      return table(
        ["path", "className", "edits", "lineCount", "lineDelta", "rev"],
        response.items as unknown as Array<Record<string, unknown>>,
      );
    },
  );

  defineTool(
    context,
    {
      name: "script_grep",
      title: "Search script source",
      description:
        "Searches inside Luau source across the place and returns matching lines " +
        "with their paths and line numbers.\n\n" +
        "Use this to find where something is defined or used before editing it — " +
        "it is far cheaper than reading whole scripts to look for one call.\n\n" +
        "Patterns are Lua patterns, which are not regular expressions: `%` escapes " +
        "instead of backslash, there is no alternation, and `-` means a lazy " +
        "quantifier. Set `literal` to search for text exactly as written, which is " +
        "usually what you want for identifiers.\n\n" +
        "Matches come from the script editor's live buffer, so unsaved edits are " +
        "searched too.",
      inputSchema: {
        pattern: z
          .string()
          .describe('Lua pattern, or exact text when `literal` is set, e.g. "PlayerAdded".'),
        path: z
          .string()
          .optional()
          .describe('Limit to this subtree, e.g. "ServerScriptService". Omit to search everywhere.'),
        literal: z
          .boolean()
          .default(false)
          .describe("Treat `pattern` as plain text rather than a Lua pattern."),
        ignoreCase: z
          .boolean()
          .default(false)
          .describe(
            "Case-insensitive. Both sides are lowercased, so pattern classes like " +
              "%u stop being meaningful — combine with `literal`.",
          ),
        contextLines: z
          .number()
          .int()
          .min(0)
          .max(10)
          .default(0)
          .describe("Lines of context to show either side of each match."),
        className: z
          .string()
          .optional()
          .describe('Restrict to one script class: "Script", "LocalScript" or "ModuleScript".'),
        limit: limitSchema,
        cursor: cursorSchema,
        studioId: z.string().optional().describe("Target Studio; omit for the active one."),
      },
      readOnly: true,
    },
    async (args): Promise<ToolResult> => {
      const offset = decodeCursor(args.cursor);
      const response = await bridge.call<GrepResponse>(
        "script.grep",
        {
          pattern: args.pattern,
          path: args.path,
          literal: args.literal,
          ignoreCase: args.ignoreCase,
          contextLines: args.contextLines,
          className: args.className,
          limit: args.limit,
          offset,
        },
        { studioId: args.studioId, timeoutMs: 30_000 },
      );

      if (response.total === 0) {
        if (response.searched === 0) {
          return text(
            args.path
              ? `No scripts under "${args.path}" to search.`
              : "This place contains no scripts.",
          );
        }
        // Suggesting `literal` to someone who already set it reads as though the
        // tool did not register the argument.
        // `|` is called out by name because it is the one difference that fails
        // silently. A regex habit writes `foo|bar`, Lua reads it as the literal
        // characters, nothing matches, and the empty result looks like an
        // answer rather than like a malformed pattern.
        const alternation = !args.literal && args.pattern.includes("|");
        return text(
          `No matches in ${response.searched} script(s).\n` +
            (alternation
              ? "This pattern contains `|`, which Lua patterns do not support — " +
                "there is no alternation, so `|` matched as a literal character. " +
                "Search one alternative per call, or set `literal`."
              : args.literal
                ? "The match is literal and case-sensitive unless you set `ignoreCase`."
                : "Check case, and remember patterns are Lua patterns — set `literal` " +
                  "to search for the text exactly as written."),
        );
      }

      const lines: string[] = [];
      let previousPath = "";
      for (const match of response.items) {
        // Context blocks get a separator; a flat list of adjacent lines is
        // otherwise impossible to tell apart from a run of separate matches.
        if (match.path !== previousPath) {
          if (previousPath !== "") lines.push("");
          previousPath = match.path;
        }
        for (const [index, before] of (match.before ?? []).entries()) {
          lines.push(`${match.path}-${match.line - (match.before?.length ?? 0) + index}- ${before}`);
        }
        lines.push(`${match.path}:${match.line}: ${match.text}`);
        for (const [index, after] of (match.after ?? []).entries()) {
          lines.push(`${match.path}-${match.line + index + 1}- ${after}`);
        }
      }

      const trailer: string[] = [`[searched ${response.searched} scripts]`];
      const nextOffset = offset + response.items.length;
      if (nextOffset < response.total) {
        trailer.unshift(
          `[showing ${response.items.length} of ${response.total} matches — call again ` +
            `with cursor: "${encodeCursor(nextOffset)}"]`,
        );
      }

      return body(
        [...lines, "", ...trailer].join("\n"),
        "re-run with a smaller `limit` or a narrower `path`",
      );
    },
  );

  defineTool(
    context,
    {
      name: "script_create",
      title: "Create scripts",
      description:
        "Creates Script, LocalScript or ModuleScript instances with their source.\n\n" +
        "Batch related scripts into one call: they are created inside one " +
        "ChangeHistoryService recording, so the user can drop a whole generated " +
        "system in a single undo. The response says whether that recording was " +
        "actually opened — Studio refuses while another one is in progress.\n\n" +
        "Prefer `Script` with `runContext: \"Client\"` over `LocalScript` in new " +
        "work — a Script with an explicit RunContext runs wherever you parent it, " +
        "while LocalScript only runs under a player's character, backpack or " +
        "PlayerGui.\n\n" +
        "The exception is the starter containers — `StarterGui`, `StarterPack`, " +
        "`StarterPlayerScripts`, `StarterCharacterScripts`. They are COPIED into " +
        "each player, so a Script with a non-Legacy RunContext there runs once " +
        "where it sits and again in every copy, while a Legacy one does not run " +
        "at all. Use `LocalScript` inside those. Creating one anyway comes back " +
        "with a warning, because Studio's own warning about it goes to its Output " +
        "and never reaches `console`.\n\n" +
        "Use `script_edit` to change a script that already exists.",
      inputSchema: {
        scripts: z
          .array(
            z.object({
              parent: z
                .string()
                .describe('Path of the parent instance, e.g. "ServerScriptService.Systems".'),
              name: z.string().describe("Name for the new script."),
              className: z
                .enum(["Script", "LocalScript", "ModuleScript"])
                .describe("Which kind of script to create."),
              source: z
                .string()
                .optional()
                .describe("Initial Luau source. Omit for Roblox's default stub."),
              runContext: z
                .enum(["Legacy", "Server", "Client"])
                .optional()
                .describe(
                  "Where a `Script` runs. 'Legacy' means server-only and only under " +
                    "a server container. Ignored for the other classes.",
                ),
              disabled: z
                .boolean()
                .optional()
                .describe("Create it disabled, so it does not run on the next playtest."),
            }),
          )
          .min(1)
          .max(50)
          .describe("Scripts to create together as one undoable step."),
        studioId: z.string().optional().describe("Target Studio; omit for the active one."),
      },
    },
    async (args): Promise<ToolResult> => {
      const response = await bridge.call<CreateResponse>(
        "script.create",
        { scripts: args.scripts },
        // A batch of full script sources is the largest payload any tool sends.
        // The timeouts once blamed on its size were the plugin dropping any
        // command the stream delivered in more than one piece (see frameReader
        // in Transport.luau); the longer budget stays for big batches that
        // Studio is slow to parent.
        { studioId: args.studioId, timeoutMs: 60_000 },
      );

      const listing = table(
        ["path", "className"],
        response.items as unknown as Array<Record<string, unknown>>,
        {
          more: response.undoStep
            ? `undoable as one step, "${response.undoStep}" — Ctrl+Z with focus ` +
              "outside the script editor"
            : "Studio would not open an undo recording, so this is not undoable " +
              "as a single step",
        },
      );
      if (!response.warnings || response.warnings.length === 0) return listing;

      // Appended rather than thrown: the scripts do exist, and the fix is a
      // different class, not a retry.
      const existing = listing.content[0];
      const body = existing && existing.type === "text" ? existing.text : "";
      return text(`${body}\n\nWARNING: ${response.warnings.join("\n\n")}`);
    },
  );
}
