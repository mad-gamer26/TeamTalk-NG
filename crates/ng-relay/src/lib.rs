//! Self-hosted Monitors, reached through the main service's relay
//! (docs/design.md "The tunnel and pairing"):
//!
//! - [`code`]: pairing codes, such as `K7QF-4821-9035`. The first part
//!   finds the Monitor through the relay; the rest is a secret the relay
//!   never sees.
//! - [`pairing`]: the phone and the Monitor prove they know the code
//!   (SPAKE2, so the relay can't guess it offline) and swap their long-term
//!   public keys under the key it gives.
//! - [`session`]: every later connection is a Noise IK handshake between
//!   those keys (mutual authentication, forward secrecy), then encrypted
//!   messages of any size.
//! - [`frame`]: what the relay passes between a Monitor and phones.

pub mod code;
pub mod frame;
pub mod pairing;
pub mod rpc;
pub mod session;

/// A long-term X25519 key pair (the phone's or the Monitor's).
#[derive(Clone)]
pub struct Keys {
    pub private: [u8; 32],
    pub public: [u8; 32],
}

impl Keys {
    pub fn generate() -> Keys {
        let kp = snow::Builder::new(session::PATTERN.parse().unwrap()).generate_keypair().expect("a key pair");
        Keys { private: kp.private.try_into().unwrap(), public: kp.public.try_into().unwrap() }
    }

    /// From a stored private key.
    pub fn from_private(private: [u8; 32]) -> Keys {
        use x25519::public_of;
        Keys { private, public: public_of(&private) }
    }
}

impl std::fmt::Debug for Keys {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        // Never the private key.
        write!(f, "Keys {{ public: {} }}", base64::Engine::encode(&base64::engine::general_purpose::STANDARD, self.public))
    }
}

mod x25519 {
    /// The public key of an X25519 private key: a Noise handshake with
    /// ourselves would do, but the curve's base point multiplication is
    /// what snow's resolver uses inside.
    pub fn public_of(private: &[u8; 32]) -> [u8; 32] {
        use snow::resolvers::{CryptoResolver, DefaultResolver};
        use snow::params::DHChoice;
        let mut dh = DefaultResolver.resolve_dh(&DHChoice::Curve25519).expect("Curve25519");
        dh.set(private);
        dh.pubkey().try_into().unwrap()
    }
}

#[derive(Debug, thiserror::Error, PartialEq, Eq)]
pub enum Error {
    /// The code was wrong (or someone in between changed the messages).
    #[error("That pairing code isn't right")]
    WrongCode,
    #[error("That isn't a pairing code")]
    BadCode,
    /// The other side isn't who it should be, or isn't paired.
    #[error("The Monitor couldn't be verified")]
    NotTrusted,
    #[error("The message was damaged or isn't for this connection")]
    Damaged,
    #[error("The message is malformed")]
    Malformed,
}
