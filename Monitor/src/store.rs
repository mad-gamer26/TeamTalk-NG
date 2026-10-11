//! The monitor's SQLite database: the app installs using it (devices), the
//! servers each one monitors, the event log and private-message history.
//! Every server belongs to one device, and reads are limited to a device's
//! own servers.

use std::path::Path;

use anyhow::Context;
use rusqlite::{Connection, OptionalExtension, params};
use serde::{Deserialize, Serialize};

use crate::push::Prefs;
use crate::tt::state::Event;

/// Events kept per server; older ones are deleted.
const EVENTS_KEPT_PER_SERVER: i64 = 5000;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct ServerConfig {
    #[serde(default)]
    pub id: i64,
    /// The device that monitors this server.
    #[serde(default, skip_serializing)]
    pub owner: i64,
    pub name: String,
    pub host: String,
    #[serde(default = "default_port")]
    pub tcp_port: u16,
    #[serde(default)]
    pub encrypted: bool,
    #[serde(default)]
    pub nickname: String,
    #[serde(default)]
    pub username: String,
    /// Never sent to the app.
    #[serde(default, skip_serializing)]
    pub password: String,
    #[serde(default)]
    pub status_msg: String,
    /// The monitor's gender, as TeamTalk status mode bits (female 256,
    /// neutral 4096; neither is male).
    #[serde(default)]
    pub status_mode: i64,
    #[serde(default)]
    pub channel: String,
    #[serde(default, skip_serializing)]
    pub channel_password: String,
    #[serde(default = "yes")]
    pub enabled: bool,
}

fn default_port() -> u16 {
    10333
}

fn yes() -> bool {
    true
}

/// A TeamTalk NG sign-up (called a device for history's sake): it owns its
/// monitored servers. The app keeps it in iCloud Keychain, so every iPhone
/// of the same person shares it; each one registers for pushes on its own
/// (`PushTarget`).
#[derive(Debug, Clone, Serialize)]
pub struct Device {
    pub id: i64,
    pub name: String,
    #[serde(skip)]
    pub push_key: Vec<u8>,
    pub has_push: bool,
    pub prefs: Prefs,
    pub created: i64,
    /// When the app last made contact (Unix ms).
    pub last_seen: i64,
    /// Not heard from for a long time: its servers are not monitored until
    /// the app is back.
    pub dormant: bool,
}

/// One installed copy of the app that gets this sign-up's pushes.
#[derive(Debug, Clone, Serialize)]
pub struct PushTarget {
    pub install_id: String,
    pub apns_token: String,
    pub sandbox: bool,
    /// Sent back in every push so the app knows which key opens it.
    pub app_ref: String,
}

/// What a sweep for abandoned sign-ups did.
#[derive(Debug, Default, PartialEq)]
pub struct Sweep {
    pub dormant: Vec<i64>,
    pub deleted: Vec<i64>,
}

/// When sign-ups the app has stopped contacting go dormant and are deleted.
#[derive(Debug, Clone, Copy)]
pub struct Retention {
    /// No contact for this long: dormant.
    pub dormant_after_ms: i64,
    /// Apple says every copy of the app was uninstalled, and no contact for
    /// this long: dormant.
    pub uninstalled_dormant_after_ms: i64,
    /// No contact for this long: deleted, with its servers and messages.
    pub delete_after_ms: i64,
}

const DAY_MS: i64 = 24 * 60 * 60 * 1000;

/// How often each phone gets the silent check that the app is installed.
pub const PHONE_CHECK_EVERY_MS: i64 = DAY_MS;

impl Default for Retention {
    fn default() -> Self {
        Retention { dormant_after_ms: 14 * DAY_MS, uninstalled_dormant_after_ms: DAY_MS, delete_after_ms: 180 * DAY_MS }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct StoredEvent {
    pub seq: i64,
    pub server_id: i64,
    /// Unix time in milliseconds.
    pub time: i64,
    pub event: Event,
}

/// A private conversation, as in TeamTalk: with one user ID for as long as
/// that person stays logged in. When they log out it ends; their next login
/// (a new user ID, or the same ID after a server restart) is a new one.
#[derive(Debug, Clone, Serialize)]
pub struct Conversation {
    pub id: i64,
    pub server_id: i64,
    pub user_id: i64,
    /// The person's nickname as last seen.
    pub nickname: String,
    pub username: String,
    /// Still logged in with this user ID, so replies reach them.
    pub active: bool,
    pub last_text: String,
    pub last_time: i64,
    pub last_outgoing: bool,
    pub unread: i64,
}

#[derive(Debug, Clone, Serialize)]
pub struct PrivateMessage {
    pub id: i64,
    pub conversation_id: i64,
    pub server_id: i64,
    pub outgoing: bool,
    pub text: String,
    pub time: i64,
    pub read: bool,
}

pub fn now_ms() -> i64 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_millis() as i64).unwrap_or(0)
}

pub struct Store {
    db: Connection,
}

impl Store {
    pub fn open(path: &Path) -> anyhow::Result<Store> {
        if let Some(dir) = path.parent() {
            std::fs::create_dir_all(dir).ok();
        }
        let db = Connection::open(path).with_context(|| format!("Could not open {}", path.display()))?;
        Self::setup(db)
    }

    #[cfg(test)]
    pub fn memory() -> Store {
        Self::setup(Connection::open_in_memory().unwrap()).unwrap()
    }

