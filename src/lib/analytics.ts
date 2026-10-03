import type { Credentials } from "./credentials.js";
import { ToolError } from "./errors.js";
import { call } from "./opencloud.js";
import { pollDelayMs } from "./timeout.js";
import { reportProgress } from "./progress.js";

/**
 * Analytics Query API: the game's own numbers, over Open Cloud.
 *
 * The same metrics the Creator Dashboard charts -- players, revenue, retention,
 * crashes, frame rate -- as time series, optionally split by a dimension such
 * as platform or country. This is what answers "did last night's update hurt
 * retention" without leaving the conversation.
 *
 * A query is a task, like a live Luau run: most answer at once, a big date range
 * or many breakdown series answer 202 with a path to poll.
 */
const BASE = "/analytics-query-api/v1/universes";
const SCOPE = "universe.analytics:read" as const;
const POLL_CEILING_MS = 2_000;
const TIMEOUT_MS = 90_000;

/** Granularities the API names. Which a metric accepts depends on the metric. */
export const GRANULARITIES = ["OneMinute", "HalfHour", "OneHour", "OneDay", "OneWeek", "OneMonth", "None"] as const;
export type Granularity = (typeof GRANULARITIES)[number];

interface Series {
  breakdowns?: unknown[];
  dataPoints?: Array<{ time?: string; value?: number | string | null }>;
}

interface QueryOperation {
  path?: string;
  done?: boolean;
  response?: { values?: Series[] };
  error?: { code?: number | string; message?: string };
}

export interface MetricQuery {
  universeId: string;
  metric: string;
  granularity: Granularity;
  startTime: string;
  endTime: string;
  breakdown?: string[];
  filter?: Array<{ dimension: string; values: string[]; operation: "In" }>;
  limit?: number;
}

/**
 * `Platform=Phone,Tablet;Country=US` as the API's filter list.
 *
 * A string rather than a nested object so an agent can write it in one breath;
 * `In` is the only operation the documentation names.
 */
export function parseFilter(text: string): NonNullable<MetricQuery["filter"]> {
  const filters: NonNullable<MetricQuery["filter"]> = [];
  for (const part of text.split(";")) {
    if (part.trim() === "") continue;
    const at = part.indexOf("=");
    const dimension = at === -1 ? "" : part.slice(0, at).trim();
    const values = at === -1 ? [] : part.slice(at + 1).split(",").map((value) => value.trim()).filter((value) => value !== "");
    if (dimension === "" || values.length === 0) {
      throw new ToolError(
        "BAD_PARAMS",
        `"${part.trim()}" is not a filter.`,
        "Write one as Dimension=value1,value2 and separate several with `;`, e.g. Platform=Phone,Tablet;Country=US.",
      );
    }
    filters.push({ dimension, values, operation: "In" });
  }
  return filters;
}

/**
 * A range of whole UTC days ending at the start of today.
 *
 * Today is left out on purpose: its bucket is still filling, and a half-day
 * that reads as a collapse in players is a worse answer than a day late.
 */
export function lastDays(days: number, now = new Date()): { startTime: string; endTime: string } {
  const end = Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate());
  const iso = (ms: number): string => new Date(ms).toISOString().replace(".000Z", "Z");
  return { startTime: iso(end - days * 86_400_000), endTime: iso(end) };
}

