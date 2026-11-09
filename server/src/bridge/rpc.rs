//! Owns every connected Studio and the in-flight request table.
//!
//! The two transports converge here: `deliver` writes straight to an open SSE
//! stream or parks the command for the next long-poll. Callers use `call` and
//! never learn which one was used. One mutex guards all state; it is never held
//! across an await, so the hot path is a lock, a map insert and a channel send.

use crate::errors::{self, Result, TimeoutState, ToolError};
use crate::protocol::{ClientView, Command, CommandResult, StudioIdentity, StudioSession, now_ms};
use bytes::Bytes;
use parking_lot::Mutex;
use serde_json::{Map, Value, json};
use std::collections::{HashMap, VecDeque};
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::{mpsc, oneshot};

pub const DEFAULT_TIMEOUT_MS: u64 = 15_000;
pub const POLL_HOLD_MS: u64 = 25_000;
const STALE_AFTER_MS: u64 = 90_000;
const CLIENT_STALE_AFTER_MS: u64 = 90_000;
const RECONNECT_GRACE_MS: u64 = 10_000;

const PEER_STRING: usize = 160;
const PEER_ITEMS: usize = 8;
const PEER_DEPTH: usize = 3;

/// A trimmed copy of the request, so peers can name what ran without the payload.
fn summarize(value: &Value, depth: usize) -> Option<Value> {
    match value {
        Value::String(s) if s.chars().count() > PEER_STRING => {
            Some(Value::String(format!("{}…", s.chars().take(PEER_STRING).collect::<String>())))
        }
        Value::Array(_) | Value::Object(_) if depth >= PEER_DEPTH => None,
        Value::Array(items) => Some(Value::Array(
            items.iter().take(PEER_ITEMS).map(|v| summarize(v, depth + 1).unwrap_or(Value::Null)).collect(),
        )),
        Value::Object(map) => {
            let mut out = Map::new();
            for (k, v) in map {
                if let Some(kept) = summarize(v, depth + 1) {
                    out.insert(k.clone(), kept);
                }
            }
            Some(Value::Object(out))
        }
        other => Some(other.clone()),
    }
}

/// One SSE event. JSON never holds a raw newline, so one `data:` line suffices.
pub fn sse_frame(data: &impl serde::Serialize) -> Bytes {
    let mut out = b"data: ".to_vec();
    let _ = serde_json::to_writer(&mut out, data);
    out.extend_from_slice(b"\n\n");
    Bytes::from(out)
}

pub type Stream = mpsc::UnboundedSender<Bytes>;

struct Pending {
    tx: oneshot::Sender<Result<Value>>,
    op: String,
    params: Value,
    started_at: u64,
}

struct Session {
    identity: StudioIdentity,
    connected_at: u64,
    last_seen_at: u64,
    stream: Option<Stream>,
    /// Identifies the stream, so a superseded stream's close is ignored.
    stream_id: u64,
    queue: VecDeque<Command>,
    waiter: Option<oneshot::Sender<Option<Command>>>,
    pending: HashMap<String, Pending>,
    noted_name: Option<String>,
    generation: u64,
}

impl Session {
    fn live_stream(&self) -> Option<&Stream> {
        self.stream.as_ref().filter(|s| !s.is_closed())
    }

    fn transport(&self) -> &'static str {
        if self.stream.is_some() { "sse" } else { "poll" }
    }
}

struct ClientRecord {
    last_seen_at: u64,
    connected_at: u64,
    name: String,
    version: String,
    pid: u32,
    spawned: bool,
}

/// Fields a client may say about itself; `None` keeps what is known.
#[derive(Default, Clone)]
pub struct ClientAbout {
    pub name: Option<String>,
    pub version: Option<String>,
    pub pid: Option<u32>,
    pub spawned: Option<bool>,
}

type ClientsListener = Box<dyn Fn(&Bridge, usize, Vec<ClientView>) + Send + Sync>;

