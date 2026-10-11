//! One monitor login on one TeamTalk server, kept up for as long as the
//! monitor runs: connects (plain or TLS), logs in, pings so the server
//! keeps the login, sends commands and matches their replies, and
//! reconnects with a growing delay when the link drops.

use std::collections::HashMap;
use std::net::{IpAddr, SocketAddr};
use std::sync::Arc;
use std::time::Duration;

use anyhow::{Context, anyhow, bail};
use rustls::pki_types::ServerName;
use tokio::io::{AsyncBufReadExt, AsyncRead, AsyncWrite, AsyncWriteExt, BufReader};
use tokio::net::TcpStream;
use tokio::sync::{mpsc, oneshot, watch};
use tokio::time::{Instant, sleep, timeout};

use super::line::Line;
use super::state::ConnectionStatus;

/// Version the monitor reports in its login, like other clients do.
pub const CLIENT_VERSION: &str = "5.22.0";
/// Protocol level the monitor speaks (the same as TTCom).
pub const PROTOCOL: &str = "5.14";

const COMMAND_TIMEOUT: Duration = Duration::from_secs(30);
const MIN_RETRY: Duration = Duration::from_secs(2);
const MAX_RETRY: Duration = Duration::from_secs(60);
const LOGIN_FAILED_RETRY: Duration = Duration::from_secs(300);
/// A login that lasted this long resets the retry delay.
const STABLE_LOGIN: Duration = Duration::from_secs(60);
/// Waits after the same account logged in somewhere else and the server
/// logged the monitor out. Logging straight back in would throw the person
/// off in turn, so the monitor steps aside for longer each time.
const DISPLACED_RETRY: [Duration; 4] = [
    Duration::from_secs(2 * 60),
    Duration::from_secs(5 * 60),
    Duration::from_secs(10 * 60),
    Duration::from_secs(15 * 60),
];

#[derive(Debug, Clone, PartialEq)]
pub struct Target {
    pub host: String,
    pub tcp_port: u16,
    pub encrypted: bool,
    /// Allow private, loopback and other non-public addresses. Off for the
    /// public service, where anyone picks the hosts: the monitor must not
    /// become a way into the machine it runs on or its network.
    pub allow_private: bool,
}

/// Whether an address is on the public internet.
pub fn is_public(ip: IpAddr) -> bool {
    match ip {
        IpAddr::V4(v4) => {
            let o = v4.octets();
            !(v4.is_loopback()
                || v4.is_private()
                || v4.is_link_local()
                || v4.is_unspecified()
                || v4.is_broadcast()
                || v4.is_multicast()
                || v4.is_documentation()
                || o[0] == 0
                || (o[0] == 100 && (64..128).contains(&o[1]))
                || (o[0] == 192 && o[1] == 0 && o[2] == 0)
                || (o[0] == 198 && (18..20).contains(&o[1]))
                || o[0] >= 240)
        }
        IpAddr::V6(v6) => {
            if let Some(v4) = v6.to_ipv4_mapped() {
                return is_public(IpAddr::V4(v4));
            }
            let seg = v6.segments();
            !(v6.is_loopback()
                || v6.is_unspecified()
                || v6.is_multicast()
                || (seg[0] & 0xfe00) == 0xfc00
                || (seg[0] & 0xffc0) == 0xfe80
                || (seg[0] == 0x2001 && seg[1] == 0x0db8))
        }
    }
}

/// The addresses to connect to for a target, refusing non-public ones
/// unless allowed.
pub async fn resolve(target: &Target) -> anyhow::Result<Vec<SocketAddr>> {
    let addrs: Vec<SocketAddr> = timeout(Duration::from_secs(10), tokio::net::lookup_host((target.host.as_str(), target.tcp_port)))
        .await
        .map_err(|_| anyhow!("Looking up {} timed out", target.host))?
        .with_context(|| format!("There is no server called {}", target.host))?
        .collect();
    if addrs.is_empty() {
        bail!("There is no server called {}", target.host);
    }
    if target.allow_private {
        return Ok(addrs);
    }
    let public: Vec<SocketAddr> = addrs.into_iter().filter(|a| is_public(a.ip())).collect();
    if public.is_empty() {
        bail!("{} is a private or local address; the monitor can only reach servers on the internet", target.host);
    }
    Ok(public)
}

