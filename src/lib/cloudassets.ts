import { readFile, stat } from "node:fs/promises";
import { basename, extname, resolve } from "node:path";
import type { Credentials } from "./credentials.js";
import { ToolError } from "./errors.js";
import { call } from "./opencloud.js";

/**
 * Putting local files into Roblox: upload, grant, publish.
 *
 * All three go out over Open Cloud rather than through the plugin. Studio's
 * HttpService cannot carry a creator API key without shipping it into the place
 * file, and two of the three endpoints are multipart or raw-binary, which
 * HttpService cannot build at all. The server already has the file on disk, so
 * it does the work and hands Studio nothing but an id.
 *
 * They live behind the `assets` tool with everything else that moves content
 * between disk, the cloud and the place — `search`, `peek`, `insert`, `bake`.
 * One noun, one tool.
 */
const ASSETS_ENDPOINT = "/assets/v1/assets";
const OPERATIONS_ENDPOINT = "/assets/v1/operations";
const PERMISSIONS_ENDPOINT = "/asset-permissions-api/v1/assets/permissions";

/** Open Cloud's cap, per call. */
const MAX_BYTES = 20 * 1024 * 1024;

/**
 * Moderation runs before an asset is usable and it is not instant. Roblox hands
 * back an operation to poll rather than the asset. Give up well before an
 * agent's patience runs out and say what happened, rather than reporting a
 * failure for something that is merely slow.
 */
const POLL_TIMEOUT_MS = 90_000;
const POLL_INTERVAL_MS = 2_000;

/**
 * Extension to (assetType, content type).
 *
 * Roblox validates both and rejects a mismatch with a message naming neither.
 * Derived from the file rather than asked for: an agent picking "Model" for a
 * .png costs a round trip and a confusing error.
 */
const KINDS: Record<string, { assetType: string; contentType: string }> = {
  ".mp3": { assetType: "Audio", contentType: "audio/mpeg" },
  ".ogg": { assetType: "Audio", contentType: "audio/ogg" },
  ".wav": { assetType: "Audio", contentType: "audio/wav" },
  ".flac": { assetType: "Audio", contentType: "audio/flac" },
  ".png": { assetType: "Decal", contentType: "image/png" },
  ".jpg": { assetType: "Decal", contentType: "image/jpeg" },
  ".jpeg": { assetType: "Decal", contentType: "image/jpeg" },
  ".bmp": { assetType: "Decal", contentType: "image/bmp" },
  ".tga": { assetType: "Decal", contentType: "image/tga" },
  ".fbx": { assetType: "Model", contentType: "model/fbx" },
  ".gltf": { assetType: "Model", contentType: "model/gltf+json" },
  ".glb": { assetType: "Model", contentType: "model/gltf-binary" },
  ".mp4": { assetType: "Video", contentType: "video/mp4" },
  ".mov": { assetType: "Video", contentType: "video/mov" },
};

interface Operation {
  path?: string;
  done?: boolean;
  response?: {
    assetId?: string;
    displayName?: string;
    moderationResult?: { moderationState?: string };
  };
  error?: { message?: string };
  message?: string;
}

async function readLocal(
  file: string,
  allowed?: string[],
): Promise<{ path: string; bytes: Uint8Array<ArrayBuffer>; extension: string }> {
  const path = resolve(file);
  let size: number;
  try {
    size = (await stat(path)).size;
  } catch {
    throw new ToolError(
      "NO_FILE",
      `There is no file at ${path}.`,
      "Give an absolute path, or one relative to where the server was started.",
    );
  }
  if (size === 0) throw new ToolError("EMPTY_FILE", `${path} is empty.`);
  if (size > MAX_BYTES) {
    throw new ToolError(
      "TOO_BIG",
      `${path} is ${(size / 1024 / 1024).toFixed(1)}MB; the limit is 20MB.`,
    );
  }

  const extension = extname(path).toLowerCase();
  if (allowed && !allowed.includes(extension)) {
    throw new ToolError(
      "WRONG_KIND",
      `This takes ${allowed.join(" or ")}, not ${extension || "a file with no extension"}.`,
    );
  }
  const raw = await readFile(path);
  // Copied into a plain ArrayBuffer: Node hands back a Buffer over a pooled,
  // possibly shared allocation, which neither fetch nor Blob will accept here.
  const bytes = new Uint8Array(new ArrayBuffer(raw.byteLength));
  bytes.set(raw);
  return { path, bytes, extension };
}

