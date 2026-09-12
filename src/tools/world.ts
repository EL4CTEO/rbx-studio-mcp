import { z } from "zod";
import { json, table, text, textOf, type ToolResult } from "../lib/format.js";
import { defineTool, type ToolContext } from "../lib/tool.js";

interface GeometryResponse {
  created: string[];
  removed?: string[];
  pieces?: number;
  undoable: boolean;
}

interface SweepResponse {
  created: string[];
  hits: string[];
  checked: boolean;
  frames: number;
  kept: boolean;
  undoable: boolean;
}

interface SegmentResponse {
  path: string;
  parts: string[];
  size: string;
  schema: string;
  removed?: string;
  steps?: number;
}

interface BakeResponse {
  converted: string[];
  skipped: string[];
  failed: string[];
  opaque: number;
  examined: number;
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

interface MeshResponse {
  items: Array<{
    path: string;
    name: string;
    vertices: number;
    triangles: number;
    meshSize: string;
    partSize: string;
    collisionFidelity: string;
    renderFidelity: string;
  }>;
  failures: string[];
  totalTriangles: number;
}

interface AudioResponse {
  /** Echoed back, because the default is not the engine's and the caller should see which index answered. */
  audioType: string;
  items: Array<{
    assetId: string;
    title: string;
    artist?: string;
    duration: number;
    audioType: string;
    endorsed: boolean;
  }>;
  count: number;
}

interface PeekResponse {
  assetId: number;
  roots: string[];
  descendants: number;
  classes: Array<{ className: string; count: number }>;
  scripts: string[];
  scriptCount: number;
}

interface CollisionResponse {
  groups?: Array<{ name: string; mask: number; passesThrough?: string }>;
  /** Which WorldRoot the call landed on; groups are per-world, not per-place. */
  world?: string;
  /** Ceiling on registered groups, reported by list so a loop can stop short of it. */
  max?: number;
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
/** Segmentation runs the same slow generation backend `generate` does. */
const SEGMENT_TIMEOUT_MS = 240_000;

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
    /** Exact count, where hasScripts is only yes/no. */
    scriptCount?: number;
    isEndorsed?: boolean;
    createdUtc?: string;
    updatedUtc?: string;
    /** Roblox's own categorisation, e.g. ["Door", "Furniture"]. */
    objectTypes?: string[];
    modelTechnicalDetails?: {
      objectMeshSummary?: { triangles?: number };
      instanceCounts?: Record<string, number>;
    };
  };
  creator?: { name?: string; isVerifiedCreator?: boolean };
  voting?: { upVotePercent?: number; voteCount?: number; upVotes?: number };
  /** Not every asset is free, and inserting a paid one simply fails. */
  fiatProduct?: { isFree?: boolean; purchasable?: boolean };
}

/** What the caller asked to exclude, applied here because the API ignores it. */
interface StoreFilters {
  excludeScripts?: boolean;
  maxTriangles?: number;
  verifiedOnly?: boolean;
  freeOnly?: boolean;
  minVotes?: number;
}

/**
 * Searches the Creator Store from the server rather than the plugin.
 *
 * Node already has internet access and these endpoints answer unauthenticated,
 * while a plugin making outbound HTTP needs the user to approve each domain in
 * Plugin Management. Searching here means it works the moment the server starts.
 */
/**
 * Pages to pull before filtering gives up looking for more.
 *
 * Filtering happens here rather than at Roblox (see below), so a strict filter
 * over one page of thirty can return nothing while the good results sit on page
 * two. Four pages is enough to find script-free models for any ordinary search
 * without turning one call into a crawl of the whole index.
 */
const MAX_PAGES = 4;

