//! TeamTalk NG's core: a safe client for BearWare's TeamTalk 5 SDK. One
//! `Client` per server connection; see `client.rs` for how it works.

mod client;
mod error;
mod model;
pub mod text;

pub use client::{AudioDevices, Client, ConnectOptions, EventListener};
pub use error::{Error, Result};
pub use model::*;

/// The SDK's version ("5.23.0.5209").
pub fn sdk_version() -> String {
    // SAFETY: returns a pointer to a static, NUL-terminated string.
    let p = unsafe { ttng_sys::TT_GetVersion() };
    if p.is_null() {
        return String::new();
    }
    let mut n = 0;
    // SAFETY: reads the static string up to its NUL.
    while unsafe { *p.add(n) } != 0 {
        n += 1;
    }
    // SAFETY: p points to n valid units.
    text::from_tt(unsafe { std::slice::from_raw_parts(p, n) })
}

/// Turns off the SDK's trial mode with a license from BearWare.dk. Call it
/// before the first `Client`; returns whether the SDK accepted it. Without
/// one the SDK runs as a trial (it says "TRAIL MODE").
pub fn set_license(name: &str, key: &str) -> bool {
    let (n, k) = (text::to_tt(name), text::to_tt(key));
    // SAFETY: both are NUL-terminated arrays of the SDK's string length.
    unsafe { ttng_sys::TT_SetLicenseInformation(n.as_ptr(), k.as_ptr()) != 0 }
}
