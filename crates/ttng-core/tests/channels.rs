//! Channels as the desktop clients set them up: every setting, operator
//! passwords, hidden channels, and streaming a media file to the channel.

mod common;

use std::time::Duration;

use common::{Server, TestClient};
use ttng_core::*;

fn root(c: &TestClient) -> i32 {
    c.client
        .snapshot()
        .channels
        .iter()
        .find(|c| c.parent_id == 0)
        .unwrap()
        .id
}

fn made(c: &TestClient, name: &str) -> Channel {
    c.wait_for("the new channel", |e| match e {
        Event::ChannelAdded(ch) if ch.name == name => Some(ch.clone()),
        _ => None,
    })
}

/// A 48 kHz mono WAV of a tone, `secs` long.
fn tone_wav(path: &std::path::Path, secs: u32) {
    let rate = 48000u32;
    let n = rate * secs;
    let mut w = Vec::with_capacity(44 + n as usize * 2);
    w.extend_from_slice(b"RIFF");
    w.extend_from_slice(&(36 + n * 2).to_le_bytes());
    w.extend_from_slice(b"WAVEfmt ");
    w.extend_from_slice(&16u32.to_le_bytes());
    w.extend_from_slice(&1u16.to_le_bytes());
    w.extend_from_slice(&1u16.to_le_bytes());
    w.extend_from_slice(&rate.to_le_bytes());
    w.extend_from_slice(&(rate * 2).to_le_bytes());
    w.extend_from_slice(&2u16.to_le_bytes());
    w.extend_from_slice(&16u16.to_le_bytes());
    w.extend_from_slice(b"data");
    w.extend_from_slice(&(n * 2).to_le_bytes());
    for i in 0..n {
        let v = ((i as f32 * 440.0 * std::f32::consts::TAU / rate as f32).sin() * 12000.0) as i16;
        w.extend_from_slice(&v.to_le_bytes());
    }
    std::fs::write(path, w).unwrap();
}

#[test]
fn every_channel_setting_round_trips() {
    let server = Server::start();
    let admin = TestClient::logged_in(&server, "admin");
    let opus = AudioCodec {
        sample_rate: 32000,
        channels: 2,
        bitrate: 48000,
        music: true,
        ..AudioCodec::opus_default()
    };
    admin
        .client
        .make_channel(&ChannelSpec {
            parent_id: root(&admin),
            name: "Studio".into(),
            permanent: true,
            operator_receive_only: true,
            operator_password: Some("op-pw".into()),
            disk_quota: Some(1_000_000),
            codec: Some(opus),
            fixed_volume: Some((true, 50)),
            voice_timeout_ms: Some(30_000),
            media_timeout_ms: Some(60_000),
            ..Default::default()
        })
        .expect("made");
    let c = made(&admin, "Studio");
    assert_eq!(c.operator_password, "op-pw", "admins see it");
    assert!(c.operator_receive_only);
    assert_eq!(c.disk_quota, 1_000_000);
    assert_eq!(
        (
            c.codec.kind,
            c.codec.sample_rate,
            c.codec.channels,
            c.codec.bitrate,
            c.codec.music
        ),
        (CodecKind::Opus, 32000, 2, 48000, true)
    );
    assert!(c.fixed_volume);
    assert_eq!(c.fixed_volume_level, 50);
    assert_eq!((c.voice_timeout_ms, c.media_timeout_ms), (30_000, 60_000));

    // A new codec; everything else as it was.
    admin
        .client
        .update_channel(
            c.id,
            &ChannelSpec {
                name: "Studio".into(),
                permanent: true,
                codec: Some(AudioCodec {
                    channels: 1,
                    bitrate: 24000,
                    music: false,
                    ..opus
                }),
                ..Default::default()
            },
        )
        .unwrap();
    let c2 = admin.wait_for("the change", |e| match e {
        Event::ChannelUpdated(ch) if ch.id == c.id && ch.codec.bitrate == 24000 => Some(ch.clone()),
        _ => None,
    });
    assert_eq!((c2.codec.channels, c2.codec.music), (1, false));
    assert_eq!(
        (c2.disk_quota, c2.operator_password.as_str(), c2.voice_timeout_ms),
        (1_000_000, "op-pw", 30_000)
    );

    // Normal people don't see the operator password, but may use it.
    let alice = TestClient::logged_in(&server, "alice");
    alice.client.join_channel_path("/Studio/", "").unwrap();
    let seen = alice.client.snapshot().channel(c.id).cloned().unwrap();
    assert_eq!(seen.operator_password, "");
    let me = alice.client.snapshot().my_user_id;
    let wrong = alice.client.set_operator(me, c.id, "nope", true);
    assert!(wrong.is_err(), "{wrong:?}");
    alice
        .client
        .set_operator(me, c.id, "op-pw", true)
        .expect("with the password");
    alice.wait_for("being operator", |e| {
        matches!(e, Event::UserUpdated(u) if u.id == me && u.operator).then_some(())
    });
}

