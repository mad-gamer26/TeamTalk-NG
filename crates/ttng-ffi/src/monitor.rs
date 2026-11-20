//! The Monitor for the apps.

use std::sync::{Arc, Mutex};

use ttng_services as svc;

use crate::services::NgError;

type Result<T> = std::result::Result<T, NgError>;

#[derive(Clone, Debug, PartialEq, Eq, uniffi::Record)]
pub struct MonitorServer {
    pub id: i64,
    pub name: String,
    pub host: String,
    pub tcp_port: u16,
    pub encrypted: bool,
    pub enabled: bool,
    pub nickname: String,
    pub username: String,
    pub status: String,
    /// The status in words.
    pub status_text: String,
    pub status_since: i64,
    pub server_name: String,
    pub user_count: i64,
    pub unread_private_messages: i64,
}

impl From<svc::MonitorServer> for MonitorServer {
    fn from(s: svc::MonitorServer) -> Self {
        MonitorServer {
            status_text: s.status_text(),
            id: s.id,
            name: s.name,
            host: s.host,
            tcp_port: s.tcp_port,
            encrypted: s.encrypted,
            enabled: s.enabled,
            nickname: s.nickname,
            username: s.username,
            status: s.status,
            status_since: s.status_since,
            server_name: s.server_name,
            user_count: s.user_count,
            unread_private_messages: s.unread_private_messages,
        }
    }
}

#[derive(Clone, Debug, Default, PartialEq, Eq, uniffi::Record)]
pub struct MonitorServerInput {
    pub name: String,
    pub host: String,
    pub tcp_port: u16,
    pub encrypted: bool,
    pub nickname: String,
    pub username: String,
    pub password: String,
    pub status_msg: String,
    /// The monitor's gender as TeamTalk status mode bits (female 256,
    /// neutral 4096; neither is male).
    pub status_mode: i64,
    pub channel: String,
    /// Empty keeps the service's (as does an empty `password`).
    pub channel_password: String,
    pub enabled: bool,
}

/// A monitored server's settings as the service keeps them (no passwords).
#[derive(Clone, Debug, Default, PartialEq, Eq, uniffi::Record)]
pub struct MonitorServerConfig {
    pub id: i64,
    pub name: String,
    pub host: String,
    pub tcp_port: u16,
    pub encrypted: bool,
    pub nickname: String,
    pub username: String,
    pub status_msg: String,
    pub status_mode: i64,
    pub channel: String,
    pub enabled: bool,
}

impl From<svc::MonitorServerConfig> for MonitorServerConfig {
    fn from(c: svc::MonitorServerConfig) -> Self {
        MonitorServerConfig {
            id: c.id,
            name: c.name,
            host: c.host,
            tcp_port: c.tcp_port,
            encrypted: c.encrypted,
            nickname: c.nickname,
            username: c.username,
            status_msg: c.status_msg,
            status_mode: c.status_mode,
            channel: c.channel,
            enabled: c.enabled,
        }
    }
}

