//! Keeping the saved servers on a device and in NG Account the same.
//!
//! Each sync pulls what changed in the account since the last revision,
//! applies it to the device's list, then sends the device's changes. The
//! account wins a conflict (the other change came first). A server already
//! on the device but never synced, with the same address, port and
//! username as one in the account, becomes that server rather than a copy
//! (the old app matches the same way).

use std::collections::{BTreeSet, HashMap};

use serde::{Deserialize, Serialize};
use serde_json::Value;
use sha2::{Digest, Sha256};

use crate::account::{NgAccount, SyncChange, SyncRecord};
use crate::error::Result;
use crate::server_record::SyncedServer;

/// A saved server on the device, by its sync key.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct LocalServer {
    pub key: String,
    /// Its `order` is ignored: the list's order is what counts.
    pub server: SyncedServer,
}

/// What sync remembers between runs. No secrets: content hashes only.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct SyncState {
    pub last_rev: i64,
    /// Each server's revision as last seen.
    pub known: HashMap<String, i64>,
    /// Each server's content when last in step with the account.
    pub hashes: HashMap<String, String>,
    /// Removed on the device, not yet from the account.
    pub deleted: BTreeSet<String>,
    /// Synced settings (kind "setting"): each one's revision as last seen.
    #[serde(default)]
    pub setting_known: HashMap<String, i64>,
    /// Each setting's value when last in step with the account.
    #[serde(default)]
    pub setting_hashes: HashMap<String, String>,
}

impl SyncState {
    pub fn from_json(s: &str) -> SyncState {
        serde_json::from_str(s).unwrap_or_default()
    }

    pub fn to_json(&self) -> String {
        serde_json::to_string(self).unwrap_or_default()
    }

    /// The device removed a server.
    pub fn deleted(&mut self, key: &str) {
        if self.known.contains_key(key) {
            self.deleted.insert(key.to_owned());
        }
    }
}

/// The device's list after a sync.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SyncOutcome {
    pub servers: Vec<LocalServer>,
    /// Whether the account changed the list (save it).
    pub changed: bool,
    /// Servers matched up with the account's (key changes: old → new).
    pub rekeyed: Vec<(String, String)>,
    /// Settings the account changed: their new values (None: removed).
    pub settings: Vec<(String, Option<Value>)>,
}

fn value_hash(v: &Option<Value>) -> String {
    let mut h = Sha256::new();
    h.update(v.as_ref().map(|v| v.to_string()).unwrap_or_default().as_bytes());
    h.finalize().iter().map(|b| format!("{b:02x}")).collect()
}

/// Applies the account's setting records for the keys the device syncs.
fn apply_settings(
    state: &mut SyncState,
    local: &mut HashMap<String, Option<Value>>,
    records: &[SyncRecord],
    out: &mut Vec<(String, Option<Value>)>,
) {
    for r in records.iter().filter(|r| r.kind == "setting") {
        let Some(mine) = local.get_mut(&r.key) else { continue };
        let value = if r.deleted { None } else { r.data.clone() };
        // Kept when deleted too: a change is made from the latest revision.
        state.setting_known.insert(r.key.clone(), r.rev);
        state.setting_hashes.insert(r.key.clone(), value_hash(&value));
        if *mine != value {
            *mine = value.clone();
            out.retain(|(k, _)| k != &r.key);
            out.push((r.key.clone(), value));
        }
    }
}

fn same(a: &SyncedServer, b: &SyncedServer) -> bool {
    a.host.eq_ignore_ascii_case(&b.host) && a.tcp_port == b.tcp_port && a.username == b.username
}

/// The same for the same content, from either side.
pub fn content_hash(s: &SyncedServer) -> String {
    let j = s.to_json();
    // to_json is a map with sorted keys (serde_json's default map).
    let mut h = Sha256::new();
    h.update(j.to_string().as_bytes());
    h.finalize().iter().map(|b| format!("{b:02x}")).collect()
}

fn with_order(s: &SyncedServer, order: usize) -> SyncedServer {
    SyncedServer {
        order: order as i64,
        ..s.clone()
    }
}

