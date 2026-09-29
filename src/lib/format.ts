import { z } from "zod";
import { ToolError } from "./errors.js";

/**
 * Hard ceiling on a single tool response, in characters (~6k tokens). Roblox
 * data models routinely run to tens of thousands of instances, so an unbounded
 * response can blow an agent's whole context on one call. Everything that can
 * grow is paged instead of truncated silently.
 */
export const CHARACTER_LIMIT = 25_000;

/** Default page size for list-shaped results, tuned to stay well under the cap. */
export const DEFAULT_PAGE_SIZE = 100;
export const MAX_PAGE_SIZE = 500;

export type Detail = "concise" | "standard" | "full";

export const detailSchema = z
  .enum(["concise", "standard", "full"])
  .default("standard")
  .describe(
    "concise: compact identity. standard: selected facts. full: all readable " +
      "properties for inspect; tree/find use the same columns as standard.",
  );

export const cursorSchema = z
  .string()
  .optional()
  .describe(
    "Opaque cursor from a previous call's `nextCursor`. Omit for the first page.",
  );

export const limitSchema = z
  .number()
  .int()
  .min(1)
  .max(MAX_PAGE_SIZE)
  .default(DEFAULT_PAGE_SIZE)
  .describe(`Maximum items to return (1-${MAX_PAGE_SIZE}).`);

/**
 * Cursors are just offsets. They are encoded so callers treat them as opaque
 * and pass them back verbatim instead of doing arithmetic on a number whose
 * meaning may change.
 */
export const encodeCursor = (offset: number): string =>
  Buffer.from(String(offset)).toString("base64url");

/**
 * Decodes a page cursor, refusing one this server did not issue.
 *
 * This used to fall back to 0 for anything it could not read, which is the
 * worst available behaviour: a stale or mistyped cursor silently returned page
 * one again, indistinguishable from a genuine first page. An agent paging
 * through results that way never reaches the end and never learns why -- it
 * just reads the same rows forever. Saying so costs one error and ends the
 * loop immediately.
 */
export function decodeCursor(cursor: string | undefined): number {
  if (!cursor) return 0;
  const decoded = Buffer.from(cursor, "base64url").toString("utf8");
  const parsed = Number.parseInt(decoded, 10);
  if (!Number.isInteger(parsed) || parsed < 0 || String(parsed) !== decoded.trim()) {
    throw new ToolError(
      "BAD_CURSOR",
      `${JSON.stringify(cursor)} is not a cursor this server issued.`,
      "Cursors are opaque — pass back the exact `nextCursor` string from the " +
        "previous page, or omit it to start from the beginning.",
    );
  }
  return parsed;
}

/** Line width `stringify` keeps a short object or array within before wrapping it. */
const COMPACT_WIDTH = 100;

/**
 * JSON for an agent to read: valid, and parsed back identical to
 * `JSON.stringify`, but a short object or array stays on one line.
 *
 * Fully indented JSON spends a line -- and its indentation -- on every value,
 * so a list of `{ path, className }` rows cost three to five lines each. Those
 * bytes count against CHARACTER_LIMIT and are billed as tokens on every call,
 * while telling the reader nothing. Only structures too wide for one line are
 * broken up, which keeps nesting as readable as before.
 */
export function stringify(value: unknown): string {
  const render = (node: unknown, indent: string, prefix: number): string => {
    const flat = JSON.stringify(node) ?? "null";
    if (
      node === null ||
      typeof node !== "object" ||
      typeof (node as { toJSON?: unknown }).toJSON === "function" ||
      indent.length + prefix + flat.length <= COMPACT_WIDTH
    ) {
      return flat;
    }
    const inner = `${indent}  `;
    if (Array.isArray(node)) {
      if (node.length === 0) return "[]";
      return `[\n${node.map((item) => inner + render(item, inner, 0)).join(",\n")}\n${indent}]`;
    }
    // The same entries JSON.stringify keeps: undefined, functions and symbols go.
    const entries = Object.entries(node as Record<string, unknown>).filter(
      ([, entry]) =>
        entry !== undefined && typeof entry !== "function" && typeof entry !== "symbol",
    );
    if (entries.length === 0) return "{}";
    const lines = entries.map(([key, entry]) => {
      const name = `${JSON.stringify(key)}: `;
      return inner + name + render(entry, inner, name.length);
    });
    return `{\n${lines.join(",\n")}\n${indent}}`;
  };
  return render(value, "", 0);
}

