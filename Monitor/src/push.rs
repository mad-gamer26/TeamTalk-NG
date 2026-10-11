//! Push notifications: which events a device wants to hear about, the
//! notification for each, sealing its text so only that device can read it,
//! and delivering it to Apple (APNs) with the app's key.
//!
//! Sealed, Apple sees only a placeholder: the app's notification service
//! extension opens the text with the key the device got when it
//! registered.

use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use anyhow::{Context as _, anyhow};
use base64::Engine;
use base64::engine::general_purpose::STANDARD as B64;
use chacha20poly1305::aead::{Aead, KeyInit};
use chacha20poly1305::{ChaCha20Poly1305, Key, Nonce};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use tokio::sync::mpsc;

use crate::config::{ApnsConfig, PushConfig, PushMode};
use crate::tt::state::{ConnectionStatus, Event, MessageKind};

/// Notification categories the app registers, with their actions.
pub const CATEGORY_PRIVATE_MESSAGE: &str = "TTNG_PRIVATE_MESSAGE";
pub const CATEGORY_CHANNEL_MESSAGE: &str = "TTNG_CHANNEL_MESSAGE";
pub const CATEGORY_PRESENCE: &str = "TTNG_PRESENCE";
pub const CATEGORY_BROADCAST: &str = "TTNG_BROADCAST";
pub const CATEGORY_CONNECTION: &str = "TTNG_CONNECTION";

/// Apple refuses payloads over 4 KB; text is cut to leave room.
const MAX_BODY_CHARS: usize = 1200;

#[derive(Debug, Clone, Copy, Default, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum Presence {
    #[default]
    All,
    /// Only people in `watched`.
    Watched,
    None,
}

#[derive(Debug, Clone, Copy, Default, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum ChannelMessages {
    All,
    /// Messages naming the monitor's nickname or a word in `mention_words`.
    #[default]
    Mentions,
    None,
}

/// What one device wants to be notified about.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(default)]
pub struct Prefs {
    pub logins: Presence,
    pub logouts: Presence,
    /// Usernames or nicknames, matched without regard to case.
    pub watched: Vec<String>,
    pub private_messages: bool,
    pub channel_messages: ChannelMessages,
    pub mention_words: Vec<String>,
    pub broadcasts: bool,
    /// The monitor lost a server for more than a minute, or was kicked.
    pub connection: bool,
    pub muted_servers: Vec<i64>,
    /// No notifications at all until this time (Unix milliseconds).
    pub muted_until: Option<i64>,
    /// People never to notify about, like `watched`.
    pub ignored: Vec<String>,
}

impl Default for Prefs {
    fn default() -> Self {
        Prefs {
            logins: Presence::All,
            logouts: Presence::All,
            watched: Vec::new(),
            private_messages: true,
            channel_messages: ChannelMessages::Mentions,
            mention_words: Vec::new(),
            broadcasts: true,
            connection: true,
            muted_servers: Vec::new(),
            muted_until: None,
            ignored: Vec::new(),
        }
    }
}

fn listed(list: &[String], nickname: &str, username: &str) -> bool {
    list.iter().any(|w| {
        let w = w.trim();
        !w.is_empty() && (w.eq_ignore_ascii_case(username) || w.to_lowercase() == nickname.to_lowercase())
    })
}

