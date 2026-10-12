//! NG Account sound packs. Every custom pack is backed up to its owner's
//! account, privately; publishing one puts it in the catalog everyone
//! browses, under the name and author its owner chooses. Files are kept
//! once each, named by their SHA-256.

use std::collections::HashSet;
use std::path::{Path, PathBuf};
use std::sync::Arc;

use base64::Engine;
use base64::engine::general_purpose::URL_SAFE_NO_PAD as B64URL;
use rusqlite::{OptionalExtension, params};
use serde::Serialize;
use sha2::{Digest, Sha256};

use crate::hub::{Hub, HubError, Result};
use crate::push::RateLimit;
use crate::store::{Store, now_ms};

pub const MAX_PACK_BYTES: i64 = 25 * 1024 * 1024;
pub const MAX_ACCOUNT_BYTES: i64 = 250 * 1024 * 1024;
const MAX_PACKS_PER_ACCOUNT: i64 = 200;

/// The sounds a pack may have, as TeamTalk NG names them.
pub const SOUND_NAMES: &[&str] = &[
    "on", "off", "channel_msg", "broadcast_msg", "user_msg", "serverlost", "newuser", "removeuser", "txqueue_start",
    "txqueue_stop", "logged_on", "logged_off", "intercept", "interceptEnd", "fileupdate", "filetx_complete",
];
const EXTENSIONS: &[&str] = &["mp3", "wav", "caf", "aiff", "aif", "m4a", "aac"];

#[derive(Debug, Clone, Serialize)]
pub struct PackFile {
    /// Such as `logged_on.wav`.
    pub name: String,
    pub hash: String,
    pub size: i64,
}

#[derive(Debug, Clone, Serialize)]
pub struct Pack {
    pub id: String,
    /// The app's own ID for the pack it backs up.
    pub local_id: String,
    pub name: String,
    /// The name shown as the pack's author in the catalog.
    pub author: String,
    pub description: String,
    pub public: bool,
    pub official: bool,
    /// Hidden from the catalog by an administrator.
    pub hidden: bool,
    /// Goes up with every change to the pack's sounds.
    pub version: String,
    pub created: i64,
    pub updated: i64,
    pub installs: i64,
    pub size: i64,
    pub files: Vec<PackFile>,
    #[serde(skip)]
    pub owner: Option<i64>,
}

/// What the app may change about a pack.
#[derive(Debug, Default, serde::Deserialize)]
pub struct PackChange {
    pub name: Option<String>,
    pub author: Option<String>,
    pub description: Option<String>,
    pub public: Option<bool>,
}

impl Store {
    pub(crate) fn setup_packs(&self) -> anyhow::Result<()> {
        self.db.execute_batch(
            r#"
            CREATE TABLE IF NOT EXISTS packs (
                id TEXT PRIMARY KEY,
                owner INTEGER,
                local_id TEXT NOT NULL,
                name TEXT NOT NULL,
                author TEXT NOT NULL DEFAULT '',
                description TEXT NOT NULL DEFAULT '',
                public INTEGER NOT NULL DEFAULT 0,
                official INTEGER NOT NULL DEFAULT 0,
                hidden INTEGER NOT NULL DEFAULT 0,
                version INTEGER NOT NULL DEFAULT 0,
                created INTEGER NOT NULL,
                updated INTEGER NOT NULL,
                installs INTEGER NOT NULL DEFAULT 0
            );
            CREATE INDEX IF NOT EXISTS packs_owner ON packs (owner);
            CREATE TABLE IF NOT EXISTS pack_files (
                pack TEXT NOT NULL,
                name TEXT NOT NULL,
                hash TEXT NOT NULL,
                size INTEGER NOT NULL,
                PRIMARY KEY (pack, name)
            );
            CREATE INDEX IF NOT EXISTS pack_files_hash ON pack_files (hash);
            CREATE TABLE IF NOT EXISTS pack_reports (
                pack TEXT NOT NULL,
                account INTEGER NOT NULL,
                reason TEXT NOT NULL,
                created INTEGER NOT NULL,
                PRIMARY KEY (pack, account)
            );
            "#,
        )?;
        if self.db.prepare("SELECT publishing_blocked FROM accounts LIMIT 0").is_err() {
            self.db.execute_batch("ALTER TABLE accounts ADD COLUMN publishing_blocked INTEGER NOT NULL DEFAULT 0")?;
        }
        Ok(())
    }