/**
 * Searches the Creator Store from the server rather than the plugin.
 *
 * Node already has internet access and these endpoints answer unauthenticated,
 * while a plugin making outbound HTTP needs the user to approve each domain in
 * Plugin Management. Searching here means it works the moment the server starts.
 *
 * Filtering and ranking are done HERE, on purpose. The endpoint accepts
 * `sortType` and `creatorFilter` and ignores both — measured, Relevance,
 * MostTaken, Favorited and Updated returned byte-identical results for the same
 * keyword, as did a Roblox-only creator filter. Passing them through would have
 * looked like sorting and done nothing, which is worse than not offering it. So
 * the only server-side lever that works is the cursor, and everything else is
 * decided from the details each result carries.
 */
async function searchCreatorStore(
  keyword: string,
  category: string,
  limit: number,
  filters: StoreFilters = {},
): Promise<{ items: ToolboxDetail[]; scanned: number; total?: number }> {
  const categoryId = CATEGORIES[category] ?? 10;
  const kept: ToolboxDetail[] = [];
  let cursor = "";
  let scanned = 0;
  let total: number | undefined;

  for (let page = 0; page < MAX_PAGES && kept.length < limit; page += 1) {
    const url =
      `${TOOLBOX_SEARCH}/${categoryId}?keyword=${encodeURIComponent(keyword)}` +
      `&limit=30${cursor ? `&cursor=${encodeURIComponent(cursor)}` : ""}`;

    const found = await fetch(url, { signal: AbortSignal.timeout(15_000) });
    if (!found.ok) {
      throw new Error(`Creator Store search failed (${found.status}). Roblox may be rate-limiting.`);
    }
    const results = (await found.json()) as {
      data?: Array<{ id: number }>;
      nextPageCursor?: string | null;
      totalResults?: number;
    };
    total = total ?? results.totalResults;

    const ids = (results.data ?? []).map((entry) => entry.id);
    if (ids.length === 0) break;
    scanned += ids.length;

    // Search returns bare ids; everything worth showing — name, creator, script
    // count, price — needs the second call.
    const detailed = await fetch(`${TOOLBOX_DETAILS}?assetIds=${ids.join(",")}`, {
      signal: AbortSignal.timeout(15_000),
    });
    if (!detailed.ok) {
      throw new Error(`Could not read asset details (${detailed.status}).`);
    }
    const payload = (await detailed.json()) as { data?: ToolboxDetail[] };

    for (const entry of payload.data ?? []) {
      if (filters.excludeScripts && entry.asset?.hasScripts) continue;
      if (filters.verifiedOnly && !entry.creator?.isVerifiedCreator) continue;
      if (filters.freeOnly && entry.fiatProduct?.isFree === false) continue;
      if (filters.minVotes !== undefined && (entry.voting?.voteCount ?? 0) < filters.minVotes) {
        continue;
      }
      if (filters.maxTriangles !== undefined) {
        const triangles = entry.asset?.modelTechnicalDetails?.objectMeshSummary?.triangles;
        if (triangles !== undefined && triangles > filters.maxTriangles) continue;
      }
      kept.push(entry);
    }

    cursor = results.nextPageCursor ?? "";
    if (!cursor) break;
  }

  /*
   * Ranked by approval WEIGHTED BY how many people voted.
   *
   * The raw percentage is what the API gives and it is close to meaningless on
   * its own: 82% of 5000 votes and 100% of 2 votes sort the wrong way round
   * every time, and the second is the one nobody should be inserting into their
   * game. Pulling the percentage toward 50 in proportion to how little evidence
   * there is behind it costs nothing and puts the well-used models first.
   */
  const score = (entry: ToolboxDetail): number => {
    const percent = entry.voting?.upVotePercent ?? 50;
    const votes = entry.voting?.voteCount ?? 0;
    const confidence = votes / (votes + 50);
    return 50 + (percent - 50) * confidence;
  };
  kept.sort((a, b) => score(b) - score(a));

  return { items: kept.slice(0, limit), scanned, total };
}