    fn setup(db: Connection) -> anyhow::Result<Store> {
        db.busy_timeout(std::time::Duration::from_secs(5))?;
        db.pragma_update(None, "journal_mode", "WAL")?;
        db.execute_batch(
            r#"
            CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
            -- AUTOINCREMENT: IDs of removed servers and installs are never
            -- given out again, so nothing old can point at someone new.
            CREATE TABLE IF NOT EXISTS servers (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                name TEXT NOT NULL,
                host TEXT NOT NULL,
                tcp_port INTEGER NOT NULL,
                encrypted INTEGER NOT NULL,
                nickname TEXT NOT NULL,
                username TEXT NOT NULL,
                password TEXT NOT NULL,
                status_msg TEXT NOT NULL,
                channel TEXT NOT NULL,
                channel_password TEXT NOT NULL,
                enabled INTEGER NOT NULL
            );
            CREATE TABLE IF NOT EXISTS devices (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                name TEXT NOT NULL,
                token_hash TEXT NOT NULL UNIQUE,
                push_key BLOB NOT NULL,
                apns_token TEXT,
                apns_sandbox INTEGER NOT NULL DEFAULT 0,
                prefs TEXT NOT NULL,
                created INTEGER NOT NULL,
                last_seen INTEGER NOT NULL
            );
            CREATE TABLE IF NOT EXISTS events (
                seq INTEGER PRIMARY KEY,
                server_id INTEGER NOT NULL,
                time INTEGER NOT NULL,
                event TEXT NOT NULL
            );
            CREATE INDEX IF NOT EXISTS events_server ON events (server_id, seq);
            CREATE TABLE IF NOT EXISTS conversations (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                server_id INTEGER NOT NULL,
                user_id INTEGER NOT NULL,
                nickname TEXT NOT NULL,
                username TEXT NOT NULL,
                started INTEGER NOT NULL,
                active INTEGER NOT NULL
            );
            CREATE INDEX IF NOT EXISTS conversations_user ON conversations (server_id, user_id, active);
            "#,
        )?;
        // Messages were once kept by name; that history cannot be tied to
        // user IDs, so it starts over.
        if db.prepare("SELECT peer FROM messages LIMIT 0").is_ok() {
            db.execute_batch("DROP TABLE messages")?;
        }
        db.execute_batch(
            r#"
            CREATE TABLE IF NOT EXISTS messages (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                conversation_id INTEGER NOT NULL,
                server_id INTEGER NOT NULL,
                outgoing INTEGER NOT NULL,
                text TEXT NOT NULL,
                time INTEGER NOT NULL,
                read INTEGER NOT NULL
            );
            CREATE INDEX IF NOT EXISTS messages_conversation ON messages (conversation_id, id);
            "#,
        )?;
        // Columns added after the first release.
        let has_app_ref = db.prepare("SELECT app_ref FROM devices LIMIT 0").is_ok();
        if !has_app_ref {
            db.execute_batch("ALTER TABLE devices ADD COLUMN app_ref TEXT NOT NULL DEFAULT ''")?;
        }
        if db.prepare("SELECT owner FROM servers LIMIT 0").is_err() {
            db.execute_batch("ALTER TABLE servers ADD COLUMN owner INTEGER NOT NULL DEFAULT 0")?;
        }
        db.execute_batch("CREATE INDEX IF NOT EXISTS servers_owner ON servers (owner)")?;
        if db.prepare("SELECT status_mode FROM servers LIMIT 0").is_err() {
            db.execute_batch("ALTER TABLE servers ADD COLUMN status_mode INTEGER NOT NULL DEFAULT 0")?;
        }
        if db.prepare("SELECT dormant_since FROM devices LIMIT 0").is_err() {
            db.execute_batch("ALTER TABLE devices ADD COLUMN dormant_since INTEGER")?;
        }
        db.execute_batch(
            r#"
            CREATE TABLE IF NOT EXISTS push_targets (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                device_id INTEGER NOT NULL,
                install_id TEXT NOT NULL,
                app_ref TEXT NOT NULL,
                apns_token TEXT NOT NULL,
                sandbox INTEGER NOT NULL,
                updated INTEGER NOT NULL,
                -- When Apple said the token no longer works (the app was
                -- uninstalled); NULL while it works.
                gone_at INTEGER,
                UNIQUE (device_id, install_id)
            );
            "#,
        )?;
        if db.prepare("SELECT checked FROM push_targets LIMIT 0").is_err() {
            db.execute_batch("ALTER TABLE push_targets ADD COLUMN checked INTEGER NOT NULL DEFAULT 0")?;
        }
        // Push registrations once lived on the device row.
        db.execute(
            "INSERT OR IGNORE INTO push_targets (device_id, install_id, app_ref, apns_token, sandbox, updated)
             SELECT id, app_ref, app_ref, apns_token, apns_sandbox, last_seen FROM devices WHERE apns_token IS NOT NULL",
            [],
        )?;
        db.execute("UPDATE devices SET apns_token = NULL WHERE apns_token IS NOT NULL", [])?;
        Ok(Store { db })
    }

    // Change counter for servers, so a running monitor sees edits made
    // from the command line.

    pub fn servers_version(&self) -> anyhow::Result<i64> {
        Ok(self
            .db
            .query_row("SELECT value FROM meta WHERE key = 'servers_version'", [], |r| r.get::<_, String>(0))
            .optional()?
            .and_then(|v| v.parse().ok())
            .unwrap_or(0))
    }

    fn bump_servers_version(&self) -> anyhow::Result<()> {
        let v = self.servers_version()? + 1;
        self.db.execute("INSERT INTO meta (key, value) VALUES ('servers_version', ?1) ON CONFLICT(key) DO UPDATE SET value = ?1", [v.to_string()])?;
        Ok(())
    }

    // Servers

    pub fn servers(&self) -> anyhow::Result<Vec<ServerConfig>> {
        self.query_servers(None)
    }

    /// The servers one device monitors.
    pub fn servers_of(&self, owner: i64) -> anyhow::Result<Vec<ServerConfig>> {
        self.query_servers(Some(owner))
    }

    pub fn count_servers(&self, owner: Option<i64>) -> anyhow::Result<i64> {
        Ok(self.db.query_row("SELECT COUNT(*) FROM servers WHERE ?1 IS NULL OR owner = ?1", [owner], |r| r.get(0))?)
    }

