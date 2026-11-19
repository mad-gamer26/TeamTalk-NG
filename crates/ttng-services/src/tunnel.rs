//! Reaching your own Monitor (`ng-monitor` on a home computer) through the
//! NG service's relay, end to end encrypted: pairing with the code it shows
//! (SPAKE2), then a Noise session per connection carrying the same API
//! calls as the hosted Monitor. The relay passes the pieces along and can't
//! read or change them.

use std::net::{TcpStream, ToSocketAddrs};
use std::sync::Arc;
use std::time::Duration;

use ng_relay::Keys;
use ng_relay::code::Code;
use ng_relay::pairing::AppPairing;
use ng_relay::rpc::Request;
use ng_relay::session::{Channel, Initiator};
use serde_json::{Value, json};
use tungstenite::stream::MaybeTlsStream;
use tungstenite::{Message, WebSocket};

use crate::ServiceError;

type Result<T> = std::result::Result<T, ServiceError>;
pub(crate) type Ws = WebSocket<MaybeTlsStream<TcpStream>>;

/// How long to wait for the relay or the Monitor.
const TIMEOUT: Duration = Duration::from_secs(20);
/// A connection unused this long may have been dropped on the way.
const IDLE: Duration = Duration::from_secs(25);

/// A Monitor this phone paired with: where to reach it and the key that
/// proves it's the one.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PairedMonitor {
    pub monitor_id: String,
    pub name: String,
    pub monitor_key: [u8; 32],
}

/// A new private key for this phone (keep it secret, in the Keychain).
pub fn new_phone_key() -> [u8; 32] {
    Keys::generate().private
}

/// Pairs with the Monitor showing `typed_code`, as `phone_name`.
pub fn pair(relay: &str, typed_code: &str, phone_name: &str, phone_key: &[u8; 32]) -> Result<PairedMonitor> {
    let code = Code::parse(typed_code)
        .map_err(|_| refused(400, "That isn't a pairing code. It looks like ABCD-1234-5678."))?;
    let keys = Keys::from_private(*phone_key);
    let mut ws = open(relay, &format!("/v2/relay/pair/{}", code.id)).map_err(|e| match e {
        Open::Status(404) => refused(404, "That pairing code has expired. Make a new one on your Monitor."),
        Open::Status(503) => {
            ServiceError::Network("Your Monitor isn't connected right now. Check that it's running.".into())
        }
        other => other.into(),
    })?;
    let (pairing, m1) = AppPairing::start(&code, &keys, phone_name);
    send(&mut ws, m1)?;
    let m2 = recv(&mut ws)?;
    match &m2[..] {
        b"expired" => {
            return Err(refused(
                404,
                "That pairing code has expired. Make a new one on your Monitor.",
            ));
        }
        b"wrong" => {
            return Err(refused(
                403,
                "That code isn't right. Check it on your Monitor and try again.",
            ));
        }
        _ => {}
    }
    let (monitor_key, m3) = pairing
        .finish(&m2)
        .map_err(|_| refused(403, "That code isn't right. Check it on your Monitor and try again."))?;
    send(&mut ws, m3)?;
    match &recv(&mut ws)?[..] {
        b"paired" => {}
        b"wrong" => {
            return Err(refused(
                403,
                "That code isn't right. Check it on your Monitor and try again.",
            ));
        }
        _ => {
            return Err(ServiceError::Unexpected(
                "The Monitor answered something unexpected.".into(),
            ));
        }
    }
    let me: Value = serde_json::from_slice(&recv(&mut ws)?)
        .map_err(|_| ServiceError::Unexpected("The Monitor didn't say who it is.".into()))?;
    let _ = ws.close(None);
    let monitor_id = me["monitor_id"].as_str().unwrap_or_default().to_owned();
    if monitor_id.is_empty() {
        return Err(ServiceError::Unexpected("The Monitor didn't say who it is.".into()));
    }
    Ok(PairedMonitor {
        monitor_id,
        name: me["name"].as_str().unwrap_or("My Monitor").to_owned(),
        monitor_key,
    })
}

/// The way to a paired Monitor; connects when first used and again after
/// the connection drops.
#[derive(Debug)]
pub struct Tunnel {
    relay: String,
    monitor: PairedMonitor,
    keys: Keys,
    conn: Option<Conn>,
    next_id: u64,
}

pub(crate) struct Conn {
    pub(crate) ws: Ws,
    pub(crate) channel: Channel,
    last_used: std::time::Instant,
}

impl std::fmt::Debug for Conn {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Conn").finish_non_exhaustive()
    }
}

impl Tunnel {
    pub fn new(relay: &str, monitor: PairedMonitor, phone_key: &[u8; 32]) -> Tunnel {
        Tunnel {
            relay: relay.trim_end_matches('/').to_owned(),
            monitor,
            keys: Keys::from_private(*phone_key),
            conn: None,
            next_id: 1,
        }
    }

