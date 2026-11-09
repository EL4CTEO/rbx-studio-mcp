//! MCP over stdio: newline-delimited JSON-RPC 2.0.
//!
//! Hand-rolled rather than through an SDK: the server needs initialize, the
//! tool and resource lists, tools/call, ping, progress and cancellation, and
//! nothing else. Calls run concurrently, each in its own task; one writer task
//! owns stdout so frames never interleave.

use crate::bridge::{ClientDescription, StudioBridge};
use crate::format::stringify;
use crate::protocol::VERSION;
use crate::tool::{Ctx, Tool, invoke};
use parking_lot::Mutex;
use serde_json::{Value, json};
use std::collections::HashMap;
use std::sync::Arc;
use std::time::Duration;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::sync::mpsc;
use tokio::task::AbortHandle;

const SUPPORTED: [&str; 4] = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"];
const PROGRESS_FIRST: Duration = Duration::from_secs(5);
const PROGRESS_EVERY: Duration = Duration::from_secs(8);

pub const INSTRUCTIONS: &str = "Drives a live Roblox Studio session through a companion plugin.\n\n\
Start with `studio_status` to confirm Studio is connected. Instances are addressed by dot-notation path \
from the DataModel root, e.g. \"Workspace.Map.Spawn\" or \"ServerScriptService.Systems.Combat\". Paths are \
case-sensitive.\n\n\
The user may have several Studio windows open on different places. When more than one is connected, no \
place is targeted by default and tools refuse with AMBIGUOUS_STUDIO: call `list_studios`, ask the user \
which place they mean, then `set_active_studio`. Do the same whenever they mention their other place — \
never assume a switch.\n\n\
Prefer the batch tools: `create`, `modify`, `delete`, `move` and `script_edit` all take arrays. Instance \
batches are a single undo step (script source uses the script editor's own undo, per script), so one call \
beats a loop of calls both in latency and in how cleanly the user can revert your work. Reach for \
`execute_luau` only when no dedicated tool fits — it is the escape hatch, not the default.\n\n\
Open Cloud calls (uploads, data stores, publishing, products, bans, live Luau) follow per-game permissions \
the user sets in the Studio panel; only reading is on until they allow more. On PERMISSION_OFF, ask the \
user to run the `allow` command it names. Never work around a permission that is off.";

struct Resource {
    uri: &'static str,
    name: &'static str,
    title: &'static str,
    description: &'static str,
    op: &'static str,
    params: fn() -> Value,
}

const RESOURCES: [Resource; 3] = [
    Resource {
        uri: "studio://status",
        name: "studio-status",
        title: "Studio session",
        description: "Which place is open, whether it is playing, what is selected, and which scripts the user has on screen. The cheapest orientation there is.",
        op: "studio.status",
        params: || json!({}),
    },
    Resource {
        uri: "studio://tree",
        name: "studio-tree",
        title: "Place hierarchy",
        description: "The authored containers and what is directly inside them, two levels deep. A map of the place, without the ~120 engine services that would bury it.",
        op: "discover.tree",
        params: || json!({ "depth": 2, "limit": 150, "detail": "concise" }),
    },
    Resource {
        uri: "studio://console",
        name: "studio-console",
        title: "Recent output",
        description: "The last 100 lines Studio printed, warnings and errors included. Reading this after a playtest is usually the first useful thing to do.",
        op: "perf.console",
        params: || json!({ "limit": 100 }),
    },
];

pub struct Server {
    tools: HashMap<&'static str, Tool>,
    tool_list: Value,
    ctx: Arc<Ctx>,
    out: mpsc::UnboundedSender<Vec<u8>>,
    running: Mutex<HashMap<String, AbortHandle>>,
    client: Mutex<Option<ClientDescription>>,
}

fn id_key(id: &Value) -> String {
    id.to_string()
}

impl Server {
    fn send(&self, message: Value) {
        let mut bytes = serde_json::to_vec(&message).unwrap_or_default();
        bytes.push(b'\n');
        let _ = self.out.send(bytes);
    }

    fn reply(&self, id: Value, result: Value) {
        self.send(json!({ "jsonrpc": "2.0", "id": id, "result": result }));
    }

    fn fail(&self, id: Value, code: i64, message: &str) {
        self.send(json!({ "jsonrpc": "2.0", "id": id, "error": { "code": code, "message": message } }));
    }