/** Minimal MCP content result. Kept local so tools never import SDK types. */
export interface ToolResult {
  content: Array<
    { type: "text"; text: string } | { type: "image"; data: string; mimeType: string }
  >;
  isError?: boolean;
  [key: string]: unknown;
}

export function text(body: string): ToolResult {
  return { content: [{ type: "text", text: body }] };
}

/**
 * An image the model can actually look at, with a line of text alongside it.
 *
 * The caption is not decoration: an image arrives with no path, no size and no
 * indication of which of several Studio windows it came from, and none of that
 * is recoverable from the pixels.
 */
export function image(data: string, caption: string, mimeType = "image/png"): ToolResult {
  return {
    content: [
      { type: "image", data, mimeType },
      { type: "text", text: caption },
    ],
  };
}

export function errorText(body: string): ToolResult {
  return { content: [{ type: "text", text: body }], isError: true };
}

/**
 * The rendered text of a result, for composing one helper's output into another.
 *
 * Results can now carry an image, so reading `content[0].text` is no longer
 * always meaningful. Callers that stitch tables together want the text and
 * nothing else, which is exactly what this returns.
 */
export function textOf(result: ToolResult): string {
  return result.content
    .filter((part): part is { type: "text"; text: string } => part.type === "text")
    .map((part) => part.text)
    .join("\n");
}

export interface PageMeta {
  /** Offset of the fetched page, for continuation after response-budget clipping. */
  offset?: number;
  /** Total matches Studio found, before this page was sliced out. */
  total?: number;
  nextCursor?: string;
  /** What the caller should do to get the rest, in plain language. */
  more?: string;
}

/**
 * Renders a page of records as JSON plus a short trailer telling the agent
 * whether anything was left behind and how to reach it. The trailer is the
 * point: a bare truncated array reads as a complete answer and the agent
 * confidently reports the wrong total.
 */
export function page(items: unknown[], meta: PageMeta = {}): ToolResult {
  const parts: string[] = [];
  let body = stringify(items);

  let shown = items.length;
  if (body.length > CHARACTER_LIMIT - 500) {
    const kept = fitToLimit(items, CHARACTER_LIMIT - 500);
    let truncatedItem = false;
    if (kept.length === 0 && items.length > 0) { kept.push(boundedValue(items[0])); truncatedItem = true; }
    body = truncatedItem ? JSON.stringify(kept) : stringify(kept);
    while (body.length > CHARACTER_LIMIT - 500 && kept.length > 1) { kept.pop(); body = stringify(kept); }
    if (body.length > CHARACTER_LIMIT - 500) { body = JSON.stringify([boundedValue(kept[0])]); truncatedItem = true; }
    shown = kept.length;
    parts.push(body);
    if (truncatedItem) parts.push("\n[first item truncated to fit the response budget; narrow properties or detail to retrieve it fully]");
    parts.push(
      `\n[${items.length - kept.length} of ${items.length} items dropped: the page ` +
        `exceeded the ${CHARACTER_LIMIT}-character response limit. Re-run with a ` +
        `smaller \`limit\`, or with \`detail: "concise"\` to fit more per page.]`,
    );
  } else {
    parts.push(body);
  }

  if (meta.total !== undefined && meta.total > shown) {
    parts.push(`\n[showing ${shown} of ${meta.total} matches]`);
  }
  const nextCursor = continuation(meta, shown);
  if (nextCursor) {
    parts.push(
      `\n[more results available — call again with cursor: "${nextCursor}"]`,
    );
  }
  if (meta.more) parts.push(`\n[${meta.more}]`);

  return text(parts.join(""));
}

/**
 * Renders a list of uniform records as a pipe-delimited table.
 *
 * A hierarchy listing pretty-printed as JSON spends five lines and a dozen
 * punctuation tokens per instance to repeat the same three keys. One header
 * plus one line per row carries the same information for roughly a quarter of
 * the tokens, and reads better in a transcript. `json` is still the right
 * choice for nested or heterogeneous data.
 */