    const PACK_COLUMNS: &str = "id, owner, local_id, name, author, description, public, official, hidden, version, created, updated, installs";

    fn pack_rows(&self, sql: &str, p: impl rusqlite::Params) -> anyhow::Result<Vec<Pack>> {
        let mut st = self.db.prepare(sql)?;
        let mut packs: Vec<Pack> = st
            .query_map(p, |r| {
                Ok(Pack {
                    id: r.get(0)?,
                    owner: r.get(1)?,
                    local_id: r.get(2)?,
                    name: r.get(3)?,
                    author: r.get(4)?,
                    description: r.get(5)?,
                    public: r.get(6)?,
                    official: r.get(7)?,
                    hidden: r.get(8)?,
                    version: r.get::<_, i64>(9)?.to_string(),
                    created: r.get(10)?,
                    updated: r.get(11)?,
                    installs: r.get(12)?,
                    size: 0,
                    files: Vec::new(),
                })
            })?
            .collect::<std::result::Result<_, _>>()?;
        let mut files = self.db.prepare("SELECT name, hash, size FROM pack_files WHERE pack = ?1 ORDER BY name")?;
        for p in &mut packs {
            p.files = files
                .query_map([&p.id], |r| Ok(PackFile { name: r.get(0)?, hash: r.get(1)?, size: r.get(2)? }))?
                .collect::<std::result::Result<_, _>>()?;
            p.size = p.files.iter().map(|f| f.size).sum();
        }
        Ok(packs)
    }

    pub fn pack(&self, id: &str) -> anyhow::Result<Option<Pack>> {
        Ok(self.pack_rows(&format!("SELECT {} FROM packs WHERE id = ?1", Self::PACK_COLUMNS), [id])?.into_iter().next())
    }

    pub fn packs_of(&self, account: i64) -> anyhow::Result<Vec<Pack>> {
        self.pack_rows(&format!("SELECT {} FROM packs WHERE owner = ?1 ORDER BY created", Self::PACK_COLUMNS), [account])
    }

    pub fn all_packs(&self) -> anyhow::Result<Vec<Pack>> {
        self.pack_rows(&format!("SELECT {} FROM packs ORDER BY created", Self::PACK_COLUMNS), [])
    }

    /// The catalog: public packs nobody has hidden, Official ones first.
    pub fn catalog(&self, query: &str, popular: bool) -> anyhow::Result<Vec<Pack>> {
        let order = if popular { "official DESC, installs DESC, updated DESC" } else { "official DESC, updated DESC" };
        let pattern = format!("%{}%", query.trim().replace('\\', "\\\\").replace('%', "\\%").replace('_', "\\_"));
        self.pack_rows(
            &format!(
                "SELECT {} FROM packs WHERE public = 1 AND hidden = 0
                 AND (name LIKE ?1 ESCAPE '\\' OR author LIKE ?1 ESCAPE '\\' OR description LIKE ?1 ESCAPE '\\')
                 ORDER BY {order} LIMIT 500",
                Self::PACK_COLUMNS
            ),
            [pattern],
        )
    }

    fn account_pack_bytes(&self, account: i64) -> anyhow::Result<i64> {
        Ok(self.db.query_row(
            "SELECT COALESCE(SUM(f.size), 0) FROM pack_files f JOIN packs p ON p.id = f.pack WHERE p.owner = ?1",
            [account],
            |r| r.get(0),
        )?)
    }

    pub fn pack_usage(&self, account: i64) -> anyhow::Result<(i64, i64)> {
        Ok((self.account_pack_bytes(account)?, MAX_ACCOUNT_BYTES))
    }

