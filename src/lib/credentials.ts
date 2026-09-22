import { chmod, mkdir, readFile, rename, rm, writeFile } from "node:fs/promises";
import { homedir } from "node:os";
import { join } from "node:path";

/**
 * Where the Open Cloud key lives, and the rules about handling it.
 *
 * A Roblox API key with `assets:write` can publish assets under the user's own
 * name, and Roblox counts those against a real monthly quota. So it is treated
 * as a password everywhere in this file: it is never returned to a caller, never
 * logged, never put in a tool result, and never written anywhere that travels.
 *
 * Not `plugin:SetSetting`, which was the obvious place to put it. Plugin
 * settings are stored per place and move with the .rbxl: into version control,
 * into a Team Create session, to whoever the place is shared with. A file under
 * the user's own home directory does not move at all.
 *
 * The environment still wins over the file. Someone running this in CI, or
 * sharing one machine, wants the key to come from the process they started and
 * to leave nothing behind — so `ROBLOX_API_KEY` is checked first and the file is
 * only consulted when it is unset.
 */
const DIRECTORY = join(homedir(), ".rbx-studio-mcp");
const FILE = join(DIRECTORY, "credentials.json");

export interface Credentials {
  apiKey: string;
  creatorId: string;
  creatorField: "userId" | "groupId";
  /**
   * The game every universe-scoped call acts on. Optional: uploads and grants
   * do not need one, live data stores and remote Luau cannot work without one.
   */
  universeId?: string;
  placeId?: string;
  /** Where the values came from, so the panel can say so. */
  source: "environment" | "file";
}

interface Stored {
  apiKey?: string;
  userId?: string;
  groupId?: string;
  universeId?: string;
  placeId?: string;
}

/** What is set, with nothing secret in it. Safe to print and to return. */
export interface CredentialStatus {
  hasKey: boolean;
  /** Last four characters only — enough to tell two keys apart, not to use one. */
  keyHint: string | null;
  creatorId: string | null;
  creatorField: "userId" | "groupId" | null;
  universeId: string | null;
  placeId: string | null;
  source: "environment" | "file" | null;
  path: string;
}

async function readStored(): Promise<Stored> {
  try {
    return JSON.parse(await readFile(FILE, "utf8")) as Stored;
  } catch {
    // Absent, unreadable or corrupt all mean the same thing to every caller:
    // nothing is stored. A parse error is not worth failing a tool over.
    return {};
  }
}

async function writeStored(next: Stored): Promise<void> {
  await mkdir(DIRECTORY, { recursive: true, mode: 0o700 });
  /**
   * Written, then narrowed.
   *
   * `mode` on writeFile is masked by the process umask, so it is not on its own
   * a guarantee; chmod after the fact is. On Windows this is close to a no-op —
   * Node maps it to the read-only flag — and the protection there comes from
   * the file sitting inside the user's profile, which is ACL'd to that user.
   * Worth doing anyway: this server runs on macOS and Linux too, where a
   * world-readable key in a home directory is a real exposure.
   */
  // Written beside the real file and renamed over it, so a crash mid-write
  // cannot leave a truncated file that reads back as "nothing stored".
  const staging = `${FILE}.${process.pid}.tmp`;
  await writeFile(staging, `${JSON.stringify(next, null, 2)}\n`, { mode: 0o600 });
  await chmod(staging, 0o600).catch(() => {
    // Best effort: a filesystem that does not do permissions is not a reason to
    // refuse to save.
  });
  await rename(staging, FILE);
}

/**
 * The credentials to upload with, or null when the setup is incomplete.
 *
 * A key with no creator is incomplete, not usable: Roblox rejects the upload
 * with a permissions error that names neither, which is a much worse thing to
 * debug than being told up front.
 */