export function table(
  columns: string[],
  rows: Array<Record<string, unknown>>,
  meta: PageMeta = {},
): ToolResult {
  if (rows.length === 0) {
    return text(meta.more ?? "No matches.");
  }

  const render = (row: Record<string, unknown>): string =>
    columns.map((column) => formatCell(row[column])).join(" | ");

  const lines: string[] = [columns.join(" | ")];
  let used = lines[0]!.length;
  let dropped = 0;

  for (const row of rows) {
    let line = render(row);
    if (lines.length === 1 && line.length > CHARACTER_LIMIT - 1000) {
      line = columns.map(column => formatCell(row[column]).slice(0, 1000)).join(" | ") + " [row truncated]";
    }
    if (used + line.length + 1 > CHARACTER_LIMIT - 500) {
      dropped = rows.length - (lines.length - 1);
      break;
    }
    lines.push(line);
    used += line.length + 1;
  }

  const trailer: string[] = [];
  if (dropped > 0) {
    trailer.push(
      `[${dropped} rows dropped to stay under the ${CHARACTER_LIMIT}-character ` +
        `response limit — re-run with a smaller \`limit\`]`,
    );
  }
  const shown = lines.length - 1;
  if (meta.total !== undefined && meta.total > shown) {
    trailer.push(`[showing ${shown} of ${meta.total} matches]`);
  }
  const nextCursor = continuation(meta, shown);
  if (nextCursor) {
    trailer.push(`[more results — call again with cursor: "${nextCursor}"]`);
  }
  if (meta.more) trailer.push(`[${meta.more}]`);

  return text([...lines, ...(trailer.length > 0 ? ["", ...trailer] : [])].join("\n"));
}

function formatCell(value: unknown): string {
  if (value === null || value === undefined) return "";
  const cell = typeof value === "object" ? JSON.stringify(value) : String(value);
  return cell.replaceAll("\n", "\\n").replaceAll("\r", "\\r").replaceAll("|", "\\|");
}

function continuation(meta: PageMeta, shown: number): string | undefined {
  if (meta.offset !== undefined && meta.total !== undefined)
    return meta.offset + shown < meta.total ? encodeCursor(meta.offset + shown) : undefined;
  return meta.nextCursor;
}

/** Greedily keeps the longest prefix of `items` that serialises under `budget`. */
function fitToLimit(items: unknown[], budget: number): unknown[] {
  const kept: unknown[] = [];
  let used = 2; // the enclosing brackets
  for (const item of items) {
    const cost = stringify(item).length + 2;
    if (used + cost > budget) break;
    used += cost;
    kept.push(item);
  }
  return kept;
}

/**
 * Emits a plain text body, clipping at the character limit with an explicit
 * marker. Used for source listings, where the content is already line-oriented
 * and reflowing it into JSON would only add escaping noise.
 */
export function body(content: string, advice: string): ToolResult {
  if (content.length <= CHARACTER_LIMIT) return text(content);
  return text(
    `${content.slice(0, CHARACTER_LIMIT - 500)}\n\n[clipped at ${CHARACTER_LIMIT} characters — ${advice}]`,
  );
}

/**
 * Renders arbitrary structured data, clipping at the character limit with an
 * explicit marker so the agent never mistakes a clipped blob for the whole one.
 */
export function json(value: unknown, note?: string): ToolResult {
  let body = stringify(value);
  if (body.length > CHARACTER_LIMIT - 500) {
    body = JSON.stringify({ truncated: true, data: boundedValue(value) });
  }
  return text(note ? `${body}\n\n${note.slice(0, 450)}` : body);
}

/** Preserve valid JSON under one global byte/node budget, even for wide trees. */
function boundedValue(value: unknown): unknown {
  let remaining = CHARACTER_LIMIT - 2000;
  let nodes = 500;
  const visit = (node: unknown, depth: number): unknown => {
    if (--nodes < 0 || remaining < 100 || depth > 8) return "<truncated>";
    remaining -= 30;
    if (typeof node === "string") {
      let lo = 0, hi = node.length;
      while (lo < hi) {
        const mid = Math.ceil((lo + hi) / 2);
        if (JSON.stringify(node.slice(0, mid)).length <= remaining) lo = mid;
        else hi = mid - 1;
      }
      const result = lo < node.length ? node.slice(0, Math.max(0, lo - 20)) + "<truncated>" : node;
      remaining -= JSON.stringify(result).length;
      return result;
    }
    if (node === null || typeof node !== "object") { remaining -= 30; return node; }
    const result: Record<string, unknown> | unknown[] = Array.isArray(node) ? [] : {};
    for (const [key, child] of Object.entries(node)) {
      if (nodes <= 0 || remaining < JSON.stringify(key).length + 100) {
        if (Array.isArray(result)) result.push("<truncated>");
        else result["..."] = "<truncated>";
        break;
      }
      remaining -= JSON.stringify(key).length + 5;
      const entry = visit(child, depth + 1);
      if (Array.isArray(result)) result.push(entry); else Object.defineProperty(result, key, { value: entry, enumerable: true });
    }
    return result;
  };
  return visit(value, 0);
}