    pub fn monitor(&self) -> &PairedMonitor {
        &self.monitor
    }

    /// An API call, as over HTTP: the answer's body, or why not. A dropped
    /// connection is opened again once.
    pub fn call(&mut self, method: &str, path: &str, body: Option<Value>) -> Result<Value> {
        // Only calls that can be repeated safely are tried again when the
        // connection drops (a POST might have arrived, its answer lost:
        // never send a message twice). Before a POST, a connection idle
        // for a while is replaced instead, the likely way to have lost it.
        let repeatable = method != "POST";
        if !repeatable && self.conn.as_ref().is_some_and(|c| c.last_used.elapsed() > IDLE) {
            self.conn = None;
        }
        let (status, body) = match self.exchange(method, path, body.clone()) {
            Err(ServiceError::Network(_)) if repeatable => {
                self.conn = None;
                self.exchange(method, path, body)?
            }
            other => other?,
        };
        if (200..300).contains(&status) {
            return Ok(body);
        }
        let message = body
            .get("error")
            .and_then(Value::as_str)
            .map(str::to_owned)
            .unwrap_or_else(|| format!("Your Monitor refused that (HTTP {status})."));
        Err(refused(status, &message))
    }

    /// What the Monitor says about itself (its name and the key that opens
    /// its notifications).
    pub fn hello(&mut self) -> Result<Value> {
        self.call("HELLO", "", None)
    }

    fn exchange(&mut self, method: &str, path: &str, body: Option<Value>) -> Result<(u16, Value)> {
        if self.conn.is_none() {
            self.conn = Some(self.connect()?);
        }
        let id = self.next_id;
        self.next_id += 1;
        let hello = method == "HELLO";
        let req = Request {
            id,
            method: (!hello).then(|| method.to_owned()),
            path: (!hello).then(|| path.to_owned()),
            body: if hello {
                None
            } else {
                body.or_else(|| (method != "GET" && method != "DELETE").then(|| json!({})))
            },
            hello,
            subscribe: None,
            unsubscribe: false,
        };
        let conn = self.conn.as_mut().expect("connected");
        let result = (|| {
            let bytes = serde_json::to_vec(&req).map_err(|e| ServiceError::Unexpected(e.to_string()))?;
            for piece in conn.channel.seal(&bytes) {
                send(&mut conn.ws, piece)?;
            }
            loop {
                let piece = recv(&mut conn.ws)?;
                let message = conn
                    .channel
                    .open(&piece)
                    .map_err(|_| ServiceError::Network("The connection to your Monitor was tampered with.".into()))?;
                let Some(message) = message else { continue };
                let v: Value = serde_json::from_slice(&message)
                    .map_err(|_| ServiceError::Unexpected("Your Monitor answered something unexpected.".into()))?;
                if v["id"] == id {
                    let status = v["status"].as_u64().unwrap_or(500) as u16;
                    return Ok((status, v["body"].clone()));
                }
            }
        })();
        match &result {
            Ok(_) => conn.last_used = std::time::Instant::now(),
            Err(_) => self.conn = None,
        }
        result
    }

    /// A connection of its own, subscribed to the Monitor's events.
    pub fn open_events(&self, since: Option<i64>) -> Result<crate::stream::EventStream> {
        let mut conn = self.connect()?;
        let req = Request {
            id: 1,
            method: None,
            path: None,
            body: None,
            hello: false,
            subscribe: Some(ng_relay::rpc::Subscribe { since }),
            unsubscribe: false,
        };
        let bytes = serde_json::to_vec(&req).map_err(|e| ServiceError::Unexpected(e.to_string()))?;
        for piece in conn.channel.seal(&bytes) {
            send(&mut conn.ws, piece)?;
        }
        Ok(crate::stream::EventStream::tunnel(conn))
    }

    fn connect(&self) -> Result<Conn> {
        let mut ws = open(&self.relay, &format!("/v2/relay/app/{}", self.monitor.monitor_id)).map_err(|e| match e {
            Open::Status(503) => {
                ServiceError::Network("Your Monitor isn't connected right now. Check that it's running.".into())
            }
            other => other.into(),
        })?;
        let (init, m1) = Initiator::start(&self.keys, &self.monitor.monitor_key)
            .map_err(|_| ServiceError::Unexpected("Couldn't start a session with your Monitor.".into()))?;
        send(&mut ws, m1)?;
        // A Monitor that no longer knows this phone just closes.
        let m2 = recv(&mut ws).map_err(|_| {
            refused(
                403,
                "Your Monitor didn't accept this iPhone: it may have been unpaired. Pair it again.",
            )
        })?;
        let channel = init
            .finish(&m2)
            .map_err(|_| refused(403, "That isn't your Monitor answering. Pair it again."))?;
        Ok(Conn {
            ws,
            channel,
            last_used: std::time::Instant::now(),
        })
    }
}

