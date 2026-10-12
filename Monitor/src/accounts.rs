//! NG Account: an email and password that own a person's monitors, synced
//! servers and settings, and sound packs, so a new phone or a reinstall
//! only needs signing in.
//!
//! An account owns one sign-up (a `devices` row), the same kind of owner
//! an install without an account has, so monitoring, notifications and
//! conversations work the same either way. Each app install that signs in
//! gets a session of its own; signing out ends it.

use std::sync::Arc;

use anyhow::Context;
use argon2::password_hash::{PasswordHash, PasswordHasher, PasswordVerifier, SaltString};
use argon2::Argon2;
use base64::Engine;
use base64::engine::general_purpose::{STANDARD as B64, URL_SAFE_NO_PAD as B64URL};
use rusqlite::{OptionalExtension, params};
use serde::Serialize;

use crate::hub::{Hub, HubError, Result, hash};
use crate::mail::{CodePurpose, Mailer};
use crate::push::RateLimit;
use crate::store::{Device, Store, now_ms};

/// How long an emailed code works.
const CODE_LIFETIME_MS: i64 = 15 * 60 * 1000;
/// Wrong tries before a code stops working.
const CODE_ATTEMPTS: i64 = 5;
/// Wrong passwords in a row before the account waits a while.
const LOCK_AFTER_FAILURES: i64 = 10;
const LOCK_MS: i64 = 15 * 60 * 1000;
/// Sessions not used for this long are ended.
const SESSION_IDLE_MS: i64 = 400 * 24 * 60 * 60 * 1000;

#[derive(Debug, Clone, Serialize)]
pub struct Account {
    pub id: i64,
    pub email: String,
    /// The sign-up that owns this account's monitors.
    #[serde(skip)]
    pub owner: i64,
    pub created: i64,
    #[serde(skip)]
    password_hash: String,
    #[serde(skip)]
    locked_until: i64,
}

/// One app install signed in to an account.
#[derive(Debug, Clone, Serialize)]
pub struct Session {
    pub id: i64,
    #[serde(skip)]
    pub account: i64,
    pub install_id: String,
    pub name: String,
    pub created: i64,
    pub last_seen: i64,
}

/// What signing in gives the app.
#[derive(Debug, Serialize)]
pub struct SignedIn {
    /// The session's secret, sent as `Authorization: Bearer`.
    pub token: String,
    pub session_id: i64,
    pub account: Account,
    /// The sign-up that owns the monitors (shown in notifications).
    pub device_id: i64,
    /// Opens sealed notifications; the same on every install.
    pub push_key: String,
}

/// Which app install is signing in.
#[derive(Debug, Clone, Default)]
pub struct Install {
    pub install_id: String,
    pub name: String,
    /// The secret token of the sign-up this install used before NG
    /// Account, if any: its monitors become the account's.
    pub claim_token: Option<String>,
}

impl Store {
    pub(crate) fn setup_accounts(&self) -> anyhow::Result<()> {
        self.db.execute_batch(
            r#"
            CREATE TABLE IF NOT EXISTS accounts (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                email TEXT NOT NULL UNIQUE,
                password_hash TEXT NOT NULL,
                owner INTEGER NOT NULL,
                created INTEGER NOT NULL,
                failed_logins INTEGER NOT NULL DEFAULT 0,
                locked_until INTEGER NOT NULL DEFAULT 0
            );
            CREATE TABLE IF NOT EXISTS sessions (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                account INTEGER NOT NULL,
                token_hash TEXT NOT NULL UNIQUE,
                install_id TEXT NOT NULL,
                name TEXT NOT NULL,
                created INTEGER NOT NULL,
                last_seen INTEGER NOT NULL
            );
            CREATE INDEX IF NOT EXISTS sessions_account ON sessions (account);
            -- Emailed codes, one per address and purpose. A sign-up's code
            -- also holds the chosen password until the code is typed in.
            CREATE TABLE IF NOT EXISTS email_codes (
                email TEXT NOT NULL,
                purpose TEXT NOT NULL,
                code_hash TEXT NOT NULL,
                password_hash TEXT,
                expires INTEGER NOT NULL,
                attempts INTEGER NOT NULL DEFAULT 0,
                PRIMARY KEY (email, purpose)
            );
            "#,
        )?;
        Ok(())
    }

    const ACCOUNT_COLUMNS: &str = "id, email, owner, created, password_hash, locked_until";

