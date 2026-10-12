//! NG Account sync: an account's saved servers and settings, as records
//! that each carry a revision. The app pulls what changed since the last
//! revision it saw, and pushes its changes with the revision each was
//! based on; a change made elsewhere meanwhile comes back as a conflict
//! for the app to resolve.

use rusqlite::{OptionalExtension, params};
use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::hub::{HubError, Result};
use crate::store::{Store, now_ms};

/// What can be synced, and how many of each an account may have.
const KINDS: &[(&str, i64)] = &[("server", 500), ("setting", 1000)];
/// Fields of a synced server that are encrypted at rest.
const SECRET_FIELDS: &[&str] = &["password", "chanpasswd", "certprivkeydata"];
/// The largest record (a server with its certificates fits easily).
const MAX_RECORD_BYTES: usize = 64 * 1024;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct Record {
    pub kind: String,
    pub key: String,
    pub rev: i64,
    #[serde(default)]
    pub deleted: bool,
    /// Absent when deleted.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub data: Option<Value>,
    #[serde(default)]
    pub updated: i64,
}

/// One change the app sends.
#[derive(Debug, Clone, Deserialize)]
pub struct Change {
    pub kind: String,
    pub key: String,
    /// The revision this change was made from: 0 for something new.
    pub base_rev: i64,
    #[serde(default)]
    pub deleted: bool,
    #[serde(default)]
    pub data: Option<Value>,
}

#[derive(Debug, Default, Serialize)]
pub struct Applied {
    /// The account's revision after the changes.
    pub rev: i64,
    /// Each change made, with its new revision.
    pub applied: Vec<Record>,
    /// Records changed elsewhere since the app's base revision, as they are
    /// now; the app merges and sends them again.
    pub conflicts: Vec<Record>,
}

impl Store {
    pub(crate) fn setup_sync(&self) -> anyhow::Result<()> {
        self.db.execute_batch(
            r#"
            CREATE TABLE IF NOT EXISTS sync_records (
                account INTEGER NOT NULL,
                kind TEXT NOT NULL,
                key TEXT NOT NULL,
                rev INTEGER NOT NULL,
                deleted INTEGER NOT NULL,
                data TEXT,
                updated INTEGER NOT NULL,
                PRIMARY KEY (account, kind, key)
            );
            CREATE INDEX IF NOT EXISTS sync_records_rev ON sync_records (account, rev);
            CREATE TABLE IF NOT EXISTS sync_revs (account INTEGER PRIMARY KEY, rev INTEGER NOT NULL);
            "#,
        )?;
        Ok(())
    }

    pub fn sync_rev(&self, account: i64) -> anyhow::Result<i64> {
        Ok(self.db.query_row("SELECT rev FROM sync_revs WHERE account = ?1", [account], |r| r.get(0)).optional()?.unwrap_or(0))
    }

    fn sync_record_row(&self, r: &rusqlite::Row) -> rusqlite::Result<Record> {
        let data: Option<String> = r.get(4)?;
        Ok(Record {
            kind: r.get(0)?,
            key: r.get(1)?,
            rev: r.get(2)?,
            deleted: r.get(3)?,
            data: data.and_then(|d| serde_json::from_str(&d).ok()),
            updated: r.get(5)?,
        })
    }

    /// Records changed after `since`, oldest change first. From the start
    /// (`since` 0) deleted records are left out.
    pub fn sync_changes(&self, account: i64, since: i64) -> anyhow::Result<Vec<Record>> {
        let mut st = self.db.prepare(
            "SELECT kind, key, rev, deleted, data, updated FROM sync_records
             WHERE account = ?1 AND rev > ?2 AND (?2 > 0 OR deleted = 0) ORDER BY rev",
        )?;
        let rows = st.query_map(params![account, since], |r| self.sync_record_row(r))?;
        let mut records: Vec<Record> = rows.collect::<std::result::Result<_, _>>()?;
        for r in &mut records {
            self.open_secrets(r);
        }
        Ok(records)
    }