    /// A pack for one of the app's packs: the one backed up already, or a
    /// new one.
    pub fn backup_pack(&self, account: i64, local_id: &str, name: &str) -> Result<Pack> {
        if let Some(p) = self
            .pack_rows(&format!("SELECT {} FROM packs WHERE owner = ?1 AND local_id = ?2", Self::PACK_COLUMNS), params![account, local_id])?
            .into_iter()
            .next()
        {
            return Ok(p);
        }
        let count: i64 = self.db.query_row("SELECT COUNT(*) FROM packs WHERE owner = ?1", [account], |r| r.get(0)).map_err(anyhow::Error::from)?;
        if count >= MAX_PACKS_PER_ACCOUNT {
            return Err(HubError::Refused(format!("An NG Account can keep at most {MAX_PACKS_PER_ACCOUNT} sound packs")));
        }
        let id = B64URL.encode(rand::random::<[u8; 12]>());
        let now = now_ms();
        self.db
            .execute(
                "INSERT INTO packs (id, owner, local_id, name, created, updated) VALUES (?1, ?2, ?3, ?4, ?5, ?5)",
                params![id, account, local_id, clean(name, 80), now],
            )
            .map_err(anyhow::Error::from)?;
        Ok(self.pack(&id)?.expect("just made"))
    }

    fn owned_pack(&self, account: i64, id: &str) -> Result<Pack> {
        match self.pack(id)? {
            Some(p) if p.owner == Some(account) => Ok(p),
            _ => Err(HubError::NotFound("You have no sound pack like that".into())),
        }
    }

    pub fn change_pack(&self, account: i64, id: &str, change: &PackChange) -> Result<Pack> {
        let p = self.owned_pack(account, id)?;
        let name = change.name.as_deref().map(|n| clean(n, 80)).unwrap_or(p.name.clone());
        let author = change.author.as_deref().map(|a| clean(a, 60)).unwrap_or(p.author.clone());
        let description = change.description.as_deref().map(|d| clean(d, 1000)).unwrap_or(p.description.clone());
        let public = change.public.unwrap_or(p.public);
        if public {
            if name.is_empty() {
                return Err(HubError::Invalid("Give the pack a name before publishing it".into()));
            }
            if author.is_empty() {
                return Err(HubError::Invalid("Say who made the pack (the name people see) before publishing it".into()));
            }
            if p.files.is_empty() {
                return Err(HubError::Invalid("Back up the pack's sounds before publishing it".into()));
            }
            let blocked: bool = self
                .db
                .query_row("SELECT publishing_blocked FROM accounts WHERE id = ?1", [account], |r| r.get(0))
                .optional()
                .map_err(anyhow::Error::from)?
                .unwrap_or(false);
            if blocked && !p.public {
                return Err(HubError::Refused("This NG Account can't publish sound packs".into()));
            }
        }
        self.db
            .execute(
                "UPDATE packs SET name = ?2, author = ?3, description = ?4, public = ?5, updated = ?6 WHERE id = ?1",
                params![id, name, author, description, public, now_ms()],
            )
            .map_err(anyhow::Error::from)?;
        Ok(self.pack(id)?.expect("exists"))
    }

    /// Record a file already stored under `hash`, within the size limits.
    fn put_pack_file(&self, account: i64, id: &str, name: &str, hash: &str, size: i64) -> Result<Pack> {
        let p = self.owned_pack(account, id)?;
        let replacing = p.files.iter().find(|f| f.name.eq_ignore_ascii_case(name) || stem(&f.name) == stem(name)).map_or(0, |f| f.size);
        if p.size - replacing + size > MAX_PACK_BYTES {
            return Err(HubError::Refused("A sound pack can be at most 25 MB".into()));
        }
        if self.account_pack_bytes(account)? - replacing + size > MAX_ACCOUNT_BYTES {
            return Err(HubError::Refused("Your NG Account's sound packs can take at most 250 MB".into()));
        }
        // One file per sound: a new format replaces the old.
        self.db
            .execute("DELETE FROM pack_files WHERE pack = ?1 AND (name = ?2 OR name LIKE ?3)", params![id, name, format!("{}.%", stem(name))])
            .map_err(anyhow::Error::from)?;
        self.db
            .execute("INSERT INTO pack_files (pack, name, hash, size) VALUES (?1, ?2, ?3, ?4)", params![id, name, hash, size])
            .map_err(anyhow::Error::from)?;
        self.pack_changed(id)?;
        Ok(self.pack(id)?.expect("exists"))
    }