    fn account_row(r: &rusqlite::Row) -> rusqlite::Result<Account> {
        Ok(Account {
            id: r.get(0)?,
            email: r.get(1)?,
            owner: r.get(2)?,
            created: r.get(3)?,
            password_hash: r.get(4)?,
            locked_until: r.get(5)?,
        })
    }

    pub fn account(&self, id: i64) -> anyhow::Result<Option<Account>> {
        let sql = format!("SELECT {} FROM accounts WHERE id = ?1", Self::ACCOUNT_COLUMNS);
        Ok(self.db.query_row(&sql, [id], Self::account_row).optional()?)
    }

    pub fn account_by_email(&self, email: &str) -> anyhow::Result<Option<Account>> {
        let sql = format!("SELECT {} FROM accounts WHERE email = ?1", Self::ACCOUNT_COLUMNS);
        Ok(self.db.query_row(&sql, [email], Self::account_row).optional()?)
    }

    /// The account a sign-up belongs to, if it belongs to one.
    pub fn account_of_owner(&self, device_id: i64) -> anyhow::Result<Option<i64>> {
        Ok(self.db.query_row("SELECT id FROM accounts WHERE owner = ?1", [device_id], |r| r.get(0)).optional()?)
    }

    pub fn accounts(&self) -> anyhow::Result<Vec<Account>> {
        let sql = format!("SELECT {} FROM accounts ORDER BY id", Self::ACCOUNT_COLUMNS);
        let mut st = self.db.prepare(&sql)?;
        let rows = st.query_map([], Self::account_row)?;
        Ok(rows.collect::<std::result::Result<_, _>>()?)
    }

    fn add_account(&self, email: &str, password_hash: &str, owner: i64) -> anyhow::Result<i64> {
        self.db.execute(
            "INSERT INTO accounts (email, password_hash, owner, created) VALUES (?1, ?2, ?3, ?4)",
            params![email, password_hash, owner, now_ms()],
        )?;
        Ok(self.db.last_insert_rowid())
    }

    fn set_password_hash(&self, account: i64, password_hash: &str) -> anyhow::Result<()> {
        self.db.execute(
            "UPDATE accounts SET password_hash = ?2, failed_logins = 0, locked_until = 0 WHERE id = ?1",
            params![account, password_hash],
        )?;
        Ok(())
    }

    fn login_failed(&self, account: i64) -> anyhow::Result<()> {
        self.db.execute(
            "UPDATE accounts SET
                locked_until = CASE WHEN failed_logins + 1 >= ?2 THEN ?3 ELSE locked_until END,
                failed_logins = CASE WHEN failed_logins + 1 >= ?2 THEN 0 ELSE failed_logins + 1 END
             WHERE id = ?1",
            params![account, LOCK_AFTER_FAILURES, now_ms() + LOCK_MS],
        )?;
        Ok(())
    }

    fn login_succeeded(&self, account: i64) -> anyhow::Result<()> {
        self.db.execute("UPDATE accounts SET failed_logins = 0, locked_until = 0 WHERE id = ?1", [account])?;
        Ok(())
    }

    // Codes

    fn put_code(&self, email: &str, purpose: CodePurpose, code: &str, password_hash: Option<&str>) -> anyhow::Result<()> {
        self.db.execute(
            "INSERT OR REPLACE INTO email_codes (email, purpose, code_hash, password_hash, expires, attempts) VALUES (?1, ?2, ?3, ?4, ?5, 0)",
            params![email, purpose.as_str(), code_hash(email, code), password_hash, now_ms() + CODE_LIFETIME_MS],
        )?;
        Ok(())
    }

    fn delete_code(&self, email: &str, purpose: CodePurpose) -> anyhow::Result<()> {
        self.db.execute("DELETE FROM email_codes WHERE email = ?1 AND purpose = ?2", params![email, purpose.as_str()])?;
        Ok(())
    }

