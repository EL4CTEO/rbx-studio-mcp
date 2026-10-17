/**
 * UI snapshots and the diff between two of them.
 *
 * The plugin reports every UI element under a root with the properties that
 * decide how it looks. Snapshots are kept here, in the server, so a later call
 * can say exactly what an edit moved, recoloured or re-fonted -- including the
 * things it was not meant to touch, which is the part a screenshot comparison
 * by eye misses.
 */

export interface UiElement {
  path: string;
  className: string;
  props: Record<string, unknown>;
}

export interface UiSnapshotResponse {
  root: string;
  screen: string;
  device?: string;
  elements: UiElement[];
  omitted?: number;
}

export interface UiSnapshot extends UiSnapshotResponse {
  id: string;
  takenAt: number;
  /** Which session and client it was taken in, so a diff never mixes them. */
  scope: string;
}

export interface UiChange {
  path: string;
  className: string;
  changes: Array<{ property: string; before: unknown; after: unknown }>;
}

export interface UiDiff {
  added: UiElement[];
  removed: UiElement[];
  changed: UiChange[];
  unchanged: number;
}

/** Old snapshots are dropped past this; an agent rarely needs more than the last few. */
const MAX_SNAPSHOTS = 20;
/** Long enough for a design pass, short enough that memory does not grow all session. */
const SNAPSHOT_TTL_MS = 60 * 60 * 1000;

const snapshots = new Map<string, UiSnapshot>();
let counter = 0;

export function storeSnapshot(response: UiSnapshotResponse, scope: string, now = Date.now()): UiSnapshot {
  for (const [id, snapshot] of snapshots) {
    if (now - snapshot.takenAt > SNAPSHOT_TTL_MS) snapshots.delete(id);
  }
  while (snapshots.size >= MAX_SNAPSHOTS) {
    const oldest = snapshots.keys().next().value;
    if (oldest === undefined) break;
    snapshots.delete(oldest);
  }
  counter += 1;
  const snapshot: UiSnapshot = { ...response, id: `ui${counter}`, takenAt: now, scope };
  snapshots.set(snapshot.id, snapshot);
  return snapshot;
}

export function getSnapshot(id: string): UiSnapshot | undefined {
  return snapshots.get(id);
}

/** For tests. */
export function clearSnapshots(): void {
  snapshots.clear();
  counter = 0;
}

const same = (a: unknown, b: unknown): boolean => JSON.stringify(a) === JSON.stringify(b);

export function diffSnapshots(before: UiSnapshotResponse, after: UiSnapshotResponse): UiDiff {
  const old = new Map(before.elements.map((element) => [element.path, element]));
  const seen = new Set<string>();
  const added: UiElement[] = [];
  const changed: UiChange[] = [];
  let unchanged = 0;

  for (const element of after.elements) {
    const previous = old.get(element.path);
    // A class change at the same path is a different element, not an edit.
    if (previous === undefined || previous.className !== element.className) {
      added.push(element);
      continue;
    }
    seen.add(element.path);
    const names = new Set([...Object.keys(previous.props), ...Object.keys(element.props)]);
    const changes = [...names]
      .filter((name) => !same(previous.props[name], element.props[name]))
      .sort()
      .map((property) => ({ property, before: previous.props[property], after: element.props[property] }));
    if (changes.length > 0) changed.push({ path: element.path, className: element.className, changes });
    else unchanged += 1;
  }

  const removed = before.elements.filter((element) => !seen.has(element.path));
  return { added, removed, changed, unchanged };
}

const show = (value: unknown): string =>
  value === undefined ? "(none)" : typeof value === "object" || typeof value === "string" ? JSON.stringify(value) : String(value);

/** The diff as text: removed and added by path, then each changed element's properties. */
export function renderDiff(diff: UiDiff, limit = 60): string {
  const lines: string[] = [];
  let budget = limit;
  const take = <T>(rows: T[]): T[] => {
    const shown = rows.slice(0, Math.max(budget, 0));
    budget -= shown.length;
    return shown;
  };

  if (diff.removed.length > 0) {
    lines.push(`REMOVED (${diff.removed.length})`);
    for (const element of take(diff.removed)) lines.push(`  ${element.path} (${element.className})`);
  }
  if (diff.added.length > 0) {
    lines.push(`ADDED (${diff.added.length})`);
    for (const element of take(diff.added)) lines.push(`  ${element.path} (${element.className})`);
  }
  if (diff.changed.length > 0) {
    lines.push(`CHANGED (${diff.changed.length})`);
    for (const element of take(diff.changed)) {
      lines.push(`  ${element.path} (${element.className})`);
      for (const change of element.changes) {
        lines.push(`    ${change.property}: ${show(change.before)} -> ${show(change.after)}`);
      }
    }
  }
  const total = diff.removed.length + diff.added.length + diff.changed.length;
  if (total > limit) lines.push(`[${total - limit} more elements left out; narrow \`path\`.]`);
  return lines.join("\n");
}