#[test]
fn hidden_channels_are_joined_by_path() {
    let server = Server::start();
    let admin = TestClient::logged_in(&server, "admin");
    admin
        .client
        .make_channel(&ChannelSpec {
            parent_id: root(&admin),
            name: "Secret".into(),
            password: Some("sesame".into()),
            permanent: true,
            hidden: true,
            ..Default::default()
        })
        .unwrap();
    let alice = TestClient::logged_in(&server, "alice");
    std::thread::sleep(Duration::from_millis(300));
    assert!(
        !alice.client.snapshot().channels.iter().any(|c| c.name == "Secret"),
        "not listed for normal people"
    );
    assert!(
        alice.client.join_channel_path("/Secret/", "sesame").is_err(),
        "not by the list"
    );
    alice
        .client
        .join_hidden_channel("/Secret/", "sesame")
        .expect("by its path");
    assert!(alice.client.snapshot().my_channel_id > 0);
}

#[test]
fn a_media_file_streams_to_the_channel() {
    let server = Server::start();
    let a = TestClient::logged_in(&server, "alice");
    let b = TestClient::logged_in(&server, "bob");
    for c in [&a, &b] {
        c.client.init_audio(AudioDevices::Virtual).unwrap();
        c.client.join_channel_path("/", "").unwrap();
    }
    let wav = std::env::temp_dir().join(format!("ttng-stream-{}-{}.wav", std::process::id(), server.port));
    tone_wav(&wav, 4);
    let info = media_file_info(wav.to_str().unwrap()).expect("playable");
    assert_eq!((info.sample_rate, info.channels), (48000, 1));
    assert!((3900..=4100).contains(&info.duration_ms), "{info:?}");
    assert!(media_file_info("/nowhere.wav").is_none());

    let alice = a.client.snapshot().my_user_id;
    a.client
        .stream_media_file(wav.to_str().unwrap(), 0, false, false)
        .expect("streaming");
    a.wait_for("playing", |e| {
        matches!(e, Event::StreamChanged(s) if s.status == StreamStatus::Playing).then_some(())
    });
    b.wait_for("Alice's file playing", |e| {
        matches!(e, Event::UserUpdated(u) if u.id == alice && u.playing_media && u.streaming_media).then_some(())
    });

    a.client.update_stream(None, true).unwrap();
    assert_eq!(a.client.snapshot().streaming.unwrap().status, StreamStatus::Paused);
    a.client.update_stream(Some(1000), false).unwrap();
    a.client.stop_stream().unwrap();
    assert!(a.client.snapshot().streaming.is_none());
    b.wait_for("Alice's status without streaming", |e| {
        matches!(e, Event::UserUpdated(u) if u.id == alice && !u.streaming_media).then_some(())
    });
    assert_eq!(
        a.client.stop_stream(),
        Err(Error::Refused("Nothing is being streamed.".into()))
    );
    let _ = std::fs::remove_file(&wav);
}