impl From<MonitorServerInput> for svc::MonitorServerInput {
    fn from(s: MonitorServerInput) -> Self {
        svc::MonitorServerInput {
            name: s.name,
            host: s.host,
            tcp_port: s.tcp_port,
            encrypted: s.encrypted,
            nickname: s.nickname,
            username: s.username,
            password: s.password,
            status_msg: s.status_msg,
            status_mode: s.status_mode,
            channel: s.channel,
            channel_password: s.channel_password,
            enabled: s.enabled,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq, uniffi::Record)]
pub struct MonitorUser {
    pub id: i64,
    pub display_name: String,
    pub username: String,
    pub status_msg: String,
    pub client_name: String,
    /// The client's version, such as "5.8".
    pub version: String,
    /// Shown to administrators only ("" otherwise).
    pub ip_address: String,
    pub admin: bool,
    /// 0 when not in a channel.
    pub channel_id: i64,
    /// TeamTalk's status bits (mode, gender, streaming, video, desktop).
    pub status_mode: i64,
    pub nickname: String,
}

#[derive(Clone, Debug, PartialEq, Eq, uniffi::Record)]
pub struct MonitorChannel {
    pub id: i64,
    pub parent_id: i64,
    pub name: String,
    pub path: String,
    pub topic: String,
    pub password_protected: bool,
}

#[derive(Clone, Debug, PartialEq, Eq, uniffi::Record)]
pub struct MonitorView {
    pub server: MonitorServer,
    pub server_name: String,
    pub motd: String,
    pub channels: Vec<MonitorChannel>,
    pub users: Vec<MonitorUser>,
    pub my_user_id: i64,
    /// The monitor's account: TeamTalk's user type (2: admin) and rights bits.
    pub my_user_type: i64,
    pub my_user_rights: i64,
    pub seq: i64,
}

#[derive(Clone, Debug, PartialEq, Eq, uniffi::Record)]
pub struct MonitorEvent {
    pub seq: i64,
    pub server_id: i64,
    pub time: i64,
    pub kind: String,
    /// What happened, in words to show and say.
    pub text: String,
    pub message_kind: String,
    pub user_id: i64,
    pub user_name: String,
    pub channel_id: i64,
    pub body: String,
    pub outgoing: bool,
    pub to_user_id: i64,
}

#[derive(Clone, Debug, PartialEq, Eq, uniffi::Record)]
pub struct MonitorEvents {
    pub events: Vec<MonitorEvent>,
    pub last_seq: i64,
    /// Some were missed: reload.
    pub gap: bool,
}

#[derive(Clone, Debug, PartialEq, Eq, uniffi::Record)]
pub struct MonitorConversation {
    pub id: i64,
    pub server_id: i64,
    pub user_id: i64,
    pub nickname: String,
    pub username: String,
    pub active: bool,
    pub last_text: String,
    pub last_time: i64,
    pub last_outgoing: bool,
    pub unread: i64,
}

#[derive(Clone, Debug, PartialEq, Eq, uniffi::Record)]
pub struct MonitorMessage {
    pub id: i64,
    pub outgoing: bool,
    pub text: String,
    pub time: i64,
}

#[derive(Clone, Debug, PartialEq, Eq, uniffi::Enum)]
pub enum MonitorTarget {
    User {
        user_id: i64,
        conversation_id: Option<i64>,
    },
    /// None: the monitor's own channel.
    Channel {
        channel_id: Option<i64>,
    },
    Broadcast,
}

#[derive(Clone, Debug, PartialEq, Eq, uniffi::Enum)]
pub enum MonitorAction {
    Join { channel_path: String, password: String },
    Leave,
    Move { user_id: i64, channel_id: i64 },
    Kick { user_id: i64, channel_id: Option<i64> },
    Ban { user_id: i64 },
    Nickname { nickname: String },
    Status { mode: i64, message: String },
}

/// The Monitor for one install. Calls block: run them off the main thread.
#[derive(uniffi::Object)]
pub struct MonitorClient {
    inner: Mutex<svc::Monitor>,
}

impl std::fmt::Debug for MonitorClient {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("MonitorClient").finish_non_exhaustive()
    }
}

impl MonitorClient {
    fn with<T>(&self, f: impl FnOnce(&mut svc::Monitor) -> std::result::Result<T, svc::ServiceError>) -> Result<T> {
        let mut m = self.inner.lock().unwrap_or_else(|e| e.into_inner());
        f(&mut m).map_err(Into::into)
    }
}

#[uniffi::export]
impl MonitorClient {
    /// `base_url` empty: the live service. `token`: an NG Account session's
    /// or this install's registration's.
    #[uniffi::constructor]
    pub fn new(base_url: String, token: Option<String>) -> Arc<Self> {
        let base = if base_url.is_empty() {
            svc::DEFAULT_BASE_URL.to_owned()
        } else {
            base_url
        };
        Arc::new(MonitorClient {
            inner: Mutex::new(svc::Monitor::new(&base, token.as_deref())),
        })
    }

