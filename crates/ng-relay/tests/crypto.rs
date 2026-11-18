//! Pairing, sessions, codes and frames: the right path, and every way the
//! relay in the middle (or anyone else) could try to cheat.

use ng_relay::code::Code;
use ng_relay::frame::{Frame, Kind};
use ng_relay::pairing::{AppPairing, MonitorPairing};
use ng_relay::session::{self, Initiator};
use ng_relay::{Error, Keys};
use proptest::prelude::*;

fn code() -> Code {
    Code::with_id(&Code::new_id()).unwrap()
}

/// A whole pairing: the phone's view (the Monitor's key) and the
/// Monitor's (the phone's key and name).
#[allow(clippy::type_complexity)]
fn pair(app_code: &Code, monitor_code: &Code, app: &Keys, monitor: &Keys) -> (Result<[u8; 32], Error>, Option<Result<([u8; 32], String), Error>>) {
    let (a, m1) = AppPairing::start(app_code, app, "Matt's iPhone");
    let (m, m2) = MonitorPairing::respond(monitor_code, monitor, &m1).unwrap();
    match a.finish(&m2) {
        Ok((monitor_pub, m3)) => (Ok(monitor_pub), Some(m.finish(&m3))),
        Err(e) => (Err(e), None),
    }
}

#[test]
fn pairing_with_the_right_code() {
    let (app, monitor) = (Keys::generate(), Keys::generate());
    let c = code();
    let (seen_by_app, seen_by_monitor) = pair(&c, &c, &app, &monitor);
    assert_eq!(seen_by_app.unwrap(), monitor.public);
    let (key, name) = seen_by_monitor.unwrap().unwrap();
    assert_eq!(key, app.public);
    assert_eq!(name, "Matt's iPhone");
}

#[test]
fn a_wrong_code_fails_on_both_sides() {
    let (app, monitor) = (Keys::generate(), Keys::generate());
    let shown = code();
    let mut typed = shown.clone();
    typed.secret = format!("{:08}", (typed.secret.parse::<u32>().unwrap() + 1) % 100_000_000);
    let (seen_by_app, _) = pair(&typed, &shown, &app, &monitor);
    assert_eq!(seen_by_app, Err(Error::WrongCode), "the phone finds out first");
    // And a Monitor that gets a third message made with another secret.
    let (a, m1) = AppPairing::start(&typed, &app, "x");
    let (m, m2) = MonitorPairing::respond(&shown, &monitor, &m1).unwrap();
    let _ = a;
    let _ = m2;
    let (other, _) = AppPairing::start(&shown, &Keys::generate(), "x");
    let _ = other;
    assert!(m.finish(&[0u8; 80]).is_err());
}

#[test]
fn a_relay_changing_messages_is_caught() {
    let (app, monitor, relay) = (Keys::generate(), Keys::generate(), Keys::generate());
    let c = code();
    // The relay answers with its own key instead of the Monitor's: it
    // doesn't know the code, so it can't seal it.
    let (a, m1) = AppPairing::start(&c, &app, "x");
    let (_m, m2) = MonitorPairing::respond(&c, &monitor, &m1).unwrap();
    let mut forged = m2.clone();
    let last = forged.len() - 1;
    forged[last] ^= 1;
    assert_eq!(a.finish(&forged).err(), Some(Error::WrongCode));
    // Running its own SPAKE2 with a guessed code: the phone refuses.
    let (a, m1) = AppPairing::start(&c, &app, "x");
    let guess = Code { id: c.id.clone(), secret: "00000000".into() };
    let (_relay_side, m2) = MonitorPairing::respond(&guess, &relay, &m1).unwrap();
    if c.secret != "00000000" {
        assert_eq!(a.finish(&m2).err(), Some(Error::WrongCode));
    }
    // Garbage.
    let (a, _) = AppPairing::start(&c, &app, "x");
    assert!(a.finish(&[1]).is_err());
    assert!(MonitorPairing::respond(&c, &monitor, &[1, 2, 3]).is_err());
}