export async function uploadAsset(
  credentials: Credentials,
  args: { file: string; name?: string; description?: string; assetType?: string },
): Promise<Record<string, unknown>> {
  const { path, bytes, extension } = await readLocal(args.file);
  const kind = KINDS[extension];
  if (!kind) {
    throw new ToolError(
      "WRONG_KIND",
      `Roblox does not take ${extension || "files with no extension"} through Open Cloud.`,
      `It takes: ${Object.keys(KINDS).join(", ")}.`,
    );
  }
  const assetType = args.assetType ?? kind.assetType;

  const form = new FormData();
  form.append(
    "request",
    JSON.stringify({
      assetType,
      displayName: args.name ?? basename(path, extension),
      description: args.description ?? "",
      creationContext: { creator: { [credentials.creatorField]: credentials.creatorId } },
    }),
  );
  form.append("fileContent", new Blob([bytes], { type: kind.contentType }), basename(path));

  const started = await call<Operation>(credentials, {
    method: "POST",
    path: ASSETS_ENDPOINT,
    body: form,
    scope: "assets:write",
  });
  if (!started.path) {
    throw new ToolError(
      "NO_OPERATION",
      "Roblox accepted the upload but did not say where to track it.",
      "Check the Development Items tab on the Creator Dashboard.",
    );
  }

  const finished = await poll(credentials, started.path);
  if (finished.error || !finished.response?.assetId) {
    throw new ToolError(
      "UPLOAD_REJECTED",
      `The upload failed moderation or validation: ${
        finished.error?.message ?? finished.message ?? "no reason given"
      }`,
    );
  }

  const assetId = finished.response.assetId;
  /**
   * Roblox spells the verdict two ways and the docs only show one.
   *
   * The published example returns `MODERATION_STATE_APPROVED`; the live API
   * returns a bare `Approved`. Comparing against the documented spelling alone
   * made every successful upload read as pending -- measured on a real upload,
   * not assumed -- so both are accepted and the flag is computed once here
   * rather than re-derived by each caller.
   */
  const state = finished.response.moderationResult?.moderationState ?? "unknown";
  return {
    assetId,
    approved: state === "Approved" || state === "MODERATION_STATE_APPROVED",
    assetType,
    uri: `rbxassetid://${assetId}`,
    name: finished.response.displayName,
    moderation: state,
    uploadedAs: `${credentials.creatorField} ${credentials.creatorId}`,
    file: path,
  };
}