#[derive(Default)]
struct State {
    sessions: indexmap_like::OrderedMap<Session>,
    clients: HashMap<String, ClientRecord>,
    chosen: HashMap<String, String>,
    default_studio: Option<String>,
    next_stream_id: u64,
    /// Playtest sessions that went away, newest last. A Test Teleport ends the
    /// server an agent was holding and starts another, so an id from here is
    /// answered with where the test went rather than a bare "unknown".
    departed_playtests: Vec<String>,
}

/// Insertion-ordered session map: listings read in connection order.
mod indexmap_like {
    pub struct OrderedMap<V> {
        keys: Vec<String>,
        map: std::collections::HashMap<String, V>,
    }
    impl<V> Default for OrderedMap<V> {
        fn default() -> Self {
            Self { keys: Vec::new(), map: Default::default() }
        }
    }
    impl<V> OrderedMap<V> {
        pub fn get(&self, k: &str) -> Option<&V> {
            self.map.get(k)
        }
        pub fn get_mut(&mut self, k: &str) -> Option<&mut V> {
            self.map.get_mut(k)
        }
        pub fn contains(&self, k: &str) -> bool {
            self.map.contains_key(k)
        }
        pub fn insert(&mut self, k: String, v: V) {
            if self.map.insert(k.clone(), v).is_none() {
                self.keys.push(k);
            }
        }
        pub fn remove(&mut self, k: &str) -> Option<V> {
            let v = self.map.remove(k)?;
            self.keys.retain(|x| x != k);
            Some(v)
        }
        pub fn len(&self) -> usize {
            self.keys.len()
        }
        pub fn keys(&self) -> impl Iterator<Item = &String> {
            self.keys.iter()
        }
        pub fn values(&self) -> impl Iterator<Item = &V> {
            self.keys.iter().filter_map(|k| self.map.get(k))
        }
        pub fn iter(&self) -> impl Iterator<Item = (&String, &V)> {
            self.keys.iter().filter_map(|k| self.map.get(k).map(|v| (k, v)))
        }
    }
}

pub struct Bridge {
    state: Mutex<State>,
    on_clients: Mutex<Option<Arc<ClientsListener>>>,
    reconnect_grace: Duration,
}

impl Bridge {
    pub fn new() -> Arc<Self> {
        Self::with_grace(Duration::from_millis(RECONNECT_GRACE_MS))
    }

    pub fn with_grace(grace: Duration) -> Arc<Self> {
        Arc::new(Self { state: Mutex::new(State::default()), on_clients: Mutex::new(None), reconnect_grace: grace })
    }

    // --- session lifecycle -------------------------------------------------

    /// Registers a Studio, or refreshes one that reconnected. Returns the stream id.
    pub fn attach(&self, identity: StudioIdentity, stream: Option<Stream>) -> u64 {
        let mut st = self.state.lock();
        st.next_stream_id += 1;
        let stream_id = st.next_stream_id;
        let now = now_ms();
        if let Some(existing) = st.sessions.get_mut(&identity.studio_id) {
            // Reconnected (stream cap, plugin reload). Pending calls survive the gap.
            existing.stream = None; // dropping the sender ends the old stream
            existing.identity = match &existing.noted_name {
                Some(name) => StudioIdentity { place_name: name.clone(), ..identity },
                None => identity,
            };
            existing.stream = stream;
            existing.stream_id = stream_id;
            existing.generation += 1;
            existing.last_seen_at = now;
            Self::flush(existing);
            return stream_id;
        }
        let id = identity.studio_id.clone();
        st.sessions.insert(
            id,
            Session {
                identity,
                connected_at: now,
                last_seen_at: now,
                stream,
                stream_id,
                queue: VecDeque::new(),
                waiter: None,
                pending: HashMap::new(),
                noted_name: None,
                generation: 0,
            },
        );
        stream_id
    }

