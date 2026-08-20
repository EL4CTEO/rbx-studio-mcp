import { z } from "zod";
import { json, text, type ToolResult } from "../lib/format.js";
import { defineTool, type ToolContext } from "../lib/tool.js";

interface DescribeResponse {
  className: string;
  superclass?: string;
  properties?: string[];
  methods?: string[];
  events?: string[];
  propertiesInherited?: number;
  methodsInherited?: number;
  eventsInherited?: number;
  propertiesDeprecated?: number;
  methodsDeprecated?: number;
  eventsDeprecated?: number;
}

interface ClassesResponse {
  classes: string[];
  matched: number;
  truncated?: number;
}

export function registerApiTools(context: ToolContext): void {
  const { bridge } = context;

  defineTool(
    context,
    {
      name: "api",
      title: "What a class can do",
      description:
        "Lists the properties, methods and events of any Roblox class, read " +
        "from the engine that is running.\n\n" +
        "Use it before writing Luau against a class you are not certain of. " +
        "Guessing a method name costs a runtime error and a round trip; this " +
        "costs one call and is never out of date, because the answer comes from " +
        "the running binary rather than from a published dump or from training " +
        "data. That matters most for exactly the classes worth checking — new " +
        "ones, and ones that changed recently.\n\n" +
        "Members come back as signatures rather than bare names — " +
        "`AddAccessory(accessory: Instance)`, `HoldDuration: number` — because a " +
        "name tells you something exists and a signature tells you how to call " +
        "it, which is the actual question.\n\n" +
        "`describe` takes a class name and gives the members it declares itself, " +
        "counting the inherited ones separately. `classes` searches class names, " +
        "which is how to find one whose exact spelling you do not have.\n\n" +
        "Deprecated members are never listed, only counted — `Instance` has " +
        "eight, including `clone`, `remove` and `getChildren`. They still run, " +
        "so picking one from a list gives you working code and a deprecation " +
        "warning in the user's output.\n\n" +
        "This is not the same as `inspect`. `inspect` reads the values on an " +
        "instance that exists; this reads the shape of a class whether or not " +
        "anything in the place is one — which is what you need when deciding " +
        "what to create in the first place.",
      inputSchema: {
        op: z
          .enum(["describe", "classes"])
          .default("describe")
          .describe("'describe' details one class, 'classes' searches class names."),
        className: z
          .string()
          .optional()
          .describe(
            'describe only: the class, e.g. "TweenService", "ProximityPrompt", "Humanoid". Case-sensitive.',
          ),
        contains: z
          .string()
          .optional()
          .describe(
            'classes only: substring to match, case-insensitive, e.g. "constraint" or "gui". Omit to list everything.',
          ),
        include: z
          .array(z.enum(["properties", "methods", "events"]))
          .optional()
          .describe(
            "describe only: which member kinds to return. Defaults to all " +
              "three; narrow it when you only need one and the class is large.",
          ),
        inherited: z
          .boolean()
          .default(false)
          .describe(
            "describe only: include members inherited from Instance and Object. " +
              "Off by default because they swamp the answer — ProximityPrompt has " +
              "2 methods of its own and 42 inherited, and the two you want are not " +
              "the ones you already know. The inherited count is reported either way.",
          ),
        studioId: z.string().optional().describe("Target Studio; omit for the active one."),
      },
      readOnly: true,
    },
    async (args): Promise<ToolResult> => {
      if (args.op === "classes") {
        const response = await bridge.call<ClassesResponse>(
          "api.classes",
          { contains: args.contains },
          { studioId: args.studioId },
        );
        if (response.matched === 0) {
          return text(
            `No class name contains ${JSON.stringify(args.contains ?? "")}.\n` +
              "The match is a plain substring, case-insensitive — try a shorter one.",
          );
        }
        return json(
          response.classes,
          response.truncated
            ? `${response.matched} matched; ${response.truncated} not shown. Narrow with \`contains\`.`
            : `${response.matched} matched.`,
        );
      }

      if (args.className === undefined || args.className === "") {
        return text('describe needs a `className`. Use `op: "classes"` to search for one.');
      }

      const response = await bridge.call<DescribeResponse>(
        "api.describe",
        { className: args.className, include: args.include, inherited: args.inherited },
        { studioId: args.studioId },
      );
      return json(response);
    },
  );
}
