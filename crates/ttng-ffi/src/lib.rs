//! TeamTalk NG's core for the apps (Swift on iPhone and Mac, Kotlin on
//! Android), through [UniFFI](https://mozilla.github.io/uniffi-rs/).
//!
//! The types here mirror `ttng-core`'s (which doesn't depend on UniFFI).
//! Every [`TtClient`] method blocks until the SDK or the server answers (up
//! to 20 s): call them off the main thread. Events arrive on the client's
//! event thread, one at a time, in order.

use std::sync::Arc;

use ttng_core as core;

uniffi::setup_scaffolding!();

mod admin;
mod monitor;
mod services;
mod sound;
pub use admin::*;
pub use monitor::*;
pub use services::*;
pub use sound::*;

/// What went wrong, in words the apps can show as they are (`message`).
#[derive(Clone, Debug, PartialEq, Eq, uniffi::Error)]
pub enum TtError {
    NotConnected {
        message: String,
    },
    Timeout {
        message: String,
    },
    /// The connection couldn't be made, or broke.
    Connection {
        message: String,
    },
    /// The server refused: its error number, and what it means.
    Server {
        code: i32,
        message: String,
    },
    /// Not possible now (or not allowed).
    Refused {
        message: String,
    },
}

impl std::fmt::Display for TtError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::NotConnected { message }
            | Self::Timeout { message }
            | Self::Connection { message }
            | Self::Server { message, .. }
            | Self::Refused { message } => f.write_str(message),
        }
    }
}

impl std::error::Error for TtError {}

impl From<core::Error> for TtError {
    fn from(e: core::Error) -> Self {
        let message = e.to_string();
        match e {
            core::Error::NotConnected => Self::NotConnected { message },
            core::Error::Timeout => Self::Timeout { message },
            core::Error::Connection(_) => Self::Connection { message },
            core::Error::Server { code, .. } => Self::Server { code, message },
            core::Error::Refused(_) => Self::Refused { message },
        }
    }
}

pub(crate) type Result<T> = std::result::Result<T, TtError>;

/// Where to connect, and as whom.
#[derive(Clone, Debug, PartialEq, Eq, uniffi::Record)]
pub struct ConnectOptions {
    pub host: String,
    pub tcp_port: u16,
    pub udp_port: u16,
    pub encrypted: bool,
    pub nickname: String,
    pub username: String,
    pub password: String,
    /// What other clients see as this client's name.
    pub client_name: String,
    /// A channel to join after logging in ("/Lobby/"); empty for none.
    pub join_channel_path: String,
    pub join_channel_password: String,
    /// Reconnect (and rejoin the channel) when the connection drops.
    pub reconnect: bool,
}

impl From<ConnectOptions> for core::ConnectOptions {
    fn from(o: ConnectOptions) -> Self {
        core::ConnectOptions {
            host: o.host,
            tcp_port: o.tcp_port,
            udp_port: o.udp_port,
            encrypted: o.encrypted,
            nickname: o.nickname,
            username: o.username,
            password: o.password,
            client_name: o.client_name,
            join_channel: (!o.join_channel_path.is_empty()).then_some((o.join_channel_path, o.join_channel_password)),
            reconnect: o.reconnect,
        }
    }
}

/// Which sound devices to use.
#[derive(Clone, Copy, Debug, PartialEq, Eq, uniffi::Enum)]
pub enum AudioDevices {
    /// The system's default input and output.
    Default,
    /// The defaults, shared with other connections (several servers at once).
    Shared,
    /// No hardware.
    Virtual,
}

impl From<AudioDevices> for core::AudioDevices {
    fn from(d: AudioDevices) -> Self {
        match d {
            AudioDevices::Default => Self::Default,
            AudioDevices::Shared => Self::Shared,
            AudioDevices::Virtual => Self::Virtual,
        }
    }
}

/// Where a connection stands.
#[derive(Clone, Debug, PartialEq, Eq, uniffi::Enum)]
pub enum ConnectionState {
    Disconnected,
    Connecting,
    LoggingIn,
    LoggedIn,
    /// The connection dropped; trying again (attempt number, from 1).
    Reconnecting {
        attempt: u32,
    },
}

impl From<core::ConnectionState> for ConnectionState {
    fn from(s: core::ConnectionState) -> Self {
        match s {
            core::ConnectionState::Disconnected => Self::Disconnected,
            core::ConnectionState::Connecting => Self::Connecting,
            core::ConnectionState::LoggingIn => Self::LoggingIn,
            core::ConnectionState::LoggedIn => Self::LoggedIn,
            core::ConnectionState::Reconnecting { attempt } => Self::Reconnecting { attempt },
        }
    }
}

#[derive(Clone, Debug, Default, PartialEq, Eq, uniffi::Record)]
pub struct ServerInfo {
    pub name: String,
    pub motd: String,
    pub version: String,
    pub max_users: i32,
}

impl From<core::ServerInfo> for ServerInfo {
    fn from(s: core::ServerInfo) -> Self {
        ServerInfo {
            name: s.name,
            motd: s.motd,
            version: s.version,
            max_users: s.max_users,
        }
    }
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, uniffi::Enum)]
pub enum CodecKind {
    #[default]
    NoAudio,
    Speex,
    SpeexVbr,
    Opus,
}

/// A channel's audio codec and its settings.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, uniffi::Record)]
pub struct AudioCodec {
    pub kind: CodecKind,
    pub sample_rate: i32,
    pub channels: i32,
    pub bitrate: i32,
    pub vbr: bool,
    pub dtx: bool,
    /// Opus tuned for music rather than voice.
    pub music: bool,
    pub frame_size_ms: i32,
    pub transmit_interval_ms: i32,
    /// Speex quality (0–10).
    pub quality: i32,
}

