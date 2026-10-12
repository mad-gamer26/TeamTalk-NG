//! `ngmon.toml`: where the monitor listens, where it keeps its data, its
//! limits, and how it sends push notifications.

use std::path::{Path, PathBuf};

use anyhow::Context;
use serde::Deserialize;

pub const DEFAULT_CONFIG: &str = "ngmon.toml";

#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Config {
    /// Address for the app's API, behind an HTTPS proxy.
    #[serde(default = "default_listen")]
    pub listen: String,
    /// Folder for the database; relative paths are relative to this file.
    #[serde(default = "default_data_dir")]
    pub data_dir: PathBuf,
    /// The key that encrypts stored server passwords; made on first start.
    /// Keep it out of database backups, and back it up on its own: without
    /// it the stored passwords cannot be read.
    #[serde(default = "default_secret_key_file")]
    pub secret_key_file: PathBuf,
    /// The client name other TeamTalk users see for the monitor.
    #[serde(default = "default_client_name")]
    pub client_name: String,
    /// Let people monitor servers at private or local addresses. Only for
    /// testing: on the public service it would let anyone reach the
    /// monitor's own machine and network.
    #[serde(default)]
    pub allow_private_hosts: bool,
    #[serde(default)]
    pub limits: Limits,
    #[serde(default)]
    pub push: PushConfig,
    /// How NG Account emails its sign-up and password reset codes.
    #[serde(default)]
    pub mail: MailConfig,
    /// Where sound pack files are kept; relative paths are relative to
    /// this file.
    #[serde(default = "default_packs_dir")]
    pub packs_dir: PathBuf,
}

#[derive(Debug, Clone, Copy, Default, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum MailMode {
    /// No email: nobody can make an NG Account or reset a password.
    #[default]
    None,
    /// Through an SMTP relay (STARTTLS).
    Smtp,
    /// Written as files into `outbox` instead of sent (for tests).
    Outbox,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct MailConfig {
    #[serde(default)]
    pub mode: MailMode,
    /// Who the codes come from, such as `TeamTalk NG <no-reply@example.com>`.
    #[serde(default = "default_mail_from")]
    pub from: String,
    #[serde(default)]
    pub smtp: Option<SmtpConfig>,
    /// The folder for `outbox` mode.
    #[serde(default)]
    pub outbox: Option<PathBuf>,
}

impl Default for MailConfig {
    fn default() -> Self {
        MailConfig { mode: MailMode::None, from: default_mail_from(), smtp: None, outbox: None }
    }
}

#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct SmtpConfig {
    pub host: String,
    #[serde(default = "default_smtp_port")]
    pub port: u16,
    pub username: String,
    /// A file holding the password only, kept private (relative paths
    /// are relative to this file).
    pub password_file: PathBuf,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Limits {
    /// Servers one app install may monitor.
    #[serde(default = "default_per_device")]
    pub servers_per_device: i64,
    /// Servers monitored in all.
    #[serde(default = "default_total")]
    pub servers_total: i64,
    /// New app installs accepted per address per hour.
    #[serde(default = "default_registrations")]
    pub registrations_per_address_per_hour: usize,
}

impl Default for Limits {
    fn default() -> Self {
        Limits { servers_per_device: default_per_device(), servers_total: default_total(), registrations_per_address_per_hour: default_registrations() }
    }
}

#[derive(Debug, Clone, Copy, Default, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum PushMode {
    /// No push notifications (the app still gets everything live).
    #[default]
    None,
    /// To Apple with the app's APNs key.
    Apns,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct PushConfig {
    #[serde(default)]
    pub mode: PushMode,
    /// Seal notification text so only the device it is for can read it;
    /// Apple sees a placeholder.
    #[serde(default = "yes")]
    pub encrypt: bool,
    #[serde(default)]
    pub apns: Option<ApnsConfig>,
}

impl Default for PushConfig {
    fn default() -> Self {
        PushConfig { mode: PushMode::None, encrypt: true, apns: None }
    }
}

#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ApnsConfig {
    /// The `.p8` key from the Apple Developer site.
    pub key_file: String,
    pub key_id: String,
    pub team_id: String,
    /// The app's bundle identifier.
    #[serde(default = "default_topic")]
    pub topic: String,
    /// Send somewhere other than Apple, such as `http://127.0.0.1:18651`
    /// (for tests).
    #[serde(default)]
    pub endpoint: Option<String>,
}

fn default_mail_from() -> String {
    "TeamTalk NG <no-reply@example.com>".into()
}

fn default_smtp_port() -> u16 {
    587
}

