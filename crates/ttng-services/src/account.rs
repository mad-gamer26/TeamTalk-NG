//! NG Account: accounts, sessions, and syncing saved servers.

use serde::Deserialize;
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

    /// Deletes the account for good (its password confirms it): its
    /// sessions end, and packs it published stay in the catalog owned by
    /// nobody (delete them first to take them out).
    pub fn delete_account(&mut self, password: &str) -> Result<()> {
        self.post("/v1/account/delete", &json!({ "password": password }))?;
        self.token = None;
        Ok(())
    }

    // MARK: Sound packs (backed up privately; published to the catalog)

    /// The account's packs.
    pub fn my_packs(&self) -> Result<Vec<OwnPack>> {
        #[derive(serde::Deserialize)]
        struct Answer {
            packs: Vec<OwnPack>,
        }
        decode::<Answer>(self.get("/v1/packs")?).map(|a| a.packs)
    }

    /// Backs up one of this app's packs (its `local_id`), or finds it.
    pub fn backup_pack(&self, local_id: &str, name: &str) -> Result<OwnPack> {
        decode(self.post("/v1/packs", &json!({ "local_id": local_id, "name": name }))?)
    }

    /// Changes a pack's name, author, description, or whether it's in the catalog.
    pub fn change_pack(&self, id: &str, change: &PackChange) -> Result<OwnPack> {
        decode(self.send(
            "PATCH",
            &format!("/v1/packs/{}", seg(id)),
            Some(serde_json::to_vec(change).unwrap_or_default()),
            true,
        )?)
    }

    /// Puts one sound (`logged_on.wav`) in a pack.
    pub fn upload_pack_file(&self, id: &str, name: &str, data: &[u8]) -> Result<OwnPack> {
        decode(self.send(
            "PUT",
            &format!("/v1/packs/{}/files/{}", seg(id), seg(name)),
            Some(data.to_vec()),
            false,
        )?)
    }

    pub fn remove_pack_file(&self, id: &str, name: &str) -> Result<OwnPack> {
        decode(self.send(
            "DELETE",
            &format!("/v1/packs/{}/files/{}", seg(id), seg(name)),
            None,
            false,
        )?)
    }

    pub fn delete_pack(&self, id: &str) -> Result<()> {
        self.send("DELETE", &format!("/v1/packs/{}", seg(id)), None, false)
            .map(|_| ())
    }

    fn send(&self, method: &str, path: &str, body: Option<Vec<u8>>, json_body: bool) -> Result<Value> {
        let url = format!("{}{path}", self.base);
        let auth = self.token.as_ref().map(|t| format!("Bearer {t}"));
        let r = match method {
            "PATCH" => {
                let mut req = self.agent.patch(url);
                if let Some(a) = &auth {
                    req = req.header("Authorization", a);
                }
                if json_body {
                    req = req.header("Content-Type", "application/json");
                }
                req.send(body.unwrap_or_default())
            }
            "PUT" => {
                let mut req = self.agent.put(url);
                if let Some(a) = &auth {
                    req = req.header("Authorization", a);
                }
                req.send(body.unwrap_or_default())
            }
            _ => {
                let mut req = self.agent.delete(url);
                if let Some(a) = &auth {
                    req = req.header("Authorization", a);
                }
                req.call()
            }
        };
        answer(r, self.token.is_some())
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

/// A path segment, escaped.
fn seg(s: &str) -> String {
    s.bytes()
        .map(|b| match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => (b as char).to_string(),
            _ => format!("%{b:02X}"),
        })
        .collect()
}

/// One of the account's sound packs, as the service has it.
#[derive(Clone, Debug, Default, PartialEq, Eq, serde::Deserialize)]
#[serde(default)]
pub struct OwnPack {
    pub id: String,
    /// The app's own ID for the pack.
    pub local_id: String,
    pub name: String,
    pub author: String,
    pub description: String,
    /// In the catalog for everyone.
    pub public: bool,
    /// Hidden from the catalog by an administrator.
    pub hidden: bool,
    pub version: String,
    pub installs: i64,
    pub files: Vec<OwnPackFile>,
}

#[derive(Clone, Debug, Default, PartialEq, Eq, serde::Deserialize)]
#[serde(default)]
pub struct OwnPackFile {
    pub name: String,
    pub hash: String,
    pub size: i64,
}

/// What to change about a pack (what's left out stays).
#[derive(Clone, Debug, Default, PartialEq, Eq, serde::Serialize)]
pub struct PackChange {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub author: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub description: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub public: Option<bool>,
}