    pub fn remove_pack_file(&self, account: i64, id: &str, name: &str) -> Result<Pack> {
        self.owned_pack(account, id)?;
        let n = self.db.execute("DELETE FROM pack_files WHERE pack = ?1 AND name = ?2", params![id, name]).map_err(anyhow::Error::from)?;
        if n > 0 {
            self.pack_changed(id)?;
        }
        Ok(self.pack(id)?.expect("exists"))
    }

    fn pack_changed(&self, id: &str) -> anyhow::Result<()> {
        self.db.execute("UPDATE packs SET version = version + 1, updated = ?2 WHERE id = ?1", params![id, now_ms()])?;
        Ok(())
    }

    pub fn delete_pack(&self, account: i64, id: &str) -> Result<()> {
        self.owned_pack(account, id)?;
        self.drop_pack(id)?;
        Ok(())
    }

    fn drop_pack(&self, id: &str) -> anyhow::Result<()> {
        self.db.execute("DELETE FROM pack_files WHERE pack = ?1", [id])?;
        self.db.execute("DELETE FROM pack_reports WHERE pack = ?1", [id])?;
        self.db.execute("DELETE FROM packs WHERE id = ?1", [id])?;
        Ok(())
    }

    /// An account is going: its private packs go with it; its public ones
    /// stay in the catalog, owned by nobody.
    pub(crate) fn release_packs(&self, account: i64) -> anyhow::Result<()> {
        for p in self.packs_of(account)? {
            if p.public {
                self.db.execute("UPDATE packs SET owner = NULL WHERE id = ?1", [&p.id])?;
            } else {
                self.drop_pack(&p.id)?;
            }
        }
        Ok(())
    }

    pub fn count_install(&self, id: &str) -> anyhow::Result<()> {
        self.db.execute("UPDATE packs SET installs = installs + 1 WHERE id = ?1 AND public = 1", [id])?;
        Ok(())
    }

    pub fn report_pack(&self, account: i64, id: &str, reason: &str) -> Result<()> {
        match self.pack(id)? {
            Some(p) if p.public => {}
            _ => return Err(HubError::NotFound("There's no published pack like that".into())),
        }
        self.db
            .execute(
                "INSERT OR REPLACE INTO pack_reports (pack, account, reason, created) VALUES (?1, ?2, ?3, ?4)",
                params![id, account, clean(reason, 1000), now_ms()],
            )
            .map_err(anyhow::Error::from)?;
        tracing::warn!(pack = id, "a sound pack was reported");
        Ok(())
    }

