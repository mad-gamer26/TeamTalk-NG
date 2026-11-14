//! NG Account: accounts, sessions, and syncing saved servers.

use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use crate::error::{Result, ServiceError};

/// An NG Account.
#[derive(Clone, Debug, Default, PartialEq, Eq, Deserialize)]
pub struct Account {
    pub id: i64,
    pub email: String,
    /// When it was made, in milliseconds since the Unix epoch.
    pub created: i64,
}

/// A signed-in session. `token` is a secret: keep it in the keychain.
#[derive(Clone, Debug, PartialEq, Eq, Deserialize)]
pub struct Session {
    pub token: String,
    pub session_id: i64,
    pub account: Account,
    /// The sign-up that owns the account's monitors.
    pub device_id: i64,
    /// Opens sealed notifications (the same on every install).
    pub push_key: String,
}

/// The account, as the service sees it now.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct AccountInfo {
    pub account: Account,
    pub session_id: i64,
    pub sync_rev: i64,
}

/// One synced thing (a server or a setting) at a revision.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize)]
pub struct SyncRecord {
    pub kind: String,
    pub key: String,
    pub rev: i64,
    #[serde(default)]
    pub deleted: bool,
    #[serde(default)]
    pub data: Option<Value>,
    #[serde(default)]
    pub updated: i64,
}

/// What changed since a revision.
#[derive(Clone, Debug, PartialEq, Deserialize)]
pub struct SyncPull {
    /// The account's revision now (pull from it next time).
    pub rev: i64,
    /// The account's data started over: `records` is all of it.
    pub reset: bool,
    pub records: Vec<SyncRecord>,
}

/// A change to send: made from `base_rev` (0 for something new).
#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct SyncChange {
    pub kind: String,
    pub key: String,
    pub base_rev: i64,
    pub deleted: bool,
    pub data: Option<Value>,
}

/// What the service made of the changes.
#[derive(Clone, Debug, PartialEq, Deserialize)]
pub struct SyncApplied {
    pub rev: i64,
    pub applied: Vec<SyncRecord>,
    /// Changed elsewhere meanwhile, as they are now: merge and send again.
    pub conflicts: Vec<SyncRecord>,
}

/// A client for NG Account on one service, as one install of the app.
#[derive(Clone)]
pub struct NgAccount {
    base: String,
    install_id: String,
    device_name: String,
    token: Option<String>,
    agent: ureq::Agent,
}

impl std::fmt::Debug for NgAccount {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("NgAccount")
            .field("base", &self.base)
            .finish_non_exhaustive()
    }
}

impl NgAccount {
    /// `install_id`: this install's lasting ID (letters, digits, dashes);
    /// `device_name`: what the account's device list shows ("Matthew's iPhone").
    pub fn new(base_url: &str, install_id: &str, device_name: &str) -> NgAccount {
        let agent = ureq::Agent::config_builder()
            .http_status_as_error(false)
            .timeout_global(Some(std::time::Duration::from_secs(30)))
            .build()
            .into();
        NgAccount {
            base: base_url.trim_end_matches('/').to_owned(),
            install_id: install_id.into(),
            device_name: device_name.into(),
            token: None,
            agent,
        }
    }

    /// Uses a session from before (its token from the keychain).
    pub fn with_token(mut self, token: &str) -> NgAccount {
        self.token = Some(token.into());
        self
    }

    pub fn signed_in(&self) -> bool {
        self.token.is_some()
    }

    fn install(&self) -> Value {
        json!({ "install_id": self.install_id, "device_name": self.device_name })
    }

    fn with(&self, extra: Value) -> Value {
        let mut v = self.install();
        if let (Some(o), Some(e)) = (v.as_object_mut(), extra.as_object()) {
            o.extend(e.clone());
        }
        v
    }

    /// Starts making an account: the service emails a code to `email`.
    pub fn sign_up(&self, email: &str, password: &str) -> Result<()> {
        self.post("/v1/account/signup", &json!({ "email": email, "password": password }))
            .map(|_| ())
    }

    /// Finishes making the account with the emailed code; signed in.
    pub fn verify(&mut self, email: &str, code: &str) -> Result<Session> {
        let v = self.post(
            "/v1/account/verify",
            &self.with(json!({ "email": email, "code": code })),
        )?;
        self.session(v)
    }

