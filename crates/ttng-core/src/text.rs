//! Text across the SDK boundary. `TTCHAR` is `char` (UTF-8) everywhere but
//! Windows, where it's UTF-16 (`WCHAR`). Strings in structs are fixed arrays
//! of `TT_STRLEN` (512) units, ending in a NUL.

use ttng_sys::{TT_STRLEN, TTCHAR};

const LEN: usize = TT_STRLEN as usize;

/// A string from a fixed `TTCHAR` array (up to its first NUL). Invalid text
/// is replaced, never an error: it came from a server.
pub fn from_tt(buf: &[TTCHAR]) -> String {
    let end = buf.iter().position(|&c| c == 0).unwrap_or(buf.len());
    #[cfg(not(windows))]
    {
        let bytes: Vec<u8> = buf[..end].iter().map(|&c| c as u8).collect();
        String::from_utf8_lossy(&bytes).into_owned()
    }
    #[cfg(windows)]
    {
        String::from_utf16_lossy(&buf[..end])
    }
}

/// `s` as a fixed `TTCHAR` array, cut (at a character boundary) to fit with
/// its NUL.
pub fn to_tt(s: &str) -> [TTCHAR; LEN] {
    let mut out = [0 as TTCHAR; LEN];
    let units = encode(s, LEN - 1);
    out[..units.len()].copy_from_slice(&units);
    out
}

/// `s` as a NUL-terminated `TTCHAR` buffer, for functions that take a
/// `*const TTCHAR` (the buffer must outlive the call).
pub fn arg(s: &str) -> Vec<TTCHAR> {
    let mut units = encode(s, usize::MAX);
    units.push(0);
    units
}

/// The encoded units of `s`, at most `max` of them, never splitting a
/// character. Interior NULs end the string (the SDK would stop there anyway).
fn encode(s: &str, max: usize) -> Vec<TTCHAR> {
    let s = s.split('\0').next().unwrap_or("");
    let mut out = Vec::with_capacity(s.len().min(max));
    for ch in s.chars() {
        #[cfg(not(windows))]
        {
            let mut b = [0u8; 4];
            let enc = ch.encode_utf8(&mut b).as_bytes();
            if out.len() + enc.len() > max {
                break;
            }
            out.extend(enc.iter().map(|&u| u as TTCHAR));
        }
        #[cfg(windows)]
        {
            let mut b = [0u16; 2];
            let enc = ch.encode_utf16(&mut b);
            if out.len() + enc.len() > max {
                break;
            }
            out.extend(enc.iter().map(|&u| u as TTCHAR));
        }
    }
    out
}

/// Splits `s` into parts that each fit a text message (a fixed array, less
/// its NUL), at character boundaries. Long messages are sent as several,
/// marked "more to come" (`bMore`) except the last.
pub fn split_message(s: &str) -> Vec<String> {
    let mut parts = Vec::new();
    let mut rest = s;
    while !rest.is_empty() {
        let mut cut = 0;
        let mut units = 0;
        for (i, ch) in rest.char_indices() {
            #[cfg(not(windows))]
            let n = ch.len_utf8();
            #[cfg(windows)]
            let n = ch.len_utf16();
            if units + n > LEN - 1 {
                break;
            }
            units += n;
            cut = i + ch.len_utf8();
        }
        if cut == 0 {
            break;
        }
        parts.push(rest[..cut].to_owned());
        rest = &rest[cut..];
    }
    if parts.is_empty() {
        parts.push(String::new());
    }
    parts
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn round_trips_and_cuts_at_character_boundaries() {
        assert_eq!(from_tt(&to_tt("Héllo wörld")), "Héllo wörld");
        // 600 "é" (2 bytes each) don't fit 511 bytes: cut to 255 whole ones.
        let long = "é".repeat(600);
        let back = from_tt(&to_tt(&long));
        assert_eq!(back.chars().count(), 255);
        assert!(back.chars().all(|c| c == 'é'));
        assert_eq!(arg("a\0b"), vec![b'a' as TTCHAR, 0]);
    }

    #[test]
    fn long_messages_split_without_breaking_characters() {
        let msg = format!("{}{}", "a".repeat(510), "ééé");
        let parts = split_message(&msg);
        assert_eq!(parts.concat(), msg);
        assert!(parts.iter().all(|p| p.len() <= 511));
        assert_eq!(parts.len(), 2);
        assert_eq!(split_message(""), vec![String::new()]);
    }
}
