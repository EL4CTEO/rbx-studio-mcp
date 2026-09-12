import { z } from "zod";
import { json, table, text, textOf, type ToolResult } from "../lib/format.js";
import { defineTool, type ToolContext } from "../lib/tool.js";

interface Row {
  key?: string;
  store?: string;
  value?: string;
  version?: string;
  created?: string;
  deleted?: boolean;
  [field: string]: unknown;
}

interface DataResponse {
  kind?: string;
  store?: string;
  items?: Row[];
  count?: number;
  cursor?: string;
  budget?: number;
  [field: string]: unknown;
}

/**
 * Data store calls cross the network twice — bridge to Studio, Studio to
 * Roblox — and the second hop is a real HTTP request to a service that
 * throttles. A list that walks several pages is several of those in sequence,
 * so the ceiling is generous on purpose.
 */
const TIMEOUT_MS = 45_000;

export function registerDataTools(context: ToolContext): void {
  const { bridge } = context;

  defineTool(
    context,
    {
      name: "datastore",
      title: "Read and write saved data",
      description:
        "Reads and writes the game's saved data — DataStore and MemoryStore — " +
        "from the connected Studio.\n\n" +
        "This is the only tool here that looks at anything outside the place " +
        "file. Every other tool answers 'is the instance right'; this one " +
        "answers 'is what the player saved right', which is a different " +
        "question and the one behind most reports of lost progress, reset " +
        "stats, or items that come back after a rejoin.\n\n" +
        "`kind=\"data\"` (the default) is DataStoreService: permanent, per-player, " +
        "and version-tracked. `kind=\"memory\"` is MemoryStoreService: a shared " +
        "scratchpad that expires on its own — queues, locks, live leaderboards.\n\n" +
        "The workflow for a bug report is: `list` with no store to see what " +
        "exists, `list` with one to see its keys, `get` the player's key, and — " +
        "the part worth knowing about — `versions` then `get` with a `version` " +
        "to see what that same key held BEFORE it broke. You cannot diagnose a " +
        "bad save by looking only at the bad save.\n\n" +
        "Writes need `confirm: true` on `kind=\"data\"`, because nothing in this " +
        "server can undo one: there is no recording to cancel and no Ctrl+Z. " +
        "Read the key first.\n\n" +
        "DataStore needs 'Enable Studio Access to API Services' ticked in Game " +
        "Settings → Security, and a published place. If it is off, this tool " +
        "says so in those words rather than reporting the raw 502. MemoryStore " +
        "needs neither.",
      inputSchema: {
        op: z
          .enum(["list", "get", "versions", "set", "remove"])
          .default("list")
          .describe(
            "'list' shows stores (no `store`) or a store's keys (with one). " +
              "'versions' is DataStore only and is how you see a key's history.",
          ),
        kind: z
          .enum(["data", "memory"])
          .default("data")
          .describe(
            "'data' = DataStoreService, permanent and versioned. 'memory' = " +
              "MemoryStoreService, shared and expiring. They are separate " +
              "storage — a key in one is not in the other.",
          ),
        store: z
          .string()
          .optional()
          .describe(
            "Data store name, or the sorted map's name for memory. Omit on " +
              "`list` to see which stores exist.",
          ),
        scope: z
          .string()
          .optional()
          .describe(
            "DataStore scope, if the game uses them. Omit for the default — but " +
              "if a store reads as empty and you expected data, a scope is the " +
              "usual reason.",
          ),
        key: z.string().optional().describe("The key. Usually the player's UserId as a string."),
        value: z
          .string()
          .optional()
          .describe(
            'set only: the new value as JSON — {"coins":10}, 42, or a bare ' +
              "string. Read the key first and edit what comes back rather than " +
              "writing a value from scratch: a save is usually a whole table and " +
              "writing part of one deletes the rest.",
          ),
        version: z
          .string()
          .optional()
          .describe("get only: read this exact version instead of the current value. From `versions`."),
        at: z
          .number()
          .optional()
          .describe(
            "get only: read the version that was current at this Unix time in " +
              "MILLISECONDS. Use when the player says when it broke but no " +
              "version id is known.",
          ),
        ttl: z
          .number()
          .int()
          .min(1)
          .max(3_888_000)
          .optional()
          .describe("memory set only: seconds before the value expires. Defaults to an hour."),
        prefix: z.string().optional().describe("list only: only names starting with this."),
        cursor: z.string().optional().describe("list only: continue from a previous call's cursor."),
        limit: z
          .number()
          .int()
          .min(1)
          .max(200)
          .optional()
          .describe("list/versions only: rows to return. Defaults to 50."),
        confirm: z
          .boolean()
          .optional()
          .describe(
            "Required for set and remove on kind=\"data\". This is real player " +
              "data and nothing here can put it back.",
          ),
        studioId: z.string().optional().describe("Target Studio; omit for the active one."),
      },
      // Reads dominate, but the tool can write, so it is not annotated read-only.
      readOnly: false,
      destructive: true,
    },
    async (args): Promise<ToolResult> => {
      const response = await bridge.call<DataResponse>(
        `data.${args.op}`,
        {
          kind: args.kind,
          store: args.store,
          scope: args.scope,
          key: args.key,
          value: args.value,
          version: args.version,
          at: args.at,
          ttl: args.ttl,
          prefix: args.prefix,
          cursor: args.cursor,
          limit: args.limit,
          confirm: args.confirm,
        },
        { studioId: args.studioId, timeoutMs: TIMEOUT_MS },
      );

      if (args.op === "list" || args.op === "versions") {
        const items = response.items ?? [];
        if (items.length === 0) {
          return text(
            args.store === undefined
              ? "No data stores in this place yet."
              : `Nothing in ${args.store}. If you expected data, check the \`scope\` — a game ` +
                  "that used scopes keeps its keys under them, and the default scope looks empty.",
          );
        }

        /*
         * Column choice is per-op rather than inferred from the rows, because
         * an inferred set drifts: `list` over stores has no `key`, over keys
         * has nothing else, and `versions` has three. Naming them keeps each
         * table readable instead of mostly blank.
         */
        const columns =
          args.op === "versions"
            ? ["version", "created", "deleted"]
            : args.store === undefined
              ? ["store", "created"]
              : args.kind === "memory"
                ? ["key", "value"]
                : ["key"];

        const notes: string[] = [];
        if (response.cursor) {
          notes.push(`more available — pass cursor="${response.cursor}"`);
        }
        if (typeof response.budget === "number") {
          notes.push(`${response.budget} requests left in budget`);
        }
        if (args.op === "versions") {
          notes.push('read one with op="get" and its `version`');
        }

        return text(
          textOf(
            table(columns, items as unknown as Array<Record<string, unknown>>, {
              more: notes.length > 0 ? notes.join("; ") : undefined,
            }),
          ),
        );
      }

      if (args.op === "get" && response.exists === false) {
        /*
         * The advice differs by backend, and the DataStore version of it is
         * nonsense for memory: MemoryStore has no scopes and no version
         * history, so pointing someone at either sends them looking for
         * something that does not exist.
         */
        return text(
          `${args.key} is not set in ${args.store}.\n` +
            (args.kind === "memory"
              ? "MemoryStore entries expire on their own, so a key written earlier may " +
                "simply have passed its TTL. There is no history to check."
              : "An empty key and a key that was never written look identical here. If a " +
                'player should have data, check the `scope`, and try op="versions" — a key ' +
                "that was removed still has history."),
        );
      }

      return json(response);
    },
  );
}
