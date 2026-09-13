import type { Credentials } from "./credentials.js";
import { ToolError } from "./errors.js";
import { call, paged, type Scope } from "./opencloud.js";

/**
 * Data stores of the PUBLISHED game, over Open Cloud.
 *
 * The `datastore` tool already reads data stores — through Studio, which reads
 * whatever the open place is connected to. That is the right thing while
 * building and the wrong thing when a player reports lost progress, because
 * Studio's view depends on which place is open and on "Enable Studio Access to
 * API Services" being ticked. This path talks to Roblox directly and always
 * sees exactly what the live servers see.
 *
 * Kept behind the same tool and the same five verbs rather than a new one. The
 * question "what did this player save" does not change because the answer comes
 * over HTTP, and a second tool would mean an agent picking between two spellings
 * of one idea.
 *
 * Two differences from the engine API are load-bearing and are surfaced rather
 * than hidden:
 *
 * 1. Creating and updating are separate permissions. `SetAsync` creates or
 *    overwrites; here a write to a missing key is refused unless it is asked
 *    for, which is what makes a support tool safe to hand out.
 * 2. Values are JSON, not Luau. Roblox does no serialising for us, and a value
 *    that was a Luau table arrives as a JSON object.
 */

/** Percent-encodes one path segment. Key names routinely contain slashes. */
function segment(value: string): string {
  return encodeURIComponent(value);
}

/**
 * Builds the entries path, with or without a scope.
 *
 * Open Cloud has two shapes rather than a scope parameter: omitting the scope
 * is not "the default scope", it means "all scopes". A game that uses scopes
 * and a game that does not therefore need genuinely different URLs, and getting
 * this wrong reads as the store being empty.
 */
function entriesPath(universe: string, store: string, scope?: string): string {
  const base = `/cloud/v2/universes/${segment(universe)}/data-stores/${segment(store)}`;
  return scope && scope !== ""
    ? `${base}/scopes/${segment(scope)}/entries`
    : `${base}/entries`;
}

function orderedPath(universe: string, store: string, scope: string): string {
  return (
    `/cloud/v2/universes/${segment(universe)}` +
    `/ordered-data-stores/${segment(store)}/scopes/${segment(scope)}/entries`
  );
}

interface Entry {
  path?: string;
  value?: unknown;
  revisionId?: string;
  revisionCreateTime?: string;
  createTime?: string;
  state?: string;
  etag?: string;
  id?: string;
}

/** The trailing id of a resource path, which is the only part a human wants. */
function idOf(path: string | undefined): string {
  if (!path) return "";
  const parts = path.split("/");
  return decodeURIComponent(parts[parts.length - 1] ?? "");
}

export interface LiveArgs {
  op: "list" | "get" | "versions" | "set" | "remove" | "increment";
  kind: "data" | "ordered";
  universe: string;
  store?: string;
  scope?: string;
  key?: string;
  value?: string;
  amount?: number;
  version?: string;
  limit: number;
  cursor?: string;
  create?: boolean;
}

function parseValue(raw: string | undefined): unknown {
  if (raw === undefined) {
    throw new ToolError("BAD_PARAMS", "set needs a `value`.");
  }
  try {
    return JSON.parse(raw);
  } catch {
    /**
     * A bare string is valid JSON only when quoted, and people write
     * `value: "hello"` meaning the string. Accepting it is friendlier than a
     * parse error — but only after real JSON has been tried, so `{"a":1}` is
     * never stored as the eleven characters that spell it.
     */
    return raw;
  }
}