export function registerWorldTools(context: ToolContext): void {
  const { bridge } = context;

  defineTool(
    context,
    {
      name: "geometry",
      title: "Mesh operations",
      description:
        "Every operation that reshapes solid geometry, in one place.\n\n" +
        "**Boolean** - `union` merges parts into one solid, `subtract` cuts the " +
        "`with` parts out of `path`, `intersect` keeps only the overlap. This is " +
        "how to build a shape that is not a box without importing a mesh.\n\n" +
        "**Breaking apart** - `fragment` shatters a part into random debris, for " +
        "destruction. `segment` is the opposite kind of break: it cuts a MeshPart " +
        "into parts you NAME, so a solid car mesh becomes a body and four wheels " +
        "a script can find and turn. Use `fragment` for rubble and `segment` for " +
        "articulation.\n\n" +
        "**Motion** - `sweep` builds the volume a part passes through as it moves, " +
        "which is the only real answer to 'does this door hit the wall when it " +
        "opens'. Give `to` for a slide, or `spin` degrees with a `pivot` for a " +
        "hinge. Pass `checkAgainst` and it reports what the swept volume overlaps; " +
        "with `keep: false` it measures and cleans up after itself, leaving " +
        "nothing behind.\n\n" +
        "`subtract` and `intersect` need the parts to actually overlap, and they " +
        "fail differently when they do not. `intersect` returns nothing, which " +
        "comes back as an error rather than a silent no-op. `subtract` returns " +
        "the subject UNCHANGED - a full-size copy of it, reported as a created " +
        "part - because cutting nothing out of something legitimately leaves it " +
        "whole. So a subtract that succeeds is not proof that anything was cut: " +
        "check the positions overlap with `inspect` first, or compare the " +
        "result's size against the original.\n\n" +
        "Results keep the original's material, colour, texture and anchoring. " +
        "Roblox returns bare grey MeshParts, so a brick wall with a hole cut in " +
        "it would otherwise come back as a grey slab - correct geometry that " +
        "looks like a mistake.\n\n" +
        "`mesh` reads the real triangle and vertex counts of MeshParts, which is " +
        "the only way to tell a 40,000-triangle tree from a 400-triangle one — " +
        "they are identical in the Explorer and in Properties, and the difference " +
        "is whether the place runs on a phone. It also reports mesh size against " +
        "part size: the same triangles stretched over a bigger object is the usual " +
        "reason a model costs more than it looks like it should.\n\n" +
        "`mesh` only works on meshes the signed-in Studio user or the experience " +
        "owner OWNS. Roblox refuses to open anyone else's, so a model inserted " +
        "from the Creator Store cannot be measured this way — the tool says which " +
        "parts were skipped rather than failing the whole batch.\n\n" +
        "`segment` runs Roblox's Cube model and takes tens of seconds; the rest " +
        "are fast. Each call is one undo step.",
      inputSchema: {
        op: z
          .enum(["union", "subtract", "intersect", "fragment", "sweep", "segment", "mesh"])
          .describe(
            "'union' merges, 'subtract' cuts `with` out of `path`, 'intersect' " +
              "keeps only the overlap, 'fragment' shatters into debris, 'sweep' " +
              "builds a motion volume, 'segment' cuts a mesh into named parts.",
          ),
        path: z.string().describe("The part being operated on - the one cut from, for subtract."),
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
        groups: z
          .array(z.string())
          .max(16)
          .optional()
          .describe(
            'segment only: the part names to cut into, e.g. ["body", "lid"]. ' +
              "Overrides `schema`.",
          ),
        schema: z
          .enum(["Body1", "Car5"])
          .optional()
          .describe(
            "segment only: a built-in split. 'Car5' gives a body and four wheels " +
              "under fixed names; 'Body1' gives one mesh. Ignored when `groups` is set.",
          ),
        keepOriginal: z
          .boolean()
          .default(false)
          .describe("segment only: leave the source MeshPart in place instead of replacing it."),
        to: z
          .string()
          .optional()
          .describe('sweep only: slide to this position, e.g. "0, 10, 0".'),
        spin: z
          .number()
          .optional()
          .describe("sweep only: rotate this many degrees. Use with `pivot` for a hinge."),
        axis: z
          .string()
          .optional()
          .describe('sweep only: axis to spin around, e.g. "0, 1, 0". Defaults to up.'),
        pivot: z
          .string()
          .optional()
          .describe(
            "sweep only: the hinge point. Defaults to the part's own centre, which " +
              "spins it in place - a door needs its hinge edge here.",
          ),
        positions: z
          .array(z.string())
          .max(64)
          .optional()
          .describe("sweep only: an explicit path of positions to sweep along."),
        steps: z
          .number()
          .int()
          .min(2)
          .max(64)
          .default(12)
          .describe("sweep only: how many samples along the motion. Too few cuts corners off an arc."),
        checkAgainst: z
          .array(z.string())
          .max(50)
          .optional()
          .describe(
            "sweep only: report what the volume overlaps. An empty array checks " +
              "against everything; a list checks only those.",
          ),
        keep: z
          .boolean()
          .default(true)
          .describe("sweep only: leave the volume as a part. Off measures and cleans up."),
        transparency: z
          .number()
          .min(0)
          .max(1)
          .default(0.5)
          .describe("sweep only: how see-through the volume is."),
        name: z.string().optional().describe("Name for the result. Defaults to the original's."),
        parent: z.string().optional().describe("Where to put the result. Defaults to the original's parent."),
        position: z
          .string()
          .optional()
          .describe("segment only: where to place the result. Defaults to where the source was."),
        scaleTo: z
          .number()
          .positive()
          .optional()
          .describe("segment only: scale so the longest side is this many studs."),
        anchor: z.boolean().default(true).describe("segment only: anchor every part."),
        keepOriginals: z
          .boolean()
          .default(false)
          .describe("Leave the input parts in place instead of consuming them."),
        collisionFidelity: z
          .enum(["Default", "Hull", "Box", "PreciseConvexDecomposition"])
          .default("Default")
          .describe(
            "How exactly the result collides. Precise is expensive - raise it " +
              "only for a surface players walk on.",
          ),
        splitApart: z
          .boolean()
          .default(false)
          .describe("Return disconnected chunks as separate parts rather than one."),
        paths: z
          .array(z.string())
          .max(50)
          .optional()
          .describe("mesh only: the MeshParts to read geometry from."),
        studioId: z.string().optional().describe("Target Studio; omit for the active one."),
      },
      destructive: true,
    },
    async (args): Promise<ToolResult> => {
      if (args.op === "mesh") {
        const paths = args.paths ?? (args.path !== undefined ? [args.path] : []);
        if (paths.length === 0) {
          return text('mesh needs `paths` — the MeshParts to read, e.g. ["Workspace.Tree"].');
        }
        const read = await bridge.call<MeshResponse>(
          "geometry.mesh",
          { paths },
          // Each part is a separate download-and-open, so a batch of twenty is
          // twenty round trips to Roblox's asset servers.
          { studioId: args.studioId, timeoutMs: 120_000 },
        );
        if (read.items.length === 0) {
          return text(
            read.failures.length > 0
              ? `Nothing readable:\n  ${read.failures.join("\n  ")}`
              : "No MeshParts in that list.",
          );
        }
        const rendered = textOf(
          table(
            ["name", "triangles", "vertices", "meshSize", "partSize", "renderFidelity", "collisionFidelity"],
            read.items as unknown as Array<Record<string, unknown>>,
            { more: `${read.totalTriangles} triangles across ${read.items.length} part(s)` },
          ),
        );
        return text(
          read.failures.length > 0
            ? `${rendered}\n\nSkipped:\n  ${read.failures.join("\n  ")}`
            : rendered,
        );
      }

      // `segment` is GenerationService, not GeometryService - the same job from
      // the caller's side, a different service underneath, and far slower.
      if (args.op === "segment") {
        const cut = await bridge.call<SegmentResponse>(
          "generate.segment",
          {
            path: args.path,
            groups: args.groups,
            schema: args.schema ?? "Body1",
            keepOriginal: args.keepOriginal,
            name: args.name,
            parent: args.parent,
            position: args.position,
            scaleTo: args.scaleTo,
            anchor: args.anchor,
          },
          { studioId: args.studioId, timeoutMs: SEGMENT_TIMEOUT_MS },
        );
        const lines = [`${cut.path}  (${cut.schema}, ${cut.size} studs)`, `Parts: ${cut.parts.join(", ")}`];
        if (cut.removed) {
          lines.push(`Replaced ${cut.removed}.`);
        }
        if (cut.steps === 2) {
          lines.push("Two undo steps: the placement, then removing the original.");
        }
        return text(lines.join("\n"));
      }

      if (args.op === "sweep") {
        const swept = await bridge.call<SweepResponse>(
          "geometry.sweep",
          {
            path: args.path,
            to: args.to,
            spin: args.spin,
            axis: args.axis,
            pivot: args.pivot,
            positions: args.positions,
            steps: args.steps,
            checkAgainst: args.checkAgainst,
            keep: args.keep,
            transparency: args.transparency,
            name: args.name,
            parent: args.parent,
            collisionFidelity: args.collisionFidelity,
          },
          { studioId: args.studioId, timeoutMs: 120_000 },
        );
        const lines: string[] = [];
        lines.push(
          swept.kept
            ? `${swept.created[0]}  (swept through ${swept.frames} positions)`
            : `Measured a sweep through ${swept.frames} positions; the volume was not kept.`,
        );
        if (swept.checked) {
          lines.push(
            swept.hits.length === 0
              ? "Clear - the motion hits nothing."
              : `Hits ${swept.hits.length}: ${swept.hits.join(", ")}`,
          );
        }
        if (!swept.undoable) {
          lines.push("Studio would not open an undo recording, so this is not one Ctrl+Z.");
        }
        return text(lines.join("\n"));
      }

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
        "uses. It reports script COUNT, triangles, whether the creator is " +
        "verified, whether the asset is free, and what Roblox thinks it is " +
        "(\"Door/Furniture\"). `insert` puts one into the place by id.\n\n" +
        "Results are ranked by approval WEIGHTED BY vote count, because the raw " +
        "percentage lies: 100% from two voters outranks 82% from five thousand " +
        "unless the count is taken into account. The vote count is shown beside " +
        "the percentage for the same reason.\n\n" +
        "Filters — `excludeScripts`, `maxTriangles`, `verifiedOnly`, `freeOnly`, " +
        "`minVotes` — are applied here, not by Roblox, and several pages are " +
        "fetched to fill the results. Roblox's own sort and creator filters are " +
        "accepted by the endpoint and silently ignored, so they are not offered.\n\n" +
        "ALWAYS check `hasScripts` before inserting. Free models carrying " +
        "scripts are the oldest hazard on the platform, and a model dropped into " +
        "someone's game can run whatever it likes. The insert reports the script " +
        "count again, and names them, so it can still be undone.\n\n" +
        "`peek` is the safer half of that: it loads the asset in memory WITHOUT " +
        "putting it in the place and tells you exactly what is inside — every " +
        "class, every script by name. Nothing is parented, so there is nothing " +
        "to undo. Use it whenever `hasScripts` says YES and the model still " +
        "looks worth having.\n\n" +
        "Audio searches take a different path from everything else here. They go " +
        "to the engine's own audio index, so results carry duration, artist and " +
        "whether the clip is music or a sound effect — the fields that actually " +
        "decide which sound you want. They return SOUND EFFECTS by default; pass " +
        '`audioType: "Music"` for tracks. Filter with `minDuration` / ' +
        "`maxDuration` — a footstep is under a second and a music bed is minutes.\n\n" +
        "Only public assets can be inserted. A private or deleted id fails with " +
        "a message saying so rather than inserting nothing quietly.\n\n" +
        "`bake` is unrelated to the Creator Store and does not upload anything. " +
        "It turns EditableMesh and EditableImage data into static content, which " +
        "frees the editable memory budget and lets a mesh built at runtime " +
        "replicate from the server down to clients.\n\n" +
        "READ THIS BEFORE REACHING FOR IT. What it produces is scoped to the data " +
        "model session it was made in. Baking in edit mode therefore carries " +
        "NOTHING into a playtest — a playtest is a new data model, and the " +
        "content reads as empty there. Measured, not assumed. Its real use is " +
        "against a RUNNING playtest server session: pass that `studioId`, and " +
        "baking a mesh the game just built is what lets clients see it.\n\n" +
        "It does not help `generate` at all. Generated meshes hold opaque " +
        "content, which the engine refuses to bake.",
      inputSchema: {
        op: z
          .enum(["search", "peek", "insert", "bake"])
          .describe(
            "'search' finds assets, 'peek' shows what is inside one without " +
              "inserting it, 'insert' adds one to the place, 'bake' makes " +
              "in-memory mesh and image data replicate.",
          ),
        keyword: z.string().optional().describe("search only: what to look for, e.g. \"medieval door\"."),
        category: z
          .enum(["model", "decal", "mesh", "audio"])
          .default("model")
          .describe("search only: what kind of asset. Only models insert as instances."),
        limit: z.number().int().min(1).max(20).default(8).describe("search only: how many results."),
        excludeScripts: z
          .boolean()
          .default(false)
          .describe(
            "search only: drop every result that contains scripts. The single " +
              "safest filter — a free model's scripts run with your game's full " +
              "permissions.",
          ),
        maxTriangles: z
          .number()
          .int()
          .min(1)
          .optional()
          .describe(
            "search only: drop models heavier than this. A prop you place fifty " +
              "times wants to be in the hundreds, not the tens of thousands.",
          ),
        verifiedOnly: z
          .boolean()
          .default(false)
          .describe("search only: only results from verified creators."),
        freeOnly: z
          .boolean()
          .default(false)
          .describe("search only: drop paid assets, which cannot just be inserted."),
        minVotes: z
          .number()
          .int()
          .min(0)
          .optional()
          .describe(
            "search only: require at least this many votes. Filters out models " +
              "with a perfect score from three people.",
          ),
        minDuration: z
          .number()
          .min(0)
          .optional()
          .describe("audio search only: shortest clip to return, in seconds."),
        maxDuration: z
          .number()
          .min(0)
          .optional()
          .describe(
            "audio search only: longest clip to return, in seconds. Set it to 3 " +
              "or so for effects — otherwise full-length music dominates the results.",
          ),
        audioType: z
          .enum(["SoundEffect", "Music"])
          .default("SoundEffect")
          .describe(
            "audio search only. Defaults to SoundEffect, which is what a noise in " +
              'a game is. Ask for "Music" only when you want a track — the engine\'s ' +
              'own default is Music, and it makes "footstep" return three-minute ' +
              "ambient songs with footsteps in the title.",
          ),
        assetId: z
          .number()
          .int()
          .positive()
          .optional()
          .describe("insert and peek only: the asset id."),
        parent: z.string().optional().describe("insert only: where to put it. Defaults to Workspace."),
        position: z
          .string()
          .optional()
          .describe('insert only: where to place it, e.g. "0, 10, 0". Defaults to wherever it was saved.'),
        name: z.string().optional().describe("insert only: rename it on the way in."),
        paths: z
          .array(z.string())
          .max(200)
          .optional()
          .describe("bake only: MeshParts to convert, or models containing them."),
        studioId: z.string().optional().describe("Target Studio; omit for the active one."),
      },
      destructive: false,
    },
    async (args): Promise<ToolResult> => {
      if (args.op === "peek") {
        if (!args.assetId) return text("peek needs an `assetId`.");
        const inside = await bridge.call<PeekResponse>(
          "assets.peek",
          { assetId: args.assetId },
          { studioId: args.studioId, timeoutMs: 60_000 },
        );
        const lines = [
          `Asset ${inside.assetId}: ${inside.descendants} instances, nothing inserted.`,
          "",
          `Top level: ${inside.roots.join(", ")}`,
          "",
          textOf(table(["className", "count"], inside.classes as unknown as Array<Record<string, unknown>>)),
        ];
        lines.push(
          inside.scriptCount === 0
            ? "\nNo scripts — safe to insert."
            : `\n${inside.scriptCount} script(s), and inserting runs them:\n  ` +
                inside.scripts.join("\n  ") +
                "\nRead them with `script_read` after inserting, or leave this asset alone.",
        );
        return text(lines.join("\n"));
      }

      if (args.op === "search" && args.category === "audio") {
        if (!args.keyword) return text("search needs a `keyword`.");
        const found = await bridge.call<AudioResponse>(
          "assets.audio",
          {
            keyword: args.keyword,
            limit: args.limit,
            minDuration: args.minDuration,
            maxDuration: args.maxDuration,
            audioType: args.audioType,
          },
          { studioId: args.studioId, timeoutMs: 45_000 },
        );
        if (found.items.length === 0) {
          return text(
            `No audio matched "${args.keyword}".` +
              (args.minDuration !== undefined || args.maxDuration !== undefined
                ? " The duration filter may be too narrow — try it without one."
                : ""),
          );
        }
        return text(
          textOf(
            table(
              ["assetId", "title", "artist", "duration", "audioType", "endorsed"],
              found.items as unknown as Array<Record<string, unknown>>,
              {
                more:
                  `${found.audioType}s only; duration in seconds; use the assetId as a ` +
                  "Sound's SoundId" +
                  (found.audioType === "SoundEffect"
                    ? '. Pass audioType="Music" for tracks.'
                    : "."),
              },
            ),
          ),
        );
      }

      if (args.op === "search") {
        if (!args.keyword) return text("search needs a `keyword`.");
        const found = await searchCreatorStore(args.keyword, args.category, args.limit, {
          excludeScripts: args.excludeScripts,
          maxTriangles: args.maxTriangles,
          verifiedOnly: args.verifiedOnly,
          freeOnly: args.freeOnly,
          minVotes: args.minVotes,
        });

        if (found.items.length === 0) {
          const filtered =
            args.excludeScripts || args.verifiedOnly || args.freeOnly || args.maxTriangles || args.minVotes;
          return text(
            `Nothing matched "${args.keyword}" in ${args.category}s` +
              (filtered
                ? `. ${found.scanned} result(s) were checked and every one was filtered out — loosen a filter.`
                : "."),
          );
        }

        const rows = found.items.map((entry) => ({
          assetId: entry.asset?.id ?? 0,
          name: entry.asset?.name ?? "?",
          creator:
            (entry.creator?.name ?? "?") + (entry.creator?.isVerifiedCreator ? " ✓" : ""),
          /*
           * Votes shown beside the percentage, never alone. "100%" is what two
           * friends upvoting looks like, and it sorts above a model used by
           * thousands unless the count is on screen next to it.
           */
          approval:
            entry.voting?.upVotePercent !== undefined
              ? `${entry.voting.upVotePercent}% (${entry.voting.voteCount ?? 0})`
              : "—",
          scripts: entry.asset?.hasScripts ? (entry.asset.scriptCount ?? "yes") : "no",
          triangles: entry.asset?.modelTechnicalDetails?.objectMeshSummary?.triangles ?? "—",
          free: entry.fiatProduct?.isFree === false ? "PAID" : "free",
          kind: (entry.asset?.objectTypes ?? []).join("/") || "—",
        }));

        const risky = rows.filter((row) => row.scripts !== "no");
        const paid = rows.filter((row) => row.free === "PAID");

        const notes: string[] = [];
        notes.push(
          `${found.items.length} shown of ${found.scanned} checked` +
            (found.total !== undefined ? ` (${found.total} exist)` : "") +
            "; ranked by approval weighted by vote count.",
        );
        if (risky.length > 0) {
          notes.push(
            `${risky.length} contain scripts (${risky.map((r) => r.name).join(", ")}). ` +
              "Inserting one runs whatever its author put in it — use `peek` to read them " +
              "first, or pass excludeScripts.",
          );
        } else {
          notes.push("None of these contain scripts.");
        }
        if (paid.length > 0) {
          notes.push(
            `${paid.length} are PAID and cannot simply be inserted: ${paid
              .map((r) => r.name)
              .join(", ")}.`,
          );
        }

        return text(
          textOf(
            table(
              ["assetId", "name", "creator", "approval", "scripts", "triangles", "free", "kind"],
              rows,
            ),
          ) +
            "\n\n" +
            notes.join("\n"),
        );
      }

      if (args.op === "bake") {
        if (!args.paths || args.paths.length === 0) {
          return text("bake needs `paths` — the MeshParts or models to convert.");
        }
        const baked = await bridge.call<BakeResponse>(
          "assets.bake",
          { paths: args.paths },
          // One conversion per mesh, each a round trip through the engine.
          { studioId: args.studioId, timeoutMs: 180_000 },
        );
        const lines = [`Examined ${baked.examined} MeshPart(s).`];
        if (baked.converted.length > 0) {
          lines.push(`Converted ${baked.converted.length}: ${baked.converted.join(", ")}`);
        }
        if (baked.skipped.length > 0) {
          lines.push(`Already replicating, left alone: ${baked.skipped.length}.`);
        }
        if (baked.opaque > 0) {
          lines.push(
            `${baked.opaque} hold opaque content, which the engine will not bake. ` +
              "That is what `generate` produces — those meshes are edit-mode only, " +
              "and nothing here can change that yet.",
          );
        }
        if (baked.failed.length > 0) {
          lines.push(`Refused: ${baked.failed.join("; ")}`);
        }
        if (baked.converted.length === 0 && baked.failed.length === 0 && baked.opaque === 0) {
          lines.push("Nothing needed baking — none of it was editable content.");
        }
        return text(lines.join("\n"));
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
        "what is meant.\n\n" +
        "Groups are not undoable and not scoped to a session: `remove` when one " +
        "was created to try something and is no longer wanted, rather than " +
        "leaving it registered in the place indefinitely. The built-in " +
        "\"Default\" group cannot be removed.\n\n" +
        "Groups belong to a world, not to the place. The Workspace is the " +
        "default and is what nearly every question is about; a `WorldModel` " +
        "inside a ViewportFrame keeps its own separate registry, so pass " +
        "`worldModel` to reach that one. A group of the same name in each is " +
        "two different groups.",
      inputSchema: {
        action: z
          .enum(["list", "create", "assign", "collidable", "remove"])
          .default("list")
          .describe(
            "'list' shows existing groups and changes nothing. 'remove' " +
              "unregisters a group entirely — not the same as un-assigning " +
              "parts from it.",
          ),
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
        worldModel: z
          .string()
          .optional()
          .describe(
            "Path to a WorldModel whose own collision groups this call is " +
              "about, e.g. \"StarterGui.Preview.Viewport.WorldModel\". Omit " +
              "for the Workspace, which is what you want unless the parts in " +
              "question live inside a ViewportFrame.",
          ),
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
          worldModel: args.worldModel,
        },
        { studioId: args.studioId },
      );
      if (args.action === "list") {
        const groups = response.groups ?? [];
        const where = response.world ?? "Workspace";
        if (groups.length === 0) return text(`No collision groups are registered in ${where}.`);
        return text(
          textOf(
            table(["name", "passes through", "mask"], groups.map((group) => ({
              name: group.name,
              "passes through": group.passesThrough ?? "?",
              mask: group.mask,
            })) as unknown as Array<Record<string, unknown>>, {
              // The ceiling is low enough to hit, and a caller registering
              // groups in a loop has no other way to find out where it is.
              more:
                response.max === undefined
                  ? where
                  : `${where}: ${groups.length} of ${response.max} groups used`,
            }),
          ),
        );
      }
      return json(response);
    },
  );
}
