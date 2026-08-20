import type { ToolContext } from "./lib/tool.js";

/**
 * MCP resources: place state an agent can read without spending a tool call.
 *
 * Tools cost schema tokens in every request, whether or not they are used.
 * Resources cost nothing until read, which makes them the right home for the
 * three questions asked at the start of almost every session — what is
 * connected, what is in the place, what is selected — and lets a client attach
 * them as context rather than making the model ask.
 *
 * Everything here is read-only by construction: resources have no parameters to
 * validate and no way to express a mutation, which is exactly why the state
 * queries belong here and the actions do not.
 */
export function registerResources(context: ToolContext): void {
  const { server, bridge } = context;

  const readJson = async (op: string, params: Record<string, unknown> = {}): Promise<string> => {
    // Resources have nowhere to put an error, so a failure is returned as the
    // content itself rather than thrown: a client attaching this to a prompt
    // should see why it is empty, not a blank block.
    try {
      const result = await bridge.call<unknown>(op, params, {});
      return JSON.stringify(result, null, 2);
    } catch (cause) {
      const message = cause instanceof Error ? cause.message : String(cause);
      return JSON.stringify({ unavailable: message }, null, 2);
    }
  };

  server.registerResource(
    "studio-status",
    "studio://status",
    {
      title: "Studio session",
      description:
        "Which place is open, whether it is playing, what is selected, and " +
        "which scripts the user has on screen. The cheapest orientation there is.",
      mimeType: "application/json",
    },
    async (uri) => ({
      contents: [{ uri: uri.href, mimeType: "application/json", text: await readJson("studio.status") }],
    }),
  );

  server.registerResource(
    "studio-tree",
    "studio://tree",
    {
      title: "Place hierarchy",
      description:
        "The authored containers and what is directly inside them, two levels " +
        "deep. A map of the place, without the ~120 engine services that would " +
        "bury it.",
      mimeType: "application/json",
    },
    async (uri) => ({
      contents: [
        {
          uri: uri.href,
          mimeType: "application/json",
          // Two levels and a modest cap: this is orientation, not an inventory,
          // and a resource that dumps a large place would cost more than the
          // tool call it saves.
          text: await readJson("discover.tree", { depth: 2, limit: 150, detail: "concise" }),
        },
      ],
    }),
  );

  server.registerResource(
    "studio-console",
    "studio://console",
    {
      title: "Recent output",
      description:
        "The last 100 lines Studio printed, warnings and errors included. " +
        "Reading this after a playtest is usually the first useful thing to do.",
      mimeType: "application/json",
    },
    async (uri) => ({
      contents: [
        {
          uri: uri.href,
          mimeType: "application/json",
          text: await readJson("perf.console", { limit: 100 }),
        },
      ],
    }),
  );
}
