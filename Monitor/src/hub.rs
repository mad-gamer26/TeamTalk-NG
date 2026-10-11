//! The monitor itself: one TeamTalk session per monitored server, the state
//! each one builds, the numbered event log the app follows, private-message
//! history, push notifications, and the app installs (devices) using it.
//! Each server belongs to one device, and a device can only see and act on
//! its own.

use std::collections::HashMap;
use std::sync::{Arc, Mutex, Weak};
use std::time::Duration;

use base64::Engine;
use base64::engine::general_purpose::{STANDARD as B64, URL_SAFE_NO_PAD as B64URL};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use tokio::sync::{broadcast, mpsc};

use crate::config::Limits;
use crate::push::{self, PushJob, RateLimit};
use crate::store::{Device, ServerConfig, Store, StoredEvent, now_ms};
use crate::tt::conn::{self, CommandError, GENDER_BITS, Login, Presence, SessionHandle, Sink, Target};
use crate::tt::line::Line;
use crate::tt::state::{self, ConnectionStatus, Event, MessageKind, ServerState, Snapshot, TextMessage};

/// How long a server may stay lost before its device is told.
const DOWN_NOTICE_AFTER: Duration = Duration::from_secs(60);

#[derive(Debug, thiserror::Error)]
pub enum HubError {
    #[error("{0}")]
    NotFound(String),
    #[error("{0}")]
    Invalid(String),
    #[error("{0}")]
    Refused(String),
    #[error(transparent)]
    Command(#[from] CommandError),
    #[error(transparent)]
    Internal(#[from] anyhow::Error),
}

pub type Result<T> = std::result::Result<T, HubError>;

/// A monitored server as the app lists it.
#[derive(Debug, Clone, Serialize)]
pub struct ServerSummary {
    pub id: i64,
    pub name: String,
    pub host: String,
    pub tcp_port: u16,
    pub encrypted: bool,
    pub enabled: bool,
    pub nickname: String,
    /// The account the monitor logs in with.
    pub username: String,
    pub status: ConnectionStatus,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub reason: Option<String>,
    /// When `status` last changed (Unix milliseconds).
    pub status_since: i64,
    /// The name the server gives itself.
    pub server_name: String,
    pub user_count: usize,
    pub unread_private_messages: i64,
}

#[derive(Debug, Clone, Serialize)]
pub struct ServerView {
    pub server: ServerSummary,
    pub state: Snapshot,
    /// The last event already reflected in `state`; follow events after it.
    pub seq: i64,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(tag = "to", rename_all = "snake_case")]
pub enum MessageTarget {
    /// Someone logged in now, by their user ID. With `conversation_id`,
    /// only while that conversation lasts (the person has not logged out
    /// and the ID has not gone to someone else).
    User { user_id: i64, #[serde(default)] conversation_id: Option<i64> },
    /// A channel; the monitor's own channel when missing.
    Channel { channel_id: Option<i64> },
    Broadcast,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(tag = "action", rename_all = "snake_case")]
pub enum Action {
    Join { channel_id: Option<i64>, channel: Option<String>, #[serde(default)] password: String },
    Leave,
    Move { user_id: i64, channel_id: i64 },
    /// From a channel, or from the server when `channel_id` is missing.
    Kick { user_id: i64, channel_id: Option<i64> },
    Ban { user_id: i64 },
    Nickname { nickname: String },
    Status { #[serde(default)] status_mode: i64, #[serde(default)] status_msg: String },
}

#[derive(Debug, Clone, Serialize)]
pub struct Registered {
    pub device_id: i64,
    /// The device's secret for the API; shown only now.
    pub token: String,
    /// Key that opens sealed notification text (base64).
    pub push_key: String,
}

/// Settings for the whole service.
#[derive(Debug, Clone)]
pub struct Options {
    pub client_name: String,
    pub seal: bool,
    pub allow_private_hosts: bool,
    pub limits: Limits,
}

struct Runtime {
    config: ServerConfig,
    state: ServerState,
    status: ConnectionStatus,
    reason: Option<String>,
    status_since: i64,
}

/// Whether two settings log in the same way (they may differ in nickname
/// and status, which change while logged in).
fn same_login(a: &ServerConfig, b: &ServerConfig) -> bool {
    ServerConfig { nickname: b.nickname.clone(), status_mode: b.status_mode, status_msg: b.status_msg.clone(), ..a.clone() } == *b
}

struct Running {
    config: ServerConfig,
    handle: SessionHandle,
    generation: u64,
}

struct Inner {
    store: Store,
    seq: i64,
    servers: HashMap<i64, Runtime>,
    servers_version: i64,
    /// Servers paused by their owner's app, until when (Unix ms).
    paused: HashMap<i64, i64>,
}

pub struct Hub {
    inner: Mutex<Inner>,
    running: Mutex<HashMap<i64, Running>>,
    generation: Mutex<u64>,
    events: broadcast::Sender<StoredEvent>,
    push: Mutex<Option<mpsc::UnboundedSender<PushJob>>>,
    options: Options,
    register_limit: RateLimit,
    me: Weak<Hub>,
}

impl Hub {
    pub fn new(store: Store, options: Options) -> anyhow::Result<Arc<Hub>> {
        let seq = store.last_seq()?;
        let (events, _) = broadcast::channel(1024);
        Ok(Arc::new_cyclic(|me| Hub {
            inner: Mutex::new(Inner { store, seq, servers: HashMap::new(), servers_version: -1, paused: HashMap::new() }),
            running: Mutex::new(HashMap::new()),
            generation: Mutex::new(0),
            events,
            push: Mutex::new(None),
            register_limit: RateLimit::new(options.limits.registrations_per_address_per_hour),
            options,
            me: me.clone(),
        }))
    }

    pub fn set_push(&self, tx: mpsc::UnboundedSender<PushJob>) {
        *self.push.lock().unwrap() = Some(tx);
    }

    pub fn subscribe(&self) -> broadcast::Receiver<StoredEvent> {
        self.events.subscribe()
    }

    pub fn with_store<T>(&self, f: impl FnOnce(&Store) -> anyhow::Result<T>) -> Result<T> {
        let inner = self.inner.lock().unwrap();
        Ok(f(&inner.store)?)
    }

    // Sessions

    /// Start, restart and stop sessions to match the servers in the
    /// database. Cheap when nothing changed.
    pub fn reconcile(&self, force: bool) {
        let (configs, paused, dormant) = {
            let mut inner = self.inner.lock().unwrap();
            let version = inner.store.servers_version().unwrap_or(0);
            if !force && version == inner.servers_version {
                return;
            }
            inner.servers_version = version;
            let dormant = inner.store.dormant_devices().unwrap_or_default();
            match inner.store.servers() {
                Ok(c) => (
                    c,
                    inner.paused.keys().copied().collect::<Vec<i64>>(),
                    dormant,
                ),
                Err(e) => {
                    tracing::error!("could not read servers: {e:#}");
                    return;
                }
            }
        };
        let active = |c: &ServerConfig| c.enabled && !paused.contains(&c.id) && !dormant.contains(&c.owner);
        let mut running = self.running.lock().unwrap();
        // A new nickname or status is set without logging in again.
        for c in configs.iter().filter(|c| active(c)) {
            if let Some(r) = running.get_mut(&c.id)
                && *c != r.config
                && same_login(c, &r.config)
            {
                r.handle.set_presence(Presence { nickname: c.nickname.clone(), status_mode: c.status_mode, status_msg: c.status_msg.clone() });
                r.config = c.clone();
            }
        }
        // Stop what was removed, disabled or changed.
        let keep: Vec<i64> = running
            .iter()
            .filter(|(id, r)| configs.iter().any(|c| c.id == **id && active(c) && *c == r.config))
            .map(|(id, _)| *id)
            .collect();
        for (id, r) in running.extract_if(|id, _| !keep.contains(id)) {
            tracing::info!(server = id, "stopping session");
            r.handle.stop();
        }
        {
            let mut inner = self.inner.lock().unwrap();
            inner.servers.retain(|id, _| configs.iter().any(|c| c.id == *id));
            for c in &configs {
                let rt = inner.servers.entry(c.id).or_insert_with(|| Runtime {
                    config: c.clone(),
                    state: ServerState::default(),
                    status: ConnectionStatus::Disconnected,
                    reason: None,
                    status_since: now_ms(),
                });
                rt.config = c.clone();
                if !c.enabled {
                    rt.state.reset();
                    rt.status = ConnectionStatus::Disconnected;
                    rt.reason = Some("Monitoring is off for this server".into());
                } else if dormant.contains(&c.owner) {
                    rt.state.reset();
                    rt.status = ConnectionStatus::Paused;
                    rt.reason = Some("Asleep: TeamTalk NG has not been in touch for a long time. Opening the app wakes it.".into());
                } else if paused.contains(&c.id) && rt.status != ConnectionStatus::Paused {
                    rt.state.reset();
                    rt.status = ConnectionStatus::Paused;
                    rt.reason = Some("Paused while you are connected to this server".into());
                    rt.status_since = now_ms();
                    let id = c.id;
                    self.record(&mut inner, id, Event::Connection { status: ConnectionStatus::Paused, reason: Some("Paused while you are connected to this server".into()) });
                }
            }
        }
        for c in configs.into_iter().filter(|c| active(c)) {
            if running.contains_key(&c.id) {
                continue;
            }
            let generation = {
                let mut g = self.generation.lock().unwrap();
                *g += 1;
                *g
            };
            tracing::info!(server = c.id, host = %c.host, "starting session");
            let sink = Arc::new(ServerSink { hub: self.me.clone(), server_id: c.id, generation });
            let handle = conn::spawn(
                self.target(&c),
                Login {
                    nickname: c.nickname.clone(),
                    username: c.username.clone(),
                    password: c.password.clone(),
                    client_name: self.options.client_name.clone(),
                    status_msg: c.status_msg.clone(),
                    status_mode: c.status_mode,
                    channel: c.channel.clone(),
                    channel_password: c.channel_password.clone(),
                },
                sink,
            );
            running.insert(c.id, Running { config: c, handle, generation });
        }
    }

    fn target(&self, c: &ServerConfig) -> Target {
        Target { host: c.host.clone(), tcp_port: c.tcp_port, encrypted: c.encrypted, allow_private: self.options.allow_private_hosts }
    }

    /// Fail unless the server exists and belongs to this device. Others'
    /// servers look the same as missing ones.
    fn check_owner(&self, owner: i64, server_id: i64) -> Result<()> {
        let inner = self.inner.lock().unwrap();
        match inner.servers.get(&server_id) {
            Some(rt) if rt.config.owner == owner => Ok(()),
            _ => Err(HubError::NotFound("No such server".into())),
        }
    }

    pub fn owner_of(&self, server_id: i64) -> Option<i64> {
        self.inner.lock().unwrap().servers.get(&server_id).map(|rt| rt.config.owner)
    }

    pub fn stop_all(&self) {
        for (_, r) in self.running.lock().unwrap().drain() {
            r.handle.stop();
        }
    }

    fn current(&self, server_id: i64, generation: u64) -> bool {
        self.running.lock().unwrap().get(&server_id).is_some_and(|r| r.generation == generation)
    }

    fn session(&self, server_id: i64) -> Result<SessionHandle> {
        self.running
            .lock()
            .unwrap()
            .get(&server_id)
            .map(|r| r.handle.clone())
            .ok_or_else(|| HubError::Refused("The monitor is not connected to that server".into()))
    }

    fn on_line(&self, server_id: i64, line: &Line) {
        let mut inner = self.inner.lock().unwrap();
        let Some(rt) = inner.servers.get_mut(&server_id) else { return };
        let events = rt.state.apply(line);
        for e in events {
            self.record(&mut inner, server_id, e);
        }
    }

    fn on_status(&self, server_id: i64, status: ConnectionStatus, reason: Option<String>) {
        let mut inner = self.inner.lock().unwrap();
        let Some(rt) = inner.servers.get_mut(&server_id) else { return };
        if rt.status == status && rt.reason == reason {
            return;
        }
        let was_up = rt.status == ConnectionStatus::LoggedIn;
        // Retries while already down are not news.
        let quiet = status == ConnectionStatus::Connecting && rt.status != ConnectionStatus::LoggedIn;
        rt.status = status;
        rt.reason = reason.clone();
        rt.status_since = now_ms();
        if matches!(status, ConnectionStatus::Disconnected | ConnectionStatus::LoginFailed | ConnectionStatus::SteppedAside) {
            rt.state.reset();
        }
        // Logged in again: conversations whose user ID is no longer the
        // same person (they left meanwhile, or the server restarted) end.
        let present: Option<Vec<(i64, String)>> = (status == ConnectionStatus::LoggedIn)
            .then(|| rt.state.users.values().map(|u| (u.id, u.username.clone())).collect());
        let since = rt.status_since;
        if let Some(present) = present
            && let Err(e) = inner.store.keep_conversations(server_id, &present)
        {
            tracing::error!("could not check conversations: {e:#}");
        }
        if !quiet {
            self.record(&mut inner, server_id, Event::Connection { status, reason: reason.clone() });
        }
        drop(inner);
        if was_up && matches!(status, ConnectionStatus::Disconnected | ConnectionStatus::LoginFailed | ConnectionStatus::Connecting) {
            let hub = self.me.clone();
            tokio::spawn(async move {
                tokio::time::sleep(DOWN_NOTICE_AFTER).await;
                if let Some(hub) = hub.upgrade() {
                    hub.check_still_down(server_id, since);
                }
            });
        }
    }

    /// Tell devices a server has been lost for a while, unless it came back.
    fn check_still_down(&self, server_id: i64, since: i64) {
        let inner = self.inner.lock().unwrap();
        let Some(rt) = inner.servers.get(&server_id) else { return };
        if rt.status == ConnectionStatus::LoggedIn || !rt.config.enabled {
            return;
        }
        // Any status change since then, other than retrying, counts as
        // the same outage.
        if rt.status_since < since || matches!(rt.status, ConnectionStatus::SteppedAside | ConnectionStatus::Paused) {
            return;
        }
        let e = Event::Connection { status: ConnectionStatus::Disconnected, reason: rt.reason.clone() };
        self.notify(&inner, server_id, &e);
    }

    /// Number an event, store it, send it to listening apps, keep private
    /// messages, and notify devices.
    fn record(&self, inner: &mut Inner, server_id: i64, event: Event) {
        inner.seq += 1;
        let stored = StoredEvent { seq: inner.seq, server_id, time: now_ms(), event };
        if let Err(e) = inner.store.add_event(&stored) {
            tracing::error!("could not store event: {e:#}");
        }
        // Private conversations follow user IDs, as in TeamTalk.
        match &stored.event {
            Event::Message { message: m } if m.kind == MessageKind::User && !m.intercepted => {
                let peer = if m.outgoing { m.to.clone() } else { Some(m.from.clone()) };
                if let Some(p) = peer {
                    let saved = inner
                        .store
                        .conversation_for(server_id, p.id, &p.nickname, &p.username, stored.time)
                        .and_then(|c| inner.store.add_message(c, server_id, m.outgoing, &m.text, stored.time));
                    if let Err(e) = saved {
                        tracing::error!("could not store message: {e:#}");
                    }
                }
            }
            Event::LoggedOut { user } => {
                if let Err(e) = inner.store.end_conversation(server_id, user.id) {
                    tracing::error!("could not end conversation: {e:#}");
                }
            }
            _ => {}
        }
        self.notify(inner, server_id, &stored.event);
        let _ = self.events.send(stored);
    }

    fn notify(&self, inner: &Inner, server_id: i64, event: &Event) {
        let worth = matches!(
            event,
            Event::LoggedIn { .. } | Event::LoggedOut { .. } | Event::Message { .. } | Event::Kicked { .. } | Event::Connection { .. }
        );
        let push = self.push.lock().unwrap();
        let Some(push) = push.as_ref().filter(|_| worth) else { return };
        let Some(rt) = inner.servers.get(&server_id) else { return };
        // Connection changes are only pushed by `check_still_down`, never
        // as they happen.
        if matches!(event, Event::Connection { .. }) && rt.status == ConnectionStatus::LoggedIn {
            return;
        }
        let server_name = if rt.config.name.is_empty() { rt.state.info.name.clone() } else { rt.config.name.clone() };
        let monitor_nickname = rt.state.users.get(&rt.state.me.user_id).map(|u| u.nickname.clone()).unwrap_or_else(|| rt.config.nickname.clone());
        let ctx = push::EventContext { server_id, server_name: &server_name, monitor_nickname: &monitor_nickname, now_ms: now_ms() };
        let devices = match inner.store.device(rt.config.owner) {
            Ok(d) => d,
            Err(e) => {
                tracing::error!("could not read the device: {e:#}");
                return;
            }
        };
        for d in devices {
            let targets = inner.store.push_targets(d.id).unwrap_or_default();
            if targets.is_empty() {
                continue;
            }
            let Some(mut n) = push::notification_for(&d.prefs, &ctx, event) else { continue };
            // A private message opens, and is answered in, its conversation.
            if let Event::Message { message: m } = event
                && m.kind == MessageKind::User
                && let Ok(Some(c)) = inner.store.active_conversation(server_id, m.from.id)
            {
                n.data["conversation_id"] = c.into();
            }
            let key = self.options.seal.then_some(d.push_key.as_slice());
            // Every iPhone with the app signed in to this account.
            for t in targets {
                match push::payload(&n, key, &t.app_ref) {
                    Ok(payload) => {
                        let _ = push.send(PushJob { apns_token: t.apns_token, sandbox: t.sandbox, payload, background: false });
                    }
                    Err(e) => tracing::error!("could not build push: {e:#}"),
                }
            }
        }
    }

    // Reading

    fn summary(inner: &Inner, rt: &Runtime) -> ServerSummary {
        let unread = inner.store.conversations(rt.config.owner, Some(rt.config.id)).map(|c| c.iter().map(|c| c.unread).sum()).unwrap_or(0);
        ServerSummary {
            id: rt.config.id,
            name: rt.config.name.clone(),
            host: rt.config.host.clone(),
            tcp_port: rt.config.tcp_port,
            encrypted: rt.config.encrypted,
            enabled: rt.config.enabled,
            nickname: rt.config.nickname.clone(),
            username: rt.config.username.clone(),
            status: rt.status,
            reason: rt.reason.clone(),
            status_since: rt.status_since,
            server_name: rt.state.info.name.clone(),
            user_count: rt.state.users.len(),
            unread_private_messages: unread,
        }
    }

    pub fn servers(&self, owner: i64) -> Vec<ServerSummary> {
        let inner = self.inner.lock().unwrap();
        let mut list: Vec<_> = inner.servers.values().filter(|rt| rt.config.owner == owner).map(|rt| Self::summary(&inner, rt)).collect();
        list.sort_by_key(|s| s.id);
        list
    }

    pub fn server(&self, owner: i64, id: i64) -> Result<ServerView> {
        let inner = self.inner.lock().unwrap();
        let rt = inner.servers.get(&id).filter(|rt| rt.config.owner == owner).ok_or_else(|| HubError::NotFound("No such server".into()))?;
        Ok(ServerView { server: Self::summary(&inner, rt), state: rt.state.snapshot(), seq: inner.seq })
    }

    /// Read from the store together with the newest event number at that
    /// instant: everything in the result is from that event or before, so
    /// the app can skip live events it already has.
    pub fn with_store_at<T>(&self, f: impl FnOnce(&Store) -> anyhow::Result<T>) -> Result<(T, i64)> {
        let inner = self.inner.lock().unwrap();
        Ok((f(&inner.store)?, inner.seq))
    }

    pub fn last_seq(&self) -> i64 {
        self.inner.lock().unwrap().seq
    }

    // Changing servers

    /// The server's settings, for its owner only.
    pub fn server_config(&self, owner: i64, id: i64) -> Result<ServerConfig> {
        self.check_owner(owner, id)?;
        self.with_store(|s| s.server(id))?.ok_or_else(|| HubError::NotFound("No such server".into()))
    }

    /// Check a server's settings, including that its address is one the
    /// monitor may reach.
    async fn validate(&self, c: &ServerConfig) -> Result<()> {
        if c.host.trim().is_empty() {
            return Err(HubError::Invalid("The server address is missing".into()));
        }
        if c.tcp_port == 0 {
            return Err(HubError::Invalid("The TCP port is missing".into()));
        }
        if c.name.chars().count() > 100 || c.host.len() > 255 || c.nickname.chars().count() > 100 {
            return Err(HubError::Invalid("A setting is too long".into()));
        }
        conn::resolve(&self.target(c)).await.map_err(|e| HubError::Invalid(e.to_string()))?;
        Ok(())
    }

    pub async fn add_server(&self, owner: i64, mut c: ServerConfig) -> Result<i64> {
        c.owner = owner;
        self.validate(&c).await?;
        let limits = &self.options.limits;
        let (mine, all) = self.with_store(|s| Ok((s.count_servers(Some(owner))?, s.count_servers(None)?)))?;
        if mine >= limits.servers_per_device {
            return Err(HubError::Refused(format!("You can monitor up to {} servers", limits.servers_per_device)));
        }
        if all >= limits.servers_total {
            return Err(HubError::Refused("The monitor is full right now; try again later".into()));
        }
        c.id = self.with_store(|s| s.add_server(&c))?;
        tracing::info!(device = owner, server = c.id, host = %c.host, "server added");
        self.reconcile(false);
        Ok(c.id)
    }

    /// Update a server; an empty password keeps the current one.
    pub async fn update_server(&self, owner: i64, mut c: ServerConfig) -> Result<()> {
        let old = self.server_config(owner, c.id)?;
        c.owner = owner;
        self.validate(&c).await?;
        if c.password.is_empty() {
            c.password = old.password;
        }
        if c.channel_password.is_empty() && c.channel == old.channel {
            c.channel_password = old.channel_password;
        }
        self.with_store(|s| s.update_server(&c))?;
        self.reconcile(false);
        Ok(())
    }

    /// Stop monitoring a server for a while: the app does this while its
    /// owner is connected to the server with the same account, so the two
    /// logins do not throw each other off.
    pub fn pause(&self, owner: i64, id: i64, minutes: i64) -> Result<()> {
        self.check_owner(owner, id)?;
        let until = now_ms() + minutes.clamp(1, 12 * 60) * 60_000;
        self.inner.lock().unwrap().paused.insert(id, until);
        tracing::info!(server = id, minutes, "paused");
        self.reconcile(true);
        Ok(())
    }

    pub fn resume(&self, owner: i64, id: i64) -> Result<()> {
        self.check_owner(owner, id)?;
        if self.inner.lock().unwrap().paused.remove(&id).is_some() {
            tracing::info!(server = id, "resumed");
            self.reconcile(true);
        }
        Ok(())
    }

    /// End pauses that ran out (the app never said it disconnected).
    pub fn expire_pauses(&self) {
        let expired = {
            let mut inner = self.inner.lock().unwrap();
            let now = now_ms();
            let before = inner.paused.len();
            inner.paused.retain(|_, until| *until > now);
            inner.paused.len() != before
        };
        if expired {
            self.reconcile(true);
        }
    }

    pub fn remove_server(&self, owner: i64, id: i64) -> Result<()> {
        self.check_owner(owner, id)?;
        self.with_store(|s| s.remove_server(id))?;
        self.reconcile(false);
        Ok(())
    }

    // Acting on a server

    pub async fn command(&self, owner: i64, server_id: i64, line: Line) -> Result<Vec<Line>> {
        self.check_owner(owner, server_id)?;
        let session = self.session(server_id)?;
        Ok(session.command(line).await?)
    }

    pub async fn send_message(&self, owner: i64, server_id: i64, target: MessageTarget, text: &str) -> Result<()> {
        self.check_owner(owner, server_id)?;
        let text = text.trim_end();
        if text.trim().is_empty() {
            return Err(HubError::Invalid("The message is empty".into()));
        }
        let (base, to) = {
            let inner = self.inner.lock().unwrap();
            let rt = inner.servers.get(&server_id).ok_or_else(|| HubError::NotFound("No such server".into()))?;
            if rt.status != ConnectionStatus::LoggedIn {
                return Err(HubError::Refused("The monitor is not logged in to that server right now".into()));
            }
            let st = &rt.state;
            match target {
                MessageTarget::User { user_id, conversation_id } => {
                    let ended = || HubError::Refused("That person has logged out, so this conversation has ended".into());
                    let u = st.users.get(&user_id).filter(|_| user_id != st.me.user_id).ok_or_else(ended)?;
                    if let Some(c) = conversation_id {
                        let current = inner.store.active_conversation(server_id, user_id)?;
                        let same = inner.store.conversation(c)?.is_some_and(|conv| conv.username == u.username);
                        if current.is_some_and(|cur| cur != c) || !same {
                            return Err(ended());
                        }
                    }
                    (Line::new("message").with("type", state::MSG_USER).with("destuserid", user_id), Some(u.reference()))
                }
                MessageTarget::Channel { channel_id } => {
                    let chan = channel_id
                        .or(st.me.channel_id)
                        .ok_or_else(|| HubError::Refused("The monitor is not in a channel; join one first".into()))?;
                    if !st.channels.contains_key(&chan) {
                        return Err(HubError::NotFound("No such channel".into()));
                    }
                    (Line::new("message").with("type", state::MSG_CHANNEL).with("chanid", chan), None)
                }
                MessageTarget::Broadcast => (Line::new("message").with("type", state::MSG_BROADCAST), None),
            }
        };
        let session = self.session(server_id)?;
        let chars: Vec<char> = text.chars().collect();
        let parts: Vec<String> = chars.chunks(state::MAX_MESSAGE_PART).map(|c| c.iter().collect()).collect();
        let count = parts.len();
        for (i, part) in parts.into_iter().enumerate() {
            let line = base.clone().with("content", part).with("more", i64::from(i + 1 < count));
            session.command(line).await?;
        }
        // The server does not echo private messages back, so record the
        // monitor's own here.
        if let Some(to) = to {
            let mut inner = self.inner.lock().unwrap();
            let from = inner
                .servers
                .get(&server_id)
                .and_then(|rt| rt.state.users.get(&rt.state.me.user_id).map(|u| u.reference()))
                .unwrap_or(state::UserRef { id: 0, nickname: String::new(), username: String::new() });
            let msg = TextMessage { kind: MessageKind::User, from, to: Some(to), channel_id: None, channel_path: None, text: text.to_owned(), outgoing: true, intercepted: false };
            self.record(&mut inner, server_id, Event::Message { message: msg });
        }
        Ok(())
    }

    pub async fn act(&self, owner: i64, server_id: i64, action: Action) -> Result<()> {
        self.check_owner(owner, server_id)?;
        let line = match action {
            Action::Join { channel_id, channel, password } => {
                // Servers join by channel ID only.
                let id = match (channel_id, channel) {
                    (Some(id), _) => id,
                    (None, Some(path)) if !path.is_empty() => {
                        let inner = self.inner.lock().unwrap();
                        let rt = inner.servers.get(&server_id).ok_or_else(|| HubError::NotFound("No such server".into()))?;
                        rt.state.channel_by_path(&path).ok_or_else(|| HubError::NotFound(format!("There is no channel {path}")))?
                    }
                    _ => return Err(HubError::Invalid("Say which channel to join".into())),
                };
                let mut l = Line::new("join").with("chanid", id);
                if !password.is_empty() {
                    l.set("password", password);
                }
                l
            }
            Action::Leave => Line::new("leave"),
            Action::Move { user_id, channel_id } => Line::new("moveuser").with("userid", user_id).with("chanid", channel_id),
            Action::Kick { user_id, channel_id } => {
                let mut l = Line::new("kick").with("userid", user_id);
                if let Some(c) = channel_id {
                    l.set("chanid", c);
                }
                l
            }
            Action::Ban { user_id } => Line::new("ban").with("userid", user_id),
            Action::Nickname { nickname } => {
                let nickname = nickname.trim().to_owned();
                if nickname.is_empty() {
                    return Err(HubError::Invalid("Enter a nickname".into()));
                }
                self.command(owner, server_id, Line::new("changenick").with("nickname", nickname.as_str())).await?;
                // The server took it: keep it for later logins, and in the
                // settings, without logging in again.
                if let Ok(session) = self.session(server_id) {
                    session.remember_nickname(&nickname);
                }
                self.with_store(|s| s.set_nickname(server_id, &nickname))?;
                self.reconcile(false);
                return Ok(());
            }
            Action::Status { status_mode, status_msg } => {
                // Keep the monitor's gender unless this says one.
                let mode = if status_mode & GENDER_BITS == 0 {
                    let inner = self.inner.lock().unwrap();
                    status_mode | inner.servers.get(&server_id).map_or(0, |rt| rt.config.status_mode & GENDER_BITS)
                } else {
                    status_mode
                };
                self.command(owner, server_id, Line::new("changestatus").with("statusmode", mode).with("statusmsg", status_msg.as_str())).await?;
                // The server took it: keep it for later logins, and in the
                // settings, without logging in again.
                let mode = mode & GENDER_BITS;
                if let Ok(session) = self.session(server_id) {
                    session.remember_status(mode, &status_msg);
                }
                self.with_store(|s| s.set_status(server_id, mode, &status_msg))?;
                self.reconcile(false);
                return Ok(());
            }
        };
        self.command(owner, server_id, line).await?;
        Ok(())
    }

    /// Server administration: accounts, bans, settings and statistics. Only
    /// these commands and their own fields are passed on; the server itself
    /// decides whether the monitor's account may do them. Returns what the
    /// server answered (accounts, bans, statistics, new settings).
    pub async fn admin(&self, owner: i64, server_id: i64, command: &str, params: &serde_json::Map<String, serde_json::Value>) -> Result<Vec<serde_json::Value>> {
        let allowed: &[&str] = match command {
            "listaccounts" | "listbans" => &["index", "count", "chanid"],
            "newaccount" => &["username", "password", "usertype", "userrights", "note", "initchan", "userdata", "audiocodeclimit", "cmdflood", "opchannels"],
            "delaccount" => &["username"],
            "ban" | "unban" => &["userid", "ipaddr", "username", "chanid", "channel", "bantype"],
            "updateserver" => &[
                "servername", "motdraw", "maxusers", "maxloginattempts", "maxiplogins", "logindelay", "usertimeout", "autosave",
                "tcpport", "udpport", "voicetxlimit", "videotxlimit", "mediafiletxlimit", "desktoptxlimit", "totaltxlimit", "logevents",
            ],
            "querystats" | "saveconfig" => &[],
            _ => return Err(HubError::Invalid(format!("{command} is not a server management command"))),
        };
        let mut line = Line::new(command);
        for (k, v) in params {
            if !allowed.contains(&k.as_str()) {
                return Err(HubError::Invalid(format!("{command} does not take {k}")));
            }
            let value = crate::tt::line::Value::from_json(v).ok_or_else(|| HubError::Invalid(format!("{k} has the wrong kind of value")))?;
            line.set(k, value);
        }
        let lines = self.command(owner, server_id, line).await?;
        Ok(lines.iter().filter(|l| l.name != "ok").map(|l| l.to_json()).collect())
    }

    // Devices

    /// A new app install: its secret token and push key. `address` is
    /// where the request came from, to slow down mass sign-ups.
    pub fn register(&self, device_name: &str, address: &str) -> Result<Registered> {
        if !self.register_limit.allow(address) {
            return Err(HubError::Refused("Too many new sign-ups from your network; try again later".into()));
        }
        let token_bytes: [u8; 32] = rand::random();
        let token = B64URL.encode(token_bytes);
        let push_key: [u8; 32] = rand::random();
        let name: String = device_name.trim().chars().take(100).collect();
        let name = if name.is_empty() { "iPhone".to_owned() } else { name };
        let device_id = self.with_store(|s| s.add_device(&name, &hash(&token), &push_key, &push::Prefs::default()))?;
        tracing::info!(device = device_id, "registered");
        Ok(Registered { device_id, token, push_key: B64.encode(push_key) })
    }

    /// Merge another sign-up of the same person into this one. Holding the
    /// other sign-up's secret token is the proof it is theirs.
    pub fn merge(&self, into: i64, other_token: &str) -> Result<()> {
        let other = self
            .with_store(|s| s.device_by_token(&hash(other_token)))?
            .ok_or_else(|| HubError::NotFound("That sign-up does not exist (it may be merged already)".into()))?;
        if other.id == into {
            return Ok(());
        }
        self.with_store(|s| s.merge_devices(into, other.id))?;
        tracing::info!(into, from = other.id, "merged sign-ups");
        self.reconcile(true);
        Ok(())
    }

    /// Forget a device and stop monitoring its servers.
    pub fn remove_device(&self, id: i64) -> Result<()> {
        self.with_store(|s| s.remove_device(id))?;
        self.reconcile(false);
        Ok(())
    }

    pub fn authenticate(&self, token: &str) -> Option<Device> {
        let woke = {
            let inner = self.inner.lock().unwrap();
            let d = inner.store.device_by_token(&hash(token)).ok()??;
            // Only note visits now and then.
            if now_ms() - d.last_seen > 60_000 {
                let _ = inner.store.touch_device(d.id);
            }
            // The app is back: monitor its servers again.
            d.dormant && inner.store.wake_device(d.id).unwrap_or(false)
        };
        if woke {
            tracing::info!("a dormant sign-up is back; monitoring its servers again");
            self.reconcile(true);
        }
        let inner = self.inner.lock().unwrap();
        inner.store.device_by_token(&hash(token)).ok()?
    }

    /// Once a day per phone, a silent push: Apple refuses it when the app
    /// has been deleted, so the service learns of it even when the
    /// monitored server is quiet.
    pub fn check_phones(&self) {
        let due = self.with_store(|s| s.push_targets_due(now_ms(), crate::store::PHONE_CHECK_EVERY_MS));
        let due = match due {
            Ok(d) => d,
            Err(e) => {
                tracing::error!("could not list phones to check: {e:#}");
                return;
            }
        };
        let push = self.push.lock().unwrap();
        let Some(push) = push.as_ref() else { return };
        for t in due {
            let _ = push.send(PushJob { apns_token: t.apns_token, sandbox: t.sandbox, payload: push::silent_payload(), background: true });
        }
    }

    /// Put abandoned sign-ups to sleep and delete long-abandoned ones.
    pub fn sweep(&self, retention: crate::store::Retention) {
        let result = self.with_store(|s| s.sweep(now_ms(), retention));
        match result {
            Ok(r) if r.dormant.is_empty() && r.deleted.is_empty() => {}
            Ok(r) => {
                tracing::info!(dormant = ?r.dormant, deleted = ?r.deleted, "swept abandoned sign-ups");
                self.reconcile(true);
            }
            Err(e) => tracing::error!("sweep failed: {e:#}"),
        }
    }

    pub fn forget_apns_token(&self, token: &str) {
        let _ = self.with_store(|s| s.drop_apns_token(token));
    }
}

pub fn hash(s: &str) -> String {
    hex::encode(Sha256::digest(s.as_bytes()))
}

struct ServerSink {
    hub: Weak<Hub>,
    server_id: i64,
    generation: u64,
}

impl Sink for ServerSink {
    fn status(&self, status: ConnectionStatus, reason: Option<String>) {
        if let Some(hub) = self.hub.upgrade().filter(|h| h.current(self.server_id, self.generation)) {
            hub.on_status(self.server_id, status, reason);
        }
    }

    fn line(&self, line: &Line) {
        if let Some(hub) = self.hub.upgrade().filter(|h| h.current(self.server_id, self.generation)) {
            hub.on_line(self.server_id, line);
        }
    }
}
