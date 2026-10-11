//! A live copy of one TeamTalk server as the monitor sees it, built from the
//! protocol lines the server sends, and the meaningful events (someone
//! logged in, a message arrived) those lines amount to.

use std::collections::{BTreeMap, HashMap};

use serde::{Deserialize, Serialize};

use super::line::Line;

/// TeamTalk's message types (`TextMsgType` in the SDK).
pub const MSG_USER: i64 = 1;
pub const MSG_CHANNEL: i64 = 2;
pub const MSG_BROADCAST: i64 = 3;
pub const MSG_CUSTOM: i64 = 4;

/// Longest text one `message` command may carry; longer text is split into
/// parts sent with `more=1` (as TeamTalk clients do).
pub const MAX_MESSAGE_PART: usize = 511;

#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq)]
pub struct User {
    pub id: i64,
    pub nickname: String,
    pub username: String,
    pub status_mode: i64,
    pub status_msg: String,
    pub client_name: String,
    pub version: String,
    /// 1 = default user, 2 = administrator.
    pub user_type: i64,
    /// The channel the user is in, if the server shows it.
    pub channel_id: Option<i64>,
    /// 0 = text-only client (like this monitor), 1 = voice client.
    pub packet_protocol: i64,
    /// Only sent to administrators.
    #[serde(skip_serializing_if = "String::is_empty", default)]
    pub ip_address: String,
}

impl User {
    pub fn display_name(&self) -> String {
        if !self.nickname.trim().is_empty() {
            self.nickname.clone()
        } else if !self.username.is_empty() {
            self.username.clone()
        } else {
            format!("User {}", self.id)
        }
    }

    pub fn reference(&self) -> UserRef {
        UserRef { id: self.id, nickname: self.display_name(), username: self.username.clone() }
    }

    fn update_from(&mut self, l: &Line) {
        if let Some(v) = l.str("nickname") {
            self.nickname = v.to_owned();
        }
        if let Some(v) = l.str("username") {
            self.username = v.to_owned();
        }
        if let Some(v) = l.int("statusmode") {
            self.status_mode = v;
        }
        if let Some(v) = l.str("statusmsg") {
            self.status_msg = v.to_owned();
        }
        if let Some(v) = l.str("clientname") {
            self.client_name = v.to_owned();
        }
        if let Some(v) = l.str("version") {
            self.version = v.to_owned();
        }
        if let Some(v) = l.int("usertype") {
            self.user_type = v;
        }
        if let Some(v) = l.int("packetprotocol") {
            self.packet_protocol = v;
        }
        if let Some(v) = l.str("ipaddr") {
            self.ip_address = v.to_owned();
        }
    }
}

/// Who did something, as they were called at the time.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct UserRef {
    pub id: i64,
    pub nickname: String,
    pub username: String,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq)]
pub struct Channel {
    pub id: i64,
    pub parent_id: i64,
    pub name: String,
    /// Full path, such as `/` or `/Lobby/Music/`.
    pub path: String,
    pub topic: String,
    pub password_protected: bool,
    pub max_users: i64,
    /// TeamTalk's `ChannelType` bits.
    pub channel_type: i64,
    pub operators: Vec<i64>,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq)]
pub struct ServerInfo {
    /// Every server setting as the server last sent it (`serverupdate`),
    /// for the server settings screen.
    #[serde(default)]
    pub properties: serde_json::Map<String, serde_json::Value>,
    pub name: String,
    pub motd: String,
    pub version: String,
    pub protocol: String,
    pub max_users: i64,
    pub user_timeout: i64,
}

