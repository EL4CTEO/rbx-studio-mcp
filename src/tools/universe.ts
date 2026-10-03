import { z } from "zod";
import { ToolError } from "../lib/errors.js";
import { GRANULARITIES, lastDays, parseFilter, queryMetric, renderSeries } from "../lib/analytics.js";
import { cancelEvent, getEvent, listEvents, saveEvent } from "../lib/events.js";
import { json, table, text, textOf, type ToolResult } from "../lib/format.js";
import {
  getInventory,
  getUser,
  listGameServers,
  listRestrictions,
  listServerLogs,
  publishMessage,
  restartServers,
  setRestriction,
} from "../lib/liveops.js";
import { listItems, saveItem } from "../lib/monetization.js";
import {
  assertTargetsOpenPlace,
  requireCredentials,
  requirePlace,
  requireUniverse,
} from "../lib/opencloud.js";
import { defineTool, type ToolContext } from "../lib/tool.js";

/**
 * Operating the published game, as opposed to building it.
 *
 * This is the one genuinely new tool in this area, and it earns the slot by
 * being a different job rather than a different spelling of an existing one.
 * Everything else that reaches Roblox folded into the tool that already owned
 * the noun: uploads and publishing into `assets`, live saves into `datastore`,
 * remote code into `execute_luau`, cloud scripts into `script_read`/`script_edit`.
 *
 * What was left over has no such home. Banning a player, messaging live servers
 * and rolling servers onto a new build are not things you do to a place file;
 * they are things you do to a running game with people in it. Bolting them onto
 * `character` or `console` would have meant hiding live moderation inside a tool
 * about the local test avatar.
 *
 * Everything here acts on real players. Every write asks for confirmation.
 */
