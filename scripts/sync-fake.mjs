/**
 * An in-memory Studio answering the plugin's `sync.*` ops, for the offline
 * sync tests. It keeps the plugin's contracts -- revisions, writes and moves
 * conditional on them, per-item results, change tracking that also reports
 * the echo of sync's own writes -- without any of its Roblox.
 */
import { createHash } from "node:crypto";
import { ToolError } from "../dist/lib/errors.js";

export const fingerprint = (source) => createHash("sha1").update(source).digest("hex").slice(0, 12);

/** A scan from a flat map of script paths, the way the plugin reports one. */
export function scanOf(scripts, folders = {}) {
  const nodes = [];
  const index = new Map();
  const nodeOf = (segments, className) => {
    const key = segments.join(".");
    if (index.has(key)) return index.get(key);
    const parent = segments.length > 1 ? nodeOf(segments.slice(0, -1), folders[segments.slice(0, -1).join(".")] ?? "Folder") : 0;
    nodes.push({ path: key, name: segments.at(-1), className, parent });
    index.set(key, nodes.length);
    return nodes.length;
  };
  const items = [];
  for (const [scriptPath, info] of Object.entries(scripts)) {
    const node = nodeOf(scriptPath.split("."), info.className);
    nodes[node - 1].className = info.className;
    items.push({ node, revision: info.revision, fileSynced: info.fileSynced });
  }
  return { nodes, items, roots: [...new Set(Object.keys(scripts).map((key) => key.split(".")[0]))] };
}

/** `{value, type}` property specs back to plain values, as Studio would store them. */
function untype(spec) {
  const out = { className: spec.className, name: spec.name };
  if (spec.properties) {
    out.properties = Object.fromEntries(
      Object.entries(spec.properties).map(([key, value]) => [key, value && typeof value === "object" && "value" in value ? value.value : value]),
    );
  }
  if (spec.attributes) out.attributes = spec.attributes;
  if (spec.tags) out.tags = spec.tags;
  if (spec.children) out.children = spec.children.map(untype);
  for (const key of Object.keys(out)) if (out[key] === undefined) delete out[key];
  return out;
}

const classesIn = (spec, into = new Set()) => {
  into.add(spec.className);
  for (const child of spec.children ?? []) classesIn(child, into);
  return into;
};

export function fakeStudio(placeId = 1) {
  const scripts = new Map(); // path -> { className, source }
  const trees = new Map(); // path -> build spec (plain values)
  const dirty = new Set();
  const logged = [];
  const session = { studioId: "edit", placeId, placeName: "Test", context: "edit" };
  const chain = (item) => [item.parentPath, ...(item.parents ?? []).map((link) => link.name)].filter(Boolean).join(".");
  const calls = [];

  const bridge = {
    scripts,
    trees,
    logged,
    calls,
    /** Studio restarted: same place, new session id. */
    restart() {
      session.studioId = `${session.studioId}+`;
    },
    /** An edit made in Studio: tracked, as the plugin's events would. */
    edit(path, source) {
      scripts.get(path).source = source;
      dirty.add(path);
    },
    async sessions() {
      return { list: [session], activeId: null, activeIsChosen: false };
    },
    async call(op, params = {}, options = {}) {
      calls.push(op);
      if (options.studioId !== undefined && options.studioId !== session.studioId) {
        throw new ToolError("UNKNOWN_STUDIO", `No connected Studio has id "${options.studioId}".`);
      }
      switch (op) {
        case "sync.scan": {
          const byPath = {};
          for (const [key, value] of scripts) {
            byPath[key] = { className: value.className, revision: params.revisions === false ? undefined : fingerprint(value.source) };
          }
          const scan = scanOf(byPath);
          scan.roots = ["ServerScriptService", "ReplicatedStorage", "StarterGui"];
          return scan;
        }
        case "sync.shape":
          return { shape: [...scripts.keys()].sort().join("\n") };
        case "sync.read":
          return {
            items: params.paths.map((key) =>
              scripts.has(key)
                ? { path: key, source: scripts.get(key).source, revision: fingerprint(scripts.get(key).source), className: scripts.get(key).className }
                : { path: key, code: "NOT_FOUND", message: "gone" },
            ),
          };
        case "sync.revisions":
          return {
            items: params.paths.map((key) =>
              scripts.has(key) ? { path: key, revision: fingerprint(scripts.get(key).source) } : { path: key, missing: true },
            ),
          };
        case "sync.changes": {
          const out = { token: "tracking", reset: params.token !== "tracking", dirty: [...dirty], structural: false };
          dirty.clear();
          return out;
        }
        case "sync.apply": {
          const out = { writes: [], creates: [], deletes: [], moves: [], undoStep: "MCP sync" };
          for (const item of params.creates ?? []) {
            const target = `${chain(item)}.${item.name}`;
            if (scripts.has(target)) out.creates.push({ ok: false, code: "EXISTS", message: "exists" });
            else {
              scripts.set(target, { className: item.className, source: item.source });
              out.creates.push({ ok: true, path: target, revision: fingerprint(item.source) });
            }
          }
          for (const item of params.deletes ?? []) {
            const current = scripts.get(item.path);
            if (!current || fingerprint(current.source) !== item.revision) out.deletes.push({ ok: false, path: item.path, code: "STALE_SCRIPT", message: "changed" });
            else {
              scripts.delete(item.path);
              out.deletes.push({ ok: true, path: item.path });
            }
          }
          for (const item of params.moves ?? []) {
            const current = scripts.get(item.path);
            if (!current || fingerprint(current.source) !== item.revision) out.moves.push({ ok: false, from: item.path, code: "STALE_SCRIPT", message: "changed" });
            else {
              const target = `${chain(item)}.${item.name}`;
              scripts.delete(item.path);
              scripts.set(target, current);
              out.moves.push({ ok: true, from: item.path, path: target });
            }
          }
          for (const item of params.writes ?? []) {
            const current = scripts.get(item.path);
            if (!current || fingerprint(current.source) !== item.revision) out.writes.push({ ok: false, path: item.path, code: "STALE_SCRIPT", message: "changed" });
            else {
              current.source = item.source;
              // The plugin's editor event fires for sync's own write too.
              dirty.add(item.path);
              out.writes.push({ ok: true, path: item.path, revision: fingerprint(item.source) });
            }
          }
          return out;
        }
        case "sync.classes": {
          const spec = trees.get(params.path);
          if (!spec) throw new ToolError("NOT_FOUND", `nothing at ${params.path}`);
          const segments = params.path.split(".");
          return {
            path: params.path,
            classes: [...classesIn(spec)].sort(),
            chain: segments.map((name, index) => ({
              name,
              className: index === segments.length - 1 ? spec.className : index === 0 ? name : "Folder",
              path: segments.slice(0, index + 1).join("."),
            })),
          };
        }
        case "sync.export": {
          const spec = trees.get(params.path);
          return { path: params.path, spec: structuredClone(spec), instances: classesIn(spec).size, scripts: 0, skipped: [] };
        }
        case "sync.build": {
          const target = `${params.parent}.${params.spec.name ?? params.spec.className}`;
          if (params.replaces && params.replaces !== target) trees.delete(params.replaces);
          trees.set(target, untype(params.spec));
          return { path: target, carried: [] };
        }
        case "sync.log":
          logged.push(...params.lines);
          return { logged: true };
        case "sync.stop":
          return { stopped: true };
        default:
          throw new Error(`fake Studio has no ${op}`);
      }
    },
  };
  return bridge;
}
