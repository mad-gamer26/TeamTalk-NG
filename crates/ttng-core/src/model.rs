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
    /// Classroom channels: who may send what (user 0: everyone).
    pub transmit: Vec<TransmitPermission>,
    /// Shown to admins only; empty otherwise.
    pub operator_password: String,
    /// Bytes its files may take (0: none allowed, unless the server's own).
    pub disk_quota: i64,
    pub codec: AudioCodec,
    /// Everyone heard at one volume (the channel's gain), not their own.
    pub fixed_volume: bool,
    /// The fixed volume, in percent (100 normal).
    pub fixed_volume_level: i32,
    /// The longest one may talk, or stream a file, without stopping (ms; 0: no limit).
    pub voice_timeout_ms: i32,
    pub media_timeout_ms: i32,
}

/// Which audio codec a channel uses.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum CodecKind {
    /// No audio (text only).
    #[default]
    NoAudio,
    Speex,
    SpeexVbr,
    Opus,
}

/// A channel's audio codec and its settings (the ones the codec has).
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct AudioCodec {
    pub kind: CodecKind,
    /// Opus: 8000–48000 Hz. Speex: from the band (8, 16 or 32 kHz).
    pub sample_rate: i32,
    /// 1 or 2.
    pub channels: i32,
    /// Bits per second (Opus, Speex VBR).
    pub bitrate: i32,
    /// Opus: variable bitrate.
    pub vbr: bool,
    /// Don't send silence.
    pub dtx: bool,
    /// Opus: tuned for music rather than voice.
    pub music: bool,
    /// Opus frame size in ms (2 to 120).
    pub frame_size_ms: i32,
    /// How often packets are sent, in ms.
    pub transmit_interval_ms: i32,
    /// Speex: 0–10.
    pub quality: i32,
}

impl AudioCodec {
    /// Opus as the desktop client makes new channels: 48 kHz mono voice,
    /// 64 kbit/s, 40 ms.
    pub fn opus_default() -> AudioCodec {
        AudioCodec {
            kind: CodecKind::Opus,
            sample_rate: 48000,
            channels: 1,
            bitrate: 64000,
            vbr: true,
            dtx: false,
            music: false,
            frame_size_ms: 20,
            transmit_interval_ms: 40,
            quality: 0,
        }
    }

    pub(crate) fn from_sys(c: &sys::AudioCodec) -> AudioCodec {
        match c.nCodec {
            sys::Codec_OPUS_CODEC => {
                // SAFETY: nCodec says the union holds this member.
                let o = unsafe { c.__bindgen_anon_1.opus };
                AudioCodec {
                    kind: CodecKind::Opus,
                    sample_rate: o.nSampleRate,
                    channels: o.nChannels,
                    bitrate: o.nBitRate,
                    vbr: o.bVBR != 0,
                    dtx: o.bDTX != 0,
                    music: o.nApplication == sys::OPUS_APPLICATION_AUDIO as i32,
                    frame_size_ms: o.nFrameSizeMSec,
                    transmit_interval_ms: o.nTxIntervalMSec,
                    quality: o.nComplexity,
                }
            }
            sys::Codec_SPEEX_CODEC => {
                // SAFETY: nCodec says the union holds this member.
                let o = unsafe { c.__bindgen_anon_1.speex };
                AudioCodec {
                    kind: CodecKind::Speex,
                    sample_rate: [8000, 16000, 32000][o.nBandmode.clamp(0, 2) as usize],
                    channels: if o.bStereoPlayback != 0 { 2 } else { 1 },
                    quality: o.nQuality,
                    transmit_interval_ms: o.nTxIntervalMSec,
                    ..Default::default()
                }
            }
            sys::Codec_SPEEX_VBR_CODEC => {
                // SAFETY: nCodec says the union holds this member.
                let o = unsafe { c.__bindgen_anon_1.speex_vbr };
                AudioCodec {
                    kind: CodecKind::SpeexVbr,
                    sample_rate: [8000, 16000, 32000][o.nBandmode.clamp(0, 2) as usize],
                    channels: if o.bStereoPlayback != 0 { 2 } else { 1 },
                    quality: o.nQuality,
                    bitrate: o.nBitRate,
                    dtx: o.bDTX != 0,
                    transmit_interval_ms: o.nTxIntervalMSec,
                    ..Default::default()
                }
            }
            _ => AudioCodec::default(),
        }
    }