export function registerUniverseTools(context: ToolContext): void {
  const { bridge } = context;

  defineTool(
    context,
    {
      name: "universe",
      title: "Operate the live game",
      description:
        "Acts on the PUBLISHED experience and the people in it — not on the " +
        "place open in Studio.\n\n" +
        "`restart` rolls live servers onto the version you just published. " +
        "Publishing on its own changes nothing for anyone already playing: " +
        "they stay on their server, running the old code, until it empties. " +
        "This is the step people forget. By default it bleeds off over 10 " +
        "minutes — matchmaking stops and players finish what they are doing — " +
        "rather than shutting servers down under them, which is what Roblox's " +
        "own default does.\n\n" +
        "`message` publishes to MessagingService, reaching every live server at " +
        "once. Only servers with a `SubscribeAsync` listener on that exact " +
        "topic receive it, and nothing reports whether anything was listening, " +
        "so success here does not mean delivery.\n\n" +
        "`ban` and `unban` set a player's game-join restriction. A ban with no " +
        "`durationSeconds` is PERMANENT. `displayReason` is shown to the " +
        "player; `privateReason` is for your records. Scope it to one place " +
        "with `placeId`, or leave that out to cover the whole experience. " +
        "`bans` lists who is currently restricted.\n\n" +
        "`user` looks up a user id — the name-to-id step most other calls need. " +
        "`inventory` reports what someone owns: passes, badges, assets.\n\n" +
        "`servers` lists the place's live servers — players, uptime, frame " +
        "rate, memory, version — and `logs` reads one server's errors and " +
        "warnings by its `jobId`, with stack traces and structured-log context. " +
        "That is where a player's bug report actually happened; Studio only " +
        "shows your own test. Roblox keeps warnings and errors only, and they " +
        "arrive about three minutes after they are written.\n\n" +
        "`products` lists the game's developer products and game passes with " +
        "their ids and prices — the ids a purchase script needs. `sell` " +
        "creates one, or changes one given `itemId`. Creating checks the name " +
        "first, so a retried create cannot leave two \"100 Coins\" products.\n\n" +
        "`analytics` reads the game's own numbers over a date range: players, " +
        "revenue, retention, crashes, frame rate, as a time series, optionally " +
        "split by a `breakdown` such as Platform or Country. Common metrics: " +
        "DailyActiveUsers, Visits, DailyRevenue, PayingUsers, ForwardD1Retention, " +
        "AverageSessionLengthMinutes, PeakConcurrentPlayers, ClientCrashCount, " +
        "ClientFpsP50. Give `days` for the last N whole UTC days, or " +
        "`startTime` and `endTime`.\n\n" +
        "`events` lists the game's scheduled events, or reads one by " +
        "`eventId`. `schedule` creates one (`title`, `startTime`, `endTime`) or " +
        "changes one given `eventId`; `cancel` deletes it. Players see these on " +
        "the experience's page.\n\n" +
        "Everything here needs an Open Cloud key and a universe id. The user " +
        "sets both once with `cloud` in the Studio panel.",
      inputSchema: {
        op: z
          .enum(["restart", "message", "ban", "unban", "bans", "user", "inventory", "servers", "logs", "products", "sell", "analytics", "events", "schedule", "cancel"])
          .describe(
            "'restart' rolls servers onto the new version, 'message' publishes " +
              "to MessagingService, 'ban'/'unban'/'bans' manage player access, " +
              "'user' and 'inventory' look someone up, 'servers' and 'logs' read " +
              "live servers, 'products' and 'sell' manage products and passes, " +
              "'analytics' reads metrics, 'events'/'schedule'/'cancel' manage scheduled events.",
          ),
        universeId: z
          .string()
          .optional()
          .describe("Which game. Omit to use the one set with `cloud universe <id>`."),
        placeId: z
          .string()
          .optional()
          .describe(
            "ban/unban: restrict to this place only, instead of the whole " +
              "experience. restart: only restart this place's servers. " +
              "servers/logs: which place, defaulting to `cloud place`.",
          ),
        jobId: z
          .string()
          .optional()
          .describe("logs only: the server, as listed by `servers`."),
        severity: z
          .enum(["error", "warning"])
          .optional()
          .describe("logs only: just this level. Omit for both."),
        search: z
          .string()
          .optional()
          .describe(
            "logs only: case-insensitive text to find in the message, stack " +
              "trace or context.",
          ),
        topic: z.string().optional().describe("message only: the MessagingService topic."),
        message: z.string().optional().describe("message only: the payload, as a string."),
        userId: z.string().optional().describe("ban/unban/user/inventory: the player's user id."),
        durationSeconds: z
          .number()
          .int()
          .min(1)
          .optional()
          .describe(
            "ban only: how long, in seconds. OMIT THIS AND THE BAN IS " +
              "PERMANENT — say so to the user before you do it.",
          ),
        displayReason: z
          .string()
          .max(400)
          .optional()
          .describe("ban only: shown to the player when they are turned away."),
        privateReason: z
          .string()
          .max(1000)
          .optional()
          .describe("ban only: your own record. The player never sees it."),
        excludeAltAccounts: z
          .boolean()
          .optional()
          .describe(
            "ban only: if true, the ban applies to this account alone rather " +
              "than to alts Roblox links to it. Defaults to false.",
          ),
        bleedOffMinutes: z
          .number()
          .int()
          .min(0)
          .max(60)
          .optional()
          .describe(
            "restart only: minutes to let existing servers drain. 0 shuts them " +
              "down immediately, moving players mid-game. Defaults to 10.",
          ),
        filter: z
          .string()
          .optional()
          .describe(
            'inventory: an Open Cloud filter, e.g. `gamePassIds=123` or ' +
              "`assetIds=456`, to ask about specific items rather than listing " +
              "everything. servers: a CEL filter over the server fields, e.g. " +
              "`occupancy > 0`. analytics: Dimension=a,b;Dimension=c, e.g. " +
              "`Platform=Phone,Tablet;Country=US`.",
          ),
        limit: z
          .number()
          .int()
          .min(1)
          .max(200)
          .default(50)
          .describe("bans/inventory/servers/logs/events: how many rows to return. analytics: most breakdown series."),
        confirm: z
          .boolean()
          .optional()
          .describe(
            "Required for restart, message, ban, unban, sell, schedule and cancel. Each of these " +
              "is visible to players the moment it runs and none can be undone " +
              "from here.",
          ),
        kind: z
          .enum(["product", "pass"])
          .optional()
          .describe(
            "products/sell: 'product' is a developer product (bought again and " +
              "again: currency, boosts), 'pass' a game pass (bought once: VIP, " +
              "perks). products lists both when omitted; sell needs it.",
          ),
        itemId: z
          .string()
          .optional()
          .describe("sell only: the product or pass to change. Omit to create a new one."),
        name: z.string().optional().describe("sell only: the item's name. Required to create."),
        description: z.string().optional().describe("sell/schedule: the item's or event's description."),
        price: z.number().int().min(1).optional().describe("sell only: price in Robux."),
        forSale: z
          .boolean()
          .optional()
          .describe("sell only: whether players can buy it. Say it explicitly when creating."),
        image: z
          .string()
          .optional()
          .describe("sell only: path to a local .png/.jpg/.bmp/.tga icon."),
        metric: z.string().optional().describe("analytics only: the metric, e.g. DailyActiveUsers."),
        granularity: z
          .enum(GRANULARITIES)
          .optional()
          .describe("analytics only: size of each time bucket. Default OneDay. Which a metric allows varies."),
        breakdown: z
          .array(z.string())
          .max(3)
          .optional()
          .describe('analytics only: dimensions to split by, e.g. ["Platform"].'),
        days: z
          .number()
          .int()
          .min(1)
          .max(730)
          .optional()
          .describe("analytics only: the last N whole UTC days, not counting today. Default 7."),
        startTime: z
          .string()
          .optional()
          .describe("analytics/schedule: ISO 8601 UTC start, e.g. 2026-11-07T18:00:00Z. analytics: inclusive."),
        endTime: z.string().optional().describe("analytics/schedule: ISO 8601 UTC end. analytics: exclusive."),
        eventId: z.string().optional().describe("events/schedule/cancel: the event, as listed by `events`."),
        title: z.string().max(100).optional().describe("schedule only: the event's title."),
        subtitle: z.string().max(200).optional().describe("schedule only: a line under the title."),
        visibility: z.string().optional().describe("schedule only: e.g. public."),
      },
      destructive: true,
    },
    async (args): Promise<ToolResult> => {
      const credentials = await requireCredentials();
      const universeId = await requireUniverse(args.universeId);
      await assertTargetsOpenPlace(bridge, {
        universeId,
        explicit: args.universeId !== undefined,
      });

      const needsConfirm = ["restart", "message", "ban", "unban", "sell", "schedule", "cancel"].includes(args.op);
      if (needsConfirm && args.confirm !== true) {
        throw new ToolError(
          "NEEDS_CONFIRM",
          `\`${args.op}\` affects the live game and the people currently in it.`,
          args.op === "ban" && args.durationSeconds === undefined
            ? "This ban would be PERMANENT — no duration was given. Tell the " +
              "user that in plain words, then pass confirm: true."
            : "Nothing here can undo it. Pass confirm: true once the user has agreed.",
        );
      }

      if (args.op === "analytics") {
        if (!args.metric) {
          throw new ToolError("BAD_PARAMS", "analytics needs a `metric`, e.g. DailyActiveUsers.");
        }
        if ((args.startTime === undefined) !== (args.endTime === undefined)) {
          throw new ToolError("BAD_PARAMS", "Give both `startTime` and `endTime`, or `days`.");
        }
        const range =
          args.startTime !== undefined && args.endTime !== undefined
            ? { startTime: args.startTime, endTime: args.endTime }
            : lastDays(args.days ?? 7);
        const query = {
          universeId,
          metric: args.metric,
          granularity: args.granularity ?? "OneDay",
          ...range,
          breakdown: args.breakdown,
          filter: args.filter ? parseFilter(args.filter) : undefined,
          limit: args.limit,
        } as const;
        return text(renderSeries(query, await queryMetric(credentials, query)));
      }

      if (args.op === "events") {
        if (args.eventId) return json(await getEvent(credentials, args.eventId));
        const found = await listEvents(credentials, { universeId, limit: args.limit });
        if (found.items.length === 0) return text("This game has no scheduled events.");
        return table(["id", "title", "start", "end", "visibility"], found.items, {
          more: found.more ? "More events exist: raise `limit`." : undefined,
        });
      }

      if (args.op === "schedule") {
        return json(
          await saveEvent(credentials, {
            universeId,
            eventId: args.eventId,
            title: args.title,
            subtitle: args.subtitle,
            description: args.description,
            startTime: args.startTime,
            endTime: args.endTime,
            visibility: args.visibility,
          }),
          "Players can see this on the experience's page and RSVP to it.",
        );
      }

      if (args.op === "cancel") {
        if (!args.eventId) throw new ToolError("BAD_PARAMS", 'cancel needs an `eventId`. List them with `op="events"`.');
        return json(await cancelEvent(credentials, args.eventId));
      }

      if (args.op === "restart") {
        return json(
          await restartServers(credentials, {
            universeId,
            placeIds: args.placeId ? [Number(args.placeId)] : undefined,
            bleedOffMinutes: args.bleedOffMinutes,
          }),
        );
      }

      if (args.op === "message") {
        if (!args.topic || args.message === undefined) {
          throw new ToolError("BAD_PARAMS", "message needs both `topic` and `message`.");
        }
        return json(
          await publishMessage(credentials, {
            universeId,
            topic: args.topic,
            message: args.message,
          }),
        );
      }

      if (args.op === "bans") {
        const found = await listRestrictions(credentials, { universeId, limit: args.limit });
        const items = found["items"] as Array<Record<string, unknown>>;
        if (items.length === 0) return text("Nobody is restricted in this experience.");
        return text(
          textOf(table(["user", "active", "duration", "reason", "updated"], items)),
        );
      }

      if (args.op === "products") {
        const items = await listItems(credentials, { universeId, kind: args.kind });
        if (items.length === 0) return text("This game has no developer products or game passes yet.");
        return table(["kind", "id", "name", "price", "forSale", "created"], items, {
          more:
            `${items.length} item(s). A script sells a product with ` +
            "MarketplaceService:PromptProductPurchase and a pass with PromptGamePassPurchase.",
        });
      }

      if (args.op === "sell") {
        if (!args.kind) {
          throw new ToolError("BAD_PARAMS", 'sell needs a `kind`: "product" or "pass".');
        }
        return json(
          await saveItem(credentials, {
            universeId,
            kind: args.kind,
            id: args.itemId,
            name: args.name,
            description: args.description,
            price: args.price,
            forSale: args.forSale,
            image: args.image,
          }),
          args.kind === "product"
            ? "A developer product needs a ProcessReceipt callback on the server to grant what was bought, or purchases are charged and then refunded."
            : "Check ownership with MarketplaceService:UserOwnsGamePassAsync.",
        );
      }

      if (args.op === "servers") {
        const placeId = await requirePlace(args.placeId);
        const found = await listGameServers(credentials, {
          universeId,
          placeId,
          limit: args.limit,
          filter: args.filter,
        });
        const items = found["items"] as Array<Record<string, unknown>>;
        const partial = found["partial"] === true ? " Roblox returned a partial list; try again shortly." : "";
        if (items.length === 0) {
          return text(`No servers are running for place ${placeId}.${partial}`);
        }
        return table(["jobId", "status", "players", "uptime", "fps", "memoryMb", "version"], items, {
          more:
            `${items.length} server(s)${found["more"] === true ? ", more available — raise `limit`" : ""}. ` +
            `Read one with \`op="logs" jobId=...\`.${partial}`,
        });
      }

      if (args.op === "logs") {
        if (!args.jobId) {
          throw new ToolError("BAD_PARAMS", 'logs needs a `jobId`. List them with `op="servers"`.');
        }
        const placeId = await requirePlace(args.placeId);
        const found = await listServerLogs(credentials, {
          universeId,
          placeId,
          jobId: args.jobId,
          limit: args.limit,
          severity: args.severity,
          search: args.search,
        });
        const items = found["items"] as Array<Record<string, unknown>>;
        if (items.length === 0) {
          return text(
            `No ${args.severity ?? "error or warning"} logs for ${args.jobId}` +
              (args.search ? ` matching "${args.search}"` : "") +
              ". Logs arrive about three minutes after they are written, and a wrong " +
              "`placeId` also reads as empty.",
          );
        }
        // Newest first, one entry per block: the stack and context belong
        // to the line above them, which a table would split apart.
        const lines = items.map((entry) =>
          [
            `${String(entry["time"])} [${String(entry["level"])}] ${String(entry["message"])}` +
              (entry["repeats"] ? `  (+${String(entry["repeats"])} similar)` : ""),
            entry["stack"] ? `  ${String(entry["stack"]).trim().replace(/\n/g, "\n  ")}` : undefined,
            entry["context"] ? `  context: ${String(entry["context"])}` : undefined,
          ]
            .filter((line): line is string => line !== undefined)
            .join("\n"),
        );
        return text(
          lines.join("\n") +
            (found["more"] === true ? "\n\n[more available — raise `limit` or narrow with `search`]" : ""),
        );
      }

      if (!args.userId) {
        throw new ToolError("BAD_PARAMS", `${args.op} needs a \`userId\`.`);
      }

      if (args.op === "user") return json(await getUser(credentials, args.userId));

      if (args.op === "inventory") {
        return json(
          await getInventory(credentials, {
            userId: args.userId,
            limit: args.limit,
            filter: args.filter,
          }),
        );
      }

      return json(
        await setRestriction(credentials, {
          universeId,
          placeId: args.placeId,
          userId: args.userId,
          active: args.op === "ban",
          durationSeconds: args.durationSeconds,
          displayReason: args.displayReason,
          privateReason: args.privateReason,
          excludeAltAccounts: args.excludeAltAccounts,
        }),
      );
    },
  );
}
