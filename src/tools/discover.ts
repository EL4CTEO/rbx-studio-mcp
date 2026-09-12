import { z } from "zod";
import { propertiesOf, restrictionsOf, standardProperties } from "../lib/apidump.js";
import { cursorSchema, decodeCursor, detailSchema, encodeCursor, json, limitSchema, table, text, textOf, type Detail, type ToolResult } from "../lib/format.js";
import { defineTool, type ToolContext } from "../lib/tool.js";

/** Shape the plugin returns for tree/find. */
interface TagsResponse {
  tags: Array<{ tag: string; count: number; sample: string[] }>;
  count: number;
  scope?: string;
  studioTagsHidden: number;
}

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

/** Per class, at most this many restricted names before the note summarises. */
const RESTRICTED_SHOWN = 10;

/**
 * What `detail: "full"` could not read, named rather than omitted.
 *
 * "Every readable property" quietly means "every property this identity is
 * allowed to see", and the gap is invisible: Lighting.Technology is absent from
 * a full inspect exactly the way a nonexistent property would be. Saying which
 * ones exist but are out of reach is the difference between an agent trying a
 * different spelling and an agent telling the user to change it in Studio.
 */
async function restrictedNote(classNames: Set<string>): Promise<string | undefined> {
  const lines: string[] = [];

  for (const className of classNames) {
    // Only the ones the read actually missed. A property readable by a plugin
    // but not writable by one is already in the output above.
    const hidden = [...(await restrictionsOf(className)).values()].filter(
      (restriction) => restriction.blocked !== "write",
    );
    if (hidden.length === 0) continue;

    const shown = hidden.slice(0, RESTRICTED_SHOWN).map((restriction) => {
      const why = restriction.notScriptable ? "NotScriptable" : restriction.capability;
      // Unreadable here but still writable is rare enough to be worth saying,
      // because the rest of this note tells the agent not to bother trying.
      return `${restriction.name} (${why}${restriction.writable ? ", writable" : ""})`;
    });
    const rest = hidden.length - shown.length;
    lines.push(`  ${className}: ${shown.join(", ")}${rest > 0 ? `, and ${rest} more` : ""}`);
  }

  if (lines.length === 0) return undefined;
  return (
    "Present but not readable at plugin identity, so absent above rather than " +
    "unset. Unless marked writable they cannot be set from here either — change " +
    "those in Studio's Properties panel:\n" +
    lines.join("\n")
  );
}

/**
 * Sorts property and attribute keys alphabetically.
 *
 * Luau table iteration order is unspecified, so the same instance inspected
 * twice comes back with its keys shuffled. That defeats prompt caching, makes
 * two inspects impossible to diff, and reads as though something changed when
 * nothing did.
 */