    /// Writes it into the SDK's struct (Opus, or no audio; other kinds stay
    /// as they are).
    pub(crate) fn write(&self, c: &mut sys::AudioCodec) {
        match self.kind {
            CodecKind::Opus => {
                c.nCodec = sys::Codec_OPUS_CODEC;
                c.__bindgen_anon_1.opus = sys::OpusCodec {
                    nSampleRate: self.sample_rate,
                    nChannels: self.channels.clamp(1, 2),
                    nApplication: if self.music {
                        sys::OPUS_APPLICATION_AUDIO as i32
                    } else {
                        sys::OPUS_APPLICATION_VOIP as i32
                    },
                    nComplexity: if self.quality > 0 { self.quality.min(10) } else { 10 },
                    bFEC: 1,
                    bDTX: self.dtx as sys::TTBOOL,
                    nBitRate: self
                        .bitrate
                        .clamp(sys::OPUS_MIN_BITRATE as i32, sys::OPUS_MAX_BITRATE as i32),
                    bVBR: self.vbr as sys::TTBOOL,
                    bVBRConstraint: 0,
                    nTxIntervalMSec: self.transmit_interval_ms,
                    nFrameSizeMSec: self.frame_size_ms,
                };
            }
            CodecKind::NoAudio => c.nCodec = sys::Codec_NO_CODEC,
            CodecKind::Speex | CodecKind::SpeexVbr => {}
        }
    }
}

impl From<&sys::Channel> for Channel {
    fn from(c: &sys::Channel) -> Self {
        let t = c.uChannelType;
        let has = |flag: sys::ChannelType| t & flag != 0;
        let gain = c.audiocfg.nGainLevel;
        Channel {
            operator_password: from_tt(&c.szOpPassword),
            disk_quota: c.nDiskQuota,
            codec: AudioCodec::from_sys(&c.audiocodec),
            fixed_volume: c.audiocfg.bEnableAGC != 0,
            fixed_volume_level: gain * 100 / sys::SoundLevel_SOUND_GAIN_DEFAULT as i32,
            voice_timeout_ms: c.nTimeOutTimerVoiceMSec,
            media_timeout_ms: c.nTimeOutTimerMediaFileMSec,
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
            transmit: c
                .transmitUsers
                .iter()
                .filter(|e| e[0] != 0)
                .map(|e| TransmitPermission {
                    user_id: if e[0] == sys::TT_TRANSMITUSERS_FREEFORALL as i32 {
                        0
                    } else {
                        e[0]
                    },
                    streams: e[1] as u32,
                })
                .collect(),
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
    /// The client's version ("5.23.0").
    pub version: String,
    pub gender: Gender,
    /// Sending camera video, sharing a desktop, streaming a media file
    /// (their status says so).
    pub sending_video: bool,
    pub sharing_desktop: bool,
    pub streaming_media: bool,
    /// Their media file audio is playing for me right now.
    pub playing_media: bool,
    /// What I receive from them, and what they receive from me.
    pub my_subscriptions: Subscriptions,
    pub their_subscriptions: Subscriptions,
    /// Their voice and media files, for me only.
    pub voice_muted: bool,
    pub media_muted: bool,
    /// In percent (100 as sent, up to 400).
    pub voice_volume: i32,
    pub media_volume: i32,
    /// Which of my speakers play them (both normally).
    pub voice_left: bool,
    pub voice_right: bool,
    pub media_left: bool,
    pub media_right: bool,
    /// An operator of the channel they're in.
    pub operator: bool,
    /// Their status number as the server has it (mode and flags).
    pub status_raw: i32,
}

/// Gender, as TeamTalk keeps it in the status.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Gender {
    Male,
    Female,
    Neutral,
}

impl Gender {
    pub(crate) fn from_raw(mode: i32) -> Self {
        if mode & 0x100 != 0 {
            Gender::Female
        } else if mode & 0x1000 != 0 {
            Gender::Neutral
        } else {
            Gender::Male
        }
    }

    pub(crate) fn bits(self) -> i32 {
        match self {
            Gender::Male => 0,
            Gender::Female => 0x100,
            Gender::Neutral => 0x1000,
        }
    }
}

/// One kind of thing to receive from someone (TeamTalk's subscriptions).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Subscription {
    UserMessages,
    ChannelMessages,
    BroadcastMessages,
    Voice,
    Video,
    Desktop,
    DesktopAccess,
    MediaFile,
    /// Theirs, even in other channels or to others (admins).
    InterceptUserMessages,
    InterceptChannelMessages,
    InterceptVoice,
    InterceptVideo,
    InterceptDesktop,
    InterceptMediaFile,
}

