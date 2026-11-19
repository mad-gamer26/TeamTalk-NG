//! A live connection to the Monitor's events, as the old app had: what
//! happened since a point first, `ready`, then each event as it happens.
//! The hosted Monitor's WebSocket (`/v1/ws`), or a stream inside your own
//! Monitor's encrypted tunnel; the messages are the same.

use std::io::ErrorKind;
use std::time::{Duration, Instant};

use serde_json::Value;
use tungstenite::Message;

use crate::ServiceError;
use crate::monitor::MonitorEvent;
use crate::tunnel::{Conn, Ws};

type Result<T> = std::result::Result<T, ServiceError>;

/// How long a read waits before saying "nothing yet" (so the caller can
/// stop the stream promptly).
const POLL: Duration = Duration::from_secs(2);
/// Silence this long (the Monitor or relay pings every 25 s): gone.
const DEAD: Duration = Duration::from_secs(70);

/// One thing from the stream.
#[derive(Clone, Debug, PartialEq)]
pub enum StreamItem {
    /// An event (before `Ready`: one missed since the given point).
    Event(MonitorEvent),
    /// Caught up: what follows happens now; the last event's number.
    Ready(i64),
    /// The given point is unknown (the log started over, or too far
    /// back): start again from this number.
    Reset(i64),
    /// Nothing in the last moment (the connection is fine).
    Nothing,
}

#[derive(Debug)]
pub struct EventStream {
    inner: Inner,
    last_heard: Instant,
}

enum Inner {
    Hosted(Ws),
    Tunnel(Conn),
    Closed,
}

impl std::fmt::Debug for Inner {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(match self {
            Inner::Hosted(_) => "Hosted",
            Inner::Tunnel(_) => "Tunnel",
            Inner::Closed => "Closed",
        })
    }
}

fn set_poll(ws: &Ws) {
    use tungstenite::stream::MaybeTlsStream;
    let tcp = match ws.get_ref() {
        MaybeTlsStream::Plain(t) => t,
        MaybeTlsStream::Rustls(t) => t.get_ref(),
        _ => return,
    };
    let _ = tcp.set_read_timeout(Some(POLL));
}

fn gone(e: impl std::fmt::Display) -> ServiceError {
    ServiceError::Network(format!("The Monitor's live connection dropped ({e})."))
}

impl EventStream {
    pub(crate) fn hosted(base: &str, token: Option<&str>, since: Option<i64>) -> Result<EventStream> {
        let token =
            token.ok_or_else(|| ServiceError::SignedOut("This iPhone isn't registered with the Monitor.".into()))?;
        let path = match since {
            Some(s) => format!("/v1/ws?since={s}"),
            None => "/v1/ws".into(),
        };
        let ws = crate::tunnel::open_with(base, &path, Some(token)).map_err(|e| match e {
            crate::tunnel::Open::Status(401) => {
                ServiceError::SignedOut("The Monitor no longer knows this iPhone.".into())
            }
            other => other.into(),
        })?;
        set_poll(&ws);
        Ok(EventStream {
            inner: Inner::Hosted(ws),
            last_heard: Instant::now(),
        })
    }

    pub(crate) fn tunnel(conn: Conn) -> EventStream {
        set_poll(&conn.ws);
        EventStream {
            inner: Inner::Tunnel(conn),
            last_heard: Instant::now(),
        }
    }

    /// The next thing (waits a moment at most: `Nothing` then). An error:
    /// the connection is gone (open a new one).
    pub fn receive(&mut self) -> Result<StreamItem> {
        let ws = match &mut self.inner {
            Inner::Hosted(ws) => ws,
            Inner::Tunnel(c) => &mut c.ws,
            Inner::Closed => return Err(gone("closed")),
        };
        let bytes = match ws.read() {
            Ok(Message::Text(t)) => t.as_bytes().to_vec(),
            Ok(Message::Binary(b)) => b.to_vec(),
            Ok(Message::Close(_)) => return Err(gone("closed by the other side")),
            Ok(_) => {
                self.last_heard = Instant::now();
                return Ok(StreamItem::Nothing);
            }
            Err(tungstenite::Error::Io(e)) if matches!(e.kind(), ErrorKind::WouldBlock | ErrorKind::TimedOut) => {
                if self.last_heard.elapsed() > DEAD {
                    return Err(gone("no word from it"));
                }
                return Ok(StreamItem::Nothing);
            }
            Err(e) => return Err(gone(e)),
        };
        self.last_heard = Instant::now();
        let message: Value = match &mut self.inner {
            Inner::Tunnel(c) => {
                let Some(opened) = c.channel.open(&bytes).map_err(|_| gone("tampered with"))? else {
                    return Ok(StreamItem::Nothing);
                };
                let v: Value = serde_json::from_slice(&opened).map_err(gone)?;
                // The subscription's own answer, or its stream's messages.
                if v.get("stream").is_none() {
                    if v["status"].as_u64().is_some_and(|s| s >= 400) {
                        return Err(ServiceError::Refused {
                            status: v["status"].as_u64().unwrap_or(400) as u16,
                            message: v["body"]["error"].as_str().unwrap_or("Refused").into(),
                        });
                    }
                    return Ok(StreamItem::Nothing);
                }
                v["message"].clone()
            }
            _ => serde_json::from_slice(&bytes).map_err(gone)?,
        };
        Ok(match message["type"].as_str() {
            Some("event") => StreamItem::Event(crate::monitor::event(&message["event"])),
            Some("ready") => StreamItem::Ready(message["seq"].as_i64().unwrap_or(0)),
            Some("reset") => StreamItem::Reset(message["seq"].as_i64().unwrap_or(0)),
            _ => StreamItem::Nothing,
        })
    }

    pub fn close(&mut self) {
        match std::mem::replace(&mut self.inner, Inner::Closed) {
            Inner::Hosted(mut ws) => {
                let _ = ws.close(None);
            }
            Inner::Tunnel(mut c) => {
                let _ = c.ws.close(None);
            }
            Inner::Closed => {}
        }
    }
}

impl Drop for EventStream {
    fn drop(&mut self) {
        self.close();
    }
}
