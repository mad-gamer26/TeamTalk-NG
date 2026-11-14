//! NG Account for the apps.

use std::sync::{Arc, Mutex};

use serde_json::Value;
use ttng_services as svc;

/// What went wrong with NG Account, in words to show (`message`).
#[derive(Clone, Debug, PartialEq, Eq, uniffi::Error)]
pub enum NgError {
    /// The service couldn't be reached.
    Network {
        message: String,
    },
    /// The service said no, in its words.
    Refused {
        status: u16,
        message: String,
    },
    /// The session is over: sign in again.
    SignedOut {
        message: String,
    },
    Unexpected {
        message: String,
    },
}

impl std::fmt::Display for NgError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Network { message }
            | Self::Refused { message, .. }
            | Self::SignedOut { message }
            | Self::Unexpected { message } => f.write_str(message),
        }
    }
}

impl std::error::Error for NgError {}

impl From<svc::ServiceError> for NgError {
    fn from(e: svc::ServiceError) -> Self {
        match e {
            svc::ServiceError::Network(message) => Self::Network { message },
            svc::ServiceError::Refused { status, message } => Self::Refused { status, message },
            svc::ServiceError::SignedOut(message) => Self::SignedOut { message },
            svc::ServiceError::Unexpected(message) => Self::Unexpected { message },
        }
    }
}

type Result<T> = std::result::Result<T, NgError>;

/// A signed-in session. `token` is a secret: keep it in the keychain.
#[derive(Clone, Debug, PartialEq, Eq, uniffi::Record)]
pub struct NgSession {
    pub token: String,
    pub session_id: i64,
    pub account_id: i64,
    pub email: String,
    pub device_id: i64,
    pub push_key: String,
}

impl From<svc::Session> for NgSession {
    fn from(s: svc::Session) -> Self {
        NgSession {
            token: s.token,
            session_id: s.session_id,
            account_id: s.account.id,
            email: s.account.email,
            device_id: s.device_id,
            push_key: s.push_key,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq, uniffi::Record)]
pub struct NgAccountInfo {
    pub email: String,
    pub created: i64,
    pub session_id: i64,
    pub sync_rev: i64,
}

/// A saved server as NG Account syncs it (shared with the old app).
#[derive(Clone, Debug, Default, PartialEq, Eq, uniffi::Record)]
pub struct SyncedServer {
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
    pub sync_password: bool,
    pub order: i64,
    /// Fields this app doesn't use, kept as they were.
    pub other_json: String,
}

impl From<svc::SyncedServer> for SyncedServer {
    fn from(s: svc::SyncedServer) -> Self {
        SyncedServer {
            name: s.name,
            host: s.host,
            tcp_port: s.tcp_port,
            udp_port: s.udp_port,
            encrypted: s.encrypted,
            username: s.username,
            password: s.password,
            nickname: s.nickname,
            status_message: s.status_message,
            channel: s.channel,
            channel_password: s.channel_password,
            sync_password: s.sync_password,
            order: s.order,
            other_json: s.other_json,
        }
    }
}

impl From<SyncedServer> for svc::SyncedServer {
    fn from(s: SyncedServer) -> Self {
        svc::SyncedServer {
            name: s.name,
            host: s.host,
            tcp_port: s.tcp_port,
            udp_port: s.udp_port,
            encrypted: s.encrypted,
            username: s.username,
            password: s.password,
            nickname: s.nickname,
            status_message: s.status_message,
            channel: s.channel,
            channel_password: s.channel_password,
            sync_password: s.sync_password,
            order: s.order,
            other_json: s.other_json,
        }
    }
}

/// One synced thing at a revision. For `kind` "server", `server` is set
/// (unless deleted); other kinds carry their JSON in `data_json`.
#[derive(Clone, Debug, PartialEq, Eq, uniffi::Record)]
pub struct SyncRecord {
    pub kind: String,
    pub key: String,
    pub rev: i64,
    pub deleted: bool,
    pub server: Option<SyncedServer>,
    pub data_json: Option<String>,
    pub updated: i64,
}

impl From<svc::SyncRecord> for SyncRecord {
    fn from(r: svc::SyncRecord) -> Self {
        let server = (r.kind == "server" && !r.deleted)
            .then(|| r.data.as_ref().map(|d| svc::SyncedServer::from_json(d).into()))
            .flatten();
        SyncRecord {
            kind: r.kind,
            key: r.key,
            rev: r.rev,
            deleted: r.deleted,
            server,
            data_json: r.data.map(|d| d.to_string()),
            updated: r.updated,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq, uniffi::Record)]
pub struct SyncPull {
    pub rev: i64,
    /// The account's data started over: `records` is all of it.
    pub reset: bool,
    pub records: Vec<SyncRecord>,
}

/// A change: `server` for a server, else `data_json`; `base_rev` 0 for new.
#[derive(Clone, Debug, PartialEq, Eq, uniffi::Record)]
pub struct SyncChange {
    pub kind: String,
    pub key: String,
    pub base_rev: i64,
    pub deleted: bool,
    pub server: Option<SyncedServer>,
    pub data_json: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Eq, uniffi::Record)]
pub struct SyncApplied {
    pub rev: i64,
    pub applied: Vec<SyncRecord>,
    /// Changed elsewhere meanwhile, as they are now.
    pub conflicts: Vec<SyncRecord>,
}

/// NG Account for one install of the app. Calls block: run them off the
/// main thread.
#[derive(uniffi::Object)]
pub struct NgAccountClient {
    inner: Mutex<svc::NgAccount>,
}

impl std::fmt::Debug for NgAccountClient {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("NgAccountClient").finish_non_exhaustive()
    }
}