    /// Your own Monitor (`ng-monitor` on a home computer), paired before,
    /// through the relay at `relay` (empty: the live service).
    #[uniffi::constructor]
    pub fn own(relay: String, monitor: OwnMonitor, phone_key: Vec<u8>) -> Result<Arc<Self>> {
        let relay = if relay.is_empty() {
            svc::DEFAULT_BASE_URL.to_owned()
        } else {
            relay
        };
        let monitor_key: [u8; 32] = monitor.monitor_key.try_into().map_err(|_| bad_key())?;
        let phone_key: [u8; 32] = phone_key.try_into().map_err(|_| bad_key())?;
        let paired = svc::PairedMonitor {
            monitor_id: monitor.monitor_id,
            name: monitor.name,
            monitor_key,
        };
        Ok(Arc::new(MonitorClient {
            inner: Mutex::new(svc::Monitor::own(&relay, paired, &phone_key)),
        }))
    }

    /// Your own Monitor's name and the key that opens its notifications.
    pub fn own_hello(&self) -> Result<OwnMonitorHello> {
        self.with(|m| m.hello()).map(|v| OwnMonitorHello {
            name: v["name"].as_str().unwrap_or_default().to_owned(),
            push_key: v["push_key"].as_str().unwrap_or_default().to_owned(),
            version: v["version"].as_str().unwrap_or_default().to_owned(),
        })
    }

    /// Registers this install alone; returns its token (keep it secret).
    pub fn register(&self, device_name: String) -> Result<String> {
        self.with(|m| m.register(&device_name)).map(|r| r.token)
    }

    /// As register, with the key that opens its notifications (secret too).
    pub fn register_with_key(&self, device_name: String) -> Result<MonitorRegistration> {
        self.with(|m| m.register(&device_name)).map(|r| MonitorRegistration {
            token: r.token,
            push_key: r.push_key,
        })
    }

    /// A live connection to the Monitor's events, from `since` (missed
    /// ones first) or from now.
    pub fn open_events(&self, since: Option<i64>) -> Result<Arc<MonitorEventStream>> {
        let stream = self.with(|m| m.open_events(since))?;
        Ok(Arc::new(MonitorEventStream {
            inner: Mutex::new(Some(stream)),
        }))
    }

    /// Ends this install's hosted registration: its servers (and their
    /// passwords) are deleted from the hosted Monitor.
    pub fn forget_registration(&self) -> Result<()> {
        self.with(|m| m.forget_registration())
    }

    /// Where this install's notifications go (see the services crate).
    pub fn set_push(
        &self,
        apns_token: Option<String>,
        sandbox: bool,
        app_ref: String,
        install_id: String,
        topic: String,
    ) -> Result<()> {
        self.with(|m| m.set_push_for(apns_token.as_deref(), sandbox, &app_ref, &install_id, &topic))
    }

    pub fn servers(&self) -> Result<Vec<MonitorServer>> {
        self.with(|m| m.servers())
            .map(|v| v.into_iter().map(Into::into).collect())
    }

    pub fn view(&self, server_id: i64) -> Result<MonitorView> {
        self.with(|m| m.view(server_id)).map(|v| MonitorView {
            server: v.server.into(),
            server_name: v.server_name,
            motd: v.motd,
            channels: v
                .channels
                .into_iter()
                .map(|c| MonitorChannel {
                    id: c.id,
                    parent_id: c.parent_id,
                    name: c.name,
                    path: c.path,
                    topic: c.topic,
                    password_protected: c.password_protected,
                })
                .collect(),
            users: v
                .users
                .into_iter()
                .map(|u| MonitorUser {
                    display_name: u.display_name(),
                    id: u.id,
                    username: u.username,
                    status_msg: u.status_msg,
                    client_name: u.client_name,
                    version: u.version,
                    ip_address: u.ip_address,
                    admin: u.user_type == 2,
                    channel_id: u.channel_id.unwrap_or(0),
                    status_mode: u.status_mode,
                    nickname: u.nickname,
                })
                .collect(),
            my_user_id: v.my_user_id,
            my_user_type: v.my_user_type,
            my_user_rights: v.my_user_rights,
            seq: v.seq,
        })
    }

