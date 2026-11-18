//! The Monitor: ttmonitor.mad-gamer.com stays logged in to the person's
//! servers while the app isn't, keeps their private conversations, and
//! tells them what happened. Authorised by an NG Account session's token,
//! or by a token from registering this install on its own.

use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use crate::account::{answer, decode};
use crate::error::Result;

/// A monitored server and how the monitor's link to it stands.
#[derive(Clone, Debug, PartialEq, Eq, Deserialize)]
pub struct MonitorServer {
    pub id: i64,
    pub name: String,
    pub host: String,
    pub tcp_port: u16,
    pub encrypted: bool,
    pub enabled: bool,
    pub nickname: String,
    pub username: String,
    /// connecting, connected, logged_in, disconnected, login_failed,
    /// stepped_aside or paused.
    pub status: String,
    #[serde(default)]
    pub reason: Option<String>,
    pub status_since: i64,
    pub server_name: String,
    pub user_count: i64,
    pub unread_private_messages: i64,
}

impl MonitorServer {
    /// The status in words.
    pub fn status_text(&self) -> String {
        let s = match self.status.as_str() {
            "connecting" => "Connecting",
            "connected" => "Connected, logging in",
            "logged_in" => "Watching",
            "disconnected" => "Not connected",
            "login_failed" => "The server refused the login",
            "stepped_aside" => "Stepped aside (the account logged in elsewhere)",
            "paused" => "Paused while you're connected",
            other => other,
        };
        match &self.reason {
            Some(r) if !r.is_empty() => format!("{s}: {r}"),
            _ => s.to_owned(),
        }
    }
}

/// A server to monitor, or its new settings.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize)]
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
    /// neutral 4096; neither is male). The service keeps only these bits.
    pub status_mode: i64,
    pub channel: String,
    /// Empty keeps the one the service has (as does an empty `password`).
    pub channel_password: String,
    pub enabled: bool,
}

/// A monitored server's settings as the service keeps them (its passwords
/// are never sent back).
#[derive(Clone, Debug, Default, PartialEq, Eq, Deserialize)]
pub struct MonitorServerConfig {
    pub id: i64,
    pub name: String,
    pub host: String,
    pub tcp_port: u16,
    #[serde(default)]
    pub encrypted: bool,
    #[serde(default)]
    pub nickname: String,
    #[serde(default)]
    pub username: String,
    #[serde(default)]
    pub status_msg: String,
    #[serde(default)]
    pub status_mode: i64,
    #[serde(default)]
    pub channel: String,
    #[serde(default)]
    pub enabled: bool,
}

#[derive(Clone, Debug, PartialEq, Eq, Deserialize)]
pub struct MonitorUser {
    pub id: i64,
    pub nickname: String,
    pub username: String,
    #[serde(default)]
    pub status_mode: i64,
    #[serde(default)]
    pub status_msg: String,
    #[serde(default)]
    pub client_name: String,
    /// 2 for an administrator.
    #[serde(default)]
    pub user_type: i64,
    #[serde(default)]
    pub channel_id: Option<i64>,
}

impl MonitorUser {
    pub fn display_name(&self) -> String {
        if !self.nickname.trim().is_empty() {
            self.nickname.clone()
        } else if !self.username.is_empty() {
            self.username.clone()
        } else {
            format!("User {}", self.id)
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Deserialize)]
pub struct MonitorChannel {
    pub id: i64,
    pub parent_id: i64,
    pub name: String,
    /// "/" or "/Lobby/Music/".
    pub path: String,
    #[serde(default)]
    pub topic: String,
    #[serde(default)]
    pub password_protected: bool,
}

/// Who's where on a monitored server, as the monitor sees it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct MonitorView {
    pub server: MonitorServer,
    pub server_name: String,
    pub motd: String,
    pub channels: Vec<MonitorChannel>,
    pub users: Vec<MonitorUser>,
    /// The monitor's own user ID there.
    pub my_user_id: i64,
    /// The monitor's account: TeamTalk's user type (2: admin) and rights bits.
    pub my_user_type: i64,
    pub my_user_rights: i64,
    /// Events after this one are news.
    pub seq: i64,
}