export async function liveDataStore(
  credentials: Credentials,
  args: LiveArgs,
): Promise<Record<string, unknown>> {
  const { universe, op, kind } = args;

  if (kind === "ordered") return orderedStore(credentials, args);

  if (op === "list" && !args.store) {
    const { items, truncated } = await paged<{ path?: string; createTime?: string; state?: string }>(
      credentials,
      {
        path: `/cloud/v2/universes/${segment(universe)}/data-stores`,
        scope: "universe-datastores.control:list" as Scope,
        field: "dataStores",
        limit: args.limit,
        query: { pageToken: args.cursor },
      },
    );
    return {
      target: "live",
      universe,
      items: items.map((store) => ({
        store: idOf(store.path),
        created: store.createTime,
        state: store.state,
      })),
      count: items.length,
      truncated,
    };
  }

  if (!args.store) {
    throw new ToolError("BAD_PARAMS", `live ${op} needs a \`store\`.`);
  }
  const base = entriesPath(universe, args.store, args.scope);

  if (op === "list") {
    const { items, truncated } = await paged<Entry>(credentials, {
      path: base,
      scope: "universe-datastores.objects:list" as Scope,
      field: "dataStoreEntries",
      limit: args.limit,
      query: { pageToken: args.cursor },
    });
    return {
      target: "live",
      store: args.store,
      items: items.map((entry) => ({ key: idOf(entry.path), state: entry.state })),
      count: items.length,
      truncated,
    };
  }

  if (!args.key) throw new ToolError("BAD_PARAMS", `live ${op} needs a \`key\`.`);
  const entry = `${base}/${segment(args.key)}`;

  if (op === "versions") {
    const { items, truncated } = await paged<Entry>(credentials, {
      path: `${entry}:listRevisions`,
      scope: "universe-datastores.versions:list" as Scope,
      field: "dataStoreEntries",
      limit: args.limit,
      query: { pageToken: args.cursor },
    });
    return {
      target: "live",
      store: args.store,
      key: args.key,
      items: items.map((revision) => ({
        version: revision.revisionId,
        created: revision.revisionCreateTime,
        deleted: revision.state === "DELETED",
      })),
      count: items.length,
      truncated,
    };
  }

  if (op === "get") {
    const found = await call<Entry>(credentials, {
      path: entry,
      scope: "universe-datastores.objects:read" as Scope,
    });
    return {
      target: "live",
      store: args.store,
      key: args.key,
      exists: true,
      value: found.value,
      version: found.revisionId,
      updated: found.revisionCreateTime,
      etag: found.etag,
    };
  }

  if (op === "remove") {
    await call(credentials, {
      method: "DELETE",
      path: entry,
      scope: "universe-datastores.objects:delete" as Scope,
    });
    return { target: "live", store: args.store, key: args.key, removed: true };
  }

  if (op === "increment") {
    if (typeof args.amount !== "number") {
      throw new ToolError("BAD_PARAMS", "increment needs an `amount`.");
    }
    const result = await call<Entry>(credentials, {
      method: "POST",
      path: `${entry}:increment`,
      body: { amount: args.amount },
      scope: "universe-datastores.objects:update" as Scope,
    });
    return {
      target: "live",
      store: args.store,
      key: args.key,
      value: result.value,
      version: result.revisionId,
    };
  }

  /**
   * `allowMissing` is the create/update split made visible.
   *
   * Off by default so a typo in a key name fails instead of quietly creating a
   * second, empty save beside the real one — the failure mode that makes people
   * think a player's data "reset".
   */
  const written = await call<Entry>(credentials, {
    method: "PATCH",
    path: entry,
    query: { allowMissing: args.create ? "true" : undefined },
    body: { value: parseValue(args.value) },
    scope: "universe-datastores.objects:update" as Scope,
  });
  return {
    target: "live",
    store: args.store,
    key: args.key,
    written: true,
    version: written.revisionId,
  };
}

/**
 * Ordered data stores: the leaderboard backend.
 *
 * A separate service with a separate scope, not a flavour of the one above —
 * values are numbers only, entries are always sorted, and there is no version
 * history. It lives here rather than in its own file because from the caller's
 * side it is the same five verbs against the same game.
 */