    pub fn add_server(&self, server: MonitorServerInput) -> Result<i64> {
        self.with(|m| m.add_server(&server.into()))
    }

    /// A monitored server's settings: nickname, status message, gender,
    /// channel, enabled.
    pub fn server_config(&self, server_id: i64) -> Result<MonitorServerConfig> {
        self.with(|m| m.server_config(server_id)).map(Into::into)
    }

    pub fn update_server(&self, server_id: i64, server: MonitorServerInput) -> Result<()> {
        self.with(|m| m.update_server(server_id, &server.into()))
    }

    pub fn remove_server(&self, server_id: i64) -> Result<()> {
        self.with(|m| m.remove_server(server_id))
    }

    /// A server as it moves to another Monitor: opaque JSON with its
    /// settings (passwords too) and private conversations. An older
    /// Monitor answers Refused 404.
    pub fn export_server(&self, server_id: i64) -> Result<String> {
        self.with(|m| m.export_server(server_id))
    }

    /// Adds a server moved from another Monitor (`export_server`'s JSON).
    pub fn import_server(&self, moved: String) -> Result<i64> {
        self.with(|m| m.import_server(&moved))
    }

    /// This phone's notification settings on this Monitor, as opaque JSON.
    pub fn notification_prefs(&self) -> Result<String> {
        self.with(|m| m.prefs())
    }

    pub fn set_notification_prefs(&self, prefs: String) -> Result<()> {
        self.with(|m| m.set_prefs(&prefs))
    }

    pub fn pause(&self, server_id: i64, minutes: i64) -> Result<()> {
        self.with(|m| m.pause(server_id, minutes))
    }

    pub fn resume(&self, server_id: i64) -> Result<()> {
        self.with(|m| m.resume(server_id))
    }

    pub fn quiet(&self, server_id: i64, install_id: String, seconds: i64) -> Result<()> {
        self.with(|m| m.quiet(server_id, &install_id, seconds))
    }

    pub fn unquiet(&self, server_id: i64, install_id: String) -> Result<()> {
        self.with(|m| m.unquiet(server_id, &install_id))
    }

    pub fn events(&self, since: Option<i64>, server_id: Option<i64>) -> Result<MonitorEvents> {
        self.with(|m| m.events(since, server_id)).map(|e| MonitorEvents {
            events: e
                .events
                .into_iter()
                .map(|e| MonitorEvent {
                    seq: e.seq,
                    server_id: e.server_id,
                    time: e.time,
                    kind: e.kind,
                    text: e.text,
                    message_kind: e.message_kind,
                    user_id: e.user_id,
                    user_name: e.user_name,
                    channel_id: e.channel_id,
                    body: e.body,
                    outgoing: e.outgoing,
                    to_user_id: e.to_user_id,
                })
                .collect(),
            last_seq: e.last_seq,
            gap: e.gap,
        })
    }

    pub fn send_message(&self, server_id: i64, to: MonitorTarget, text: String) -> Result<()> {
        let to = match to {
            MonitorTarget::User {
                user_id,
                conversation_id,
            } => svc::MonitorTarget::User {
                user_id,
                conversation_id,
            },
            MonitorTarget::Channel { channel_id } => svc::MonitorTarget::Channel(channel_id),
            MonitorTarget::Broadcast => svc::MonitorTarget::Broadcast,
        };
        self.with(|m| m.send_message(server_id, &to, &text))
    }

    pub fn act(&self, server_id: i64, action: MonitorAction) -> Result<()> {
        let a = match action {
            MonitorAction::Join { channel_path, password } => svc::MonitorAction::Join { channel_path, password },
            MonitorAction::Leave => svc::MonitorAction::Leave,
            MonitorAction::Move { user_id, channel_id } => svc::MonitorAction::Move { user_id, channel_id },
            MonitorAction::Kick { user_id, channel_id } => svc::MonitorAction::Kick { user_id, channel_id },
            MonitorAction::Ban { user_id } => svc::MonitorAction::Ban { user_id },
            MonitorAction::Nickname { nickname } => svc::MonitorAction::Nickname(nickname),
            MonitorAction::Status { mode, message } => svc::MonitorAction::Status { mode, message },
        };
        self.with(|m| m.act(server_id, &a))
    }