/// Something that happened on a monitored server.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct MonitorEvent {
    pub seq: i64,
    pub server_id: i64,
    /// Milliseconds since the Unix epoch.
    pub time: i64,
    /// connection, logged_in, logged_out, joined, left, user_updated,
    /// channel_added, channel_updated, channel_removed, server_updated,
    /// message, kicked or my_channel.
    pub kind: String,
    /// What happened, in words to show and say.
    pub text: String,
    /// For messages: user, channel or broadcast; otherwise empty.
    pub message_kind: String,
    /// Who it's about (or who sent it), when someone.
    pub user_id: i64,
    pub user_name: String,
    /// The channel it's about (joined, left, a channel message, the
    /// monitor's channel, kicked from a channel), else 0.
    pub channel_id: i64,
    /// A message's own text, whether the monitor sent it, and (private
    /// messages) who it went to: for showing it as a live connection would.
    pub body: String,
    pub outgoing: bool,
    pub to_user_id: i64,
}

/// Events since a number, and whether some were missed.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct MonitorEvents {
    pub events: Vec<MonitorEvent>,
    pub last_seq: i64,
    /// Older events than the monitor keeps were asked for: reload the view.
    pub gap: bool,
}

/// A private conversation, with one login of one person.
#[derive(Clone, Debug, PartialEq, Eq, Deserialize)]
pub struct Conversation {
    pub id: i64,
    pub server_id: i64,
    pub user_id: i64,
    pub nickname: String,
    pub username: String,
    /// Still logged in, so replies reach them.
    pub active: bool,
    pub last_text: String,
    pub last_time: i64,
    pub last_outgoing: bool,
    pub unread: i64,
}

#[derive(Clone, Debug, PartialEq, Eq, Deserialize)]
pub struct PrivateMessage {
    pub id: i64,
    pub conversation_id: i64,
    pub outgoing: bool,
    pub text: String,
    pub time: i64,
    pub read: bool,
}

/// Who a message from the monitor goes to.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum MonitorTarget {
    /// A person, in a conversation (replies stop when it ends).
    User {
        user_id: i64,
        conversation_id: Option<i64>,
    },
    /// A channel; the monitor's own when `None`.
    Channel(Option<i64>),
    Broadcast,
}

/// Something for the monitor to do on the server.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum MonitorAction {
    Join {
        channel_path: String,
        password: String,
    },
    Leave,
    Move {
        user_id: i64,
        channel_id: i64,
    },
    /// From a channel, or the server when `None`.
    Kick {
        user_id: i64,
        channel_id: Option<i64>,
    },
    Ban {
        user_id: i64,
    },
    Nickname(String),
    Status {
        mode: i64,
        message: String,
    },
}

/// The Monitor for one install.
#[derive(Clone)]
pub struct Monitor {
    base: String,
    token: Option<String>,
    agent: ureq::Agent,
    /// Your own Monitor, through the relay (instead of `base`).
    tunnel: Option<std::sync::Arc<std::sync::Mutex<crate::tunnel::Tunnel>>>,
}

impl std::fmt::Debug for Monitor {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Monitor")
            .field("base", &self.base)
            .finish_non_exhaustive()
    }
}

/// A registration of this install alone (without NG Account).
#[derive(Clone, Debug, PartialEq, Eq, Deserialize)]
pub struct Registration {
    pub device_id: i64,
    /// A secret: keep it in the keychain.
    pub token: String,
    pub push_key: String,
}

impl Monitor {
    /// `token`: an NG Account session's, or a registration's.
    pub fn new(base_url: &str, token: Option<&str>) -> Monitor {
        Monitor {
            base: base_url.trim_end_matches('/').to_owned(),
            token: token.map(str::to_owned),
            agent: ureq::Agent::config_builder()
                .http_status_as_error(false)
                .timeout_global(Some(std::time::Duration::from_secs(30)))
                .build()
                .into(),
            tunnel: None,
        }
    }

    /// Your own paired Monitor, reached through the relay at `relay`.
    pub fn own(relay: &str, monitor: crate::tunnel::PairedMonitor, phone_key: &[u8; 32]) -> Monitor {
        let mut m = Monitor::new(relay, None);
        m.tunnel = Some(std::sync::Arc::new(std::sync::Mutex::new(crate::tunnel::Tunnel::new(
            relay, monitor, phone_key,
        ))));
        m
    }