#[test]
fn a_stream_ends_by_itself_or_loops() {
    let server = Server::start();
    let a = TestClient::logged_in(&server, "alice");
    a.client.init_audio(AudioDevices::Virtual).unwrap();
    a.client.join_channel_path("/", "").unwrap();
    let wav = std::env::temp_dir().join(format!("ttng-loop-{}-{}.wav", std::process::id(), server.port));
    tone_wav(&wav, 1);
    a.client
        .stream_media_file(wav.to_str().unwrap(), 0, false, true)
        .unwrap();
    // It finishes, then starts again.
    a.wait_for("the end", |e| {
        matches!(e, Event::StreamChanged(s) if s.status == StreamStatus::Finished).then_some(())
    });
    a.wait_for("the start again", |e| {
        matches!(e, Event::StreamChanged(s) if s.status == StreamStatus::Started || s.status == StreamStatus::Playing)
            .then_some(())
    });
    assert!(a.client.snapshot().streaming.is_some());
    a.client.stop_stream().unwrap();
    // Without looping, it just ends.
    a.client
        .stream_media_file(wav.to_str().unwrap(), 0, false, false)
        .unwrap();
    a.wait_for("the end", |e| {
        matches!(e, Event::StreamChanged(s) if s.status == StreamStatus::Finished).then_some(())
    });
    std::thread::sleep(Duration::from_millis(200));
    assert!(a.client.snapshot().streaming.is_none());
    let _ = std::fs::remove_file(&wav);
}

#[test]
fn the_others_really_hear_a_streamed_file() {
    let server = Server::start();
    let a = TestClient::logged_in(&server, "alice");
    let b = TestClient::logged_in(&server, "bob");
    for c in [&a, &b] {
        c.client.init_audio(AudioDevices::Virtual).unwrap();
        c.client.join_channel_path("/", "").unwrap();
    }
    let dir = std::env::temp_dir().join(format!("ttng-hear-{}-{}", std::process::id(), server.port));
    std::fs::create_dir_all(&dir).unwrap();
    let wav = dir.join("tone.wav");
    tone_wav(&wav, 3);
    // Bob records what arrives, media files included.
    let rec = dir.join("heard.wav");
    b.client
        .start_recording_with(rec.to_str().unwrap(), RecordingFormat::Wave, true)
        .unwrap();
    a.client
        .stream_media_file(wav.to_str().unwrap(), 0, false, false)
        .unwrap();
    a.wait_for("the end", |e| {
        matches!(e, Event::StreamChanged(s) if s.status == StreamStatus::Finished).then_some(())
    });
    std::thread::sleep(Duration::from_millis(800));
    b.client.stop_recording().unwrap();
    let data = std::fs::read(&rec).unwrap();
    let loud = data[44..]
        .as_chunks::<2>()
        .0
        .iter()
        .filter(|c| i16::from_le_bytes(**c).unsigned_abs() > 1000)
        .count();
    assert!(loud > 48_000, "Bob heard the tone ({loud} loud samples)");
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn hearing_my_own_stream_and_refusing_what_cant_play() {
    let server = Server::start();
    let a = TestClient::logged_in(&server, "alice");
    let b = TestClient::logged_in(&server, "bob");
    for c in [&a, &b] {
        c.client.init_audio(AudioDevices::Virtual).unwrap();
        c.client.join_channel_path("/", "").unwrap();
    }
    let dir = std::env::temp_dir().join(format!("ttng-own-{}-{}", std::process::id(), server.port));
    std::fs::create_dir_all(&dir).unwrap();
    let wav = dir.join("tone.wav");
    tone_wav(&wav, 3);
    a.client.set_hear_own_stream(true).unwrap();
    a.client
        .stream_media_file(wav.to_str().unwrap(), 0, false, false)
        .unwrap();
    let alice = a.client.snapshot().my_user_id;
    b.wait_for("the file playing", |e| {
        matches!(e, Event::UserUpdated(u) if u.id == alice && u.playing_media).then_some(())
    });
    a.client.update_stream(None, true).unwrap();
    a.client.update_stream(Some(500), false).unwrap();
    a.client.stop_stream().unwrap();

    let junk = dir.join("not-audio.mp3");
    std::fs::write(&junk, b"this is text, not sound").unwrap();
    let refused = a.client.stream_media_file(junk.to_str().unwrap(), 0, false, false);
    assert!(matches!(refused, Err(Error::Refused(_))), "{refused:?}");
    let _ = std::fs::remove_dir_all(&dir);
}