    pub fn conversations(&self, server_id: Option<i64>) -> Result<Vec<MonitorConversation>> {
        self.with(|m| m.conversations(server_id)).map(|v| {
            v.into_iter()
                .map(|c| MonitorConversation {
                    id: c.id,
                    server_id: c.server_id,
                    user_id: c.user_id,
                    nickname: c.nickname,
                    username: c.username,
                    active: c.active,
                    last_text: c.last_text,
                    last_time: c.last_time,
                    last_outgoing: c.last_outgoing,
                    unread: c.unread,
                })
                .collect()
        })
    }

    pub fn messages(&self, server_id: i64, conversation_id: i64, before: Option<i64>) -> Result<Vec<MonitorMessage>> {
        self.with(|m| m.messages(server_id, conversation_id, before)).map(|v| {
            v.into_iter()
                .map(|m| MonitorMessage {
                    id: m.id,
                    outgoing: m.outgoing,
                    text: m.text,
                    time: m.time,
                })
                .collect()
        })
    }

    pub fn mark_read(&self, server_id: i64, conversation_id: i64) -> Result<()> {
        self.with(|m| m.mark_read(server_id, conversation_id))
    }

    pub fn delete_conversation(&self, server_id: i64, conversation_id: i64) -> Result<()> {
        self.with(|m| m.delete_conversation(server_id, conversation_id))
    }
}

fn event_of(e: svc::MonitorEvent) -> MonitorEvent {
    MonitorEvent {
        seq: e.seq,
        server_id: e.server_id,
        time: e.time,
        kind: e.kind,
        text: e.text,
        message_kind: e.message_kind,
        user_id: e.user_id,
        user_name: e.user_name,
        channel_id: e.channel_id,
        body: e.body,
        outgoing: e.outgoing,
        to_user_id: e.to_user_id,
    }
}

/// One thing from a Monitor's live connection.
#[derive(Clone, Debug, PartialEq, uniffi::Enum)]
pub enum MonitorStreamItem {
    /// An event (before `Ready`: one missed since the point asked for).
    Event { event: MonitorEvent },
    /// Caught up: what follows happens now.
    Ready { seq: i64 },
    /// The point asked for is unknown: start again from here.
    Reset { seq: i64 },
    /// Nothing in the last moment (still connected).
    Nothing,
}

/// A live connection to the Monitor's events (`next` blocks a moment at
/// most: run it off the main thread).
#[derive(uniffi::Object)]
pub struct MonitorEventStream {
    inner: Mutex<Option<svc::EventStream>>,
}

impl std::fmt::Debug for MonitorEventStream {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("MonitorEventStream").finish_non_exhaustive()
    }
}

#[uniffi::export]
impl MonitorEventStream {
    /// The next item; an error means the connection is gone.
    pub fn next(&self) -> Result<MonitorStreamItem> {
        let mut g = self.inner.lock().unwrap_or_else(|e| e.into_inner());
        let Some(s) = g.as_mut() else {
            return Err(NgError::Network {
                message: "The Monitor's live connection is closed.".into(),
            });
        };
        Ok(match s.receive()? {
            svc::StreamItem::Event(e) => MonitorStreamItem::Event { event: event_of(e) },
            svc::StreamItem::Ready(seq) => MonitorStreamItem::Ready { seq },
            svc::StreamItem::Reset(seq) => MonitorStreamItem::Reset { seq },
            svc::StreamItem::Nothing => MonitorStreamItem::Nothing,
        })
    }

    pub fn close(&self) {
        if let Some(mut s) = self.inner.lock().unwrap_or_else(|e| e.into_inner()).take() {
            s.close();
        }
    }
}

/// Your own Monitor, as pairing found it: keep all of it (the key proves
/// it's the one).
#[derive(Clone, Debug, PartialEq, Eq, uniffi::Record)]
pub struct OwnMonitor {
    pub monitor_id: String,
    pub name: String,
    pub monitor_key: Vec<u8>,
}

