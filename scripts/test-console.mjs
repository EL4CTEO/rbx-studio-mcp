/**
 * Checks the console panel's command line and the agents it starts.
 *
 * Everything here is a pure function or a call against a real Bridge with fake
 * Studio sessions -- no sockets, no Studio, and above all no agent processes.
 * That last one is the constraint that shapes the file: the interesting code is
 * "start a coding agent and stream it back", and a test that actually did so
 * would cost money, need an API key, and take a minute. So the seam is
 * `harness.read`, which turns one line of a harness's output into console rows
 * and is where every adapter's real work lives.
 *
 * The event shapes below are recorded from live runs of each CLI, not invented.
 * A test built on a guessed envelope passes forever and proves nothing.
 */
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { Bridge } from "../dist/bridge/rpc.js";
import { LocalBridge } from "../dist/bridge/api.js";
import { frame, handleConsole } from "../dist/bridge/console.js";
import { find, installed } from "../dist/bridge/harness.js";

let checks = 0;
const ok = (condition, what) => {
  assert.ok(condition, what);
  checks += 1;
};

/** Every row a harness produces for one line of its output. */
const readAll = (id, lines) => {
  const harness = find(id);
  const rows = [];
  let session = null;
  for (const line of lines) {
    const reading = harness.read(line);
    if (reading.session !== undefined) session = reading.session;
    rows.push(...reading.lines);
  }
  return { rows, session };
};

// --- Claude Code -----------------------------------------------------------
{
  const { rows, session } = readAll("claude", [
    JSON.stringify({ type: "system", subtype: "init", session_id: "abc-123" }),
    JSON.stringify({
      type: "assistant",
      message: {
        content: [
          { type: "text", text: "Looking at the place." },
          {
            type: "tool_use",
            name: "mcp__rbx-studio__create",
            input: { instances: [], parent: "Workspace" },
          },
        ],
      },
    }),
    "not json at all",
    JSON.stringify({ type: "result", duration_ms: 5600, total_cost_usd: 0.1282 }),
  ]);

  ok(session === "abc-123", "claude: session id is learned from the init event");
  ok(rows.length === 3, "claude: init contributes no row, junk lines are ignored");
  ok(rows[0].level === "reply" && rows[0].message === "Looking at the place.", "claude: prose");
  ok(rows[1].level === "call" && rows[1].message === "create", "claude: server prefix is stripped");
  ok(rows[2].level === "ok" && rows[2].message === "agent done", "claude: result row");
  ok(rows[2].detail === "5.6s  $0.1282", "claude: duration and cost ride the detail column");

  // A failure must not be reported as a completion. This is the one row a user
  // reads to decide whether to trust what just happened to their place.
  const failed = readAll("claude", [
    JSON.stringify({ type: "result", is_error: true, duration_ms: 100 }),
  ]);
  ok(failed.rows[0].level === "error", "claude: is_error becomes an error row");
}

// --- Tool arguments --------------------------------------------------------
{
  // Regression: a Luau snippet passed to execute_luau is multi-line, and 32
  // characters of it used to carry a newline into a log whose rows are lines.
  // The visible symptom was a stray "m" sitting at column 0 under the entry.
  const { rows } = readAll("claude", [
    JSON.stringify({
      type: "assistant",
      message: {
        content: [
          {
            type: "tool_use",
            name: "mcp__rbx-studio__execute_luau",
            input: { source: "local m = workspace.SmallHouse\nm.Parent = nil\nprint(m)" },
          },
        ],
      },
    }),
  ]);
  ok(!rows[0].detail.includes("\n"), "tool detail never contains a newline");
  ok(rows[0].message === "execute_luau", "tool name keeps its own underscores");
}

// --- Codex and opencode ----------------------------------------------------
{
  const codex = readAll("codex", [
    JSON.stringify({ type: "session.created", session_id: "cx-1" }),
    JSON.stringify({ type: "agent_message", text: "Done." }),
  ]);
  ok(codex.session === "cx-1", "codex: session id");
  ok(codex.rows[0].level === "reply" && codex.rows[0].message === "Done.", "codex: prose");

  const oc = readAll("opencode", [
    JSON.stringify({
      type: "message.part.updated",
      properties: { part: { type: "text", text: "Placed the model." } },
    }),
  ]);
  ok(oc.rows[0].message === "Placed the model.", "opencode: prose");
}

// --- DeepSeek Harness ------------------------------------------------------
{
  const dsh = find("dsh");
  const argv = dsh.argv("add a spawn point", null);

  // `dsh [options] [command] [args...]`: --patch is a launcher option and the
  // prompt is a positional argument, so the flag has to come first. Getting
  // this backwards is silent -- dsh reads the prompt as the patch path.
  const patchAt = argv.indexOf("--patch");
  ok(patchAt !== -1, "dsh: the overlay is passed");
  ok(
    patchAt < argv.indexOf("add a spawn point"),
    "dsh: --patch comes before the prompt, or dsh reads the prompt as a path",
  );
  ok(argv[argv.length - 1] === "add a spawn point", "dsh: the prompt is last");
  ok(dsh.mcpFlag === undefined, "dsh: builds its own argv rather than appending flags");

  const { rows } = readAll("dsh", ["The spawn point is placed.", "   ", ""]);
  ok(rows.length === 1, "dsh: blank lines are not rows");
  ok(rows[0].level === "reply", "dsh: headless prints prose, not events");
}

// --- The registry ----------------------------------------------------------
{
  ok(find("claude") !== undefined && find("nonesuch") === undefined, "registry: lookup by id");
  ok(
    installed().every((entry) => typeof entry.id === "string" && entry.id.length > 0),
    "registry: every detected harness is named",
  );
}

