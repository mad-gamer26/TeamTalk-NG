//! NG Account for the apps.

use std::sync::{Arc, Mutex};

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
#[derive(Clone, Debug, PartialEq, Eq, uniffi::Record)]
pub struct OwnPack {
    pub id: String,
    pub local_id: String,
    pub name: String,
    pub author: String,
    pub description: String,
    pub public: bool,
    pub hidden: bool,
    pub version: String,
    pub installs: i64,
    pub files: Vec<OwnPackFile>,
}

#[derive(Clone, Debug, PartialEq, Eq, uniffi::Record)]
pub struct OwnPackFile {
    pub name: String,
    /// SHA-256, hex.
    pub hash: String,
    pub size: i64,
}

impl From<svc::OwnPack> for OwnPack {
    fn from(p: svc::OwnPack) -> Self {
        OwnPack {
            id: p.id,
            local_id: p.local_id,
            name: p.name,
            author: p.author,
            description: p.description,
            public: p.public,
            hidden: p.hidden,
            version: p.version,
            installs: p.installs,
            files: p
                .files
                .into_iter()
                .map(|f| OwnPackFile {
                    name: f.name,
                    hash: f.hash,
                    size: f.size,
                })
                .collect(),
        }
    }
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

    /// The account's sound packs (backed up, maybe published).
    pub fn my_packs(&self) -> Result<Vec<OwnPack>> {
        self.with(|a| a.my_packs())
            .map(|l| l.into_iter().map(Into::into).collect())
    }

    /// Backs up one of this app's packs (or finds it): `local_id` is the app's ID for it.
    pub fn backup_pack(&self, local_id: String, name: String) -> Result<OwnPack> {
        self.with(|a| a.backup_pack(&local_id, &name)).map(Into::into)
    }

    /// Changes what's given (nil stays): name, author, description, in the catalog.
    pub fn change_pack(
        &self,
        id: String,
        name: Option<String>,
        author: Option<String>,
        description: Option<String>,
        public: Option<bool>,
    ) -> Result<OwnPack> {
        let c = svc::PackChange {
            name,
            author,
            description,
            public,
        };
        self.with(|a| a.change_pack(&id, &c)).map(Into::into)
    }

    /// Puts a sound (its file's bytes, named as the desktop's, such as `logged_on.wav`) in a pack.
    pub fn upload_pack_file(&self, id: String, name: String, data: Vec<u8>) -> Result<OwnPack> {
        self.with(|a| a.upload_pack_file(&id, &name, &data)).map(Into::into)
    }

    pub fn remove_pack_file(&self, id: String, name: String) -> Result<OwnPack> {
        self.with(|a| a.remove_pack_file(&id, &name)).map(Into::into)
    }

    pub fn delete_pack(&self, id: String) -> Result<()> {
        self.with(|a| a.delete_pack(&id))
    }
}