impl Subscription {
    pub const ALL: [Subscription; 14] = [
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

    pub(crate) fn bit(self) -> u32 {
        match self {
            Subscription::UserMessages => sys::Subscription_SUBSCRIBE_USER_MSG,
            Subscription::ChannelMessages => sys::Subscription_SUBSCRIBE_CHANNEL_MSG,
            Subscription::BroadcastMessages => sys::Subscription_SUBSCRIBE_BROADCAST_MSG,
            Subscription::Voice => sys::Subscription_SUBSCRIBE_VOICE,
            Subscription::Video => sys::Subscription_SUBSCRIBE_VIDEOCAPTURE,
            Subscription::Desktop => sys::Subscription_SUBSCRIBE_DESKTOP,
            Subscription::DesktopAccess => sys::Subscription_SUBSCRIBE_DESKTOPINPUT,
            Subscription::MediaFile => sys::Subscription_SUBSCRIBE_MEDIAFILE,
            Subscription::InterceptUserMessages => sys::Subscription_SUBSCRIBE_INTERCEPT_USER_MSG,
            Subscription::InterceptChannelMessages => sys::Subscription_SUBSCRIBE_INTERCEPT_CHANNEL_MSG,
            Subscription::InterceptVoice => sys::Subscription_SUBSCRIBE_INTERCEPT_VOICE,
            Subscription::InterceptVideo => sys::Subscription_SUBSCRIBE_INTERCEPT_VIDEOCAPTURE,
            Subscription::InterceptDesktop => sys::Subscription_SUBSCRIBE_INTERCEPT_DESKTOP,
            Subscription::InterceptMediaFile => sys::Subscription_SUBSCRIBE_INTERCEPT_MEDIAFILE,
        }
    }
}

/// A set of subscriptions.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Subscriptions(pub u32);

impl Subscriptions {
    pub fn has(self, s: Subscription) -> bool {
        self.0 & s.bit() != 0
    }
}

/// How someone's audio arrives (for "user information").
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct UserStatistics {
    pub voice_packets_received: i64,
    pub voice_packets_lost: i64,
    pub media_audio_packets_received: i64,
    pub media_audio_packets_lost: i64,
    pub video_packets_received: i64,
    pub video_frames_received: i64,
    pub video_frames_lost: i64,
}

/// A stream someone may send in a classroom channel.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum TransmitStream {
    Voice,
    Video,
    Desktop,
    MediaFile,
    ChannelMessages,
}

impl TransmitStream {
    pub const ALL: [TransmitStream; 5] = [
        TransmitStream::Voice,
        TransmitStream::Video,
        TransmitStream::Desktop,
        TransmitStream::MediaFile,
        TransmitStream::ChannelMessages,
    ];

    pub(crate) fn bits(self) -> u32 {
        match self {
            TransmitStream::Voice => sys::StreamType_STREAMTYPE_VOICE,
            TransmitStream::Video => sys::StreamType_STREAMTYPE_VIDEOCAPTURE,
            TransmitStream::Desktop => sys::StreamType_STREAMTYPE_DESKTOP,
            TransmitStream::MediaFile => sys::StreamType_STREAMTYPE_MEDIAFILE,
            TransmitStream::ChannelMessages => sys::StreamType_STREAMTYPE_CHANNELMSG,
        }
    }
}

/// Who may send what in a classroom channel. `user_id` 0 means everyone.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct TransmitPermission {
    pub user_id: i32,
    pub streams: u32,
}

impl TransmitPermission {
    pub fn allows(&self, s: TransmitStream) -> bool {
        self.streams & s.bits() == s.bits()
    }
}

/// Someone's audio stream, to relay into my channel.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum AudioStream {
    Voice,
    MediaFile,
}