// --- Panel-started agents are not other people's clients -------------------
{
  const bridge = new Bridge();
  const announcements = [];
  bridge.watchClients((count) => announcements.push(count));

  const mine = new LocalBridge(bridge);
  ok(bridge.clientCount() === 1, "an ordinary client counts");

  // What a spawned agent's own server reports when it says hello. Counting it
  // flashed the badge to 2 and logged an arrival and a departure around every
  // single prompt -- around output the user was trying to read.
  bridge.noteClient("spawned-agent", { name: "claude-code", pid: 42, spawned: true });
  ok(bridge.clientCount() === 1, "a panel-started agent is not counted");
  ok(
    bridge.clientList().every((client) => client.name !== "claude-code"),
    "a panel-started agent is not in the roster",
  );
  ok(
    announcements.every((count) => count <= 1),
    "a panel-started agent never announces an arrival",
  );

  mine.goodbye();
}

// --- Command routing -------------------------------------------------------
{
  const bridge = new Bridge();
  const identity = (studioId, placeId, placeName) => ({
    studioId,
    placeName,
    placeId,
    pluginVersion: "test",
    buildId: "test",
    protocolVersion: 1,
    transport: "poll",
    context: "edit",
  });
  bridge.attach(identity("studio-a", 111, "Alpha"), null);
  bridge.attach(identity("studio-b", 222, "Beta"), null);

  const run = (command, args = []) =>
    handleConsole(bridge, 44755, { studioId: "studio-a", command, args, line: command });

  const studios = await run("studios");
  ok(studios.length === 3, "studios: a heading and one row per Studio");
  ok(
    studios.some((row) => row.message.includes("(this panel)")),
    "studios: the asking panel is marked, so two rows with one place name are told apart",
  );

  // `use` takes the number printed by `studios`, because requiring the id would
  // mean reading a hex string off one line to type it into the next.
  const used = await run("use", ["2"]);
  ok(used[0].level === "ok" && used[0].message.includes("Beta"), "use: resolves a list number");
  ok(bridge.activeId("nobody-in-particular") === "studio-b", "use: applies to clients too");

  const bad = await run("use", ["nope"]);
  ok(bad[0].level === "error", "use: an unknown target is an error, not a silent no-op");
  ok(bridge.activeId("nobody") === "studio-b", "use: a failed switch changes nothing");

  const noArg = await run("use");
  ok(noArg[0].message.startsWith("usage:"), "use: says how to use it");

  const stopped = await run("stop");
  ok(stopped[0].message === "nothing is running", "stop: honest when idle");

  const agents = await run("agent");
  ok(agents.length > 0, "agent: always answers, installed or not");

  const unknown = await run("wat");
  ok(unknown[0].level === "error", "an unknown command is reported, not guessed at");
  ok(
    unknown[0].detail.includes("different builds"),
    "an unknown command names the likely cause, since the plugin filters first",
  );
}

// --- doctor ----------------------------------------------------------------
{
  const bridge = new Bridge();
  // A port nothing is listening on: doctor must still answer, because "why is
  // nothing working" is exactly when it is run.
  const rows = await handleConsole(bridge, 45999, {
    studioId: "studio-a",
    command: "doctor",
    args: [],
    line: "doctor",
  });
  ok(rows.length > 1, "doctor: reports against a dead port rather than failing");
  ok(
    rows.every((row) => typeof row.message === "string" && !row.message.includes("\n")),
    "doctor: every row is one line",
  );
  const summary = rows[rows.length - 1];
  ok(/passed.*warning.*failure/.test(summary.message), "doctor: ends with a tally");
}

// The framing preamble --------------------------------------------------------
//
// The shipped bug: "create a simple script, then edit it" sent the agent to the
// filesystem, because that is where a coding agent spawned in a repo assumes a
// script lives. It tried Bash, was refused, and reported the test impossible.
{
  const framed = frame("make the door open");
  ok(framed.endsWith("make the door open"), "frame: the user's words come last and unaltered");
  ok(/Roblox Studio/.test(framed), "frame: says where the prompt came from");
  ok(/script_create|script_edit/.test(framed), "frame: names the tools that reach the place");
  ok(!framed.includes(String.fromCharCode(13)), "frame: no stray carriage returns");
  // A framing that swallows an empty prompt would send the agent a wall of
  // instructions and no request.
  ok(frame("").trim().length > 0, "frame: survives an empty prompt");
}

// The spawned marker reaches the server the agent starts ----------------------
//
// The shipped bug: the agent inherited RBX_STUDIO_MCP_SPAWNED, but the agent is
// not what connects -- it launches its own copy of this server, and Claude did
// not pass its environment down. So the spawned server announced itself as a
// stranger: "2 MCP clients connected" on every prompt, and a stopped agent sat
// in `clients` until the stale timeout swept it.
{
  const claude = find("claude");
  ok(claude !== undefined, "registry: claude is registered");
  const flag = claude.mcpFlag();
  ok(flag[0] === "--mcp-config", "claude: passes an mcp config file");
  const written = JSON.parse(readFileSync(flag[1], "utf8"));
  const server = written.mcpServers["rbx-studio"];
  ok(server !== undefined, "claude config: names this server");
  ok(
    server.env?.RBX_STUDIO_MCP_SPAWNED === "1",
    "claude config: marks the server it starts as spawned by the panel",
  );

  const dsh = find("dsh");
  const argv = dsh.argv("hello");
  const patch = argv[argv.indexOf("--patch") + 1];
  ok(
    readFileSync(patch, "utf8").includes("RBX_STUDIO_MCP_SPAWNED: '1'"),
    "dsh overlay: carries the same marker",
  );
}

process.stdout.write(`console: ${checks} checks pass\n`);
