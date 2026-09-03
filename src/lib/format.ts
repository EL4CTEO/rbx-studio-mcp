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
    "How much to return per item. 'concise' = name + class only, cheapest, use " +
      "when scanning or counting. 'standard' = the properties that matter for most " +
      "edits. 'full' = every readable property, expensive — use only after you have " +
      "narrowed to a handful of instances.",
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
  let body = JSON.stringify(items, null, 2);

  if (body.length > CHARACTER_LIMIT) {
    const kept = fitToLimit(items, CHARACTER_LIMIT - 500);
    body = JSON.stringify(kept, null, 2);
    parts.push(body);
    parts.push(
      `\n[${items.length - kept.length} of ${items.length} items dropped: the page ` +
        `exceeded the ${CHARACTER_LIMIT}-character response limit. Re-run with a ` +
        `smaller \`limit\`, or with \`detail: "concise"\` to fit more per page.]`,
    );
  } else {
    parts.push(body);
  }

  if (meta.total !== undefined && meta.total > items.length) {
    parts.push(`\n[showing ${items.length} of ${meta.total} matches]`);
  }
  if (meta.nextCursor) {
    parts.push(
      `\n[more results available — call again with cursor: "${meta.nextCursor}"]`,
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
    const line = render(row);
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
  if (meta.total !== undefined && meta.total > rows.length) {
    trailer.push(`[showing ${rows.length} of ${meta.total} matches]`);
  }
  if (meta.nextCursor) {
    trailer.push(`[more results — call again with cursor: "${meta.nextCursor}"]`);
  }
  if (meta.more) trailer.push(`[${meta.more}]`);

  return text([...lines, ...(trailer.length > 0 ? ["", ...trailer] : [])].join("\n"));
}

function formatCell(value: unknown): string {
  if (value === null || value === undefined) return "";
  if (typeof value === "object") return JSON.stringify(value);
  return String(value);
}

/** Greedily keeps the longest prefix of `items` that serialises under `budget`. */
function fitToLimit(items: unknown[], budget: number): unknown[] {
  const kept: unknown[] = [];
  let used = 2; // the enclosing brackets
  for (const item of items) {
    const cost = JSON.stringify(item, null, 2).length + 2;
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
    `${content.slice(0, CHARACTER_LIMIT)}\n\n[clipped at ${CHARACTER_LIMIT} characters — ${advice}]`,
  );
}

/**
 * Renders arbitrary structured data, clipping at the character limit with an
 * explicit marker so the agent never mistakes a clipped blob for the whole one.
 */
export function json(value: unknown, note?: string): ToolResult {
  let body = JSON.stringify(value, null, 2);
  if (body.length > CHARACTER_LIMIT) {
    body =
      body.slice(0, CHARACTER_LIMIT) +
      `\n\n[response clipped at ${CHARACTER_LIMIT} characters — narrow the request ` +
      `(fewer paths, lower depth, or detail: "concise") to see the rest]`;
  }
  return text(note ? `${body}\n\n${note}` : body);
}