    /// Check a typed code. A right one is used up; a wrong one counts
    /// against the code. Returns the sign-up's password, if it has one.
    fn use_code(&self, email: &str, purpose: CodePurpose, code: &str) -> Result<Option<String>> {
        let row: Option<(String, Option<String>, i64, i64)> = self
            .db
            .query_row(
                "SELECT code_hash, password_hash, expires, attempts FROM email_codes WHERE email = ?1 AND purpose = ?2",
                params![email, purpose.as_str()],
                |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?)),
            )
            .optional()
            .map_err(anyhow::Error::from)?;
        let Some((stored, password_hash, expires, attempts)) = row else {
            return Err(HubError::Unauthorized("That code has expired. Ask for a new one.".into()));
        };
        if expires < now_ms() || attempts >= CODE_ATTEMPTS {
            self.delete_code(email, purpose)?;
            return Err(HubError::Unauthorized("That code has expired. Ask for a new one.".into()));
        }
        if stored != code_hash(email, code.trim()) {
            self.db
                .execute("UPDATE email_codes SET attempts = attempts + 1 WHERE email = ?1 AND purpose = ?2", params![email, purpose.as_str()])
                .map_err(anyhow::Error::from)?;
            return Err(HubError::Unauthorized("That code is not right. Check the email and try again.".into()));
        }
        self.delete_code(email, purpose)?;
        Ok(password_hash)
    }

    // Sessions

    /// A new session for an install, replacing any it had on this account.
    fn add_session(&self, account: i64, token_hash: &str, install: &Install) -> anyhow::Result<i64> {
        self.db.execute("DELETE FROM sessions WHERE account = ?1 AND install_id = ?2", params![account, install.install_id])?;
        let now = now_ms();
        self.db.execute(
            "INSERT INTO sessions (account, token_hash, install_id, name, created, last_seen) VALUES (?1, ?2, ?3, ?4, ?5, ?5)",
            params![account, token_hash, install.install_id, install.name, now],
        )?;
        Ok(self.db.last_insert_rowid())
    }

    const SESSION_COLUMNS: &str = "id, account, install_id, name, created, last_seen";

    fn session_row(r: &rusqlite::Row) -> rusqlite::Result<Session> {
        Ok(Session { id: r.get(0)?, account: r.get(1)?, install_id: r.get(2)?, name: r.get(3)?, created: r.get(4)?, last_seen: r.get(5)? })
    }

    pub fn session_by_token(&self, token_hash: &str) -> anyhow::Result<Option<Session>> {
        let sql = format!("SELECT {} FROM sessions WHERE token_hash = ?1", Self::SESSION_COLUMNS);
        Ok(self.db.query_row(&sql, [token_hash], Self::session_row).optional()?)
    }

    pub fn sessions(&self, account: i64) -> anyhow::Result<Vec<Session>> {
        let sql = format!("SELECT {} FROM sessions WHERE account = ?1 ORDER BY last_seen DESC", Self::SESSION_COLUMNS);
        let mut st = self.db.prepare(&sql)?;
        let rows = st.query_map([account], Self::session_row)?;
        Ok(rows.collect::<std::result::Result<_, _>>()?)
    }

    pub fn touch_session(&self, id: i64) -> anyhow::Result<()> {
        self.db.execute("UPDATE sessions SET last_seen = ?2 WHERE id = ?1", params![id, now_ms()])?;
        Ok(())
    }

    /// End a session; its install stops getting the account's
    /// notifications.
    pub fn end_session(&self, account: i64, session: i64) -> anyhow::Result<bool> {
        let Some((install_id, owner)): Option<(String, i64)> = self
            .db
            .query_row(
                "SELECT s.install_id, a.owner FROM sessions s JOIN accounts a ON a.id = s.account WHERE s.id = ?1 AND s.account = ?2",
                params![session, account],
                |r| Ok((r.get(0)?, r.get(1)?)),
            )
            .optional()?
        else {
            return Ok(false);
        };
        self.db.execute("DELETE FROM sessions WHERE id = ?1", [session])?;
        self.db.execute("DELETE FROM push_targets WHERE device_id = ?1 AND install_id = ?2", params![owner, install_id])?;
        Ok(true)
    }

    /// End every session of an account but `keep`.
    fn end_other_sessions(&self, account: i64, keep: Option<i64>) -> anyhow::Result<()> {
        let others: Vec<i64> = self
            .sessions(account)?
            .into_iter()
            .map(|s| s.id)
            .filter(|id| Some(*id) != keep)
            .collect();
        for id in others {
            self.end_session(account, id)?;
        }
        Ok(())
    }

    /// Forget an account and everything that is only its own: monitors,
    /// sessions, codes, and (through `delete_account_data`) synced data
    /// and private sound packs.
    fn delete_account(&self, account: &Account) -> anyhow::Result<()> {
        self.delete_account_data(account.id)?;
        self.db.execute("DELETE FROM sessions WHERE account = ?1", [account.id])?;
        self.db.execute("DELETE FROM email_codes WHERE email = ?1", [&account.email])?;
        self.db.execute("DELETE FROM push_targets WHERE device_id = ?1", [account.owner])?;
        self.db.execute("DELETE FROM accounts WHERE id = ?1", [account.id])?;
        self.remove_device(account.owner)?;
        Ok(())
    }

    /// What an account keeps beyond its monitors: synced records and
    /// sound packs (public packs stay, without an owner).
    fn delete_account_data(&self, account: i64) -> anyhow::Result<()> {
        self.delete_sync_records(account)?;
        self.release_packs(account)?;
        Ok(())
    }

    /// Drop expired codes and sessions nobody has used for a long time.
    pub fn sweep_accounts(&self, now: i64) -> anyhow::Result<()> {
        self.db.execute("DELETE FROM email_codes WHERE expires < ?1", [now])?;
        let idle: Vec<(i64, i64)> = self
            .db
            .prepare("SELECT account, id FROM sessions WHERE last_seen < ?1")?
            .query_map([now - SESSION_IDLE_MS], |r| Ok((r.get(0)?, r.get(1)?)))?
            .collect::<std::result::Result<_, _>>()?;
        for (account, id) in idle {
            self.end_session(account, id)?;
        }
        Ok(())
    }
}