impl From<core::AudioCodec> for AudioCodec {
    fn from(c: core::AudioCodec) -> Self {
        AudioCodec {
            kind: match c.kind {
                core::CodecKind::NoAudio => CodecKind::NoAudio,
                core::CodecKind::Speex => CodecKind::Speex,
                core::CodecKind::SpeexVbr => CodecKind::SpeexVbr,
                core::CodecKind::Opus => CodecKind::Opus,
            },
            sample_rate: c.sample_rate,
            channels: c.channels,
            bitrate: c.bitrate,
            vbr: c.vbr,
            dtx: c.dtx,
            music: c.music,
            frame_size_ms: c.frame_size_ms,
            transmit_interval_ms: c.transmit_interval_ms,
            quality: c.quality,
        }
    }
}

impl From<AudioCodec> for core::AudioCodec {
    fn from(c: AudioCodec) -> Self {
        core::AudioCodec {
            kind: match c.kind {
                CodecKind::NoAudio => core::CodecKind::NoAudio,
                CodecKind::Speex => core::CodecKind::Speex,
                CodecKind::SpeexVbr => core::CodecKind::SpeexVbr,
                CodecKind::Opus => core::CodecKind::Opus,
            },
            sample_rate: c.sample_rate,
            channels: c.channels,
            bitrate: c.bitrate,
            vbr: c.vbr,
            dtx: c.dtx,
            music: c.music,
            frame_size_ms: c.frame_size_ms,
            transmit_interval_ms: c.transmit_interval_ms,
            quality: c.quality,
        }
    }
}

/// Opus as the desktop makes new channels.
#[uniffi::export]
pub fn opus_default() -> AudioCodec {
    core::AudioCodec::opus_default().into()
}

#[derive(Clone, Debug, Default, PartialEq, Eq, uniffi::Record)]
pub struct MediaFileInfo {
    pub duration_ms: u32,
    pub sample_rate: i32,
    pub channels: i32,
    pub video_width: i32,
    pub video_height: i32,
}

/// A media file's properties (nil when it can't be played).
#[uniffi::export]
pub fn media_file_info(path: String) -> Option<MediaFileInfo> {
    core::media_file_info(&path).map(|i| MediaFileInfo {
        duration_ms: i.duration_ms,
        sample_rate: i.sample_rate,
        channels: i.channels,
        video_width: i.video_width,
        video_height: i.video_height,
    })
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, uniffi::Enum)]
pub enum StreamStatus {
    Started,
    Playing,
    Paused,
    Finished,
    Failed,
    Stopped,
}

/// The file I'm streaming to my channel.
#[derive(Clone, Debug, PartialEq, Eq, uniffi::Record)]
pub struct MediaStream {
    pub path: String,
    pub status: StreamStatus,
    pub elapsed_ms: u32,
    pub duration_ms: u32,
    pub looping: bool,
}

impl From<core::MediaStream> for MediaStream {
    fn from(m: core::MediaStream) -> Self {
        MediaStream {
            path: m.path,
            status: match m.status {
                core::StreamStatus::Started => StreamStatus::Started,
                core::StreamStatus::Playing => StreamStatus::Playing,
                core::StreamStatus::Paused => StreamStatus::Paused,
                core::StreamStatus::Finished => StreamStatus::Finished,
                core::StreamStatus::Failed => StreamStatus::Failed,
                core::StreamStatus::Stopped => StreamStatus::Stopped,
            },
            elapsed_ms: m.elapsed_ms,
            duration_ms: m.duration_ms,
            looping: m.looping,
        }
    }
}

/// A channel. The root channel has parent 0 and an empty name.
#[derive(Clone, Debug, PartialEq, Eq, uniffi::Record)]
pub struct Channel {
    pub id: i32,
    pub parent_id: i32,
    pub name: String,
    pub topic: String,
    pub has_password: bool,
    pub max_users: i32,
    pub permanent: bool,
    pub solo_transmit: bool,
    pub classroom: bool,
    pub operator_receive_only: bool,
    pub no_voice_activation: bool,
    pub no_recording: bool,
    pub hidden: bool,
    /// Classroom channels: who may send what.
    pub transmit: Vec<TransmitPermission>,
    /// One-at-a-time channels: who waits to talk, the one talking first.
    pub transmit_queue: Vec<i32>,
    /// Admins only; empty otherwise.
    pub operator_password: String,
    pub disk_quota: i64,
    pub codec: AudioCodec,
    pub fixed_volume: bool,
    pub fixed_volume_level: i32,
    pub voice_timeout_ms: i32,
    pub media_timeout_ms: i32,
}