    pub fn pack_reports(&self) -> anyhow::Result<Vec<(String, i64, String, i64)>> {
        let mut st = self.db.prepare("SELECT pack, account, reason, created FROM pack_reports ORDER BY created DESC")?;
        let rows = st.query_map([], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?)))?;
        Ok(rows.collect::<std::result::Result<_, _>>()?)
    }

    /// Give a pack to an account (an administrator's decision): it becomes
    /// one of the account's packs, which it can update or unpublish.
    pub fn assign_pack(&self, id: &str, account: i64) -> anyhow::Result<bool> {
        Ok(self.db.execute("UPDATE packs SET owner = ?2, updated = ?3 WHERE id = ?1", params![id, account, now_ms()])? > 0)
    }

    pub fn set_pack_hidden(&self, id: &str, hidden: bool) -> anyhow::Result<bool> {
        Ok(self.db.execute("UPDATE packs SET hidden = ?2 WHERE id = ?1", params![id, hidden])? > 0)
    }

    pub fn set_pack_official(&self, id: &str, official: bool) -> anyhow::Result<bool> {
        Ok(self.db.execute("UPDATE packs SET official = ?2 WHERE id = ?1", params![id, official])? > 0)
    }

    pub fn set_publishing_blocked(&self, account: i64, blocked: bool) -> anyhow::Result<bool> {
        let n = self.db.execute("UPDATE accounts SET publishing_blocked = ?2 WHERE id = ?1", params![account, blocked])?;
        if blocked {
            self.db.execute("UPDATE packs SET public = 0 WHERE owner = ?1", [account])?;
        }
        Ok(n > 0)
    }

    /// An Official pack, made or replaced by an administrator.
    pub fn put_official_pack(&self, id: &str, name: &str, author: &str, version: i64, files: &[PackFile]) -> anyhow::Result<()> {
        let now = now_ms();
        self.db.execute(
            "INSERT INTO packs (id, owner, local_id, name, author, public, official, version, created, updated)
             VALUES (?1, NULL, ?1, ?2, ?3, 1, 1, ?4, ?5, ?5)
             ON CONFLICT(id) DO UPDATE SET name = ?2, author = ?3, public = 1, official = 1, version = ?4, updated = ?5",
            params![id, name, author, version, now],
        )?;
        self.db.execute("DELETE FROM pack_files WHERE pack = ?1", [id])?;
        for f in files {
            self.db.execute("INSERT INTO pack_files (pack, name, hash, size) VALUES (?1, ?2, ?3, ?4)", params![id, f.name, f.hash, f.size])?;
        }
        Ok(())
    }

    fn referenced_hashes(&self) -> anyhow::Result<HashSet<String>> {
        let mut st = self.db.prepare("SELECT DISTINCT hash FROM pack_files")?;
        let rows = st.query_map([], |r| r.get(0))?;
        Ok(rows.collect::<std::result::Result<_, _>>()?)
    }
}

fn clean(s: &str, max: usize) -> String {
    s.trim().chars().filter(|c| !c.is_control() || *c == '\n').take(max).collect()
}

fn stem(name: &str) -> &str {
    name.rsplit_once('.').map_or(name, |(s, _)| s)
}

/// A file name a pack may have, such as `logged_on.wav`, as stored.
pub fn check_file_name(name: &str) -> Result<String> {
    let (sound, ext) = name.rsplit_once('.').ok_or_else(|| HubError::Invalid("A sound file needs its extension, like .wav".into()))?;
    let ext = ext.to_lowercase();
    if !SOUND_NAMES.contains(&sound) {
        return Err(HubError::Invalid(format!("A sound pack has no sound called {sound:?}")));
    }
    if !EXTENSIONS.contains(&ext.as_str()) {
        return Err(HubError::Invalid("Sounds can be MP3, WAV, CAF, AIFF, M4A or AAC files".into()));
    }
    Ok(format!("{sound}.{ext}"))
}

/// Whether `data` really is audio of the kind its extension says.
pub fn looks_like_audio(ext: &str, data: &[u8]) -> bool {
    let at = |i: usize, s: &[u8]| data.len() >= i + s.len() && &data[i..i + s.len()] == s;
    match ext {
        "wav" => at(0, b"RIFF") && at(8, b"WAVE"),
        "caf" => at(0, b"caff"),
        "aiff" | "aif" => at(0, b"FORM") && (at(8, b"AIFF") || at(8, b"AIFC")),
        "m4a" => at(4, b"ftyp"),
        "mp3" => at(0, b"ID3") || (data.len() > 1 && data[0] == 0xFF && data[1] & 0xE0 == 0xE0),
        "aac" => at(0, b"ID3") || (data.len() > 1 && data[0] == 0xFF && data[1] & 0xF6 == 0xF0) || at(4, b"ftyp"),
        _ => false,
    }
}

/// Sound packs on top of the store: the files on disk.
pub struct Packs {
    hub: Arc<Hub>,
    dir: PathBuf,
    installs: RateLimit,
}

impl Packs {
    pub fn new(hub: Arc<Hub>, dir: PathBuf) -> anyhow::Result<Packs> {
        std::fs::create_dir_all(&dir)?;
        // One install counted per address and pack each hour.
        Ok(Packs { hub, dir, installs: RateLimit::new(1) })
    }

    fn blob_path(&self, hash: &str) -> PathBuf {
        self.dir.join(&hash[..2]).join(hash)
    }