    /// A stream closed: hold the session briefly, since that is usually a reconnect.
    pub fn detach_stream(self: &Arc<Self>, studio_id: &str, stream_id: u64) {
        let generation = {
            let mut st = self.state.lock();
            let Some(session) = st.sessions.get_mut(studio_id) else { return };
            if session.stream_id != stream_id || session.stream.is_none() {
                return;
            }
            session.stream = None;
            session.generation
        };
        let bridge = Arc::clone(self);
        let studio_id = studio_id.to_string();
        let grace = self.reconnect_grace;
        tokio::spawn(async move {
            tokio::time::sleep(grace).await;
            let still = bridge
                .state
                .lock()
                .sessions
                .get(&studio_id)
                .is_some_and(|s| s.generation == generation && s.stream.is_none());
            if still {
                bridge.detach(&studio_id);
            }
        });
    }

    pub fn detach(&self, studio_id: &str) {
        let mut st = self.state.lock();
        let Some(mut session) = st.sessions.remove(studio_id) else { return };
        if session.identity.context.as_deref().is_some_and(|c| c != "edit") {
            st.departed_playtests.push(studio_id.to_string());
            if st.departed_playtests.len() > 16 {
                st.departed_playtests.remove(0);
            }
        }
        for (_, pending) in session.pending.drain() {
            let _ = pending.tx.send(Err(errors::disconnected()));
        }
        if let Some(waiter) = session.waiter.take() {
            let _ = waiter.send(None);
        }
        if st.default_studio.as_deref() == Some(studio_id) {
            st.default_studio = None;
        }
        st.chosen.retain(|_, chosen| chosen != studio_id);
    }

    /// Drops sessions and clients that stopped checking in without a goodbye.
    pub fn reap_stale(&self) {
        let cutoff = now_ms().saturating_sub(STALE_AFTER_MS);
        let stale: Vec<String> = {
            let st = self.state.lock();
            st.sessions.iter().filter(|(_, s)| s.last_seen_at < cutoff && s.stream.is_none()).map(|(k, _)| k.clone()).collect()
        };
        for id in stale {
            self.detach(&id);
        }
        let client_cutoff = now_ms().saturating_sub(CLIENT_STALE_AFTER_MS);
        let gone: Vec<String> = {
            let st = self.state.lock();
            st.clients.iter().filter(|(_, c)| c.last_seen_at < client_cutoff).map(|(k, _)| k.clone()).collect()
        };
        for id in gone {
            self.forget_client(&id);
        }
    }

    pub fn touch(&self, studio_id: &str) {
        if let Some(s) = self.state.lock().sessions.get_mut(studio_id) {
            s.last_seen_at = now_ms();
        }
    }

    // --- clients -----------------------------------------------------------

    pub fn note_client(&self, client_id: &str, about: ClientAbout) {
        if client_id.is_empty() {
            return;
        }
        let announce = {
            let mut st = self.state.lock();
            let now = now_ms();
            let known = st.clients.get(client_id);
            let named = about.name.as_ref().is_some_and(|n| !n.is_empty());
            let announce = known.is_none() || (named && known.map(|k| &k.name) != about.name.as_ref());
            let record = ClientRecord {
                last_seen_at: now,
                connected_at: known.map(|k| k.connected_at).unwrap_or(now),
                name: about.name.clone().or_else(|| known.map(|k| k.name.clone())).unwrap_or_else(|| "unknown".into()),
                version: about.version.clone().or_else(|| known.map(|k| k.version.clone())).unwrap_or_default(),
                pid: about.pid.or_else(|| known.map(|k| k.pid)).unwrap_or(0),
                spawned: about.spawned.or_else(|| known.map(|k| k.spawned)).unwrap_or(false),
            };
            st.clients.insert(client_id.to_string(), record);
            announce
        };
        if announce {
            self.announce_clients();
        }
    }

    /// Clients sharing this bridge, not counting agents the panel itself started.
    pub fn client_count(&self) -> usize {
        self.state.lock().clients.values().filter(|c| !c.spawned).count()
    }