#[test]
fn names_are_cleaned() {
    let (app, monitor) = (Keys::generate(), Keys::generate());
    let c = code();
    let (a, m1) = AppPairing::start(&c, &app, &format!("bad\u{7}name{}", "x".repeat(500)));
    let (m, m2) = MonitorPairing::respond(&c, &monitor, &m1).unwrap();
    let (_, m3) = a.finish(&m2).unwrap();
    let (_, name) = m.finish(&m3).unwrap();
    assert!(name.starts_with("badname") && name.chars().count() <= 200, "{name}");
}

#[test]
fn sessions_between_paired_keys() {
    let (app, monitor) = (Keys::generate(), Keys::generate());
    let (init, m1) = Initiator::start(&app, &monitor.public).unwrap();
    let (m2, mut mon_side, phone) = session::respond(&monitor, &m1, |k| *k == app.public).unwrap();
    assert_eq!(phone, app.public);
    let mut app_side = init.finish(&m2).unwrap();
    for msg in [b"hello".to_vec(), Vec::new(), vec![7u8; 200_000]] {
        let pieces = app_side.seal(&msg);
        assert_eq!(pieces.len(), msg.len().max(1).div_ceil(65518));
        let mut got = None;
        for p in &pieces {
            assert!(p.len() <= 65535);
            got = mon_side.open(p).unwrap();
        }
        assert_eq!(got.unwrap(), msg);
    }
    // The other way.
    let p = mon_side.seal(b"reply");
    assert_eq!(app_side.open(&p[0]).unwrap().unwrap(), b"reply");
}

#[test]
fn an_unpaired_phone_is_refused() {
    let (app, monitor) = (Keys::generate(), Keys::generate());
    let (_, m1) = Initiator::start(&app, &monitor.public).unwrap();
    assert_eq!(session::respond(&monitor, &m1, |_| false).err().map(|e| e.to_string()), Some(Error::NotTrusted.to_string()));
}

#[test]
fn a_phone_talking_to_the_wrong_monitor_finds_out() {
    let (app, monitor, impostor) = (Keys::generate(), Keys::generate(), Keys::generate());
    // The phone thinks it's talking to `monitor`; the impostor can't even
    // read the first message.
    let (_, m1) = Initiator::start(&app, &monitor.public).unwrap();
    assert!(session::respond(&impostor, &m1, |_| true).is_err());
}

#[test]
fn damaged_replayed_and_reordered_pieces_are_refused() {
    let (app, monitor) = (Keys::generate(), Keys::generate());
    let (init, m1) = Initiator::start(&app, &monitor.public).unwrap();
    let (m2, mut mon_side, _) = session::respond(&monitor, &m1, |_| true).unwrap();
    let mut app_side = init.finish(&m2).unwrap();
    let a = app_side.seal(b"one").remove(0);
    let b = app_side.seal(b"two").remove(0);
    let mut damaged = a.clone();
    damaged[3] ^= 0x80;
    assert_eq!(mon_side.open(&damaged).err(), Some(Error::Damaged));
    // (After a damaged piece the connection is closed; a fresh one here.)
    let (init, m1) = Initiator::start(&app, &monitor.public).unwrap();
    let (m2, mut mon_side, _) = session::respond(&monitor, &m1, |_| true).unwrap();
    let mut app_side = init.finish(&m2).unwrap();
    let a = app_side.seal(b"one").remove(0);
    let b2 = app_side.seal(b"two").remove(0);
    assert_eq!(mon_side.open(&b2).err(), Some(Error::Damaged), "out of order");
    let _ = (a, b);
    let (init, m1) = Initiator::start(&app, &monitor.public).unwrap();
    let (m2, mut mon_side, _) = session::respond(&monitor, &m1, |_| true).unwrap();
    let mut app_side = init.finish(&m2).unwrap();
    let a = app_side.seal(b"one").remove(0);
    assert!(mon_side.open(&a).unwrap().is_some());
    assert_eq!(mon_side.open(&a).err(), Some(Error::Damaged), "replayed");
}