async function orderedStore(
  credentials: Credentials,
  args: LiveArgs,
): Promise<Record<string, unknown>> {
  if (!args.store) throw new ToolError("BAD_PARAMS", "ordered stores need a `store`.");
  // Roblox requires a scope in the URL and every SDK defaults it to "global";
  // an ordered store written by an engine script with no scope lands there.
  const scope = args.scope && args.scope !== "" ? args.scope : "global";
  const base = orderedPath(args.universe, args.store, scope);

  if (args.op === "list") {
    const { items, truncated } = await paged<Entry & { value?: number }>(credentials, {
      path: base,
      scope: "universe.ordered-data-store.scope.entry:read" as Scope,
      field: "orderedDataStoreEntries",
      limit: args.limit,
      // Descending: a leaderboard is read from the top, and asking for the
      // bottom of one is the rarer case.
      query: { orderBy: "value desc", pageToken: args.cursor },
    });
    return {
      target: "live",
      kind: "ordered",
      store: args.store,
      scope,
      items: items.map((entry, index) => ({
        rank: index + 1,
        key: entry.id ?? idOf(entry.path),
        value: entry.value,
      })),
      count: items.length,
      truncated,
    };
  }

  if (!args.key) throw new ToolError("BAD_PARAMS", `ordered ${args.op} needs a \`key\`.`);
  const entry = `${base}/${segment(args.key)}`;

  if (args.op === "get") {
    const found = await call<Entry & { value?: number }>(credentials, {
      path: entry,
      scope: "universe.ordered-data-store.scope.entry:read" as Scope,
    });
    return { target: "live", kind: "ordered", store: args.store, scope, key: args.key, value: found.value };
  }

  if (args.op === "remove") {
    await call(credentials, {
      method: "DELETE",
      path: entry,
      scope: "universe.ordered-data-store.scope.entry:write" as Scope,
    });
    return { target: "live", kind: "ordered", store: args.store, key: args.key, removed: true };
  }

  if (args.op === "increment") {
    if (typeof args.amount !== "number") {
      throw new ToolError("BAD_PARAMS", "increment needs an `amount`.");
    }
    const result = await call<Entry & { value?: number }>(credentials, {
      method: "POST",
      path: `${entry}:increment`,
      body: { amount: args.amount },
      scope: "universe.ordered-data-store.scope.entry:write" as Scope,
    });
    return { target: "live", kind: "ordered", store: args.store, key: args.key, value: result.value };
  }

  if (args.op === "versions") {
    throw new ToolError(
      "UNSUPPORTED",
      "Ordered data stores keep no version history.",
      'Use kind="data" for anything that needs to be recoverable.',
    );
  }

  const numeric = Number(args.value);
  if (!Number.isFinite(numeric)) {
    throw new ToolError(
      "BAD_PARAMS",
      `An ordered data store holds numbers; "${args.value}" is not one.`,
    );
  }
  /**
   * Update first, create on 404.
   *
   * Open Cloud splits the two and the caller usually does not know which they
   * need — setting a player's score works the same whether or not they have one
   * yet. Trying the safer verb first keeps the create path from being the
   * default, which is what stops a typo'd key becoming a new leaderboard row.
   */
  try {
    const patched = await call<Entry & { value?: number }>(credentials, {
      method: "PATCH",
      path: entry,
      body: { value: numeric },
      scope: "universe.ordered-data-store.scope.entry:write" as Scope,
    });
    return {
      target: "live",
      kind: "ordered",
      store: args.store,
      key: args.key,
      value: patched.value,
      created: false,
    };
  } catch (cause) {
    if (!(cause instanceof ToolError) || cause.code !== "NOT_FOUND") throw cause;
    const made = await call<Entry & { value?: number }>(credentials, {
      method: "POST",
      path: base,
      query: { id: args.key },
      body: { value: numeric },
      scope: "universe.ordered-data-store.scope.entry:write" as Scope,
    });
    return {
      target: "live",
      kind: "ordered",
      store: args.store,
      key: args.key,
      value: made.value,
      created: true,
    };
  }
}
