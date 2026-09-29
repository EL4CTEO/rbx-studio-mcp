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
  counts?: number[];
  matchedFiles?: number;
  items: Array<{
    revision?: string;
    className?: string;
    matches?: number;
    needles?: number[];
    truncated?: boolean;
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
      description: "Read live editor buffers with numbered lines and whole-file rev values. Batch paths, or {path,startLine,endLine} windows with per-entry ranges; top-level ranges are defaults. Pass rev back as revision to script_edit. Unsaved edits are included; file-synced scripts are flagged. op=open opens the first script at line only when requested. target=live reads the published place through Open Cloud: only Folder/script paths are traversable, each segment costs a request. list=true lists children instead of source.",
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
      description: "Edit existing scripts using exact find/replace, inclusive line ranges, or complete source; choose one form per entry. Edits to one script are sequential. Batch up to 50 edits. Pass revision from script_read or script_grep; mismatches refuse the batch before writing. Current source is checked again in the editor callback. Writes share a mutation lock; each document has its own editor undo. Failed writes attempt conditional compensation; PARTIAL_EDIT names unresolved scripts and preserves newer text. Read those before retrying. Result rev values support chained edits. target=live rewrites published source, requires path/source/confirm=true, and has no undo.",
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
            "Edits to apply together, with per-script editor undo. Required unless target is \"live\". " +
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
      description: "Search live editor buffers within a subtree or a single script. Supply pattern (Lua pattern; % escapes, no alternation) or patterns (1-16 literal needles in one scan). literal=true is recommended for identifiers. mode=lines groups matches by script with revisions and merged context; files returns one row per matching script; counts returns matching-line counts per needle. A line matching several needles is returned once with 1-based needle indexes. Results use deterministic path/line order and cursors based on visible matches. Pass revision to script_edit.",
      inputSchema: {
        pattern: z
          .string()
          .min(1)
          .optional()
          .describe('Lua pattern, or exact text when `literal` is set, e.g. "PlayerAdded".'),
        patterns: z.array(z.string().min(1)).min(1).max(16).optional().describe("Batch literal needles in one scan; use instead of pattern. Hit indexes are 1-based."),
        mode: z.enum(["lines", "files", "counts"]).default("lines").describe("Matching lines with revisions, one row per file, or per-needle matching-line counts."),
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
      if (Boolean(args.pattern) === Boolean(args.patterns)) throw new ToolError("BAD_PARAMS", "Supply pattern or patterns, not both.");
      const response = await bridge.call<GrepResponse>(
        "script.grep",
        {
          pattern: args.pattern,
          patterns: args.patterns,
          mode: args.mode,
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

      if (args.mode === "counts") return json({ searched: response.searched, matchedFiles: response.matchedFiles,
        counts: (args.patterns ?? [args.pattern!]).map((pattern, index) => ({ pattern, lines: response.counts?.[index] ?? 0 })) });
      if (args.mode === "files") return table(["path", "className", "revision", "matches"], response.items as unknown as Array<Record<string, unknown>>,
        {offset, total: response.total, more: `searched ${response.searched} scripts`});
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
        const alternation = !args.literal && !args.patterns && args.pattern?.includes("|");
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

      const render = (matches: GrepResponse["items"]): string => {
        const groups = new Map<string, { header: string; lines: Map<number, string>; hits: Set<number> }>();
        for (const match of matches) {
          let group = groups.get(match.path);
          if (!group) {
            group = { header: match.path + (match.revision ? " rev=" + match.revision : ""), lines: new Map(), hits: new Set() };
            groups.set(match.path, group);
          }
          for (const [i, line] of (match.before ?? []).entries()) {
            const number = match.line - (match.before?.length ?? 0) + i;
            if (!group.hits.has(number)) group.lines.set(number, line);
          }
          group.hits.add(match.line);
          group.lines.set(match.line, match.text + (match.truncated ? " [line truncated; use script_read]" : "") + (match.needles ? " [patterns " + match.needles.join(",") + "]" : ""));
          for (const [i, line] of (match.after ?? []).entries()) {
            const number = match.line + i + 1;
            if (!group.hits.has(number)) group.lines.set(number, line);
          }
        }
        return [...groups.values()].map(group => group.header + "\n" +
          [...group.lines].sort(([a], [b]) => a - b).map(([number, line]) => number + (group.hits.has(number) ? ": " : "- ") + line).join("\n")).join("\n\n");
      };
      let shown = response.items.length;
      let listing = render(response.items);
      if (listing.length > CHARACTER_LIMIT - 500) {
        let lo = 0, hi = shown;
        while (lo < hi) {
          const mid = Math.ceil((lo + hi) / 2);
          if (render(response.items.slice(0, mid)).length <= CHARACTER_LIMIT - 500) lo = mid;
          else hi = mid - 1;
        }
        shown = Math.max(1, lo);
        listing = render(response.items.slice(0, shown));
        if (lo === 0) listing = listing.slice(0, CHARACTER_LIMIT - 600) + " [match truncated; use script_read for a window]";
      }
      const nextOffset = offset + shown;
      const trailer = "[searched " + response.searched + " scripts; showing " + shown + " of " + response.total + " matches" +
        (nextOffset < response.total ? '; cursor: "' + encodeCursor(nextOffset) + '"' : "") + "]";
      return text(listing + "\n\n" + trailer);
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