/// What your own Monitor says about itself.
#[derive(Clone, Debug, PartialEq, Eq, uniffi::Record)]
pub struct OwnMonitorHello {
    pub name: String,
    /// Opens its notifications (a secret).
    pub push_key: String,
    pub version: String,
}

fn bad_key() -> NgError {
    NgError::Unexpected {
        message: "A stored Monitor key is damaged. Pair again.".into(),
    }
}

/// A new private key for this phone, for pairing with your own Monitors
/// (keep it in the Keychain).
#[uniffi::export]
pub fn own_monitor_new_phone_key() -> Vec<u8> {
    svc::new_phone_key().to_vec()
}

/// Pairs with your own Monitor using the code it shows (blocks: run it off
/// the main thread). `relay` empty: the live service.
#[uniffi::export]
pub fn own_monitor_pair(relay: String, code: String, phone_name: String, phone_key: Vec<u8>) -> Result<OwnMonitor> {
    let relay = if relay.is_empty() {
        svc::DEFAULT_BASE_URL.to_owned()
    } else {
        relay
    };
    let phone_key: [u8; 32] = phone_key.try_into().map_err(|_| bad_key())?;
    let p = svc::pair_own_monitor(&relay, &code, &phone_name, &phone_key)?;
    Ok(OwnMonitor {
        monitor_id: p.monitor_id,
        name: p.name,
        monitor_key: p.monitor_key.to_vec(),
    })
}

/// A new registration: its token and the key that opens its notifications.
#[derive(Clone, Debug, uniffi::Record)]
pub struct MonitorRegistration {
    pub token: String,
    pub push_key: String,
}

// Server administration through the Monitor: TeamTalk's own commands and
// replies (the protocol's field names, as BearWare's server writes them),
// as the core's records, so the app's admin screens work the same.

use crate::Ban;
use crate::admin::{ServerSettings, ServerStatistics, UserAccount, UserRight};
use serde_json::{Value, json};

const BANTYPE_CHANNEL: u32 = 0x01;
const BANTYPE_IPADDR: u32 = 0x02;
const BANTYPE_USERNAME: u32 = 0x04;

fn text(v: &Value, k: &str) -> String {
    v.get(k).and_then(Value::as_str).unwrap_or_default().to_owned()
}

/// A time the server sends as Unix seconds, as text (the app formats it);
/// servers use small numbers for "never".
fn time(v: &Value, k: &str) -> String {
    match v.get(k) {
        Some(Value::Number(n)) => n
            .as_i64()
            .filter(|&t| t > 86_400)
            .map(|t| t.to_string())
            .unwrap_or_default(),
        Some(Value::String(s)) => s.clone(),
        _ => String::new(),
    }
}

fn int(v: &Value, k: &str) -> i64 {
    v.get(k).and_then(Value::as_i64).unwrap_or(0)
}

fn ints(v: &Value, k: &str) -> Vec<i64> {
    v.get(k)
        .and_then(Value::as_array)
        .map(|a| a.iter().filter_map(Value::as_i64).collect())
        .unwrap_or_default()
}

fn rights_from(bits: u32) -> Vec<UserRight> {
    ttng_core::UserRight::ALL
        .into_iter()
        .filter(|r| bits & r.bit() != 0)
        .map(Into::into)
        .collect()
}

fn rights_bits(rights: &[UserRight]) -> u32 {
    rights
        .iter()
        .map(|r| ttng_core::UserRight::from(*r).bit())
        .fold(0, |a, b| a | b)
}

pub(crate) fn account_from(l: &Value) -> UserAccount {
    let flood = ints(l, "cmdflood");
    UserAccount {
        username: text(l, "username"),
        password: text(l, "password"),
        admin: int(l, "usertype") & 2 != 0,
        rights: rights_from(int(l, "userrights") as u32),
        note: text(l, "note"),
        initial_channel: text(l, "initchan"),
        auto_operator_channels: ints(l, "opchannels").into_iter().map(|c| c as i32).collect(),
        bitrate_limit: int(l, "audiocodeclimit") as i32,
        commands_limit: flood.first().copied().unwrap_or(0) as i32,
        commands_interval_ms: flood.get(1).copied().unwrap_or(0) as i32,
        last_modified: time(l, "modifiedtime"),
        last_login: time(l, "lastlogin"),
    }
}

