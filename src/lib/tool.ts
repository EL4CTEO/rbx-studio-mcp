import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z, type ZodRawShape } from "zod";
import type { StudioBridge } from "../bridge/api.js";
import { toToolError } from "./errors.js";
import { errorText, type ToolResult } from "./format.js";

/** Everything a tool module needs, passed once at registration. */
export interface ToolContext {
  server: McpServer;
  bridge: StudioBridge;
}

export interface ToolSpec<Shape extends ZodRawShape> {
  name: string;
  /** Short human label shown in client tool pickers. */
  title: string;
  /**
   * Sent to the model verbatim, so it must say what the tool does, when to
   * reach for it, and when to reach for a different one instead. This is the
   * single biggest lever on whether an agent picks the right tool.
   */
  description: string;
  inputSchema: Shape;
  readOnly?: boolean;
  /** True only for tools that can remove or overwrite the user's work. */
  destructive?: boolean;
  idempotent?: boolean;
}

/**
 * Registers a tool with consistent annotations and a single error boundary.
 *
 * Failures come back as `isError` content rather than a protocol-level error:
 * the agent can read the hint and correct itself, where a transport error just
 * aborts the turn.
 */
/**
 * Parsed argument object for a tool declared with `inputSchema: Shape`.
 *
 * Zod 4 dropped `objectOutputType`, so this goes through `z.object` and infers
 * the result — the same type, derived rather than named.
 */
export type ToolArgs<Shape extends ZodRawShape> = z.infer<z.ZodObject<Shape>>;

export function defineTool<Shape extends ZodRawShape>(
  context: ToolContext,
  spec: ToolSpec<Shape>,
  handler: (args: ToolArgs<Shape>) => Promise<ToolResult>,
): void {
  const readOnly = spec.readOnly ?? false;
  context.server.registerTool(
    spec.name,
    {
      title: spec.title,
      description: spec.description,
      inputSchema: spec.inputSchema,
      annotations: {
        title: spec.title,
        readOnlyHint: readOnly,
        destructiveHint: spec.destructive ?? !readOnly,
        idempotentHint: spec.idempotent ?? readOnly,
        // Studio is a live external process whose state we do not control.
        openWorldHint: true,
      },
    },
    (async (args: ToolArgs<Shape>) => {
      try {
        return await handler(args);
      } catch (cause) {
        const error = toToolError(cause);
        return errorText(`[${error.code}] ${error.message}`);
      }
    }) as never,
  );
}
