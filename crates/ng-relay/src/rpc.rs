//! What a phone and its Monitor say inside the encrypted channel: the same
//! API as the hosted Monitor's `/v1` (methods, paths, JSON bodies, status
//! codes) as JSON messages, and the event stream the hosted Monitor sends
//! over its WebSocket.
//!
//! Phone → Monitor:
//! - `{"id": 1, "hello": true}` → `{"id": 1, "status": 200, "body": {"name",
//!   "push_key", "device_id", "version"}}`
//! - `{"id": 2, "method": "GET", "path": "/v1/servers", "body": …}` →
//!   `{"id": 2, "status": 200, "body": …}`
//! - `{"id": 3, "subscribe": {"since": 41}}` → stream messages `{"stream":
//!   3, "message": {"type": "event"|"ready"|"reset", …}}`, until
//!   `{"id": 3, "unsubscribe": true}` or the channel closes.
//!
//! Only the Monitor's own part of the API passes (`/v1/info`, `/v1/me…`,
//! `/v1/servers…`, `/v1/conversations…`, `/v1/events`); NG Account and
//! sound packs stay on the main service.

use serde::{Deserialize, Serialize};
use serde_json::Value;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct Request {
    pub id: u64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub method: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub path: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub body: Option<Value>,
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub hello: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub subscribe: Option<Subscribe>,
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub unsubscribe: bool,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq)]
pub struct Subscribe {
    #[serde(default)]
    pub since: Option<i64>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct Response {
    pub id: u64,
    pub status: u16,
    #[serde(default)]
    pub body: Value,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct StreamMessage {
    pub stream: u64,
    pub message: Value,
}

/// Paths a phone may use through the tunnel.
pub fn allowed(method: &str, path: &str) -> bool {
    let p = path.split('?').next().unwrap_or("");
    let ok_method = matches!(method, "GET" | "POST" | "PUT" | "PATCH" | "DELETE");
    let segment_ok = |prefix: &str| p == prefix || p.starts_with(&format!("{prefix}/"));
    ok_method
        && !p.contains("..")
        && (p == "/v1/info" || segment_ok("/v1/me") || segment_ok("/v1/servers") || segment_ok("/v1/conversations") || p == "/v1/events")
}
