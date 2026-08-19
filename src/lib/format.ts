import { z } from "zod";

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

/** Minimal MCP content result. Kept local so tools never import SDK types. */
export interface ToolResult {
  content: Array<{ type: "text"; text: string }>;
  isError?: boolean;
  [key: string]: unknown;
}

export function text(body: string): ToolResult {
  return { content: [{ type: "text", text: body }] };
}

export function errorText(body: string): ToolResult {
  return { content: [{ type: "text", text: body }], isError: true };
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
