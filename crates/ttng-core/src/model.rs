//! What the apps see: the server, its channels and users, messages, and the
//! events that change them. Plain data, converted from the SDK's structs.

use std::time::{SystemTime, UNIX_EPOCH};

use ttng_sys as sys;

use crate::text::from_tt;

/// Where a connection stands.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ConnectionState {
    Disconnected,
    Connecting,
    /// Connected, logging in.
    LoggingIn,
    LoggedIn,
    /// The connection dropped; trying again (attempt number, from 1).
    Reconnecting {
        attempt: u32,
    },
}

/// The server's properties, as far as a client may see them.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct ServerInfo {
    pub name: String,
    pub motd: String,
    pub version: String,
    pub max_users: i32,
}

impl From<&sys::ServerProperties> for ServerInfo {
    fn from(p: &sys::ServerProperties) -> Self {
        ServerInfo {
            name: from_tt(&p.szServerName),
            motd: from_tt(&p.szMOTD),
            version: from_tt(&p.szServerVersion),
            max_users: p.nMaxUsers,
        }
    }
}

/// A channel. The root channel (no parent) has an empty name.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Channel {
    pub id: i32,
    /// 0 for the root channel.
    pub parent_id: i32,
    pub name: String,
    pub topic: String,
    pub has_password: bool,
    pub max_users: i32,
    /// Stays when empty (otherwise the server removes it once the last
    /// person leaves).
    pub permanent: bool,
    /// One person can talk at a time.
    pub solo_transmit: bool,
    /// Only people the operators allow can talk.
    pub classroom: bool,
    /// Only operators hear the others.
    pub operator_receive_only: bool,
    pub no_voice_activation: bool,
    pub no_recording: bool,
    pub hidden: bool,
}

impl From<&sys::Channel> for Channel {
    fn from(c: &sys::Channel) -> Self {
        let t = c.uChannelType;
        let has = |flag: sys::ChannelType| t & flag != 0;
        Channel {
            id: c.nChannelID,
            parent_id: c.nParentID,
            name: from_tt(&c.szName),
            topic: from_tt(&c.szTopic),
            has_password: c.bPassword != 0,
            max_users: c.nMaxUsers,
            permanent: has(sys::ChannelType_CHANNEL_PERMANENT),
            solo_transmit: has(sys::ChannelType_CHANNEL_SOLO_TRANSMIT),
            classroom: has(sys::ChannelType_CHANNEL_CLASSROOM),
            operator_receive_only: has(sys::ChannelType_CHANNEL_OPERATOR_RECVONLY),
            no_voice_activation: has(sys::ChannelType_CHANNEL_NO_VOICEACTIVATION),
            no_recording: has(sys::ChannelType_CHANNEL_NO_RECORDING),
            hidden: has(sys::ChannelType_CHANNEL_HIDDEN),
        }
    }
}

/// Someone's status: the mode the TeamTalk clients agree on (the low byte of
/// `nStatusMode`), and their status message.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum StatusMode {
    Available,
    Away,
    Question,
}

impl StatusMode {
    fn from_raw(mode: i32) -> Self {
        match mode & 0xff {
            1 => StatusMode::Away,
            2 => StatusMode::Question,
            _ => StatusMode::Available,
        }
    }

    pub(crate) fn raw(self) -> i32 {
        match self {
            StatusMode::Available => 0,
            StatusMode::Away => 1,
            StatusMode::Question => 2,
        }
    }
}

/// A person on the server.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct User {
    pub id: i32,
    pub nickname: String,
    pub username: String,
    /// 0 when not in a channel.
    pub channel_id: i32,
    pub status: StatusMode,
    pub status_message: String,
    pub admin: bool,
    /// "TeamTalk NG", "TeamTalk 5" or whatever their client says.
    pub client_name: String,
    /// Shown to admins only; empty otherwise.
    pub ip_address: String,
    /// Talking right now (voice).
    pub talking: bool,
}

impl From<&sys::User> for User {
    fn from(u: &sys::User) -> Self {
        User {
            id: u.nUserID,
            nickname: from_tt(&u.szNickname),
            username: from_tt(&u.szUsername),
            channel_id: u.nChannelID,
            status: StatusMode::from_raw(u.nStatusMode),
            status_message: from_tt(&u.szStatusMsg),
            admin: u.uUserType & sys::UserType_USERTYPE_ADMIN != 0,
            client_name: from_tt(&u.szClientName),
            ip_address: from_tt(&u.szIPAddress),
            talking: u.uUserState & sys::UserState_USERSTATE_VOICE != 0,
        }
    }
}

impl User {
    /// The name to show: the nickname, or the username without one.
    pub fn display_name(&self) -> &str {
        if self.nickname.is_empty() {
            &self.username
        } else {
            &self.nickname
        }
    }
}

/// Who a message goes to.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum MessageTarget {
    /// Everyone in a channel.
    Channel(i32),
    /// One person, privately.
    User(i32),
    /// Everyone on the server (admins only).
    Broadcast,
}

/// A text message, whole (long ones arrive in parts and are joined).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct TextMessage {
    pub target: MessageTarget,
    pub from_user_id: i32,
    pub from_username: String,
    pub text: String,
    /// When it arrived, in milliseconds since the Unix epoch.
    pub received_at: u64,
}

pub(crate) fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}

/// Everything the core knows about a connection, at one moment.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Snapshot {
    pub state: Option<ConnectionState>,
    pub server: ServerInfo,
    pub my_user_id: i32,
    pub my_channel_id: i32,
    pub channels: Vec<Channel>,
    pub users: Vec<User>,
}

impl Snapshot {
    pub fn user(&self, id: i32) -> Option<&User> {
        self.users.iter().find(|u| u.id == id)
    }

    pub fn channel(&self, id: i32) -> Option<&Channel> {
        self.channels.iter().find(|c| c.id == id)
    }

    /// A channel's path ("/Lobby/Music/"), as TeamTalk shows it.
    pub fn channel_path(&self, id: i32) -> String {
        let mut names = Vec::new();
        let mut at = self.channel(id);
        while let Some(c) = at {
            if c.parent_id == 0 {
                break;
            }
            names.push(c.name.as_str());
            at = self.channel(c.parent_id);
        }
        names.reverse();
        if names.is_empty() {
            "/".into()
        } else {
            format!("/{}/", names.join("/"))
        }
    }

    /// The people in a channel.
    pub fn users_in(&self, channel_id: i32) -> Vec<&User> {
        self.users.iter().filter(|u| u.channel_id == channel_id).collect()
    }
}

/// What happened. A UI can rebuild everything from a snapshot plus the
/// events after it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Event {
    ConnectionChanged(ConnectionState),
    /// The connection is gone and won't be retried (with why, in words).
    ConnectionFailed(String),
    ServerUpdated(ServerInfo),
    ChannelAdded(Channel),
    ChannelUpdated(Channel),
    ChannelRemoved(Channel),
    UserLoggedIn(User),
    UserLoggedOut(User),
    UserUpdated(User),
    UserJoined {
        user: User,
        channel_id: i32,
    },
    UserLeft {
        user: User,
        channel_id: i32,
    },
    TalkingChanged {
        user_id: i32,
        talking: bool,
    },
    MessageReceived(TextMessage),
    /// Voice activation started (true) or stopped (false) sending my voice.
    VoiceActivated(bool),
    /// I was kicked: from a channel (`channel_id` > 0) or the server.
    Kicked {
        by_user_id: i32,
        channel_id: i32,
    },
}
