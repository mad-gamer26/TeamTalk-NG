//! The core against a real TeamTalk server (BearWare's tt5srv): logging in,
//! channels, people, messages, status, voice, reconnecting.

mod common;

use std::time::{Duration, Instant};

use common::{Server, TestClient};
use ttng_core::*;

#[test]
fn logs_in_and_sees_the_server() {
    let server = Server::start();
    let a = TestClient::logged_in(&server, "alice");
    let s = a.client.snapshot();
    assert_eq!(s.state, Some(ConnectionState::LoggedIn));
    assert_eq!(s.server.name, "TTNG Test");
    assert_eq!(s.server.motd, "Welcome to the test server");
    assert!(s.my_user_id > 0);
    let me = s.user(s.my_user_id).expect("I'm in the user list");
    assert_eq!(
        (me.nickname.as_str(), me.username.as_str(), me.client_name.as_str()),
        ("Alice", "alice", "TeamTalk NG")
    );
    let root = s.channels.iter().find(|c| c.parent_id == 0).expect("a root channel");
    assert_eq!(s.channel_path(root.id), "/");
    assert!(sdk_version().starts_with("5.23"), "{}", sdk_version());
}

#[test]
fn a_wrong_password_says_so_and_isnt_retried() {
    let server = Server::start();
    let a = TestClient::new();
    let mut o = server.options("alice");
    o.password = "wrong".into();
    o.reconnect = true;
    let err = a.client.connect(o).unwrap_err();
    assert_eq!(err.to_string(), "The username or password is wrong.");
    a.wait_for("the failure event", |e| {
        matches!(e, Event::ConnectionFailed(m) if m == "The username or password is wrong.").then_some(())
    });
    std::thread::sleep(Duration::from_millis(1500));
    assert_eq!(
        a.client.snapshot().state,
        Some(ConnectionState::Disconnected),
        "not retried"
    );
}

#[test]
fn nobody_listening_is_a_connection_error() {
    let mut server = Server::start();
    let o = server.options("alice");
    server.stop();
    let a = TestClient::new();
    let err = a.client.connect(o).unwrap_err();
    assert!(
        matches!(err, Error::Connection(ref m) if m.starts_with("Couldn't connect to 127.0.0.1:")),
        "{err:?}"
    );
}

#[test]
fn people_join_talk_and_message_each_other() {
    let server = Server::start();
    let a = TestClient::logged_in(&server, "alice");
    let b = TestClient::logged_in(&server, "bob");
    // Alice sees Bob log in.
    let bob = a.wait_for("Bob logging in", |e| match e {
        Event::UserLoggedIn(u) if u.username == "bob" => Some(u.clone()),
        _ => None,
    });
    assert_eq!(bob.display_name(), "Bob");

    // Both join the root channel; each sees the other there.
    a.client.join_channel_path("/", "").expect("Alice joins");
    b.client.join_channel_path("/", "").expect("Bob joins");
    let root = a.client.snapshot().my_channel_id;
    assert!(root > 0);
    a.wait_for("Bob joining", |e| {
        matches!(e, Event::UserJoined { user, channel_id } if user.username == "bob" && *channel_id == root)
            .then_some(())
    });
    assert_eq!(a.client.snapshot().users_in(root).len(), 2);

    // A channel message, both ways.
    a.client
        .send_message(MessageTarget::Channel(root), "Hello, channel!")
        .unwrap();
    let got = b.wait_for("the channel message", |e| match e {
        Event::MessageReceived(m) => Some(m.clone()),
        _ => None,
    });
    assert_eq!(
        (got.target, got.text.as_str(), got.from_username.as_str()),
        (MessageTarget::Channel(root), "Hello, channel!", "alice")
    );
    // The sender gets their own channel message back (the server echoes it),
    // so the apps show it from the event. Private messages aren't echoed:
    // the apps show those when sent.
    a.wait_for("Alice's own message", |e| {
        matches!(e, Event::MessageReceived(m) if m.text == "Hello, channel!").then_some(())
    });

    // A private message.
    let alice_id = a.client.snapshot().my_user_id;
    b.client
        .send_message(MessageTarget::User(alice_id), "Just for you")
        .unwrap();
    let got = a.wait_for("the private message", |e| match e {
        Event::MessageReceived(m) if m.text == "Just for you" => Some(m.clone()),
        _ => None,
    });
    assert_eq!(got.target, MessageTarget::User(alice_id));

    // A long message arrives whole (sent in parts).
    let long: String = (0..400).map(|i| format!("{i} ")).collect::<String>() + "Ünïcödé end";
    assert!(long.len() > 1500);
    a.client.send_message(MessageTarget::Channel(root), &long).unwrap();
    let got = b.wait_for("the long message", |e| match e {
        Event::MessageReceived(m) if m.text.ends_with("end") => Some(m.text.clone()),
        _ => None,
    });
    assert_eq!(got, long);

    // Leaving.
    b.client.leave_channel().unwrap();
    a.wait_for("Bob leaving", |e| {
        matches!(e, Event::UserLeft { user, channel_id } if user.username == "bob" && *channel_id == root).then_some(())
    });
    assert_eq!(b.client.snapshot().my_channel_id, 0);
}

