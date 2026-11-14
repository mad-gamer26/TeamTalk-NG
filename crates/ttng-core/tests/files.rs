//! Channel files against a real TeamTalk server: uploading, seeing,
//! downloading, deleting.

mod common;

use common::{Server, TestClient};
use ttng_core::*;

fn finished(c: &TestClient, inbound: bool) -> Transfer {
    c.wait_for("the transfer finishing", |e| match e {
        Event::TransferChanged(t) if t.inbound == inbound && t.status != TransferStatus::Active => Some(t.clone()),
        _ => None,
    })
}

#[test]
fn files_go_up_come_down_and_go_away() {
    let server = Server::start();
    let a = TestClient::logged_in(&server, "alice");
    let b = TestClient::logged_in(&server, "bob");
    for c in [&a, &b] {
        c.client.join_channel_path("/", "").unwrap();
    }
    let root = a.client.snapshot().my_channel_id;
    let dir = std::env::temp_dir().join(format!("ttng-files-{}-{}", std::process::id(), server.port));
    std::fs::create_dir_all(&dir).unwrap();
    // 3 MB of varied bytes, with a name that isn't plain ASCII.
    let content: Vec<u8> = (0..3_000_000u32)
        .map(|i| (i.wrapping_mul(2_654_435_761) >> 13) as u8)
        .collect();
    let up = dir.join("Grüße 1.bin");
    std::fs::write(&up, &content).unwrap();

    a.client
        .upload_file(root, up.to_str().unwrap())
        .expect("upload accepted");
    let t = finished(&a, false);
    assert_eq!(
        (t.status, t.remote_name.as_str(), t.size),
        (TransferStatus::Finished, "Grüße 1.bin", 3_000_000)
    );
    let f = b.wait_for("the new file", |e| match e {
        Event::FileAdded(f) => Some(f.clone()),
        _ => None,
    });
    assert_eq!(
        (f.channel_id, f.name.as_str(), f.size, f.uploader.as_str()),
        (root, "Grüße 1.bin", 3_000_000, "alice")
    );
    assert_eq!(b.client.snapshot().files_in(root).len(), 1);

    let down = dir.join("downloaded.bin");
    b.client
        .download_file(root, f.id, down.to_str().unwrap())
        .expect("download accepted");
    let t = finished(&b, true);
    assert_eq!(t.status, TransferStatus::Finished);
    assert_eq!(std::fs::read(&down).unwrap(), content, "the same bytes");
    assert!(b.client.snapshot().transfers.is_empty(), "nothing left under way");

    a.client.delete_file(root, f.id).expect("deleted");
    b.wait_for("the file going", |e| {
        matches!(e, Event::FileRemoved(g) if g.id == f.id).then_some(())
    });
    assert!(b.client.snapshot().files_in(root).is_empty());
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn what_cant_be_done_says_why() {
    let server = Server::start();
    let a = TestClient::logged_in(&server, "alice");
    a.client.join_channel_path("/", "").unwrap();
    let root = a.client.snapshot().my_channel_id;
    assert_eq!(
        a.client.upload_file(root, "/nowhere/at/all.txt"),
        Err(Error::Refused("There's no file at /nowhere/at/all.txt.".into()))
    );
    let gone = Err(Error::Refused("That file isn't there any more.".into()));
    assert_eq!(a.client.delete_file(root, 4242), gone);
    assert_eq!(a.client.download_file(root, 4242, "/tmp/x"), gone);
    assert_eq!(
        a.client.cancel_transfer(99),
        Err(Error::Refused("That transfer isn't running.".into()))
    );
}