    /// Store a sound, checked, and add it to a pack.
    pub fn upload(&self, account: i64, pack: &str, name: &str, data: &[u8]) -> Result<Pack> {
        let name = check_file_name(name)?;
        let ext = name.rsplit_once('.').map(|(_, e)| e).unwrap_or_default();
        if data.is_empty() || !looks_like_audio(ext, data) {
            return Err(HubError::Invalid(format!("{name} isn't a {} sound", ext.to_uppercase())));
        }
        if data.len() as i64 > MAX_PACK_BYTES {
            return Err(HubError::Refused("A sound pack can be at most 25 MB".into()));
        }
        let hash = hex::encode(Sha256::digest(data));
        let path = self.blob_path(&hash);
        if !path.exists() {
            write_atomically(&path, data).map_err(HubError::Internal)?;
        }
        self.hub.with_store(|s| Ok(s.put_pack_file(account, pack, &name, &hash, data.len() as i64)))?
    }

    /// A pack's sound, for its owner, or for anyone once published.
    pub fn file(&self, account: Option<i64>, pack: &str, name: &str) -> Result<(String, Vec<u8>)> {
        let p = self.hub.with_store(|s| s.pack(pack))?;
        let p = match p {
            Some(p) if (p.public && !p.hidden) || (account.is_some() && p.owner == account) => p,
            _ => return Err(HubError::NotFound("There's no sound pack like that".into())),
        };
        let f = p.files.iter().find(|f| f.name == name).ok_or_else(|| HubError::NotFound("That pack has no such sound".into()))?;
        let data = std::fs::read(self.blob_path(&f.hash)).map_err(|e| HubError::Internal(e.into()))?;
        Ok((f.name.clone(), data))
    }

    /// A whole pack as a zip of its sounds, for its owner, or for anyone
    /// once published: the name to give the file, and the zip.
    pub fn zip(&self, account: Option<i64>, pack: &str) -> Result<(String, Vec<u8>)> {
        let p = self.hub.with_store(|s| s.pack(pack))?;
        let p = match p {
            Some(p) if (p.public && !p.hidden) || (account.is_some() && p.owner == account) => p,
            _ => return Err(HubError::NotFound("There's no sound pack like that".into())),
        };
        let mut files = Vec::new();
        for f in &p.files {
            let data = std::fs::read(self.blob_path(&f.hash)).map_err(|e| HubError::Internal(e.into()))?;
            files.push((f.name.clone(), data));
        }
        Ok((p.name.clone(), crate::zip::write(&files)?))
    }

    pub fn count_install(&self, pack: &str, address: &str) -> Result<()> {
        if self.installs.allow(&format!("{address} {pack}")) {
            self.hub.with_store(|s| s.count_install(pack))?;
        }
        Ok(())
    }

    /// Delete files no pack uses any more.
    pub fn collect_garbage(&self) -> anyhow::Result<usize> {
        let used = self.hub.with_store(|s| s.referenced_hashes())?;
        let mut removed = 0;
        for shard in std::fs::read_dir(&self.dir)?.flatten() {
            if !shard.path().is_dir() {
                continue;
            }
            for f in std::fs::read_dir(shard.path())?.flatten() {
                let name = f.file_name().to_string_lossy().into_owned();
                // A file mid-upload has a temporary name; leave it alone.
                if name.len() == 64 && !used.contains(&name) && std::fs::remove_file(f.path()).is_ok() {
                    removed += 1;
                }
            }
        }
        Ok(removed)
    }

    /// Import an Official pack from a zip of sounds (the old catalog's
    /// format), keeping its ID so installed copies keep updating.
    pub fn import_official(&self, id: &str, name: &str, author: &str, version: i64, zip: &Path) -> anyhow::Result<usize> {
        let files = crate::zip::sounds(zip)?;
        let mut stored = Vec::new();
        for (file_name, data) in files {
            let Ok(file_name) = check_file_name(&file_name) else { continue };
            let ext = file_name.rsplit_once('.').map(|(_, e)| e).unwrap_or_default().to_owned();
            if !looks_like_audio(&ext, &data) {
                continue;
            }
            let hash = hex::encode(Sha256::digest(&data));
            let path = self.blob_path(&hash);
            if !path.exists() {
                write_atomically(&path, &data)?;
            }
            stored.retain(|f: &PackFile| stem(&f.name) != stem(&file_name));
            stored.push(PackFile { name: file_name, hash, size: data.len() as i64 });
        }
        anyhow::ensure!(!stored.is_empty(), "{} has no sounds a pack can have", zip.display());
        self.hub.with_store(|s| s.put_official_pack(id, name, author, version, &stored))?;
        Ok(stored.len())
    }
}