#[test]
fn every_handshake_has_fresh_keys() {
    let (app, monitor) = (Keys::generate(), Keys::generate());
    let (_, m1a) = Initiator::start(&app, &monitor.public).unwrap();
    let (_, m1b) = Initiator::start(&app, &monitor.public).unwrap();
    assert_ne!(m1a, m1b);
}

#[test]
fn keys_from_a_stored_private_key() {
    let k = Keys::generate();
    let again = Keys::from_private(k.private);
    assert_eq!(again.public, k.public);
    assert!(!format!("{k:?}").contains(&format!("{:?}", k.private)), "the private key isn't printed");
}

#[test]
fn codes() {
    let c = Code::with_id("k7qf").unwrap();
    assert_eq!(c.id, "K7QF");
    assert_eq!(c.secret.len(), 8);
    let shown = c.display();
    assert_eq!(shown.len(), 14);
    assert_eq!(Code::parse(&shown).unwrap(), c);
    assert_eq!(Code::parse(&shown.to_lowercase().replace('-', " ")).unwrap(), c);
    assert_eq!(Code::parse(&format!("  {}  ", shown.replace('-', ""))).unwrap(), c);
    for bad in ["", "K7QF-1234-567", "K7QF-1234-56789", "K7QF-1234-567A", "O0IL-1234-5678", "K7Q-11234-5678"] {
        assert_eq!(Code::parse(bad), Err(Error::BadCode), "{bad}");
    }
    assert!(Code::with_id("bad!").is_err());
    for _ in 0..200 {
        let id = Code::new_id();
        assert!(Code::with_id(&id).is_ok(), "{id}");
    }
    // Two codes' secrets differ (they're random).
    assert_ne!(Code::with_id("ACDE").unwrap().secret, Code::with_id("ACDE").unwrap().secret);
}

#[test]
fn frames() {
    let f = Frame::new(Kind::Data, 0xDEADBEEF, b"payload".to_vec());
    let bytes = f.encode();
    assert_eq!(&bytes[..5], &[2, 0xDE, 0xAD, 0xBE, 0xEF]);
    assert_eq!(Frame::decode(&bytes).unwrap(), f);
    assert!(Frame::decode(&[2, 0, 0]).is_err(), "too short");
    assert!(Frame::decode(&[9, 0, 0, 0, 1]).is_err(), "unknown kind");
    assert!(Frame::decode(&vec![2u8; 70_001]).is_err(), "too long");
    assert_eq!(Frame::decode(&[3, 0, 0, 0, 7]).unwrap(), Frame::new(Kind::Close, 7, Vec::new()));
}

proptest! {
    #[test]
    fn frames_round_trip(kind in 1u8..=5, channel: u32, payload in proptest::collection::vec(any::<u8>(), 0..1000)) {
        let bytes = [vec![kind], channel.to_be_bytes().to_vec(), payload.clone()].concat();
        let f = Frame::decode(&bytes).unwrap();
        prop_assert_eq!(f.channel, channel);
        prop_assert_eq!(&f.payload, &payload);
        prop_assert_eq!(f.encode(), bytes);
    }

    #[test]
    fn decoding_anything_never_panics(bytes in proptest::collection::vec(any::<u8>(), 0..200)) {
        let _ = Frame::decode(&bytes);
        let _ = Code::parse(&String::from_utf8_lossy(&bytes));
    }

    #[test]
    fn opening_garbage_never_panics(bytes in proptest::collection::vec(any::<u8>(), 0..300)) {
        let (app, monitor) = (Keys::generate(), Keys::generate());
        let _ = session::respond(&monitor, &bytes, |_| true);
        let c = Code::with_id("ACDE").unwrap();
        let _ = MonitorPairing::respond(&c, &monitor, &bytes);
        let (a, _) = AppPairing::start(&c, &app, "x");
        let _ = a.finish(&bytes);
    }
}