impl NgAccountClient {
    fn with<T>(&self, f: impl FnOnce(&mut svc::NgAccount) -> std::result::Result<T, svc::ServiceError>) -> Result<T> {
        let mut a = self.inner.lock().unwrap_or_else(|e| e.into_inner());
        f(&mut a).map_err(Into::into)
    }
}

#[uniffi::export]
impl NgAccountClient {
    /// `base_url` empty means the live service; `token` from the keychain
    /// resumes a session.
    #[uniffi::constructor]
    pub fn new(base_url: String, install_id: String, device_name: String, token: Option<String>) -> Arc<Self> {
        let base = if base_url.is_empty() {
            svc::DEFAULT_BASE_URL.to_owned()
        } else {
            base_url
        };
        let mut a = svc::NgAccount::new(&base, &install_id, &device_name);
        if let Some(t) = token {
            a = a.with_token(&t);
        }
        Arc::new(NgAccountClient { inner: Mutex::new(a) })
    }

    pub fn signed_in(&self) -> bool {
        self.inner.lock().map(|a| a.signed_in()).unwrap_or(false)
    }

    /// Emails a code to finish making the account.
    pub fn sign_up(&self, email: String, password: String) -> Result<()> {
        self.with(|a| a.sign_up(&email, &password))
    }

    pub fn verify(&self, email: String, code: String) -> Result<NgSession> {
        self.with(|a| a.verify(&email, &code)).map(Into::into)
    }

    pub fn sign_in(&self, email: String, password: String) -> Result<NgSession> {
        self.with(|a| a.sign_in(&email, &password)).map(Into::into)
    }

    pub fn forgot_password(&self, email: String) -> Result<()> {
        self.with(|a| a.forgot_password(&email))
    }

    pub fn reset_password(&self, email: String, code: String, password: String) -> Result<NgSession> {
        self.with(|a| a.reset_password(&email, &code, &password))
            .map(Into::into)
    }

    pub fn account(&self) -> Result<NgAccountInfo> {
        self.with(|a| a.account()).map(|i| NgAccountInfo {
            email: i.account.email,
            created: i.account.created,
            session_id: i.session_id,
            sync_rev: i.sync_rev,
        })
    }

    pub fn change_password(&self, current: String, new: String) -> Result<()> {
        self.with(|a| a.change_password(&current, &new))
    }

    pub fn sign_out(&self) -> Result<()> {
        self.with(|a| a.sign_out())
    }

    pub fn pull(&self, since: i64) -> Result<SyncPull> {
        self.with(|a| a.pull(since)).map(|p| SyncPull {
            rev: p.rev,
            reset: p.reset,
            records: p.records.into_iter().map(Into::into).collect(),
        })
    }

    pub fn push(&self, changes: Vec<SyncChange>) -> Result<SyncApplied> {
        let changes: Vec<svc::SyncChange> = changes
            .into_iter()
            .map(|c| svc::SyncChange {
                data: match (c.server, c.data_json) {
                    (Some(s), _) => Some(svc::SyncedServer::from(s).to_json()),
                    (None, Some(j)) => serde_json::from_str::<Value>(&j).ok(),
                    (None, None) => None,
                },
                kind: c.kind,
                key: c.key,
                base_rev: c.base_rev,
                deleted: c.deleted,
            })
            .collect();
        self.with(|a| a.push(&changes)).map(|r| SyncApplied {
            rev: r.rev,
            applied: r.applied.into_iter().map(Into::into).collect(),
            conflicts: r.conflicts.into_iter().map(Into::into).collect(),
        })
    }
}
