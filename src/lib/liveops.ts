import type { Credentials } from "./credentials.js";
import { ToolError } from "./errors.js";
import { call, paged } from "./opencloud.js";

/**
 * Operating the published experience, over Open Cloud.
 *
 * Everything here acts on the game as it exists on Roblox rather than on the
 * place someone has open in Studio: its scripts, its servers, its players, its
 * saved data. That is a different job from building, and the failure modes are
 * different too — there is no undo stack and the audience is real.
 *
 * Two things in here are long-running operations rather than requests. Roblox
 * answers the Instance calls with an `Operation` to poll, because reaching into
 * a place file is not instant. `awaitOperation` hides that; nothing else should
 * have to know.
 */
const OPERATION_INTERVAL_MS = 1_000;
const OPERATION_TIMEOUT_MS = 60_000;

interface Operation {
  path?: string;
  done?: boolean;
  response?: Record<string, unknown>;
  error?: { code?: number; message?: string };
}

/**
 * Polls an Operation to completion and returns its payload.
 *
 * The error case is worth naming rather than passing through: a 422 here means
 * the response exceeded Roblox's 500,000-byte cap, which is a real and
 * recoverable situation (ask for fewer children, or a smaller script) and reads
 * as nothing at all in the raw body.
 */
async function awaitOperation(
  credentials: Credentials,
  started: Operation,
  scope: Parameters<typeof call>[1]["scope"],
): Promise<Record<string, unknown>> {
  let operation = started;
  const deadline = Date.now() + OPERATION_TIMEOUT_MS;

  while (!operation.done) {
    if (!operation.path) {
      throw new ToolError("NO_OPERATION", "Roblox did not say where to track this request.");
    }
    if (Date.now() >= deadline) {
      throw new ToolError("TIMEOUT", "Roblox did not finish this request in time.");
    }
    await new Promise((done) => setTimeout(done, OPERATION_INTERVAL_MS));
    operation = await call<Operation>(credentials, {
      path: `/cloud/v2/${operation.path}`,
      scope,
    });
  }

  if (operation.error) {
    if (operation.error.code === 422) {
      throw new ToolError(
        "TOO_LARGE",
        "The response was over Roblox's 500,000-byte limit for this API.",
        "Ask for a smaller piece: fewer children at a time, or one script rather " +
          "than a folder.",
      );
    }
    throw new ToolError(
      "OPERATION_FAILED",
      `Roblox refused: ${operation.error.message ?? operation.error.code ?? "no reason given"}`,
    );
  }
  return operation.response ?? {};
}

/**
 * The Instance API: scripts in the PUBLISHED place, without Studio.
 *
 * Narrower than it first looks, and the narrowness is the important part.
 * Roblox's `InstanceDetails` covers exactly four classes — Folder, Script,
 * LocalScript and ModuleScript — so this is not a live DataModel browser. It is
 * a way to read and edit the code of a published place from outside Studio,
 * which is why it belongs beside `script_read` and `script_edit` rather than
 * beside `tree` and `modify`.
 *
 * It also acts on the saved place, not on a running server. Editing here
 * changes what the next server to start will run; it does not change what a
 * player in a server right now is running. `restartServers` is the other half
 * of that, and they are meant to be used together.
 */
const INSTANCE_SCOPE = "universe.place.instance:read" as const;
const INSTANCE_WRITE = "universe.place.instance:write" as const;

function instancePath(universe: string, place: string, instance: string): string {
  return (
    `/cloud/v2/universes/${encodeURIComponent(universe)}` +
    `/places/${encodeURIComponent(place)}/instances/${encodeURIComponent(instance)}`
  );
}

interface EngineInstance {
  Id?: string;
  Name?: string;
  Parent?: string;
  Details?: Record<string, { Source?: string; Enabled?: boolean; RunContext?: string }>;
}

interface CloudInstance {
  path?: string;
  hasChildren?: boolean;
  engineInstance?: EngineInstance;
}

/** Flattens one instance into the shape the script tools already speak. */
function describe(entry: CloudInstance): Record<string, unknown> {
  const engine = entry.engineInstance ?? {};
  const details = engine.Details ?? {};
  const className = Object.keys(details)[0] ?? "Instance";
  const body = details[className] ?? {};
  return {
    id: engine.Id,
    name: engine.Name,
    className,
    hasChildren: entry.hasChildren ?? false,
    ...(body.Source === undefined ? {} : { source: body.Source }),
    ...(body.Enabled === undefined ? {} : { enabled: body.Enabled }),
    ...(body.RunContext === undefined ? {} : { runContext: body.RunContext }),
  };
}

