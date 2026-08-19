import { z } from "zod";
import { propertiesOf, suggestClass, suggestProperty } from "../lib/apidump.js";
import { ToolError } from "../lib/errors.js";
import { table, type ToolResult } from "../lib/format.js";
import { defineTool, type ToolContext } from "../lib/tool.js";

interface MutationResponse {
  items: Array<Record<string, unknown>>;
  undoStep?: string;
}

/** What the plugin needs per property: the text, plus its type from the dump. */
interface PropertySpec {
  value: string | number | boolean;
  type: string;
}

const propertyBag = z
  .record(z.union([z.string(), z.number(), z.boolean()]))
  .optional()
  .describe(
    'Properties to set, as name → value. Values are written the way Studio\'s ' +
      'Properties panel shows them: "12, 0, 5" for a Vector3, "0.2, 0.6, 1" for ' +
      'a Color3, "Neon" or "Enum.Material.Neon" for an enum, true/false for a bool.',
  );

const attributeBag = z
  .record(z.union([z.string(), z.number(), z.boolean()]))
  .optional()
  .describe("Attributes to set, as name → value. An empty string removes one.");

const tagSpec = z
  .object({
    add: z.array(z.string()).optional().describe("CollectionService tags to add."),
    remove: z.array(z.string()).optional().describe("Tags to remove."),
  })
  .optional()
  .describe("CollectionService tags to add or remove.");

/**
 * Resolves each property to its declared type, refusing unknown ones.
 *
 * This is the reason the server holds a live API dump. A misspelled property
 * would otherwise reach Studio, fail there, and come back as an engine message
 * with no idea what was meant; here it is caught before the round trip and
 * answered with the closest real names.
 */
async function resolveProperties(
  className: string,
  properties: Record<string, string | number | boolean> | undefined,
  where: string,
): Promise<Record<string, PropertySpec> | undefined> {
  if (!properties || Object.keys(properties).length === 0) return undefined;

  const known = await propertiesOf(className);
  // No dump (offline, or a class too new for the cached copy) means passing the
  // values through untyped is better than refusing work we cannot check.
  if (known.length === 0) return undefined;

  const byName = new Map(known.map((property) => [property.name, property]));
  const resolved: Record<string, PropertySpec> = {};

  for (const [name, value] of Object.entries(properties)) {
    const info = byName.get(name);
    if (!info) {
      const suggestions = await suggestProperty(className, name);
      throw new ToolError(
        "UNKNOWN_PROPERTY",
        `${className} has no property "${name}" (${where}).`,
        suggestions.length > 0
          ? `Did you mean: ${suggestions.join(", ")}?`
          : `Call \`inspect\` with detail "full" on an existing ${className} to see ` +
            "its properties.",
      );
    }
    resolved[name] = { value, type: info.valueType };
  }
  return resolved;
}

async function assertCreatable(className: string): Promise<void> {
  const known = await propertiesOf(className);
  if (known.length > 0) return;
  const suggestions = await suggestClass(className);
  if (suggestions.length > 0) {
    throw new ToolError(
      "UNKNOWN_CLASS",
      `"${className}" is not a Roblox class.`,
      `Did you mean: ${suggestions.join(", ")}?`,
    );
  }
}

/** Recursive create spec. Typed loosely because zod cannot infer the recursion. */
interface CreateSpec {
  parent?: string;
  className: string;
  name?: string;
  properties?: Record<string, string | number | boolean>;
  attributes?: Record<string, string | number | boolean>;
  tags?: { add?: string[]; remove?: string[] };
  children?: CreateSpec[];
}

const createSpec: z.ZodType<CreateSpec> = z.lazy(() =>
  z.object({
    parent: z
      .string()
      .optional()
      .describe('Where to put it, e.g. "Workspace". Required at the top level only.'),
    className: z
      .string()
      .describe('Concrete class to create, e.g. "Part", "Folder", "Model", "SpawnLocation".'),
    name: z.string().optional().describe("Name for the new instance."),
    properties: propertyBag,
    attributes: attributeBag,
    tags: tagSpec,
    children: z
      .array(createSpec)
      .optional()
      .describe(
        "Instances to create inside this one. Build a whole model in one call " +
          "rather than creating a parent and then addressing it by a path you " +
          "have to guess.",
      ),
  }),
);