/// The status mode bits that say a user's gender: female (256) and neutral
/// (4096). Neither means male.
pub const GENDER_BITS: i64 = 0x100 | 0x1000;

#[derive(Debug, Clone, PartialEq)]
pub struct Login {
    pub nickname: String,
    pub username: String,
    pub password: String,
    pub client_name: String,
    pub status_msg: String,
    /// Gender bits of the status mode (see [`GENDER_BITS`]).
    pub status_mode: i64,
    /// Channel path to join after login, such as `/Lobby/`; empty stays out
    /// of every channel.
    pub channel: String,
    pub channel_password: String,
}

/// Receives everything a session sees. Called from the session's task, in
/// order.
pub trait Sink: Send + Sync + 'static {
    fn status(&self, status: ConnectionStatus, reason: Option<String>);
    fn line(&self, line: &Line);
}

#[derive(Debug, Clone, thiserror::Error, PartialEq)]
pub enum CommandError {
    #[error("not logged in to the server")]
    NotConnected,
    #[error("the server did not answer in time")]
    Timeout,
    #[error("TeamTalk error {number}: {message}")]
    Server { number: i64, message: String },
}

struct Request {
    line: Line,
    reply: oneshot::Sender<Result<Vec<Line>, CommandError>>,
}

/// Commands go to the session through this; dropping every handle (or
/// calling `stop`) logs out and ends the session.
#[derive(Clone)]
pub struct SessionHandle {
    tx: mpsc::Sender<Request>,
    stop: Arc<watch::Sender<bool>>,
    /// The nickname and status to log in with next time.
    presence: Arc<watch::Sender<Presence>>,
}

/// How the monitor appears to others: what it can change while logged in.
#[derive(Debug, Clone, PartialEq)]
pub struct Presence {
    pub nickname: String,
    pub status_mode: i64,
    pub status_msg: String,
}

impl SessionHandle {
    /// Send a command and wait for the server's reply: the lines between
    /// its `begin` and `end`, or the error it reported.
    pub async fn command(&self, line: Line) -> Result<Vec<Line>, CommandError> {
        let (reply, rx) = oneshot::channel();
        self.tx.send(Request { line, reply }).await.map_err(|_| CommandError::NotConnected)?;
        rx.await.unwrap_or(Err(CommandError::NotConnected))
    }

    pub fn stop(&self) {
        let _ = self.stop.send(true);
    }

    /// Change the monitor's nickname and status without logging in again:
    /// now, if it is logged in, and at every later login.
    pub fn set_presence(&self, new: Presence) {
        let old = self.presence.send_replace(new.clone());
        let mut lines = Vec::new();
        if new.nickname != old.nickname {
            lines.push(Line::new("changenick").with("nickname", new.nickname.as_str()));
        }
        if (new.status_mode, &new.status_msg) != (old.status_mode, &old.status_msg) {
            lines.push(Line::new("changestatus").with("statusmode", new.status_mode).with("statusmsg", new.status_msg.as_str()));
        }
        if lines.is_empty() {
            return;
        }
        let me = self.clone();
        tokio::spawn(async move {
            for line in lines {
                if let Err(e) = me.command(line).await {
                    tracing::debug!("presence change not sent now: {e}");
                }
            }
        });
    }

    /// The status the monitor already took: kept for later logins.
    pub fn remember_status(&self, mode: i64, msg: &str) {
        self.presence.send_modify(|p| (p.status_mode, p.status_msg) = (mode, msg.to_owned()));
    }

    /// The nickname the monitor already took: kept for later logins.
    pub fn remember_nickname(&self, nickname: &str) {
        self.presence.send_modify(|p| p.nickname = nickname.to_owned());
    }
}

pub fn spawn(target: Target, login: Login, sink: Arc<dyn Sink>) -> SessionHandle {
    let (tx, rx) = mpsc::channel(64);
    let (stop_tx, stop_rx) = watch::channel(false);
    let (presence_tx, presence_rx) = watch::channel(Presence {
        nickname: login.nickname.clone(),
        status_mode: login.status_mode,
        status_msg: login.status_msg.clone(),
    });
    tokio::spawn(run(target, login, sink, rx, stop_rx, presence_rx));
    SessionHandle { tx, stop: Arc::new(stop_tx), presence: Arc::new(presence_tx) }
}

enum Ended {
    Stopped,
    /// The same account logged in elsewhere on a server that allows one
    /// login per account.
    Displaced,
    Lost(String),
    LoginFailed(String),
}