export async function loadCredentials(): Promise<Credentials | null> {
  const stored = await readStored();
  const envKey = process.env["ROBLOX_API_KEY"]?.trim();
  const envUser = process.env["ROBLOX_USER_ID"]?.trim();
  const envGroup = process.env["ROBLOX_GROUP_ID"]?.trim();

  /**
   * The universe and place fall back to the file even when the key comes from
   * the environment.
   *
   * They are not secrets and they are not part of the credential: someone who
   * exports a key in CI has still told the panel which game they are working
   * on, and making them re-export two public ids to keep that would be a
   * papercut with nothing behind it.
   */
  const universeId = process.env["ROBLOX_UNIVERSE_ID"]?.trim() || stored.universeId;
  const placeId = process.env["ROBLOX_PLACE_ID"]?.trim() || stored.placeId;

  const apiKey = envKey || stored.apiKey;
  if (!apiKey) return null;

  const source = envKey ? "environment" : "file";
  const groupId = envKey ? envGroup : stored.groupId;
  const userId = envKey ? envUser : stored.userId;
  if (!groupId && !userId) return null;

  return {
    apiKey,
    creatorId: (groupId || userId) as string,
    creatorField: groupId ? "groupId" : "userId",
    universeId,
    placeId,
    source,
  };
}

/** What is configured, without the key itself. */
export async function credentialStatus(): Promise<CredentialStatus> {
  const envKey = process.env["ROBLOX_API_KEY"]?.trim();
  const envUser = process.env["ROBLOX_USER_ID"]?.trim();
  const envGroup = process.env["ROBLOX_GROUP_ID"]?.trim();
  const stored = await readStored();

  const apiKey = envKey || stored.apiKey;
  const source = envKey ? "environment" : stored.apiKey ? "file" : null;
  const groupId = envKey ? envGroup : stored.groupId;
  const userId = envKey ? envUser : stored.userId;

  return {
    hasKey: Boolean(apiKey),
    keyHint: apiKey ? apiKey.slice(-4) : null,
    creatorId: groupId || userId || null,
    creatorField: groupId ? "groupId" : userId ? "userId" : null,
    universeId: process.env["ROBLOX_UNIVERSE_ID"]?.trim() || stored.universeId || null,
    placeId: process.env["ROBLOX_PLACE_ID"]?.trim() || stored.placeId || null,
    source,
    path: FILE,
  };
}

/** Remembers which game the universe-scoped calls act on. */
export async function saveTarget(field: "universeId" | "placeId", id: string): Promise<void> {
  const stored = await readStored();
  stored[field] = id;
  await writeStored(stored);
}

export async function saveApiKey(apiKey: string): Promise<void> {
  const stored = await readStored();
  stored.apiKey = apiKey;
  await writeStored(stored);
}

/**
 * Sets the creator, clearing the other kind.
 *
 * Both at once is not a state worth allowing: Roblox takes one creator per
 * upload, and a leftover userId sitting under a groupId is the kind of thing
 * that silently publishes to the wrong account months later.
 */
export async function saveCreator(field: "userId" | "groupId", id: string): Promise<void> {
  const stored = await readStored();
  delete stored.userId;
  delete stored.groupId;
  stored[field] = id;
  await writeStored(stored);
}

/** Deletes the file outright. Nothing is left behind to un-delete. */
export async function forgetCredentials(): Promise<boolean> {
  try {
    await rm(FILE);
    return true;
  } catch {
    return false;
  }
}

/**
 * Asks Roblox whether the key works, without uploading anything.
 *
 * There is no "who am I" endpoint for an API key, so this calls the operations
 * endpoint with an id that cannot exist. A working key gets 404 (or 400); a bad
 * one gets 401 or 403 before Roblox ever looks at the id. That distinction is
 * the whole test, and it costs no quota.
 */
export async function testCredentials(apiKey: string): Promise<{ ok: boolean; detail: string }> {
  let response: Response;
  try {
    response = await fetch("https://apis.roblox.com/assets/v1/operations/0", {
      headers: { "x-api-key": apiKey },
      signal: AbortSignal.timeout(15_000),
    });
  } catch (cause) {
    return { ok: false, detail: `could not reach Roblox: ${(cause as Error).message}` };
  }

  if (response.status === 401) return { ok: false, detail: "Roblox rejected the key (401)" };
  if (response.status === 403) {
    return {
      ok: false,
      detail:
        "Roblox refused the key (403) — usually a missing `assets` permission, " +
        "or your IP is not in the key's allowed list",
    };
  }
  if (response.status === 429) return { ok: true, detail: "the key works (rate limited right now)" };
  return { ok: true, detail: "the key works" };
}

export { FILE as CREDENTIALS_PATH };