    pub fn client_list(&self) -> Vec<ClientView> {
        let st = self.state.lock();
        let mut list: Vec<ClientView> = st
            .clients
            .values()
            .filter(|c| !c.spawned)
            .map(|c| ClientView { name: c.name.clone(), version: c.version.clone(), pid: c.pid, connected_at: c.connected_at })
            .collect();
        list.sort_by_key(|c| c.connected_at);
        list
    }

    pub fn watch_clients(&self, listener: impl Fn(&Bridge, usize, Vec<ClientView>) + Send + Sync + 'static) {
        *self.on_clients.lock() = Some(Arc::new(Box::new(listener)));
    }

    fn announce_clients(&self) {
        let listener = self.on_clients.lock().clone();
        if let Some(listener) = listener {
            listener(self, self.client_count(), self.client_list());
        }
    }

    /// Records the published place name a status call resolved.
    pub fn note_place_name(&self, studio_id: &str, place_name: &str, context: Option<&str>) {
        let mut st = self.state.lock();
        let Some(s) = st.sessions.get_mut(studio_id) else { return };
        if !place_name.is_empty() {
            s.identity.place_name = place_name.to_string();
            s.noted_name = Some(place_name.to_string());
        }
        if let Some(ctx) = context.filter(|c| !c.is_empty()) {
            s.identity.context = Some(ctx.to_string());
        }
    }

    pub fn has(&self, studio_id: &str) -> bool {
        self.state.lock().sessions.contains(studio_id)
    }

    pub fn list(&self) -> Vec<StudioSession> {
        Self::list_locked(&self.state.lock())
    }

    fn list_locked(st: &State) -> Vec<StudioSession> {
        st.sessions
            .values()
            .map(|s| StudioSession { identity: s.identity.clone(), connected_at: s.connected_at, last_seen_at: s.last_seen_at })
            .collect()
    }

    pub fn active_id(&self, client_id: &str) -> Option<String> {
        let st = self.state.lock();
        if let Some(picked) = st.chosen.get(client_id).filter(|p| st.sessions.contains(p)) {
            return Some(picked.clone());
        }
        if let Some(d) = st.default_studio.as_ref().filter(|d| st.sessions.contains(d)) {
            return Some(d.clone());
        }
        if st.sessions.len() == 1 {
            return st.sessions.keys().next().cloned();
        }
        None
    }

    pub fn active_is_chosen(&self, client_id: &str) -> bool {
        let st = self.state.lock();
        st.chosen.get(client_id).is_some_and(|p| st.sessions.contains(p))
            || st.default_studio.as_ref().is_some_and(|d| st.sessions.contains(d))
    }

    pub fn set_active(&self, client_id: &str, studio_id: &str) -> Result<()> {
        let mut st = self.state.lock();
        if !st.sessions.contains(studio_id) {
            return Err(errors::unknown_studio(studio_id, false));
        }
        st.chosen.insert(client_id.to_string(), studio_id.to_string());
        Ok(())
    }

    /// Points every client (and future ones) at one Studio: the panel's `use`.
    pub fn set_active_for_all(&self, studio_id: &str) -> Result<()> {
        let mut st = self.state.lock();
        if !st.sessions.contains(studio_id) {
            return Err(errors::unknown_studio(studio_id, false));
        }
        let ids: Vec<String> = st.clients.keys().cloned().collect();
        for id in ids {
            st.chosen.insert(id, studio_id.to_string());
        }
        st.default_studio = Some(studio_id.to_string());
        Ok(())
    }

    pub fn forget_client(&self, client_id: &str) -> bool {
        let removed = {
            let mut st = self.state.lock();
            st.chosen.remove(client_id);
            st.clients.remove(client_id).is_some()
        };
        if removed {
            self.announce_clients();
        }
        removed
    }

    // --- request/response --------------------------------------------------