impl From<&sys::User> for User {
    fn from(u: &sys::User) -> Self {
        let state = u.uUserState;
        let mode = u.nStatusMode;
        let percent = |v: i32| {
            (v * 100 + sys::SoundLevel_SOUND_VOLUME_DEFAULT as i32 / 2) / sys::SoundLevel_SOUND_VOLUME_DEFAULT as i32
        };
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
            talking: state & sys::UserState_USERSTATE_VOICE != 0,
            version: format!(
                "{}.{}.{}",
                (u.uVersion >> 16) & 0xff,
                (u.uVersion >> 8) & 0xff,
                u.uVersion & 0xff
            ),
            gender: Gender::from_raw(mode),
            sending_video: mode & 0x200 != 0,
            sharing_desktop: mode & 0x400 != 0,
            streaming_media: mode & 0x800 != 0,
            playing_media: state & sys::UserState_USERSTATE_MEDIAFILE_AUDIO != 0,
            my_subscriptions: Subscriptions(u.uLocalSubscriptions),
            their_subscriptions: Subscriptions(u.uPeerSubscriptions),
            voice_muted: state & sys::UserState_USERSTATE_MUTE_VOICE != 0,
            media_muted: state & sys::UserState_USERSTATE_MUTE_MEDIAFILE != 0,
            voice_volume: percent(u.nVolumeVoice),
            media_volume: percent(u.nVolumeMediaFile),
            voice_left: u.stereoPlaybackVoice[0] != 0,
            voice_right: u.stereoPlaybackVoice[1] != 0,
            media_left: u.stereoPlaybackMediaFile[0] != 0,
            media_right: u.stereoPlaybackMediaFile[1] != 0,
            operator: false,
            status_raw: mode,
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

/// A file in a channel's file area.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RemoteFile {
    pub id: i32,
    pub channel_id: i32,
    pub name: String,
    /// In bytes.
    pub size: i64,
    /// Who uploaded it (their username).
    pub uploader: String,
    /// When, as the server writes it ("2026/11/14 09:30").
    pub uploaded: String,
}

impl From<&sys::RemoteFile> for RemoteFile {
    fn from(f: &sys::RemoteFile) -> Self {
        RemoteFile {
            id: f.nFileID,
            channel_id: f.nChannelID,
            name: from_tt(&f.szFileName),
            size: f.nFileSize,
            uploader: from_tt(&f.szUsername),
            uploaded: from_tt(&f.szUploadTime),
        }
    }
}

/// Where a file transfer stands.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum TransferStatus {
    Active,
    Finished,
    /// It broke off (the connection, the disk, or the server).
    Failed,
    Cancelled,
}

/// An upload or a download.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Transfer {
    pub id: i32,
    pub channel_id: i32,
    /// A download (true) or an upload.
    pub inbound: bool,
    /// The file on this device.
    pub local_path: String,
    /// Its name on the server.
    pub remote_name: String,
    pub size: i64,
    pub transferred: i64,
    pub status: TransferStatus,
}

impl From<&sys::FileTransfer> for Transfer {
    fn from(t: &sys::FileTransfer) -> Self {
        Transfer {
            id: t.nTransferID,
            channel_id: t.nChannelID,
            inbound: t.bInbound != 0,
            local_path: from_tt(&t.szLocalFilePath),
            remote_name: from_tt(&t.szRemoteFileName),
            size: t.nFileSize,
            transferred: t.nTransferred,
            status: match t.nStatus {
                sys::FileTransferStatus_FILETRANSFER_ACTIVE => TransferStatus::Active,
                sys::FileTransferStatus_FILETRANSFER_FINISHED => TransferStatus::Finished,
                sys::FileTransferStatus_FILETRANSFER_ERROR => TransferStatus::Failed,
                _ => TransferStatus::Cancelled,
            },
        }
    }
}

/// What a recording is saved as.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum RecordingFormat {
    /// Uncompressed (large, any app plays it).
    Wave,
    /// MP3 at 128 kbit/s.
    Mp3,
}

/// What I may do on this server (from my account).
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
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

impl MyRights {
    pub(crate) fn from_raw(rights: u32, admin: bool) -> Self {
        let has = |r: sys::UserRight| admin || rights & r != 0;
        MyRights {
            admin,
            create_temporary_channels: has(sys::UserRight_USERRIGHT_CREATE_TEMPORARY_CHANNEL),
            modify_channels: has(sys::UserRight_USERRIGHT_MODIFY_CHANNELS),
            broadcast: has(sys::UserRight_USERRIGHT_TEXTMESSAGE_BROADCAST),
            kick: has(sys::UserRight_USERRIGHT_KICK_USERS),
            ban: has(sys::UserRight_USERRIGHT_BAN_USERS),
            move_users: has(sys::UserRight_USERRIGHT_MOVE_USERS),
            upload_files: has(sys::UserRight_USERRIGHT_UPLOAD_FILES),
            download_files: has(sys::UserRight_USERRIGHT_DOWNLOAD_FILES),
            update_server: has(sys::UserRight_USERRIGHT_UPDATE_SERVERPROPERTIES),
        }
    }
}