    fn query_servers(&self, owner: Option<i64>) -> anyhow::Result<Vec<ServerConfig>> {
        let mut st = self.db.prepare(
            "SELECT id, name, host, tcp_port, encrypted, nickname, username, password, status_msg, channel, channel_password, enabled, owner, status_mode FROM servers WHERE ?1 IS NULL OR owner = ?1 ORDER BY id",
        )?;
        let rows = st.query_map([owner], |r| {
            Ok(ServerConfig {
                id: r.get(0)?,
                name: r.get(1)?,
                host: r.get(2)?,
                tcp_port: r.get(3)?,
                encrypted: r.get(4)?,
                nickname: r.get(5)?,
                username: r.get(6)?,
                password: r.get(7)?,
                status_msg: r.get(8)?,
                channel: r.get(9)?,
                channel_password: r.get(10)?,
                enabled: r.get(11)?,
                owner: r.get(12)?,
                status_mode: r.get(13)?,
            })
        })?;
        Ok(rows.collect::<Result<_, _>>()?)
    }

    pub fn server(&self, id: i64) -> anyhow::Result<Option<ServerConfig>> {
        Ok(self.servers()?.into_iter().find(|s| s.id == id))
    }

    pub fn add_server(&self, s: &ServerConfig) -> anyhow::Result<i64> {
        self.db.execute(
            "INSERT INTO servers (name, host, tcp_port, encrypted, nickname, username, password, status_msg, channel, channel_password, enabled, owner, status_mode) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13)",
            params![s.name, s.host, s.tcp_port, s.encrypted, s.nickname, s.username, s.password, s.status_msg, s.channel, s.channel_password, s.enabled, s.owner, s.status_mode],
        )?;
        let id = self.db.last_insert_rowid();
        self.bump_servers_version()?;
        Ok(id)
    }

    pub fn set_nickname(&self, id: i64, nickname: &str) -> anyhow::Result<()> {
        self.db.execute("UPDATE servers SET nickname = ?2 WHERE id = ?1", params![id, nickname])?;
        self.bump_servers_version()?;
        Ok(())
    }

    pub fn set_status(&self, id: i64, status_mode: i64, status_msg: &str) -> anyhow::Result<()> {
        self.db.execute("UPDATE servers SET status_mode = ?2, status_msg = ?3 WHERE id = ?1", params![id, status_mode, status_msg])?;
        self.bump_servers_version()?;
        Ok(())
    }

    pub fn update_server(&self, s: &ServerConfig) -> anyhow::Result<bool> {
        let n = self.db.execute(
            "UPDATE servers SET name = ?2, host = ?3, tcp_port = ?4, encrypted = ?5, nickname = ?6, username = ?7, password = ?8, status_msg = ?9, channel = ?10, channel_password = ?11, enabled = ?12, status_mode = ?13 WHERE id = ?1",
            params![s.id, s.name, s.host, s.tcp_port, s.encrypted, s.nickname, s.username, s.password, s.status_msg, s.channel, s.channel_password, s.enabled, s.status_mode],
        )?;
        self.bump_servers_version()?;
        Ok(n > 0)
    }

    pub fn remove_server(&self, id: i64) -> anyhow::Result<bool> {
        let n = self.db.execute("DELETE FROM servers WHERE id = ?1", [id])?;
        self.db.execute("DELETE FROM events WHERE server_id = ?1", [id])?;
        self.db.execute("DELETE FROM messages WHERE server_id = ?1", [id])?;
        self.db.execute("DELETE FROM conversations WHERE server_id = ?1", [id])?;
        self.bump_servers_version()?;
        Ok(n > 0)
    }

    // Devices

    pub fn add_device(&self, name: &str, token_hash: &str, push_key: &[u8], prefs: &Prefs) -> anyhow::Result<i64> {
        let now = now_ms();
        self.db.execute(
            "INSERT INTO devices (name, token_hash, push_key, prefs, created, last_seen) VALUES (?1, ?2, ?3, ?4, ?5, ?5)",
            params![name, token_hash, push_key, serde_json::to_string(prefs)?, now],
        )?;
        Ok(self.db.last_insert_rowid())
    }

    fn device_row(r: &rusqlite::Row) -> rusqlite::Result<Device> {
        let prefs: String = r.get(3)?;
        Ok(Device {
            id: r.get(0)?,
            name: r.get(1)?,
            push_key: r.get(2)?,
            prefs: serde_json::from_str(&prefs).unwrap_or_default(),
            created: r.get(4)?,
            last_seen: r.get(5)?,
            dormant: r.get::<_, Option<i64>>(6)?.is_some(),
            has_push: r.get(7)?,
        })
    }

    const DEVICE_COLUMNS: &str = "id, name, push_key, prefs, created, last_seen, dormant_since, \
        EXISTS (SELECT 1 FROM push_targets t WHERE t.device_id = devices.id AND t.gone_at IS NULL)";

    pub fn device_by_token(&self, token_hash: &str) -> anyhow::Result<Option<Device>> {
        let sql = format!("SELECT {} FROM devices WHERE token_hash = ?1", Self::DEVICE_COLUMNS);
        Ok(self.db.query_row(&sql, [token_hash], Self::device_row).optional()?)
    }

    /// One device, as a list of zero or one.
    pub fn device(&self, id: i64) -> anyhow::Result<Vec<Device>> {
        let sql = format!("SELECT {} FROM devices WHERE id = ?1", Self::DEVICE_COLUMNS);
        let mut st = self.db.prepare(&sql)?;
        let rows = st.query_map([id], Self::device_row)?;
        Ok(rows.collect::<Result<_, _>>()?)
    }

    pub fn devices(&self) -> anyhow::Result<Vec<Device>> {
        let sql = format!("SELECT {} FROM devices ORDER BY id", Self::DEVICE_COLUMNS);
        let mut st = self.db.prepare(&sql)?;
        let rows = st.query_map([], Self::device_row)?;
        Ok(rows.collect::<Result<_, _>>()?)
    }

    pub fn touch_device(&self, id: i64) -> anyhow::Result<()> {
        self.touch_device_at(id, now_ms())
    }