#[test]
fn status_and_nickname_changes_reach_others() {
    let server = Server::start();
    let a = TestClient::logged_in(&server, "alice");
    let b = TestClient::logged_in(&server, "bob");
    a.client.set_status(StatusMode::Away, "Back soon").unwrap();
    let u = b.wait_for("Alice's status", |e| match e {
        Event::UserUpdated(u) if u.username == "alice" && u.status == StatusMode::Away => Some(u.clone()),
        _ => None,
    });
    assert_eq!(u.status_message, "Back soon");
    a.client.set_nickname("Alice B.").unwrap();
    b.wait_for("Alice's new nickname", |e| {
        matches!(e, Event::UserUpdated(u) if u.nickname == "Alice B.").then_some(())
    });
    assert_eq!(b.user_named("Alice B.").username, "alice");
}

#[test]
fn voice_reaches_the_other_person() {
    let server = Server::start();
    let a = TestClient::logged_in(&server, "alice");
    let b = TestClient::logged_in(&server, "bob");
    for c in [&a, &b] {
        c.client
            .init_audio(AudioDevices::Virtual)
            .expect("virtual sound device");
        c.client.join_channel_path("/", "").unwrap();
    }
    let alice_id = a.client.snapshot().my_user_id;
    // A tone instead of a microphone, sent while "push to talk" is held.
    a.client.set_test_tone(440).unwrap();
    a.client.set_transmitting(true).unwrap();
    b.wait_for("Alice talking", |e| {
        matches!(e, Event::TalkingChanged { user_id, talking: true } if *user_id == alice_id).then_some(())
    });
    assert!(b.client.snapshot().user(alice_id).unwrap().talking);
    a.client.set_transmitting(false).unwrap();
    b.wait_for("Alice stopping", |e| {
        matches!(e, Event::TalkingChanged { user_id, talking: false } if *user_id == alice_id).then_some(())
    });
}

#[test]
fn reconnects_and_rejoins_after_the_server_comes_back() {
    let mut server = Server::start();
    let a = TestClient::new();
    let mut o = server.options("alice");
    o.reconnect = true;
    o.join_channel = Some(("/".into(), String::new()));
    a.client.connect(o).unwrap();
    assert!(a.client.snapshot().my_channel_id > 0, "joined the channel to join");

    server.restart();
    a.wait_for("reconnecting", |e| {
        matches!(e, Event::ConnectionChanged(ConnectionState::Reconnecting { .. })).then_some(())
    });
    a.wait_for("logged in again", |e| {
        matches!(e, Event::ConnectionChanged(ConnectionState::LoggedIn)).then_some(())
    });
    a.wait_for("back in the channel", |e| {
        matches!(e, Event::UserJoined { user, .. } if user.username == "alice").then_some(())
    });
    let s = a.client.snapshot();
    assert_eq!(s.state, Some(ConnectionState::LoggedIn));
    assert!(s.my_channel_id > 0);
}