pub(crate) fn account_params(a: &UserAccount) -> Value {
    json!({
        "username": a.username, "password": a.password,
        "usertype": if a.admin { 2 } else { 1 },
        "userrights": if a.admin { 0 } else { rights_bits(&a.rights) },
        "note": a.note, "initchan": a.initial_channel,
        "opchannels": a.auto_operator_channels,
        "audiocodeclimit": a.bitrate_limit,
        "cmdflood": [a.commands_limit, a.commands_interval_ms],
    })
}

pub(crate) fn ban_from(l: &Value) -> Ban {
    let types = int(l, "type") as u32;
    Ban {
        ip_address: text(l, "ipaddr"),
        username: text(l, "username"),
        nickname: text(l, "nickname"),
        time: time(l, "bantime"),
        owner: text(l, "owner"),
        channel_path: text(l, "channel"),
        by_ip_address: types & BANTYPE_IPADDR != 0,
        by_username: types & BANTYPE_USERNAME != 0,
        in_channel: types & BANTYPE_CHANNEL != 0,
        raw_types: types,
    }
}

pub(crate) fn settings_from(p: &serde_json::Map<String, Value>) -> ServerSettings {
    let v = Value::Object(p.clone());
    let n = |k: &str| int(&v, k) as i32;
    ServerSettings {
        name: text(&v, "servername"),
        motd: text(&v, "motdraw"),
        max_users: n("maxusers"),
        max_login_attempts: n("maxloginattempts"),
        max_logins_per_address: n("maxiplogins"),
        login_delay_ms: n("logindelay"),
        voice_limit: n("voicetxlimit"),
        video_limit: n("videotxlimit"),
        media_file_limit: n("mediafiletxlimit"),
        desktop_limit: n("desktoptxlimit"),
        total_limit: n("totaltxlimit"),
        auto_save: int(&v, "autosave") != 0,
        tcp_port: n("tcpport"),
        udp_port: n("udpport"),
        user_timeout: n("usertimeout"),
        log_events: int(&v, "logevents") as u32,
        version: text(&v, "version"),
        protocol_version: text(&v, "protocol"),
    }
}

pub(crate) fn settings_params(s: &ServerSettings) -> Value {
    json!({
        "servername": s.name, "motdraw": s.motd, "maxusers": s.max_users,
        "maxloginattempts": s.max_login_attempts, "maxiplogins": s.max_logins_per_address,
        "logindelay": s.login_delay_ms, "voicetxlimit": s.voice_limit, "videotxlimit": s.video_limit,
        "mediafiletxlimit": s.media_file_limit, "desktoptxlimit": s.desktop_limit,
        "totaltxlimit": s.total_limit, "autosave": s.auto_save, "tcpport": s.tcp_port,
        "udpport": s.udp_port, "usertimeout": s.user_timeout, "logevents": s.log_events,
    })
}

pub(crate) fn statistics_from(l: &Value) -> ServerStatistics {
    ServerStatistics {
        total_bytes_sent: int(l, "totaltx"),
        total_bytes_received: int(l, "totalrx"),
        voice_bytes_sent: int(l, "voicetx"),
        voice_bytes_received: int(l, "voicerx"),
        video_bytes_sent: int(l, "videocaptx"),
        video_bytes_received: int(l, "videocaprx"),
        media_file_bytes_sent: int(l, "mediafiletx"),
        media_file_bytes_received: int(l, "mediafilerx"),
        desktop_bytes_sent: int(l, "desktoptx"),
        desktop_bytes_received: int(l, "desktoprx"),
        users_served: int(l, "usersserved") as i32,
        users_peak: int(l, "userspeak") as i32,
        files_sent: int(l, "filestx"),
        files_received: int(l, "filesrx"),
        uptime_ms: int(l, "uptime"),
    }
}

