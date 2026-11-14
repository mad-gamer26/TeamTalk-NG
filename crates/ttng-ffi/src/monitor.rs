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
    pub channel: String,
    pub channel_password: String,
    pub enabled: bool,
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
    pub admin: bool,
    /// 0 when not in a channel.
    pub channel_id: i64,
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

    /// Registers this install alone; returns its token (keep it secret).
    pub fn register(&self, device_name: String) -> Result<String> {
        self.with(|m| m.register(&device_name)).map(|r| r.token)
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
                    admin: u.user_type == 2,
                    channel_id: u.channel_id.unwrap_or(0),
                })
                .collect(),
            my_user_id: v.my_user_id,
            seq: v.seq,
        })
    }

    pub fn add_server(&self, server: MonitorServerInput) -> Result<i64> {
        self.with(|m| m.add_server(&server.into()))
    }

    pub fn update_server(&self, server_id: i64, server: MonitorServerInput) -> Result<()> {
        self.with(|m| m.update_server(server_id, &server.into()))
    }

    pub fn remove_server(&self, server_id: i64) -> Result<()> {
        self.with(|m| m.remove_server(server_id))
    }

    pub fn pause(&self, server_id: i64, minutes: i64) -> Result<()> {
        self.with(|m| m.pause(server_id, minutes))
    }

    pub fn resume(&self, server_id: i64) -> Result<()> {
        self.with(|m| m.resume(server_id))
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