impl From<core::Channel> for Channel {
    fn from(c: core::Channel) -> Self {
        Channel {
            id: c.id,
            parent_id: c.parent_id,
            name: c.name,
            topic: c.topic,
            has_password: c.has_password,
            max_users: c.max_users,
            permanent: c.permanent,
            solo_transmit: c.solo_transmit,
            classroom: c.classroom,
            operator_receive_only: c.operator_receive_only,
            no_voice_activation: c.no_voice_activation,
            no_recording: c.no_recording,
            hidden: c.hidden,
            transmit_queue: c.transmit_queue.clone(),
            operator_password: c.operator_password.clone(),
            disk_quota: c.disk_quota,
            codec: c.codec.into(),
            fixed_volume: c.fixed_volume,
            fixed_volume_level: c.fixed_volume_level,
            voice_timeout_ms: c.voice_timeout_ms,
            media_timeout_ms: c.media_timeout_ms,
            transmit: c
                .transmit
                .iter()
                .map(|t| TransmitPermission {
                    user_id: t.user_id,
                    allowed: [
                        TransmitStream::Voice,
                        TransmitStream::Video,
                        TransmitStream::Desktop,
                        TransmitStream::MediaFile,
                        TransmitStream::ChannelMessages,
                    ]
                    .into_iter()
                    .filter(|s| t.allows((*s).into()))
                    .collect(),
                })
                .collect(),
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, uniffi::Enum)]
pub enum StatusMode {
    Available,
    Away,
    Question,
}

impl From<core::StatusMode> for StatusMode {
    fn from(s: core::StatusMode) -> Self {
        match s {
            core::StatusMode::Available => Self::Available,
            core::StatusMode::Away => Self::Away,
            core::StatusMode::Question => Self::Question,
        }
    }
}

impl From<StatusMode> for core::StatusMode {
    fn from(s: StatusMode) -> Self {
        match s {
            StatusMode::Available => Self::Available,
            StatusMode::Away => Self::Away,
            StatusMode::Question => Self::Question,
        }
    }
}

/// A person on the server.
#[derive(Clone, Debug, PartialEq, Eq, uniffi::Record)]
pub struct User {
    pub id: i32,
    /// The nickname, or the username without one.
    pub display_name: String,
    pub nickname: String,
    pub username: String,
    /// 0 when not in a channel.
    pub channel_id: i32,
    pub status: StatusMode,
    pub status_message: String,
    pub admin: bool,
    pub client_name: String,
    /// Shown to admins only; empty otherwise.
    pub ip_address: String,
    pub talking: bool,
    pub version: String,
    pub gender: Gender,
    pub sending_video: bool,
    pub sharing_desktop: bool,
    pub streaming_media: bool,
    pub playing_media: bool,
    /// What I receive from them, and they from me.
    pub my_subscriptions: Subscriptions,
    pub their_subscriptions: Subscriptions,
    pub voice_muted: bool,
    pub media_muted: bool,
    /// Percent (100 as sent).
    pub voice_volume: i32,
    pub media_volume: i32,
    pub voice_left: bool,
    pub voice_right: bool,
    pub media_left: bool,
    pub media_right: bool,
    /// An operator of their channel.
    pub operator: bool,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, uniffi::Enum)]
pub enum Gender {
    Male,
    Female,
    Neutral,
}

impl From<core::Gender> for Gender {
    fn from(g: core::Gender) -> Self {
        match g {
            core::Gender::Male => Self::Male,
            core::Gender::Female => Self::Female,
            core::Gender::Neutral => Self::Neutral,
        }
    }
}

impl From<Gender> for core::Gender {
    fn from(g: Gender) -> Self {
        match g {
            Gender::Male => Self::Male,
            Gender::Female => Self::Female,
            Gender::Neutral => Self::Neutral,
        }
    }
}

/// One kind of thing to receive from someone.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum Subscription {
    UserMessages,
    ChannelMessages,
    BroadcastMessages,
    Voice,
    Video,
    Desktop,
    DesktopAccess,
    MediaFile,
    InterceptUserMessages,
    InterceptChannelMessages,
    InterceptVoice,
    InterceptVideo,
    InterceptDesktop,
    InterceptMediaFile,
}

impl From<Subscription> for core::Subscription {
    fn from(s: Subscription) -> Self {
        use core::Subscription as S;
        match s {
            Subscription::UserMessages => S::UserMessages,
            Subscription::ChannelMessages => S::ChannelMessages,
            Subscription::BroadcastMessages => S::BroadcastMessages,
            Subscription::Voice => S::Voice,
            Subscription::Video => S::Video,
            Subscription::Desktop => S::Desktop,
            Subscription::DesktopAccess => S::DesktopAccess,
            Subscription::MediaFile => S::MediaFile,
            Subscription::InterceptUserMessages => S::InterceptUserMessages,
            Subscription::InterceptChannelMessages => S::InterceptChannelMessages,
            Subscription::InterceptVoice => S::InterceptVoice,
            Subscription::InterceptVideo => S::InterceptVideo,
            Subscription::InterceptDesktop => S::InterceptDesktop,
            Subscription::InterceptMediaFile => S::InterceptMediaFile,
        }
    }
}

const ALL_SUBSCRIPTIONS: [Subscription; 14] = [
    Subscription::UserMessages,
    Subscription::ChannelMessages,
    Subscription::BroadcastMessages,
    Subscription::Voice,
    Subscription::Video,
    Subscription::Desktop,
    Subscription::DesktopAccess,
    Subscription::MediaFile,
    Subscription::InterceptUserMessages,
    Subscription::InterceptChannelMessages,
    Subscription::InterceptVoice,
    Subscription::InterceptVideo,
    Subscription::InterceptDesktop,
    Subscription::InterceptMediaFile,
];

/// The subscriptions that are on.
#[derive(Clone, Debug, Default, PartialEq, Eq, uniffi::Record)]
pub struct Subscriptions {
    pub on: Vec<Subscription>,
}

