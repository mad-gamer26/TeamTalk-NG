//! Sound as the desktop's Sound System settings have it, client
//! statistics, and recording each person to their own files.

mod common;
mod mp3_check;

use std::time::Duration;

use common::{Server, TestClient};
use ttng_core::*;

fn in_root(server: &Server, names: &[&str]) -> Vec<TestClient> {
    names
        .iter()
        .map(|n| {
            let c = TestClient::logged_in(server, n);
            c.client.init_audio(AudioDevices::Virtual).unwrap();
            c.client.join_channel_path("/", "").unwrap();
            c
        })
        .collect()
}

fn talks_to(a: &TestClient, b: &TestClient) {
    let alice = a.client.snapshot().my_user_id;
    a.client.set_test_tone(440).unwrap();
    a.client.set_transmitting(true).unwrap();
    b.wait_for("the voice", |e| {
        matches!(e, Event::TalkingChanged { user_id, talking: true } if *user_id == alice).then_some(())
    });
    a.client.set_transmitting(false).unwrap();
    b.wait_for("the voice stopping", |e| {
        matches!(e, Event::TalkingChanged { user_id, talking: false } if *user_id == alice).then_some(())
    });
}

#[test]
fn voice_goes_through_every_kind_of_processing() {
    let server = Server::start();
    let v = in_root(&server, &["alice", "bob"]);
    let (a, b) = (&v[0], &v[1]);
    for s in [
        AudioSettings::default(),
        AudioSettings {
            echo_cancellation: true,
            ..Default::default()
        },
        AudioSettings {
            echo_cancellation: false,
            gain_control: false,
            noise_suppression: false,
            mic_gain: 250,
            output_volume: 60,
            media_volume: 50,
        },
    ] {
        a.client.set_audio_settings(s).expect("applied");
        assert_eq!(a.client.snapshot().audio, s);
        talks_to(a, b);
    }
}

#[test]
fn a_channel_with_a_fixed_volume_still_carries_voices() {
    let server = Server::start();
    let admin = TestClient::logged_in(&server, "admin");
    let root = admin
        .client
        .snapshot()
        .channels
        .iter()
        .find(|c| c.parent_id == 0)
        .unwrap()
        .id;
    admin
        .client
        .make_channel(&ChannelSpec {
            parent_id: root,
            name: "Even".into(),
            permanent: true,
            fixed_volume: Some((true, 30)),
            ..Default::default()
        })
        .unwrap();
    let a = TestClient::logged_in(&server, "alice");
    let b = TestClient::logged_in(&server, "bob");
    for c in [&a, &b] {
        c.client.init_audio(AudioDevices::Virtual).unwrap();
        c.client.join_channel_path("/Even/", "").unwrap();
    }
    let ch = a
        .client
        .snapshot()
        .channel(a.client.snapshot().my_channel_id)
        .cloned()
        .unwrap();
    assert!(ch.fixed_volume && ch.fixed_volume_level == 30, "{ch:?}");
    talks_to(&a, &b);
}

#[test]
fn client_statistics_count_what_was_sent() {
    let server = Server::start();
    let v = in_root(&server, &["alice", "bob"]);
    talks_to(&v[0], &v[1]);
    let st = v[0].client.client_statistics().unwrap();
    assert!(st.voice_bytes_sent > 0 && st.udp_bytes_sent > 0, "{st:?}");
    let st = v[1].client.client_statistics().unwrap();
    assert!(st.voice_bytes_received > 0, "{st:?}");
}