fn default_packs_dir() -> PathBuf {
    "packs".into()
}

fn default_listen() -> String {
    "127.0.0.1:8650".into()
}

fn default_secret_key_file() -> PathBuf {
    PathBuf::from("secret.key")
}

fn default_data_dir() -> PathBuf {
    "data".into()
}

fn default_client_name() -> String {
    "TeamTalk NG Monitor".into()
}

fn default_topic() -> String {
    "com.matthewdovi.TeamTalk-NG".into()
}

fn default_per_device() -> i64 {
    10
}

fn default_total() -> i64 {
    2000
}

fn default_registrations() -> usize {
    20
}

fn yes() -> bool {
    true
}

impl Config {
    /// Read the config file; a missing file gives the defaults.
    pub fn load(path: &Path) -> anyhow::Result<Config> {
        let mut cfg: Config = match std::fs::read_to_string(path) {
            Ok(text) => toml::from_str(&text).with_context(|| format!("{} has a mistake", path.display()))?,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => toml::from_str("")?,
            Err(e) => return Err(e).with_context(|| format!("Could not read {}", path.display())),
        };
        let base = path.parent().filter(|p| !p.as_os_str().is_empty()).unwrap_or(Path::new("."));
        if cfg.data_dir.is_relative() {
            cfg.data_dir = base.join(&cfg.data_dir);
        }
        if cfg.secret_key_file.is_relative() {
            cfg.secret_key_file = base.join(&cfg.secret_key_file);
        }
        if cfg.packs_dir.is_relative() {
            cfg.packs_dir = base.join(&cfg.packs_dir);
        }
        if let Some(smtp) = cfg.mail.smtp.as_mut()
            && smtp.password_file.is_relative()
        {
            smtp.password_file = base.join(&smtp.password_file);
        }
        if let Some(outbox) = cfg.mail.outbox.as_mut()
            && outbox.is_relative()
        {
            *outbox = base.join(&*outbox);
        }
        if let Some(apns) = cfg.push.apns.as_mut()
            && Path::new(&apns.key_file).is_relative()
        {
            apns.key_file = base.join(&apns.key_file).to_string_lossy().into_owned();
        }
        Ok(cfg)
    }

    pub fn database(&self) -> PathBuf {
        self.data_dir.join("ngmon.sqlite")
    }

    /// The database, with stored passwords encrypted by the secret key.
    pub fn open_store(&self) -> anyhow::Result<crate::store::Store> {
        crate::store::Store::open(&self.database(), crate::store::secret_key(&self.secret_key_file)?)
    }
}

pub const SAMPLE: &str = r#"# TeamTalk NG Monitor settings.

# Where the app's API listens; put an HTTPS proxy in front.
listen = "127.0.0.1:8650"

# Database folder, relative to this file.
data_dir = "data"

# Sound pack files for NG Account, relative to this file.
packs_dir = "packs"

# The key that encrypts stored server passwords, made on first start. Back
# it up separately from the database.
secret_key_file = "secret.key"

# What other TeamTalk users see as the monitor's client.
client_name = "TeamTalk NG Monitor"

[limits]
servers_per_device = 10
servers_total = 2000
registrations_per_address_per_hour = 20

[push]
# "none" or "apns".
mode = "none"
# Seal notification text so Apple sees only a placeholder.
encrypt = true

# [push.apns]
# key_file = "AuthKey_XXXXXXXXXX.p8"
# key_id = "XXXXXXXXXX"
# team_id = "5NJK4F832Z"
# topic = "com.matthewdovi.TeamTalk-NG"

[mail]
# How NG Account emails sign-up and password reset codes: "none" (no
# accounts), "smtp", or "outbox" (files in a folder, for tests).
mode = "none"
from = "TeamTalk NG <no-reply@example.com>"

# [mail.smtp]
# host = "smtp-relay.example.com"
# port = 587
# username = "you@example.com"
# password_file = "smtp-password"
"#;

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sample_parses_and_defaults_apply() {
        let cfg: Config = toml::from_str(SAMPLE).unwrap();
        assert_eq!(cfg.listen, "127.0.0.1:8650");
        assert_eq!(cfg.push.mode, PushMode::None);
        assert!(cfg.push.encrypt && !cfg.allow_private_hosts);
        assert_eq!(cfg.limits.servers_per_device, 10);
        let empty: Config = toml::from_str("").unwrap();
        assert_eq!(empty.client_name, "TeamTalk NG Monitor");
    }

    #[test]
    fn rejects_misspelled_settings() {
        assert!(toml::from_str::<Config>("lisen = \"x\"").is_err());
    }
}
