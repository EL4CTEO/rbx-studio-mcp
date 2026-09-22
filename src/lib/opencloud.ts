import { loadCredentials, type Credentials } from "./credentials.js";
import { ToolError } from "./errors.js";

/**
 * One HTTP client for every Open Cloud call this server makes.
 *
 * Six features now talk to apis.roblox.com — uploads, asset grants, live data
 * stores, ordered data stores, place publishing and remote Luau. They share an
 * auth header, a set of failure modes and a pagination scheme, and the failure
 * modes are the reason this is one file rather than six copies: Roblox answers
 * a missing scope, a stale IP allowlist and a revoked key with the same 403 and
 * a body that names none of them. Guessing wrong there costs an hour, so the
 * guess is made once, here, with the scope that was actually needed in hand.
 */
const BASE = "https://apis.roblox.com";

/** Every distinct thing a caller can need, with the scope it requires. */
export type Scope =
  | "assets:write"
  | "asset-permissions:write"
  | "universe-datastores.control:list"
  | "universe-datastores.objects:list"
  | "universe-datastores.objects:read"
  | "universe-datastores.objects:create"
  | "universe-datastores.objects:update"
  | "universe-datastores.objects:delete"
  | "universe-datastores.versions:list"
  | "universe.ordered-data-store.scope.entry:read"
  | "universe.ordered-data-store.scope.entry:write"
  | "universe-places:write"
  | "universe.place.luau-execution-session:write"
  | "universe.place.instance:read"
  | "universe.place.instance:write"
  | "universe:write"
  | "universe-messaging-service:publish"
  | "universe-datastores.control:snapshot"
  | "universe.user-restriction:read"
  | "universe.user-restriction:write"
  | "user.advanced:read"
  | "user.inventory-item:read";

interface CallOptions {
  method?: "GET" | "POST" | "PATCH" | "DELETE";
  /** Path after the host, with a leading slash. */
  path: string;
  query?: Record<string, string | number | undefined>;
  /** A JSON body, a FormData, or raw bytes with an explicit content type. */
  body?: unknown;
  raw?: { bytes: Uint8Array<ArrayBuffer>; contentType: string };
  /** Named in the error when Roblox refuses, so the fix is one sentence. */
  scope: Scope;
  timeoutMs?: number;
}

/**
 * The credentials, or a ToolError explaining exactly what is missing.
 *
 * Thrown rather than returned. Every caller does the same thing with an
 * incomplete setup — stop and say so — and an early return per call site is how
 * one of them ends up forgetting.
 */
export async function requireCredentials(): Promise<Credentials> {
  const found = await loadCredentials();
  if (found !== null) return found;

  throw new ToolError(
    "NO_CREDENTIALS",
    "No Open Cloud API key is set up, so this cannot run.",
    "The user sets it once by typing `cloud` in the Studio panel — it walks " +
      "through creating the key and storing it safely. Never ask them to paste " +
      "a key into this conversation.",
  );
}

/**
 * Turns a place id into the universe that contains it.
 *
 * Not part of Open Cloud and not in Roblox's OpenAPI document, but it is the
 * endpoint Studio and every deploy tool uses, it needs no key, and it is the
 * only way to answer the question at all: a place knows nothing about its own
 * universe, and every universe-scoped call needs one. Verified against a live
 * place rather than taken from a forum post.
 *
 * Treated as best-effort. If Roblox ever moves it, the caller falls back to
 * asking the user, which is where they were before.
 */
export async function universeForPlace(placeId: string): Promise<string | null> {
  try {
    const response = await fetch(
      `${BASE}/universes/v1/places/${encodeURIComponent(placeId)}/universe`,
      // Best effort, so it must not be able to hang the call that asked.
      { signal: AbortSignal.timeout(10_000) },
    );
    if (!response.ok) return null;
    const body = (await response.json()) as { universeId?: number | string };
    return body.universeId === undefined ? null : String(body.universeId);
  } catch {
    return null;
  }
}

/**
 * The universe id, which every universe-scoped call needs and none can guess.
 *
 * Open Cloud is stateless: unlike the engine API it has no idea which game it
 * is talking about, and the Studio session cannot supply it either — a place
 * open in Studio knows its placeId but not the universe that contains it.
 */
export async function requireUniverse(explicit?: string): Promise<string> {
  if (explicit && explicit.trim() !== "") return explicit.trim();
  const found = await loadCredentials();
  if (found?.universeId) return found.universeId;

  /**
   * Derived from the place rather than demanded from the user.
   *
   * Someone who has told the panel which place they are working on has already
   * said which game they mean; making them go and copy a second id off a web
   * page to say it again is a papercut with nothing behind it.
   */
  if (found?.placeId) {
    const derived = await universeForPlace(found.placeId);
    if (derived) return derived;
  }

  throw new ToolError(
    "NO_UNIVERSE",
    "This needs a universe id and none is set.",
    "Ask the user to run `cloud universe <id>` in the Studio panel. They find " +
      "it on the Creator Dashboard: hover the game's thumbnail, click the ⋯ " +
      "button, Copy Universe ID. Or pass `universeId` to this call.",
  );
}

