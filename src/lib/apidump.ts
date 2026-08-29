import { mkdir, readFile, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";

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

function cachePath(): string {
  return join(tmpdir(), "roblox-studio-mcp", "api-dump.json");
}

async function readCache(): Promise<ApiDump | null> {
  try {
    const raw = await readFile(cachePath(), "utf8");
    const cached = JSON.parse(raw) as CacheFile;
    if (Date.now() - cached.fetchedAt > CACHE_TTL_MS) return null;
    return cached.dump;
  } catch {
    return null;
  }
}

async function writeCache(dump: ApiDump): Promise<void> {
  try {
    const path = cachePath();
    await mkdir(join(path, ".."), { recursive: true });
    await writeFile(path, JSON.stringify({ fetchedAt: Date.now(), dump }), "utf8");
  } catch {
    // A read-only or full temp directory only costs us the cache, not the feature.
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
  loaded ??= (async () => {
    const cached = await readCache();
    if (cached) return cached;

    try {
      const response = await fetch(DUMP_URL, {
        signal: AbortSignal.timeout(15_000),
      });
      if (!response.ok) return null;
      const dump = (await response.json()) as ApiDump;
      await writeCache(dump);
      return dump;
    } catch {
      // Stale beats absent: fall back to an expired cache when the network is
      // unavailable, since engine APIs change slowly.
      try {
        const raw = await readFile(cachePath(), "utf8");
        return (JSON.parse(raw) as CacheFile).dump;
      } catch {
        return null;
      }
    }
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
  "Rotation",
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
      !GENERIC_BASES.has(property.declaredBy) && !property.deprecated && !property.readOnly,
  );

  // Classes that add nothing of their own (Folder, Model) fall back to the full
  // set, minus the noise, rather than returning just the name.
  const chosen = useful.length > 0 ? useful : all.filter((p) => !p.deprecated && !p.readOnly);

  const ranked = rankProperties(chosen.map((property) => property.name));
  const names = ranked.slice(0, STANDARD_LIMIT);
  return ["Name", ...names.filter((name) => name !== "Name")];
}

/** True when the dump knows this class. False also covers "dump unavailable". */
export async function isKnownClass(className: string): Promise<boolean> {
  const dump = await loadApiDump();
  return dump?.Classes.some((entry) => entry.Name === className) ?? false;
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