fn write_atomically(path: &Path, data: &[u8]) -> anyhow::Result<()> {
    let dir = path.parent().expect("blob paths have a folder");
    std::fs::create_dir_all(dir)?;
    let tmp = dir.join(format!(".upload-{}", rand::random::<u64>()));
    std::fs::write(&tmp, data)?;
    std::fs::rename(&tmp, path)?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    const WAV: &[u8] = b"RIFF\x24\x00\x00\x00WAVEfmt ";

    #[test]
    fn names_and_formats_are_checked() {
        assert_eq!(check_file_name("logged_on.WAV").unwrap(), "logged_on.wav");
        assert!(check_file_name("../etc/passwd").is_err());
        assert!(check_file_name("logged_on.exe").is_err());
        assert!(check_file_name("nosuch.wav").is_err());
        assert!(looks_like_audio("wav", WAV));
        assert!(!looks_like_audio("wav", b"<html>"));
        assert!(looks_like_audio("mp3", b"ID3\x04"));
        assert!(looks_like_audio("m4a", b"\x00\x00\x00\x20ftypM4A "));
    }

    #[test]
    fn backup_publish_limits_and_release() {
        let st = Store::memory();
        let p = st.backup_pack(1, "local-1", "Mine").unwrap();
        assert_eq!(st.backup_pack(1, "local-1", "Mine").unwrap().id, p.id, "the same app pack backs up to the same pack");
        // Can't publish without an author or sounds.
        assert!(st.change_pack(1, &p.id, &PackChange { public: Some(true), ..Default::default() }).is_err());
        st.put_pack_file(1, &p.id, "logged_on.wav", &"a".repeat(64), 1000).unwrap();
        // A new format of the same sound replaces it.
        let p2 = st.put_pack_file(1, &p.id, "logged_on.mp3", &"b".repeat(64), 900).unwrap();
        assert_eq!(p2.files.iter().map(|f| f.name.as_str()).collect::<Vec<_>>(), ["logged_on.mp3"]);
        assert_eq!(p2.version, "2");
        assert!(st.put_pack_file(1, &p.id, "logged_off.wav", &"c".repeat(64), MAX_PACK_BYTES).is_err(), "pack limit");
        // Someone else can't touch it.
        assert!(st.change_pack(2, &p.id, &PackChange { name: Some("x".into()), ..Default::default() }).is_err());
        let public = st.change_pack(1, &p.id, &PackChange { public: Some(true), author: Some("Matt".into()), ..Default::default() }).unwrap();
        assert!(public.public);
        assert_eq!(st.catalog("matt", false).unwrap().len(), 1);
        assert_eq!(st.catalog("nothing like it", false).unwrap().len(), 0);
        let private = st.backup_pack(1, "local-2", "Private").unwrap();
        st.release_packs(1).unwrap();
        assert!(st.pack(&private.id).unwrap().is_none(), "private packs go with the account");
        let kept = st.pack(&p.id).unwrap().unwrap();
        assert!(kept.public && kept.owner.is_none(), "public packs stay, owned by nobody");
        assert!(st.assign_pack(&p.id, 3).unwrap());
        assert_eq!(st.packs_of(3).unwrap().iter().map(|x| x.id.as_str()).collect::<Vec<_>>(), [p.id.as_str()], "an administrator gives it to someone");
        assert!(st.change_pack(3, &p.id, &PackChange { description: Some("Mine now".into()), ..Default::default() }).is_ok(), "who can change it");
        assert!(!st.assign_pack("no such pack", 3).unwrap());
    }
}
