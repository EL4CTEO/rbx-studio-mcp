import { z } from "zod";
import { json, table, text, textOf, type ToolResult } from "../lib/format.js";
import { defineTool, type ToolContext } from "../lib/tool.js";

interface GeometryResponse {
  created: string[];
  removed?: string[];
  pieces?: number;
  undoable: boolean;
}

interface InsertResponse {
  inserted: string[];
  assetId: number;
  scriptCount: number;
  scripts?: string[];
  undoable: boolean;
}

interface HistoryResponse {
  action?: string;
  applied?: number;
  requested?: number;
  canUndo: boolean;
  canRedo: boolean;
  note?: string;
}

interface CollisionResponse {
  groups?: Array<{ name: string; mask: number }>;
  group?: string;
  assigned?: number;
  parts?: string[];
  with?: string;
  collidable?: boolean;
  created?: boolean;
  existed?: boolean;
  undoable?: boolean;
}

/** Roblox's toolbox search. Public, unauthenticated, and the same index Studio's own asset browser uses. */
const TOOLBOX_SEARCH = "https://apis.roblox.com/toolbox-service/v1/marketplace";
const TOOLBOX_DETAILS = "https://apis.roblox.com/toolbox-service/v1/items/details";

/** Toolbox category ids. Models is the only one that inserts as instances. */
const CATEGORIES: Record<string, number> = { model: 10, decal: 13, mesh: 40, audio: 3 };

interface ToolboxDetail {
  asset?: {
    id?: number;
    name?: string;
    description?: string;
    hasScripts?: boolean;
    modelTechnicalDetails?: { objectMeshSummary?: { triangles?: number } };
  };
  creator?: { name?: string; isVerifiedCreator?: boolean };
  voting?: { upVotePercent?: number; voteCount?: number };
}

/**
 * Searches the Creator Store from the server rather than the plugin.
 *
 * Node already has internet access and these endpoints answer unauthenticated,
 * while a plugin making outbound HTTP needs the user to approve each domain in
 * Plugin Management. Searching here means it works the moment the server starts.
 */
async function searchCreatorStore(
  keyword: string,
  category: string,
  limit: number,
): Promise<ToolboxDetail[]> {
  const categoryId = CATEGORIES[category] ?? 10;
  const url =
    `${TOOLBOX_SEARCH}/${categoryId}?keyword=${encodeURIComponent(keyword)}` +
    `&limit=${Math.min(limit, 30)}&sortType=Relevance`;

  const found = await fetch(url, { signal: AbortSignal.timeout(15_000) });
  if (!found.ok) {
    throw new Error(`Creator Store search failed (${found.status}). Roblox may be rate-limiting.`);
  }
  const results = (await found.json()) as { data?: Array<{ id: number }> };
  const ids = (results.data ?? []).map((entry) => entry.id).slice(0, limit);
  if (ids.length === 0) return [];

  // Search returns bare ids; everything worth showing — name, creator, whether
  // it carries scripts — needs the second call.
  const detailed = await fetch(`${TOOLBOX_DETAILS}?assetIds=${ids.join(",")}`, {
    signal: AbortSignal.timeout(15_000),
  });
  if (!detailed.ok) {
    throw new Error(`Could not read asset details (${detailed.status}).`);
  }
  const payload = (await detailed.json()) as { data?: ToolboxDetail[] };
  return payload.data ?? [];
}

