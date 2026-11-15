//! Server descriptions (.tt files, tt:// links) and BearWare.dk's web
//! services, for the apps.

use ttng_core::{bearware, ttfile};

use crate::TtError;

type Result<T> = std::result::Result<T, TtError>;

fn refused(message: String) -> TtError {
    TtError::Refused { message }
}

/// A server as a .tt file, a tt:// link or BearWare's list describes it.
#[derive(Clone, Debug, Default, PartialEq, Eq, uniffi::Record)]
pub struct HostEntry {
    pub name: String,
    pub host: String,
    pub tcp_port: u16,
    pub udp_port: u16,
    pub encrypted: bool,
    pub username: String,
    pub password: String,
    pub nickname: String,
    pub status_message: String,
    pub channel: String,
    pub channel_password: String,
    pub ca_pem: String,
    pub cert_pem: String,
    pub key_pem: String,
    pub verify_peer: bool,
    pub join_code: String,
    pub listing: String,
    pub user_count: i32,
    pub country: String,
    pub server_name: String,
    pub motd: String,
}

macro_rules! both_ways {
    ($($f:ident),*) => {
        impl From<ttfile::HostEntry> for HostEntry {
            fn from(e: ttfile::HostEntry) -> Self { HostEntry { $($f: e.$f),* } }
        }
        impl From<HostEntry> for ttfile::HostEntry {
            fn from(e: HostEntry) -> Self { ttfile::HostEntry { $($f: e.$f),* } }
        }
    };
}
both_ways!(
    name,
    host,
    tcp_port,
    udp_port,
    encrypted,
    username,
    password,
    nickname,
    status_message,
    channel,
    channel_password,
    ca_pem,
    cert_pem,
    key_pem,
    verify_peer,
    join_code,
    listing,
    user_count,
    country,
    server_name,
    motd
);

/// The servers in a .tt file.
#[uniffi::export]
pub fn parse_tt_file(xml: String) -> Result<Vec<HostEntry>> {
    Ok(ttfile::parse_tt_file(&xml)
        .map_err(refused)?
        .into_iter()
        .map(Into::into)
        .collect())
}

/// A .tt file for a server (as the desktop writes them).
#[uniffi::export]
pub fn tt_file(entry: HostEntry) -> String {
    ttfile::to_tt_file(&entry.into())
}

/// A .tt file with several servers (the desktop's "Export Server list to
/// .tt File").
#[uniffi::export]
pub fn tt_file_many(entries: Vec<HostEntry>) -> String {
    ttfile::to_tt_file_many(&entries.into_iter().map(Into::into).collect::<Vec<_>>())
}

/// The server a tt:// link describes (nil if it isn't one).
#[uniffi::export]
pub fn parse_tt_link(link: String) -> Option<HostEntry> {
    ttfile::parse_tt_link(&link).map(Into::into)
}

/// A tt:// link for a server and channel.
#[uniffi::export]
pub fn tt_link(entry: HostEntry) -> String {
    ttfile::to_tt_link(&entry.into())
}

/// BearWare's public server list. Blocking.
#[uniffi::export]
pub fn public_servers(official: bool, unofficial: bool) -> Result<Vec<HostEntry>> {
    Ok(bearware::public_servers(official, unofficial)
        .map_err(refused)?
        .into_iter()
        .map(Into::into)
        .collect())
}

/// The server for a join code. Blocking.
#[uniffi::export]
pub fn server_for_join_code(code: String) -> Result<HostEntry> {
    Ok(bearware::server_for_join_code(&code).map_err(refused)?.into())
}

#[derive(Clone, Debug, Default, PartialEq, Eq, uniffi::Record)]
pub struct BearWareAccount {
    pub username: String,
    pub nickname: String,
    /// Keep it in the keychain.
    pub token: String,
}

/// Signs in to a BearWare.dk account (web login). Blocking.
#[uniffi::export]
pub fn bearware_sign_in(username: String, password: String) -> Result<BearWareAccount> {
    let a = bearware::bearware_sign_in(&username, &password).map_err(refused)?;
    Ok(BearWareAccount {
        username: a.username,
        nickname: a.nickname,
        token: a.token,
    })
}
