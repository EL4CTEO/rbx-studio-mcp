#!/usr/bin/env node
/**
 * Drives a real, connected Studio through the running bridge and checks the
 * paths no fake can: big payloads over the actual stream, and scripts that
 * survive a create -> read -> edit -> delete round trip.
 *
 * Not part of `npm test`, because it needs Studio open with the plugin. It
 * exists because the worst transport bug this project had -- any command the
 * stream delivered in more than one piece was dropped, so a big `script_create`
 * timed out -- passed every offline test and only showed up against Studio.
 *
 * Everything it makes is named `__mcp_live_*` under ServerScriptService and is
 * deleted before it exits, pass or fail.
 *
 * Usage: node scripts/test-live.mjs [--port 44755] [--sizes 1000,16000,64000,256000] [--client] [--remotes] [--playtest-start] [--playtest-op play|multiplayer] [--stale-cursor CURSOR] [--playtests-off] [--studio-id ID] [--player NAME]
 */
import { expectedPluginBuildId } from "../dist/lib/pluginbuild.js";

const args = process.argv.slice(2);
const flag = (name, fallback) => {
  const at = args.indexOf(`--${name}`);
  return at === -1 ? fallback : args[at + 1];
};
const port = Number.parseInt(flag("port", "44755"), 10);
const sizes = flag("sizes", "1000,16000,64000,256000").split(",").map(Number);
const base = `http://127.0.0.1:${port}`;
const HEADERS = {
  "x-roblox-studio-mcp": "test-live",
  "x-roblox-studio-mcp-peer": `test-live-${process.pid}`,
  "content-type": "application/json",
};
const PREFIX = "__mcp_live_";

async function call(op, params, timeoutMs = 20_000) {
  const response = await fetch(`${base}/call`, {
    method: "POST",
    headers: HEADERS,
    body: JSON.stringify({ op, params, timeoutMs, studioId: flag("studio-id", undefined) }),
  });
  const body = await response.json();
  if (!body.ok) throw new Error(`${op}: [${body.error?.code}] ${body.error?.message}`);
  return body.data;
}

async function callTo(studioId, op, params, timeoutMs = 20_000) {
  const response = await fetch(`${base}/call`, {
    method: "POST", headers: HEADERS,
    body: JSON.stringify({ op, params, timeoutMs, studioId }),
  });
  const body = await response.json();
  if (!body.ok) throw new Error(`${op}: [${body.error?.code}] ${body.error?.message}`);
  return body.data;
}

/** Luau source of about `size` bytes, with quotes and non-ASCII so escaping is exercised. */
function sourceOf(size) {
  const lines = [];
  let length = 0;
  for (let index = 0; length < size; index += 1) {
    const line = `local value${index} = "line ${index}: \\"quoted\\" ünïcode ✓"`;
    lines.push(line);
    length += line.length + 1;
  }
  return lines.join("\n");
}

let sessions;
try {
  sessions = await (await fetch(`${base}/sessions`, { headers: HEADERS })).json();
} catch {
  process.stderr.write(`Nothing is listening on port ${port}. Start the MCP server and open Studio.\n`);
  process.exit(1);
}
const studio = flag("studio-id", undefined)
  ? sessions.list.find((entry) => entry.studioId === flag("studio-id"))
  : sessions.list[0];
if (studio === undefined) {
  process.stderr.write("The bridge is up but no Studio is connected.\n");
  process.exit(1);
}
if (studio.buildId !== expectedPluginBuildId()) {
  process.stderr.write(
    `warning: Studio runs plugin build ${studio.buildId}, this checkout is ` +
      `${expectedPluginBuildId()}. Results describe the plugin Studio has loaded.\n`,
  );
}
process.stdout.write(`Studio: ${studio.placeName} (${studio.transport})\n`);

const created = [];
let failures = 0;
const check = (ok, what) => {
  process.stdout.write(`${ok ? "ok  " : "FAIL"}  ${what}\n`);
  if (!ok) failures += 1;
};

