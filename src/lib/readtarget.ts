import { z } from "zod";
import type { StudioBridge } from "../bridge/api.js";

/** Shared by readers; studio preserves the existing selected-session behaviour. */
export const readTargetSchema = {
  target: z.enum(["studio", "client"]).default("studio").describe(
    "client: read the actual player's playtest VM. Use the playtest server studioId.",
  ),
  player: z.string().optional().describe(
    "client only: player name; required with multiple players.",
  ),
};

export const handlesSchema = z.boolean().default(false).describe(
  "Include bounded session handles usable in place of paths. Survive rename/reparent; refuse expired references.",
);

export function readCall<T>(
  bridge: StudioBridge,
  op: string,
  params: Record<string, unknown>,
  args: { target: string; player?: string; studioId?: string },
  timeoutMs = 30_000,
): Promise<T> {
  return bridge.call<T>(
    args.target === "client" ? "client.read" : op,
    args.target === "client" ? { op, params, player: args.player } : params,
    { studioId: args.studioId, timeoutMs },
  );
}

export function readContext(args: { target: string; player?: string }): string | undefined {
  return args.target === "client" ? `Read from the actual playtest client${args.player ? ` (${args.player})` : ""}.` : undefined;
}