fn of_type<'a>(lines: &'a [Value], t: &'a str) -> impl Iterator<Item = &'a Value> + 'a {
    lines
        .iter()
        .filter(move |l| l.get("type").and_then(Value::as_str) == Some(t))
}

#[uniffi::export]
impl MonitorClient {
    /// The server's user accounts (the Monitor's login must be an admin).
    pub fn admin_accounts(&self, server_id: i64) -> Result<Vec<UserAccount>> {
        let lines = self.with(|m| m.admin(server_id, "listaccounts", json!({ "index": 0, "count": 100000 })))?;
        Ok(of_type(&lines, "useraccount").map(account_from).collect())
    }

    /// Adds an account, or changes the one with its username.
    pub fn admin_save_account(&self, server_id: i64, account: UserAccount) -> Result<()> {
        self.with(|m| m.admin(server_id, "newaccount", account_params(&account)))
            .map(|_| ())
    }

    pub fn admin_delete_account(&self, server_id: i64, username: String) -> Result<()> {
        self.with(|m| m.admin(server_id, "delaccount", json!({ "username": username })))
            .map(|_| ())
    }

    /// The server's bans (server-wide and channels').
    pub fn admin_bans(&self, server_id: i64) -> Result<Vec<Ban>> {
        let lines = self.with(|m| m.admin(server_id, "listbans", json!({ "index": 0, "count": 100000 })))?;
        // A ban's own `type` (its ban types, a number) hides the line's name
        // in the Monitor's reply: they're the lines with a ban time.
        Ok(lines
            .iter()
            .filter(|l| l.get("bantime").is_some() || l.get("type").and_then(Value::as_str) == Some("userbanned"))
            .map(ban_from)
            .collect())
    }

    /// A channel's bans.
    pub fn admin_channel_bans(&self, server_id: i64, channel_id: i32) -> Result<Vec<Ban>> {
        let lines = self.with(|m| {
            m.admin(
                server_id,
                "listbans",
                json!({ "chanid": channel_id, "index": 0, "count": 100000 }),
            )
        })?;
        Ok(lines
            .iter()
            .filter(|l| l.get("bantime").is_some())
            .map(ban_from)
            .collect())
    }

    /// Bans an IP address or a username (by hand), from the server or a
    /// channel (its path; empty: the server).
    pub fn admin_ban(&self, server_id: i64, address: String, username: String, channel_path: String) -> Result<()> {
        let mut types = if username.is_empty() {
            BANTYPE_IPADDR
        } else {
            BANTYPE_USERNAME
        };
        let mut p = json!({ "ipaddr": address, "username": username });
        if !channel_path.is_empty() {
            types |= BANTYPE_CHANNEL;
            p["channel"] = channel_path.into();
        }
        p["type"] = types.into();
        self.with(|m| m.admin(server_id, "ban", p)).map(|_| ())
    }

    pub fn admin_unban(&self, server_id: i64, ban: Ban) -> Result<()> {
        let p = json!({
            "ipaddr": ban.ip_address, "username": ban.username,
            "channel": ban.channel_path, "type": ban.raw_types,
        });
        self.with(|m| m.admin(server_id, "unban", p)).map(|_| ())
    }

    pub fn admin_server_settings(&self, server_id: i64) -> Result<ServerSettings> {
        Ok(settings_from(&self.with(|m| m.server_properties(server_id))?))
    }

    pub fn admin_update_server(&self, server_id: i64, settings: ServerSettings) -> Result<()> {
        self.with(|m| m.admin(server_id, "updateserver", settings_params(&settings)))
            .map(|_| ())
    }

    pub fn admin_statistics(&self, server_id: i64) -> Result<ServerStatistics> {
        let lines = self.with(|m| m.admin(server_id, "querystats", json!({})))?;
        Ok(of_type(&lines, "stats").next().map(statistics_from).unwrap_or_default())
    }

    pub fn admin_save_config(&self, server_id: i64) -> Result<()> {
        self.with(|m| m.admin(server_id, "saveconfig", json!({}))).map(|_| ())
    }
}