export async function requirePlace(explicit?: string): Promise<string> {
  if (explicit && explicit.trim() !== "") return explicit.trim();
  const found = await loadCredentials();
  if (found?.placeId) return found.placeId;

  throw new ToolError(
    "NO_PLACE",
    "This needs a place id and none is set.",
    "Ask the user to run `cloud place <id>` in the Studio panel, or pass " +
      "`placeId`. `studio_status` reports the placeId of the open place.",
  );
}

/** place id -> universe id, so the guard costs one request per place, not per call. */
const universeCache = new Map<string, string | null>();

async function universeOf(placeId: string): Promise<string | null> {
  const known = universeCache.get(placeId);
  if (known !== undefined) return known;
  const found = await universeForPlace(placeId);
  universeCache.set(placeId, found);
  return found;
}

/** The shape of the bridge these tools already hold, narrowed to what is needed. */
interface StatusSource {
  call<T>(
    command: string,
    params: Record<string, unknown>,
    options: { studioId?: string; timeoutMs?: number },
  ): Promise<T>;
}

/**
 * Refuses to act on a different game from the one open in Studio.
 *
 * The stored place is sticky and Studio's is not: someone runs `cloud place`
 * once, opens a different experience a week later, and every live call still
 * points at the first one. Nothing about that looks wrong from the outside. A
 * live data store read returns another game's player saves, a restart cycles
 * another game's servers, a ban lands on the wrong experience -- each with a
 * plausible success message and no error anywhere. Found by opening a real game
 * in Studio while the stored place was still a test place.
 *
 * Passing `placeId` or `universeId` explicitly is taken as "I mean this one"
 * and skips the check: a deliberate cross-place call is a real thing to want,
 * drifting into one by accident is not. So is having no Studio connected --
 * there is nothing to compare against, and refusing would break every headless
 * use.
 */
export async function assertTargetsOpenPlace(
  bridge: StatusSource,
  target: { universeId?: string; placeId?: string; explicit: boolean; studioId?: string },
): Promise<void> {
  if (target.explicit) return;

  let openPlaceId: string | undefined;
  try {
    const status = await bridge.call<{ placeId?: number }>(
      "studio.status",
      {},
      { studioId: target.studioId, timeoutMs: 5_000 },
    );
    // An unpublished place reports 0, which names no game and cannot be compared.
    openPlaceId = status.placeId ? String(status.placeId) : undefined;
  } catch {
    return;
  }
  if (openPlaceId === undefined) return;

  if (target.placeId !== undefined && target.placeId !== openPlaceId) {
    throw new ToolError(
      "WRONG_PLACE",
      `This would act on place ${target.placeId}, but Studio has ${openPlaceId} open.`,
      `The stored \`cloud place\` is from another session. Run \`cloud place ` +
        `${openPlaceId}\` in the Studio panel, or pass \`placeId\` to say you ` +
        "meant the other game on purpose.",
    );
  }

  if (target.universeId !== undefined) {
    const openUniverse = await universeOf(openPlaceId);
    if (openUniverse !== null && openUniverse !== target.universeId) {
      throw new ToolError(
        "WRONG_PLACE",
        `This would act on universe ${target.universeId}, but Studio has a place ` +
          `from universe ${openUniverse} open.`,
        `Run \`cloud place ${openPlaceId}\` in the Studio panel to point at the ` +
          "open game, or pass `universeId` to say you meant the other one.",
      );
    }
  }
}

/** Pulls something readable out of Roblox's several error body shapes. */
function detailOf(body: string): string {
  try {
    const parsed = JSON.parse(body) as {
      message?: string;
      error?: string | { message?: string };
      errors?: Array<{ message?: string }>;
    };
    if (typeof parsed.error === "string") return parsed.error;
    return (
      parsed.message ??
      (typeof parsed.error === "object" ? parsed.error?.message : undefined) ??
      parsed.errors?.[0]?.message ??
      body.slice(0, 300)
    );
  } catch {
    return body.slice(0, 300);
  }
}

/**
 * Turns an HTTP failure into an error a reader can act on.
 *
 * The 403 branch carries the whole value of this module. Roblox returns it for
 * a key missing a scope, a key whose IP allowlist no longer matches, and a key
 * with no access to that particular universe — three different fixes behind one
 * status and a body that distinguishes none of them. Naming the scope the call
 * needed turns "Forbidden" into a checklist.
 */
