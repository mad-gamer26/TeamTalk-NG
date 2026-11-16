//! Outside audio in and out (AudioNet): a login with no sound devices sends
//! the app's audio as its voice; the channel's sound and my microphone are
//! captured for the app.

mod common;

use common::*;
use std::time::{Duration, Instant};
use ttng_core::*;

fn me(c: &TestClient) -> i32 {
    c.client.snapshot().my_user_id
}

fn loudest(s: &[i16]) -> i32 {
    s.iter().map(|v| (*v as i32).abs()).max().unwrap_or(0)
}

/// 40 ms of a 440 Hz tone at 48 kHz, mono, starting at sample `start`.
fn tone(start: usize) -> Vec<i16> {
    (start..start + 1920)
        .map(|i| ((i as f32 * 440.0 * std::f32::consts::TAU / 48_000.0).sin() * 12_000.0) as i16)
        .collect()
}

#[test]
fn inserted_audio_is_heard_as_voice_and_captured_as_the_channels_sound() {
    let server = Server::start();
    // The AudioNet login: no sound devices at all.
    let feed = TestClient::logged_in(&server, "alice");
    feed.client.join_channel_path("/", "").unwrap();
    let listener = TestClient::logged_in(&server, "bob");
    listener.client.join_channel_path("/", "").unwrap();
    listener.client.init_audio(AudioDevices::Virtual).unwrap();
    listener
        .client
        .set_capture(Capture::Channel, true)
        .expect("captures the channel");
    let alice = me(&feed);
    listener.wait_until(|s| s.users.iter().any(|u| u.id == alice && u.channel_id == s.my_channel_id));

    // Fed in real time, as AudioNet's sound would come.
    let start = Instant::now();
    let mut sample = 0;
    let mut heard = false;
    let mut loud = 0;
    while start.elapsed() < Duration::from_secs(4) && !(heard && loud > 2000) {
        // A full queue just drops the block (as the app does).
        let _ = feed.client.insert_audio(tone(sample), 48_000, 1);
        sample += 1920;
        std::thread::sleep(Duration::from_millis(40));
        heard |= listener
            .client
            .snapshot()
            .users
            .iter()
            .any(|u| u.id == alice && u.talking);
        loud = loud.max(loudest(&listener.client.read_captured(Capture::Channel).samples));
    }
    assert!(heard, "heard as Alice's voice");
    assert!(loud > 2000, "the channel's sound captured: loudest {loud}");

    feed.client.end_inserted_audio().unwrap();
    listener.wait_for("Alice stopped", |e| {
        matches!(e, Event::TalkingChanged { user_id, talking: false } if *user_id == alice).then_some(())
    });
    listener.client.set_capture(Capture::Channel, false).unwrap();
    assert!(
        listener.client.read_captured(Capture::Channel).samples.is_empty(),
        "nothing once stopped"
    );
}

/// The microphone as the sound device gives it, before TeamTalk's own
/// processing (so the virtual device's test tone, added in that
/// processing, isn't in it): it arrives steadily, in its format.
#[test]
fn my_microphone_is_captured() {
    let server = Server::start();
    let me_ = TestClient::logged_in(&server, "alice");
    me_.client.join_channel_path("/", "").unwrap();
    me_.client.init_audio(AudioDevices::Virtual).unwrap();
    me_.client
        .set_capture(Capture::Microphone, true)
        .expect("captures the microphone");
    std::thread::sleep(Duration::from_millis(300));
    let _ = me_.client.read_captured(Capture::Microphone);
    std::thread::sleep(Duration::from_millis(1000));
    let got = me_.client.read_captured(Capture::Microphone);
    assert!(got.sample_rate > 0 && got.channels >= 1, "{got:?}");
    let seconds = got.samples.len() as f32 / (got.sample_rate * got.channels) as f32;
    assert!((0.7..1.4).contains(&seconds), "a second's worth: {seconds} s");
    me_.client.set_capture(Capture::Microphone, false).unwrap();
}