#[test]
fn disconnecting_is_clean_and_calls_then_say_not_connected() {
    let server = Server::start();
    let a = TestClient::logged_in(&server, "alice");
    a.client.disconnect().unwrap();
    let s = a.client.snapshot();
    assert_eq!(
        (s.state, s.users.len(), s.channels.len()),
        (Some(ConnectionState::Disconnected), 0, 0)
    );
    assert_eq!(
        a.client.join_channel_path("/", ""),
        Err(Error::Refused("There's no channel /.".into()))
    );
    assert_eq!(
        a.client.send_message(MessageTarget::Broadcast, "hi"),
        Err(Error::NotConnected)
    );
}

#[test]
fn voice_activation_talks_when_there_is_sound() {
    let server = Server::start();
    let a = TestClient::logged_in(&server, "alice");
    let b = TestClient::logged_in(&server, "bob");
    for c in [&a, &b] {
        c.client.init_audio(AudioDevices::Virtual).unwrap();
        c.client.join_channel_path("/", "").unwrap();
    }
    let alice_id = a.client.snapshot().my_user_id;
    // Silence first. Turning voice activation on may send for about the
    // stop delay even in silence (the SDK can start it active); after that
    // it stays stopped.
    a.client.set_voice_activation(true, 10, 300).unwrap();
    std::thread::sleep(Duration::from_millis(1000));
    let quiet_by = Instant::now() + Duration::from_secs(5);
    while b.client.snapshot().user(alice_id).unwrap().talking {
        assert!(Instant::now() < quiet_by, "Alice never stopped");
        std::thread::sleep(Duration::from_millis(50));
    }
    a.drain();
    b.drain();
    std::thread::sleep(Duration::from_millis(800));
    assert!(
        !b.client.snapshot().user(alice_id).unwrap().talking,
        "silence isn't sent"
    );
    // A tone: the level rises, voice activation starts sending.
    a.client.set_test_tone(440).unwrap();
    a.wait_for("voice activation starting", |e| {
        matches!(e, Event::VoiceActivated(true)).then_some(())
    });
    b.wait_for("Alice talking", |e| {
        matches!(e, Event::TalkingChanged { user_id, talking: true } if *user_id == alice_id).then_some(())
    });
    let level_by = Instant::now() + Duration::from_secs(2);
    while a.client.input_level() <= 10 {
        assert!(Instant::now() < level_by, "the level meter never read the tone");
        std::thread::sleep(Duration::from_millis(20));
    }
    // Quiet again: it stops after the delay.
    a.client.set_test_tone(0).unwrap();
    a.wait_for("voice activation stopping", |e| {
        matches!(e, Event::VoiceActivated(false)).then_some(())
    });
    b.wait_for("Alice stopping", |e| {
        matches!(e, Event::TalkingChanged { user_id, talking: false } if *user_id == alice_id).then_some(())
    });
    // Someone's volume, in percent.
    b.client.set_user_volume(alice_id, 200).unwrap();
    b.client.set_user_muted(alice_id, true).unwrap();
}

#[test]
fn several_servers_at_once() {
    let one = Server::start();
    let two = Server::start();
    // One app, two connections.
    let a1 = TestClient::logged_in(&one, "alice");
    let a2 = TestClient::logged_in(&two, "alice");
    let b1 = TestClient::logged_in(&one, "bob");
    let c2 = TestClient::logged_in(&two, "carol");
    for c in [&a1, &a2, &b1, &c2] {
        c.client.join_channel_path("/", "").unwrap();
    }
    a1.client
        .send_message(
            MessageTarget::Channel(a1.client.snapshot().my_channel_id),
            "on server one",
        )
        .unwrap();
    a2.client
        .send_message(
            MessageTarget::Channel(a2.client.snapshot().my_channel_id),
            "on server two",
        )
        .unwrap();
    b1.wait_for("server one's message", |e| {
        matches!(e, Event::MessageReceived(m) if m.text == "on server one").then_some(())
    });
    c2.wait_for("server two's message", |e| {
        matches!(e, Event::MessageReceived(m) if m.text == "on server two").then_some(())
    });
    // Each connection only knows its own server's people.
    assert!(a1.client.snapshot().users.iter().any(|u| u.username == "bob"));
    assert!(!a1.client.snapshot().users.iter().any(|u| u.username == "carol"));
    assert!(a2.client.snapshot().users.iter().any(|u| u.username == "carol"));
}