    pub fn sign_in(&mut self, email: &str, password: &str) -> Result<Session> {
        let v = self.post(
            "/v1/account/signin",
            &self.with(json!({ "email": email, "password": password })),
        )?;
        self.session(v)
    }

    /// Emails a code for choosing a new password.
    pub fn forgot_password(&self, email: &str) -> Result<()> {
        self.post("/v1/account/forgot", &json!({ "email": email })).map(|_| ())
    }

    /// A new password with the emailed code; signed in.
    pub fn reset_password(&mut self, email: &str, code: &str, password: &str) -> Result<Session> {
        let v = self.post(
            "/v1/account/reset",
            &self.with(json!({ "email": email, "code": code, "password": password })),
        )?;
        self.session(v)
    }

    pub fn account(&self) -> Result<AccountInfo> {
        let v = self.get("/v1/account")?;
        Ok(AccountInfo {
            account: decode(v.get("account").cloned().unwrap_or(Value::Null))?,
            session_id: v.get("session_id").and_then(Value::as_i64).unwrap_or(0),
            sync_rev: v.get("sync_rev").and_then(Value::as_i64).unwrap_or(0),
        })
    }

    pub fn change_password(&self, current: &str, new: &str) -> Result<()> {
        self.post("/v1/account/password", &json!({ "current": current, "new": new }))
            .map(|_| ())
    }

    /// Ends this session (the token stops working).
    pub fn sign_out(&mut self) -> Result<()> {
        let r = self.post("/v1/account/signout", &json!({}));
        self.token = None;
        r.map(|_| ())
    }

    /// What changed since revision `since` (0 for everything).
    pub fn pull(&self, since: i64) -> Result<SyncPull> {
        decode(self.get(&format!("/v1/sync?since={since}"))?)
    }

    /// Sends changes (at most 500 at a time).
    pub fn push(&self, changes: &[SyncChange]) -> Result<SyncApplied> {
        decode(self.post("/v1/sync", &json!({ "changes": changes }))?)
    }

    fn session(&mut self, v: Value) -> Result<Session> {
        let s: Session = decode(v)?;
        self.token = Some(s.token.clone());
        Ok(s)
    }

    fn get(&self, path: &str) -> Result<Value> {
        let mut req = self.agent.get(format!("{}{path}", self.base));
        if let Some(t) = &self.token {
            req = req.header("Authorization", format!("Bearer {t}"));
        }
        answer(req.call(), self.token.is_some())
    }

    fn post(&self, path: &str, body: &Value) -> Result<Value> {
        let mut req = self.agent.post(format!("{}{path}", self.base));
        if let Some(t) = &self.token {
            req = req.header("Authorization", format!("Bearer {t}"));
        }
        answer(req.send_json(body), self.token.is_some())
    }
}

pub(crate) fn decode<T: serde::de::DeserializeOwned>(v: Value) -> Result<T> {
    serde_json::from_value(v)
        .map_err(|e| ServiceError::Unexpected(format!("The service's answer wasn't understood ({e}).")))
}

/// The answer's JSON, or the service's words for why not. A 401 with a
/// token means the session is over.
pub(crate) fn answer(
    r: std::result::Result<ureq::http::Response<ureq::Body>, ureq::Error>,
    had_token: bool,
) -> Result<Value> {
    let mut resp = r.map_err(|e| ServiceError::Network(format!("Couldn't reach NG Account ({e}).")))?;
    let status = resp.status().as_u16();
    let text = resp.body_mut().read_to_string().unwrap_or_default();
    let value: Value = if text.trim().is_empty() {
        Value::Null
    } else {
        serde_json::from_str(&text).unwrap_or(Value::Null)
    };
    if (200..300).contains(&status) {
        return Ok(value);
    }
    let message = value
        .get("error")
        .and_then(Value::as_str)
        .map(str::to_owned)
        .unwrap_or_else(|| format!("NG Account refused that (HTTP {status})."));
    Err(if status == 401 && had_token {
        ServiceError::SignedOut(message)
    } else {
        ServiceError::Refused { status, message }
    })
}
