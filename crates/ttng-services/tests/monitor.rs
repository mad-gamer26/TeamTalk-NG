//! The Monitor end to end: a private ngmon watching a private TeamTalk
//! server (tt5srv), with the core logged in as the other person.

mod common;
#[path = "../../ttng-core/tests/common/mod.rs"]
mod tt;

use std::time::{Duration, Instant};

use common::*;
use ttng_core::{Event, MessageTarget};
use ttng_services::*;

fn until<T>(what: &str, mut f: impl FnMut() -> Option<T>) -> T {
    let end = Instant::now() + Duration::from_secs(20);
    loop {
        if let Some(v) = f() {
            return v;
        }
        assert!(Instant::now() < end, "no {what} within 20 s");
        std::thread::sleep(Duration::from_millis(200));
    }
}

#[test]
fn the_monitor_watches_and_carries_private_messages() {
    let Some(ng) = Ngmon::start() else { return };
    let server = tt::Server::start();
    let mut mon = Monitor::new(&ng.url, None);
    let reg = mon.register("Test iPhone").expect("registered");
    assert_eq!(reg.push_key.len(), 44, "a 32-byte key in base64");
    // Notifications: a development build's APNs token, then off.
    mon.set_push(Some(&"ab".repeat(32)), true, "ref-1", "install-1")
        .expect("push token set");
    assert!(
        mon.set_push(Some("not hex"), true, "ref-1", "install-1").is_err(),
        "a bad token is refused"
    );
    mon.set_push(None, true, "ref-1", "install-1").expect("push off");

    let id = mon
        .add_server(&MonitorServerInput {
            name: "Test".into(),
            host: "127.0.0.1".into(),
            tcp_port: server.port,
            nickname: "Alice (monitor)".into(),
            username: "alice".into(),
            password: "alice-pw".into(),
            enabled: true,
            ..Default::default()
        })
        .expect("added");
    let watching = until("the monitor logging in", || {
        mon.servers()
            .unwrap()
            .into_iter()
            .find(|s| s.id == id && s.status == "logged_in")
    });
    assert_eq!(watching.status_text(), "Watching");
    let view = mon.view(id).unwrap();
    assert_eq!(view.server_name, "TTNG Test");
    assert!(view.my_user_id > 0);
    let since = view.seq;

    // Bob logs in: an event, in words.
    let bob = tt::TestClient::logged_in(&server, "bob");
    let e = until("Bob's login", || {
        mon.events(Some(since), Some(id))
            .unwrap()
            .events
            .into_iter()
            .find(|e| e.kind == "logged_in")
    });
    assert_eq!(e.text, "Bob logged in");
    assert!(e.user_id > 0, "who logged in: {e:?}");
    assert!(mon.view(id).unwrap().users.iter().any(|u| u.username == "bob"));

    // Bob writes to the monitor privately: a conversation.
    bob.client
        .send_message(MessageTarget::User(view.my_user_id as i32), "Are you there?")
        .unwrap();
    let c = until("the conversation", || {
        mon.conversations(Some(id))
            .unwrap()
            .into_iter()
            .find(|c| c.username == "bob")
    });
    assert_eq!((c.last_text.as_str(), c.unread, c.active), ("Are you there?", 1, true));
    let e = until("the message event", || {
        mon.events(Some(since), Some(id))
            .unwrap()
            .events
            .into_iter()
            .find(|e| e.kind == "message")
    });
    assert_eq!(
        (e.text.as_str(), e.message_kind.as_str()),
        ("Bob, privately: Are you there?", "user")
    );
    // Its parts, for showing it as a live connection would.
    assert_eq!((e.body.as_str(), e.outgoing), ("Are you there?", false));
    assert!(e.user_id > 0 && e.user_name == "Bob", "{e:?}");

    // A reply from the app, through the monitor, reaches Bob.
    mon.send_message(
        id,
        &MonitorTarget::User {
            user_id: c.user_id,
            conversation_id: Some(c.id),
        },
        "Yes, on my phone",
    )
    .unwrap();
    bob.wait_for("the reply", |e| {
        matches!(e, Event::MessageReceived(m) if m.text == "Yes, on my phone").then_some(())
    });
    let m = mon.messages(id, c.id, None).unwrap();
    assert_eq!(
        m.iter().map(|m| (m.outgoing, m.text.as_str())).collect::<Vec<_>>(),
        [(false, "Are you there?"), (true, "Yes, on my phone")]
    );
    mon.mark_read(id, c.id).unwrap();
    assert_eq!(mon.conversations(Some(id)).unwrap()[0].unread, 0);

    // Bob leaves: the conversation stays, no longer active.
    bob.client.disconnect().unwrap();
    until("the conversation ending", || {
        mon.conversations(Some(id)).unwrap().into_iter().find(|c| !c.active)
    });
    mon.remove_server(id).unwrap();
    assert!(mon.servers().unwrap().is_empty());
}

#[test]
fn an_ng_account_session_is_also_the_monitor() {
    let Some(ng) = Ngmon::start() else { return };
    let (_a, s) = signed_up(&ng, "mon@example.com", "phone");
    let mon = Monitor::new(&ng.url, Some(&s.token));
    assert!(mon.servers().unwrap().is_empty());
    let none = Monitor::new(&ng.url, Some("not a token"));
    assert!(matches!(none.servers(), Err(ServiceError::SignedOut(_))));
}
