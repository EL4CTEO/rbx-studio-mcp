import { readFile } from "node:fs/promises";
import { basename, extname, resolve } from "node:path";
import type { Credentials } from "./credentials.js";
import { ToolError } from "./errors.js";
import { call } from "./opencloud.js";

/**
 * Developer products and game passes, over Open Cloud.
 *
 * The two are the same idea on two APIs that disagree about everything but the
 * shape: different versions, different id field names, different scopes. This
 * hides that so the tool can speak of one "item" with a `kind`.
 */
export type ItemKind = "product" | "pass";

interface RawItem {
  productId?: number;
  gamePassId?: number;
  name?: string;
  description?: string;
  isForSale?: boolean;
  priceInformation?: { defaultPriceInRobux?: number | null } | null;
  createdTimestamp?: string;
}

const API = {
  product: {
    base: (universe: string) => `/developer-products/v2/universes/${encodeURIComponent(universe)}/developer-products`,
    field: "developerProducts",
    read: "developer-product:read",
    write: "developer-product:write",
  },
  pass: {
    base: (universe: string) => `/game-passes/v1/universes/${encodeURIComponent(universe)}/game-passes`,
    field: "gamePasses",
    read: "game-pass:read",
    write: "game-pass:write",
  },
} as const;

function row(kind: ItemKind, item: RawItem): Record<string, unknown> {
  return {
    kind,
    id: item.productId ?? item.gamePassId,
    name: item.name,
    price: item.priceInformation?.defaultPriceInRobux ?? undefined,
    forSale: item.isForSale ?? false,
    created: item.createdTimestamp?.slice(0, 10),
  };
}

async function listKind(credentials: Credentials, universeId: string, kind: ItemKind): Promise<Array<Record<string, unknown>>> {
  const api = API[kind];
  const found: Array<Record<string, unknown>> = [];
  let token: string | undefined;
  // A game with more than a thousand items is not a list anyone reads; the cap
  // only exists so a broken cursor cannot loop forever.
  for (let page = 0; page < 20; page += 1) {
    const response = await call<Record<string, unknown>>(credentials, {
      path: `${api.base(universeId)}/creator`,
      query: { pageSize: 50, pageToken: token },
      scope: api.read,
    });
    for (const item of (response[api.field] as RawItem[] | null | undefined) ?? []) found.push(row(kind, item));
    token = (response["nextPageToken"] as string | null | undefined) ?? undefined;
    if (!token) break;
  }
  return found;
}

/** Every developer product and game pass the game has, or just one kind. */
export async function listItems(
  credentials: Credentials,
  args: { universeId: string; kind?: ItemKind },
): Promise<Array<Record<string, unknown>>> {
  const kinds: ItemKind[] = args.kind ? [args.kind] : ["product", "pass"];
  const lists = await Promise.all(kinds.map((kind) => listKind(credentials, args.universeId, kind)));
  return lists.flat();
}

const IMAGE_TYPES: Record<string, string> = {
  ".png": "image/png",
  ".jpg": "image/jpeg",
  ".jpeg": "image/jpeg",
  ".bmp": "image/bmp",
  ".tga": "image/x-tga",
};

/**
 * Creates an item, or updates one when `id` is given.
 *
 * A create first checks for an item of the same kind and name. Roblox allows
 * duplicates, and an agent retrying a create it thinks failed is exactly how a
 * game ends up with three "100 Coins" products that a script can only tell
 * apart by id.
 */
export async function saveItem(
  credentials: Credentials,
  args: {
    universeId: string;
    kind: ItemKind;
    id?: string;
    name?: string;
    description?: string;
    price?: number;
    forSale?: boolean;
    image?: string;
  },
): Promise<Record<string, unknown>> {
  const api = API[args.kind];
  const label = args.kind === "product" ? "developer product" : "game pass";

  if (args.id === undefined) {
    if (!args.name) throw new ToolError("BAD_PARAMS", `Creating a ${label} needs a \`name\`.`);
    const existing = (await listKind(credentials, args.universeId, args.kind)).find(
      (item) => String(item["name"]).toLowerCase() === args.name!.toLowerCase(),
    );
    if (existing) {
      throw new ToolError(
        "ALREADY_EXISTS",
        `This game already has a ${label} called "${String(existing["name"])}" (id ${String(existing["id"])}).`,
        "Pass that id as `itemId` to change it, or pick a different name.",
      );
    }
  }

  const form = new FormData();
  if (args.name !== undefined) form.append("name", args.name);
  if (args.description !== undefined) form.append("description", args.description);
  if (args.price !== undefined) form.append("price", String(args.price));
  if (args.forSale !== undefined) form.append("isForSale", String(args.forSale));
  if (args.image !== undefined) {
    const path = resolve(args.image);
    const type = IMAGE_TYPES[extname(path).toLowerCase()];
    if (!type) {
      throw new ToolError("BAD_PARAMS", `\`image\` must be a .png, .jpg, .bmp or .tga file, not ${basename(path)}.`);
    }
    let bytes: Buffer;
    try {
      bytes = await readFile(path);
    } catch (cause) {
      throw new ToolError("BAD_PARAMS", `Could not read ${path}: ${(cause as Error).message}`);
    }
    form.append("imageFile", new Blob([new Uint8Array(bytes)], { type }), basename(path));
  }

  const saved = await call<RawItem>(credentials, {
    method: args.id === undefined ? "POST" : "PATCH",
    path: args.id === undefined ? api.base(args.universeId) : `${api.base(args.universeId)}/${encodeURIComponent(args.id)}`,
    body: form,
    scope: api.write,
  });
  // PATCH answers with an empty body; the id is the one that was asked for.
  const result = row(args.kind, saved);
  return {
    ...result,
    id: result["id"] ?? (args.id !== undefined ? Number(args.id) : undefined),
    action: args.id === undefined ? "created" : "updated",
  };
}