export async function queryMetric(credentials: Credentials, query: MetricQuery): Promise<QueryOperation> {
  const path = `${BASE}/${encodeURIComponent(query.universeId)}/metrics`;
  const body = {
    metric: query.metric,
    granularity: query.granularity,
    startTime: query.startTime,
    endTime: query.endTime,
    ...(query.breakdown && query.breakdown.length > 0 ? { breakdown: query.breakdown, limit: query.limit } : {}),
    ...(query.filter && query.filter.length > 0 ? { filter: query.filter } : {}),
  };

  let operation: QueryOperation;
  try {
    operation = await call<QueryOperation>(credentials, { method: "POST", path, body, scope: SCOPE });
    const deadline = Date.now() + TIMEOUT_MS;
    for (let attempt = 0; operation.done !== true; attempt += 1) {
      if (operation.error) break;
      if (!operation.path) {
        throw new ToolError("NO_OPERATION", "Roblox did not say where to read this query's result.");
      }
      if (Date.now() >= deadline) {
        throw new ToolError(
          "STILL_PROCESSING",
          `The query was still running after ${TIMEOUT_MS / 1000}s.`,
          "Ask for a shorter range, a coarser granularity, or fewer breakdown series.",
        );
      }
      reportProgress("Roblox is still computing the query");
      await new Promise((done) => setTimeout(done, pollDelayMs(attempt, POLL_CEILING_MS, 500)));
      operation = await call<QueryOperation>(credentials, {
        path: `/analytics-query-api/${operation.path.replace(/^\/+/, "")}`,
        scope: SCOPE,
      });
    }
  } catch (cause) {
    // Documented as 429 code 3000. It is not a rate limit -- waiting changes
    // nothing -- so it is said as what it is.
    if (cause instanceof ToolError && cause.code === "RATE_LIMITED" && /budget/i.test(cause.message)) {
      throw new ToolError(
        "TOO_MUCH_DATA",
        "That query would return more data points than Roblox allows in one answer.",
        "Ask for a shorter range, a coarser granularity (OneWeek instead of OneDay), or cap the breakdown with `limit`.",
      );
    }
    throw cause;
  }

  if (operation.error) {
    throw new ToolError(
      "QUERY_FAILED",
      `Roblox could not answer the query: ${operation.error.message ?? operation.error.code ?? "no reason given"}`,
      "Check the metric name, and that it supports this granularity and these breakdown dimensions.",
    );
  }
  return operation;
}

const numberText = (value: unknown): string => {
  if (typeof value !== "number") return String(value ?? "");
  return Number.isInteger(value) ? String(value) : String(Number(value.toPrecision(5)));
};

/** Most data points printed per series; the summary line always covers all of them. */
const MAX_ROWS = 60;

/** One query as text an agent can read: a summary per series, then the points. */
export function renderSeries(query: MetricQuery, operation: QueryOperation): string {
  const series = operation.response?.values ?? [];
  const heading =
    `${query.metric}, ${query.granularity}, ${query.startTime.slice(0, 10)} to ${query.endTime.slice(0, 10)} ` +
    `(end exclusive, UTC)` +
    (query.filter?.length ? `, filtered by ${query.filter.map((f) => `${f.dimension}=${f.values.join("|")}`).join(", ")}` : "");
  if (series.length === 0 || series.every((entry) => (entry.dataPoints ?? []).length === 0)) {
    return `${heading}\n\nNo data for that range. A metric with no traffic, a range before the game had players, or a metric that does not apply to this game all read like this.`;
  }

  const blocks = series.map((entry) => {
    const label = (entry.breakdowns ?? [])
      .map((item) => {
        const pair = item as { dimension?: unknown; value?: unknown };
        return pair !== null && typeof pair === "object" && "value" in pair
          ? `${String(pair.dimension ?? "?")}=${String(pair.value)}`
          : JSON.stringify(item);
      })
      .join(", ");
    const points = entry.dataPoints ?? [];
    const numbers = points.map((point) => Number(point.value)).filter((value) => Number.isFinite(value));
    const last = points[points.length - 1];
    const summary =
      numbers.length === 0
        ? `${points.length} point(s)`
        : `${points.length} point(s): latest ${numberText(last?.value)}, min ${numberText(Math.min(...numbers))}, ` +
          `max ${numberText(Math.max(...numbers))}, mean ${numberText(numbers.reduce((sum, value) => sum + value, 0) / numbers.length)}`;
    const shown = points.slice(-MAX_ROWS);
    const rows = shown.map((point) => `${(point.time ?? "").replace(/T00:00:00Z$/, "")}  ${numberText(point.value)}`);
    return [
      label === "" ? summary : `[${label}] ${summary}`,
      ...(points.length > shown.length ? [`(latest ${shown.length} shown; the summary covers all ${points.length})`] : []),
      ...rows,
    ].join("\n");
  });

  return `${heading}\n\n${blocks.join("\n\n")}`;
}