fn code_hash(email: &str, code: &str) -> String {
    hash(&format!("{email}\n{code}"))
}

/// Emails are compared in lower case, without spaces around them.
pub fn normalize_email(email: &str) -> Result<String> {
    let email = email.trim().to_lowercase();
    let valid = email.len() <= 254
        && !email.chars().any(char::is_whitespace)
        && email.split_once('@').is_some_and(|(user, domain)| !user.is_empty() && domain.contains('.') && !domain.starts_with('.') && !domain.ends_with('.'));
    if !valid {
        return Err(HubError::Invalid("Enter your email address, like name@example.com".into()));
    }
    Ok(email)
}

pub fn check_password(password: &str) -> Result<()> {
    let n = password.chars().count();
    if n < 8 {
        return Err(HubError::Invalid("Choose a password of at least 8 characters".into()));
    }
    if n > 200 {
        return Err(HubError::Invalid("That password is too long".into()));
    }
    Ok(())
}

async fn hash_password(password: &str) -> Result<String> {
    let password = password.to_owned();
    tokio::task::spawn_blocking(move || {
        let salt = SaltString::encode_b64(&rand::random::<[u8; 16]>()).map_err(|e| anyhow::anyhow!("{e}"))?;
        Ok::<_, anyhow::Error>(Argon2::default().hash_password(password.as_bytes(), &salt).map_err(|e| anyhow::anyhow!("{e}"))?.to_string())
    })
    .await
    .context("hashing stopped")?
    .map_err(HubError::Internal)
}

async fn password_matches(password: &str, stored: &str) -> bool {
    let (password, stored) = (password.to_owned(), stored.to_owned());
    tokio::task::spawn_blocking(move || {
        PasswordHash::new(&stored).is_ok_and(|h| Argon2::default().verify_password(password.as_bytes(), &h).is_ok())
    })
    .await
    .unwrap_or(false)
}

fn new_code() -> String {
    format!("{:06}", rand::random::<u32>() % 1_000_000)
}

/// NG Account sign-up, sign-in and everything else about accounts.
pub struct Accounts {
    hub: Arc<Hub>,
    mailer: Mailer,
    /// Codes emailed, per network and per address.
    codes_per_address: RateLimit,
    codes_per_email: RateLimit,
    /// Failed sign-ins per network.
    failures_per_address: RateLimit,
}

impl Accounts {
    pub fn new(hub: Arc<Hub>, mailer: Mailer) -> Accounts {
        Accounts {
            hub,
            mailer,
            codes_per_address: RateLimit::new(20),
            codes_per_email: RateLimit::new(5),
            failures_per_address: RateLimit::new(50),
        }
    }

    fn need_mail(&self) -> Result<()> {
        if self.mailer.enabled() {
            Ok(())
        } else {
            Err(HubError::Unavailable("NG Accounts are not available on this monitor yet".into()))
        }
    }