#[test]
fn each_person_records_to_their_own_files() {
    let server = Server::start();
    let v = in_root(&server, &["alice", "bob"]);
    let (a, b) = (&v[0], &v[1]);
    let dir = std::env::temp_dir().join(format!("ttng-each-{}-{}", std::process::id(), server.port));
    std::fs::create_dir_all(&dir).unwrap();
    a.client
        .set_record_each(Some((dir.to_str().unwrap(), RecordingFormat::Wave)))
        .unwrap();
    assert_eq!(a.client.snapshot().recording_each.as_deref(), dir.to_str());
    let bob = b.client.snapshot().my_user_id;
    b.client.set_test_tone(440).unwrap();
    b.client.set_transmitting(true).unwrap();
    a.wait_for("Bob talking", |e| {
        matches!(e, Event::TalkingChanged { user_id, talking: true } if *user_id == bob).then_some(())
    });
    std::thread::sleep(Duration::from_millis(1500));
    b.client.set_transmitting(false).unwrap();
    a.wait_for("Bob stopping", |e| {
        matches!(e, Event::TalkingChanged { user_id, talking: false } if *user_id == bob).then_some(())
    });
    // The SDK finishes the file a moment after the talk ends.
    std::thread::sleep(Duration::from_millis(1000));
    a.client.set_record_each(None).unwrap();
    let files: Vec<_> = std::fs::read_dir(&dir).unwrap().flatten().collect();
    let bobs: Vec<_> = files
        .iter()
        .filter(|f| f.file_name().to_string_lossy().contains("Bob"))
        .collect();
    assert!(
        !bobs.is_empty(),
        "files: {:?}",
        files.iter().map(|f| f.file_name()).collect::<Vec<_>>()
    );
    // A talk can come in more than one file; the longest holds it.
    let longest = bobs.iter().map(|f| f.metadata().unwrap().len()).max().unwrap();
    assert!(longest > 10_000, "Bob's talk is in it ({longest} bytes)");
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn each_person_can_be_recorded_as_mp3() {
    let server = Server::start();
    let v = in_root(&server, &["alice", "bob"]);
    let (a, b) = (&v[0], &v[1]);
    let dir = std::env::temp_dir().join(format!("ttng-each-mp3-{}-{}", std::process::id(), server.port));
    std::fs::create_dir_all(&dir).unwrap();
    a.client
        .set_record_each(Some((dir.to_str().unwrap(), RecordingFormat::Mp3)))
        .unwrap();
    let bob = b.client.snapshot().my_user_id;
    b.client.set_test_tone(440).unwrap();
    b.client.set_transmitting(true).unwrap();
    a.wait_for("Bob talking", |e| {
        matches!(e, Event::TalkingChanged { user_id, talking: true } if *user_id == bob).then_some(())
    });
    std::thread::sleep(Duration::from_millis(1500));
    b.client.set_transmitting(false).unwrap();
    // Each file becomes an MP3 once the SDK finishes it.
    let mp3s = || -> Vec<std::path::PathBuf> {
        std::fs::read_dir(&dir)
            .unwrap()
            .flatten()
            .map(|f| f.path())
            .filter(|p| p.extension().is_some_and(|e| e == "mp3"))
            .collect()
    };
    let start = std::time::Instant::now();
    while mp3s().is_empty() && start.elapsed() < Duration::from_secs(10) {
        std::thread::sleep(Duration::from_millis(100));
    }
    // The conversions running then get a moment to finish.
    std::thread::sleep(Duration::from_millis(500));
    a.client.set_record_each(None).unwrap();
    let names: Vec<_> = std::fs::read_dir(&dir)
        .unwrap()
        .flatten()
        .map(|f| f.file_name())
        .collect();
    let found = mp3s();
    assert!(
        found.iter().any(|p| p.to_string_lossy().contains("Bob")),
        "files: {names:?}"
    );
    let loud = found
        .iter()
        .map(|p| {
            mp3_check::decode_mp3(p)
                .0
                .iter()
                .filter(|s| s.unsigned_abs() > 1000)
                .count()
        })
        .max()
        .unwrap();
    assert!(
        loud > 4800,
        "Bob's talk is in an MP3 ({loud} loud samples); files: {names:?}"
    );
    let _ = std::fs::remove_dir_all(&dir);
}