async fn run(target: Target, mut login: Login, sink: Arc<dyn Sink>, mut rx: mpsc::Receiver<Request>, mut stop: watch::Receiver<bool>, presence: watch::Receiver<Presence>) {
    let mut retry = MIN_RETRY;
    let mut displaced = 0usize;
    loop {
        if *stop.borrow() {
            return;
        }
        sink.status(ConnectionStatus::Connecting, None);
        let p = presence.borrow().clone();
        (login.nickname, login.status_mode, login.status_msg) = (p.nickname, p.status_mode, p.status_msg);
        let started = Instant::now();
        let ended = match connect(&target).await {
            Ok(stream) => drive(stream, &login, sink.as_ref(), &mut rx, &mut stop).await,
            Err(e) => Ended::Lost(format!("{e:#}")),
        };
        let wait = match ended {
            Ended::Stopped => {
                sink.status(ConnectionStatus::Disconnected, Some("Stopped".into()));
                return;
            }
            Ended::Lost(reason) => {
                tracing::info!(host = %target.host, %reason, "disconnected");
                sink.status(ConnectionStatus::Disconnected, Some(reason));
                if started.elapsed() >= STABLE_LOGIN {
                    retry = MIN_RETRY;
                }
                let wait = retry;
                retry = (retry * 2).min(MAX_RETRY);
                wait
            }
            Ended::LoginFailed(reason) => {
                tracing::warn!(host = %target.host, %reason, "login refused");
                sink.status(ConnectionStatus::LoginFailed, Some(reason));
                LOGIN_FAILED_RETRY
            }
            Ended::Displaced => {
                if started.elapsed() >= Duration::from_secs(60 * 60) {
                    displaced = 0;
                }
                let wait = DISPLACED_RETRY[displaced.min(DISPLACED_RETRY.len() - 1)];
                displaced += 1;
                tracing::info!(host = %target.host, minutes = wait.as_secs() / 60, "displaced by another login");
                sink.status(
                    ConnectionStatus::SteppedAside,
                    Some(format!("Someone logged in with the same account, so the monitor stepped aside. It tries again in {} minutes.", wait.as_secs() / 60)),
                );
                wait
            }
        };
        // Wait to reconnect; commands sent meanwhile fail straight away.
        let until = Instant::now() + wait;
        loop {
            tokio::select! {
                _ = tokio::time::sleep_until(until) => break,
                _ = stop.changed() => return,
                req = rx.recv() => match req {
                    Some(req) => { let _ = req.reply.send(Err(CommandError::NotConnected)); }
                    None => return,
                },
            }
        }
    }
}

trait Stream: AsyncRead + AsyncWrite + Unpin + Send {}
impl<T: AsyncRead + AsyncWrite + Unpin + Send> Stream for T {}

async fn connect(target: &Target) -> anyhow::Result<Box<dyn Stream>> {
    let addrs = resolve(target).await?;
    let tcp = timeout(Duration::from_secs(15), TcpStream::connect(&addrs[..]))
        .await
        .map_err(|_| anyhow!("Connecting to {}:{} timed out", target.host, target.tcp_port))?
        .with_context(|| format!("Could not connect to {}:{}", target.host, target.tcp_port))?;
    tcp.set_nodelay(true).ok();
    if !target.encrypted {
        return Ok(Box::new(tcp));
    }
    let config = rustls::ClientConfig::builder_with_provider(Arc::new(rustls::crypto::ring::default_provider()))
        .with_safe_default_protocol_versions()?
        .dangerous()
        .with_custom_certificate_verifier(Arc::new(AcceptAnyCertificate))
        .with_no_client_auth();
    let name = ServerName::try_from(target.host.clone()).unwrap_or_else(|_| ServerName::try_from("teamtalk").unwrap());
    let tls = tokio_rustls::TlsConnector::from(Arc::new(config))
        .connect(name, tcp)
        .await
        .context("Encrypted connection failed (is the server really encrypted?)")?;
    Ok(Box::new(tls))
}

struct Pending {
    reply: Option<oneshot::Sender<Result<Vec<Line>, CommandError>>>,
    lines: Vec<Line>,
    error: Option<CommandError>,
    sent: Instant,
}