    async fn send_code(&self, email: &str, purpose: CodePurpose, address: &str, password_hash: Option<&str>) -> Result<()> {
        if !self.codes_per_address.allow(address) || !self.codes_per_email.allow(email) {
            return Err(HubError::TooMany("Too many codes asked for. Wait a while, then try again.".into()));
        }
        let code = new_code();
        self.hub.with_store(|s| s.put_code(email, purpose, &code, password_hash))?;
        if let Err(e) = self.mailer.send_code(email, purpose, &code).await {
            tracing::warn!("could not email a code: {e:#}");
            self.hub.with_store(|s| s.delete_code(email, purpose))?;
            return Err(HubError::Unavailable("The email could not be sent. Check the address, or try again later.".into()));
        }
        tracing::info!(purpose = purpose.as_str(), "emailed a code");
        Ok(())
    }

    /// Start making an account: email a code to finish with.
    pub async fn sign_up(&self, email: &str, password: &str, address: &str) -> Result<()> {
        self.need_mail()?;
        let email = normalize_email(email)?;
        check_password(password)?;
        if self.hub.with_store(|s| s.account_by_email(&email))?.is_some() {
            return Err(HubError::Refused("There's already an NG Account with that email. Sign in instead, or reset its password.".into()));
        }
        let password_hash = hash_password(password).await?;
        self.send_code(&email, CodePurpose::SignUp, address, Some(&password_hash)).await
    }

    /// Finish making an account with the emailed code; signs this install
    /// in.
    pub async fn verify_sign_up(&self, email: &str, code: &str, install: &Install) -> Result<SignedIn> {
        let email = normalize_email(email)?;
        let signed_in = {
            let hub = &self.hub;
            hub.with_store(|s| {
                let password_hash = match s.use_code(&email, CodePurpose::SignUp, code) {
                    Ok(Some(p)) => p,
                    Ok(None) => anyhow::bail!("a sign-up code without a password"),
                    Err(e) => return Ok(Err(e)),
                };
                if s.account_by_email(&email)?.is_some() {
                    return Ok(Err(HubError::Refused("There's already an NG Account with that email. Sign in instead.".into())));
                }
                // The install's monitors from before become the account's.
                let claimed = claimable(s, install)?;
                let owner = match &claimed {
                    Some(d) => d.id,
                    None => {
                        let push_key: [u8; 32] = rand::random();
                        let unused = hash(&B64URL.encode(rand::random::<[u8; 32]>()));
                        s.add_device(&format!("NG Account {email}"), &unused, &push_key, &crate::push::Prefs::default())?
                    }
                };
                let id = s.add_account(&email, &password_hash, owner)?;
                tracing::info!(account = id, owner, claimed = claimed.is_some(), "NG Account made");
                Ok(Ok(start_session(s, id, install)?))
            })??
        };
        self.hub.reconcile(true);
        Ok(signed_in)
    }

    pub async fn sign_in(&self, email: &str, password: &str, install: &Install, address: &str) -> Result<SignedIn> {
        let email = normalize_email(email)?;
        let wrong = || HubError::Unauthorized("That email and password don't match an NG Account".into());
        let account = self.hub.with_store(|s| s.account_by_email(&email))?;
        let Some(account) = account else {
            if !self.failures_per_address.allow(address) {
                return Err(HubError::TooMany("Too many tries. Wait a while, then try again.".into()));
            }
            return Err(wrong());
        };
        if account.locked_until > now_ms() {
            return Err(HubError::TooMany("Too many wrong passwords. Wait 15 minutes, or reset your password.".into()));
        }
        if !password_matches(password, &account.password_hash).await {
            self.hub.with_store(|s| s.login_failed(account.id))?;
            if !self.failures_per_address.allow(address) {
                return Err(HubError::TooMany("Too many tries. Wait a while, then try again.".into()));
            }
            return Err(wrong());
        }
        let signed_in = self.hub.with_store(|s| {
            s.login_succeeded(account.id)?;
            claim_into(s, &account, install)?;
            start_session(s, account.id, install)
        })?;
        tracing::info!(account = account.id, "signed in");
        self.hub.reconcile(true);
        Ok(signed_in)
    }

    /// Email a code to choose a new password with. Says the same whether
    /// or not there is an account, so nobody can find out who has one.
    pub async fn forgot_password(&self, email: &str, address: &str) -> Result<()> {
        self.need_mail()?;
        let email = normalize_email(email)?;
        if self.hub.with_store(|s| s.account_by_email(&email))?.is_none() {
            // Still counts against the limits, like a real request.
            let _ = self.codes_per_address.allow(address) && self.codes_per_email.allow(&email);
            return Ok(());
        }
        self.send_code(&email, CodePurpose::Reset, address, None).await
    }