impl From<core::Subscriptions> for Subscriptions {
    fn from(s: core::Subscriptions) -> Self {
        Subscriptions {
            on: ALL_SUBSCRIPTIONS.into_iter().filter(|x| s.has((*x).into())).collect(),
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, uniffi::Enum)]
pub enum AudioStream {
    Voice,
    MediaFile,
}

impl From<AudioStream> for core::AudioStream {
    fn from(s: AudioStream) -> Self {
        match s {
            AudioStream::Voice => Self::Voice,
            AudioStream::MediaFile => Self::MediaFile,
        }
    }
}

impl From<core::AudioStream> for AudioStream {
    fn from(s: core::AudioStream) -> Self {
        match s {
            core::AudioStream::Voice => Self::Voice,
            core::AudioStream::MediaFile => Self::MediaFile,
        }
    }
}

/// A stream someone may send in a classroom channel.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum TransmitStream {
    Voice,
    Video,
    Desktop,
    MediaFile,
    ChannelMessages,
}

impl From<TransmitStream> for core::TransmitStream {
    fn from(s: TransmitStream) -> Self {
        match s {
            TransmitStream::Voice => Self::Voice,
            TransmitStream::Video => Self::Video,
            TransmitStream::Desktop => Self::Desktop,
            TransmitStream::MediaFile => Self::MediaFile,
            TransmitStream::ChannelMessages => Self::ChannelMessages,
        }
    }
}

/// Who may send what in a classroom channel (`user_id` 0: everyone).
#[derive(Clone, Debug, PartialEq, Eq, uniffi::Record)]
pub struct TransmitPermission {
    pub user_id: i32,
    pub allowed: Vec<TransmitStream>,
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, uniffi::Record)]
pub struct UserStatistics {
    pub voice_packets_received: i64,
    pub voice_packets_lost: i64,
    pub media_audio_packets_received: i64,
    pub media_audio_packets_lost: i64,
    pub video_packets_received: i64,
    pub video_frames_received: i64,
    pub video_frames_lost: i64,
}

/// Whose audio I relay into my channel.
#[derive(Clone, Copy, Debug, PartialEq, Eq, uniffi::Record)]
pub struct Relay {
    pub user_id: i32,
    pub stream: AudioStream,
}

impl From<core::User> for User {
    fn from(u: core::User) -> Self {
        User {
            id: u.id,
            display_name: u.display_name().to_owned(),
            nickname: u.nickname,
            username: u.username,
            channel_id: u.channel_id,
            status: u.status.into(),
            status_message: u.status_message,
            admin: u.admin,
            client_name: u.client_name,
            ip_address: u.ip_address,
            talking: u.talking,
            version: u.version,
            gender: u.gender.into(),
            sending_video: u.sending_video,
            sharing_desktop: u.sharing_desktop,
            streaming_media: u.streaming_media,
            playing_media: u.playing_media,
            my_subscriptions: u.my_subscriptions.into(),
            their_subscriptions: u.their_subscriptions.into(),
            voice_muted: u.voice_muted,
            media_muted: u.media_muted,
            voice_volume: u.voice_volume,
            media_volume: u.media_volume,
            voice_left: u.voice_left,
            voice_right: u.voice_right,
            media_left: u.media_left,
            media_right: u.media_right,
            operator: u.operator,
        }
    }
}

/// Who a message goes to.
#[derive(Clone, Copy, Debug, PartialEq, Eq, uniffi::Enum)]
pub enum MessageTarget {
    Channel {
        channel_id: i32,
    },
    User {
        user_id: i32,
    },
    /// Everyone on the server (admins only).
    Broadcast,
}

impl From<core::MessageTarget> for MessageTarget {
    fn from(t: core::MessageTarget) -> Self {
        match t {
            core::MessageTarget::Channel(channel_id) => Self::Channel { channel_id },
            core::MessageTarget::User(user_id) => Self::User { user_id },
            core::MessageTarget::Broadcast => Self::Broadcast,
        }
    }
}

impl From<MessageTarget> for core::MessageTarget {
    fn from(t: MessageTarget) -> Self {
        match t {
            MessageTarget::Channel { channel_id } => Self::Channel(channel_id),
            MessageTarget::User { user_id } => Self::User(user_id),
            MessageTarget::Broadcast => Self::Broadcast,
        }
    }
}

/// A text message, whole.
#[derive(Clone, Debug, PartialEq, Eq, uniffi::Record)]
pub struct TextMessage {
    pub target: MessageTarget,
    pub from_user_id: i32,
    pub from_username: String,
    pub text: String,
    /// Milliseconds since the Unix epoch.
    pub received_at: u64,
}

impl From<core::TextMessage> for TextMessage {
    fn from(m: core::TextMessage) -> Self {
        TextMessage {
            target: m.target.into(),
            from_user_id: m.from_user_id,
            from_username: m.from_username,
            text: m.text,
            received_at: m.received_at,
        }
    }
}

/// A file in a channel's file area.
#[derive(Clone, Debug, PartialEq, Eq, uniffi::Record)]
pub struct RemoteFile {
    pub id: i32,
    pub channel_id: i32,
    pub name: String,
    /// In bytes.
    pub size: i64,
    /// Who uploaded it (username).
    pub uploader: String,
    /// When, as the server writes it.
    pub uploaded: String,
}