/// Applies the account's records to the list.
fn apply(
    state: &mut SyncState,
    list: &mut Vec<LocalServer>,
    records: &[SyncRecord],
    rekeyed: &mut Vec<(String, String)>,
) -> bool {
    let mut changed = false;
    let mut order: HashMap<String, i64> = HashMap::new();
    for r in records.iter().filter(|r| r.kind == "server") {
        state.deleted.remove(&r.key);
        if r.deleted {
            let before = list.len();
            list.retain(|l| l.key != r.key);
            changed |= list.len() != before;
            state.known.remove(&r.key);
            state.hashes.remove(&r.key);
            continue;
        }
        let Some(data) = &r.data else { continue };
        let mut remote = SyncedServer::from_json(data);
        state.known.insert(r.key.clone(), r.rev);
        order.insert(r.key.clone(), remote.order);
        let index = list.iter().position(|l| l.key == r.key).or_else(|| {
            list.iter()
                .position(|l| !state.known.contains_key(&l.key) && same(&l.server, &remote))
        });
        match index {
            Some(i) => {
                if list[i].key != r.key {
                    rekeyed.push((list[i].key.clone(), r.key.clone()));
                }
                // Unsynced passwords stay as they are on the device.
                if !remote.sync_password {
                    remote.password = list[i].server.password.clone();
                    remote.channel_password = list[i].server.channel_password.clone();
                }
                if list[i].server != remote || list[i].key != r.key {
                    changed = true;
                }
                list[i] = LocalServer {
                    key: r.key.clone(),
                    server: remote.clone(),
                };
            }
            None => {
                list.push(LocalServer {
                    key: r.key.clone(),
                    server: remote.clone(),
                });
                changed = true;
            }
        }
        state.hashes.insert(r.key.clone(), content_hash(&remote));
    }
    if !order.is_empty() {
        // The account's order; the others keep their places.
        let mut keyed: Vec<(i64, usize, LocalServer)> = list
            .drain(..)
            .enumerate()
            .map(|(i, l)| (order.get(&l.key).copied().unwrap_or(i as i64), i, l))
            .collect();
        keyed.sort_by_key(|(o, i, _)| (*o, *i));
        let sorted: Vec<LocalServer> = keyed.into_iter().map(|(_, _, l)| l).collect();
        *list = sorted;
    }
    changed
}

/// One sync. `local` is the device's list in its order.
pub fn sync(account: &NgAccount, state: &mut SyncState, local: Vec<LocalServer>) -> Result<SyncOutcome> {
    sync_with_settings(account, state, local, Vec::new())
}

/// One sync of the servers and of the settings the device syncs (`settings`:
/// each key with its value on the device, None when it has none). Settings
/// with other keys in the account (another app's) are left alone.
pub fn sync_with_settings(
    account: &NgAccount,
    state: &mut SyncState,
    local: Vec<LocalServer>,
    settings: Vec<(String, Option<Value>)>,
) -> Result<SyncOutcome> {
    let mut list = local;
    let mut values: HashMap<String, Option<Value>> = settings.iter().cloned().collect();
    let mut setting_changes = Vec::new();
    let mut rekeyed = Vec::new();
    let pulled = account.pull(state.last_rev)?;
    if pulled.reset {
        state.known.clear();
        state.hashes.clear();
        state.setting_known.clear();
        state.setting_hashes.clear();
    }
    let mut changed = apply(state, &mut list, &pulled.records, &mut rekeyed);
    apply_settings(state, &mut values, &pulled.records, &mut setting_changes);
    state.last_rev = pulled.rev;

    // The device's changes.
    let mut changes = Vec::new();
    let mut sent: HashMap<String, String> = HashMap::new();
    for (i, l) in list.iter().enumerate() {
        let s = with_order(&l.server, i);
        let h = content_hash(&s);
        if state.hashes.get(&l.key) == Some(&h) {
            continue;
        }
        sent.insert(l.key.clone(), h);
        changes.push(SyncChange {
            kind: "server".into(),
            key: l.key.clone(),
            base_rev: state.known.get(&l.key).copied().unwrap_or(0),
            deleted: false,
            data: Some(s.to_json()),
        });
    }
    let mut sent_settings: HashMap<String, String> = HashMap::new();
    for (key, _) in &settings {
        let v = &values[key];
        let h = value_hash(v);
        let known = state.setting_known.get(key).copied();
        // Nothing to send: in step, or a setting neither side has.
        if state.setting_hashes.get(key) == Some(&h) || (v.is_none() && !state.setting_hashes.contains_key(key)) {
            continue;
        }
        sent_settings.insert(key.clone(), h);
        changes.push(SyncChange {
            kind: "setting".into(),
            key: key.clone(),
            base_rev: known.unwrap_or(0),
            deleted: v.is_none(),
            data: v.clone(),
        });
    }
    for key in &state.deleted {
        changes.push(SyncChange {
            kind: "server".into(),
            key: key.clone(),
            base_rev: state.known.get(key).copied().unwrap_or(0),
            deleted: true,
            data: None,
        });
    }
    for chunk in changes.chunks(500) {
        let r = account.push(chunk)?;
        for a in r.applied.iter().filter(|a| a.kind == "setting") {
            state.setting_known.insert(a.key.clone(), a.rev);
            if let Some(h) = sent_settings.get(&a.key) {
                state.setting_hashes.insert(a.key.clone(), h.clone());
            }
        }
        for a in r.applied.iter().filter(|a| a.kind != "setting") {
            state.known.insert(a.key.clone(), a.rev);
            match sent.get(&a.key) {
                Some(h) if !a.deleted => {
                    state.hashes.insert(a.key.clone(), h.clone());
                }
                _ => {
                    state.hashes.remove(&a.key);
                }
            }
            if a.deleted {
                state.known.remove(&a.key);
            }
            state.deleted.remove(&a.key);
        }
        changed |= apply(state, &mut list, &r.conflicts, &mut rekeyed);
        apply_settings(state, &mut values, &r.conflicts, &mut setting_changes);
    }
    Ok(SyncOutcome {
        servers: list,
        changed,
        rekeyed,
        settings: setting_changes,
    })
}