    /// Choose a new password with the emailed code. Signs out every other
    /// install, and signs this one in.
    pub async fn reset_password(&self, email: &str, code: &str, password: &str, install: &Install) -> Result<SignedIn> {
        let email = normalize_email(email)?;
        check_password(password)?;
        let password_hash = hash_password(password).await?;
        let signed_in = self.hub.with_store(|s| {
            if let Err(e) = s.use_code(&email, CodePurpose::Reset, code) {
                return Ok(Err(e));
            }
            let Some(account) = s.account_by_email(&email)? else {
                return Ok(Err(HubError::NotFound("There's no NG Account with that email".into())));
            };
            s.set_password_hash(account.id, &password_hash)?;
            s.end_other_sessions(account.id, None)?;
            claim_into(s, &account, install)?;
            tracing::info!(account = account.id, "password reset");
            Ok(Ok(start_session(s, account.id, install)?))
        })??;
        self.hub.reconcile(true);
        Ok(signed_in)
    }

    pub async fn change_password(&self, session: &Session, current: &str, new: &str) -> Result<()> {
        check_password(new)?;
        let account = self.account(session.account)?;
        if !password_matches(current, &account.password_hash).await {
            return Err(HubError::Unauthorized("Your current password isn't right".into()));
        }
        let password_hash = hash_password(new).await?;
        self.hub.with_store(|s| {
            s.set_password_hash(account.id, &password_hash)?;
            s.end_other_sessions(account.id, Some(session.id))
        })?;
        tracing::info!(account = account.id, "password changed");
        Ok(())
    }

    pub fn account(&self, id: i64) -> Result<Account> {
        self.hub.with_store(|s| s.account(id))?.ok_or_else(|| HubError::Unauthorized("That NG Account no longer exists".into()))
    }

    pub fn sessions(&self, account: i64) -> Result<Vec<Session>> {
        self.hub.with_store(|s| s.sessions(account))
    }

    pub fn end_session(&self, account: i64, session: i64) -> Result<()> {
        if !self.hub.with_store(|s| s.end_session(account, session))? {
            return Err(HubError::NotFound("That device is already signed out".into()));
        }
        Ok(())
    }

    /// Delete an account and everything only it has. Its public sound
    /// packs stay, under the name they were published with.
    pub async fn delete(&self, session: &Session, password: &str) -> Result<()> {
        let account = self.account(session.account)?;
        if !password_matches(password, &account.password_hash).await {
            return Err(HubError::Unauthorized("That password isn't right".into()));
        }
        self.hub.with_store(|s| s.delete_account(&account))?;
        tracing::info!(account = account.id, "NG Account deleted");
        self.hub.reconcile(true);
        Ok(())
    }

    /// Who is behind a session token.
    pub fn authenticate(&self, token: &str) -> Option<(Session, Device)> {
        self.hub.authenticate_session(token)
    }
}

/// The sign-up an install brings with it, if it may become an account's:
/// the token must be right, and it must not be another account's already.
fn claimable(s: &Store, install: &Install) -> anyhow::Result<Option<Device>> {
    let Some(token) = install.claim_token.as_deref().filter(|t| !t.is_empty()) else {
        return Ok(None);
    };
    let Some(d) = s.device_by_token(&hash(token))? else {
        return Ok(None);
    };
    if s.account_of_owner(d.id)?.is_some() {
        return Ok(None);
    }
    Ok(Some(d))
}

/// Move what an install monitored before signing in into the account.
fn claim_into(s: &Store, account: &Account, install: &Install) -> anyhow::Result<()> {
    if let Some(d) = claimable(s, install)?
        && d.id != account.owner
    {
        s.merge_devices(account.owner, d.id)?;
        tracing::info!(account = account.id, from = d.id, "merged a sign-up into an NG Account");
    }
    Ok(())
}

fn start_session(s: &Store, account: i64, install: &Install) -> anyhow::Result<SignedIn> {
    let token = B64URL.encode(rand::random::<[u8; 32]>());
    let session_id = s.add_session(account, &hash(&token), install)?;
    let account = s.account(account)?.context("the account just signed in to is gone")?;
    let device = s.device(account.owner)?.into_iter().next().context("the account's sign-up is gone")?;
    s.wake_device(device.id)?;
    Ok(SignedIn { token, session_id, device_id: device.id, push_key: B64.encode(&device.push_key), account })
}