try {
  for (const size of sizes) {
    const name = `${PREFIX}${size}`;
    const source = sourceOf(size);
    const started = Date.now();
    try {
      await call("script.create", {
        scripts: [{ parent: "ServerScriptService", name, className: "ModuleScript", source }],
      });
      created.push(`ServerScriptService.${name}`);
      const read = await call("script.read", { paths: [`ServerScriptService.${name}`] });
      const item = read.items[0];
      check(item?.source === source, `${size} bytes: create + read back identical (${Date.now() - started}ms)`);

      const edited = await call("script.edit", {
        edits: [{ path: `ServerScriptService.${name}`, find: "local value0 =", replace: "local first =", revision: item.revision }],
      });
      check(edited.items[0]?.edits === 1, `${size} bytes: conditional edit applied`);
    } catch (cause) {
      check(false, `${size} bytes: ${cause.message}`);
    }
  }
} finally {
  if (created.length > 0) {
    await call("instances.delete", { paths: created }).catch((cause) => {
      process.stderr.write(`cleanup failed, delete ${created.join(", ")} by hand: ${cause.message}\n`);
    });
  }
}

// --client requires a running playtest with this checkout's plugin loaded.
// --studio-id selects its server session; --player supports multiplayer tests.
if (args.includes("--client")) {
  if (studio.buildId !== expectedPluginBuildId()) {
    check(false, "client checks require the current plugin build; reload the plugin first");
  } else {
    const client = (source, timeoutSeconds = 5) => call("exec.run", {
      target: "client", player: flag("player", undefined), source, timeoutSeconds,
    }, (timeoutSeconds + 10) * 1000);
    try {
      const identity = await client('return game:GetService("RunService"):IsClient(), game:GetService("Players").LocalPlayer.Name');
      check(identity.ok && identity.returned[0] === true && typeof identity.returned[1] === "string", "exec runs in the actual client VM");
      const playerName = identity.returned[1];
      const baseline = await call("perf.console", {target:"client",player:playerName,limit:10});
      check(baseline.capturing === true && typeof baseline.nextCursor === "string", "persistent client diagnostics relay is ready");
      const diagnosticPath = `Players.${playerName}.PlayerGui.__mcp_live_diagnostics`;
      try {
        await call("script.create", {scripts:[{parent:`Players.${playerName}.PlayerGui`,name:"__mcp_live_diagnostics",className:"LocalScript",source:'print("mcp live client print"); warn("mcp live client warning"); error("mcp live client error")'}]});
        let captured;
        for (let attempt = 0; attempt < 20; attempt += 1) {
          captured = await call("perf.console", {target:"client",player:playerName,since:baseline.nextCursor,limit:20});
          if (captured.items.some(item => item.message.includes("mcp live client error"))) break;
          await new Promise(resolve => setTimeout(resolve, 200));
        }
        check(captured.items.some(item => item.message.includes("mcp live client print") && item.level === "print") &&
          captured.items.some(item => item.message.includes("mcp live client warning") && item.level === "warning") &&
          captured.items.some(item => item.message.includes("mcp live client error") && item.level === "error"),
          "console captures LocalScript output outside execute_luau");
        check(captured.items.some(item => item.level === "error" && item.stack && item.source), "client errors include stack and source");
        const incremental = await call("perf.console", {target:"client",player:playerName,since:captured.nextCursor,limit:20});
        check(incremental.items.length === 0, "client console cursor does not repeat old output");
        const runtimeState = await call("playtest.control", {op:"state"});
        const other = runtimeState.state.players?.find(player => player.name !== playerName);
        if (other) {
          const second = await call("perf.console", {target:"client",player:other.name,limit:20});
          check(!second.items.some(item => item.message.includes("mcp live client error")), "multiplayer client logs stay with their player");
          try {
            await call("perf.console", {target:"client",player:other.name,since:captured.nextCursor});
            check(false, "a cursor from another player is rejected");
          } catch (cause) {
            check(cause.message.includes("BAD_CURSOR"), "a cursor from another player is rejected");
          }
        }
      } finally {
        await call("instances.delete", {paths:[diagnosticPath]}).catch(() => {});
      }
      const values = await client('print("client print"); warn("client warning"); local t = {}; t.self = t; return 1, nil, t, Vector3.new(1,2,3)');
      check(values.ok && values.returned[1] === "nil" && values.returned[2].self === "<circular reference>", "client structured values preserve nil and cycles");
      check(values.output.some(v => v.message.includes("client print")) && values.output.some(v => v.level === "warning"), "client prints and warnings captured");
      const bounds = await client('for i=1,220 do print(i) end; local t = {}; for i=1,60 do t[i]=i end; return t,2,3,4,5,6,7,8,9,10,11');
      check(bounds.ok && bounds.output.length === 200 && bounds.returned.length === 10 && bounds.returned[0].length === 51, "client output limits match Studio execution");
      const failed = await client('print("before error"); error("client failure")');
      check(!failed.ok && failed.error.includes("client failure") && failed.output.length > 0, "runtime failures retain output");
      const syntax = await client('local =');
      check(!syntax.ok && typeof syntax.error === "string", "client syntax errors are reported");
      const timeout = await client('task.wait(30)', 1);
      check(!timeout.ok && timeout.error.includes("CLIENT_TIMEOUT"), "yielding client execution times out cleanly");
      await call("script.create", { scripts: [{ parent: "ReplicatedStorage", name: "__mcp_live_cache", className: "ModuleScript", source: "return {count = 0}" }] });
      await client('local t = require(game.ReplicatedStorage.__mcp_live_cache); t.count = 42');
      const cached = await client('return require(game.ReplicatedStorage.__mcp_live_cache).count');
      check(cached.ok && cached.returned[0] === 42, "separate client calls share the client module cache");
      const gui = await client(`
local gui = Instance.new("ScreenGui"); gui.Name = "__mcp_live_gui"; gui.ResetOnSpawn = false
local button = Instance.new("TextButton"); button.Name = "BuyButton"; button.Size = UDim2.fromOffset(160,60); button.Position = UDim2.fromOffset(100,100); button.Parent = gui
local box = Instance.new("TextBox"); box.Name = "NameBox"; box.Size = UDim2.fromOffset(160,60); box.Position = UDim2.fromOffset(100,200); box.Text = ""; box.Parent = gui
gui.Parent = game.Players.LocalPlayer.PlayerGui
return true`);
      check(gui.ok, "client-only GUI fixture created");
      const typed = await call("input.send", { player: flag("player", undefined), cursor: false, steps: [{kind: "text", target: "PlayerGui.__mcp_live_gui.NameBox", text: "bridge"}] });
      const text = await client('return game.Players.LocalPlayer.PlayerGui.__mcp_live_gui.NameBox.Text');
      check(typed.delivered && text.returned[0] === "bridge", "GUI target focuses and types into the client TextBox");
      const clicked = await call("input.send", { player: flag("player", undefined), cursor: false, steps: [{kind: "click", target: "PlayerGui.__mcp_live_gui.BuyButton"}] });
      const centre = await client('local b=game.Players.LocalPlayer.PlayerGui.__mcp_live_gui.BuyButton; return b.AbsolutePosition.X+b.AbsoluteSize.X/2, b.AbsolutePosition.Y+b.AbsoluteSize.Y/2');
      check(clicked.landed && Math.abs(clicked.landed.seen.x-centre.returned[0]) < 2 && Math.abs(clicked.landed.seen.y-centre.returned[1]) < 2, "GUI click lands at the actual client centre");
      const missing = await call("input.send", { player: flag("player", undefined), cursor: false, steps: [{kind:"click",target:"PlayerGui.__missing"}] });
      check(missing.notes?.some(note => note.includes("not found")), "missing GUI path reports a failure");
      const clean = await call("exec.run", { source: 'local n=0; for _,p in game.Players:GetPlayers() do for _,v in p.PlayerGui:GetChildren() do if v.Name == "MCPExecRelay" or v.Name == "MCPInputRelay" then n+=1 end end end; return n' });
      check(clean.returned[0] === 0, "temporary relay instances are removed after success, failure and timeout");
    } catch (cause) {
      check(false, `client: ${cause.message}`);
    } finally {
      await client('local g=game.Players.LocalPlayer.PlayerGui:FindFirstChild("__mcp_live_gui"); if g then g:Destroy() end').catch(() => {});
      await call("instances.delete", {paths:["ReplicatedStorage.__mcp_live_cache"]}).catch(() => {});
    }
  }
}

