import { z } from "zod";
import { propertiesOf, standardProperties } from "../lib/apidump.js";
import {
  cursorSchema,
  detailSchema,
  json,
  limitSchema,
  table,
  text,
  type Detail,
  type ToolResult,
} from "../lib/format.js";
import { defineTool, type ToolContext } from "../lib/tool.js";

/** Shape the plugin returns for tree/find. */
interface ListResponse {
  items: Array<{ path: string; className: string; childCount: number }>;
  total: number;
  offset: number;
  root?: string;
  searched?: number;
  hiddenServices?: number;
}

interface InspectResponse {
  items: Array<{
    path: string;
    className: string;
    properties: Record<string, unknown>;
    attributes: Record<string, unknown>;
    tags: string[];
    childCount: number;
    children?: Array<{ name: string; className: string }>;
  }>;
  failures: string[];
}

/** Cursors are just offsets, encoded so callers treat them as opaque. */
const encodeCursor = (offset: number): string => Buffer.from(String(offset)).toString("base64url");

function decodeCursor(cursor: string | undefined): number {
  if (!cursor) return 0;
  const parsed = Number.parseInt(Buffer.from(cursor, "base64url").toString("utf8"), 10);
  return Number.isInteger(parsed) && parsed >= 0 ? parsed : 0;
}

/**
 * Renders a hierarchy page as a table. `concise` drops the child count, which
 * is the only column a pure scan does not need.
 */
function pageOf(response: ListResponse, detail: Detail, more?: string): ToolResult {
  const columns = detail === "concise" ? ["path", "className"] : ["path", "className", "childCount"];
  const nextOffset = response.offset + response.items.length;
  return table(columns, response.items as unknown as Array<Record<string, unknown>>, {
    total: response.total,
    ...(nextOffset < response.total ? { nextCursor: encodeCursor(nextOffset) } : {}),
    ...(more ? { more } : {}),
  });
}