/// The monitor's own login.
#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq)]
pub struct Me {
    pub user_id: i64,
    pub user_type: i64,
    /// TeamTalk's `UserRight` bits for the monitor's account.
    pub user_rights: i64,
    pub channel_id: Option<i64>,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum MessageKind {
    User,
    Channel,
    Broadcast,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct TextMessage {
    pub kind: MessageKind,
    pub from: UserRef,
    /// The recipient of a private message.
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub to: Option<UserRef>,
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub channel_id: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub channel_path: Option<String>,
    pub text: String,
    /// Sent by the monitor (from the app).
    pub outgoing: bool,
    /// Neither from nor to the monitor: seen because the monitor's account
    /// is intercepting someone's messages.
    pub intercepted: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum Event {
    /// The monitor's link to the server changed.
    Connection { status: ConnectionStatus, #[serde(skip_serializing_if = "Option::is_none", default)] reason: Option<String> },
    LoggedIn { user: User },
    LoggedOut { user: User },
    Joined { user: User, channel_id: i64, channel_path: String },
    Left { user: User, channel_id: i64, channel_path: String },
    UserUpdated { user: User },
    ChannelAdded { channel: Channel },
    ChannelUpdated { channel: Channel },
    ChannelRemoved { channel_id: i64, channel_path: String },
    ServerUpdated { info: ServerInfo },
    Message { message: TextMessage },
    /// The monitor was kicked from a channel or (when `channel_id` is
    /// missing) from the server.
    Kicked { #[serde(skip_serializing_if = "Option::is_none", default)] by: Option<UserRef>, #[serde(skip_serializing_if = "Option::is_none", default)] channel_id: Option<i64> },
    /// The monitor joined or left a channel.
    MyChannel { #[serde(skip_serializing_if = "Option::is_none", default)] channel_id: Option<i64> },
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum ConnectionStatus {
    Connecting,
    Connected,
    LoggedIn,
    Disconnected,
    /// The server refused the login; the monitor waits longer before
    /// trying again.
    LoginFailed,
    /// The same account logged in elsewhere, so the monitor stepped aside
    /// for a while.
    SteppedAside,
    /// Paused by the app while its owner is connected to the server.
    Paused,
}

/// Everything about one server, sent to the app when it opens it.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Snapshot {
    pub info: ServerInfo,
    pub me: Me,
    pub channels: Vec<Channel>,
    pub users: Vec<User>,
}

#[derive(Debug, Default)]
pub struct ServerState {
    pub info: ServerInfo,
    pub me: Me,
    pub channels: BTreeMap<i64, Channel>,
    pub users: BTreeMap<i64, User>,
    /// True from connecting until the login finishes: the server sends
    /// everyone and every channel then, which are not news.
    pub syncing: bool,
    /// Parts of long messages still arriving, by sender, type and target.
    partial: HashMap<(i64, i64, i64, i64), String>,
}

impl ServerState {
    pub fn reset(&mut self) {
        *self = ServerState::default();
    }

    pub fn snapshot(&self) -> Snapshot {
        Snapshot {
            info: self.info.clone(),
            me: self.me.clone(),
            channels: self.channels.values().cloned().collect(),
            users: self.users.values().cloned().collect(),
        }
    }

    pub fn channel_path(&self, id: i64) -> String {
        let mut names = Vec::new();
        let mut cur = id;
        // Bounded in case a server ever sends a loop.
        for _ in 0..64 {
            match self.channels.get(&cur) {
                Some(c) if c.parent_id != 0 => {
                    names.push(c.name.clone());
                    cur = c.parent_id;
                }
                _ => break,
            }
        }
        if names.is_empty() {
            return "/".into();
        }
        names.reverse();
        format!("/{}/", names.join("/"))
    }

    /// The channel at a path such as `/Lobby/` or `Lobby` (ignoring case).
    pub fn channel_by_path(&self, path: &str) -> Option<i64> {
        let want = normalize_path(path);
        self.channels.values().find(|c| c.path.eq_ignore_ascii_case(&want)).map(|c| c.id)
    }

    fn user_ref(&self, id: i64) -> UserRef {
        match self.users.get(&id) {
            Some(u) => u.reference(),
            None => UserRef { id, nickname: format!("User {id}"), username: String::new() },
        }
    }

    fn refresh_paths(&mut self) {
        let ids: Vec<i64> = self.channels.keys().copied().collect();
        for id in ids {
            let path = self.channel_path(id);
            if let Some(c) = self.channels.get_mut(&id) {
                c.path = path;
            }
        }
    }

    fn update_channel(&mut self, l: &Line) -> Option<Channel> {
        let id = l.int("chanid")?;
        let c = self.channels.entry(id).or_insert_with(|| Channel { id, ..Default::default() });
        if let Some(v) = l.int("parentid") {
            c.parent_id = v;
        }
        if let Some(v) = l.str("name") {
            c.name = v.to_owned();
        }
        if let Some(v) = l.str("topic") {
            c.topic = v.to_owned();
        }
        if let Some(v) = l.int("protected") {
            c.password_protected = v != 0;
        }
        if let Some(v) = l.int("maxusers") {
            c.max_users = v;
        }
        if let Some(v) = l.int("type") {
            c.channel_type = v;
        }
        if let Some(v) = l.list("operators") {
            c.operators = v.to_vec();
        }
        self.refresh_paths();
        self.channels.get(&id).cloned()
    }

    /// Apply one line from the server and return what it means.
    pub fn apply(&mut self, l: &Line) -> Vec<Event> {
        let mut out = Vec::new();
        match l.name.as_str() {
            "teamtalk" | "welcome" => {
                self.reset();
                self.syncing = true;
                self.me.user_id = l.int("userid").unwrap_or(0);
                self.info.user_timeout = l.int("usertimeout").unwrap_or(60);
                self.info.max_users = l.int("maxusers").unwrap_or(0);
                self.info.protocol = l.text("protocol");
            }
            "serverupdate" => {
                for (k, v) in &l.params {
                    if k != "id" {
                        self.info.properties.insert(k.clone(), v.to_json());
                    }
                }
                if let Some(v) = l.str("servername") {
                    self.info.name = v.to_owned();
                }
                if let Some(v) = l.str("motd") {
                    self.info.motd = v.to_owned();
                }
                if let Some(v) = l.str("version") {
                    self.info.version = v.to_owned();
                }
                if let Some(v) = l.int("maxusers") {
                    self.info.max_users = v;
                }
                if let Some(v) = l.int("usertimeout") {
                    self.info.user_timeout = v;
                }
                out.push(Event::ServerUpdated { info: self.info.clone() });
            }
            "accepted" => {
                if let Some(id) = l.int("userid") {
                    self.me.user_id = id;
                }
                self.me.user_type = l.int("usertype").unwrap_or(self.me.user_type);
                self.me.user_rights = l.int("userrights").unwrap_or(self.me.user_rights);
                let id = self.me.user_id;
                self.users.entry(id).or_insert_with(|| User { id, ..Default::default() }).update_from(l);
            }
            "loggedin" => {
                if let Some(id) = l.int("userid") {
                    let u = self.users.entry(id).or_insert_with(|| User { id, ..Default::default() });
                    u.update_from(l);
                    let u = u.clone();
                    if id != self.me.user_id {
                        out.push(Event::LoggedIn { user: u });
                    }
                }
            }
            "loggedout" => match l.int("userid") {
                Some(id) => {
                    let user = self.users.remove(&id).unwrap_or(User { id, ..Default::default() });
                    for k in self.partial.keys().filter(|k| k.0 == id).copied().collect::<Vec<_>>() {
                        self.partial.remove(&k);
                    }
                    if id != self.me.user_id {
                        out.push(Event::LoggedOut { user });
                    }
                }
                // No user: the monitor itself was logged out.
                None => {
                    self.channels.clear();
                    self.users.clear();
                    self.me.channel_id = None;
                }
            },
            "updateuser" => {
                if let Some(id) = l.int("userid") {
                    let u = self.users.entry(id).or_insert_with(|| User { id, ..Default::default() });
                    let before = u.clone();
                    u.update_from(l);
                    if let Some(c) = l.int("chanid") {
                        u.channel_id = (c != 0).then_some(c);
                    }
                    if *u != before {
                        out.push(Event::UserUpdated { user: u.clone() });
                    }
                }
            }
            "adduser" => {
                if let (Some(id), Some(chan)) = (l.int("userid"), l.int("chanid")) {
                    let u = self.users.entry(id).or_insert_with(|| User { id, ..Default::default() });
                    u.update_from(l);
                    u.channel_id = Some(chan);
                    let user = u.clone();
                    if id == self.me.user_id {
                        self.me.channel_id = Some(chan);
                    }
                    out.push(Event::Joined { user, channel_id: chan, channel_path: self.channel_path(chan) });
                }
            }
            "removeuser" => {
                if let Some(id) = l.int("userid") {
                    let chan = l.int("chanid").unwrap_or(0);
                    let path = self.channel_path(chan);
                    if let Some(u) = self.users.get_mut(&id) {
                        if u.channel_id == Some(chan) || chan == 0 {
                            u.channel_id = None;
                        }
                        let user = u.clone();
                        out.push(Event::Left { user, channel_id: chan, channel_path: path });
                    }
                    if id == self.me.user_id {
                        self.me.channel_id = None;
                    }
                }
            }
            "addchannel" => {
                if let Some(c) = self.update_channel(l) {
                    out.push(Event::ChannelAdded { channel: c });
                }
            }
            "updatechannel" => {
                if let Some(c) = self.update_channel(l) {
                    out.push(Event::ChannelUpdated { channel: c });
                }
            }
            "removechannel" => {
                if let Some(id) = l.int("chanid") {
                    let path = self.channel_path(id);
                    self.channels.remove(&id);
                    out.push(Event::ChannelRemoved { channel_id: id, channel_path: path });
                }
            }
            "joined" => {
                if let Some(c) = self.update_channel(l) {
                    self.me.channel_id = Some(c.id);
                    out.push(Event::MyChannel { channel_id: Some(c.id) });
                }
            }
            "left" => {
                self.me.channel_id = None;
                out.push(Event::MyChannel { channel_id: None });
            }
            "kicked" => {
                let by = l.int("kickerid").filter(|id| *id != 0).map(|id| self.user_ref(id));
                let channel_id = l.int("chanid").filter(|c| *c != 0);
                if channel_id.is_some() {
                    self.me.channel_id = None;
                }
                out.push(Event::Kicked { by, channel_id });
            }
            "messagedeliver" => {
                if let Some(m) = self.message(l) {
                    out.push(Event::Message { message: m });
                }
            }
            "ok" => {
                self.syncing = false;
            }
            _ => {}
        }
        if self.syncing {
            // Everything before the login finishes is the server's
            // current state, not news.
            out.retain(|e| matches!(e, Event::Connection { .. }));
        }
        out
    }

    fn message(&mut self, l: &Line) -> Option<TextMessage> {
        let kind = l.int("type")?;
        let src = l.int("srcuserid").unwrap_or(0);
        let dest = l.int("destuserid").unwrap_or(0);
        let chan = l.int("chanid").unwrap_or(0);
        let key = (src, kind, dest, chan);
        let mut text = self.partial.remove(&key).unwrap_or_default();
        text.push_str(&l.text("content"));
        if l.int("more").unwrap_or(0) != 0 {
            self.partial.insert(key, text);
            return None;
        }
        let me = self.me.user_id;
        let (kind, to, channel_id, intercepted) = match kind {
            MSG_USER => (MessageKind::User, Some(self.user_ref(dest)), None, dest != me && src != me),
            MSG_CHANNEL => (MessageKind::Channel, None, Some(chan), self.me.channel_id != Some(chan) && src != me),
            MSG_BROADCAST => (MessageKind::Broadcast, None, None, false),
            // Typing indicators and other custom messages.
            MSG_CUSTOM => return None,
            _ => return None,
        };
        Some(TextMessage {
            kind,
            from: self.user_ref(src),
            to,
            channel_path: channel_id.map(|c| self.channel_path(c)),
            channel_id,
            text,
            outgoing: src == me,
            intercepted,
        })
    }
}

/// A channel path with one slash at each end, as TeamTalk writes them.
pub fn normalize_path(path: &str) -> String {
    let inner = path.trim().trim_matches('/');
    if inner.is_empty() { "/".into() } else { format!("/{inner}/") }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn feed(s: &mut ServerState, lines: &str) -> Vec<Event> {
        lines.lines().filter(|l| !l.trim().is_empty()).flat_map(|l| s.apply(&Line::parse(l).unwrap())).collect()
    }

    fn logged_in() -> ServerState {
        let mut s = ServerState::default();
        let ev = feed(
            &mut s,
            r#"teamtalk userid=3 maxusers=1000 usertimeout=60 protocol="5.14"
begin id=1
accepted userid=3 nickname="Monitor" username="mon" usertype=1 userrights=259591
serverupdate servername="Test" motd="Hello" version="5.22.0.5198" usertimeout=60
addchannel chanid=1 parentid=0 name="" topic=""
addchannel chanid=2 parentid=1 name="Lobby" topic="Chat"
addchannel chanid=3 parentid=2 name="Music" protected=1
loggedin userid=3 nickname="Monitor" username="mon"
loggedin userid=5 nickname="Alice" username="alice" statusmode=0
adduser userid=5 chanid=2 nickname="Alice"
ok
end id=1"#,
        );
        assert!(ev.is_empty(), "nothing during sync is news: {ev:?}");
        s
    }

    #[test]
    fn builds_state_quietly_during_login() {
        let s = logged_in();
        assert!(!s.syncing);
        assert_eq!(s.info.name, "Test");
        assert_eq!(s.me.user_id, 3);
        assert_eq!(s.me.user_rights, 259591);
        assert_eq!(s.channel_path(1), "/");
        assert_eq!(s.channel_path(3), "/Lobby/Music/");
        assert_eq!(s.channels[&3].path, "/Lobby/Music/");
        assert!(s.channels[&3].password_protected);
        assert_eq!(s.users[&5].channel_id, Some(2));
        assert_eq!(s.channel_by_path("lobby/music"), Some(3));
        assert_eq!(s.channel_by_path("/"), Some(1));
        assert_eq!(s.channel_by_path("/Nowhere/"), None);
    }

    #[test]
    fn reports_logins_joins_and_logouts() {
        let mut s = logged_in();
        let ev = feed(
            &mut s,
            r#"loggedin userid=6 nickname="Bob" username="bob"
adduser userid=6 chanid=3
removeuser userid=6 chanid=3
loggedout userid=6"#,
        );
        assert!(matches!(&ev[0], Event::LoggedIn { user } if user.nickname == "Bob"));
        assert!(matches!(&ev[1], Event::Joined { channel_path, .. } if channel_path == "/Lobby/Music/"));
        assert!(matches!(&ev[2], Event::Left { channel_id: 3, .. }));
        assert!(matches!(&ev[3], Event::LoggedOut { user } if user.username == "bob"));
        assert!(!s.users.contains_key(&6));
    }

    #[test]
    fn joins_long_messages() {
        let mut s = logged_in();
        let ev = feed(
            &mut s,
            r#"messagedeliver type=1 srcuserid=5 destuserid=3 content="first " more=1
messagedeliver type=4 srcuserid=5 destuserid=3 content="typing\r\n1"
messagedeliver type=1 srcuserid=5 destuserid=3 content="second" more=0"#,
        );
        assert_eq!(ev.len(), 1);
        let Event::Message { message } = &ev[0] else { panic!() };
        assert_eq!(message.kind, MessageKind::User);
        assert_eq!(message.text, "first second");
        assert_eq!(message.from.nickname, "Alice");
        assert!(!message.outgoing && !message.intercepted);
    }

    #[test]
    fn channel_messages_know_where_they_are() {
        let mut s = logged_in();
        let ev = feed(&mut s, r#"messagedeliver type=2 srcuserid=5 chanid=2 content="hi all""#);
        let Event::Message { message } = &ev[0] else { panic!() };
        assert_eq!(message.channel_path.as_deref(), Some("/Lobby/"));
        // The monitor is not in /Lobby/, so it only sees this by intercepting.
        assert!(message.intercepted);
    }

    #[test]
    fn monitor_logout_clears_everything() {
        let mut s = logged_in();
        feed(&mut s, "loggedout");
        assert!(s.users.is_empty() && s.channels.is_empty());
    }
}