    /// Your own Monitor's name and the key that opens its notifications
    /// (`{name, push_key, device_id, version}`); hosted Monitors have none.
    pub fn hello(&self) -> Result<Value> {
        match &self.tunnel {
            Some(t) => t.lock().unwrap_or_else(|e| e.into_inner()).hello(),
            None => Err(crate::ServiceError::Refused {
                status: 404,
                message: "Only your own Monitor says hello.".into(),
            }),
        }
    }

    pub fn has_token(&self) -> bool {
        self.token.is_some() || self.tunnel.is_some()
    }

    /// Registers this install on its own; it then uses the new token.
    pub fn register(&mut self, device_name: &str) -> Result<Registration> {
        let r: Registration =
            decode(self.call("POST", "/v1/register", Some(json!({ "device_name": device_name })))?)?;
        self.token = Some(r.token.clone());
        Ok(r)
    }

    /// Where this install's notifications go: its APNs device token (None
    /// turns them off), from a development build or not (Apple's sandbox),
    /// with the app's own reference returned in every push.
    pub fn set_push(&self, apns_token: Option<&str>, sandbox: bool, app_ref: &str, install_id: &str) -> Result<()> {
        self.set_push_for(apns_token, sandbox, app_ref, install_id, "")
    }

    /// As `set_push`, saying the app's bundle ID (`topic`): a build other
    /// than the main one (TTNG Dev) gets its pushes under its own.
    pub fn set_push_for(
        &self,
        apns_token: Option<&str>,
        sandbox: bool,
        app_ref: &str,
        install_id: &str,
        topic: &str,
    ) -> Result<()> {
        self.call(
            "PUT",
            "/v1/me/push",
            Some(json!({ "apns_token": apns_token, "sandbox": sandbox, "app_ref": app_ref, "install_id": install_id, "topic": topic })),
        )
        .map(|_| ())
    }

    pub fn servers(&self) -> Result<Vec<MonitorServer>> {
        let v = self.call("GET", "/v1/servers", None)?;
        decode(v.get("servers").cloned().unwrap_or(Value::Null))
    }

    pub fn view(&self, server_id: i64) -> Result<MonitorView> {
        let v = self.call("GET", &format!("/v1/servers/{server_id}"), None)?;
        let state = v.get("state").cloned().unwrap_or(Value::Null);
        let info = state.get("info").cloned().unwrap_or(Value::Null);
        let s = |v: &Value, k: &str| v.get(k).and_then(Value::as_str).unwrap_or_default().to_owned();
        Ok(MonitorView {
            server: decode(v.get("server").cloned().unwrap_or(Value::Null))?,
            server_name: s(&info, "name"),
            motd: s(&info, "motd"),
            channels: decode(state.get("channels").cloned().unwrap_or(json!([])))?,
            users: decode(state.get("users").cloned().unwrap_or(json!([])))?,
            my_user_id: state.pointer("/me/user_id").and_then(Value::as_i64).unwrap_or(0),
            my_user_type: state.pointer("/me/user_type").and_then(Value::as_i64).unwrap_or(0),
            my_user_rights: state.pointer("/me/user_rights").and_then(Value::as_i64).unwrap_or(0),
            seq: v.get("seq").and_then(Value::as_i64).unwrap_or(0),
        })
    }

    /// Adds a server to monitor; its ID.
    pub fn add_server(&self, s: &MonitorServerInput) -> Result<i64> {
        let v = self.call("POST", "/v1/servers", Some(json!(s)))?;
        Ok(v.get("id").and_then(Value::as_i64).unwrap_or(0))
    }

    /// A monitored server's settings (nickname, status message, gender,
    /// channel, enabled…).
    pub fn server_config(&self, id: i64) -> Result<MonitorServerConfig> {
        decode(self.call("GET", &format!("/v1/servers/{id}/config"), None)?)
    }

    pub fn update_server(&self, id: i64, s: &MonitorServerInput) -> Result<()> {
        self.call("PUT", &format!("/v1/servers/{id}"), Some(json!(s)))
            .map(|_| ())
    }

    pub fn remove_server(&self, id: i64) -> Result<()> {
        self.call("DELETE", &format!("/v1/servers/{id}"), None).map(|_| ())
    }