fn refused(status: u16, message: &str) -> ServiceError {
    ServiceError::Refused {
        status,
        message: message.to_owned(),
    }
}

/// Why a WebSocket didn't open.
#[derive(Debug)]
pub(crate) enum Open {
    Status(u16),
    Failed(String),
}

impl From<Open> for ServiceError {
    fn from(e: Open) -> Self {
        match e {
            Open::Status(s) => ServiceError::Network(format!("The relay refused the connection (HTTP {s}).")),
            Open::Failed(m) => ServiceError::Network(format!("Couldn't reach the relay ({m}).")),
        }
    }
}

/// A WebSocket to `relay` + `path` (https → wss).
fn open(relay: &str, path: &str) -> std::result::Result<Ws, Open> {
    open_with(relay, path, None)
}

/// A WebSocket to `relay` + `path`, with a bearer token if given.
pub(crate) fn open_with(relay: &str, path: &str, bearer: Option<&str>) -> std::result::Result<Ws, Open> {
    let base = relay.trim_end_matches('/');
    let (tls, rest) = if let Some(r) = base.strip_prefix("https://") {
        (true, r)
    } else if let Some(r) = base.strip_prefix("http://") {
        (false, r)
    } else {
        return Err(Open::Failed(format!("{relay} isn't a web address")));
    };
    let host_port = rest.split('/').next().unwrap_or(rest);
    let (host, port) = match host_port.rsplit_once(':') {
        Some((h, p)) if !h.ends_with(']') || h.starts_with('[') => (
            h.to_owned(),
            p.parse::<u16>()
                .map_err(|_| Open::Failed(format!("bad port in {relay}")))?,
        ),
        _ => (host_port.to_owned(), if tls { 443 } else { 80 }),
    };
    let url = format!("{}://{rest}{path}", if tls { "wss" } else { "ws" });
    let addr = (host.trim_start_matches('[').trim_end_matches(']'), port)
        .to_socket_addrs()
        .map_err(|e| Open::Failed(e.to_string()))?
        .next()
        .ok_or_else(|| Open::Failed(format!("{host} has no address")))?;
    let tcp = TcpStream::connect_timeout(&addr, TIMEOUT).map_err(|e| Open::Failed(e.to_string()))?;
    let _ = tcp.set_read_timeout(Some(TIMEOUT));
    let _ = tcp.set_write_timeout(Some(TIMEOUT));
    let _ = tcp.set_nodelay(true);
    let connector = if tls {
        Some(tungstenite::Connector::Rustls(tls_config()))
    } else {
        Some(tungstenite::Connector::Plain)
    };
    use tungstenite::client::IntoClientRequest;
    let mut req = url
        .as_str()
        .into_client_request()
        .map_err(|e| Open::Failed(e.to_string()))?;
    if let Some(t) = bearer {
        let v = format!("Bearer {t}")
            .parse()
            .map_err(|_| Open::Failed("a bad token".into()))?;
        req.headers_mut().insert("Authorization", v);
    }
    match tungstenite::client_tls_with_config(req, tcp, None, connector) {
        Ok((ws, _)) => Ok(ws),
        Err(tungstenite::HandshakeError::Failure(tungstenite::Error::Http(r))) => {
            Err(Open::Status(r.status().as_u16()))
        }
        Err(e) => Err(Open::Failed(e.to_string())),
    }
}

fn tls_config() -> Arc<rustls::ClientConfig> {
    let roots = rustls::RootCertStore::from_iter(webpki_roots::TLS_SERVER_ROOTS.iter().cloned());
    Arc::new(
        rustls::ClientConfig::builder_with_provider(Arc::new(rustls::crypto::ring::default_provider()))
            .with_safe_default_protocol_versions()
            .expect("TLS versions")
            .with_root_certificates(roots)
            .with_no_client_auth(),
    )
}

fn send(ws: &mut Ws, bytes: Vec<u8>) -> Result<()> {
    ws.send(Message::Binary(bytes.into()))
        .map_err(|e| ServiceError::Network(format!("The connection to your Monitor dropped ({e}).")))
}

fn recv(ws: &mut Ws) -> Result<Vec<u8>> {
    loop {
        match ws.read() {
            Ok(Message::Binary(b)) => return Ok(b.to_vec()),
            Ok(Message::Close(_)) => return Err(ServiceError::Network("Your Monitor closed the connection.".into())),
            Ok(_) => {}
            Err(e) => {
                return Err(ServiceError::Network(format!(
                    "The connection to your Monitor dropped ({e})."
                )));
            }
        }
    }
}
