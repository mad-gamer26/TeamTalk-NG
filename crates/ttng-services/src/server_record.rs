//! A saved server as NG Account syncs it, in the old app's field names, so
//! one account works in both apps. Fields this app doesn't know are kept
//! and sent back unchanged.

use serde_json::{Map, Value};

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct SyncedServer {
    pub name: String,
    pub host: String,
    pub tcp_port: u16,
    pub udp_port: u16,
    pub encrypted: bool,
    pub username: String,
    /// Empty when the person chose not to sync it (`sync_password` false).
    pub password: String,
    pub nickname: String,
    pub status_message: String,
    /// The channel to join ("/Lobby/").
    pub channel: String,
    pub channel_password: String,
    /// Whether the passwords are synced.
    pub sync_password: bool,
    /// Its place in the list (0 first).
    pub order: i64,
    /// Everything else the record holds, as JSON (certificates and the
    /// like), kept as is.
    pub other_json: String,
}

const KNOWN: &[&str] = &[
    "name",
    "ipaddr",
    "tcpport",
    "udpport",
    "encrypted",
    "username",
    "password",
    "nickname",
    "statusmsg",
    "channel",
    "chanpasswd",
    "sync_password",
    "order",
];

impl SyncedServer {
    pub fn from_json(data: &Value) -> SyncedServer {
        let s = |k: &str| data.get(k).and_then(Value::as_str).unwrap_or_default().to_owned();
        let port = |k: &str| {
            data.get(k)
                .and_then(Value::as_u64)
                .and_then(|p| u16::try_from(p).ok())
                .unwrap_or(10333)
        };
        let other: Map<String, Value> = data
            .as_object()
            .map(|o| {
                o.iter()
                    .filter(|(k, _)| !KNOWN.contains(&k.as_str()))
                    .map(|(k, v)| (k.clone(), v.clone()))
                    .collect()
            })
            .unwrap_or_default();
        SyncedServer {
            name: s("name"),
            host: s("ipaddr"),
            tcp_port: port("tcpport"),
            udp_port: port("udpport"),
            encrypted: data.get("encrypted").and_then(Value::as_bool).unwrap_or(false),
            username: s("username"),
            password: s("password"),
            nickname: s("nickname"),
            status_message: s("statusmsg"),
            channel: s("channel"),
            channel_password: s("chanpasswd"),
            sync_password: data.get("sync_password").and_then(Value::as_bool).unwrap_or(true),
            order: data.get("order").and_then(Value::as_i64).unwrap_or(0),
            other_json: if other.is_empty() {
                String::new()
            } else {
                Value::Object(other).to_string()
            },
        }
    }

    pub fn to_json(&self) -> Value {
        let mut o: Map<String, Value> = serde_json::from_str::<Value>(&self.other_json)
            .ok()
            .and_then(|v| v.as_object().cloned())
            .unwrap_or_default();
        let mut put = |k: &str, v: Value| {
            o.insert(k.into(), v);
        };
        put("name", self.name.clone().into());
        put("ipaddr", self.host.clone().into());
        put("tcpport", self.tcp_port.into());
        put("udpport", self.udp_port.into());
        put("encrypted", self.encrypted.into());
        put("username", self.username.clone().into());
        put("nickname", self.nickname.clone().into());
        put("statusmsg", self.status_message.clone().into());
        put("channel", self.channel.clone().into());
        put("sync_password", self.sync_password.into());
        put("order", self.order.into());
        if self.sync_password {
            put("password", self.password.clone().into());
            put("chanpasswd", self.channel_password.clone().into());
        }
        Value::Object(o)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn old_app_records_round_trip_keeping_unknown_fields() {
        let old = serde_json::json!({
            "name": "Home", "ipaddr": "tt.example.com", "tcpport": 10335, "udpport": 10335,
            "username": "me", "password": "pw", "nickname": "Me", "statusmsg": "", "channel": "/Lobby/",
            "chanpasswd": "", "encrypted": true, "cacertdata": "CERT", "certverifypeer": false,
            "sync_password": true, "order": 2
        });
        let s = SyncedServer::from_json(&old);
        assert_eq!(
            (s.host.as_str(), s.tcp_port, s.order, s.encrypted),
            ("tt.example.com", 10335, 2, true)
        );
        assert_eq!(s.to_json(), old, "the same record back, certificates included");
    }

    #[test]
    fn unsynced_passwords_stay_off_the_service() {
        let s = SyncedServer {
            password: "secret".into(),
            sync_password: false,
            ..Default::default()
        };
        assert!(s.to_json().get("password").is_none());
    }
}