/// Ping often enough that the server never times the login out (the same
/// margins TTCom uses).
fn ping_interval(user_timeout: i64) -> Duration {
    let t = user_timeout.max(1) as f64;
    let secs = if t <= 15.0 {
        (t * 0.25).max(0.3)
    } else if t <= 30.0 {
        t * 0.3125
    } else if t <= 60.0 {
        t * 0.5
    } else if t <= 90.0 {
        t * 0.625
    } else {
        t * 0.75
    };
    Duration::from_secs_f64(secs)
}

async fn drive(stream: Box<dyn Stream>, login: &Login, sink: &dyn Sink, rx: &mut mpsc::Receiver<Request>, stop: &mut watch::Receiver<bool>) -> Ended {
    let (read, mut write) = tokio::io::split(stream);
    // Lines are read in their own task: a read cut short by another branch
    // of the select below would lose part of a line.
    let (line_tx, mut lines) = mpsc::channel::<anyhow::Result<Option<Line>>>(256);
    let reader = tokio::spawn(async move {
        let mut reader = BufReader::new(read);
        let mut buf = Vec::new();
        loop {
            let read = read_line(&mut reader, &mut buf).await;
            let last = !matches!(read, Ok(Some(_)));
            if line_tx.send(read).await.is_err() || last {
                break;
            }
        }
    });
    let _reader = AbortOnDrop(reader);
    let mut next = async || lines.recv().await.unwrap_or(Ok(None));

    async fn send(write: &mut (impl AsyncWrite + Unpin), line: &Line) -> std::io::Result<()> {
        tracing::trace!(">> {line}");
        write.write_all(format!("{line}\r\n").as_bytes()).await
    }

    // The server speaks first.
    let welcome = match timeout(Duration::from_secs(15), next()).await {
        Ok(Ok(Some(l))) if l.name == "teamtalk" || l.name == "welcome" => l,
        Ok(Ok(Some(l))) => return Ended::Lost(format!("Not a TeamTalk server (it said \"{}\")", l.name)),
        Ok(Ok(None)) => return Ended::Lost("The server closed the connection".into()),
        Ok(Err(e)) => return Ended::Lost(format!("Reading from the server failed: {e}")),
        Err(_) => return Ended::Lost("The server did not greet the monitor".into()),
    };
    let mut user_timeout = welcome.int("usertimeout").unwrap_or(60);
    sink.line(&welcome);
    sink.status(ConnectionStatus::Connected, None);

    let mut next_id: i64 = 1;
    let mut pending: HashMap<i64, Pending> = HashMap::new();
    let mut current: Option<i64> = None;

    let login_id = next_id;
    next_id += 1;
    let login_line = Line::new("login")
        .with("nickname", login.nickname.as_str())
        .with("username", login.username.as_str())
        .with("password", login.password.as_str())
        .with("clientname", login.client_name.as_str())
        .with("version", CLIENT_VERSION)
        .with("protocol", PROTOCOL)
        .with("id", login_id);
    if let Err(e) = send(&mut write, &login_line).await {
        return Ended::Lost(format!("Sending the login failed: {e}"));
    }
    pending.insert(login_id, Pending { reply: None, lines: Vec::new(), error: None, sent: Instant::now() });
    let mut logged_in = false;
    // The server kicked the monitor itself (not a person): on servers
    // allowing one login per account, that means the account logged in
    // elsewhere.
    let mut kicked_by_server = false;
    // Channel paths seen during login, to find the channel to join.
    let mut channel_paths: HashMap<String, i64> = HashMap::new();

    // A short first ping, as TTCom does, then at the regular interval.
    let mut next_ping = Instant::now() + ping_interval(user_timeout).min(Duration::from_secs(5));
    let mut housekeeping = tokio::time::interval(Duration::from_secs(1));

    loop {
        tokio::select! {
            read = next() => {
                let line = match read {
                    Ok(Some(l)) => l,
                    Ok(None) => return Ended::Lost("The server closed the connection".into()),
                    Err(e) => return Ended::Lost(format!("Reading from the server failed: {e}")),
                };
                match line.name.as_str() {
                    "begin" => { current = line.int("id"); continue; }
                    "end" => {
                        let id = line.int("id");
                        current = None;
                        let Some(id) = id else { continue };
                        let Some(p) = pending.remove(&id) else { continue };
                        if id == login_id {
                            if let Some(e) = p.error {
                                let reason = match e { CommandError::Server { message, .. } => message, e => e.to_string() };
                                return Ended::LoginFailed(reason);
                            }
                            logged_in = true;
                            sink.status(ConnectionStatus::LoggedIn, None);
                            for l in after_login(login, &channel_paths) {
                                let id = next_id;
                                next_id += 1;
                                if send(&mut write, &l.with("id", id)).await.is_err() {
                                    return Ended::Lost("Sending to the server failed".into());
                                }
                                pending.insert(id, Pending { reply: None, lines: Vec::new(), error: None, sent: Instant::now() });
                            }
                        } else if let Some(reply) = p.reply {
                            let _ = reply.send(match p.error { Some(e) => Err(e), None => Ok(p.lines) });
                        } else if let Some(e) = p.error {
                            tracing::warn!("command after login failed: {e}");
                        }
                        continue;
                    }
                    // The server answering the monitor's own pings.
                    "pong" if current.is_none() => continue,
                    _ => {}
                }
                if let Some(id) = current
                    && let Some(p) = pending.get_mut(&id) {
                        if line.name == "error" {
                            p.error = Some(CommandError::Server { number: line.int("number").unwrap_or(0), message: line.text("message") });
                        } else {
                            p.lines.push(line.clone());
                        }
                    }
                if line.name == "addchannel" && !logged_in
                    && let (Some(path), Some(id)) = (line.str("channel"), line.int("chanid")) {
                        channel_paths.insert(path.to_lowercase(), id);
                    }
                if line.name == "serverupdate"
                    && let Some(t) = line.int("usertimeout") {
                        if t < user_timeout {
                            next_ping = Instant::now();
                        }
                        user_timeout = t;
                    }
                if line.name == "kicked" && line.int("kickerid").unwrap_or(0) == 0 && line.int("chanid").unwrap_or(0) == 0 {
                    kicked_by_server = true;
                }
                if line.name == "loggedout" && !line.has("userid") {
                    sink.line(&line);
                    if kicked_by_server {
                        return Ended::Displaced;
                    }
                    return Ended::Lost("Logged out by the server".into());
                }
                sink.line(&line);
            }
            req = rx.recv() => {
                let Some(req) = req else {
                    let _ = send(&mut write, &Line::new("quit")).await;
                    return Ended::Stopped;
                };
                if !logged_in {
                    let _ = req.reply.send(Err(CommandError::NotConnected));
                    continue;
                }
                let id = next_id;
                next_id += 1;
                if let Err(e) = send(&mut write, &req.line.clone().with("id", id)).await {
                    let _ = req.reply.send(Err(CommandError::NotConnected));
                    return Ended::Lost(format!("Sending to the server failed: {e}"));
                }
                pending.insert(id, Pending { reply: Some(req.reply), lines: Vec::new(), error: None, sent: Instant::now() });
            }
            _ = tokio::time::sleep_until(next_ping) => {
                if let Err(e) = write.write_all(b"ping\r\n").await {
                    return Ended::Lost(format!("Sending a ping failed: {e}"));
                }
                next_ping = Instant::now() + ping_interval(user_timeout);
            }
            _ = housekeeping.tick() => {
                let expired: Vec<i64> = pending.iter().filter(|(_, p)| p.sent.elapsed() > COMMAND_TIMEOUT).map(|(id, _)| *id).collect();
                for id in expired {
                    if id == login_id {
                        return Ended::Lost("The server did not answer the login".into());
                    }
                    if let Some(Pending { reply: Some(reply), .. }) = pending.remove(&id) {
                        let _ = reply.send(Err(CommandError::Timeout));
                    }
                }
            }
            _ = stop.changed() => {
                let _ = send(&mut write, &Line::new("quit")).await;
                let _ = write.flush().await;
                // Give the server a moment to see the quit.
                sleep(Duration::from_millis(100)).await;
                return Ended::Stopped;
            }
        }
    }
}

