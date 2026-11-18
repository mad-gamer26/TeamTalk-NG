//! Frames between the relay and a Monitor, over the Monitor's WebSocket
//! (binary messages): `[kind: u8][channel: u32 big-endian][payload]`.
//! Each phone connected through the relay is a channel; phones' own
//! WebSockets carry only the payloads (the relay adds and removes the
//! channel).

use crate::Error;

/// The largest frame: a Noise piece (65535) and room to spare.
pub const MAX_FRAME: usize = 70_000;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Kind {
    /// Relay → Monitor: a phone connected. Payload: JSON `{"kind":
    /// "session"}` or `{"kind": "pair", "code": "<ID>"}`.
    Open = 1,
    /// Either way: a payload for or from that phone.
    Data = 2,
    /// Either way: that phone's connection ended (or should end).
    Close = 3,
    /// Monitor → relay (channel 0): deliver a notification. Payload: JSON
    /// (see `PushRequest` in the service).
    Push = 4,
    /// Relay → Monitor (channel 0): something to know (JSON), such as a
    /// push refused or a code expired.
    Notice = 5,
}

impl Kind {
    fn from_u8(b: u8) -> Option<Kind> {
        Some(match b {
            1 => Kind::Open,
            2 => Kind::Data,
            3 => Kind::Close,
            4 => Kind::Push,
            5 => Kind::Notice,
            _ => return None,
        })
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Frame {
    pub kind: Kind,
    pub channel: u32,
    pub payload: Vec<u8>,
}

impl Frame {
    pub fn new(kind: Kind, channel: u32, payload: impl Into<Vec<u8>>) -> Frame {
        Frame { kind, channel, payload: payload.into() }
    }

    pub fn encode(&self) -> Vec<u8> {
        let mut out = Vec::with_capacity(5 + self.payload.len());
        out.push(self.kind as u8);
        out.extend_from_slice(&self.channel.to_be_bytes());
        out.extend_from_slice(&self.payload);
        out
    }

    pub fn decode(bytes: &[u8]) -> Result<Frame, Error> {
        if bytes.len() < 5 || bytes.len() > MAX_FRAME {
            return Err(Error::Malformed);
        }
        let kind = Kind::from_u8(bytes[0]).ok_or(Error::Malformed)?;
        let channel = u32::from_be_bytes(bytes[1..5].try_into().unwrap());
        Ok(Frame { kind, channel, payload: bytes[5..].to_vec() })
    }
}