export function registerDiscoverTools(context: ToolContext): void {
  const { bridge } = context;

  defineTool(
    context,
    {
      name: "tree",
      title: "Browse hierarchy",
      description:
        "Lists the instance hierarchy under a path, breadth-first to a given depth. " +
        "Returns a flat array of paths — flat is both cheaper and easier to act on " +
        "than nested JSON, since every entry is directly usable as a path.\n\n" +
        "Use this to orient yourself in an unfamiliar place. Use `find` instead " +
        "when you already know what you are looking for; a deep `tree` over a " +
        "whole place wastes context on instances you will never touch.\n\n" +
        "With `path` omitted it lists only the containers a place is authored in " +
        "— Workspace, ReplicatedStorage, ServerScriptService and friends. Roblox " +
        "exposes ~120 services at the root, almost all engine internals; those are " +
        "hidden and the response says how many. Pass an explicit `path` to look " +
        "inside one of them anyway.",
      inputSchema: {
        path: z
          .string()
          .optional()
          .describe(
            'Dot-notation root, e.g. "Workspace.Map". Omit to list services from the root.',
          ),
        depth: z
          .number()
          .int()
          .min(1)
          .max(10)
          .default(2)
          .describe("Levels below `path` to walk. Keep low; each level multiplies the result."),
        className: z
          .string()
          .optional()
          .describe('Only include instances of this class or a subclass, e.g. "BasePart".'),
        nameContains: z
          .string()
          .optional()
          .describe("Only include instances whose name contains this text (case-insensitive)."),
        detail: detailSchema,
        limit: limitSchema,
        cursor: cursorSchema,
        studioId: z.string().optional().describe("Target Studio; omit for the active one."),
      },
      readOnly: true,
    },
    async (args): Promise<ToolResult> => {
      const response = await bridge.call<ListResponse>(
        "discover.tree",
        {
          path: args.path,
          depth: args.depth,
          className: args.className,
          nameContains: args.nameContains,
          limit: args.limit,
          offset: decodeCursor(args.cursor),
        },
        { studioId: args.studioId },
      );
      // Say what was withheld at the root, so an agent that genuinely needs an
      // engine service knows it can ask for one by path.
      const hidden = response.hiddenServices ?? 0;
      return pageOf(
        response,
        args.detail,
        hidden > 0
          ? `${hidden} engine services hidden — pass an explicit \`path\` to inspect one`
          : undefined,
      );
    },
  );

  defineTool(
    context,
    {
      name: "inspect",
      title: "Inspect instances",
      description:
        "Reads properties, attributes, tags and children of one or more instances. " +
        "Pass every path you care about in a single call — batching costs one " +
        "round trip instead of N.\n\n" +
        "Property selection comes from the live Roblox API dump for each " +
        "instance's actual class, so it stays correct across engine updates:\n" +
        "  concise  — class and child count only\n" +
        "  standard — the properties that characterise the class (Part gets Size, " +
        "Position, CFrame, Anchored, Material...)\n" +
        "  full     — every readable property; expensive, use on one or two " +
        "instances at most\n\n" +
        "Bad paths do not fail the call: they come back under `failures` while the " +
        "valid ones still return, so one typo does not cost you the whole batch.",
      inputSchema: {
        paths: z
          .array(z.string())
          .min(1)
          .max(50)
          .describe('Instance paths, e.g. ["Workspace.Baseplate", "Lighting"].'),
        detail: detailSchema,
        properties: z
          .array(z.string())
          .optional()
          .describe(
            "Read exactly these properties instead of the detail-level default. " +
              "Use when you want one specific value across many instances.",
          ),
        includeChildren: z
          .boolean()
          .default(true)
          .describe("Include a name/class listing of direct children."),
        studioId: z.string().optional().describe("Target Studio; omit for the active one."),
      },
      readOnly: true,
    },
    async (args): Promise<ToolResult> => {
      // Classes are not known until the plugin answers, so resolve the property
      // set in two passes: a cheap probe for class names, then the real read.
      let requested = args.properties;

      if (!requested && args.detail !== "concise") {
        const probe = await bridge.call<InspectResponse>(
          "discover.inspect",
          { paths: args.paths, includeChildren: false },
          { studioId: args.studioId },
        );
        const names = new Set<string>();
        for (const item of probe.items) {
          const list =
            args.detail === "full"
              ? (await propertiesOf(item.className)).map((property) => property.name)
              : await standardProperties(item.className);
          for (const name of list) names.add(name);
        }
        requested = [...names];
      }

      const response = await bridge.call<InspectResponse>(
        "discover.inspect",
        {
          paths: args.paths,
          properties: requested,
          includeChildren: args.includeChildren,
        },
        { studioId: args.studioId },
      );

      const note =
        response.failures.length > 0
          ? `Could not resolve ${response.failures.length} path(s):\n` +
            response.failures.map((failure) => `  - ${failure}`).join("\n")
          : undefined;
      return json(response.items, note);
    },
  );

  defineTool(
    context,
    {
      name: "find",
      title: "Find instances",
      description:
        "Searches the data model by name, class, property value and/or tag. Every " +
        "filter you supply must match, so one call answers questions that would " +
        'otherwise take several: "anchored BaseParts under Workspace.Map whose ' +
        'name contains door" is a single request.\n\n' +
        "This replaces separate name / class / property / tag search tools. " +
        "Prefer it over `tree` whenever you know what you are looking for.\n\n" +
        "Tag searches are answered from CollectionService's index rather than by " +
        "walking the tree, so they stay fast on large places. Narrow with `path` " +
        "if a search reports TOO_BROAD.",
      inputSchema: {
        path: z
          .string()
          .optional()
          .describe('Limit the search to this subtree, e.g. "Workspace.Map". Omit for everything.'),
        nameContains: z.string().optional().describe("Substring of the instance name, case-insensitive."),
        className: z.string().optional().describe('Class or superclass, e.g. "BasePart", "Script".'),
        tag: z.string().optional().describe("CollectionService tag the instance must carry."),
        propertyName: z
          .string()
          .optional()
          .describe('Property that must exist, e.g. "Anchored". Combine with propertyValue.'),
        propertyValue: z
          .string()
          .optional()
          .describe(
            'Required value of `propertyName`, compared as text — "true", "0, 5, 0", ' +
              '"Enum.Material.Neon". Omit to match any instance that has the property.',
          ),
        detail: detailSchema,
        limit: limitSchema,
        cursor: cursorSchema,
        studioId: z.string().optional().describe("Target Studio; omit for the active one."),
      },
      readOnly: true,
    },
    async (args): Promise<ToolResult> => {
      if (!args.nameContains && !args.className && !args.tag && !args.propertyName) {
        return text(
          "find needs at least one filter (nameContains, className, tag or propertyName).\n" +
            "To list everything under a path, use `tree` instead.",
        );
      }

      const response = await bridge.call<ListResponse>(
        "discover.find",
        {
          path: args.path,
          nameContains: args.nameContains,
          className: args.className,
          tag: args.tag,
          propertyName: args.propertyName,
          propertyValue: args.propertyValue,
          limit: args.limit,
          offset: decodeCursor(args.cursor),
        },
        { studioId: args.studioId, timeoutMs: 30_000 },
      );

      if (response.total === 0) {
        return text(
          `No matches (searched ${response.searched ?? 0} instances).\n` +
            "Check spelling and case — names and class names are case-sensitive. " +
            "Try a shorter `nameContains`, or drop a filter to widen the search.",
        );
      }
      return pageOf(response, args.detail, `searched ${response.searched ?? 0} instances`);
    },
  );
}