/// A channel to make, or a channel's new settings.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct ChannelSpec {
    /// Where it goes (ignored when updating).
    pub parent_id: i32,
    pub name: String,
    pub topic: String,
    /// A new password ("" for none); `None` keeps the current one.
    pub password: Option<String>,
    /// 0 keeps the current limit (a new channel: its parent's).
    pub max_users: i32,
    pub permanent: bool,
    pub solo_transmit: bool,
    pub classroom: bool,
    /// Only operators see and hear the others.
    pub operator_receive_only: bool,
    pub no_voice_activation: bool,
    pub no_recording: bool,
    pub hidden: bool,
    /// A new operator password ("" for none); `None` keeps it.
    pub operator_password: Option<String>,
    /// Bytes its files may take; `None` keeps it.
    pub disk_quota: Option<i64>,
    /// A new codec (Opus or no audio); `None` keeps it (a new channel: the
    /// parent's).
    pub codec: Option<AudioCodec>,
    /// Fixed volume on or off and its level in percent; `None` keeps it.
    pub fixed_volume: Option<(bool, i32)>,
    /// The longest one may talk, or stream, without stopping (ms, 0: no
    /// limit); `None` keeps it.
    pub voice_timeout_ms: Option<i32>,
    pub media_timeout_ms: Option<i32>,
}

/// A media file's properties.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct MediaFileInfo {
    pub duration_ms: u32,
    /// 0 when it has no audio.
    pub sample_rate: i32,
    pub channels: i32,
    /// Its video's size, when it has some.
    pub video_width: i32,
    pub video_height: i32,
}

/// Where streaming a file to the channel stands.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum StreamStatus {
    Started,
    Playing,
    Paused,
    Finished,
    Failed,
    Stopped,
}

/// The file I'm streaming to my channel.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct MediaStream {
    pub path: String,
    pub status: StreamStatus,
    pub elapsed_ms: u32,
    pub duration_ms: u32,
    /// Starts again when it ends.
    pub looping: bool,
}

/// How a ban recognises someone.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum BanKind {
    /// Their IP address.
    IpAddress,
    /// Their account.
    Username,
}

/// A ban on the server.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Ban {
    pub ip_address: String,
    pub username: String,
    pub nickname: String,
    /// When, as the server writes it.
    pub time: String,
    /// Who banned them.
    pub owner: String,
    /// A channel ban (its path), or empty for the whole server.
    pub channel_path: String,
    pub by_ip_address: bool,
    pub by_username: bool,
    /// The ban's types as the server gave them (needed to remove it).
    pub raw_types: u32,
}

impl From<&sys::BannedUser> for Ban {
    fn from(b: &sys::BannedUser) -> Self {
        Ban {
            ip_address: from_tt(&b.szIPAddress),
            username: from_tt(&b.szUsername),
            nickname: from_tt(&b.szNickname),
            time: from_tt(&b.szBanTime),
            owner: from_tt(&b.szOwner),
            channel_path: from_tt(&b.szChannelPath),
            by_ip_address: b.uBanTypes & sys::BanType_BANTYPE_IPADDR != 0,
            by_username: b.uBanTypes & sys::BanType_BANTYPE_USERNAME != 0,
            raw_types: b.uBanTypes,
        }
    }
}

/// Everything the core knows about a connection, at one moment.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Snapshot {
    pub state: Option<ConnectionState>,
    pub server: ServerInfo,
    pub my_user_id: i32,
    pub my_channel_id: i32,
    pub my_rights: MyRights,
    pub channels: Vec<Channel>,
    pub users: Vec<User>,
    /// Every channel's files (that I may see).
    pub files: Vec<RemoteFile>,
    /// Uploads and downloads under way.
    pub transfers: Vec<Transfer>,
    /// The file being recorded to (my channel's voices); empty when not.
    pub recording_path: String,
    /// Everything muted for me.
    pub muted_all: bool,
    /// Whose audio I relay into my channel, and which stream.
    pub relaying: Option<(i32, AudioStream)>,
    /// The file I'm streaming to my channel.
    pub streaming: Option<MediaStream>,
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

    /// A channel's files, by name.
    pub fn files_in(&self, channel_id: i32) -> Vec<&RemoteFile> {
        let mut f: Vec<&RemoteFile> = self.files.iter().filter(|f| f.channel_id == channel_id).collect();
        f.sort_by_key(|f| f.name.to_lowercase());
        f
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
    /// Streaming a file to my channel started, moved on (about once a
    /// second), paused or ended.
    StreamChanged(MediaStream),
    /// A recording started (`path` set) or ended (with why, if it broke).
    RecordingChanged {
        path: String,
        active: bool,
        error: Option<String>,
    },
    FileAdded(RemoteFile),
    FileRemoved(RemoteFile),
    /// A transfer started, moved on (a few times a second at most), or
    /// ended (its status says how).
    TransferChanged(Transfer),
    /// I was kicked: from a channel (`channel_id` > 0) or the server.
    Kicked {
        by_user_id: i32,
        channel_id: i32,
    },
}