fn presence_wanted(p: Presence, prefs: &Prefs, nickname: &str, username: &str) -> bool {
    match p {
        Presence::All => true,
        Presence::Watched => listed(&prefs.watched, nickname, username),
        Presence::None => false,
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct Notification {
    pub title: String,
    pub subtitle: String,
    pub body: String,
    /// Groups notifications per server (and per conversation for PMs).
    pub thread: String,
    pub category: &'static str,
    /// A sound in the app's bundle.
    pub sound: &'static str,
    /// What the app needs to act on the notification (open the right
    /// screen, reply to the right person).
    pub data: Value,
}

/// Facts about the server an event happened on.
pub struct EventContext<'a> {
    pub server_id: i64,
    pub server_name: &'a str,
    /// The monitor's nickname there, for spotting mentions.
    pub monitor_nickname: &'a str,
    pub now_ms: i64,
}

/// The notification a device should get for an event, if any.
pub fn notification_for(prefs: &Prefs, ctx: &EventContext, event: &Event) -> Option<Notification> {
    if prefs.muted_until.is_some_and(|t| t > ctx.now_ms) || prefs.muted_servers.contains(&ctx.server_id) {
        return None;
    }
    let server = ctx.server_name.to_owned();
    let thread = format!("server-{}", ctx.server_id);
    let base = json!({ "server_id": ctx.server_id });
    let with = |extra: Value| {
        let mut d = base.clone();
        if let (Some(d), Some(e)) = (d.as_object_mut(), extra.as_object()) {
            d.extend(e.clone());
        }
        d
    };
    match event {
        Event::LoggedIn { user } | Event::LoggedOut { user } => {
            let logged_in = matches!(event, Event::LoggedIn { .. });
            let pref = if logged_in { prefs.logins } else { prefs.logouts };
            if listed(&prefs.ignored, &user.nickname, &user.username) || !presence_wanted(pref, prefs, &user.nickname, &user.username) {
                return None;
            }
            let name = user.display_name();
            Some(Notification {
                title: server,
                subtitle: String::new(),
                body: if logged_in { format!("{name} logged in") } else { format!("{name} logged out") },
                thread,
                category: CATEGORY_PRESENCE,
                sound: if logged_in { "logged_on.wav" } else { "logged_off.wav" },
                data: with(json!({ "event": if logged_in { "logged_in" } else { "logged_out" }, "user_id": user.id, "nickname": name, "username": user.username })),
            })
        }
        Event::Message { message: m } if !m.outgoing => {
            if listed(&prefs.ignored, &m.from.nickname, &m.from.username) {
                return None;
            }
            let text = shorten(&m.text);
            match m.kind {
                MessageKind::User if !m.intercepted => prefs.private_messages.then(|| Notification {
                    title: m.from.nickname.clone(),
                    subtitle: server,
                    body: text,
                    thread: format!("{thread}-pm-{}", m.from.id),
                    category: CATEGORY_PRIVATE_MESSAGE,
                    sound: "user_msg.wav",
                    data: with(json!({
                        "event": "private_message",
                        "user_id": m.from.id,
                        "nickname": m.from.nickname,
                        "username": m.from.username,
                    })),
                }),
                MessageKind::Channel if !m.intercepted => {
                    let wanted = match prefs.channel_messages {
                        ChannelMessages::All => true,
                        ChannelMessages::None => false,
                        ChannelMessages::Mentions => {
                            let lower = m.text.to_lowercase();
                            std::iter::once(ctx.monitor_nickname)
                                .chain(prefs.mention_words.iter().map(String::as_str))
                                .map(str::trim)
                                .any(|w| !w.is_empty() && lower.contains(&w.to_lowercase()))
                        }
                    };
                    wanted.then(|| Notification {
                        title: format!("{} in {}", m.from.nickname, m.channel_path.clone().unwrap_or_default()),
                        subtitle: server,
                        body: text,
                        thread: format!("{thread}-channel"),
                        category: CATEGORY_CHANNEL_MESSAGE,
                        sound: "channel_msg.wav",
                        data: with(json!({ "event": "channel_message", "channel_id": m.channel_id, "user_id": m.from.id })),
                    })
                }
                MessageKind::Broadcast => prefs.broadcasts.then(|| Notification {
                    title: format!("Broadcast from {}", m.from.nickname),
                    subtitle: server,
                    body: text,
                    thread,
                    category: CATEGORY_BROADCAST,
                    sound: "broadcast_msg.wav",
                    data: with(json!({ "event": "broadcast", "user_id": m.from.id })),
                }),
                _ => None,
            }
        }
        // Kicked by the server itself: the same account logged in
        // elsewhere, most likely this very person, so not news.
        Event::Kicked { by: None, channel_id: None } => None,
        Event::Kicked { by, channel_id } if prefs.connection => Some(Notification {
            title: server,
            subtitle: String::new(),
            body: match (by, channel_id) {
                (Some(by), Some(_)) => format!("{} kicked the monitor from its channel", by.nickname),
                (None, Some(_)) => "The monitor was kicked from its channel".into(),
                (Some(by), None) => format!("{} kicked the monitor from the server", by.nickname),
                (None, None) => "The monitor was kicked from the server".into(),
            },
            thread,
            category: CATEGORY_CONNECTION,
            sound: "serverlost.wav",
            data: with(json!({ "event": "kicked" })),
        }),
        // The hub raises this one itself after the monitor has been
        // disconnected for a while (see `Hub::check_still_down`).
        Event::Connection { status: ConnectionStatus::Disconnected | ConnectionStatus::LoginFailed, reason } if prefs.connection => Some(Notification {
            title: server,
            subtitle: String::new(),
            body: format!("The monitor lost the server{}", reason.as_deref().map(|r| format!(": {r}")).unwrap_or_default()),
            thread,
            category: CATEGORY_CONNECTION,
            sound: "serverlost.wav",
            data: with(json!({ "event": "connection_lost" })),
        }),
        _ => None,
    }
}

fn shorten(text: &str) -> String {
    if text.chars().count() <= MAX_BODY_CHARS {
        text.to_owned()
    } else {
        let mut s: String = text.chars().take(MAX_BODY_CHARS).collect();
        s.push('…');
        s
    }
}

/// Seal `plain` for the device holding `key`: base64 of nonce, ciphertext
/// and tag, which is CryptoKit's `ChaChaPoly.SealedBox(combined:)` layout.
pub fn seal(key: &[u8], plain: &[u8]) -> anyhow::Result<String> {
    let cipher = ChaCha20Poly1305::new(Key::from_slice(key));
    let nonce_bytes: [u8; 12] = rand::random();
    let sealed = cipher.encrypt(Nonce::from_slice(&nonce_bytes), plain).map_err(|_| anyhow!("encryption failed"))?;
    let mut out = nonce_bytes.to_vec();
    out.extend(sealed);
    Ok(B64.encode(out))
}

#[cfg(test)]
pub fn open(key: &[u8], sealed: &str) -> anyhow::Result<Vec<u8>> {
    let bytes = B64.decode(sealed)?;
    anyhow::ensure!(bytes.len() > 12, "too short");
    let cipher = ChaCha20Poly1305::new(Key::from_slice(key));
    cipher.decrypt(Nonce::from_slice(&bytes[..12]), &bytes[12..]).map_err(|_| anyhow!("decryption failed"))
}

/// The APNs payload for a notification. Sealed, Apple and the gateway see
/// only a placeholder; the app's notification service extension replaces it
/// with the real text from `ttng`.
pub fn payload(n: &Notification, push_key: Option<&[u8]>, app_ref: &str) -> anyhow::Result<Value> {
    let content = json!({ "title": n.title, "subtitle": n.subtitle, "body": n.body, "data": n.data });
    let mut aps = json!({
        "thread-id": n.thread,
        "category": n.category,
        "sound": n.sound,
        "mutable-content": 1,
    });
    let mut root = json!({});
    match push_key {
        Some(key) => {
            aps["alert"] = json!({ "title": "TeamTalk NG", "body": "New activity on a monitored server" });
            root["ttng"] = json!({ "v": 1, "ref": app_ref, "sealed": seal(key, &serde_json::to_vec(&content)?)? });
        }
        None => {
            let mut alert = json!({ "title": n.title, "body": n.body });
            if !n.subtitle.is_empty() {
                alert["subtitle"] = json!(n.subtitle);
            }
            aps["alert"] = alert;
            root["ttng"] = json!({ "v": 1, "ref": app_ref, "content": content });
        }
    }
    root["aps"] = aps;
    Ok(root)
}

#[derive(Debug, Clone)]
pub struct PushJob {
    pub apns_token: String,
    pub sandbox: bool,
    pub payload: Value,
    /// A silent check that the app is still installed: nothing is shown,
    /// but Apple refuses it when the app is gone.
    pub background: bool,
}

/// The payload of the daily silent check.
pub fn silent_payload() -> Value {
    json!({ "aps": { "content-available": 1 } })
}

#[derive(Debug, thiserror::Error)]
pub enum PushError {
    /// The device token is no longer valid; stop using it.
    #[error("device token no longer valid")]
    Unregistered,
    #[error("{0}")]
    Other(String),
}

/// Sends pushes to Apple with the app's key (token authentication).
pub struct Apns {
    http: reqwest::Client,
    key: jsonwebtoken::EncodingKey,
    key_id: String,
    team_id: String,
    pub topic: String,
    endpoint: Option<String>,
    jwt: Mutex<Option<(String, Instant)>>,
}

impl Apns {
    pub fn new(cfg: &ApnsConfig) -> anyhow::Result<Apns> {
        let pem = std::fs::read(&cfg.key_file).with_context(|| format!("Could not read the APNs key {}", cfg.key_file))?;
        let key = jsonwebtoken::EncodingKey::from_ec_pem(&pem).context("The APNs key is not a valid .p8 key")?;
        let http = reqwest::Client::builder().timeout(Duration::from_secs(20)).build()?;
        Ok(Apns { http, key, key_id: cfg.key_id.clone(), team_id: cfg.team_id.clone(), topic: cfg.topic.clone(), endpoint: cfg.endpoint.clone(), jwt: Mutex::new(None) })
    }

    fn token(&self) -> anyhow::Result<String> {
        let mut jwt = self.jwt.lock().unwrap();
        // Apple wants a new token at most every 20 minutes and at least
        // every hour.
        if let Some((t, made)) = jwt.as_ref()
            && made.elapsed() < Duration::from_secs(40 * 60) {
                return Ok(t.clone());
            }
        let mut header = jsonwebtoken::Header::new(jsonwebtoken::Algorithm::ES256);
        header.kid = Some(self.key_id.clone());
        let iat = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH)?.as_secs();
        let t = jsonwebtoken::encode(&header, &json!({ "iss": self.team_id, "iat": iat }), &self.key)?;
        *jwt = Some((t.clone(), Instant::now()));
        Ok(t)
    }

    pub async fn send(&self, job: &PushJob) -> Result<(), PushError> {
        let base = match &self.endpoint {
            Some(e) => e.trim_end_matches('/').to_owned(),
            None if job.sandbox => "https://api.sandbox.push.apple.com".into(),
            None => "https://api.push.apple.com".into(),
        };
        let token = self.token().map_err(|e| PushError::Other(e.to_string()))?;
        let res = self
            .http
            .post(format!("{base}/3/device/{}", job.apns_token))
            .bearer_auth(token)
            .header("apns-topic", &self.topic)
            .header("apns-push-type", if job.background { "background" } else { "alert" })
            .header("apns-priority", if job.background { "5" } else { "10" })
            .json(&job.payload)
            .send()
            .await
            .map_err(|e| PushError::Other(format!("Could not reach Apple: {e}")))?;
        let status = res.status();
        if status.is_success() {
            return Ok(());
        }
        let body = res.text().await.unwrap_or_default();
        if status.as_u16() == 410 || body.contains("BadDeviceToken") || body.contains("Unregistered") {
            return Err(PushError::Unregistered);
        }
        Err(PushError::Other(format!("Apple refused the push ({status}): {body}")))
    }
}

