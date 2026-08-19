import { z } from "zod";
import {
  body,
  cursorSchema,
  decodeCursor,
  encodeCursor,
  limitSchema,
  table,
  text,
  type ToolResult,
} from "../lib/format.js";
import { defineTool, type ToolContext } from "../lib/tool.js";

interface ReadResponse {
  items: Array<{
    path: string;
    className: string;
    lineCount: number;
    startLine: number;
    source: string;
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
  }>;
  undoStep: string;
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
  undoStep: string;
}

/**
 * Prefixes each line with its number, right-aligned to the widest one.
 *
 * The numbers are not decoration: `script_edit` addresses lines by these exact
 * values, so an agent that reads a window can write back to it without counting
 * newlines itself.
 */
function numbered(source: string, startLine: number): string {
  const lines = source.length === 0 ? [] : source.split("\n");
  const width = String(startLine + lines.length - 1).length;
  return lines
    .map((line, index) => `${String(startLine + index).padStart(width)}│ ${line}`)
    .join("\n");
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
        "Pass every script you need in one call. `startLine`/`endLine` apply to all " +
        "of them, so use them when following one range across several files and " +
        "read whole files otherwise.",
      inputSchema: {
        paths: z
          .array(z.string())
          .min(1)
          .max(20)
          .describe('Script paths, e.g. ["ServerScriptService.Systems.Combat"].'),
        startLine: z
          .number()
          .int()
          .min(1)
          .optional()
          .describe("First line to return, 1-based and inclusive. Omit to start at the top."),
        endLine: z
          .number()
          .int()
          .min(1)
          .optional()
          .describe("Last line to return, inclusive. Omit to read to the end."),
        studioId: z.string().optional().describe("Target Studio; omit for the active one."),
      },
      readOnly: true,
    },
    async (args): Promise<ToolResult> => {
      const response = await bridge.call<ReadResponse>(
        "script.read",
        { paths: args.paths, startLine: args.startLine, endLine: args.endLine },
        { studioId: args.studioId },
      );

      const blocks = response.items.map((item) => {
        const shown = item.source.length === 0 ? 0 : item.source.split("\n").length;
        const range =
          shown === item.lineCount
            ? `${item.lineCount} lines`
            : `lines ${item.startLine}-${item.startLine + shown - 1} of ${item.lineCount}`;
        return `${item.path}  (${item.className}, ${range})\n${numbered(item.source, item.startLine)}`;
      });

      if (response.failures.length > 0) {
        blocks.push(
          `Could not read ${response.failures.length} path(s):\n` +
            response.failures.map((failure) => `  - ${failure}`).join("\n"),
        );
      }
      if (blocks.length === 0) return text("No scripts read.");

      return body(
        blocks.join("\n\n"),
        "read fewer scripts per call, or narrow with startLine/endLine",
      );
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
        "Every edit in one call is applied as a single transaction: they land as " +
        "one Ctrl+Z for the user, and if any edit fails the whole batch is rolled " +
        "back rather than left half applied. So batch related changes together, " +
        "even across different scripts.\n\n" +
        "Each edit picks exactly one mode:\n" +
        "  find/replace — literal text, not a pattern. Preferred: it survives line " +
        "numbers shifting. Fails if the text is not unique, unless you set " +
        "`replaceAll`, so include enough surrounding lines to pin it down.\n" +
        "  startLine/endLine + replacement — for line ranges from `script_read`. " +
        "Numbers refer to the file as you read it; several line edits to one script " +
        "are applied bottom-up so they do not shift each other.\n" +
        "  source — replaces the whole script. Only for small files or a rewrite; " +
        "it discards anything the user changed since you read it.\n\n" +
        "Writes go through `ScriptEditorService:UpdateSourceAsync`, so an open " +
        "editor tab updates in place and unsaved work is preserved.",
      inputSchema: {
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
            }),
          )
          .min(1)
          .max(50)
          .describe("Edits to apply together as one undoable step."),
        studioId: z.string().optional().describe("Target Studio; omit for the active one."),
      },
      destructive: true,
    },
    async (args): Promise<ToolResult> => {
      const response = await bridge.call<EditResponse>(
        "script.edit",
        { edits: args.edits },
        { studioId: args.studioId, timeoutMs: 30_000 },
      );

      return table(
        ["path", "className", "edits", "lineCount", "lineDelta"],
        response.items as unknown as Array<Record<string, unknown>>,
        { more: `applied as one undo step, "${response.undoStep}"` },
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
        return text(
          `No matches in ${response.searched} script(s).\n` +
            "Check case, and remember patterns are Lua patterns — set `literal` to " +
            "search for the text exactly as written.",
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
        "Batch related scripts into one call: they are created as a single undo " +
        "step, so the user can drop a whole generated system with one Ctrl+Z.\n\n" +
        "Prefer `Script` with `runContext: \"Client\"` over `LocalScript` in new " +
        "work — a Script with an explicit RunContext runs wherever you parent it, " +
        "while LocalScript only runs under a player's character, backpack or " +
        "PlayerGui. Use `script_edit` to change a script that already exists.",
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
        { studioId: args.studioId },
      );

      return table(
        ["path", "className"],
        response.items as unknown as Array<Record<string, unknown>>,
        { more: `created as one undo step, "${response.undoStep}"` },
      );
    },
  );
}