export async function liveInstance(
  credentials: Credentials,
  args: { universeId: string; placeId: string; instanceId: string },
): Promise<Record<string, unknown>> {
  const started = await call<Operation>(credentials, {
    path: instancePath(args.universeId, args.placeId, args.instanceId),
    scope: INSTANCE_SCOPE,
  });
  const done = await awaitOperation(credentials, started, INSTANCE_SCOPE);
  return describe(done as CloudInstance);
}

export async function liveChildren(
  credentials: Credentials,
  args: { universeId: string; placeId: string; instanceId: string; limit: number },
): Promise<Record<string, unknown>> {
  const started = await call<Operation>(credentials, {
    path: `${instancePath(args.universeId, args.placeId, args.instanceId)}:listChildren`,
    query: { maxPageSize: Math.min(args.limit, 100) },
    scope: INSTANCE_SCOPE,
  });
  const done = await awaitOperation(credentials, started, INSTANCE_SCOPE);
  const items = (done["instances"] as CloudInstance[] | undefined) ?? [];
  return {
    parent: args.instanceId,
    items: items.slice(0, args.limit).map(describe),
    count: Math.min(items.length, args.limit),
  };
}

/**
 * Resolves a dot path to a cloud instance id by walking down from the root.
 *
 * The Instance API addresses things by GUID, not by name, and offers no search.
 * So a path everyone already writes -- "ServerScriptService.Systems.Combat" --
 * costs one listChildren per segment, and each of those is a long-running
 * operation. Three segments is a few seconds.
 *
 * Worth paying rather than making callers hunt for GUIDs: every other tool here
 * takes a path, and a live read that needed a different kind of address would
 * be a different tool wearing this one's name.
 */
export async function resolveLivePath(
  credentials: Credentials,
  args: { universeId: string; placeId: string; path: string },
): Promise<{ id: string; className: string; name: string }> {
  const segments = args.path.split(".").filter((part) => part !== "");
  if (segments.length === 0) {
    throw new ToolError("BAD_PARAMS", "A live script path cannot be empty.");
  }

  let current = "root";
  let found: Record<string, unknown> | null = null;

  for (const segment of segments) {
    const children = await liveChildren(credentials, {
      universeId: args.universeId,
      placeId: args.placeId,
      instanceId: current,
      limit: 100,
    });
    const items = children["items"] as Array<Record<string, unknown>>;
    const match = items.find((entry) => entry["name"] === segment);
    if (!match) {
      const names = items
        .slice(0, 12)
        .map((entry) => String(entry["name"]))
        .join(", ");
      throw new ToolError(
        "NOT_FOUND",
        `The published place has no "${segment}" under ${current === "root" ? "the root" : current}.`,
        names === ""
          ? "Nothing is there. Note the Instance API only sees Folders and " +
            "scripts, so a path through any other class cannot be walked."
          : `What is there: ${names}. The Instance API only sees Folders and ` +
            "scripts, so a path through a Model or a Part cannot be walked.",
      );
    }
    current = String(match["id"]);
    found = match;
  }

  return {
    id: current,
    className: String(found?.["className"] ?? "Instance"),
    name: String(found?.["name"] ?? segments[segments.length - 1]),
  };
}

export async function liveScriptWrite(
  credentials: Credentials,
  args: {
    universeId: string;
    placeId: string;
    instanceId: string;
    className: "Script" | "LocalScript" | "ModuleScript";
    source: string;
  },
): Promise<Record<string, unknown>> {
  // Roblox caps the source at 200,000 bytes AFTER UTF-8 encoding, so the check
  // is on bytes rather than on characters — a script of emoji or non-Latin
  // comments is several times longer than its length suggests.
  const bytes = Buffer.byteLength(args.source, "utf8");
  if (bytes > 200_000) {
    throw new ToolError(
      "TOO_LARGE",
      `That source is ${bytes} bytes; Roblox accepts 200,000 for a cloud script edit.`,
    );
  }

  const started = await call<Operation>(credentials, {
    method: "PATCH",
    path: instancePath(args.universeId, args.placeId, args.instanceId),
    body: {
      engineInstance: {
        Details: { [args.className]: { Source: args.source } },
      },
    },
    scope: INSTANCE_WRITE,
  });
  const done = await awaitOperation(credentials, started, INSTANCE_WRITE);
  return {
    ...describe(done as CloudInstance),
    written: true,
    bytes,
    note:
      "This changed the SAVED place. Servers already running still have the old " +
      "code — restart them with `assets op=\"publish\" restart:true`, or wait for " +
      "them to cycle.",
  };
}