impl From<core::RemoteFile> for RemoteFile {
    fn from(f: core::RemoteFile) -> Self {
        RemoteFile {
            id: f.id,
            channel_id: f.channel_id,
            name: f.name,
            size: f.size,
            uploader: f.uploader,
            uploaded: f.uploaded,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, uniffi::Enum)]
pub enum TransferStatus {
    Active,
    Finished,
    Failed,
    Cancelled,
}

/// An upload or a download.
#[derive(Clone, Debug, PartialEq, Eq, uniffi::Record)]
pub struct Transfer {
    pub id: i32,
    pub channel_id: i32,
    /// A download (true) or an upload.
    pub inbound: bool,
    pub local_path: String,
    pub remote_name: String,
    pub size: i64,
    pub transferred: i64,
    pub status: TransferStatus,
}

impl From<core::Transfer> for Transfer {
    fn from(t: core::Transfer) -> Self {
        Transfer {
            id: t.id,
            channel_id: t.channel_id,
            inbound: t.inbound,
            local_path: t.local_path,
            remote_name: t.remote_name,
            size: t.size,
            transferred: t.transferred,
            status: match t.status {
                core::TransferStatus::Active => TransferStatus::Active,
                core::TransferStatus::Finished => TransferStatus::Finished,
                core::TransferStatus::Failed => TransferStatus::Failed,
                core::TransferStatus::Cancelled => TransferStatus::Cancelled,
            },
        }
    }
}

/// What a recording is saved as.
#[derive(Clone, Copy, Debug, PartialEq, Eq, uniffi::Enum)]
pub enum RecordingFormat {
    Wave,
    Mp3,
}

/// What I may do on this server.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, uniffi::Record)]
pub struct MyRights {
    pub admin: bool,
    pub create_temporary_channels: bool,
    pub modify_channels: bool,
    pub broadcast: bool,
    pub kick: bool,
    pub ban: bool,
    pub move_users: bool,
    pub upload_files: bool,
    pub download_files: bool,
    pub update_server: bool,
}

impl From<core::MyRights> for MyRights {
    fn from(r: core::MyRights) -> Self {
        MyRights {
            admin: r.admin,
            create_temporary_channels: r.create_temporary_channels,
            modify_channels: r.modify_channels,
            broadcast: r.broadcast,
            kick: r.kick,
            ban: r.ban,
            move_users: r.move_users,
            upload_files: r.upload_files,
            download_files: r.download_files,
            update_server: r.update_server,
        }
    }
}

/// A channel to make, or a channel's new settings.
#[derive(Clone, Debug, Default, PartialEq, Eq, uniffi::Record)]
pub struct ChannelSpec {
    /// Where it goes (ignored when updating).
    pub parent_id: i32,
    pub name: String,
    pub topic: String,
    /// A new password ("" for none); nil keeps the current one.
    pub password: Option<String>,
    /// 0 keeps the current limit (a new channel: its parent's).
    pub max_users: i32,
    pub permanent: bool,
    pub solo_transmit: bool,
    pub classroom: bool,
    pub operator_receive_only: bool,
    pub no_voice_activation: bool,
    pub no_recording: bool,
    pub hidden: bool,
    /// nil keeps each of these as it is.
    pub operator_password: Option<String>,
    pub disk_quota: Option<i64>,
    pub codec: Option<AudioCodec>,
    pub fixed_volume: Option<bool>,
    pub fixed_volume_level: i32,
    pub voice_timeout_ms: Option<i32>,
    pub media_timeout_ms: Option<i32>,
}

impl From<ChannelSpec> for core::ChannelSpec {
    fn from(s: ChannelSpec) -> Self {
        core::ChannelSpec {
            parent_id: s.parent_id,
            name: s.name,
            topic: s.topic,
            password: s.password,
            max_users: s.max_users,
            permanent: s.permanent,
            solo_transmit: s.solo_transmit,
            classroom: s.classroom,
            operator_receive_only: s.operator_receive_only,
            no_voice_activation: s.no_voice_activation,
            no_recording: s.no_recording,
            hidden: s.hidden,
            operator_password: s.operator_password,
            disk_quota: s.disk_quota,
            codec: s.codec.map(Into::into),
            fixed_volume: s.fixed_volume.map(|on| (on, s.fixed_volume_level)),
            voice_timeout_ms: s.voice_timeout_ms,
            media_timeout_ms: s.media_timeout_ms,
        }
    }
}

/// How a ban recognises someone.
#[derive(Clone, Copy, Debug, PartialEq, Eq, uniffi::Enum)]
pub enum BanKind {
    IpAddress,
    Username,
}

/// A ban on the server.
#[derive(Clone, Debug, PartialEq, Eq, uniffi::Record)]
pub struct Ban {
    pub ip_address: String,
    pub username: String,
    pub nickname: String,
    pub time: String,
    /// Who banned them.
    pub owner: String,
    /// A channel ban (its path), or empty for the whole server.
    pub channel_path: String,
    pub by_ip_address: bool,
    pub by_username: bool,
    /// Keep as it is (needed to remove the ban).
    pub raw_types: u32,
}

impl From<core::Ban> for Ban {
    fn from(b: core::Ban) -> Self {
        Ban {
            ip_address: b.ip_address,
            username: b.username,
            nickname: b.nickname,
            time: b.time,
            owner: b.owner,
            channel_path: b.channel_path,
            by_ip_address: b.by_ip_address,
            by_username: b.by_username,
            raw_types: b.raw_types,
        }
    }
}

impl From<Ban> for core::Ban {
    fn from(b: Ban) -> Self {
        core::Ban {
            ip_address: b.ip_address,
            username: b.username,
            nickname: b.nickname,
            time: b.time,
            owner: b.owner,
            channel_path: b.channel_path,
            by_ip_address: b.by_ip_address,
            by_username: b.by_username,
            raw_types: b.raw_types,
        }
    }
}

/// Everything known about a connection, at one moment.
#[derive(Clone, Debug, PartialEq, Eq, uniffi::Record)]
pub struct Snapshot {
    pub state: ConnectionState,
    pub server: ServerInfo,
    pub my_user_id: i32,
    pub my_channel_id: i32,
    pub my_rights: MyRights,
    pub channels: Vec<Channel>,
    pub users: Vec<User>,
    pub files: Vec<RemoteFile>,
    /// Uploads and downloads under way.
    pub transfers: Vec<Transfer>,
    /// The file being recorded to; empty when not.
    pub recording_path: String,
    pub muted_all: bool,
    pub relaying: Option<Relay>,
    pub streaming: Option<MediaStream>,
}

impl From<core::Snapshot> for Snapshot {
    fn from(s: core::Snapshot) -> Self {
        Snapshot {
            state: s.state.map(Into::into).unwrap_or(ConnectionState::Disconnected),
            server: s.server.into(),
            my_user_id: s.my_user_id,
            my_channel_id: s.my_channel_id,
            my_rights: s.my_rights.into(),
            channels: s.channels.into_iter().map(Into::into).collect(),
            users: s.users.into_iter().map(Into::into).collect(),
            files: s.files.into_iter().map(Into::into).collect(),
            transfers: s.transfers.into_iter().map(Into::into).collect(),
            recording_path: s.recording_path,
            muted_all: s.muted_all,
            streaming: s.streaming.map(Into::into),
            relaying: s.relaying.map(|(user_id, stream)| Relay {
                user_id,
                stream: stream.into(),
            }),
        }
    }
}

/// What happened. A UI can rebuild everything from a snapshot plus the
/// events after it.
#[derive(Clone, Debug, PartialEq, Eq, uniffi::Enum)]
pub enum Event {
    ConnectionChanged {
        state: ConnectionState,
    },
    /// Gone, and not retried (why, in words).
    ConnectionFailed {
        message: String,
    },
    ServerUpdated {
        server: ServerInfo,
    },
    ChannelAdded {
        channel: Channel,
    },
    ChannelUpdated {
        channel: Channel,
    },
    ChannelRemoved {
        channel: Channel,
    },
    UserLoggedIn {
        user: User,
    },
    UserLoggedOut {
        user: User,
    },
    UserUpdated {
        user: User,
    },
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
    MessageReceived {
        message: TextMessage,
    },
    /// Voice activation started (true) or stopped sending my voice.
    VoiceActivated {
        sending: bool,
    },
    /// My stream started, moved on (about once a second), paused or ended.
    StreamChanged {
        stream: MediaStream,
    },
    /// A recording started or ended (`error`: why it broke off).
    RecordingChanged {
        path: String,
        active: bool,
        error: Option<String>,
    },
    FileAdded {
        file: RemoteFile,
    },
    FileRemoved {
        file: RemoteFile,
    },
    /// A transfer started, moved on (a few times a second at most), or ended.
    TransferChanged {
        transfer: Transfer,
    },
    /// Kicked: from a channel (`channel_id` > 0) or the server.
    Kicked {
        by_user_id: i32,
        channel_id: i32,
    },
}

impl From<core::Event> for Event {
    fn from(e: core::Event) -> Self {
        use core::Event as E;
        match e {
            E::ConnectionChanged(s) => Self::ConnectionChanged { state: s.into() },
            E::ConnectionFailed(message) => Self::ConnectionFailed { message },
            E::ServerUpdated(s) => Self::ServerUpdated { server: s.into() },
            E::ChannelAdded(c) => Self::ChannelAdded { channel: c.into() },
            E::ChannelUpdated(c) => Self::ChannelUpdated { channel: c.into() },
            E::ChannelRemoved(c) => Self::ChannelRemoved { channel: c.into() },
            E::UserLoggedIn(u) => Self::UserLoggedIn { user: u.into() },
            E::UserLoggedOut(u) => Self::UserLoggedOut { user: u.into() },
            E::UserUpdated(u) => Self::UserUpdated { user: u.into() },
            E::UserJoined { user, channel_id } => Self::UserJoined {
                user: user.into(),
                channel_id,
            },
            E::UserLeft { user, channel_id } => Self::UserLeft {
                user: user.into(),
                channel_id,
            },
            E::TalkingChanged { user_id, talking } => Self::TalkingChanged { user_id, talking },
            E::MessageReceived(m) => Self::MessageReceived { message: m.into() },
            E::VoiceActivated(sending) => Self::VoiceActivated { sending },
            E::StreamChanged(m) => Self::StreamChanged { stream: m.into() },
            E::RecordingChanged { path, active, error } => Self::RecordingChanged { path, active, error },
            E::FileAdded(f) => Self::FileAdded { file: f.into() },
            E::FileRemoved(f) => Self::FileRemoved { file: f.into() },
            E::TransferChanged(t) => Self::TransferChanged { transfer: t.into() },
            E::Kicked { by_user_id, channel_id } => Self::Kicked { by_user_id, channel_id },
        }
    }
}

/// Implemented by the app to receive events. Called on the client's event
/// thread: hand each to the main thread before touching the UI.
#[uniffi::export(with_foreign)]
pub trait TtListener: Send + Sync {
    fn on_event(&self, event: Event);
}

/// One server connection. Several can run at once (use
/// [`AudioDevices::Shared`] for each).
#[derive(uniffi::Object)]
pub struct TtClient {
    pub(crate) inner: core::Client,
}

impl std::fmt::Debug for TtClient {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("TtClient").finish_non_exhaustive()
    }
}

