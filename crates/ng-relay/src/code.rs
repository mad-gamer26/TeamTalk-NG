//! Pairing codes: `XXXX-NNNN-NNNN`. `XXXX` (letters and digits that can't
//! be confused: no 0/O, 1/I/L, 5/S, 2/Z, 8/B) is the code's ID, which the
//! relay uses to find the Monitor showing it; the eight digits are the
//! secret, which never leaves the Monitor and the phone. People type them
//! in any case, with or without spaces and dashes.

use rand::Rng;

use crate::Error;

const ID_ALPHABET: &[u8] = b"ACDEFGHJKMNPQRTUVWXY34679";
pub const ID_LEN: usize = 4;
pub const SECRET_DIGITS: usize = 8;

/// A pairing code.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Code {
    pub id: String,
    pub secret: String,
}

impl Code {
    /// A new secret for an ID the relay gave.
    pub fn with_id(id: &str) -> Result<Code, Error> {
        let id = normalize_id(id)?;
        let mut rng = rand::thread_rng();
        let secret: String = (0..SECRET_DIGITS).map(|_| char::from(b'0' + rng.gen_range(0..10u8))).collect();
        Ok(Code { id, secret })
    }

    /// A new ID (the relay makes these).
    pub fn new_id() -> String {
        let mut rng = rand::thread_rng();
        (0..ID_LEN).map(|_| char::from(ID_ALPHABET[rng.gen_range(0..ID_ALPHABET.len())])).collect()
    }

    /// What a person typed.
    pub fn parse(typed: &str) -> Result<Code, Error> {
        let clean: String = typed.chars().filter(|c| !c.is_whitespace() && *c != '-').collect::<String>().to_uppercase();
        // Only plain letters and digits (so the split below is on characters).
        if clean.len() != ID_LEN + SECRET_DIGITS || !clean.bytes().all(|b| b.is_ascii_alphanumeric()) {
            return Err(Error::BadCode);
        }
        let (id, secret) = clean.split_at(ID_LEN);
        if !secret.chars().all(|c| c.is_ascii_digit()) {
            return Err(Error::BadCode);
        }
        Ok(Code { id: normalize_id(id)?, secret: secret.to_owned() })
    }

    /// As shown: `K7QF-4821-9035`.
    pub fn display(&self) -> String {
        format!("{}-{}-{}", self.id, &self.secret[..4], &self.secret[4..])
    }

    /// What both sides prove they know (ID and secret together).
    pub fn password(&self) -> Vec<u8> {
        format!("ng-pairing-v1:{}:{}", self.id, self.secret).into_bytes()
    }
}

/// An ID as typed, checked and upper-cased.
pub fn normalize_id(id: &str) -> Result<String, Error> {
    let id = id.trim().to_uppercase();
    if id.len() != ID_LEN || !id.bytes().all(|b| ID_ALPHABET.contains(&b)) {
        return Err(Error::BadCode);
    }
    Ok(id)
}