/**
 * Rolls live servers onto the newly published version.
 *
 * Publishing alone changes nothing for anyone already playing: they stay on the
 * server they are on, running the old code, until it empties. This is the step
 * people forget, which is why it sits on the publish call rather than on its
 * own.
 *
 * `bleedOff` is the humane default and is not the API's. Roblox defaults to
 * shutting servers down immediately, which teleports players mid-game; bleeding
 * off stops matchmaking and lets them finish.
 */
export async function restartServers(
  credentials: Credentials,
  args: { universeId: string; placeIds?: number[]; bleedOffMinutes?: number },
): Promise<Record<string, unknown>> {
  const bleed = args.bleedOffMinutes ?? 10;
  await call(credentials, {
    method: "POST",
    path: `/cloud/v2/universes/${encodeURIComponent(args.universeId)}:restartServers`,
    body: {
      placeIds: args.placeIds,
      bleedOffServers: bleed > 0,
      bleedOffDurationMinutes: bleed > 0 ? bleed : undefined,
    },
    scope: "universe:write",
  });
  return {
    restarted: true,
    universeId: args.universeId,
    bleedOffMinutes: bleed,
    note:
      bleed > 0
        ? `Matchmaking to old servers has stopped; they shut down over the next ${bleed} ` +
          "minutes so players can finish."
        : "Servers are shutting down now. Anyone playing is being moved immediately.",
  };
}

/** Sends a MessagingService message to every live server. */
export async function publishMessage(
  credentials: Credentials,
  args: { universeId: string; topic: string; message: string },
): Promise<Record<string, unknown>> {
  await call(credentials, {
    method: "POST",
    path: `/cloud/v2/universes/${encodeURIComponent(args.universeId)}:publishMessage`,
    body: { topic: args.topic, message: args.message },
    scope: "universe-messaging-service:publish",
  });
  return {
    published: true,
    topic: args.topic,
    note:
      "Delivered only to servers with a SubscribeAsync listener on this exact " +
      "topic. Nothing reports whether anything was listening, so a silent " +
      "success does not mean it was received.",
  };
}

/**
 * Takes a data store snapshot for the whole experience.
 *
 * The safety net for every live write. Roblox allows one snapshot per
 * experience per UTC day, and says in the response whether this call actually
 * took one — which matters, because a second call on the same day reports
 * success while doing nothing.
 */
export async function snapshotDataStores(
  credentials: Credentials,
  universeId: string,
): Promise<Record<string, unknown>> {
  const result = await call<{ newSnapshotTaken?: boolean; latestSnapshotTime?: string }>(
    credentials,
    {
      method: "POST",
      path: `/cloud/v2/universes/${encodeURIComponent(universeId)}/data-stores:snapshot`,
      body: {},
      scope: "universe-datastores.control:snapshot",
    },
  );
  return {
    newSnapshotTaken: result.newSnapshotTaken === true,
    latestSnapshotTime: result.latestSnapshotTime,
    note:
      result.newSnapshotTaken === true
        ? "Snapshot taken. Safe to make the change."
        : "NO new snapshot was taken — Roblox allows one per experience per UTC " +
          `day and one already exists (${result.latestSnapshotTime}). Anything ` +
          "written since then is NOT covered.",
  };
}