struct AbortOnDrop(tokio::task::JoinHandle<()>);

impl Drop for AbortOnDrop {
    fn drop(&mut self) {
        self.0.abort();
    }
}

/// What the monitor does once logged in: set its status message and join
/// its channel, if it has them.
fn after_login(login: &Login, channel_paths: &HashMap<String, i64>) -> Vec<Line> {
    let mut lines = Vec::new();
    if !login.status_msg.is_empty() || login.status_mode != 0 {
        lines.push(Line::new("changestatus").with("statusmode", login.status_mode).with("statusmsg", login.status_msg.as_str()));
    }
    if !login.channel.is_empty() {
        let path = super::state::normalize_path(&login.channel).to_lowercase();
        let Some(&id) = channel_paths.get(&path) else {
            tracing::warn!(channel = %login.channel, "the channel to join does not exist");
            return lines;
        };
        let mut join = Line::new("join").with("chanid", id);
        if !login.channel_password.is_empty() {
            join.set("password", login.channel_password.as_str());
        }
        lines.push(join);
    }
    lines
}

/// Read one line, skipping blank ones. `None` means the server closed the
/// connection.
async fn read_line<R: tokio::io::AsyncBufRead + Unpin>(reader: &mut R, buf: &mut Vec<u8>) -> anyhow::Result<Option<Line>> {
    loop {
        buf.clear();
        let n = reader.read_until(b'\n', buf).await?;
        if n == 0 {
            return Ok(None);
        }
        if buf.len() > 1 << 20 {
            bail!("line too long");
        }
        let text = String::from_utf8_lossy(buf);
        if text.trim().is_empty() {
            continue;
        }
        tracing::trace!("<< {}", text.trim_end());
        match Line::parse(&text) {
            Ok(l) => return Ok(Some(l)),
            Err(e) => tracing::warn!("{e}"),
        }
    }
}