function withSortedProperties(
  item: InspectResponse["items"][number],
): InspectResponse["items"][number] {
  const sortKeys = (record: Record<string, unknown> | undefined) =>
    record
      ? Object.fromEntries(Object.entries(record).sort(([a], [b]) => a.localeCompare(b)))
      : undefined;

  // `requested` exists so callers can correlate an answer with the path they
  // asked about; it is redundant next to the canonical path and only costs
  // tokens here.
  const { requested: _requested, ...rest } = item as typeof item & { requested?: string };

  return {
    ...rest,
    properties: sortKeys(item.properties) ?? {},
    ...(item.attributes ? { attributes: sortKeys(item.attributes) as Record<string, unknown> } : {}),
  };
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
        physics: z
          .boolean()
          .default(false)
          .describe(
            "Also report mass, density, assembly root and centre of mass for any " +
              "BasePart. Mass appears nowhere in Studio — it is computed from " +
              "volume and material — so this is the only way to answer 'why does " +
              "this fall over', 'why does it sink', or 'why did half the model " +
              "stay behind when I moved it'.",
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
      // Classes seen by the probe, so `full` can say which properties it left
      // out. Empty for `concise` and for an explicit property list, neither of
      // which claims to be showing everything.
      const probedClasses = new Set<string>();

      if (!requested && args.detail !== "concise") {
        const probe = await bridge.call<InspectResponse>(
          "discover.inspect",
          // probeOnly is inert on the plugin side; it only tells the console
          // this is the class-probe half of one `inspect` call, not a second
          // read. Without it two calls this close together, identically
          // labelled "Inspect X", read as a duplicate rather than as the
          // two-pass shape this genuinely is.
          { paths: args.paths, includeChildren: false, probeOnly: true },
          { studioId: args.studioId },
        );
        const names = new Set<string>();
        for (const item of probe.items) {
          if (args.detail === "full") probedClasses.add(item.className);
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
          physics: args.physics,
        },
        { studioId: args.studioId },
      );

      const notes: string[] = [];
      if (response.failures.length > 0) {
        notes.push(
          `Could not resolve ${response.failures.length} path(s):\n` +
            response.failures.map((failure) => `  - ${failure}`).join("\n"),
        );
      }
      const restricted = await restrictedNote(probedClasses);
      if (restricted) notes.push(restricted);

      return json(
        response.items.map(withSortedProperties),
        notes.length > 0 ? notes.join("\n\n") : undefined,
      );
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
        "if a search reports TOO_BROAD.\n\n" +
        "`op=\"tags\"` lists which tags the place actually USES, with counts and a " +
        "few example paths. Call it before filtering by tag on a place you do not " +
        "know: a tag search that returns nothing looks the same whether you spelled " +
        "it wrong or nothing carries it, and the tag names are often the clearest " +
        "description of how a game is organised (Enemy, Checkpoint, Interactable " +
        "say more than the folder layout does).\n\n" +
        "`selector` is the engine's own query language and is the fastest option " +
        "of all — the matching happens in C++ and only survivors come back. Reach " +
        "for it when the shape of the tree is part of the question (`Model > Part`) " +
        "or when one call should answer two (`Part, Model`); the filters above " +
        "still apply on top of it.",
      inputSchema: {
        op: z
          .enum(["find", "tags"])
          .default("find")
          .describe(
            "'find' searches for instances. 'tags' lists which CollectionService " +
              "tags exist in the place, with counts — use it when you do not know " +
              "the tag names yet.",
          ),
        path: z
          .string()
          .optional()
          .describe('Limit the search to this subtree, e.g. "Workspace.Map". Omit for everything.'),
        nameContains: z.string().optional().describe("Substring of the instance name, case-insensitive."),
        className: z.string().optional().describe('Class or superclass, e.g. "BasePart", "Script".'),
        tag: z.string().optional().describe("CollectionService tag the instance must carry."),
        selector: z
          .string()
          .optional()
          .describe(
            "Engine query selector, matched inside Studio. Supports a class name " +
              '("Part", superclasses included), "#ExactName", "[Anchored=true]", ' +
              'either-or with "Part, Model", direct children with "Model > Part" ' +
              'and descendants with "Model >> Part". No substring names and no ' +
              "< > comparisons — use nameContains and propertyValue for those. " +
              "Combines with the other filters.",
          ),
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
      if (args.op === "tags") {
        const found = await bridge.call<TagsResponse>(
          "discover.tags",
          { path: args.path },
          { studioId: args.studioId, timeoutMs: 30_000 },
        );
        if (found.tags.length === 0) {
          return text(
            (found.scope !== undefined
              ? `Nothing under ${found.scope} carries a tag.`
              : "This place uses no tags.") +
              (found.studioTagsHidden > 0
                ? ` (${found.studioTagsHidden} of Studio's own internal tags were hidden.)`
                : ""),
          );
        }
        /*
         * Tags carrying nothing are listed as a sentence, not as table rows.
         * They have no count worth reading and no examples to show, so each one
         * is a blank line in the middle of the real answer — measured on a place
         * using two tags, where five empty rows from Studio's own plugins
         * (RigEdit, the tag editor, gui-object-defaults) buried both of them.
         * Naming them still matters, because one of them may be the tag the
         * caller was about to search for.
         */
        const used = found.tags.filter((entry) => entry.count > 0);
        const empty = found.tags.filter((entry) => entry.count === 0).map((entry) => entry.tag);
        const emptyNote =
          empty.length > 0
            ? `\n\nRegistered but carrying nothing: ${empty.join(", ")}. These are ` +
              "usually left by Studio plugins or by something since deleted."
            : "";

        if (used.length === 0) {
          return text(
            (found.scope !== undefined
              ? `Nothing under ${found.scope} carries a tag.`
              : "Nothing in this place carries a tag.") + emptyNote,
          );
        }

        const rows = used.map((entry) => ({
          tag: entry.tag,
          count: entry.count,
          examples: entry.sample.join(", ") || "—",
        }));
        return text(
          textOf(
            table(["tag", "count", "examples"], rows as unknown as Array<Record<string, unknown>>, {
              more:
                (found.scope !== undefined ? `within ${found.scope}; ` : "") +
                `${found.studioTagsHidden} of Studio's own tags hidden`,
            }),
          ) + emptyNote,
        );
      }

      if (!args.nameContains && !args.className && !args.tag && !args.propertyName && !args.selector) {
        return text(
          "find needs at least one filter (nameContains, className, tag, propertyName or selector).\n" +
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
          selector: args.selector,
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
            (args.propertyName !== undefined
              ? "`propertyValue` is compared as text: a Vector3 reads \"0, 5, 0\", an " +
                "enum matches either \"Neon\" or \"Enum.Material.Neon\", and a property " +
                "that is simply absent on a class never matches. "
              : "") +
            "Try a shorter `nameContains`, or drop a filter to widen the search.",
        );
      }
      return pageOf(response, args.detail, `searched ${response.searched ?? 0} instances`);
    },
  );
}