/** Bans or unbans a player, across the experience or one place. */
export async function setRestriction(
  credentials: Credentials,
  args: {
    universeId: string;
    placeId?: string;
    userId: string;
    active: boolean;
    durationSeconds?: number;
    displayReason?: string;
    privateReason?: string;
    excludeAltAccounts?: boolean;
  },
): Promise<Record<string, unknown>> {
  const base = args.placeId
    ? `/cloud/v2/universes/${encodeURIComponent(args.universeId)}/places/${encodeURIComponent(args.placeId)}`
    : `/cloud/v2/universes/${encodeURIComponent(args.universeId)}`;

  const restriction: Record<string, unknown> = { active: args.active };
  if (args.active) {
    // Omitted duration means permanent, which is the engine's rule and is worth
    // making the caller state rather than defaulting to.
    if (args.durationSeconds) restriction["duration"] = `${args.durationSeconds}s`;
    restriction["displayReason"] = args.displayReason ?? "";
    restriction["privateReason"] = args.privateReason ?? "";
    restriction["excludeAltAccounts"] = args.excludeAltAccounts ?? false;
  }

  const result = await call<{ user?: string; gameJoinRestriction?: Record<string, unknown> }>(
    credentials,
    {
      method: "PATCH",
      path: `${base}/user-restrictions/${encodeURIComponent(args.userId)}`,
      body: { gameJoinRestriction: restriction },
      scope: "universe.user-restriction:write",
    },
  );

  return {
    userId: args.userId,
    banned: args.active,
    scope: args.placeId ? `place ${args.placeId}` : `universe ${args.universeId}`,
    duration: args.durationSeconds ? `${args.durationSeconds}s` : args.active ? "permanent" : null,
    restriction: result.gameJoinRestriction,
  };
}

export async function listRestrictions(
  credentials: Credentials,
  args: { universeId: string; limit: number },
): Promise<Record<string, unknown>> {
  const { items } = await paged<{
    user?: string;
    updateTime?: string;
    gameJoinRestriction?: { active?: boolean; duration?: string; displayReason?: string };
  }>(credentials, {
    path: `/cloud/v2/universes/${encodeURIComponent(args.universeId)}/user-restrictions`,
    scope: "universe.user-restriction:read",
    field: "userRestrictions",
    limit: args.limit,
  });

  return {
    items: items.map((entry) => ({
      user: entry.user?.replace("users/", ""),
      active: entry.gameJoinRestriction?.active ?? false,
      duration: entry.gameJoinRestriction?.duration ?? "permanent",
      reason: entry.gameJoinRestriction?.displayReason,
      updated: entry.updateTime,
    })),
    count: items.length,
  };
}

/** Looks up a user: the id-to-name step almost every other call needs. */
export async function getUser(
  credentials: Credentials,
  userId: string,
): Promise<Record<string, unknown>> {
  return call<Record<string, unknown>>(credentials, {
    path: `/cloud/v2/users/${encodeURIComponent(userId)}`,
    scope: "user.advanced:read",
  });
}

/** What a user owns: passes, badges, assets, private servers. */
export async function getInventory(
  credentials: Credentials,
  args: { userId: string; limit: number; filter?: string },
): Promise<Record<string, unknown>> {
  const { items } = await paged<Record<string, unknown>>(credentials, {
    path: `/cloud/v2/users/${encodeURIComponent(args.userId)}/inventory-items`,
    query: { filter: args.filter },
    scope: "user.inventory-item:read",
    field: "inventoryItems",
    limit: args.limit,
  });
  return { userId: args.userId, items, count: items.length };
}

/**
 * How many uploads are left before Roblox starts refusing them.
 *
 * Audio is the one that bites: ten a month unverified. Worth checking before a
 * batch rather than discovering it on the eleventh.
 */
export async function assetQuotas(
  credentials: Credentials,
): Promise<Record<string, unknown>> {
  const { items } = await paged<{
    quotaType?: string;
    assetType?: string;
    usage?: number;
    capacity?: number;
    expirationTime?: string;
  }>(credentials, {
    path: `/cloud/v2/users/${encodeURIComponent(credentials.creatorId)}/asset-quotas`,
    scope: "assets:write",
    field: "assetQuotas",
    limit: 50,
  });

  return {
    items: items
      .filter((entry) => entry.quotaType === "RATE_LIMIT_UPLOAD")
      .map((entry) => {
        // Roblox sends capacity as a STRING ("2000"). Subtracting from it works
        // by coercion and would stop working the day they send a number, so it
        // is converted rather than relied upon.
        const capacity = entry.capacity === undefined ? undefined : Number(entry.capacity);
        const used = Number(entry.usage ?? 0);
        return {
          assetType: entry.assetType,
          used,
          capacity,
          remaining: capacity === undefined ? undefined : capacity - used,
          resets: entry.expirationTime,
        };
      }),
  };
}
