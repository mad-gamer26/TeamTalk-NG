//! Server administration for the apps (the desktop's Server menu).

use ttng_core as core;

use crate::{Result, TtClient};

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum UserRight {
    MultiLogin,
    ViewAllUsers,
    ViewHiddenChannels,
    CreateTemporaryChannels,
    ModifyChannels,
    Broadcast,
    KickUsers,
    BanUsers,
    MoveUsers,
    OperatorEnable,
    UploadFiles,
    DownloadFiles,
    UpdateServer,
    TransmitVoice,
    TransmitVideo,
    TransmitDesktop,
    TransmitDesktopInput,
    TransmitMediaFileAudio,
    TransmitMediaFileVideo,
    RecordVoice,
    TextMessageUser,
    TextMessageChannel,
    LockedNickname,
    LockedStatus,
}

macro_rules! rights {
    ($($n:ident),*) => {
        impl From<core::UserRight> for UserRight {
            fn from(r: core::UserRight) -> Self {
                match r { $(core::UserRight::$n => UserRight::$n),* }
            }
        }
        impl From<UserRight> for core::UserRight {
            fn from(r: UserRight) -> Self {
                match r { $(UserRight::$n => core::UserRight::$n),* }
            }
        }
    };
}
rights!(
    MultiLogin,
    ViewAllUsers,
    ViewHiddenChannels,
    CreateTemporaryChannels,
    ModifyChannels,
    Broadcast,
    KickUsers,
    BanUsers,
    MoveUsers,
    OperatorEnable,
    UploadFiles,
    DownloadFiles,
    UpdateServer,
    TransmitVoice,
    TransmitVideo,
    TransmitDesktop,
    TransmitDesktopInput,
    TransmitMediaFileAudio,
    TransmitMediaFileVideo,
    RecordVoice,
    TextMessageUser,
    TextMessageChannel,
    LockedNickname,
    LockedStatus
);

/// Every right, in the order to show them.
#[uniffi::export]
pub fn all_user_rights() -> Vec<UserRight> {
    core::UserRight::ALL.into_iter().map(Into::into).collect()
}

/// The rights a new account gets (as on the desktop).
#[uniffi::export]
pub fn default_user_rights() -> Vec<UserRight> {
    core::UserRight::defaults().into_iter().map(Into::into).collect()
}

#[derive(Clone, Debug, Default, PartialEq, Eq, uniffi::Record)]
pub struct UserAccount {
    pub username: String,
    pub password: String,
    pub admin: bool,
    pub rights: Vec<UserRight>,
    pub note: String,
    pub initial_channel: String,
    pub auto_operator_channels: Vec<i32>,
    pub bitrate_limit: i32,
    pub commands_limit: i32,
    pub commands_interval_ms: i32,
    pub last_modified: String,
    pub last_login: String,
}

impl From<core::UserAccount> for UserAccount {
    fn from(a: core::UserAccount) -> Self {
        UserAccount {
            username: a.username,
            password: a.password,
            admin: a.admin,
            rights: a.rights.into_iter().map(Into::into).collect(),
            note: a.note,
            initial_channel: a.initial_channel,
            auto_operator_channels: a.auto_operator_channels,
            bitrate_limit: a.bitrate_limit,
            commands_limit: a.commands_limit,
            commands_interval_ms: a.commands_interval_ms,
            last_modified: a.last_modified,
            last_login: a.last_login,
        }
    }
}

impl From<UserAccount> for core::UserAccount {
    fn from(a: UserAccount) -> Self {
        core::UserAccount {
            username: a.username,
            password: a.password,
            admin: a.admin,
            rights: a.rights.into_iter().map(Into::into).collect(),
            note: a.note,
            initial_channel: a.initial_channel,
            auto_operator_channels: a.auto_operator_channels,
            bitrate_limit: a.bitrate_limit,
            commands_limit: a.commands_limit,
            commands_interval_ms: a.commands_interval_ms,
            last_modified: a.last_modified,
            last_login: a.last_login,
        }
    }
}