/// TeamTalk servers almost always use self-signed certificates, and
/// TeamTalk clients do not check them unless told to; the monitor does the
/// same.
#[derive(Debug)]
struct AcceptAnyCertificate;

impl rustls::client::danger::ServerCertVerifier for AcceptAnyCertificate {
    fn verify_server_cert(
        &self,
        _: &rustls::pki_types::CertificateDer<'_>,
        _: &[rustls::pki_types::CertificateDer<'_>],
        _: &ServerName<'_>,
        _: &[u8],
        _: rustls::pki_types::UnixTime,
    ) -> Result<rustls::client::danger::ServerCertVerified, rustls::Error> {
        Ok(rustls::client::danger::ServerCertVerified::assertion())
    }

    fn verify_tls12_signature(
        &self,
        message: &[u8],
        cert: &rustls::pki_types::CertificateDer<'_>,
        dss: &rustls::DigitallySignedStruct,
    ) -> Result<rustls::client::danger::HandshakeSignatureValid, rustls::Error> {
        rustls::crypto::verify_tls12_signature(message, cert, dss, &rustls::crypto::ring::default_provider().signature_verification_algorithms)
    }

    fn verify_tls13_signature(
        &self,
        message: &[u8],
        cert: &rustls::pki_types::CertificateDer<'_>,
        dss: &rustls::DigitallySignedStruct,
    ) -> Result<rustls::client::danger::HandshakeSignatureValid, rustls::Error> {
        rustls::crypto::verify_tls13_signature(message, cert, dss, &rustls::crypto::ring::default_provider().signature_verification_algorithms)
    }

    fn supported_verify_schemes(&self) -> Vec<rustls::SignatureScheme> {
        rustls::crypto::ring::default_provider().signature_verification_algorithms.supported_schemes()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_public_addresses_count() {
        for private in ["127.0.0.1", "10.1.2.3", "192.168.0.5", "172.16.9.9", "100.64.0.1", "169.254.1.1", "0.0.0.0", "::1", "fd00::1", "fe80::1", "::ffff:127.0.0.1"] {
            assert!(!is_public(private.parse().unwrap()), "{private}");
        }
        for public in ["13.140.42.143", "8.8.8.8", "2606:4700::1111"] {
            assert!(is_public(public.parse().unwrap()), "{public}");
        }
    }

    #[tokio::test]
    async fn refuses_local_hosts_unless_allowed() {
        let mut t = Target { host: "localhost".into(), tcp_port: 10333, encrypted: false, allow_private: false };
        assert!(resolve(&t).await.unwrap_err().to_string().contains("private or local"));
        t.allow_private = true;
        assert!(!resolve(&t).await.unwrap().is_empty());
    }

    #[test]
    fn pings_well_within_the_timeout() {
        assert_eq!(ping_interval(60), Duration::from_secs(30));
        assert_eq!(ping_interval(4), Duration::from_secs(1));
        assert!(ping_interval(300) < Duration::from_secs(300));
    }
}
