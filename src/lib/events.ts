import type { Credentials } from "./credentials.js";
import { ToolError } from "./errors.js";
import { call } from "./opencloud.js";

/**
 * Scheduled game events, over Open Cloud: the "Season 5 launch, Saturday 18:00"
 * entries players see on the experience's page and can RSVP to.
 *
 * Unlike most of this server's write calls these are deliberately public --
 * an event is an announcement -- so the tool asks for confirmation before it
 * creates, reschedules or cancels one.
 */
const BASE = "/virtual-events/v3";

/** Trims every list row to what a reader needs; the API returns far more. */
const LIST_FIELDS = "id,title,subtitle,startTime,endTime,visibility";

interface GameEvent {
  id?: string;
  title?: string;
  subtitle?: string;
  description?: string;
  startTime?: string;
  endTime?: string;
  visibility?: unknown;
  universeId?: number;
  placeId?: number;
}

interface EventPage {
  gameEvents?: GameEvent[];
  nextPageToken?: string | null;
}

const row = (event: GameEvent): Record<string, unknown> => ({
  id: event.id,
  title: event.title,
  start: event.startTime,
  end: event.endTime,
  visibility: typeof event.visibility === "string" ? event.visibility : event.visibility === undefined ? undefined : JSON.stringify(event.visibility),
});

export async function listEvents(
  credentials: Credentials,
  args: { universeId: string; limit: number },
): Promise<{ items: Array<Record<string, unknown>>; more: boolean }> {
  const items: Array<Record<string, unknown>> = [];
  let token: string | undefined;
  // The cap only exists so a cursor that never ends cannot loop forever.
  for (let page = 0; page < 20; page += 1) {
    const found = await call<EventPage>(credentials, {
      path: `${BASE}/universes/${encodeURIComponent(args.universeId)}/game-events`,
      query: { pageSize: Math.min(args.limit - items.length, 100), pageToken: token, fields: LIST_FIELDS },
      scope: "universe.event:read",
    });
    items.push(...(found.gameEvents ?? []).map(row));
    token = found.nextPageToken || undefined;
    if (token === undefined || items.length >= args.limit) break;
  }
  return { items: items.slice(0, args.limit), more: token !== undefined || items.length > args.limit };
}

export async function getEvent(credentials: Credentials, eventId: string): Promise<GameEvent> {
  return call<GameEvent>(credentials, {
    path: `${BASE}/game-events/${encodeURIComponent(eventId)}`,
    query: { fields: "*" },
    scope: "universe.event:read",
  });
}

export async function saveEvent(
  credentials: Credentials,
  args: {
    universeId: string;
    eventId?: string;
    title?: string;
    subtitle?: string;
    description?: string;
    startTime?: string;
    endTime?: string;
    visibility?: string;
  },
): Promise<Record<string, unknown>> {
  const fields = {
    title: args.title,
    subtitle: args.subtitle,
    description: args.description,
    startTime: args.startTime,
    endTime: args.endTime,
    visibility: args.visibility,
  };
  const body = Object.fromEntries(Object.entries(fields).filter(([, value]) => value !== undefined));

  if (args.eventId === undefined) {
    const missing = (["title", "startTime", "endTime"] as const).filter((name) => fields[name] === undefined);
    if (missing.length > 0) {
      throw new ToolError(
        "BAD_PARAMS",
        `A new event needs ${missing.map((name) => "`" + name + "`").join(", ")}.`,
        "Times are ISO 8601 in UTC, e.g. 2026-11-07T18:00:00Z. Pass `eventId` instead to change an event that exists.",
      );
    }
  } else if (Object.keys(body).length === 0) {
    throw new ToolError("BAD_PARAMS", "Nothing to change: pass at least one of title, subtitle, description, startTime, endTime, visibility.");
  }

  const saved = await call<GameEvent>(
    credentials,
    args.eventId === undefined
      ? { method: "POST", path: `${BASE}/universes/${encodeURIComponent(args.universeId)}/game-events`, body, scope: "universe.event:write" }
      : { method: "PATCH", path: `${BASE}/game-events/${encodeURIComponent(args.eventId)}`, body, scope: "universe.event:write" },
  );
  return { action: args.eventId === undefined ? "created" : "updated", ...row(saved), description: saved.description };
}

export async function cancelEvent(credentials: Credentials, eventId: string): Promise<Record<string, unknown>> {
  await call(credentials, {
    method: "DELETE",
    path: `${BASE}/game-events/${encodeURIComponent(eventId)}`,
    scope: "universe.event:write",
  });
  return { action: "cancelled", id: eventId };
}