function failure(status: number, body: string, scope: Scope): ToolError {
  const detail = detailOf(body);

  if (status === 401) {
    return new ToolError(
      "BAD_KEY",
      `Roblox rejected the API key (401): ${detail}`,
      "The key is wrong or was revoked. `cloud test` in the Studio panel " +
        "re-checks it.",
    );
  }
  if (status === 403) {
    return new ToolError(
      "FORBIDDEN",
      `Roblox refused the key (403): ${detail}`,
      `This call needs the \`${scope}\` permission. Three things cause a 403 ` +
        "and the message names none of them: the key is missing that scope, " +
        "the key's IP allowlist no longer includes this machine, or the key " +
        "was not granted access to this experience. Check them in that order " +
        "on the Creator Dashboard.",
    );
  }
  if (status === 404) {
    return new ToolError(
      "NOT_FOUND",
      `Roblox has no such thing (404): ${detail}`,
      "Check the universe id, place id, and any data store or key name — " +
        "Open Cloud does not create parents implicitly.",
    );
  }
  if (status === 429) {
    return new ToolError("RATE_LIMITED", `Rate limited by Roblox: ${detail}`, "Wait and retry.");
  }
  if (status === 400) {
    return new ToolError("BAD_REQUEST", `Roblox refused the request (400): ${detail}`);
  }
  return new ToolError("CLOUD_ERROR", `Roblox returned ${status}: ${detail}`);
}

/**
 * One Open Cloud request.
 *
 * Returns parsed JSON, or `{}` for the endpoints that answer 200 with an empty
 * body — a DELETE among them. A caller that needs the raw text should not be
 * using this.
 */
export async function call<T>(
  credentials: Credentials,
  options: CallOptions,
): Promise<T> {
  const url = new URL(options.path, BASE);
  for (const [key, value] of Object.entries(options.query ?? {})) {
    if (value !== undefined) url.searchParams.set(key, String(value));
  }

  const headers: Record<string, string> = { "x-api-key": credentials.apiKey };
  let body: FormData | Uint8Array<ArrayBuffer> | string | undefined;

  if (options.raw) {
    headers["Content-Type"] = options.raw.contentType;
    body = options.raw.bytes;
  } else if (options.body instanceof FormData) {
    // Left unset on purpose: fetch adds the multipart boundary, and setting it
    // by hand produces a body Roblox cannot parse.
    body = options.body;
  } else if (options.body !== undefined) {
    headers["Content-Type"] = "application/json";
    body = JSON.stringify(options.body);
  }

  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), options.timeoutMs ?? 60_000);
  let response: Response;
  try {
    response = await fetch(url, {
      method: options.method ?? "GET",
      headers,
      body: body as RequestInit["body"],
      signal: controller.signal,
    });
  } catch (cause) {
    const error = cause as Error;
    throw new ToolError(
      "CLOUD_UNREACHABLE",
      error.name === "AbortError"
        ? "Roblox did not answer in time."
        : `Could not reach Roblox: ${error.message}`,
    );
  } finally {
    clearTimeout(timer);
  }

  const text = await response.text();
  if (!response.ok) throw failure(response.status, text, options.scope);
  if (text.trim() === "") return {} as T;
  try {
    return JSON.parse(text) as T;
  } catch {
    return { raw: text } as T;
  }
}

/**
 * Walks a paged collection and returns at most `limit` items.
 *
 * Open Cloud pages everything and the page size it picks is not the number a
 * caller asked for, so "the first 20 entries" is a loop, not a request. Capped
 * rather than exhaustive: a data store can hold millions of keys, and the tool
 * that asks for a page wants a page.
 */
export async function paged<T>(
  credentials: Credentials,
  options: CallOptions & { field: string; limit: number },
): Promise<{ items: T[]; nextPageToken?: string; truncated: boolean }> {
  const items: T[] = [];
  let pageToken: string | undefined = options.query?.["pageToken"] as string | undefined;

  for (;;) {
    const page = await call<Record<string, unknown>>(credentials, {
      ...options,
      query: {
        ...options.query,
        maxPageSize: Math.min(options.limit - items.length, 100),
        pageToken,
      },
    });

    const batch = (page[options.field] as T[] | undefined) ?? [];
    items.push(...batch);
    pageToken = page["nextPageToken"] as string | undefined;

    // An empty page with a token still set would spin forever; Roblox does
    // return that when a filter excludes everything on a page.
    if (!pageToken || items.length >= options.limit || batch.length === 0) {
      return {
        items: items.slice(0, options.limit),
        nextPageToken: pageToken,
        truncated: Boolean(pageToken),
      };
    }
  }
}
