//! Seeing what others send: shared desktops and the video of streamed
//! media files.

mod common;

use std::process::Command;

use common::{Server, TestClient};
use ttng_core::*;

fn pair(server: &Server) -> (TestClient, TestClient) {
    let a = TestClient::logged_in(server, "alice");
    let b = TestClient::logged_in(server, "bob");
    for c in [&a, &b] {
        c.client.init_audio(AudioDevices::Virtual).unwrap();
        c.client.join_channel_path("/", "").unwrap();
    }
    (a, b)
}

#[test]
fn a_shared_desktop_arrives_as_sent() {
    let server = Server::start();
    let (a, b) = pair(&server);
    let (w, h) = (64, 48);
    let mut bgra = Vec::new();
    for y in 0..h {
        for x in 0..w {
            bgra.extend_from_slice(&[(x * 4) as u8, (y * 5) as u8, 200, 255]);
        }
    }
    a.client.send_desktop_bitmap(w, h, &bgra).expect("shared");
    let alice = a.client.snapshot().my_user_id;
    b.wait_for("the desktop", |e| {
        matches!(e, Event::VideoFrame { user_id, kind: VideoKind::Desktop, .. } if *user_id == alice).then_some(())
    });
    // A desktop arrives in blocks: wait for the whole picture.
    let rgb = |p: &[u8]| p.chunks(4).map(|c| [c[0], c[1], c[2]]).collect::<Vec<_>>();
    let end = std::time::Instant::now() + std::time::Duration::from_secs(10);
    loop {
        let f = b.client.video_frame(alice, VideoKind::Desktop).expect("the picture");
        assert_eq!((f.width, f.height), (w, h));
        if rgb(&f.bgra) == rgb(&bgra) {
            break;
        }
        assert!(std::time::Instant::now() < end, "every pixel arrives");
        std::thread::sleep(std::time::Duration::from_millis(100));
    }
    a.client.stop_desktop().unwrap();
}

#[test]
fn a_streamed_video_arrives() {
    let dir = std::env::temp_dir().join(format!("ttng-video-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let mp4 = dir.join("test.webm");
    // VP8 in WebM: the Linux SDK reads an H.264 file's size but doesn't
    // decode its pictures.
    let made = Command::new("ffmpeg")
        .args([
            "-hide_banner",
            "-loglevel",
            "error",
            "-f",
            "lavfi",
            "-i",
            "testsrc=size=320x240:rate=15",
            "-f",
            "lavfi",
            "-i",
            "sine=frequency=440",
            "-t",
            "3",
            "-c:v",
            "libx264",
            "-pix_fmt",
            "yuv420p",
            "-c:a",
            "aac",
            "-y",
        ])
        .arg(&mp4)
        .status()
        .is_ok_and(|s| s.success());
    if !made {
        eprintln!("skipped: no ffmpeg to make a test video");
        return;
    }
    let info = media_file_info(mp4.to_str().unwrap()).expect("playable");
    assert_eq!((info.video_width, info.video_height), (320, 240));
    let server = Server::start();
    let (a, b) = pair(&server);
    a.client.set_stream_video(true).unwrap();
    a.client
        .stream_media_file(mp4.to_str().unwrap(), 0, false, false)
        .unwrap();
    let alice = a.client.snapshot().my_user_id;
    let (w, h) = b.wait_for("the video", |e| match e {
        Event::VideoFrame {
            user_id,
            kind: VideoKind::MediaFile,
            width,
            height,
        } if *user_id == alice => Some((*width, *height)),
        _ => None,
    });
    assert_eq!((w, h), (320, 240));
    let f = b.client.video_frame(alice, VideoKind::MediaFile).unwrap();
    assert_eq!(f.bgra.len(), 320 * 240 * 4);
    a.client.stop_stream().unwrap();
    let _ = std::fs::remove_dir_all(&dir);
}