#[derive(Clone, Debug, Default, PartialEq, Eq, uniffi::Record)]
pub struct ServerSettings {
    pub name: String,
    pub motd: String,
    pub max_users: i32,
    pub max_login_attempts: i32,
    pub max_logins_per_address: i32,
    pub login_delay_ms: i32,
    pub voice_limit: i32,
    pub video_limit: i32,
    pub media_file_limit: i32,
    pub desktop_limit: i32,
    pub total_limit: i32,
    pub auto_save: bool,
    pub tcp_port: i32,
    pub udp_port: i32,
    pub user_timeout: i32,
    pub log_events: u32,
    pub version: String,
    pub protocol_version: String,
}

macro_rules! same_fields {
    ($a:ty, $b:ty, $($f:ident),*) => {
        impl From<$a> for $b {
            fn from(x: $a) -> Self {
                Self { $($f: x.$f),* }
            }
        }
    };
}
same_fields!(
    core::ServerSettings,
    ServerSettings,
    name,
    motd,
    max_users,
    max_login_attempts,
    max_logins_per_address,
    login_delay_ms,
    voice_limit,
    video_limit,
    media_file_limit,
    desktop_limit,
    total_limit,
    auto_save,
    tcp_port,
    udp_port,
    user_timeout,
    log_events,
    version,
    protocol_version
);
same_fields!(
    ServerSettings,
    core::ServerSettings,
    name,
    motd,
    max_users,
    max_login_attempts,
    max_logins_per_address,
    login_delay_ms,
    voice_limit,
    video_limit,
    media_file_limit,
    desktop_limit,
    total_limit,
    auto_save,
    tcp_port,
    udp_port,
    user_timeout,
    log_events,
    version,
    protocol_version
);

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, uniffi::Record)]
pub struct ServerStatistics {
    pub total_bytes_sent: i64,
    pub total_bytes_received: i64,
    pub voice_bytes_sent: i64,
    pub voice_bytes_received: i64,
    pub video_bytes_sent: i64,
    pub video_bytes_received: i64,
    pub media_file_bytes_sent: i64,
    pub media_file_bytes_received: i64,
    pub desktop_bytes_sent: i64,
    pub desktop_bytes_received: i64,
    pub users_served: i32,
    pub users_peak: i32,
    pub files_sent: i64,
    pub files_received: i64,
    pub uptime_ms: i64,
}
same_fields!(
    core::ServerStatistics,
    ServerStatistics,
    total_bytes_sent,
    total_bytes_received,
    voice_bytes_sent,
    voice_bytes_received,
    video_bytes_sent,
    video_bytes_received,
    media_file_bytes_sent,
    media_file_bytes_received,
    desktop_bytes_sent,
    desktop_bytes_received,
    users_served,
    users_peak,
    files_sent,
    files_received,
    uptime_ms
);

#[uniffi::export]
impl TtClient {
    pub fn list_accounts(&self) -> Result<Vec<UserAccount>> {
        Ok(self.inner.list_accounts()?.into_iter().map(Into::into).collect())
    }

    /// Adds an account, or replaces the one with its username.
    pub fn save_account(&self, account: UserAccount) -> Result<()> {
        Ok(self.inner.save_account(&account.into())?)
    }

    pub fn delete_account(&self, username: String) -> Result<()> {
        Ok(self.inner.delete_account(&username)?)
    }

    pub fn server_settings(&self) -> Result<ServerSettings> {
        Ok(self.inner.server_settings()?.into())
    }

    pub fn update_server_settings(&self, settings: ServerSettings) -> Result<()> {
        Ok(self.inner.update_server_settings(&settings.into())?)
    }

    pub fn save_server_config(&self) -> Result<()> {
        Ok(self.inner.save_server_config()?)
    }

    pub fn server_statistics(&self) -> Result<ServerStatistics> {
        Ok(self.inner.server_statistics()?.into())
    }

    /// Bans an address (wildcards allowed), from the server or a channel.
    pub fn ban_address(&self, address: String, channel_path: String) -> Result<()> {
        Ok(self.inner.ban_address(&address, &channel_path)?)
    }

    /// My own account, as the server gave it at login.
    pub fn my_account(&self) -> Option<UserAccount> {
        self.inner.snapshot().my_account.map(Into::into)
    }
}