enum Sender {
    None,
    Apns(Apns),
}

impl Sender {
    async fn send(&self, job: &PushJob) -> Result<(), PushError> {
        match self {
            Sender::None => Ok(()),
            Sender::Apns(apns) => apns.send(job).await,
        }
    }
}

/// Whether payloads should be sealed for this configuration.
pub fn seals(cfg: &PushConfig) -> bool {
    cfg.encrypt && cfg.mode != PushMode::None
}

/// Start the task that delivers pushes. `unregistered` is told about device
/// tokens Apple no longer accepts.
pub fn start(cfg: &PushConfig, unregistered: impl Fn(String) + Send + Sync + 'static) -> anyhow::Result<mpsc::UnboundedSender<PushJob>> {
    let sender = match cfg.mode {
        PushMode::None => Sender::None,
        PushMode::Apns => Sender::Apns(Apns::new(cfg.apns.as_ref().context("push mode is \"apns\" but [push.apns] is missing")?)?),
    };
    let (tx, mut rx) = mpsc::unbounded_channel::<PushJob>();
    let sender = Arc::new(sender);
    let unregistered = Arc::new(unregistered);
    tokio::spawn(async move {
        while let Some(job) = rx.recv().await {
            let sender = sender.clone();
            let unregistered = unregistered.clone();
            tokio::spawn(async move {
                match sender.send(&job).await {
                    Ok(()) => {}
                    Err(PushError::Unregistered) => unregistered(job.apns_token.clone()),
                    Err(e) => tracing::warn!("push failed: {e}"),
                }
            });
        }
    });
    Ok(tx)
}