// --remotes can run independently of GUI/input checks. The fixture's normal
// server Script and LocalScript remain connected before, during and after tracing.
if (args.includes("--remotes")) {
  if (studio.buildId !== expectedPluginBuildId()) {
    check(false, "remote tracing checks require the current plugin build");
  } else {
    const client = (source) => call("exec.run", {target:"client",player:flag("player",undefined),source,timeoutSeconds:10}, 20000);
    const root = "ReplicatedStorage.__mcp_live_remotes";
    const serverPath = "ServerScriptService.__mcp_live_remote_server";
    let clientPath;
    let capture;
    const fixturePaths = [];
    try {
      const identity = await client('return game.Players.LocalPlayer.Name');
      if (!identity.ok) throw new Error(identity.error);
      const player = identity.returned[0];
      clientPath = `Players.${player}.PlayerGui.__mcp_live_remote_client`;
      const setup = await call("exec.run", {source:`
assert(not game.ReplicatedStorage:FindFirstChild("__mcp_live_remotes"), "fixture already exists")
assert(not game.ServerScriptService:FindFirstChild("__mcp_live_remote_server"), "server fixture already exists")
assert(not game.Players[${JSON.stringify(player)}].PlayerGui:FindFirstChild("__mcp_live_remote_client"), "client fixture already exists")
local folder = Instance.new("Folder"); folder.Name = "__mcp_live_remotes"; folder.Parent = game.ReplicatedStorage
for _, name in {"Request", "Reply"} do local r=Instance.new("RemoteEvent"); r.Name=name; r.Parent=folder end
return true`});
      if (!setup.ok) throw new Error(setup.error);
      fixturePaths.push(root, serverPath, clientPath);
      await call("script.create", {scripts:[{parent:"ServerScriptService",name:"__mcp_live_remote_server",className:"Script",source:`
local root = game.ReplicatedStorage:WaitForChild("__mcp_live_remotes")
root:WaitForChild("Request").OnServerEvent:Connect(function(player, ...)
 local args = table.pack(...)
 root:SetAttribute("ServerCount", (root:GetAttribute("ServerCount") or 0) + 1)
 root:SetAttribute("ServerValid", args.n == 3 and args[2] == nil and args[3].level == 37)
 root.Reply:FireClient(player, args[1], nil, args[3].level)
end)
root:SetAttribute("Ready", true)`}, {parent:`Players.${player}.PlayerGui`,name:"__mcp_live_remote_client",className:"LocalScript",source:`
local root = game.ReplicatedStorage:WaitForChild("__mcp_live_remotes")
root:WaitForChild("Reply").OnClientEvent:Connect(function(...)
 local args = table.pack(...)
 script:SetAttribute("ClientCount", (script:GetAttribute("ClientCount") or 0) + 1)
 script:SetAttribute("ClientValid", args.n == 3 and args[2] == nil and args[3] == 37)
end)
script:SetAttribute("Ready", true)`}]});
      const send = (phase, count, expected, waitForTrace = false) => client(`
local root = game.ReplicatedStorage:WaitForChild("__mcp_live_remotes")
local gui = game.Players.LocalPlayer.PlayerGui
local handler = gui:WaitForChild("__mcp_live_remote_client")
local deadline = os.clock()+8
repeat task.wait() until (root:GetAttribute("Ready") and handler:GetAttribute("Ready")) or os.clock()>deadline
assert(root:GetAttribute("Ready") and handler:GetAttribute("Ready"), "fixture startup timed out")
${waitForTrace ? `repeat task.wait() until (gui:FindFirstChild("MCPRemoteTraceRelay") and gui.MCPRemoteTraceRelay:GetAttribute("Capturing")) or os.clock()>deadline
assert(gui:FindFirstChild("MCPRemoteTraceRelay") and gui.MCPRemoteTraceRelay:GetAttribute("Capturing"), "trace startup timed out")` : ""}
for i=1,${count} do root.Request:FireServer("${phase}", nil, {level=37, nested={more={hidden=true}}}); task.wait(0.05) end
repeat task.wait() until (handler:GetAttribute("ClientCount") or 0)>=${expected} or os.clock()>deadline
return handler:GetAttribute("ClientCount"), handler:GetAttribute("ClientValid")`);
      const before = await send("before", 1, 1);
      check(before.ok && before.returned[0] === 1 && before.returned[1] === true, "fixture delivers normal traffic before tracing");
      capture = call("debug.remotes", {path:root,player,seconds:4}, 20000);
      // Attach a rejection handler immediately while the traffic call is running.
      capture.catch(() => {});
      const during = await send("during", 3, 4, true);
      const trace = await capture;
      check(during.ok && during.returned[0] === 4 && during.returned[1] === true, "client handlers receive unchanged arguments during tracing");
      const upstream = trace.items.find(row => row.path.endsWith(".Request") && row.direction === "client -> server");
      const downstream = trace.items.find(row => row.path.endsWith(".Reply") && row.direction === "server -> client");
      check(upstream?.count === 3 && downstream?.count === 3 && trace.events === 6, "trace counts both directions without counting relay traffic");
      check(upstream?.player === player && downstream?.player === player && upstream.callsPerSecond > 0 && downstream.callsPerSecond > 0, "trace identifies the player and reports rates");
      check(upstream?.samples.some(sample => sample.includes("nil:nil") && sample.includes("table")), "trace summarizes argument shapes and nil positions");
      check(Buffer.byteLength(JSON.stringify(trace)) <= 12000, "trace response obeys the hard size cap");
      const after = await send("after", 1, 5);
      check(after.ok && after.returned[0] === 5 && after.returned[1] === true, "client handlers still work after tracing cleanup");
      const server = await call("exec.run", {source:'local f=game.ReplicatedStorage.__mcp_live_remotes; return f:GetAttribute("ServerCount"), f:GetAttribute("ServerValid")'});
      check(server.ok && server.returned[0] === 5 && server.returned[1] === true, "server handler received every call exactly once with unchanged arguments");
      const clean = await call("exec.run", {source:'for _,p in game.Players:GetPlayers() do if p.PlayerGui:FindFirstChild("MCPRemoteTraceRelay") then return false end end; return true'});
      check(clean.ok && clean.returned[0] === true, "tracing removes temporary client relay instances");
      const again = await call("debug.remotes", {path:root,player,seconds:1}, 16000);
      check(again.events === 0, "a later capture starts empty and stops without traffic");
    } catch (cause) {
      check(false, `remotes: ${cause.message}`);
    } finally {
      if (capture) await capture.catch(() => {});
      if (fixturePaths.length) await call("instances.delete", {paths:fixturePaths}).catch(cause => {
        check(false, `remote fixture cleanup: ${cause.message}`);
      });
    }
  }
}