    /// Pauses watching while the app is connected itself (at most `minutes`).
    pub fn pause(&self, id: i64, minutes: i64) -> Result<()> {
        self.call(
            "POST",
            &format!("/v1/servers/{id}/pause"),
            Some(json!({ "minutes": minutes })),
        )
        .map(|_| ())
    }

    pub fn resume(&self, id: i64) -> Result<()> {
        self.call("DELETE", &format!("/v1/servers/{id}/pause"), None)
            .map(|_| ())
    }

    /// This install's app is logged in to the server itself: the monitor
    /// stays, but sends this install no notifications about the server for
    /// `seconds` (renewed while connected; it runs out by itself when the
    /// app is closed or the phone restarts). The account's other phones
    /// are notified as usual.
    pub fn quiet(&self, id: i64, install_id: &str, seconds: i64) -> Result<()> {
        self.call(
            "POST",
            &format!("/v1/servers/{id}/pause"),
            Some(json!({ "install_id": install_id, "seconds": seconds })),
        )
        .map(|_| ())
    }

    /// The app left the server: this install's notifications come back.
    pub fn unquiet(&self, id: i64, install_id: &str) -> Result<()> {
        let install: String = install_id
            .chars()
            .filter(|c| c.is_ascii_alphanumeric() || *c == '-')
            .collect();
        self.call("DELETE", &format!("/v1/servers/{id}/pause?install_id={install}"), None)
            .map(|_| ())
    }

    /// Events after `since` (None: the latest), for one server or all.
    pub fn events(&self, since: Option<i64>, server_id: Option<i64>) -> Result<MonitorEvents> {
        let mut q = vec!["limit=500".to_owned()];
        if let Some(s) = since {
            q.push(format!("since={s}"));
        }
        if let Some(id) = server_id {
            q.push(format!("server_id={id}"));
        }
        let v = self.call("GET", &format!("/v1/events?{}", q.join("&")), None)?;
        let events = v
            .get("events")
            .and_then(Value::as_array)
            .map(|a| a.iter().map(event).collect())
            .unwrap_or_default();
        Ok(MonitorEvents {
            events,
            last_seq: v.get("last_seq").and_then(Value::as_i64).unwrap_or(0),
            gap: v.get("gap").and_then(Value::as_bool).unwrap_or(false),
        })
    }

    pub fn send_message(&self, server_id: i64, to: &MonitorTarget, text: &str) -> Result<()> {
        let mut body = match to {
            MonitorTarget::User {
                user_id,
                conversation_id,
            } => {
                json!({ "to": "user", "user_id": user_id, "conversation_id": conversation_id })
            }
            MonitorTarget::Channel(c) => json!({ "to": "channel", "channel_id": c }),
            MonitorTarget::Broadcast => json!({ "to": "broadcast" }),
        };
        body["text"] = text.into();
        self.call("POST", &format!("/v1/servers/{server_id}/messages"), Some(body))
            .map(|_| ())
    }

    /// Server administration through the Monitor's own login (its owner
    /// only): a TeamTalk command with its parameters; the lines the server
    /// answered (each with its name as `type`).
    pub fn admin(&self, server_id: i64, command: &str, params: Value) -> Result<Vec<Value>> {
        let v = self.call(
            "POST",
            &format!("/v1/servers/{server_id}/admin"),
            Some(json!({ "command": command, "params": params })),
        )?;
        Ok(v.get("lines").and_then(Value::as_array).cloned().unwrap_or_default())
    }

    /// The server's settings as it last sent them (its `serverupdate`).
    pub fn server_properties(&self, server_id: i64) -> Result<serde_json::Map<String, Value>> {
        let v = self.call("GET", &format!("/v1/servers/{server_id}"), None)?;
        Ok(v.pointer("/state/info/properties")
            .and_then(Value::as_object)
            .cloned()
            .unwrap_or_default())
    }

    pub fn act(&self, server_id: i64, action: &MonitorAction) -> Result<()> {
        let body = match action {
            MonitorAction::Join { channel_path, password } => {
                json!({ "action": "join", "channel": channel_path, "password": password })
            }
            MonitorAction::Leave => json!({ "action": "leave" }),
            MonitorAction::Move { user_id, channel_id } => {
                json!({ "action": "move", "user_id": user_id, "channel_id": channel_id })
            }
            MonitorAction::Kick { user_id, channel_id } => {
                json!({ "action": "kick", "user_id": user_id, "channel_id": channel_id })
            }
            MonitorAction::Ban { user_id } => json!({ "action": "ban", "user_id": user_id }),
            MonitorAction::Nickname(n) => json!({ "action": "nickname", "nickname": n }),
            MonitorAction::Status { mode, message } => {
                json!({ "action": "status", "status_mode": mode, "status_msg": message })
            }
        };
        self.call("POST", &format!("/v1/servers/{server_id}/actions"), Some(body))
            .map(|_| ())
    }