/// Counts requests per key in a sliding hour.
pub struct RateLimit {
    per_hour: usize,
    seen: Mutex<HashMap<String, Vec<Instant>>>,
}

impl RateLimit {
    pub fn new(per_hour: usize) -> Self {
        RateLimit { per_hour, seen: Mutex::new(HashMap::new()) }
    }

    pub fn allow(&self, key: &str) -> bool {
        let mut seen = self.seen.lock().unwrap();
        let hour = Duration::from_secs(3600);
        if seen.len() > 100_000 {
            seen.retain(|_, v| v.last().is_some_and(|t| t.elapsed() < hour));
        }
        let times = seen.entry(key.to_owned()).or_default();
        times.retain(|t| t.elapsed() < hour);
        if times.len() >= self.per_hour {
            return false;
        }
        times.push(Instant::now());
        true
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::tt::state::{TextMessage, User, UserRef};

    fn ctx() -> EventContext<'static> {
        EventContext { server_id: 7, server_name: "Home", monitor_nickname: "Matt", now_ms: 1_000 }
    }

    fn user(nick: &str, username: &str) -> User {
        User { id: 4, nickname: nick.into(), username: username.into(), ..Default::default() }
    }

    fn message(kind: MessageKind, text: &str) -> Event {
        Event::Message {
            message: TextMessage {
                kind,
                from: UserRef { id: 4, nickname: "Alice".into(), username: "alice".into() },
                to: None,
                channel_id: (kind == MessageKind::Channel).then_some(2),
                channel_path: (kind == MessageKind::Channel).then(|| "/Lobby/".into()),
                text: text.into(),
                outgoing: false,
                intercepted: false,
            },
        }
    }