export function registerWorldTools(context: ToolContext): void {
  const { bridge } = context;

  defineTool(
    context,
    {
      name: "geometry",
      title: "Solid modelling",
      description:
        "Cuts, joins and shatters parts with real constructive solid geometry.\n\n" +
        "This is how to build a shape that is not a box without importing a " +
        "mesh: `subtract` a door out of a wall, `union` several parts into one " +
        "solid, `intersect` to keep only the overlap, `fragment` to shatter " +
        "something into debris.\n\n" +
        "`subtract` and `intersect` need the parts to actually overlap, and they " +
        "fail differently when they do not. `intersect` returns nothing, which " +
        "comes back as an error rather than a silent no-op. `subtract` returns " +
        "the subject UNCHANGED — a full-size copy of it, reported as a created " +
        "part — because cutting nothing out of something legitimately leaves it " +
        "whole. So a subtract that succeeds is not proof that anything was cut: " +
        "check the positions overlap with `inspect` first, or compare the " +
        "result's size against the original.\n\n" +
        "Results keep the original's material, colour and anchoring. Roblox " +
        "returns bare grey MeshParts, so a brick wall with a hole cut in it " +
        "would otherwise come back as a grey slab — correct geometry that looks " +
        "like a mistake.\n\n" +
        "The originals are consumed unless `keepOriginals` is set. The whole " +
        "operation is one undo step.",
      inputSchema: {
        op: z
          .enum(["union", "subtract", "intersect", "fragment"])
          .describe(
            "'union' merges, 'subtract' cuts `with` out of `path`, 'intersect' " +
              "keeps only the overlap, 'fragment' shatters `path` into pieces.",
          ),
        path: z.string().describe("The part being operated on — the one cut from, for subtract."),
        with: z
          .array(z.string())
          .max(50)
          .optional()
          .describe("The other parts. Required for union, subtract and intersect."),
        pieces: z
          .number()
          .int()
          .min(2)
          .max(100)
          .default(8)
          .describe("fragment only: roughly how many pieces to break into."),
        name: z.string().optional().describe("Name for the result. Defaults to the original's."),
        parent: z.string().optional().describe("Where to put the result. Defaults to the original's parent."),
        keepOriginals: z
          .boolean()
          .default(false)
          .describe("Leave the input parts in place instead of consuming them."),
        collisionFidelity: z
          .enum(["Default", "Hull", "Box", "PreciseConvexDecomposition"])
          .default("Default")
          .describe(
            "How exactly the result collides. Precise is expensive — raise it " +
              "only for a surface players walk on.",
          ),
        splitApart: z
          .boolean()
          .default(false)
          .describe("Return disconnected chunks as separate parts rather than one."),
        studioId: z.string().optional().describe("Target Studio; omit for the active one."),
      },
      destructive: true,
    },
    async (args): Promise<ToolResult> => {
      const isFragment = args.op === "fragment";
      const response = await bridge.call<GeometryResponse>(
        isFragment ? "geometry.fragment" : "geometry.combine",
        {
          op: args.op,
          path: args.path,
          with: args.with,
          pieces: args.pieces,
          name: args.name,
          parent: args.parent,
          keepOriginals: args.keepOriginals,
          collisionFidelity: args.collisionFidelity,
          splitApart: args.splitApart,
        },
        // Solid modelling on a complex mesh is genuinely slow.
        { studioId: args.studioId, timeoutMs: 120_000 },
      );

      const notes: string[] = [];
      if (response.removed && response.removed.length > 0) {
        notes.push(`Consumed: ${response.removed.join(", ")}.`);
      }
      if (!response.undoable) {
        notes.push("Studio would not open an undo recording, so this is not one Ctrl+Z.");
      }
      return json(response.created, notes.length > 0 ? notes.join(" ") : undefined);
    },
  );

  defineTool(
    context,
    {
      name: "assets",
      title: "Creator Store",
      description:
        "Searches Roblox's Creator Store and inserts models into the place.\n\n" +
        "`search` looks through the same public index Studio's own asset browser " +
        "uses and returns ids with names, creators, vote ratios and — the part " +
        "that matters — whether the model contains scripts. `insert` puts one " +
        "into the place by id.\n\n" +
        "ALWAYS check `hasScripts` before inserting. Free models carrying " +
        "scripts are the oldest hazard on the platform, and a model dropped into " +
        "someone's game can run whatever it likes. The insert reports the script " +
        "count again, and names them, so it can still be undone.\n\n" +
        "Only public assets can be inserted. A private or deleted id fails with " +
        "a message saying so rather than inserting nothing quietly.",
      inputSchema: {
        op: z.enum(["search", "insert"]).describe("'search' finds assets, 'insert' adds one to the place."),
        keyword: z.string().optional().describe("search only: what to look for, e.g. \"medieval door\"."),
        category: z
          .enum(["model", "decal", "mesh", "audio"])
          .default("model")
          .describe("search only: what kind of asset. Only models insert as instances."),
        limit: z.number().int().min(1).max(20).default(8).describe("search only: how many results."),
        assetId: z.number().int().positive().optional().describe("insert only: the asset id to insert."),
        parent: z.string().optional().describe("insert only: where to put it. Defaults to Workspace."),
        position: z
          .string()
          .optional()
          .describe('insert only: where to place it, e.g. "0, 10, 0". Defaults to wherever it was saved.'),
        name: z.string().optional().describe("insert only: rename it on the way in."),
        studioId: z.string().optional().describe("Target Studio; omit for the active one."),
      },
      destructive: false,
    },
    async (args): Promise<ToolResult> => {
      if (args.op === "search") {
        if (!args.keyword) return text("search needs a `keyword`.");
        const found = await searchCreatorStore(args.keyword, args.category, args.limit);
        if (found.length === 0) {
          return text(`Nothing matched "${args.keyword}" in ${args.category}s.`);
        }
        const rows = found.map((entry) => ({
          assetId: entry.asset?.id ?? 0,
          name: entry.asset?.name ?? "?",
          creator: entry.creator?.name ?? "?",
          approval: entry.voting?.upVotePercent ? `${entry.voting.upVotePercent}%` : "—",
          hasScripts: entry.asset?.hasScripts ? "YES" : "no",
          triangles: entry.asset?.modelTechnicalDetails?.objectMeshSummary?.triangles ?? "—",
        }));
        const risky = rows.filter((row) => row.hasScripts === "YES");
        return text(
          textOf(table(["assetId", "name", "creator", "approval", "hasScripts", "triangles"], rows)) +
            (risky.length > 0
              ? `\n\n${risky.length} of these contain scripts (${risky
                  .map((r) => r.name)
                  .join(", ")}). Inserting one runs whatever its author put in it — prefer a script-free model unless the scripts are the point.`
              : "\n\nNone of these contain scripts."),
        );
      }

      if (!args.assetId) return text("insert needs an `assetId`. Use `op: \"search\"` to find one.");
      const response = await bridge.call<InsertResponse>(
        "assets.insert",
        {
          assetId: args.assetId,
          parent: args.parent,
          position: args.position,
          name: args.name,
        },
        // Downloading an asset goes out to Roblox and back.
        { studioId: args.studioId, timeoutMs: 90_000 },
      );

      const notes: string[] = [];
      if (response.scriptCount > 0) {
        notes.push(
          `WARNING: this asset contains ${response.scriptCount} script(s): ` +
            `${(response.scripts ?? []).join(", ")}. They will run on the next playtest. ` +
            "Read them before playing, or delete them.",
        );
      }
      if (!response.undoable) notes.push("Not undoable as one step.");
      return json(response.inserted, notes.length > 0 ? notes.join("\n\n") : undefined);
    },
  );

  defineTool(
    context,
    {
      name: "undo",
      title: "Undo and redo",
      description:
        "Steps Studio's undo history backwards or forwards.\n\n" +
        "Every write this server makes is already wrapped in an undo recording, " +
        "so this reverses your own work as cleanly as the user pressing Ctrl+Z " +
        "— one tool call is one step. Use it when the user says an edit was " +
        "wrong, instead of trying to reconstruct the previous state by hand, " +
        "which is guesswork and usually incomplete.\n\n" +
        "It reports how many steps actually applied, which is not always what " +
        "was asked: the stack runs out, and an undo that did nothing otherwise " +
        "looks exactly like one that worked.\n\n" +
        "Studio's history covers the whole session, including the user's own " +
        "edits — undoing more steps than you made will start reverting THEIR " +
        "work. Undo only what you just did, and only when asked.",
      inputSchema: {
        action: z
          .enum(["undo", "redo", "status"])
          .default("status")
          .describe("'status' reports what is available without changing anything."),
        steps: z
          .number()
          .int()
          .min(1)
          .max(25)
          .default(1)
          .describe("How many steps to take. Keep it to what you did yourself."),
        studioId: z.string().optional().describe("Target Studio; omit for the active one."),
      },
      destructive: true,
    },
    async (args): Promise<ToolResult> => {
      const response = await bridge.call<HistoryResponse>(
        "world.history",
        { action: args.action, steps: args.steps },
        { studioId: args.studioId },
      );
      return json(response, response.note);
    },
  );

  defineTool(
    context,
    {
      name: "collision",
      title: "Collision groups",
      description:
        "Controls which parts physically collide with which.\n\n" +
        "This is the right answer to 'these should pass through each other'. " +
        "The alternative — turning CanCollide off — disables collision against " +
        "everything, so a ghost that should pass through walls also falls " +
        "through the floor.\n\n" +
        "The order is: `create` a group, `assign` parts to it, then set what it " +
        "is `collidable` with. A group with nothing assigned does nothing.\n\n" +
        "Assigning a Model assigns every part inside it, which is almost always " +
        "what is meant.",
      inputSchema: {
        action: z
          .enum(["list", "create", "assign", "collidable"])
          .default("list")
          .describe("'list' shows existing groups and changes nothing."),
        group: z.string().optional().describe("The group's name. Required for everything but list."),
        paths: z
          .array(z.string())
          .max(100)
          .optional()
          .describe("assign only: parts or models to put in the group."),
        with: z.string().optional().describe("collidable only: the other group."),
        collidable: z
          .boolean()
          .default(true)
          .describe("collidable only: whether the two groups collide. False makes them pass through."),
        studioId: z.string().optional().describe("Target Studio; omit for the active one."),
      },
      destructive: false,
    },
    async (args): Promise<ToolResult> => {
      const response = await bridge.call<CollisionResponse>(
        "world.collision",
        {
          action: args.action,
          group: args.group,
          paths: args.paths,
          with: args.with,
          collidable: args.collidable,
        },
        { studioId: args.studioId },
      );
      if (args.action === "list") {
        const groups = response.groups ?? [];
        if (groups.length === 0) return text("No collision groups are registered.");
        return text(textOf(table(["name", "mask"], groups as unknown as Array<Record<string, unknown>>)));
      }
      return json(response);
    },
  );
}