async function poll(credentials: Credentials, operationPath: string): Promise<Operation> {
  const id = operationPath.replace(/^operations\//, "");
  const deadline = Date.now() + POLL_TIMEOUT_MS;

  for (;;) {
    const operation = await call<Operation>(credentials, {
      path: `${OPERATIONS_ENDPOINT}/${id}`,
      scope: "assets:write",
    });
    if (operation.done) return operation;
    if (Date.now() >= deadline) {
      throw new ToolError(
        "STILL_PROCESSING",
        `Still processing after ${POLL_TIMEOUT_MS / 1000}s. It has not failed — ` +
          "moderation can take longer.",
        "Check the Development Items tab on the Creator Dashboard in a minute.",
      );
    }
    await new Promise((done) => setTimeout(done, POLL_INTERVAL_MS));
  }
}

/**
 * Grants a game or a person permission to use assets you own.
 *
 * Worth being precise about, because the surrounding folklore is wrong. Asset
 * Privacy — the Restricted-by-default setting — applies only to Images, Decals
 * and Meshes, and your own assets always work in your own published games. So
 * this is NOT needed to make audio you uploaded play in your own experience.
 *
 * What it is for: a game you do not own — a collaborator's place, a group game
 * you are not the owner of — or handing a specific person the right to use your
 * asset in theirs. That is a real workflow with no other route from here: the
 * alternative is the Creator Dashboard, one asset at a time.
 *
 * A grant to a game is PERMANENT. Roblox does not let it be revoked, so this is
 * gated on an explicit confirmation rather than treated as an ordinary write.
 */
export async function grantAssets(
  credentials: Credentials,
  args: { assetIds: number[]; subjectType: "Universe" | "User" | "Group"; subjectId: string },
): Promise<Record<string, unknown>> {
  const result = await call<{
    successAssetIds?: number[];
    errors?: Array<{ assetId?: number; code?: string }>;
  }>(credentials, {
    method: "PATCH",
    path: PERMISSIONS_ENDPOINT,
    body: {
      subjectType: args.subjectType,
      subjectId: args.subjectId,
      // "Use" is the only action valid for Audio, Decal, Image, Mesh, MeshPart
      // and Video against a Universe; the others are for models and places.
      action: "Use",
      requests: args.assetIds.map((assetId) => ({ assetId })),
    },
    scope: "asset-permissions:write",
  });

  const granted = result.successAssetIds ?? [];
  const errors = result.errors ?? [];
  return {
    granted,
    grantedCount: granted.length,
    subject: `${args.subjectType} ${args.subjectId}`,
    // AlreadyHasAccess is reported as an error by Roblox and is not one; a
    // caller re-running a grant should not be told it failed.
    failed: errors
      .filter((entry) => entry.code !== "AlreadyHasAccess")
      .map((entry) => ({ assetId: entry.assetId, reason: entry.code })),
    alreadyHad: errors
      .filter((entry) => entry.code === "AlreadyHasAccess")
      .map((entry) => entry.assetId),
  };
}

/**
 * Publishes a .rbxl / .rbxlx from disk to a place.
 *
 * `versionType=Saved` saves without publishing, which is the safe default: it
 * puts the file on Roblox and leaves what players are in alone. Publishing is
 * the thing that changes the live game, so it is asked for explicitly.
 *
 * Roblox documents a real limitation and it is not obvious from any error: this
 * API does not update EditableImage, EditableMesh, PartOperation,
 * SurfaceAppearance or BaseWrap instances. A place using any of them has to be
 * published from Studio, and the API will report success regardless.
 */
export async function publishPlace(
  credentials: Credentials,
  args: { file: string; universeId: string; placeId: string; publish: boolean },
): Promise<Record<string, unknown>> {
  const { path, bytes, extension } = await readLocal(args.file, [".rbxl", ".rbxlx"]);

  const result = await call<{ versionNumber?: number }>(credentials, {
    method: "POST",
    path: `/universes/v1/${args.universeId}/places/${args.placeId}/versions`,
    query: { versionType: args.publish ? "Published" : "Saved" },
    raw: {
      bytes,
      contentType: extension === ".rbxlx" ? "application/xml" : "application/octet-stream",
    },
    scope: "universe-places:write",
    // A place file is megabytes and the upload is one request.
    timeoutMs: 180_000,
  });

  return {
    placeId: args.placeId,
    universeId: args.universeId,
    versionNumber: result.versionNumber,
    published: args.publish,
    file: path,
    note: args.publish
      ? "This is live to players now."
      : 'Saved as a new version but NOT live. Pass publish: true to release it.',
    caveat:
      "Roblox's publishing API does not update EditableImage, EditableMesh, " +
      "PartOperation, SurfaceAppearance or BaseWrap instances. If the place uses " +
      "any of those, publish from Studio instead — this call reports success " +
      "either way.",
  };
}