    fn sync_record(&self, account: i64, kind: &str, key: &str) -> anyhow::Result<Option<Record>> {
        let mut r = self
            .db
            .query_row(
                "SELECT kind, key, rev, deleted, data, updated FROM sync_records WHERE account = ?1 AND kind = ?2 AND key = ?3",
                params![account, kind, key],
                |r| self.sync_record_row(r),
            )
            .optional()?;
        if let Some(r) = r.as_mut() {
            self.open_secrets(r);
        }
        Ok(r)
    }

    fn seal_secrets(&self, data: &mut Value) -> anyhow::Result<()> {
        if let Some(obj) = data.as_object_mut() {
            for f in SECRET_FIELDS {
                if let Some(Value::String(v)) = obj.get_mut(*f)
                    && !v.is_empty()
                {
                    *v = self.seal(v)?;
                }
            }
        }
        Ok(())
    }

    fn open_secrets(&self, r: &mut Record) {
        if let Some(obj) = r.data.as_mut().and_then(Value::as_object_mut) {
            for f in SECRET_FIELDS {
                if let Some(Value::String(v)) = obj.get_mut(*f) {
                    *v = self.unseal(v).unwrap_or_else(|e| {
                        tracing::error!("a synced secret cannot be read with this key: {e:#}");
                        String::new()
                    });
                }
            }
        }
    }

    /// Apply the app's changes, in order, in one transaction.
    pub fn apply_sync(&self, account: i64, changes: &[Change]) -> Result<Applied> {
        for c in changes {
            check_change(c)?;
        }
        let tx = self.db.unchecked_transaction().map_err(anyhow::Error::from)?;
        let mut out = Applied::default();
        let mut rev = self.sync_rev(account)?;
        for c in changes {
            let current = self.sync_record(account, &c.kind, &c.key)?;
            let current_rev = current.as_ref().map_or(0, |r| r.rev);
            if c.base_rev != current_rev {
                if let Some(r) = current {
                    out.conflicts.push(r);
                }
                continue;
            }
            if current.is_none() && !c.deleted {
                let limit = KINDS.iter().find(|(k, _)| *k == c.kind).map_or(0, |(_, n)| *n);
                let count: i64 = self
                    .db
                    .query_row("SELECT COUNT(*) FROM sync_records WHERE account = ?1 AND kind = ?2 AND deleted = 0", params![account, c.kind], |r| r.get(0))
                    .map_err(anyhow::Error::from)?;
                if count >= limit {
                    return Err(HubError::Refused(format!("An NG Account can sync at most {limit} of these")));
                }
            }
            rev += 1;
            let now = now_ms();
            let stored = if c.deleted {
                None
            } else {
                let mut data = c.data.clone().unwrap_or(Value::Null);
                self.seal_secrets(&mut data)?;
                Some(serde_json::to_string(&data).map_err(anyhow::Error::from)?)
            };
            self.db
                .execute(
                    "INSERT OR REPLACE INTO sync_records (account, kind, key, rev, deleted, data, updated) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
                    params![account, c.kind, c.key, rev, c.deleted, stored, now],
                )
                .map_err(anyhow::Error::from)?;
            out.applied.push(Record {
                kind: c.kind.clone(),
                key: c.key.clone(),
                rev,
                deleted: c.deleted,
                data: if c.deleted { None } else { c.data.clone() },
                updated: now,
            });
        }
        self.db
            .execute("INSERT OR REPLACE INTO sync_revs (account, rev) VALUES (?1, ?2)", params![account, rev])
            .map_err(anyhow::Error::from)?;
        tx.commit().map_err(anyhow::Error::from)?;
        out.rev = rev;
        Ok(out)
    }

    pub(crate) fn delete_sync_records(&self, account: i64) -> anyhow::Result<()> {
        self.db.execute("DELETE FROM sync_records WHERE account = ?1", [account])?;
        self.db.execute("DELETE FROM sync_revs WHERE account = ?1", [account])?;
        Ok(())
    }
}

