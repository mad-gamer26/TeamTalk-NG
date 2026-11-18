//! Pairing a phone with a Monitor through the relay, with a code shown on
//! the Monitor and typed on the phone.
//!
//! 1. Phone → Monitor: SPAKE2 message A (from the code).
//! 2. Monitor → phone: SPAKE2 message B, and the Monitor's public key
//!    sealed with a key derived from the shared secret.
//! 3. Phone → Monitor: the phone's public key and name, sealed likewise.
//!
//! With a wrong code the two sides get different secrets, so the seals
//! don't open: the phone finds out at step 2, the Monitor at step 3. The
//! relay sees only SPAKE2 messages and seals; it can't test guesses of the
//! code offline, and changing anything makes a seal fail.

use chacha20poly1305::aead::{Aead, KeyInit};
use chacha20poly1305::{ChaCha20Poly1305, Key, Nonce};
use spake2::{Ed25519Group, Identity, Password, Spake2};

use crate::code::Code;
use crate::{Error, Keys};

const APP: &[u8] = b"ng-pairing-app";
const MONITOR: &[u8] = b"ng-pairing-monitor";
const MAX_NAME: usize = 200;

/// A key for one direction, from the SPAKE2 secret.
fn direction_key(secret: &[u8], label: &[u8]) -> ChaCha20Poly1305 {
    let hk = hkdf::Hkdf::<sha2::Sha256>::new(Some(b"ng-pairing-v1"), secret);
    let mut key = [0u8; 32];
    hk.expand(label, &mut key).expect("32 bytes");
    ChaCha20Poly1305::new(Key::from_slice(&key))
}

/// Each direction's key seals one message, so a fixed nonce is safe.
fn seal(cipher: &ChaCha20Poly1305, plain: &[u8]) -> Vec<u8> {
    cipher.encrypt(Nonce::from_slice(&[0u8; 12]), plain).expect("sealing")
}

fn open(cipher: &ChaCha20Poly1305, sealed: &[u8]) -> Result<Vec<u8>, Error> {
    cipher.decrypt(Nonce::from_slice(&[0u8; 12]), sealed).map_err(|_| Error::WrongCode)
}

fn split(msg: &[u8]) -> Result<(&[u8], &[u8]), Error> {
    if msg.len() < 2 {
        return Err(Error::Malformed);
    }
    let n = u16::from_be_bytes([msg[0], msg[1]]) as usize;
    if msg.len() < 2 + n {
        return Err(Error::Malformed);
    }
    Ok((&msg[2..2 + n], &msg[2 + n..]))
}

fn join(a: &[u8], b: &[u8]) -> Vec<u8> {
    let mut out = (a.len() as u16).to_be_bytes().to_vec();
    out.extend_from_slice(a);
    out.extend_from_slice(b);
    out
}

/// The phone's side.
pub struct AppPairing {
    spake: Spake2<Ed25519Group>,
    keys: Keys,
    name: String,
}

impl AppPairing {
    /// Step 1: the message to send.
    pub fn start(code: &Code, keys: &Keys, name: &str) -> (AppPairing, Vec<u8>) {
        let (spake, msg) = Spake2::<Ed25519Group>::start_a(&Password::new(code.password()), &Identity::new(APP), &Identity::new(MONITOR));
        let name: String = name.chars().take(MAX_NAME).collect();
        (AppPairing { spake, keys: keys.clone(), name }, msg)
    }

    /// Step 2 received: the Monitor's public key, and step 3 to send.
    pub fn finish(self, msg2: &[u8]) -> Result<([u8; 32], Vec<u8>), Error> {
        let (spake_b, sealed) = split(msg2)?;
        let secret = self.spake.finish(spake_b).map_err(|_| Error::Malformed)?;
        let monitor_pub: [u8; 32] = open(&direction_key(&secret, b"monitor->app"), sealed)?.try_into().map_err(|_| Error::Malformed)?;
        let mut plain = self.keys.public.to_vec();
        plain.extend_from_slice(self.name.as_bytes());
        Ok((monitor_pub, seal(&direction_key(&secret, b"app->monitor"), &plain)))
    }
}

/// The Monitor's side.
pub struct MonitorPairing {
    secret: Vec<u8>,
}

impl MonitorPairing {
    /// Step 1 received: step 2 to send.
    pub fn respond(code: &Code, keys: &Keys, msg1: &[u8]) -> Result<(MonitorPairing, Vec<u8>), Error> {
        let (spake, msg_b) = Spake2::<Ed25519Group>::start_b(&Password::new(code.password()), &Identity::new(APP), &Identity::new(MONITOR));
        let secret = spake.finish(msg1).map_err(|_| Error::Malformed)?;
        let sealed = seal(&direction_key(&secret, b"monitor->app"), &keys.public);
        Ok((MonitorPairing { secret }, join(&msg_b, &sealed)))
    }

    /// Step 3 received: the phone's public key and name.
    pub fn finish(self, msg3: &[u8]) -> Result<([u8; 32], String), Error> {
        let plain = open(&direction_key(&self.secret, b"app->monitor"), msg3)?;
        if plain.len() < 32 {
            return Err(Error::Malformed);
        }
        let (key, name) = plain.split_at(32);
        let name = String::from_utf8_lossy(name).chars().filter(|c| !c.is_control()).take(MAX_NAME).collect();
        Ok((key.try_into().unwrap(), name))
    }
}

impl std::fmt::Debug for AppPairing {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("AppPairing").finish_non_exhaustive()
    }
}

impl std::fmt::Debug for MonitorPairing {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("MonitorPairing").finish_non_exhaustive()
    }
}