    pub fn touch_device_at(&self, id: i64, now: i64) -> anyhow::Result<()> {
        self.db.execute("UPDATE devices SET last_seen = ?2 WHERE id = ?1", params![id, now])?;
        Ok(())
    }

    /// Register (or, with no token, unregister) one installed copy of the
    /// app for pushes.
    pub fn set_push_target(&self, device_id: i64, install_id: &str, apns_token: Option<&str>, sandbox: bool, app_ref: &str) -> anyhow::Result<()> {
        match apns_token {
            None => {
                self.db.execute("DELETE FROM push_targets WHERE device_id = ?1 AND install_id = ?2", params![device_id, install_id])?;
            }
            Some(token) => {
                // A token is one copy of the app; anything else holding it is stale.
                self.db.execute(
                    "DELETE FROM push_targets WHERE apns_token = ?1 AND NOT (device_id = ?2 AND install_id = ?3)",
                    params![token, device_id, install_id],
                )?;
                self.db.execute(
                    "INSERT INTO push_targets (device_id, install_id, app_ref, apns_token, sandbox, updated, gone_at) VALUES (?1, ?2, ?3, ?4, ?5, ?6, NULL)
                     ON CONFLICT (device_id, install_id) DO UPDATE SET app_ref = ?3, apns_token = ?4, sandbox = ?5, updated = ?6, gone_at = NULL",
                    params![device_id, install_id, app_ref, token, sandbox, now_ms()],
                )?;
            }
        }
        Ok(())
    }

    /// The copies of the app to push to.
    pub fn push_targets(&self, device_id: i64) -> anyhow::Result<Vec<PushTarget>> {
        let mut st = self.db.prepare("SELECT install_id, apns_token, sandbox, app_ref FROM push_targets WHERE device_id = ?1 AND gone_at IS NULL ORDER BY id")?;
        let rows = st.query_map([device_id], |r| Ok(PushTarget { install_id: r.get(0)?, apns_token: r.get(1)?, sandbox: r.get(2)?, app_ref: r.get(3)? }))?;
        Ok(rows.collect::<Result<_, _>>()?)
    }

    /// Phones not checked for `every` (silent push), marked as checked now.
    pub fn push_targets_due(&self, now: i64, every: i64) -> anyhow::Result<Vec<PushTarget>> {
        let due: Vec<PushTarget> = {
            let mut st = self.db.prepare(
                "SELECT install_id, apns_token, sandbox, app_ref FROM push_targets WHERE gone_at IS NULL AND checked <= ?1 ORDER BY id",
            )?;
            st.query_map([now - every], |r| Ok(PushTarget { install_id: r.get(0)?, apns_token: r.get(1)?, sandbox: r.get(2)?, app_ref: r.get(3)? }))?
                .collect::<Result<_, _>>()?
        };
        self.db.execute("UPDATE push_targets SET checked = ?1 WHERE gone_at IS NULL AND checked <= ?2", params![now, now - every])?;
        Ok(due)
    }

    /// Apple says a token no longer works: that copy of the app is gone.
    pub fn drop_apns_token(&self, apns_token: &str) -> anyhow::Result<()> {
        self.db.execute("UPDATE push_targets SET gone_at = ?2 WHERE apns_token = ?1 AND gone_at IS NULL", params![apns_token, now_ms()])?;
        Ok(())
    }

    /// Move everything of sign-up `from` (servers with their events and
    /// conversations, and its phones) to `into`, and delete `from`. Two
    /// sign-ups of one person (an iPhone that signed up before iCloud
    /// Keychain brought the first) become one.
    pub fn merge_devices(&self, into: i64, from: i64) -> anyhow::Result<()> {
        if into == from {
            return Ok(());
        }
        self.db.execute("UPDATE servers SET owner = ?1 WHERE owner = ?2", params![into, from])?;
        // The same copy of the app registered with both: keep the newer.
        self.db.execute(
            "DELETE FROM push_targets WHERE device_id = ?1 AND install_id IN (SELECT install_id FROM push_targets WHERE device_id = ?2)",
            params![into, from],
        )?;
        self.db.execute("UPDATE push_targets SET device_id = ?1 WHERE device_id = ?2", params![into, from])?;
        self.db.execute("DELETE FROM devices WHERE id = ?1", [from])?;
        self.db.execute("UPDATE devices SET last_seen = MAX(last_seen, ?2), dormant_since = NULL WHERE id = ?1", params![into, now_ms()])?;
        self.bump_servers_version()?;
        Ok(())
    }

    /// Sign-ups whose servers are not monitored for now.
    pub fn dormant_devices(&self) -> anyhow::Result<Vec<i64>> {
        let mut st = self.db.prepare("SELECT id FROM devices WHERE dormant_since IS NOT NULL")?;
        let rows = st.query_map([], |r| r.get(0))?;
        Ok(rows.collect::<Result<_, _>>()?)
    }

    /// The app is back: monitor this sign-up's servers again.
    pub fn wake_device(&self, id: i64) -> anyhow::Result<bool> {
        let n = self.db.execute("UPDATE devices SET dormant_since = NULL WHERE id = ?1 AND dormant_since IS NOT NULL", [id])?;
        if n > 0 {
            self.bump_servers_version()?;
        }
        Ok(n > 0)
    }