    fn handle(self: &Arc<Self>, message: Value) {
        let method = message.get("method").and_then(Value::as_str).unwrap_or("").to_string();
        let id = message.get("id").cloned();
        let params = message.get("params").cloned().unwrap_or(Value::Null);

        let Some(id) = id else {
            // Notifications.
            match method.as_str() {
                "notifications/initialized" => self.initialized(),
                "notifications/cancelled" => {
                    if let Some(req) = params.get("requestId")
                        && let Some(handle) = self.running.lock().remove(&id_key(req)) {
                            handle.abort();
                        }
                }
                _ => {}
            }
            return;
        };
        if message.get("method").is_none() {
            return; // a response to something we never send
        }

        match method.as_str() {
            "initialize" => {
                let asked = params.get("protocolVersion").and_then(Value::as_str).unwrap_or(SUPPORTED[0]);
                let version = SUPPORTED.iter().find(|v| **v == asked).copied().unwrap_or(SUPPORTED[0]);
                if let Some(info) = params.get("clientInfo") {
                    *self.client.lock() = Some(ClientDescription {
                        name: info.get("name").and_then(Value::as_str).unwrap_or("unknown").to_string(),
                        version: info.get("version").and_then(Value::as_str).unwrap_or("").to_string(),
                    });
                }
                self.reply(
                    id,
                    json!({
                        "protocolVersion": version,
                        "capabilities": { "tools": { "listChanged": false }, "resources": { "listChanged": false } },
                        "serverInfo": { "name": "roblox-studio-mcp", "version": VERSION },
                        "instructions": INSTRUCTIONS,
                    }),
                );
            }
            "ping" => self.reply(id, json!({})),
            "tools/list" => self.reply(id, self.tool_list.clone()),
            "tools/call" => self.call_tool(id, params),
            "resources/list" => {
                let list: Vec<Value> = RESOURCES
                    .iter()
                    .map(|r| json!({ "uri": r.uri, "name": r.name, "title": r.title, "description": r.description, "mimeType": "application/json" }))
                    .collect();
                self.reply(id, json!({ "resources": list }));
            }
            "resources/templates/list" => self.reply(id, json!({ "resourceTemplates": [] })),
            "resources/read" => {
                let uri = params.get("uri").and_then(Value::as_str).unwrap_or("").to_string();
                let Some(resource) = RESOURCES.iter().find(|r| r.uri == uri) else {
                    return self.fail(id, -32002, &format!("Resource {uri} not found"));
                };
                let this = self.clone();
                tokio::spawn(async move {
                    // Resources have nowhere to put an error, so it becomes the content.
                    let text = match this.ctx.bridge.call(resource.op, (resource.params)(), None, None).await {
                        Ok(v) => stringify(&v),
                        Err(e) => stringify(&json!({ "unavailable": e.full_message() })),
                    };
                    this.reply(id, json!({ "contents": [{ "uri": uri, "mimeType": "application/json", "text": text }] }));
                });
            }
            "prompts/list" => self.reply(id, json!({ "prompts": [] })),
            "logging/setLevel" => self.reply(id, json!({})),
            _ => self.fail(id, -32601, &format!("Method not found: {method}")),
        }
    }

    fn initialized(self: &Arc<Self>) {
        let about = self.client.lock().clone().unwrap_or(ClientDescription { name: "unknown".into(), version: String::new() });
        self.ctx.bridge.describe(about);
        // Loaded while the agent reads the tool list, so the first inspect does not pay for it.
        tokio::spawn(async {
            tokio::time::sleep(Duration::from_millis(250)).await;
            crate::apidump::preload().await;
        });
    }

    fn call_tool(self: &Arc<Self>, id: Value, params: Value) {
        let name = params.get("name").and_then(Value::as_str).unwrap_or("").to_string();
        if !self.tools.contains_key(name.as_str()) {
            return self.fail(id, -32602, &format!("Tool {name} not found"));
        }
        let args = params.get("arguments").cloned().unwrap_or_else(|| json!({}));
        let token = params.pointer("/_meta/progressToken").cloned();
        let this = self.clone();
        let key = id_key(&id);
        let task = tokio::spawn({
            let key = key.clone();
            async move {
                let tool = &this.tools[name.as_str()];
                let slot = Arc::new(Mutex::new(None::<String>));
                let heartbeat = token.map(|token| {
                    let this = this.clone();
                    let slot = slot.clone();
                    let label = name.clone();
                    tokio::spawn(async move {
                        let started = std::time::Instant::now();
                        tokio::time::sleep(PROGRESS_FIRST).await;
                        let mut beats = 0u64;
                        loop {
                            beats += 1;
                            let note = slot.lock().clone().unwrap_or_else(|| "working".into());
                            this.send(json!({
                                "jsonrpc": "2.0",
                                "method": "notifications/progress",
                                "params": {
                                    "progressToken": token,
                                    "progress": beats,
                                    "message": format!("{label}: {note} ({}s)", started.elapsed().as_secs_f64().round()),
                                }
                            }));
                            tokio::time::sleep(PROGRESS_EVERY).await;
                        }
                    })
                });
                let result = invoke(tool, this.ctx.clone(), args, slot).await;
                if let Some(h) = heartbeat {
                    h.abort();
                }
                this.running.lock().remove(&key);
                this.reply(id, result.to_json());
            }
        });
        self.running.lock().insert(key, task.abort_handle());
    }
}

/// Serves MCP on stdin/stdout until the client hangs up.
pub async fn serve(bridge: Arc<StudioBridge>, tools: Vec<Tool>) {
    let (out_tx, mut out_rx) = mpsc::unbounded_channel::<Vec<u8>>();
    let writer = tokio::spawn(async move {
        let mut stdout = tokio::io::stdout();
        while let Some(frame) = out_rx.recv().await {
            if stdout.write_all(&frame).await.is_err() {
                break;
            }
            let _ = stdout.flush().await;
        }
    });

    let tool_list = json!({ "tools": tools.iter().map(Tool::listing).collect::<Vec<_>>() });
    let server = Arc::new(Server {
        tools: tools.into_iter().map(|t| (t.name, t)).collect(),
        tool_list,
        ctx: Arc::new(Ctx { bridge }),
        out: out_tx,
        running: Mutex::new(HashMap::new()),
        client: Mutex::new(None),
    });

    let mut lines = BufReader::with_capacity(1 << 16, tokio::io::stdin()).lines();
    while let Ok(Some(line)) = lines.next_line().await {
        let line = line.trim();
        if line.is_empty() {
            continue;
        }
        match serde_json::from_str::<Value>(line) {
            Ok(Value::Array(batch)) => batch.into_iter().for_each(|m| server.handle(m)),
            Ok(message) => server.handle(message),
            Err(_) => server.send(json!({ "jsonrpc": "2.0", "id": null, "error": { "code": -32700, "message": "Parse error" } })),
        }
    }
    // stdin closed: the client is gone. Let in-flight replies drain briefly.
    drop(server);
    let _ = tokio::time::timeout(Duration::from_millis(500), writer).await;
}