    #[test]
    fn logins_follow_watch_list() {
        let mut p = Prefs::default();
        let e = Event::LoggedIn { user: user("Bob", "bob") };
        let n = notification_for(&p, &ctx(), &e).unwrap();
        assert_eq!(n.body, "Bob logged in");
        assert_eq!(n.sound, "logged_on.wav");
        p.logins = Presence::Watched;
        assert!(notification_for(&p, &ctx(), &e).is_none());
        p.watched = vec!["BOB".into()];
        assert!(notification_for(&p, &ctx(), &e).is_some());
        p.ignored = vec!["bob".into()];
        assert!(notification_for(&p, &ctx(), &e).is_none());
    }

    #[test]
    fn private_messages_carry_reply_details() {
        let n = notification_for(&Prefs::default(), &ctx(), &message(MessageKind::User, "hello")).unwrap();
        assert_eq!(n.title, "Alice");
        assert_eq!(n.category, CATEGORY_PRIVATE_MESSAGE);
        assert_eq!(n.data["user_id"], 4);
        assert_eq!(n.data["server_id"], 7);
    }

    #[test]
    fn channel_messages_need_a_mention_by_default() {
        let p = Prefs::default();
        assert!(notification_for(&p, &ctx(), &message(MessageKind::Channel, "hi all")).is_none());
        assert!(notification_for(&p, &ctx(), &message(MessageKind::Channel, "hey matt, you there")).is_some());
    }

    #[test]
    fn muting_silences_everything() {
        let p = Prefs { muted_until: Some(2_000), ..Default::default() };
        assert!(notification_for(&p, &ctx(), &message(MessageKind::User, "hi")).is_none());
        let p = Prefs { muted_servers: vec![7], ..Default::default() };
        assert!(notification_for(&p, &ctx(), &message(MessageKind::User, "hi")).is_none());
    }

    #[test]
    fn sealed_payloads_hide_the_text() {
        let key: [u8; 32] = rand::random();
        let n = notification_for(&Prefs::default(), &ctx(), &message(MessageKind::User, "secret plans")).unwrap();
        let p = payload(&n, Some(&key), "ref-1").unwrap();
        assert_eq!(p["ttng"]["ref"], "ref-1");
        let text = p.to_string();
        assert!(!text.contains("secret") && !text.contains("Alice"));
        let opened: Value = serde_json::from_slice(&open(&key, p["ttng"]["sealed"].as_str().unwrap()).unwrap()).unwrap();
        assert_eq!(opened["body"], "secret plans");
        assert_eq!(p["aps"]["mutable-content"], 1);
        assert_eq!(p["aps"]["category"], CATEGORY_PRIVATE_MESSAGE);
    }

    #[test]
    fn rate_limit_counts_per_key() {
        let r = RateLimit::new(2);
        assert!(r.allow("a") && r.allow("a"));
        assert!(!r.allow("a"));
        assert!(r.allow("b"));
    }
}