    /// Sends `op` to a Studio and resolves with its `data` payload.
    pub async fn call(&self, op: &str, params: Value, client_id: &str, studio_id: Option<&str>, timeout_ms: Option<f64>) -> Result<Value> {
        let timeout_ms = errors::normalize_timeout_ms(timeout_ms.unwrap_or(DEFAULT_TIMEOUT_MS as f64), 0)?;
        let id = uuid::Uuid::new_v4().to_string();
        let (tx, rx) = oneshot::channel();
        let target = {
            let mut st = self.state.lock();
            let target = Self::resolve(&st, client_id, studio_id)?;
            let session = st.sessions.get_mut(&target).expect("resolved session exists");
            session.pending.insert(
                id.clone(),
                Pending { tx, op: op.to_string(), params: summarize(&params, 0).unwrap_or(Value::Null), started_at: now_ms() },
            );
            Self::deliver(session, Command { id: id.clone(), timeout_ms, op: op.to_string(), params });
            target
        };

        match tokio::time::timeout(Duration::from_millis(timeout_ms), rx).await {
            Ok(Ok(result)) => result,
            Ok(Err(_)) => Err(errors::disconnected()),
            Err(_) => {
                let mut st = self.state.lock();
                let Some(session) = st.sessions.get_mut(&target) else { return Err(errors::disconnected()) };
                session.pending.remove(&id);
                // Out of the queue too, so nobody runs work its caller gave up on.
                let queued_at = session.queue.iter().position(|c| c.id == id);
                if let Some(index) = queued_at {
                    session.queue.remove(index);
                }
                Err(errors::timeout(
                    op,
                    timeout_ms,
                    Some(TimeoutState {
                        delivered: queued_at.is_none(),
                        silent_for_ms: now_ms().saturating_sub(session.last_seen_at),
                        also_in_flight: session.pending.len(),
                        transport: session.transport(),
                    }),
                ))
            }
        }
    }

    /// Settles the call a plugin result belongs to. Unknown ids are ignored.
    pub fn settle(&self, studio_id: &str, result: CommandResult) {
        let mut st = self.state.lock();
        let Some(session) = st.sessions.get_mut(studio_id) else { return };
        session.last_seen_at = now_ms();
        let Some(pending) = session.pending.remove(&result.id) else { return };
        let origin_place = session.identity.place_id;
        let from = session.identity.context.clone().unwrap_or_else(|| "another session".into());
        let frame = sse_frame(&json!({
            "event": "peer",
            "op": pending.op,
            "params": pending.params,
            "ok": result.ok,
            "ms": now_ms().saturating_sub(pending.started_at),
            "from": from,
        }));
        // Other sessions of the same place log what ran, so each console has it all.
        for (id, other) in st.sessions.iter() {
            if id != studio_id && other.identity.place_id == origin_place
                && let Some(stream) = other.live_stream() {
                    let _ = stream.send(frame.clone());
                }
        }
        let outcome = if result.ok {
            Ok(result.data.unwrap_or(Value::Null))
        } else {
            Err(match result.error {
                Some(e) => ToolError { code: e.code, message: e.message, hint: e.hint },
                None => ToolError::new("PLUGIN_ERROR", format!("Studio failed to run \"{}\".", pending.op)),
            })
        };
        let _ = pending.tx.send(outcome);
    }

    /// Parks a long-poll until a command arrives or the hold expires.
    pub async fn wait_for_command(&self, studio_id: &str) -> Option<Command> {
        let rx = {
            let mut st = self.state.lock();
            let session = st.sessions.get_mut(studio_id)?;
            session.last_seen_at = now_ms();
            if let Some(cmd) = Self::take_queued(session) {
                return Some(cmd);
            }
            let (tx, rx) = oneshot::channel();
            session.waiter = Some(tx);
            rx
        };
        match tokio::time::timeout(Duration::from_millis(POLL_HOLD_MS), rx).await {
            Ok(Ok(cmd)) => cmd,
            _ => {
                if let Some(s) = self.state.lock().sessions.get_mut(studio_id) {
                    s.waiter.take_if(|w| w.is_closed());
                }
                None
            }
        }
    }