    /// Conversations on one server, or all.
    pub fn conversations(&self, server_id: Option<i64>) -> Result<Vec<Conversation>> {
        let path = match server_id {
            Some(id) => format!("/v1/conversations?server_id={id}"),
            None => "/v1/conversations".into(),
        };
        let v = self.call("GET", &path, None)?;
        decode(v.get("conversations").cloned().unwrap_or(json!([])))
    }

    /// A conversation's messages, oldest first (`before` a message ID for
    /// earlier ones).
    pub fn messages(&self, server_id: i64, conversation_id: i64, before: Option<i64>) -> Result<Vec<PrivateMessage>> {
        let mut path = format!("/v1/servers/{server_id}/conversations/{conversation_id}/messages?limit=200");
        if let Some(b) = before {
            path.push_str(&format!("&before={b}"));
        }
        let v = self.call("GET", &path, None)?;
        let mut m: Vec<PrivateMessage> = decode(v.get("messages").cloned().unwrap_or(json!([])))?;
        m.sort_by_key(|m| (m.time, m.id));
        Ok(m)
    }

    pub fn mark_read(&self, server_id: i64, conversation_id: i64) -> Result<()> {
        self.call(
            "POST",
            &format!("/v1/servers/{server_id}/conversations/{conversation_id}/read"),
            Some(json!({})),
        )
        .map(|_| ())
    }

    pub fn delete_conversation(&self, server_id: i64, conversation_id: i64) -> Result<()> {
        self.call(
            "DELETE",
            &format!("/v1/servers/{server_id}/conversations/{conversation_id}"),
            None,
        )
        .map(|_| ())
    }

    fn call(&self, method: &str, path: &str, body: Option<Value>) -> Result<Value> {
        if let Some(t) = &self.tunnel {
            return t.lock().unwrap_or_else(|e| e.into_inner()).call(method, path, body);
        }
        let url = format!("{}{path}", self.base);
        let auth = self.token.as_ref().map(|t| format!("Bearer {t}"));
        let r = match (method, body) {
            ("GET", _) => {
                let mut q = self.agent.get(&url);
                if let Some(a) = &auth {
                    q = q.header("Authorization", a);
                }
                q.call()
            }
            ("DELETE", _) => {
                let mut q = self.agent.delete(&url);
                if let Some(a) = &auth {
                    q = q.header("Authorization", a);
                }
                q.call()
            }
            (m, body) => {
                let mut q = if m == "PUT" {
                    self.agent.put(&url)
                } else {
                    self.agent.post(&url)
                };
                if let Some(a) = &auth {
                    q = q.header("Authorization", a);
                }
                q.send_json(body.unwrap_or(json!({})))
            }
        };
        answer(r, self.token.is_some())
    }
}