// Set `playtests off` in the panel first. This opt-in check never attempts a
// start unless Studio has confirmed OFF, and can be rerun after a Studio restart.
if (args.includes("--playtests-off")) {
  try {
    const before = await call("playtest.control", {op:"state"});
    if (before.state.playtestsAllowed !== false) {
      check(false, "Set playtests off in the Studio MCP panel before running --playtests-off");
    } else {
      for (const op of ["play", "run", "multiplayer"]) {
        try {
          await call("playtest.control", {op,players:2});
          check(false, `${op} must be refused while playtests are OFF`);
        } catch (cause) {
          check(cause.message.includes("PLAYTEST_DISABLED") && cause.message.includes("disabled by the user"), `${op} is blocked by the saved panel setting`);
        }
      }
      const stopped = await call("playtest.control", {op:"stop"});
      check(stopped.state.playtestsAllowed === false, "stop remains available while OFF");
      const state = await call("playtest.control", {op:"state"});
      check(state.state.playtestsAllowed === false, "state remains available and preserves OFF");
    }
  } catch (cause) {
    check(false, `playtest lock: ${cause.message}`);
  }
}

// Starts a real playtest through the public tool handler, proving its returned
// ID is the attached server session. Run only from an edit session, opt in.
if (args.includes("--playtest-start")) {
  const { z } = await import("zod");
  const { registerPlaytestTools } = await import("../dist/tools/playtest.js");
  let handler, spec;
  const bridge = {
    sessions: async () => (await (await fetch(`${base}/sessions`, {headers:HEADERS})).json()),
    call: (op, params, options = {}) => callTo(options.studioId ?? studio.studioId, op, params, options.timeoutMs),
    notePlaceName: async () => {},
  };
  registerPlaytestTools({bridge,server:{registerTool(_name, definition, invoke) {spec = definition; handler = invoke;}}});
  let startedId;
  let started = false;
  const startOp = flag("playtest-op", "play");
  if (!["play", "multiplayer"].includes(startOp)) throw new Error("--playtest-op must be play or multiplayer");
  try {
    const before = await callTo(studio.studioId, "playtest.control", {op:"state"});
    if (!before.state.isEdit || before.state.playtestsAllowed === false) {
      check(false, "--playtest-start needs an edit session with playtests enabled");
    } else {
      started = true;
      const result = await handler(z.object(spec.inputSchema).parse({op:startOp,players:2,studioId:studio.studioId}));
      const id = /"studioId": "([^"]+)"/.exec(result.content[0].text)?.[1];
      startedId = id;
      const sessions = await bridge.sessions();
      check(Boolean(id && id !== studio.studioId && sessions.list.some(s => s.studioId === id && s.context?.includes("playtest"))), "playtest returns its connected server studioId directly");
      const state = id ? await callTo(id, "playtest.control", {op:"state"}) : null;
      if (state?.state.players?.length && !result.content[0].text.includes("players are still joining"))
        check(/"players": \[/.test(result.content[0].text), "playtest includes available player identities");
      if (startOp === "multiplayer") {
        const reply = result.content[0].text;
        const named = state?.state.players?.length === 2 && state.state.players.every(player => reply.includes(`"name": "${player.name}"`));
        check(named || reply.includes("players are still joining"), "multiplayer returns player names when connected, or identifies late joins");
      }
      const staleCursor = flag("stale-cursor", undefined);
      if (id && staleCursor) {
        let players = state?.state.players;
        for (let attempt = 0; !players?.length && attempt < 20; attempt += 1) {
          await new Promise(resolve => setTimeout(resolve, 250));
          players = (await callTo(id, "playtest.control", {op:"state"})).state.players;
        }
        if (players?.length) {
          try {
            await callTo(id, "perf.console", {target:"client",player:players[0].name,since:staleCursor});
            check(false, "a client cursor from the prior playtest is rejected");
          } catch (cause) {
            check(cause.message.includes("BAD_CURSOR"), "a client cursor from the prior playtest is rejected");
          }
        } else check(false, "a player must join to check the prior playtest cursor");
      }
    }
  } catch (cause) {
    check(false, `playtest returned ID: ${cause.message}`);
  } finally {
    const sessions = await bridge.sessions().catch(() => ({list:[]}));
    const target = startedId ?? (started ? sessions.list.find(s => s.studioId !== studio.studioId && s.context?.includes("playtest"))?.studioId : undefined);
    if (target) await callTo(target, "playtest.control", {op:"endTest",value:"live check complete"}).catch(() => {});
  }
}

process.stdout.write(failures === 0 ? "live: ok\n" : `live: ${failures} failure(s)\n`);
process.exit(failures === 0 ? 0 : 1);