#[uniffi::export]
impl TtClient {
    #[uniffi::constructor]
    pub fn new(listener: Arc<dyn TtListener>) -> Arc<Self> {
        Arc::new(TtClient {
            inner: core::Client::new(move |e: core::Event| listener.on_event(e.into())),
        })
    }

    /// Connects and logs in; returns once logged in (or why not).
    pub fn connect(&self, options: ConnectOptions) -> Result<()> {
        Ok(self.inner.connect(options.into())?)
    }

    pub fn disconnect(&self) -> Result<()> {
        Ok(self.inner.disconnect()?)
    }

    pub fn join_channel(&self, channel_id: i32, password: String) -> Result<()> {
        Ok(self.inner.join_channel(channel_id, &password)?)
    }

    pub fn join_channel_path(&self, path: String, password: String) -> Result<()> {
        Ok(self.inner.join_channel_path(&path, &password)?)
    }

    pub fn leave_channel(&self) -> Result<()> {
        Ok(self.inner.leave_channel()?)
    }

    /// Sends a message of any length (long ones go in parts).
    pub fn send_message(&self, target: MessageTarget, text: String) -> Result<()> {
        Ok(self.inner.send_message(target.into(), &text)?)
    }

    pub fn set_status(&self, mode: StatusMode, message: String) -> Result<()> {
        Ok(self.inner.set_status(mode.into(), &message)?)
    }