/// One stored event, with its words.
fn event(e: &Value) -> MonitorEvent {
    let ev = e.get("event").cloned().unwrap_or(Value::Null);
    let kind = ev.get("type").and_then(Value::as_str).unwrap_or_default().to_owned();
    let name_of = |u: &Value| -> String {
        let n = u
            .get("nickname")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .trim()
            .to_owned();
        if !n.is_empty() {
            n
        } else {
            u.get("username")
                .and_then(Value::as_str)
                .unwrap_or("someone")
                .to_owned()
        }
    };
    let user = ev.get("user").cloned().or_else(|| ev.pointer("/message/from").cloned());
    let user_name = user.as_ref().map(name_of).unwrap_or_default();
    let user_id = user
        .as_ref()
        .and_then(|u| u.get("id"))
        .and_then(Value::as_i64)
        .unwrap_or(0);
    let path = |k: &str| ev.get(k).and_then(Value::as_str).unwrap_or_default().to_owned();
    let mut message_kind = String::new();
    let text = match kind.as_str() {
        "connection" => {
            let status = ev.get("status").and_then(Value::as_str).unwrap_or_default();
            let words = match status {
                "logged_in" => "The monitor logged in",
                "disconnected" => "The monitor lost the connection",
                "login_failed" => "The server refused the monitor's login",
                "stepped_aside" => "The monitor stepped aside (your account logged in elsewhere)",
                "paused" => "The monitor paused",
                "connecting" => "The monitor is connecting",
                _ => "The monitor's connection changed",
            };
            match ev.get("reason").and_then(Value::as_str) {
                Some(r) if !r.is_empty() => format!("{words}: {r}"),
                _ => words.to_owned(),
            }
        }
        "logged_in" => format!("{user_name} logged in"),
        "logged_out" => format!("{user_name} logged out"),
        "joined" => format!("{user_name} joined {}", path("channel_path")),
        "left" => format!("{user_name} left {}", path("channel_path")),
        "user_updated" => {
            let msg = ev
                .pointer("/user/status_msg")
                .and_then(Value::as_str)
                .unwrap_or_default();
            if msg.is_empty() {
                format!("{user_name} changed their status")
            } else {
                format!("{user_name}'s status: {msg}")
            }
        }
        "channel_added" => format!(
            "New channel {}",
            ev.pointer("/channel/path").and_then(Value::as_str).unwrap_or_default()
        ),
        "channel_updated" => format!(
            "Channel {} changed",
            ev.pointer("/channel/path").and_then(Value::as_str).unwrap_or_default()
        ),
        "channel_removed" => format!("Channel {} was removed", path("channel_path")),
        "server_updated" => "The server's settings changed".to_owned(),
        "message" => {
            let m = ev.get("message").cloned().unwrap_or(Value::Null);
            message_kind = m.get("kind").and_then(Value::as_str).unwrap_or_default().to_owned();
            let body = m.get("text").and_then(Value::as_str).unwrap_or_default();
            let outgoing = m.get("outgoing").and_then(Value::as_bool).unwrap_or(false);
            let to = m.get("to").map(name_of).unwrap_or_default();
            match (message_kind.as_str(), outgoing) {
                ("user", true) => format!("You to {to}: {body}"),
                ("user", false) => format!("{user_name}, privately: {body}"),
                ("broadcast", _) => format!("Broadcast from {user_name}: {body}"),
                (_, true) => format!("You in the channel: {body}"),
                _ => format!(
                    "{user_name} in {}: {body}",
                    m.get("channel_path").and_then(Value::as_str).unwrap_or("the channel")
                ),
            }
        }
        "kicked" => {
            let by = ev.get("by").map(name_of);
            match (ev.get("channel_id").and_then(Value::as_i64), by) {
                (Some(_), Some(b)) => format!("{b} kicked the monitor from its channel"),
                (Some(_), None) => "The monitor was kicked from its channel".to_owned(),
                (None, Some(b)) => format!("{b} kicked the monitor off the server"),
                (None, None) => "The monitor was kicked off the server".to_owned(),
            }
        }
        "my_channel" => match ev.get("channel_id").and_then(Value::as_i64) {
            Some(_) => "The monitor joined a channel".to_owned(),
            None => "The monitor left its channel".to_owned(),
        },
        other => other.replace('_', " "),
    };
    let msg = ev.get("message");
    let channel_id = ev
        .get("channel_id")
        .and_then(Value::as_i64)
        .or_else(|| msg.and_then(|m| m.get("channel_id")).and_then(Value::as_i64))
        .or_else(|| ev.pointer("/channel/id").and_then(Value::as_i64))
        .unwrap_or(0);
    MonitorEvent {
        seq: e.get("seq").and_then(Value::as_i64).unwrap_or(0),
        server_id: e.get("server_id").and_then(Value::as_i64).unwrap_or(0),
        time: e.get("time").and_then(Value::as_i64).unwrap_or(0),
        kind,
        text,
        message_kind,
        user_id,
        user_name,
        channel_id,
        body: msg
            .and_then(|m| m.get("text"))
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_owned(),
        outgoing: msg
            .and_then(|m| m.get("outgoing"))
            .and_then(Value::as_bool)
            .unwrap_or(false),
        to_user_id: msg
            .and_then(|m| m.pointer("/to/id"))
            .and_then(Value::as_i64)
            .unwrap_or(0),
    }
}
