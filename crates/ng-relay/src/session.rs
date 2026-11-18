//! An end-to-end encrypted connection between a paired phone and Monitor,
//! through the relay: a Noise IK handshake (the phone knows the Monitor's
//! key from pairing; the Monitor learns the phone's in the first message
//! and accepts it only if it's paired), then messages of any size, cut
//! into Noise's 64 KiB pieces.

use crate::{Error, Keys};

pub const PATTERN: &str = "Noise_IK_25519_ChaChaPoly_BLAKE2s";
/// The prologue binds the handshake to this protocol and version.
const PROLOGUE: &[u8] = b"ng-session-v1";
/// Room for Noise's tag in each 65535-byte piece.
const PIECE: usize = 65535 - 16 - 1;

/// The phone's side of the handshake.
pub struct Initiator {
    hs: snow::HandshakeState,
}

impl Initiator {
    /// The first message, to the Monitor whose key we paired with.
    pub fn start(mine: &Keys, monitor: &[u8; 32]) -> Result<(Initiator, Vec<u8>), Error> {
        let mut hs = snow::Builder::new(PATTERN.parse().unwrap())
            .prologue(PROLOGUE)
            .local_private_key(&mine.private)
            .remote_public_key(monitor)
            .build_initiator()
            .map_err(|_| Error::Malformed)?;
        let mut buf = vec![0u8; 256];
        let n = hs.write_message(&[], &mut buf).map_err(|_| Error::Malformed)?;
        buf.truncate(n);
        Ok((Initiator { hs }, buf))
    }

    /// The Monitor's answer: the connection.
    pub fn finish(mut self, msg2: &[u8]) -> Result<Channel, Error> {
        let mut buf = vec![0u8; 256];
        self.hs.read_message(msg2, &mut buf).map_err(|_| Error::NotTrusted)?;
        Ok(Channel { t: self.hs.into_transport_mode().map_err(|_| Error::Malformed)?, partial: Vec::new() })
    }
}

/// The Monitor's side: answers the first message if `paired` accepts the
/// phone's key. Returns the answer, the connection and the phone's key.
pub fn respond(mine: &Keys, msg1: &[u8], paired: impl Fn(&[u8; 32]) -> bool) -> Result<(Vec<u8>, Channel, [u8; 32]), Error> {
    let mut hs = snow::Builder::new(PATTERN.parse().unwrap())
        .prologue(PROLOGUE)
        .local_private_key(&mine.private)
        .build_responder()
        .map_err(|_| Error::Malformed)?;
    let mut buf = vec![0u8; 256];
    hs.read_message(msg1, &mut buf).map_err(|_| Error::NotTrusted)?;
    let phone: [u8; 32] = hs.get_remote_static().ok_or(Error::Malformed)?.try_into().map_err(|_| Error::Malformed)?;
    if !paired(&phone) {
        return Err(Error::NotTrusted);
    }
    let n = hs.write_message(&[], &mut buf).map_err(|_| Error::Malformed)?;
    buf.truncate(n);
    let t = hs.into_transport_mode().map_err(|_| Error::Malformed)?;
    Ok((buf, Channel { t, partial: Vec::new() }, phone))
}

/// An established connection. Messages arrive in order (the relay keeps
/// it), each in one or more pieces.
pub struct Channel {
    t: snow::TransportState,
    partial: Vec<u8>,
}

impl Channel {
    /// The pieces to send for one message (each a frame of its own).
    pub fn seal(&mut self, message: &[u8]) -> Vec<Vec<u8>> {
        let chunks: Vec<&[u8]> = if message.is_empty() { vec![&[][..]] } else { message.chunks(PIECE).collect() };
        let last = chunks.len() - 1;
        chunks
            .into_iter()
            .enumerate()
            .map(|(i, c)| {
                let mut plain = Vec::with_capacity(c.len() + 1);
                plain.push(u8::from(i < last));
                plain.extend_from_slice(c);
                let mut out = vec![0u8; plain.len() + 16];
                let n = self.t.write_message(&plain, &mut out).expect("a piece fits");
                out.truncate(n);
                out
            })
            .collect()
    }

    /// One piece received: the whole message once its last piece is in.
    /// Damaged, replayed or reordered pieces are refused (the connection
    /// should then be closed).
    pub fn open(&mut self, piece: &[u8]) -> Result<Option<Vec<u8>>, Error> {
        if piece.len() > 65535 {
            return Err(Error::Malformed);
        }
        let mut plain = vec![0u8; piece.len()];
        let n = self.t.read_message(piece, &mut plain).map_err(|_| Error::Damaged)?;
        if n == 0 {
            return Err(Error::Malformed);
        }
        let more = plain[0] != 0;
        self.partial.extend_from_slice(&plain[1..n]);
        if self.partial.len() > MAX_MESSAGE {
            self.partial.clear();
            return Err(Error::Malformed);
        }
        if more {
            return Ok(None);
        }
        Ok(Some(std::mem::take(&mut self.partial)))
    }
}

/// The largest whole message (a page of events, a conversation's history).
pub const MAX_MESSAGE: usize = 16 * 1024 * 1024;

impl std::fmt::Debug for Initiator {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Initiator").finish_non_exhaustive()
    }
}

impl std::fmt::Debug for Channel {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Channel").finish_non_exhaustive()
    }
}