fn check_change(c: &Change) -> Result<()> {
    if !KINDS.iter().any(|(k, _)| *k == c.kind) {
        return Err(HubError::Invalid(format!("Nothing called {:?} is synced", c.kind)));
    }
    if c.key.is_empty() || c.key.len() > 200 {
        return Err(HubError::Invalid("A synced record needs a key of up to 200 characters".into()));
    }
    if c.base_rev < 0 {
        return Err(HubError::Invalid("A revision cannot be negative".into()));
    }
    if !c.deleted {
        let Some(data) = &c.data else {
            return Err(HubError::Invalid("A synced record needs its data".into()));
        };
        if c.kind == "server" && !data.is_object() {
            return Err(HubError::Invalid("A synced server is an object".into()));
        }
        if serde_json::to_vec(data).map_err(anyhow::Error::from)?.len() > MAX_RECORD_BYTES {
            return Err(HubError::Invalid("That record is too large to sync".into()));
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn change(kind: &str, key: &str, base: i64, data: Option<Value>) -> Change {
        Change { kind: kind.into(), key: key.into(), base_rev: base, deleted: data.is_none(), data }
    }

    #[test]
    fn changes_conflicts_and_deletes() {
        let st = Store::memory();
        let a = st.apply_sync(1, &[change("setting", "nickname", 0, Some(json!("Matt"))), change("server", "s1", 0, Some(json!({"name": "Home", "password": "pw"})))]).unwrap();
        assert_eq!((a.rev, a.applied.len(), a.conflicts.len()), (2, 2, 0));
        // Another account is separate.
        assert_eq!(st.sync_rev(2).unwrap(), 0);

        // A change from an old revision comes back as a conflict.
        let b = st.apply_sync(1, &[change("setting", "nickname", 0, Some(json!("Other")))]).unwrap();
        assert_eq!((b.rev, b.applied.len()), (2, 0));
        assert_eq!(b.conflicts[0].data, Some(json!("Matt")));

        let c = st.apply_sync(1, &[change("setting", "nickname", 1, Some(json!("Matthew")))]).unwrap();
        assert_eq!(c.rev, 3);
        let d = st.apply_sync(1, &[change("server", "s1", 2, None)]).unwrap();
        assert_eq!(d.rev, 4);

        // From the start: no deleted records; since 2: the delete too.
        let all = st.sync_changes(1, 0).unwrap();
        assert_eq!(all.iter().map(|r| r.key.as_str()).collect::<Vec<_>>(), ["nickname"]);
        let since = st.sync_changes(1, 2).unwrap();
        assert_eq!(since.iter().map(|r| (r.key.as_str(), r.deleted)).collect::<Vec<_>>(), [("nickname", false), ("s1", true)]);
    }

    #[test]
    fn server_secrets_are_encrypted_at_rest() {
        let st = Store::memory();
        st.apply_sync(1, &[change("server", "s1", 0, Some(json!({"name": "Home", "password": "hunter2", "chanpasswd": "", "certprivkeydata": "KEY"})))]).unwrap();
        let raw: String = st.db.query_row("SELECT data FROM sync_records WHERE key = 's1'", [], |r| r.get(0)).unwrap();
        assert!(!raw.contains("hunter2") && !raw.contains("KEY") && raw.contains("Home"), "{raw}");
        let back = &st.sync_changes(1, 0).unwrap()[0];
        assert_eq!(back.data, Some(json!({"name": "Home", "password": "hunter2", "chanpasswd": "", "certprivkeydata": "KEY"})));
    }

    #[test]
    fn refuses_unknown_kinds_and_oversized_records() {
        let st = Store::memory();
        assert!(st.apply_sync(1, &[change("secret", "x", 0, Some(json!(1)))]).is_err());
        let big = "x".repeat(MAX_RECORD_BYTES + 1);
        assert!(st.apply_sync(1, &[change("setting", "x", 0, Some(json!(big)))]).is_err());
        assert!(st.apply_sync(1, &[change("server", "x", 0, Some(json!("not an object")))]).is_err());
    }
}
