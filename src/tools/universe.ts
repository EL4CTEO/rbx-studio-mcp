import { z } from "zod";
import { ToolError } from "../lib/errors.js";
import { json, table, text, textOf, type ToolResult } from "../lib/format.js";
import {
  getInventory,
  getUser,
  listRestrictions,
  publishMessage,
  restartServers,
  setRestriction,
} from "../lib/liveops.js";
import {
  assertTargetsOpenPlace,
  requireCredentials,
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
        "Everything here needs an Open Cloud key and a universe id. The user " +
        "sets both once with `cloud` in the Studio panel.",
      inputSchema: {
        op: z
          .enum(["restart", "message", "ban", "unban", "bans", "user", "inventory"])
          .describe(
            "'restart' rolls servers onto the new version, 'message' publishes " +
              "to MessagingService, 'ban'/'unban'/'bans' manage player access, " +
              "'user' and 'inventory' look someone up.",
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
              "experience. restart: only restart this place's servers.",
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
            'inventory only: an Open Cloud filter, e.g. `gamePassIds=123` or ' +
              "`assetIds=456`, to ask about specific items rather than listing " +
              "everything.",
          ),
        limit: z
          .number()
          .int()
          .min(1)
          .max(200)
          .default(50)
          .describe("bans/inventory: how many rows to return."),
        confirm: z
          .boolean()
          .optional()
          .describe(
            "Required for restart, message, ban and unban. Each of these is " +
              "visible to players the moment it runs and none can be undone " +
              "from here.",
          ),
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

      const needsConfirm = ["restart", "message", "ban", "unban"].includes(args.op);
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
