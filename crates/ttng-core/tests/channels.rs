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
    others_hear_streamed("wav");
}

/// MP3s need FFmpeg in the SDK (BearWare's own iOS SDK has none, so it
/// streamed WAV only; the one built from source has it).
#[test]
fn the_others_really_hear_a_streamed_mp3() {
    others_hear_streamed("mp3");
}

fn others_hear_streamed(kind: &str) {
    let server = Server::start();
    let a = TestClient::logged_in(&server, "alice");
    let b = TestClient::logged_in(&server, "bob");
    for c in [&a, &b] {
        c.client.init_audio(AudioDevices::Virtual).unwrap();
        c.client.join_channel_path("/", "").unwrap();
    }
    let dir = std::env::temp_dir().join(format!("ttng-hear-{kind}-{}-{}", std::process::id(), server.port));
    std::fs::create_dir_all(&dir).unwrap();
    let mut wav = dir.join("tone.wav");
    tone_wav(&wav, 3);
    if kind == "mp3" {
        let mp3 = dir.join("tone.mp3");
        ttng_core::mp3::wav_to_mp3(&wav, &mp3, 128, true).unwrap();
        let info = media_file_info(mp3.to_str().unwrap()).expect("the SDK reads the MP3");
        assert!(info.duration_ms > 2500, "{info:?}");
        wav = mp3;
    }
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

/// As the desktop: my own stream comes back to me when I subscribe to my
/// own media files (the server sends it); no local playback of the file.
#[test]
fn my_own_stream_comes_back_through_my_subscription() {
    let server = Server::start();
    let a = TestClient::logged_in(&server, "alice");
    a.client.init_audio(AudioDevices::Virtual).unwrap();
    a.client.join_channel_path("/", "").unwrap();
    let alice = a.client.snapshot().my_user_id;
    a.client.set_subscription(alice, Subscription::MediaFile, true).unwrap();
    let dir = std::env::temp_dir().join(format!("ttng-own-{}-{}", std::process::id(), server.port));
    std::fs::create_dir_all(&dir).unwrap();
    let wav = dir.join("tone.wav");
    tone_wav(&wav, 3);
    let rec = dir.join("heard.wav");
    a.client
        .start_recording_with(rec.to_str().unwrap(), RecordingFormat::Wave, true)
        .unwrap();
    a.client
        .stream_media_file(wav.to_str().unwrap(), 0, false, false)
        .unwrap();
    a.wait_for("the end", |e| {
        matches!(e, Event::StreamChanged(s) if s.status == StreamStatus::Finished).then_some(())
    });
    std::thread::sleep(Duration::from_millis(800));
    a.client.stop_recording().unwrap();
    let data = std::fs::read(&rec).unwrap();
    let loud = data[44..]
        .as_chunks::<2>()
        .0
        .iter()
        .filter(|c| i16::from_le_bytes(**c).unsigned_abs() > 1000)
        .count();
    assert!(loud > 48_000, "Alice heard her own stream back ({loud} loud samples)");
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn a_stream_pauses_seeks_stops_and_refuses_what_cant_play() {
    let server = Server::start();
    let a = TestClient::logged_in(&server, "alice");
    let b = TestClient::logged_in(&server, "bob");
    for c in [&a, &b] {
        c.client.init_audio(AudioDevices::Virtual).unwrap();
        c.client.join_channel_path("/", "").unwrap();
    }
    let dir = std::env::temp_dir().join(format!("ttng-pause-{}-{}", std::process::id(), server.port));
    std::fs::create_dir_all(&dir).unwrap();
    let wav = dir.join("tone.wav");
    tone_wav(&wav, 3);
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

#[test]
fn one_at_a_time_channels_queue_who_talks() {
    let server = Server::start();
    let admin = TestClient::logged_in(&server, "admin");
    admin
        .client
        .make_channel(&ChannelSpec {
            parent_id: root(&admin),
            name: "Turns".into(),
            permanent: true,
            solo_transmit: true,
            ..Default::default()
        })
        .unwrap();
    let a = TestClient::logged_in(&server, "alice");
    let b = TestClient::logged_in(&server, "bob");
    for c in [&a, &b] {
        c.client.init_audio(AudioDevices::Virtual).unwrap();
        c.client.join_channel_path("/Turns/", "").unwrap();
        c.client.set_test_tone(440).unwrap();
    }
    let (alice, bob) = (a.client.snapshot().my_user_id, b.client.snapshot().my_user_id);
    let ch = a.client.snapshot().my_channel_id;
    a.client.set_transmitting(true).unwrap();
    a.wait_until(|s| s.channel(ch).is_some_and(|c| c.transmit_queue.first() == Some(&alice)));
    b.client.set_transmitting(true).unwrap();
    let s = a.wait_until(|s| s.channel(ch).is_some_and(|c| c.transmit_queue.len() == 2));
    assert_eq!(s.channel(ch).unwrap().transmit_queue, vec![alice, bob]);
    a.client.set_transmitting(false).unwrap();
    b.wait_until(|s| s.channel(ch).is_some_and(|c| c.transmit_queue == vec![bob]));
}

/// The desktop's Stream Media File audio preprocessor: TeamTalk's gain at 0
/// silences the file for the others; Speex DSP's defaults let it through.
#[test]
fn a_streamed_files_audio_preprocessor() {
    // Each on its own server, so one file's stream can't affect the next.
    let heard = |pre: StreamPreprocessor| -> usize {
        let server = Server::start();
        let a = TestClient::logged_in(&server, "alice");
        let b = TestClient::logged_in(&server, "bob");
        for c in [&a, &b] {
            c.client.init_audio(AudioDevices::Virtual).unwrap();
            c.client.join_channel_path("/", "").unwrap();
        }
        let dir = std::env::temp_dir().join(format!("ttng-pre-{}-{}", std::process::id(), server.port));
        std::fs::create_dir_all(&dir).unwrap();
        let wav = dir.join("tone.wav");
        tone_wav(&wav, 2);
        let rec = dir.join("heard.wav");
        b.client
            .start_recording_with(rec.to_str().unwrap(), RecordingFormat::Wave, true)
            .unwrap();
        a.client
            .stream_media_file_with(wav.to_str().unwrap(), 0, false, false, pre)
            .unwrap();
        a.wait_for("the end", |e| {
            matches!(e, Event::StreamChanged(s) if s.status == StreamStatus::Finished).then_some(())
        });
        std::thread::sleep(Duration::from_millis(800));
        b.client.stop_recording().unwrap();
        let data = std::fs::read(&rec).unwrap();
        let _ = std::fs::remove_dir_all(&dir);
        data[44..]
            .as_chunks::<2>()
            .0
            .iter()
            .filter(|c| i16::from_le_bytes(**c).unsigned_abs() > 1000)
            .count()
    };
    let silent = heard(StreamPreprocessor::TeamTalk {
        gain: 0,
        mute_left: false,
        mute_right: false,
    });
    assert!(silent < 100, "gain 0 silences it ({silent} loud samples)");
    let speex = heard(StreamPreprocessor::speex_default());
    // Its gain control evens the level out, so fewer samples are loud.
    assert!(speex > 5_000, "Speex DSP lets it through ({speex} loud samples)");
}

/// A second stream after the first: the first's preprocessor doesn't stay.
#[test]
fn a_second_stream_is_heard_too() {
    let server = Server::start();
    let a = TestClient::logged_in(&server, "alice");
    let b = TestClient::logged_in(&server, "bob");
    for c in [&a, &b] {
        c.client.init_audio(AudioDevices::Virtual).unwrap();
        c.client.join_channel_path("/", "").unwrap();
    }
    let dir = std::env::temp_dir().join(format!("ttng-twice-{}-{}", std::process::id(), server.port));
    std::fs::create_dir_all(&dir).unwrap();
    let wav = dir.join("tone.wav");
    tone_wav(&wav, 2);
    let mut louds = vec![];
    // The first silenced by the TeamTalk preprocessor's gain 0, the second
    // with none: the SDK mustn't keep the first's.
    for (n, pre) in [
        StreamPreprocessor::TeamTalk {
            gain: 0,
            mute_left: false,
            mute_right: false,
        },
        StreamPreprocessor::None,
    ]
    .into_iter()
    .enumerate()
    {
        let rec = dir.join(format!("heard{n}.wav"));
        b.client
            .start_recording_with(rec.to_str().unwrap(), RecordingFormat::Wave, true)
            .unwrap();
        a.client
            .stream_media_file_with(wav.to_str().unwrap(), 0, false, false, pre)
            .unwrap();
        a.wait_for("the end", |e| {
            matches!(e, Event::StreamChanged(s) if s.status == StreamStatus::Finished).then_some(())
        });
        std::thread::sleep(Duration::from_millis(800));
        b.client.stop_recording().unwrap();
        let data = std::fs::read(&rec).unwrap();
        louds.push(
            data[44..]
                .as_chunks::<2>()
                .0
                .iter()
                .filter(|c| i16::from_le_bytes(**c).unsigned_abs() > 1000)
                .count(),
        );
    }
    let _ = std::fs::remove_dir_all(&dir);
    assert!(louds[0] < 100 && louds[1] > 20_000, "silenced, then heard: {louds:?}");
}

/// A live source: a FIFO the app writes a never-ending WAV into in real
/// time (its mix). The core doesn't probe it, so the SDK reads it once, from
/// its header; the others hear it as it's written; closing it ends it.
#[cfg(unix)]
#[test]
fn a_live_fifo_streams_as_it_is_written() {
    use std::io::Write;
    use std::time::Instant;
    let server = Server::start();
    let a = TestClient::logged_in(&server, "alice");
    let b = TestClient::logged_in(&server, "bob");
    for c in [&a, &b] {
        c.client.init_audio(AudioDevices::Virtual).unwrap();
        c.client.join_channel_path("/", "").unwrap();
    }
    let dir = std::env::temp_dir().join(format!("ttng-live-{}-{}", std::process::id(), server.port));
    std::fs::create_dir_all(&dir).unwrap();
    let fifo = dir.join("live.wav");
    assert!(
        std::process::Command::new("mkfifo")
            .arg(&fifo)
            .status()
            .unwrap()
            .success()
    );
    let path = fifo.clone();
    let writer = std::thread::spawn(move || {
        let mut f = std::fs::OpenOptions::new().write(true).open(&path).unwrap();
        let mut h = Vec::new();
        h.extend_from_slice(b"RIFF");
        h.extend_from_slice(&u32::MAX.to_le_bytes());
        h.extend_from_slice(b"WAVEfmt ");
        h.extend_from_slice(&16u32.to_le_bytes());
        h.extend_from_slice(&1u16.to_le_bytes());
        h.extend_from_slice(&1u16.to_le_bytes());
        h.extend_from_slice(&48000u32.to_le_bytes());
        h.extend_from_slice(&96000u32.to_le_bytes());
        h.extend_from_slice(&2u16.to_le_bytes());
        h.extend_from_slice(&16u16.to_le_bytes());
        h.extend_from_slice(b"data");
        h.extend_from_slice(&(u32::MAX - 36).to_le_bytes());
        f.write_all(&h).unwrap();
        // Three seconds, in real time, 20 ms blocks a little ahead.
        let t0 = Instant::now();
        let mut n = 0u64;
        while n < 3 * 48000 {
            if n >= (t0.elapsed().as_millis() as u64 + 200) * 48 {
                std::thread::sleep(Duration::from_millis(5));
                continue;
            }
            let mut block = Vec::with_capacity(1920);
            for _ in 0..960 {
                let v = ((n as f32 * 440.0 * std::f32::consts::TAU / 48000.0).sin() * 12000.0) as i16;
                block.extend_from_slice(&v.to_le_bytes());
                n += 1;
            }
            f.write_all(&block).unwrap();
        }
    });
    let rec = dir.join("heard.wav");
    b.client
        .start_recording_with(rec.to_str().unwrap(), RecordingFormat::Wave, true)
        .unwrap();
    a.client
        .stream_media_file(fifo.to_str().unwrap(), 0, false, false)
        .expect("a FIFO streams");
    a.wait_for("the end", |e| {
        matches!(e, Event::StreamChanged(s) if s.status == StreamStatus::Finished).then_some(())
    });
    writer.join().unwrap();
    std::thread::sleep(Duration::from_millis(800));
    b.client.stop_recording().unwrap();
    let data = std::fs::read(&rec).unwrap();
    let loud = data[44..]
        .as_chunks::<2>()
        .0
        .iter()
        .filter(|c| i16::from_le_bytes(**c).unsigned_abs() > 1000)
        .count();
    assert!(loud > 96_000, "Bob heard the live tone ({loud} loud samples)");
    let _ = std::fs::remove_dir_all(&dir);
}