    /// Put to sleep the sign-ups the app has stopped contacting, and
    /// delete the ones abandoned for good.
    pub fn sweep(&self, now: i64, r: Retention) -> anyhow::Result<Sweep> {
        let mut out = Sweep::default();
        {
            let mut st = self.db.prepare("SELECT id FROM devices WHERE last_seen < ?1 ORDER BY id")?;
            out.deleted = st.query_map([now - r.delete_after_ms], |r| r.get(0))?.collect::<Result<_, _>>()?;
        }
        for id in &out.deleted {
            self.remove_device(*id)?;
            self.db.execute("DELETE FROM push_targets WHERE device_id = ?1", [id])?;
        }
        {
            let mut st = self.db.prepare(
                "SELECT d.id FROM devices d WHERE d.dormant_since IS NULL AND (
                    d.last_seen < ?1
                    OR (d.last_seen < ?2
                        AND EXISTS (SELECT 1 FROM push_targets t WHERE t.device_id = d.id)
                        AND NOT EXISTS (SELECT 1 FROM push_targets t WHERE t.device_id = d.id AND t.gone_at IS NULL)))
                 ORDER BY d.id",
            )?;
            out.dormant = st
                .query_map(params![now - r.dormant_after_ms, now - r.uninstalled_dormant_after_ms], |r| r.get(0))?
                .collect::<Result<_, _>>()?;
        }
        for id in &out.dormant {
            self.db.execute("UPDATE devices SET dormant_since = ?2 WHERE id = ?1", params![id, now])?;
        }
        if !out.dormant.is_empty() || !out.deleted.is_empty() {
            self.bump_servers_version()?;
        }
        Ok(out)
    }

    pub fn set_device_prefs(&self, id: i64, prefs: &Prefs) -> anyhow::Result<()> {
        self.db.execute("UPDATE devices SET prefs = ?2 WHERE id = ?1", params![id, serde_json::to_string(prefs)?])?;
        Ok(())
    }

    pub fn rename_device(&self, id: i64, name: &str) -> anyhow::Result<()> {
        self.db.execute("UPDATE devices SET name = ?2 WHERE id = ?1", params![id, name])?;
        Ok(())
    }

    /// Forget a device and everything it monitored.
    pub fn remove_device(&self, id: i64) -> anyhow::Result<bool> {
        for s in self.servers_of(id)? {
            self.remove_server(s.id)?;
        }
        Ok(self.db.execute("DELETE FROM devices WHERE id = ?1", [id])? > 0)
    }

    pub fn count_devices(&self) -> anyhow::Result<i64> {
        Ok(self.db.query_row("SELECT COUNT(*) FROM devices", [], |r| r.get(0))?)
    }

    // Events

    pub fn last_seq(&self) -> anyhow::Result<i64> {
        Ok(self.db.query_row("SELECT COALESCE(MAX(seq), 0) FROM events", [], |r| r.get(0))?)
    }

    pub fn first_seq(&self) -> anyhow::Result<i64> {
        Ok(self.db.query_row("SELECT COALESCE(MIN(seq), 0) FROM events", [], |r| r.get(0))?)
    }

    pub fn add_event(&self, e: &StoredEvent) -> anyhow::Result<()> {
        self.db.execute(
            "INSERT INTO events (seq, server_id, time, event) VALUES (?1, ?2, ?3, ?4)",
            params![e.seq, e.server_id, e.time, serde_json::to_string(&e.event)?],
        )?;
        // Trim now and then rather than on every event.
        if e.seq % 200 == 0 {
            self.db.execute(
                "DELETE FROM events WHERE server_id = ?1 AND seq <= (SELECT seq FROM events WHERE server_id = ?1 ORDER BY seq DESC LIMIT 1 OFFSET ?2)",
                params![e.server_id, EVENTS_KEPT_PER_SERVER],
            )?;
        }
        Ok(())
    }

    /// Events after `since`, oldest first, from one device's servers (or
    /// one of them).
    pub fn events_since(&self, since: i64, owner: i64, server_id: Option<i64>, limit: i64) -> anyhow::Result<Vec<StoredEvent>> {
        let mut st = self.db.prepare(
            "SELECT seq, server_id, time, event FROM events WHERE seq > ?1 AND (?2 IS NULL OR server_id = ?2) AND server_id IN (SELECT id FROM servers WHERE owner = ?4) ORDER BY seq LIMIT ?3",
        )?;
        let rows = st.query_map(params![since, server_id, limit, owner], |r| {
            let json: String = r.get(3)?;
            Ok((r.get(0)?, r.get(1)?, r.get(2)?, json))
        })?;
        let mut out = Vec::new();
        for row in rows {
            let (seq, server_id, time, json) = row?;
            if let Ok(event) = serde_json::from_str(&json) {
                out.push(StoredEvent { seq, server_id, time, event });
            }
        }
        Ok(out)
    }

    /// The most recent events from one device's servers, newest last.
    pub fn recent_events(&self, owner: i64, server_id: Option<i64>, limit: i64) -> anyhow::Result<Vec<StoredEvent>> {
        let since: i64 = self.db.query_row(
            "SELECT COALESCE(MIN(seq) - 1, 0) FROM (SELECT seq FROM events WHERE (?1 IS NULL OR server_id = ?1) AND server_id IN (SELECT id FROM servers WHERE owner = ?3) ORDER BY seq DESC LIMIT ?2)",
            params![server_id, limit, owner],
            |r| r.get(0),
        )?;
        self.events_since(since, owner, server_id, limit)
    }

    // Private messages

    /// The conversation with whoever has `user_id` now, started if there is
    /// none. A conversation with a different account under that ID (the ID
    /// was given out again) is ended first.
    pub fn conversation_for(&self, server_id: i64, user_id: i64, nickname: &str, username: &str, now: i64) -> anyhow::Result<i64> {
        let open: Option<(i64, String)> = self
            .db
            .query_row(
                "SELECT id, username FROM conversations WHERE server_id = ?1 AND user_id = ?2 AND active = 1 ORDER BY id DESC LIMIT 1",
                params![server_id, user_id],
                |r| Ok((r.get(0)?, r.get(1)?)),
            )
            .optional()?;
        if let Some((id, existing)) = open {
            if existing == username {
                self.db.execute("UPDATE conversations SET nickname = ?2 WHERE id = ?1", params![id, nickname])?;
                return Ok(id);
            }
            self.db.execute("UPDATE conversations SET active = 0 WHERE id = ?1", [id])?;
        }
        self.db.execute(
            "INSERT INTO conversations (server_id, user_id, nickname, username, started, active) VALUES (?1, ?2, ?3, ?4, ?5, 1)",
            params![server_id, user_id, nickname, username, now],
        )?;
        Ok(self.db.last_insert_rowid())
    }

    /// The person logged out: their conversation ends.
    pub fn end_conversation(&self, server_id: i64, user_id: i64) -> anyhow::Result<()> {
        self.db.execute("UPDATE conversations SET active = 0 WHERE server_id = ?1 AND user_id = ?2 AND active = 1", params![server_id, user_id])?;
        Ok(())
    }

    /// After the monitor logs in again: conversations whose user ID is no
    /// longer the same person (gone, or someone else) end.
    pub fn keep_conversations(&self, server_id: i64, present: &[(i64, String)]) -> anyhow::Result<()> {
        let open: Vec<(i64, i64, String)> = {
            let mut st = self.db.prepare("SELECT id, user_id, username FROM conversations WHERE server_id = ?1 AND active = 1")?;
            st.query_map([server_id], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))?.collect::<Result<_, _>>()?
        };
        for (id, user_id, username) in open {
            if !present.iter().any(|(u, name)| *u == user_id && *name == username) {
                self.db.execute("UPDATE conversations SET active = 0 WHERE id = ?1", [id])?;
            }
        }
        Ok(())
    }

    /// The active conversation with a user ID, if any.
    pub fn active_conversation(&self, server_id: i64, user_id: i64) -> anyhow::Result<Option<i64>> {
        Ok(self
            .db
            .query_row("SELECT id FROM conversations WHERE server_id = ?1 AND user_id = ?2 AND active = 1", params![server_id, user_id], |r| r.get(0))
            .optional()?)
    }

    pub fn conversation(&self, id: i64) -> anyhow::Result<Option<Conversation>> {
        Ok(self.query_conversations("c.id = ?1", params![id])?.into_iter().next())
    }

    pub fn add_message(&self, conversation_id: i64, server_id: i64, outgoing: bool, text: &str, time: i64) -> anyhow::Result<PrivateMessage> {
        self.db.execute(
            "INSERT INTO messages (conversation_id, server_id, outgoing, text, time, read) VALUES (?1, ?2, ?3, ?4, ?5, ?3)",
            params![conversation_id, server_id, outgoing, text, time],
        )?;
        Ok(PrivateMessage { id: self.db.last_insert_rowid(), conversation_id, server_id, outgoing, text: text.to_owned(), time, read: outgoing })
    }

    /// Conversations with messages on one device's servers (or one of
    /// them), most recent first.
    pub fn conversations(&self, owner: i64, server_id: Option<i64>) -> anyhow::Result<Vec<Conversation>> {
        self.query_conversations(
            "(?1 IS NULL OR c.server_id = ?1) AND c.server_id IN (SELECT id FROM servers WHERE owner = ?2)",
            params![server_id, owner],
        )
    }

    fn query_conversations(&self, filter: &str, args: &[&dyn rusqlite::ToSql]) -> anyhow::Result<Vec<Conversation>> {
        let sql = format!(
            r#"SELECT c.id, c.server_id, c.user_id, c.nickname, c.username, c.active, m.text, m.time, m.outgoing,
                      (SELECT COUNT(*) FROM messages u WHERE u.conversation_id = c.id AND u.read = 0)
               FROM conversations c
               JOIN messages m ON m.id = (SELECT MAX(id) FROM messages WHERE conversation_id = c.id)
               WHERE {filter}
               ORDER BY m.id DESC"#
        );
        let mut st = self.db.prepare(&sql)?;
        let rows = st.query_map(args, |r| {
            Ok(Conversation {
                id: r.get(0)?,
                server_id: r.get(1)?,
                user_id: r.get(2)?,
                nickname: r.get(3)?,
                username: r.get(4)?,
                active: r.get(5)?,
                last_text: r.get(6)?,
                last_time: r.get(7)?,
                last_outgoing: r.get(8)?,
                unread: r.get(9)?,
            })
        })?;
        Ok(rows.collect::<Result<_, _>>()?)
    }

    /// A conversation's messages, oldest first, before message `before`.
    pub fn messages(&self, conversation_id: i64, before: Option<i64>, limit: i64) -> anyhow::Result<Vec<PrivateMessage>> {
        let mut st = self.db.prepare(
            "SELECT id, conversation_id, server_id, outgoing, text, time, read FROM messages WHERE conversation_id = ?1 AND id < ?2 ORDER BY id DESC LIMIT ?3",
        )?;
        let rows = st.query_map(params![conversation_id, before.unwrap_or(i64::MAX), limit], |r| {
            Ok(PrivateMessage {
                id: r.get(0)?,
                conversation_id: r.get(1)?,
                server_id: r.get(2)?,
                outgoing: r.get(3)?,
                text: r.get(4)?,
                time: r.get(5)?,
                read: r.get(6)?,
            })
        })?;
        let mut out: Vec<_> = rows.collect::<Result<_, _>>()?;
        out.reverse();
        Ok(out)
    }

    /// Delete a conversation and its messages. If the person is still
    /// logged in and writes again, that starts a new conversation.
    pub fn delete_conversation(&self, conversation_id: i64) -> anyhow::Result<bool> {
        self.db.execute("DELETE FROM messages WHERE conversation_id = ?1", [conversation_id])?;
        Ok(self.db.execute("DELETE FROM conversations WHERE id = ?1", [conversation_id])? > 0)
    }

    pub fn mark_read(&self, conversation_id: i64) -> anyhow::Result<()> {
        self.db.execute("UPDATE messages SET read = 1 WHERE conversation_id = ?1", [conversation_id])?;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::tt::state::ConnectionStatus;

    #[test]
    fn servers_round_trip_and_bump_version() {
        let st = Store::memory();
        let mut s = ServerConfig {
            id: 0,
            owner: 1,
            name: "Home".into(),
            host: "tt.example.com".into(),
            tcp_port: 10333,
            encrypted: false,
            nickname: "Mon".into(),
            username: "mon".into(),
            password: "pw".into(),
            status_msg: String::new(),
            status_mode: 0,
            channel: String::new(),
            channel_password: String::new(),
            enabled: true,
        };
        s.id = st.add_server(&s).unwrap();
        assert_eq!(st.servers_version().unwrap(), 1);
        assert_eq!(st.server(s.id).unwrap().unwrap(), s);
        s.name = "Renamed".into();
        st.update_server(&s).unwrap();
        assert_eq!(st.servers().unwrap()[0].name, "Renamed");
        assert!(st.remove_server(s.id).unwrap());
        assert!(st.servers().unwrap().is_empty());
        assert_eq!(st.servers_version().unwrap(), 3);
    }

    fn server(st: &Store, owner: i64) -> i64 {
        st.add_server(&ServerConfig {
            id: 0,
            owner,
            name: "S".into(),
            host: "h".into(),
            tcp_port: 1,
            encrypted: false,
            nickname: String::new(),
            username: String::new(),
            password: String::new(),
            status_msg: String::new(),
            status_mode: 0,
            channel: String::new(),
            channel_password: String::new(),
            enabled: true,
        })
        .unwrap()
    }

    #[test]
    fn devices_see_only_their_own() {
        let st = Store::memory();
        let a = st.add_device("a", "ha", &[0; 32], &Prefs::default()).unwrap();
        let b = st.add_device("b", "hb", &[0; 32], &Prefs::default()).unwrap();
        let sa = server(&st, a);
        let sb = server(&st, b);
        // A removed server's ID is not given out again.
        st.remove_server(sb).unwrap();
        let sb = server(&st, b);
        assert!(sb > sa + 1);
        assert_eq!(st.servers_of(a).unwrap().iter().map(|s| s.id).collect::<Vec<_>>(), vec![sa]);
        assert_eq!(st.count_servers(Some(b)).unwrap(), 1);
        for (seq, sid) in [(1, sa), (2, sb)] {
            st.add_event(&StoredEvent { seq, server_id: sid, time: 0, event: Event::Connection { status: ConnectionStatus::Connecting, reason: None } }).unwrap();
        }
        let ca = st.conversation_for(sa, 7, "X", "x", 0).unwrap();
        let cb = st.conversation_for(sb, 7, "Y", "y", 0).unwrap();
        st.add_message(ca, sa, false, "for a", 1).unwrap();
        st.add_message(cb, sb, false, "for b", 2).unwrap();
        assert_eq!(st.events_since(0, a, None, 10).unwrap().iter().map(|e| e.seq).collect::<Vec<_>>(), vec![1]);
        assert_eq!(st.recent_events(b, None, 10).unwrap().iter().map(|e| e.seq).collect::<Vec<_>>(), vec![2]);
        assert_eq!(st.conversations(a, None).unwrap()[0].last_text, "for a");
        // Forgetting a device forgets what it monitored.
        st.remove_device(a).unwrap();
        assert_eq!(st.count_servers(None).unwrap(), 1);
        assert!(st.events_since(0, b, None, 10).unwrap().len() == 1);
    }

    #[test]
    fn events_page_in_order() {
        let st = Store::memory();
        let (s1, s2) = (server(&st, 9), server(&st, 9));
        for seq in 1..=5 {
            st.add_event(&StoredEvent {
                seq,
                server_id: if seq % 2 == 0 { s2 } else { s1 },
                time: seq,
                event: Event::Connection { status: ConnectionStatus::Connecting, reason: None },
            })
            .unwrap();
        }
        let all = st.events_since(1, 9, None, 10).unwrap();
        assert_eq!(all.iter().map(|e| e.seq).collect::<Vec<_>>(), vec![2, 3, 4, 5]);
        let one = st.events_since(0, 9, Some(s2), 10).unwrap();
        assert_eq!(one.iter().map(|e| e.seq).collect::<Vec<_>>(), vec![2, 4]);
        let recent = st.recent_events(9, None, 2).unwrap();
        assert_eq!(recent.iter().map(|e| e.seq).collect::<Vec<_>>(), vec![4, 5]);
    }

    #[test]
    fn each_copy_of_the_app_gets_pushes() {
        let st = Store::memory();
        let d = st.add_device("me", "h", &[0; 32], &Prefs::default()).unwrap();
        st.set_push_target(d, "phone", Some("aa"), false, "ref").unwrap();
        st.set_push_target(d, "ipad", Some("bb"), true, "ref").unwrap();
        st.set_push_target(d, "phone", Some("cc"), false, "ref").unwrap();
        let t = st.push_targets(d).unwrap();
        assert_eq!(t.iter().map(|t| t.apns_token.as_str()).collect::<Vec<_>>(), vec!["cc", "bb"]);
        assert!(st.device(d).unwrap()[0].has_push);
        st.drop_apns_token("cc").unwrap();
        assert_eq!(st.push_targets(d).unwrap().len(), 1);
        st.set_push_target(d, "ipad", None, false, "").unwrap();
        assert!(!st.device(d).unwrap()[0].has_push);
    }

    #[test]
    fn two_sign_ups_become_one() {
        let st = Store::memory();
        let old = st.add_device("old", "h1", &[0; 32], &Prefs::default()).unwrap();
        let new = st.add_device("new", "h2", &[0; 32], &Prefs::default()).unwrap();
        let s_old = server(&st, old);
        let s_new = server(&st, new);
        let c = st.conversation_for(s_new, 5, "A", "a", 1).unwrap();
        st.add_message(c, s_new, false, "hi", 1).unwrap();
        st.set_push_target(old, "phone-1", Some("aa"), false, "r").unwrap();
        st.set_push_target(new, "phone-2", Some("bb"), false, "r").unwrap();
        st.set_push_target(new, "phone-1", Some("cc"), false, "r").unwrap();
        st.merge_devices(old, new).unwrap();
        assert_eq!(st.servers_of(old).unwrap().iter().map(|s| s.id).collect::<Vec<_>>(), vec![s_old, s_new]);
        assert_eq!(st.conversations(old, None).unwrap()[0].last_text, "hi");
        let mut tokens: Vec<_> = st.push_targets(old).unwrap().into_iter().map(|t| t.apns_token).collect();
        tokens.sort();
        assert_eq!(tokens, vec!["bb", "cc"]);
        assert!(st.device(new).unwrap().is_empty());
    }

    #[test]
    fn phones_are_checked_once_a_day() {
        let st = Store::memory();
        let d = st.add_device("me", "h", &[0; 32], &Prefs::default()).unwrap();
        st.set_push_target(d, "a", Some("aa"), false, "r").unwrap();
        st.set_push_target(d, "b", Some("bb"), false, "r").unwrap();
        st.drop_apns_token("bb").unwrap();
        let now = 100 * DAY_MS;
        let due = st.push_targets_due(now, PHONE_CHECK_EVERY_MS).unwrap();
        assert_eq!(due.iter().map(|t| t.apns_token.as_str()).collect::<Vec<_>>(), vec!["aa"]);
        assert!(st.push_targets_due(now + DAY_MS / 2, PHONE_CHECK_EVERY_MS).unwrap().is_empty());
        assert_eq!(st.push_targets_due(now + DAY_MS, PHONE_CHECK_EVERY_MS).unwrap().len(), 1);
    }

    #[test]
    fn abandoned_sign_ups_sleep_then_go() {
        let st = Store::memory();
        let r = Retention::default();
        let now = 1_000 * DAY_MS;
        let fresh = st.add_device("fresh", "h1", &[0; 32], &Prefs::default()).unwrap();
        let quiet = st.add_device("quiet", "h2", &[0; 32], &Prefs::default()).unwrap();
        let uninstalled = st.add_device("uninstalled", "h3", &[0; 32], &Prefs::default()).unwrap();
        let gone = st.add_device("gone", "h4", &[0; 32], &Prefs::default()).unwrap();
        st.touch_device_at(fresh, now - DAY_MS).unwrap();
        st.touch_device_at(quiet, now - 15 * DAY_MS).unwrap();
        st.touch_device_at(uninstalled, now - 2 * DAY_MS).unwrap();
        st.touch_device_at(gone, now - 181 * DAY_MS).unwrap();
        st.set_push_target(uninstalled, "x", Some("dead"), false, "r").unwrap();
        st.drop_apns_token("dead").unwrap();
        let s = server(&st, gone);
        let v = st.servers_version().unwrap();
        let swept = st.sweep(now, r).unwrap();
        assert_eq!(swept, Sweep { dormant: vec![quiet, uninstalled], deleted: vec![gone] });
        assert!(st.server(s).unwrap().is_none());
        assert!(st.servers_version().unwrap() > v);
        assert_eq!(st.dormant_devices().unwrap(), vec![quiet, uninstalled]);
        // Nothing more to do the next time.
        assert_eq!(st.sweep(now, r).unwrap(), Sweep::default());
        // The app comes back.
        assert!(st.wake_device(quiet).unwrap());
        assert!(!st.wake_device(quiet).unwrap());
        assert_eq!(st.dormant_devices().unwrap(), vec![uninstalled]);
    }

    #[test]
    fn conversations_follow_user_ids_like_teamtalk() {
        let st = Store::memory();
        let srv = server(&st, 9);
        // Alice (user 5) writes twice, changing her nickname in between: one conversation.
        let a = st.conversation_for(srv, 5, "Alice", "alice", 1).unwrap();
        st.add_message(a, srv, false, "hi", 1).unwrap();
        assert_eq!(st.conversation_for(srv, 5, "Alice (phone)", "alice", 2).unwrap(), a);
        st.add_message(a, srv, false, "you there?", 2).unwrap();
        st.add_message(a, srv, true, "yes", 3).unwrap();
        // A guest with no username is user 6.
        let g = st.conversation_for(srv, 6, "Guest", "", 4).unwrap();
        st.add_message(g, srv, false, "hello", 4).unwrap();
        let c = st.conversations(9, Some(srv)).unwrap();
        assert_eq!(c.iter().map(|c| (c.user_id, c.active)).collect::<Vec<_>>(), vec![(6, true), (5, true)]);
        let alice = c.iter().find(|c| c.id == a).unwrap();
        assert_eq!((alice.nickname.as_str(), alice.unread, alice.last_text.as_str()), ("Alice (phone)", 2, "yes"));
        let m = st.messages(a, None, 2).unwrap();
        assert_eq!(m.iter().map(|m| m.text.as_str()).collect::<Vec<_>>(), vec!["you there?", "yes"]);
        st.mark_read(a).unwrap();
        assert_eq!(st.conversation(a).unwrap().unwrap().unread, 0);
        // Deleting a conversation removes it and its messages; Alice writing
        // again (same login) starts a new one.
        let b = st.conversation_for(srv, 7, "Bea", "bea", 5).unwrap();
        st.add_message(b, srv, false, "delete me", 5).unwrap();
        assert!(st.delete_conversation(b).unwrap());
        assert!(st.conversation(b).unwrap().is_none());
        assert!(st.messages(b, None, 10).unwrap().is_empty());
        assert_eq!(st.active_conversation(srv, 7).unwrap(), None);
        assert_ne!(st.conversation_for(srv, 7, "Bea", "bea", 6).unwrap(), b);
        // Alice logs out: her conversation ends; her next login is a new one.
        st.end_conversation(srv, 5).unwrap();
        assert!(!st.conversation(a).unwrap().unwrap().active);
        assert_eq!(st.active_conversation(srv, 5).unwrap(), None);
        let a2 = st.conversation_for(srv, 9, "Alice", "alice", 5).unwrap();
        assert_ne!(a2, a);
        // After a server restart, user 6 is someone else: the guest's conversation ends.
        st.keep_conversations(srv, &[(6, "bob".into()), (9, "alice".into())]).unwrap();
        assert!(!st.conversation(g).unwrap().unwrap().active);
        assert_eq!(st.active_conversation(srv, 9).unwrap(), Some(a2));
        assert_ne!(st.conversation_for(srv, 6, "Bob", "bob", 6).unwrap(), g);
    }
}