/** Walks the create tree, replacing each property bag with typed specs. */
async function typeCreateSpec(spec: CreateSpec, where: string): Promise<unknown> {
  await assertCreatable(spec.className);
  return {
    parent: spec.parent,
    className: spec.className,
    name: spec.name,
    properties: await resolveProperties(spec.className, spec.properties, where),
    attributes: spec.attributes,
    tags: spec.tags,
    children: spec.children
      ? await Promise.all(
          spec.children.map((child, index) =>
            typeCreateSpec(child, `${where} > ${spec.className}.children[${index}]`),
          ),
        )
      : undefined,
  };
}

function undoNote(response: MutationResponse): string {
  return response.undoStep
    ? `one undo step, "${response.undoStep}"`
    : "Studio would not open an undo recording, so this is not undoable as one step";
}

export function registerInstanceTools(context: ToolContext): void {
  const { bridge } = context;

  defineTool(
    context,
    {
      name: "create",
      title: "Create instances",
      description:
        "Creates instances with their properties, attributes and tags set at " +
        "creation, as one undoable step.\n\n" +
        "Nest with `children` to build a whole model in a single call. That is " +
        "both faster and safer than creating a parent and then addressing it: a " +
        "new instance's path is not knowable until it exists, and same-named " +
        "siblings make guessing it unreliable.\n\n" +
        "Property names are checked against the live Roblox API dump before " +
        "anything is sent to Studio, so a typo comes back with the closest real " +
        "names rather than an engine error.\n\n" +
        "Use `script_create` for Script, LocalScript and ModuleScript — it takes " +
        "source directly.",
      inputSchema: {
        instances: z
          .array(createSpec)
          .min(1)
          .max(100)
          .describe("Instances to create together as one undoable step."),
        studioId: z.string().optional().describe("Target Studio; omit for the active one."),
      },
    },
    async (args): Promise<ToolResult> => {
      const specs = await Promise.all(
        (args.instances as CreateSpec[]).map((spec, index) =>
          typeCreateSpec(spec, `instances[${index}]`),
        ),
      );
      const response = await bridge.call<MutationResponse>(
        "instances.create",
        { instances: specs },
        { studioId: args.studioId, timeoutMs: 30_000 },
      );
      return table(["path", "className"], response.items, { more: undoNote(response) });
    },
  );

  defineTool(
    context,
    {
      name: "modify",
      title: "Modify instances",
      description:
        "Sets properties, attributes and tags on existing instances, as one " +
        "undoable step.\n\n" +
        "Each entry takes a list of `paths`, so one entry can apply the same " +
        "change to many instances — anchoring 200 parts is one entry, not 200. " +
        "Combine with `find` to build the path list.\n\n" +
        "The batch is all-or-nothing: if any value is rejected the recording is " +
        "cancelled and every instance reverts, rather than leaving the place " +
        "half-changed.\n\n" +
        "Values use the same notation the Properties panel shows — see the " +
        "`properties` field. To change a script's code use `script_edit`.",
      inputSchema: {
        targets: z
          .array(
            z.object({
              paths: z
                .array(z.string())
                .min(1)
                .describe('Instances to change, e.g. ["Workspace.Part[3]", "Workspace.Wall"].'),
              properties: propertyBag,
              attributes: attributeBag,
              tags: tagSpec,
            }),
          )
          .min(1)
          .max(100)
          .describe("Changes to apply together as one undoable step."),
        studioId: z.string().optional().describe("Target Studio; omit for the active one."),
      },
      destructive: true,
    },
    async (args): Promise<ToolResult> => {
      // Property types depend on each instance's actual class, which is only
      // known once Studio answers, so classes are probed first — the same
      // two-pass shape `inspect` uses.
      const needsTypes = args.targets.some(
        (target) => target.properties && Object.keys(target.properties).length > 0,
      );

      let targets: unknown[] = args.targets;
      if (needsTypes) {
        const probe = await bridge.call<{
          items: Array<{ path: string; requested?: string; className: string }>;
        }>(
          "discover.inspect",
          { paths: args.targets.flatMap((target) => target.paths), includeChildren: false },
          { studioId: args.studioId },
        );
        // Correlated on the path we asked about, not the one that came back. The
        // canonical path carries an index where a name is shared, so matching on
        // it silently found nothing for exactly the ambiguous paths that most
        // need checking — and the properties were then dropped without a word.
        const classOf = new Map(
          probe.items.map((item) => [item.requested ?? item.path, item.className]),
        );

        targets = await Promise.all(
          args.targets.map(async (target, index) => {
            if (!target.properties) return target;

            const classes = [
              ...new Set(target.paths.map((path) => classOf.get(path)).filter(Boolean)),
            ] as string[];
            if (classes.length === 0) {
              throw new ToolError(
                "UNRESOLVED_TARGET",
                `Could not read the class of any path in targets[${index}].`,
                "Check the paths with `find` or `tree`. Properties are typed from " +
                  "the class, so nothing was changed rather than guessing.",
              );
            }

            // Paths in one entry can span classes and the property must exist on
            // every one, so each is checked. The types agree across classes that
            // share a property, so the last resolution stands for all of them.
            let properties: Record<string, PropertySpec> | undefined;
            for (const className of classes) {
              properties = await resolveProperties(
                className,
                target.properties,
                `targets[${index}]`,
              );
            }
            return { ...target, properties };
          }),
        );
      }

      const response = await bridge.call<MutationResponse>(
        "instances.modify",
        { targets },
        { studioId: args.studioId, timeoutMs: 30_000 },
      );
      return table(["path", "className", "changed"], response.items, {
        more: undoNote(response),
      });
    },
  );

  defineTool(
    context,
    {
      name: "delete",
      title: "Delete instances",
      description:
        "Destroys instances and everything inside them, as one undoable step.\n\n" +
        "Deleting a container deletes its whole subtree, so the response reports " +
        "how many descendants went with each one — check it before telling the " +
        "user what happened.\n\n" +
        "Services cannot be deleted and are refused. Paths shift when same-named " +
        "siblings are removed, so read fresh paths from `find` or `tree` before a " +
        "second delete rather than reusing indexes from an earlier call.",
      inputSchema: {
        paths: z
          .array(z.string())
          .min(1)
          .max(200)
          .describe('Instances to destroy, e.g. ["Workspace.OldModel"].'),
        studioId: z.string().optional().describe("Target Studio; omit for the active one."),
      },
      destructive: true,
    },
    async (args): Promise<ToolResult> => {
      const response = await bridge.call<MutationResponse>(
        "instances.delete",
        { paths: args.paths },
        { studioId: args.studioId, timeoutMs: 30_000 },
      );
      return table(["path", "className", "descendants"], response.items, {
        more: undoNote(response),
      });
    },
  );

  defineTool(
    context,
    {
      name: "move",
      title: "Move or clone instances",
      description:
        "Reparents instances, or clones them into a new parent, as one undoable " +
        "step.\n\n" +
        'Set `mode: "clone"` to copy instead of move — that is how to duplicate ' +
        "something, optionally renaming it in the same call.\n\n" +
        "Moving an instance into itself or its own descendant is refused: it " +
        "silently detaches the branch from the data model and undo does not " +
        "bring it back.",
      inputSchema: {
        items: z
          .array(
            z.object({
              path: z.string().describe("Instance to move or clone."),
              to: z.string().describe("New parent's path."),
              mode: z
                .enum(["move", "clone"])
                .default("move")
                .describe("'move' reparents the original; 'clone' leaves it and copies."),
              name: z
                .string()
                .optional()
                .describe("Rename it as part of the same step. Useful with clone."),
            }),
          )
          .min(1)
          .max(200)
          .describe("Moves to apply together as one undoable step."),
        studioId: z.string().optional().describe("Target Studio; omit for the active one."),
      },
      destructive: true,
    },
    async (args): Promise<ToolResult> => {
      const response = await bridge.call<MutationResponse>(
        "instances.move",
        { items: args.items },
        { studioId: args.studioId, timeoutMs: 30_000 },
      );
      return table(["path", "className", "cloned"], response.items, {
        more: undoNote(response),
      });
    },
  );
}