    /// Puts a command handed to a dead poll back at the front of the queue.
    pub fn requeue(&self, studio_id: &str, command: Command) {
        let mut st = self.state.lock();
        let Some(session) = st.sessions.get_mut(studio_id) else { return };
        if !session.pending.contains_key(&command.id) {
            return;
        }
        if let Some(stream) = session.live_stream() {
            let _ = stream.send(sse_frame(&command));
            return;
        }
        if let Some(waiter) = session.waiter.take() {
            if let Err(Some(cmd)) = waiter.send(Some(command)) {
                session.queue.push_front(cmd);
            }
            return;
        }
        session.queue.push_front(command);
    }

    fn resolve(st: &State, client_id: &str, studio_id: Option<&str>) -> Result<String> {
        if let Some(id) = studio_id.filter(|s| !s.is_empty()) {
            if st.sessions.contains(id) {
                return Ok(id.to_string());
            }
            if st.sessions.len() == 0 {
                return Err(errors::no_studio());
            }
            if st.departed_playtests.iter().any(|d| d == id) {
                let servers: Vec<String> = st
                    .sessions
                    .values()
                    .filter(|s| s.identity.context.as_deref() == Some("playtest server"))
                    .map(|s| format!("{} (place {})", s.identity.studio_id, s.identity.place_id))
                    .collect();
                return Err(errors::playtest_moved(id, &servers));
            }
            return Err(errors::unknown_studio(id, true));
        }
        if st.sessions.len() == 0 {
            return Err(errors::no_studio());
        }
        if st.sessions.len() == 1 {
            return Ok(st.sessions.keys().next().cloned().unwrap());
        }
        if let Some(picked) = st.chosen.get(client_id).filter(|p| st.sessions.contains(p)) {
            return Ok(picked.clone());
        }
        if let Some(d) = st.default_studio.as_ref().filter(|d| st.sessions.contains(d)) {
            return Ok(d.clone());
        }
        let list = Self::list_locked(st);
        let rows: Vec<String> = list
            .iter()
            .map(|s| match &s.identity.context {
                Some(ctx) => format!("{} ({}, {ctx})", s.identity.studio_id, s.identity.place_name),
                None => format!("{} ({})", s.identity.studio_id, s.identity.place_name),
            })
            .collect();
        if crate::bridge::one_editor(list.iter().map(|s| &s.identity)) {
            return Err(errors::same_place_studio(&rows));
        }
        Err(errors::ambiguous_studio(&rows))
    }

    /// Sends a frame to one Studio's stream only.
    pub fn notify(&self, studio_id: &str, frame: &Value) {
        if let Some(stream) = self.state.lock().sessions.get(studio_id).and_then(Session::live_stream) {
            let _ = stream.send(sse_frame(frame));
        }
    }

    /// One non-command frame to every plugin holding an open stream.
    pub fn broadcast(&self, frame: &Value) {
        let payload = sse_frame(frame);
        for s in self.state.lock().sessions.values() {
            if let Some(stream) = s.live_stream() {
                let _ = stream.send(payload.clone());
            }
        }
    }

    fn deliver(session: &mut Session, command: Command) {
        if let Some(stream) = session.live_stream()
            && stream.send(sse_frame(&command)).is_ok() {
                return;
            }
        if let Some(waiter) = session.waiter.take() {
            match waiter.send(Some(command)) {
                Ok(()) => return,
                Err(cmd) => {
                    session.queue.push_back(cmd.expect("sent Some"));
                    return;
                }
            }
        }
        session.queue.push_back(command);
    }

    fn take_queued(session: &mut Session) -> Option<Command> {
        while let Some(next) = session.queue.pop_front() {
            if session.pending.contains_key(&next.id) {
                return Some(next);
            }
        }
        None
    }

    fn flush(session: &mut Session) {
        let Some(stream) = session.live_stream().cloned() else { return };
        while let Some(cmd) = Self::take_queued(session) {
            let _ = stream.send(sse_frame(&cmd));
        }
    }
}
