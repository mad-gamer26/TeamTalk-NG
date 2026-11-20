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

    // Its settings: nickname, status message and gender, kept by the service
    // (the password stays: an empty one keeps it).
    let mut cfg = mon.server_config(id).expect("its settings");
    assert_eq!(cfg.nickname, "Alice (monitor)");
    mon.update_server(
        id,
        &MonitorServerInput {
            name: cfg.name.clone(),
            host: cfg.host.clone(),
            tcp_port: cfg.tcp_port,
            encrypted: cfg.encrypted,
            nickname: "Alice watching".into(),
            username: cfg.username.clone(),
            password: String::new(),
            status_msg: "Back soon".into(),
            status_mode: 256,
            channel: cfg.channel.clone(),
            channel_password: String::new(),
            enabled: true,
        },
    )
    .expect("updated");
    cfg = mon.server_config(id).expect("its settings again");
    assert_eq!(
        (cfg.nickname.as_str(), cfg.status_msg.as_str(), cfg.status_mode),
        ("Alice watching", "Back soon", 256)
    );
    until("the monitor logged in again with them", || {
        mon.view(id).ok().and_then(|v| {
            v.users.into_iter().find(|u| {
                u.id == v.my_user_id
                    && u.nickname == "Alice watching"
                    && u.status_mode & 256 != 0
                    && u.status_msg == "Back soon"
            })
        })
    });
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
    // Each person's client version comes too (the app showed only the name).
    let bob_seen = mon
        .view(id)
        .unwrap()
        .users
        .into_iter()
        .find(|u| u.username == "bob")
        .unwrap();
    assert!(!bob_seen.version.is_empty(), "Bob's client version: {bob_seen:?}");

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

/// The app logged in to a monitored server itself: the monitor stays (its
/// events go on), only that install's notifications pause; where the
/// account may log in once, the monitor steps aside and waits until the
/// app leaves, instead of logging in again over it.
#[test]
fn the_apps_own_login_quiets_only_this_install() {
    let Some(ng) = Ngmon::start() else { return };
    let server = tt::Server::start_single_login();
    let mut mon = Monitor::new(&ng.url, None);
    mon.register("Test iPhone").expect("registered");
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
    let status = |mon: &Monitor| {
        mon.servers()
            .unwrap()
            .into_iter()
            .find(|s| s.id == id)
            .map(|s| s.status)
            .unwrap_or_default()
    };
    until("the monitor logging in", || (status(&mon) == "logged_in").then_some(()));
    // Quiet for this install: the monitor stays logged in.
    mon.quiet(id, "install-1", 60).expect("quiet");
    std::thread::sleep(Duration::from_secs(2));
    assert_eq!(status(&mon), "logged_in", "still watching while only quiet");
    // The app logs in with the same account: the monitor steps aside and
    // stays aside (no login over the app).
    let app = tt::TestClient::logged_in(&server, "alice");
    until("the monitor stepping aside", || {
        (status(&mon) == "stepped_aside").then_some(())
    });
    std::thread::sleep(Duration::from_secs(6));
    assert_eq!(status(&mon), "stepped_aside", "waiting while the app is there");
    assert_eq!(
        app.client.snapshot().state,
        Some(ttng_core::ConnectionState::LoggedIn),
        "the app wasn't thrown off"
    );
    // The app leaves: the monitor is back at once.
    app.client.disconnect().unwrap();
    mon.unquiet(id, "install-1").expect("notifications back");
    until("the monitor back", || (status(&mon) == "logged_in").then_some(()));
    // A quiet that isn't renewed runs out by itself (the app was closed).
    mon.quiet(id, "install-1", 30).expect("quiet again");
    mon.remove_server(id).unwrap();
}

/// Leaving the hosted Monitor (for your own): the registration ends, its
/// servers (and their passwords) are deleted there, and the monitor logs out.
#[test]
fn leaving_the_hosted_monitor_deletes_what_it_kept() {
    let Some(ng) = Ngmon::start() else { return };
    let server = tt::Server::start();
    let mut mon = Monitor::new(&ng.url, None);
    let reg = mon.register("Test iPhone").expect("registered");
    let id = mon
        .add_server(&MonitorServerInput {
            name: "Test".into(),
            host: "127.0.0.1".into(),
            tcp_port: server.port,
            nickname: "Leaving".into(),
            username: "alice".into(),
            password: "alice-pw".into(),
            enabled: true,
            ..Default::default()
        })
        .expect("added");
    until("the monitor logging in", || {
        mon.servers()
            .unwrap()
            .into_iter()
            .find(|s| s.id == id && s.status == "logged_in")
    });
    mon.forget_registration().expect("left");
    assert!(!mon.has_token(), "no registration any more");
    // The old token no longer works: everything it had is gone.
    let old = Monitor::new(&ng.url, Some(&reg.token));
    assert!(old.servers().is_err(), "the registration is gone");
}

/// The next stream items until `want` accepts one (20 s at most).
fn stream_until(s: &mut EventStream, what: &str, want: impl Fn(&StreamItem) -> bool) -> Vec<StreamItem> {
    let end = Instant::now() + Duration::from_secs(20);
    let mut seen = Vec::new();
    loop {
        let item = s.receive().expect("the stream stays open");
        let done = want(&item);
        if item != StreamItem::Nothing {
            seen.push(item);
        }
        if done {
            return seen;
        }
        assert!(Instant::now() < end, "no {what} within 20 s; got {seen:?}");
    }
}

/// The hosted Monitor's live connection (no polling): ready, then each
/// event as it happens; opened again from a point, what was missed first.
#[test]
fn the_hosted_monitors_events_come_live() {
    let Some(ng) = Ngmon::start() else { return };
    let server = tt::Server::start();
    let mut mon = Monitor::new(&ng.url, None);
    mon.register("Test iPhone").expect("registered");
    let id = mon
        .add_server(&MonitorServerInput {
            name: "Test".into(),
            host: "127.0.0.1".into(),
            tcp_port: server.port,
            nickname: "Live".into(),
            username: "alice".into(),
            password: "alice-pw".into(),
            enabled: true,
            ..Default::default()
        })
        .expect("added");
    until("the monitor logging in", || {
        mon.servers()
            .unwrap()
            .into_iter()
            .find(|s| s.id == id && s.status == "logged_in")
    });
    let mut live = mon.open_events(None).expect("opened");
    let ready = stream_until(&mut live, "ready", |i| matches!(i, StreamItem::Ready(_)));
    let StreamItem::Ready(at) = *ready.last().unwrap() else {
        unreachable!()
    };
    // Bob logs in: it arrives at once.
    let bob = tt::TestClient::logged_in(&server, "bob");
    let got = stream_until(
        &mut live,
        "Bob's login",
        |i| matches!(i, StreamItem::Event(e) if e.kind == "logged_in" && e.server_id == id),
    );
    let StreamItem::Event(e) = got.last().unwrap() else {
        unreachable!()
    };
    assert!(e.seq > at);
    drop(live);
    // Missed while closed (Bob leaves), then caught up on opening again.
    drop(bob);
    std::thread::sleep(Duration::from_secs(2));
    let mut again = mon.open_events(Some(e.seq)).expect("opened again");
    let caught = stream_until(&mut again, "ready", |i| matches!(i, StreamItem::Ready(_)));
    assert!(
        caught
            .iter()
            .any(|i| matches!(i, StreamItem::Event(x) if x.kind == "logged_out")),
        "Bob's logout first: {caught:?}"
    );
    mon.remove_server(id).unwrap();
}
