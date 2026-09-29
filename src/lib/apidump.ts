import { mkdir, readFile, rename, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";

/**
 * Live Roblox API reflection, sourced from the official API dump.
 *
 * Every other Studio MCP server hardcodes a property list per class, which goes
 * stale the moment Roblox ships an engine update — the agent then gets told a
 * real property "does not exist". Here the dump is downloaded once a day and
 * cached, so property enumeration, validation and "did you mean" suggestions
 * track whatever engine version the user is actually running.
 *
 * Doing this on the Node side rather than in the plugin keeps it off Studio's
 * HTTP permission prompt and lets the cache survive Studio restarts.
 */

/** Mirror of the dump Roblox publishes for each Studio build, updated per release. */
const DUMP_URL =
  "https://raw.githubusercontent.com/MaximumADHD/Roblox-Client-Tracker/roblox/API-Dump.json";

const CACHE_TTL_MS = 24 * 60 * 60 * 1000;

interface ApiMember {
  MemberType: string;
  Name: string;
  ValueType?: { Name: string; Category: string };
  Security?: string | { Read: string; Write: string };
  Tags?: string[];
  Serialization?: { CanLoad: boolean; CanSave: boolean };
}

interface ApiClass {
  Name: string;
  Superclass: string;
  MemberType?: string;
  Members: ApiMember[];
  Tags?: string[];
}

interface ApiDump {
  Classes: ApiClass[];
  Enums: Array<{ Name: string; Items: Array<{ Name: string; Value: number }> }>;
}

export interface PropertyInfo {
  name: string;
  valueType: string;
  category: string;
  /** Class that declares it, so callers can prefer own properties over inherited. */
  declaredBy: string;
  readOnly: boolean;
  deprecated: boolean;
}

interface CacheFile {
  fetchedAt: number;
  dump: ApiDump;
}

let loaded: Promise<ApiDump | null> | null = null;
let classIndex: Map<string, ApiClass> | null = null;
const propertyCache = new Map<string, PropertyInfo[]>();
const restrictionCache = new Map<string, Map<string, PropertyRestriction>>();

/** When the loaded dump is next due a refresh; 0 while none is loaded. */
let refreshAt = 0;
let refreshing = false;

function cachePath(): string {
  return join(tmpdir(), "roblox-studio-mcp", "api-dump.json");
}

async function readCache(): Promise<{ dump: ApiDump; fetchedAt: number; fresh: boolean } | null> {
  try {
    const raw = await readFile(cachePath(), "utf8");
    const cached = JSON.parse(raw) as CacheFile;
    if (!Array.isArray(cached?.dump?.Classes)) return null;
    const fetchedAt = typeof cached.fetchedAt === "number" ? cached.fetchedAt : 0;
    return { dump: cached.dump, fetchedAt, fresh: Date.now() - fetchedAt <= CACHE_TTL_MS };
  } catch {
    return null;
  }
}

async function download(): Promise<ApiDump | null> {
  try {
    const response = await fetch(DUMP_URL, { signal: AbortSignal.timeout(15_000) });
    if (!response.ok) return null;
    const dump = (await response.json()) as ApiDump;
    if (!Array.isArray(dump?.Classes)) return null;
    await writeCache(dump);
    return dump;
  } catch {
    return null;
  }
}

/** How long after a failed download before the next call may try again. */
const RETRY_AFTER_MS = 60_000;

async function writeCache(dump: ApiDump): Promise<void> {
  // Written beside the real file and renamed over it. Every server process on
  // the machine shares this path, and one reading it mid-write saw a truncated
  // document, which reads as "no cache" and costs a 2.4MB download.
  const path = cachePath();
  const staging = `${path}.${process.pid}.tmp`;
  try {
    await mkdir(dirname(path), { recursive: true });
    await writeFile(staging, JSON.stringify({ fetchedAt: Date.now(), dump }), "utf8");
    await rename(staging, path);
  } catch {
    // A read-only or full temp directory only costs us the cache, not the feature.
    await rm(staging, { force: true }).catch(() => undefined);
  }
}

/**
 * Downloads a newer dump and swaps it in for the one already serving calls.
 *
 * A server process lives as long as the MCP client that started it -- days, for
 * an editor left open -- so a dump loaded at startup used to be the dump for the
 * whole life of the process. The daily expiry only ever refreshed the copy on
 * disk for the NEXT process, which meant a class or property added by a Roblox
 * update was reported as a typo until somebody restarted their editor.
 *
 * Everything derived from the dump is dropped with it. Failing leaves the old
 * one in place and tries again after a short wait, because an outdated dump is
 * still far better than none.
 */
async function refresh(): Promise<void> {
  if (refreshing) return;
  refreshing = true;
  try {
    const fresh = await download();
    if (fresh === null) {
      refreshAt = Date.now() + RETRY_AFTER_MS;
      return;
    }
    classIndex = null;
    propertyCache.clear();
    restrictionCache.clear();
    loaded = Promise.resolve(fresh);
    refreshAt = Date.now() + CACHE_TTL_MS;
  } finally {
    refreshing = false;
  }
}

/**
 * Returns the API dump, or null if it cannot be obtained.
 *
 * Null is a supported state, not a failure: the server must keep working
 * offline, so callers fall back to whatever the plugin reports about an
 * instance rather than refusing to answer.
 */
export function loadApiDump(): Promise<ApiDump | null> {
  if (refreshAt !== 0 && Date.now() >= refreshAt) void refresh();

  loaded ??= (async () => {
    //[[ A stale cache is served at once and refreshed behind the call.
    //
    // Engine APIs change slowly, and the refresh used to sit in the path of
    // whichever tool call first needed the dump after the daily expiry: a
    // 2.4MB download, up to 15s on a slow network, billed to one `create`.
    // The fresh copy is swapped in when it arrives, and lands on disk for the
    // next process.
    //]]
    const cached = await readCache();
    if (cached) {
      refreshAt = cached.fetchedAt + CACHE_TTL_MS;
      if (!cached.fresh) void refresh();
      return cached.dump;
    }

    const dump = await download();
    if (dump === null) {
      // Offline is not forever. Without this, one failed download turned
      // property checking off until the server was restarted.
      setTimeout(() => {
        loaded = null;
      }, RETRY_AFTER_MS).unref();
    } else {
      refreshAt = Date.now() + CACHE_TTL_MS;
    }
    return dump;
  })();
  return loaded;
}

/** The two identities a plugin actually runs with. Anything else is out of reach. */
const PLUGIN_REACHABLE = new Set(["None", "PluginSecurity"]);

/** Security is either one level for both directions, or one per direction. */
function securityOf(member: ApiMember): { read: string; write: string } {
  const security = member.Security;
  if (typeof security === "string") return { read: security, write: security };
  return { read: security?.Read ?? "None", write: security?.Write ?? "None" };
}

/**
 * The dump's classes keyed by name, built once. Two walkers need it now, and
 * rebuilding a map over ~800 classes per lookup was already wasteful with one.
 */
async function classesByName(): Promise<Map<string, ApiClass> | null> {
  if (classIndex) return classIndex;
  const dump = await loadApiDump();
  if (!dump) return null;
  classIndex = new Map(dump.Classes.map((entry) => [entry.Name, entry]));
  return classIndex;
}

function isReadable(member: ApiMember): boolean {
  if (member.MemberType !== "Property") return false;

  // PluginSecurity is fine — the plugin runs with it. Anything higher is not
  // reachable from a plugin and would just produce errors if we offered it.
  if (!PLUGIN_REACHABLE.has(securityOf(member).read)) return false;

  // Only `NotScriptable` actually blocks Luau access. `Hidden` means "not
  // serialized / not shown in the Properties widget", which is true of
  // BasePart.Position and .Orientation — both derived from CFrame, both
  // perfectly scriptable, and both among the properties agents reach for most.
  // Filtering on `Hidden` would silently hide them.
  return !(member.Tags ?? []).includes("NotScriptable");
}

/**
 * A property the dump declares but plugin identity cannot fully use.
 *
 * These are dropped from `propertiesOf`, which is right for enumeration and
 * wrong for validation: a name that exists at a higher security level then
 * looks exactly like a typo, and the agent is told to go and look for a
 * property it can already see in Studio's Properties panel. Keeping them here,
 * separately, lets callers tell "no such property" from "not yours to touch".
 */
export interface PropertyRestriction {
  name: string;
  declaredBy: string;
  valueType: string;
  /**
   * The identity the engine demands, with the "Security" suffix trimmed so it
   * reads the way the engine's own error does ("lacking capability
   * RobloxScript"). Empty when the block is `NotScriptable` rather than security.
   */
  capability: string;
  /** What plugin identity cannot do with it. */
  blocked: "read" | "write" | "read or write";
  /** True when the engine exposes it to no script at all, at any identity. */
  notScriptable: boolean;
  /** False when the write is blocked — the only case that stops a `modify`. */
  writable: boolean;
}

function restrictionOf(member: ApiMember, declaredBy: string): PropertyRestriction | null {
  const notScriptable = (member.Tags ?? []).includes("NotScriptable");
  const { read, write } = securityOf(member);
  const readBlocked = !PLUGIN_REACHABLE.has(read);
  const writeBlocked = !PLUGIN_REACHABLE.has(write);
  if (!notScriptable && !readBlocked && !writeBlocked) return null;

  return {
    name: member.Name,
    declaredBy,
    valueType: member.ValueType?.Name ?? "unknown",
    capability: (writeBlocked ? write : readBlocked ? read : "").replace(/Security$/, ""),
    blocked:
      notScriptable || (readBlocked && writeBlocked)
        ? "read or write"
        : readBlocked
          ? "read"
          : "write",
    notScriptable,
    writable: !notScriptable && !writeBlocked,
  };
}

/**
 * Every property of a class that plugin identity cannot fully use, by name.
 *
 * Deliberately a sibling of `propertiesOf` rather than part of it: enumeration
 * wants only what an agent can act on, validation wants to know these exist.
 */
export async function restrictionsOf(
  className: string,
): Promise<Map<string, PropertyRestriction>> {
  const cached = restrictionCache.get(className);
  if (cached) return cached;

  const byName = await classesByName();
  const found = new Map<string, PropertyRestriction>();
  // No dump is not the same as "nothing is restricted", so this is not cached:
  // the next call may have the dump and should get a real answer.
  if (!byName) return found;

  const seen = new Set<string>();
  let current = byName.get(className);
  while (current) {
    for (const member of current.Members) {
      if (member.MemberType !== "Property" || seen.has(member.Name)) continue;
      seen.add(member.Name);
      const restriction = restrictionOf(member, current.Name);
      if (restriction) found.set(member.Name, restriction);
    }
    current = current.Superclass ? byName.get(current.Superclass) : undefined;
  }

  restrictionCache.set(className, found);
  return found;
}

/** Why a property is out of reach, as a clause that follows "exists but is". */
export function describeRestriction(restriction: PropertyRestriction): string {
  if (restriction.notScriptable) {
    return "marked NotScriptable, so no script or plugin can set it";
  }
  return (
    `restricted to ${restriction.capability} identity, so no plugin can ` +
    (restriction.blocked === "read" ? "read it" : "set it")
  );
}

/**
 * Every readable property of a class, walking the inheritance chain. Ordered
 * most-derived first so callers can take a prefix and get the properties that
 * actually characterise the instance.
 */
export async function propertiesOf(className: string): Promise<PropertyInfo[]> {
  const cached = propertyCache.get(className);
  if (cached) return cached;

  const byName = await classesByName();
  if (!byName) return [];

  const properties: PropertyInfo[] = [];
  const seen = new Set<string>();

  let current = byName.get(className);
  while (current) {
    for (const member of current.Members) {
      if (!isReadable(member) || seen.has(member.Name)) continue;
      seen.add(member.Name);
      const tags = member.Tags ?? [];
      properties.push({
        name: member.Name,
        valueType: member.ValueType?.Name ?? "unknown",
        category: member.ValueType?.Category ?? "unknown",
        declaredBy: current.Name,
        readOnly: tags.includes("ReadOnly"),
        deprecated: tags.includes("Deprecated"),
      });
    }
    current = current.Superclass ? byName.get(current.Superclass) : undefined;
  }

  propertyCache.set(className, properties);
  return properties;
}

/** Handled by the build spec itself, never as a property. */
const STRUCTURAL = new Set(["Name", "Parent", "ClassName", "Archivable"]);

/**
 * Values that restate another property, and runtime state that is not part of
 * what was built. A build file holding both halves of a pair lets an edit to
 * one be overwritten by the other -- `BrickColor` applied after `Color` snaps
 * the colour to the nearest brick colour -- so only the real half is kept.
 */
const DERIVED = new Set([
  "BrickColor", // Color
  "Rotation", // CFrame
  "Axis", // Attachment.CFrame
  "SecondaryAxis",
  "WorldAxis",
  "WorldSecondaryAxis",
  "WorldCFrame",
  "AssemblyLinearVelocity", // physics state
  "AssemblyAngularVelocity",
  "Jump", // Humanoid state
  "Sit",
  "PlatformStand",
  "TargetPoint",
  "WalkToPart",
  "WalkToPoint",
  "ColorMap", // Decal.Texture
  "ColorMapContent",
]);

/**
 * Properties worth writing into a build file: writable at plugin identity,
 * scriptable, not deprecated, and not derived from another property.
 *
 * `Hidden` is what marks the derived ones -- `BasePart.Position` and
 * `Orientation` restate `CFrame`, and the legacy `Font` restates `FontFace`.
 * The dump's "saved" flag looks like the better signal and is not: `Size`,
 * `Color`, `UICorner.CornerRadius` and `WeldConstraint.Part0` are all marked
 * unsaved, because the file keeps them under an internal twin, and filtering
 * on it rebuilt every part at the default size.
 */
export async function buildableProperties(className: string): Promise<PropertyInfo[]> {
  const byName = await classesByName();
  if (!byName) return [];
  const properties: PropertyInfo[] = [];
  const seen = new Set<string>();
  let current = byName.get(className);
  while (current) {
    for (const member of current.Members) {
      if (member.MemberType !== "Property" || seen.has(member.Name)) continue;
      seen.add(member.Name);
      const tags = member.Tags ?? [];
      const security = securityOf(member);
      if (
        STRUCTURAL.has(member.Name) ||
        !PLUGIN_REACHABLE.has(security.read) ||
        !PLUGIN_REACHABLE.has(security.write) ||
        tags.includes("NotScriptable") ||
        tags.includes("ReadOnly") ||
        tags.includes("Deprecated") ||
        tags.includes("Hidden") ||
        DERIVED.has(member.Name)
      ) {
        continue;
      }
      properties.push({
        name: member.Name,
        valueType: member.ValueType?.Name ?? "unknown",
        category: member.ValueType?.Category ?? "unknown",
        declaredBy: current.Name,
        readOnly: false,
        deprecated: false,
      });
    }
    current = current.Superclass ? byName.get(current.Superclass) : undefined;
  }
  return properties;
}

/** Bases that describe every instance and so distinguish none of them. */
const GENERIC_BASES = new Set(["Instance", "PVInstance"]);

/** Ceiling for `standard`, so wide classes like Humanoid stay affordable. */
const STANDARD_LIMIT = 25;

/**
 * Properties that lead, when the class has them.
 *
 * The dump lists members alphabetically, so a plain prefix of `BasePart` would
 * cut off at `Reflectance` and lose Size, Position and Transparency — the three
 * an agent reaches for most. This is the one place a curated list is worth its
 * maintenance cost; everything after it still comes straight from the dump, so
 * new engine properties appear without a code change.
 */
const PRIORITY_PROPERTIES = [
  "Size",
  "Position",
  "CFrame",
  "Orientation",
  "Anchored",
  "CanCollide",
  "Transparency",
  "Color",
  "BrickColor",
  "Material",
  "Shape",
  "Visible",
  "Enabled",
  "Disabled",
  "Text",
  "Value",
  "Source",
  "Image",
  "MeshId",
  "SoundId",
  "Health",
  "MaxHealth",
  "WalkSpeed",
  "PrimaryPart",
  "RunContext",
];

/**
 * Left out of `standard` although the dump offers them, because they were
 * filling slots on every part while answering nothing: `Rotation` restates
 * `Orientation` in the older axis order, the six surface types are legacy
 * studs-and-inlets data, and assembly velocities read 0 on anything anchored
 * (`inspect physics=true` is where motion belongs). `full` still has them all.
 */
const STANDARD_NOISE = new Set([
  "Rotation",
  "AssemblyLinearVelocity",
  "AssemblyAngularVelocity",
  "AudioCanCollide",
  "LocalTransparencyModifier",
  "BackSurface",
  "BottomSurface",
  "FrontSurface",
  "LeftSurface",
  "RightSurface",
  "TopSurface",
]);

/** Sorts priority names first (in listed order), leaving the rest untouched. */
function rankProperties(names: string[]): string[] {
  const rank = new Map(PRIORITY_PROPERTIES.map((name, index) => [name, index]));
  return [...names].sort((a, b) => {
    const left = rank.get(a) ?? Number.MAX_SAFE_INTEGER;
    const right = rank.get(b) ?? Number.MAX_SAFE_INTEGER;
    if (left !== right) return left - right;
    return 0; // ties keep dump order, which is most-derived class first
  });
}

/**
 * The properties worth showing at `detail: "standard"`.
 *
 * Heuristic: everything the class and its non-generic bases declare — for a
 * Part that is `Shape` plus all of `BasePart` (Size, Anchored, CFrame,
 * Material...), which is exactly what an agent needs to reason about it.
 * `Instance` itself is skipped because `Archivable` and `Parent` say nothing
 * about a specific instance, and the path already encodes the parent.
 *
 * Deprecated and read-only entries are dropped: an agent cannot act on them,
 * and `detail: "full"` is there when the whole surface is genuinely wanted.
 */
export async function standardProperties(className: string): Promise<string[]> {
  const all = await propertiesOf(className);
  if (all.length === 0) return [];

  const useful = all.filter(
    (property) =>
      !GENERIC_BASES.has(property.declaredBy) &&
      !property.deprecated &&
      !property.readOnly &&
      !STANDARD_NOISE.has(property.name),
  );

  // Classes that add nothing of their own (Folder, Model) fall back to the full
  // set, minus the noise, rather than returning just the name.
  const chosen = useful.length > 0 ? useful : all.filter((p) => !p.deprecated && !p.readOnly);

  const ranked = rankProperties(chosen.map((property) => property.name));
  const names = ranked.slice(0, STANDARD_LIMIT);
  return ["Name", ...names.filter((name) => name !== "Name")];
}

/**
 * Suggests real property names close to a mistyped one. Turns a dead-end
 * "property does not exist" into a correction the agent can apply immediately.
 */
export async function suggestProperty(
  className: string,
  attempted: string,
): Promise<string[]> {
  const all = await propertiesOf(className);
  const target = attempted.toLowerCase();
  return all
    .map((property) => ({
      name: property.name,
      distance: editDistance(target, property.name.toLowerCase()),
    }))
    .filter((entry) => entry.distance <= Math.max(2, Math.floor(target.length / 3)))
    .sort((a, b) => a.distance - b.distance)
    .slice(0, 5)
    .map((entry) => entry.name);
}

/** Suggests real class names close to a mistyped one, for `create`. */
export async function suggestClass(attempted: string): Promise<string[]> {
  const dump = await loadApiDump();
  if (!dump) return [];
  const target = attempted.toLowerCase();
  return dump.Classes.map((entry) => ({
    name: entry.Name,
    distance: editDistance(target, entry.Name.toLowerCase()),
  }))
    .filter((entry) => entry.distance <= Math.max(2, Math.floor(target.length / 3)))
    .sort((a, b) => a.distance - b.distance)
    .slice(0, 5)
    .map((entry) => entry.name);
}

/** Levenshtein distance, two-row variant. Inputs here are short identifiers. */
function editDistance(a: string, b: string): number {
  if (a === b) return 0;
  if (a.length === 0) return b.length;
  if (b.length === 0) return a.length;

  let previous = Array.from({ length: b.length + 1 }, (_, i) => i);
  let current = new Array<number>(b.length + 1);

  for (let i = 1; i <= a.length; i++) {
    current[0] = i;
    for (let j = 1; j <= b.length; j++) {
      const substitution = (previous[j - 1] as number) + (a[i - 1] === b[j - 1] ? 0 : 1);
      const deletion = (previous[j] as number) + 1;
      const insertion = (current[j - 1] as number) + 1;
      current[j] = Math.min(substitution, deletion, insertion);
    }
    [previous, current] = [current, previous];
  }
  return previous[b.length] as number;
}