    pub fn set_nickname(&self, nickname: String) -> Result<()> {
        Ok(self.inner.set_nickname(&nickname)?)
    }

    pub fn init_audio(&self, devices: AudioDevices) -> Result<()> {
        Ok(self.inner.init_audio(devices.into())?)
    }

    /// Push to talk: sending my voice (true) or not.
    pub fn set_transmitting(&self, on: bool) -> Result<()> {
        Ok(self.inner.set_transmitting(on)?)
    }

    /// Voice activation: on or off, the level that starts it (0–100) and
    /// how long it keeps sending after the sound stops.
    pub fn set_voice_activation(&self, on: bool, level: i32, stop_delay_ms: i32) -> Result<()> {
        Ok(self.inner.set_voice_activation(on, level, stop_delay_ms)?)
    }

    /// Someone's volume in percent (100 normal, up to 400).
    pub fn set_user_volume(&self, user_id: i32, percent: i32) -> Result<()> {
        Ok(self.inner.set_user_volume(user_id, percent)?)
    }

    pub fn set_user_muted(&self, user_id: i32, muted: bool) -> Result<()> {
        Ok(self.inner.set_user_muted(user_id, muted)?)
    }

    /// The microphone's level now, 0–100.
    pub fn input_level(&self) -> i32 {
        self.inner.input_level()
    }

    pub fn snapshot(&self) -> Snapshot {
        self.inner.snapshot().into()
    }

    /// Uploads a file from this device to a channel. Returns once the server
    /// accepts; progress arrives as `TransferChanged` events.
    pub fn upload_file(&self, channel_id: i32, local_path: String) -> Result<()> {
        Ok(self.inner.upload_file(channel_id, &local_path)?)
    }

    /// Downloads a channel's file to `local_path`.
    pub fn download_file(&self, channel_id: i32, file_id: i32, local_path: String) -> Result<()> {
        Ok(self.inner.download_file(channel_id, file_id, &local_path)?)
    }

    pub fn delete_file(&self, channel_id: i32, file_id: i32) -> Result<()> {
        Ok(self.inner.delete_file(channel_id, file_id)?)
    }

    pub fn cancel_transfer(&self, transfer_id: i32) -> Result<()> {
        Ok(self.inner.cancel_transfer(transfer_id)?)
    }

    /// Kicks someone from their channel, or (`from_channel` false) the server.
    pub fn kick_user(&self, user_id: i32, from_channel: bool) -> Result<()> {
        Ok(self.inner.kick_user(user_id, from_channel)?)
    }

    /// Bans someone from the server (kick them too).
    pub fn ban_user(&self, user_id: i32, kind: BanKind) -> Result<()> {
        let kind = match kind {
            BanKind::IpAddress => core::BanKind::IpAddress,
            BanKind::Username => core::BanKind::Username,
        };
        Ok(self.inner.ban_user(user_id, kind)?)
    }

    pub fn list_bans(&self) -> Result<Vec<Ban>> {
        Ok(self.inner.list_bans()?.into_iter().map(Into::into).collect())
    }

    pub fn unban(&self, ban: Ban) -> Result<()> {
        Ok(self.inner.unban(&ban.into())?)
    }

    pub fn move_user(&self, user_id: i32, channel_id: i32) -> Result<()> {
        Ok(self.inner.move_user(user_id, channel_id)?)
    }

    /// Makes a channel (needs the right to modify channels).
    pub fn make_channel(&self, spec: ChannelSpec) -> Result<()> {
        Ok(self.inner.make_channel(&spec.into())?)
    }

    /// Makes a temporary channel and joins it.
    pub fn join_new_channel(&self, spec: ChannelSpec) -> Result<()> {
        Ok(self.inner.join_new_channel(&spec.into())?)
    }

    pub fn update_channel(&self, channel_id: i32, spec: ChannelSpec) -> Result<()> {
        Ok(self.inner.update_channel(channel_id, &spec.into())?)
    }

    pub fn remove_channel(&self, channel_id: i32) -> Result<()> {
        Ok(self.inner.remove_channel(channel_id)?)
    }

    /// Changes the server's name and message of the day.
    pub fn update_server(&self, name: String, motd: String) -> Result<()> {
        Ok(self.inner.update_server(&name, &motd)?)
    }

    /// Records my channel's voices to `path` until stopped or I leave.
    pub fn start_recording(&self, path: String, format: RecordingFormat) -> Result<()> {
        let f = match format {
            RecordingFormat::Wave => core::RecordingFormat::Wave,
            RecordingFormat::Mp3 => core::RecordingFormat::Mp3,
        };
        Ok(self.inner.start_recording(&path, f)?)
    }

    pub fn stop_recording(&self) -> Result<()> {
        Ok(self.inner.stop_recording()?)
    }

    pub fn set_subscription(&self, user_id: i32, what: Subscription, on: bool) -> Result<()> {
        Ok(self.inner.set_subscription(user_id, what.into(), on)?)
    }

    pub fn set_hear_myself(&self, on: bool) -> Result<()> {
        Ok(self.inner.set_hear_myself(on)?)
    }

    pub fn set_user_media_volume(&self, user_id: i32, percent: i32) -> Result<()> {
        Ok(self.inner.set_user_media_volume(user_id, percent)?)
    }

    pub fn set_user_media_muted(&self, user_id: i32, muted: bool) -> Result<()> {
        Ok(self.inner.set_user_media_muted(user_id, muted)?)
    }

    pub fn set_user_stereo(&self, user_id: i32, stream: AudioStream, left: bool, right: bool) -> Result<()> {
        Ok(self.inner.set_user_stereo(user_id, stream.into(), left, right)?)
    }

    pub fn set_mute_all(&self, on: bool) -> Result<()> {
        Ok(self.inner.set_mute_all(on)?)
    }

    pub fn set_operator(&self, user_id: i32, channel_id: i32, password: String, on: bool) -> Result<()> {
        Ok(self.inner.set_operator(user_id, channel_id, &password, on)?)
    }

    pub fn set_transmit_allowed(
        &self,
        channel_id: i32,
        user_id: i32,
        stream: TransmitStream,
        allowed: bool,
    ) -> Result<()> {
        Ok(self
            .inner
            .set_transmit_allowed(channel_id, user_id, stream.into(), allowed)?)
    }

    pub fn ban_from_channel(&self, user_id: i32, kind: BanKind) -> Result<()> {
        let kind = match kind {
            BanKind::IpAddress => core::BanKind::IpAddress,
            BanKind::Username => core::BanKind::Username,
        };
        Ok(self.inner.ban_from_channel(user_id, kind)?)
    }

    pub fn list_channel_bans(&self, channel_id: i32) -> Result<Vec<Ban>> {
        Ok(self
            .inner
            .list_channel_bans(channel_id)?
            .into_iter()
            .map(Into::into)
            .collect())
    }

    pub fn set_gender(&self, gender: Gender) -> Result<()> {
        Ok(self.inner.set_gender(gender.into())?)
    }

    pub fn user_statistics(&self, user_id: i32) -> Result<UserStatistics> {
        let s = self.inner.user_statistics(user_id)?;
        Ok(UserStatistics {
            voice_packets_received: s.voice_packets_received,
            voice_packets_lost: s.voice_packets_lost,
            media_audio_packets_received: s.media_audio_packets_received,
            media_audio_packets_lost: s.media_audio_packets_lost,
            video_packets_received: s.video_packets_received,
            video_frames_received: s.video_frames_received,
            video_frames_lost: s.video_frames_lost,
        })
    }

    /// Relays someone's audio into my channel; nil stops.
    pub fn set_relay(&self, relay: Option<Relay>) -> Result<()> {
        Ok(self.inner.set_relay(relay.map(|r| (r.user_id, r.stream.into())))?)
    }

    /// Joins by path, hidden channels included.
    pub fn join_hidden_channel(&self, path: String, password: String) -> Result<()> {
        Ok(self.inner.join_hidden_channel(&path, &password)?)
    }

    pub fn stream_media_file(&self, path: String, offset_ms: u32, paused: bool, looping: bool) -> Result<()> {
        Ok(self.inner.stream_media_file(&path, offset_ms, paused, looping)?)
    }

    /// Pauses, resumes, moves (`offset_ms`) the stream.
    pub fn update_stream(&self, offset_ms: Option<u32>, paused: bool) -> Result<()> {
        Ok(self.inner.update_stream(offset_ms, paused)?)
    }

    /// Whether I hear the files I stream myself (the SDK doesn't play my
    /// own stream back; this plays the file here too, in step).
    pub fn set_hear_own_stream(&self, on: bool) -> Result<()> {
        Ok(self.inner.set_hear_own_stream(on)?)
    }

    pub fn stop_stream(&self) -> Result<()> {
        Ok(self.inner.stop_stream()?)
    }

    /// A channel's path ("/Lobby/Music/"), "/" for the root.
    pub fn channel_path(&self, channel_id: i32) -> String {
        self.inner.snapshot().channel_path(channel_id)
    }
}

/// Turns off the SDK's trial mode with a BearWare license (before the
/// first client); whether it was accepted.
#[uniffi::export]
pub fn set_license(name: String, key: String) -> bool {
    core::set_license(&name, &key)
}

/// The SDK's version ("5.23.0.5209").
#[uniffi::export]
pub fn sdk_version() -> String {
    core::sdk_version()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn errors_keep_their_words() {
        let e: TtError = core::Error::Server {
            code: 2001,
            message: "The username or password is wrong.".into(),
        }
        .into();
        assert_eq!(e.to_string(), "The username or password is wrong.");
        assert!(matches!(e, TtError::Server { code: 2001, .. }));
    }

    #[test]
    fn no_join_channel_when_the_path_is_empty() {
        let o = ConnectOptions {
            host: "h".into(),
            tcp_port: 10333,
            udp_port: 10333,
            encrypted: false,
            nickname: String::new(),
            username: String::new(),
            password: String::new(),
            client_name: "TeamTalk NG".into(),
            join_channel_path: String::new(),
            join_channel_password: String::new(),
            reconnect: true,
        };
        assert_eq!(core::ConnectOptions::from(o).join_channel, None);
    }
}
