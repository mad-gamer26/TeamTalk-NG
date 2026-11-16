//! People, as the desktop clients handle them: subscriptions and
//! intercepts, how I hear someone, operators, classroom permissions,
//! channel bans, gender, statistics, relaying.

mod common;

use std::time::Duration;

use common::{Server, TestClient};
use ttng_core::*;

fn in_root(server: &Server, names: &[&str]) -> Vec<TestClient> {
    names
        .iter()
        .map(|n| {
            let c = TestClient::logged_in(server, n);
            c.client.join_channel_path("/", "").unwrap();
            c
        })
        .collect()
}

fn me(c: &TestClient) -> i32 {
    c.client.snapshot().my_user_id
}

fn person(c: &TestClient, id: i32) -> User {
    // Someone who logged in a moment ago may not have arrived yet.
    for _ in 0..100 {
        if let Some(u) = c.client.snapshot().user(id).cloned() {
            return u;
        }
        std::thread::sleep(Duration::from_millis(50));
    }
    panic!("user {id} never appeared")
}

#[test]
fn subscriptions_decide_what_arrives() {
    let server = Server::start();
    let v = in_root(&server, &["alice", "bob"]);
    let (a, b) = (&v[0], &v[1]);
    let bob = me(b);
    assert!(
        person(a, bob).my_subscriptions.has(Subscription::ChannelMessages),
        "on by default"
    );

    a.client
        .set_subscription(bob, Subscription::ChannelMessages, false)
        .unwrap();
    assert!(!person(a, bob).my_subscriptions.has(Subscription::ChannelMessages));
    // Bob sees that Alice no longer takes his channel messages.
    b.wait_for("Alice's change", |e| {
        matches!(e, Event::UserUpdated(u) if u.username == "alice" && !u.their_subscriptions.has(Subscription::ChannelMessages))
            .then_some(())
    });
    let root = a.client.snapshot().my_channel_id;
    b.client.send_message(MessageTarget::Channel(root), "unheard").unwrap();
    b.client.send_message(MessageTarget::User(me(a)), "heard").unwrap();
    let got = a.wait_for("a message", |e| match e {
        Event::MessageReceived(m) if m.from_username == "bob" => Some(m.text.clone()),
        _ => None,
    });
    assert_eq!(got, "heard", "the channel message didn't arrive");

    a.client
        .set_subscription(bob, Subscription::ChannelMessages, true)
        .unwrap();
    assert!(person(a, bob).my_subscriptions.has(Subscription::ChannelMessages));

    // Hearing myself.
    a.client.set_hear_myself(true).unwrap();
    assert!(person(a, me(a)).my_subscriptions.has(Subscription::Voice));
}

#[test]
fn admins_intercept_private_messages() {
    let server = Server::start();
    let v = in_root(&server, &["admin", "alice", "bob"]);
    let (admin, a, b) = (&v[0], &v[1], &v[2]);
    admin
        .client
        .set_subscription(me(a), Subscription::InterceptUserMessages, true)
        .expect("admins may");
    a.client
        .send_message(MessageTarget::User(me(b)), "just between us")
        .unwrap();
    let seen = admin.wait_for("the intercepted message", |e| match e {
        Event::MessageReceived(m) if m.text == "just between us" => Some(m.clone()),
        _ => None,
    });
    // The SDK gives intercepted private messages as addressed to me: who
    // they were really for isn't known.
    assert_eq!(
        (seen.from_user_id, seen.target),
        (me(a), MessageTarget::User(me(admin)))
    );
    // Not for normal people.
    let refused = b
        .client
        .set_subscription(me(a), Subscription::InterceptUserMessages, true);
    assert!(matches!(refused, Err(Error::Server { .. })), "{refused:?}");
}

#[test]
fn how_i_hear_someone() {
    let server = Server::start();
    let v = in_root(&server, &["alice", "bob"]);
    let (a, b) = (&v[0], &v[1]);
    a.client.init_audio(AudioDevices::Virtual).unwrap();
    let bob = me(b);
    a.client.set_user_volume(bob, 30).unwrap();
    a.client.set_user_media_volume(bob, 80).unwrap();
    a.client.set_user_media_muted(bob, true).unwrap();
    a.client.set_user_stereo(bob, AudioStream::Voice, true, false).unwrap();
    let p = person(a, bob);
    assert_eq!((p.voice_volume, p.media_volume), (30, 80));
    assert!(p.media_muted && !p.voice_muted);
    assert!(p.voice_left && !p.voice_right && p.media_left && p.media_right);
    a.client.set_mute_all(true).unwrap();
    assert!(a.client.snapshot().muted_all);
    a.client.set_mute_all(false).unwrap();
    assert!(!a.client.snapshot().muted_all);
}

#[test]
fn operators_and_gender() {
    let server = Server::start();
    let v = in_root(&server, &["admin", "bob"]);
    let (admin, b) = (&v[0], &v[1]);
    let root = admin.client.snapshot().my_channel_id;
    admin.client.set_operator(me(b), root, "", true).expect("made operator");
    b.wait_for("being operator", |e| {
        matches!(e, Event::UserUpdated(u) if u.username == "bob" && u.operator).then_some(())
    });
    assert!(person(admin, me(b)).operator);
    admin.client.set_operator(me(b), root, "", false).unwrap();
    b.wait_for("not being operator", |e| {
        matches!(e, Event::UserUpdated(u) if u.username == "bob" && !u.operator).then_some(())
    });

    // Gender stays when the status changes, and the other way round.
    b.client.set_status(StatusMode::Away, "Lunch").unwrap();
    b.client.set_gender(Gender::Female).unwrap();
    let u = admin.wait_for("Bob's gender", |e| match e {
        Event::UserUpdated(u) if u.username == "bob" && u.gender == Gender::Female => Some(u.clone()),
        _ => None,
    });
    assert_eq!((u.status, u.status_message.as_str()), (StatusMode::Away, "Lunch"));
    b.client.set_status(StatusMode::Question, "?").unwrap();
    let u = admin.wait_for("Bob's question", |e| match e {
        Event::UserUpdated(u) if u.username == "bob" && u.status == StatusMode::Question => Some(u.clone()),
        _ => None,
    });
    assert_eq!(u.gender, Gender::Female);
}

#[test]
fn in_a_classroom_only_those_allowed_talk() {
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
            name: "Class".into(),
            permanent: true,
            classroom: true,
            ..Default::default()
        })
        .unwrap();
    let a = TestClient::logged_in(&server, "alice");
    let b = TestClient::logged_in(&server, "bob");
    for c in [&admin, &a, &b] {
        c.client.join_channel_path("/Class/", "").unwrap();
        c.client.init_audio(AudioDevices::Virtual).unwrap();
    }
    let class = admin.client.snapshot().my_channel_id;
    let bob = me(&b);
    b.client.set_test_tone(440).unwrap();
    b.client.set_transmitting(true).unwrap();
    std::thread::sleep(Duration::from_millis(1200));
    assert!(!person(&a, bob).talking, "not allowed yet");

    admin
        .client
        .set_transmit_allowed(class, bob, TransmitStream::Voice, true)
        .expect("allowed");
    a.wait_for("Bob talking", |e| {
        matches!(e, Event::TalkingChanged { user_id, talking: true } if *user_id == bob).then_some(())
    });
    let ch = a.client.snapshot().channel(class).cloned().unwrap();
    assert!(
        ch.transmit
            .iter()
            .any(|t| t.user_id == bob && t.allows(TransmitStream::Voice))
    );

    admin
        .client
        .set_transmit_allowed(class, bob, TransmitStream::Voice, false)
        .unwrap();
    admin
        .client
        .set_transmit_allowed(class, 0, TransmitStream::ChannelMessages, true)
        .unwrap();
    let ch = admin.client.snapshot().channel(class).cloned().unwrap();
    assert!(!ch.transmit.iter().any(|t| t.user_id == bob));
    assert!(
        ch.transmit
            .iter()
            .any(|t| t.user_id == 0 && t.allows(TransmitStream::ChannelMessages))
    );
    let refused = a.client.set_transmit_allowed(class, bob, TransmitStream::Voice, true);
    assert!(refused.is_err(), "only operators and admins");
}

/// Muting someone's voice or media files shows at once (a menu that says
/// Mute again straight after would mute twice).
#[test]
fn muting_someone_shows_at_once() {
    let server = Server::start();
    let v = in_root(&server, &["alice", "bob"]);
    let (a, b) = (&v[0], &v[1]);
    let bob = me(b);
    // Alice knows Bob first (under load, he may not be listed yet).
    a.wait_until(|s| s.users.iter().any(|u| u.id == bob));
    a.client.set_user_muted(bob, true).unwrap();
    assert!(person(a, bob).voice_muted, "voice muted at once");
    a.client.set_user_media_muted(bob, true).unwrap();
    assert!(person(a, bob).media_muted, "media files muted at once");
    a.client.set_user_muted(bob, false).unwrap();
    a.client.set_user_media_muted(bob, false).unwrap();
    let p = person(a, bob);
    assert!(!p.voice_muted && !p.media_muted, "and unmuted at once");
}

/// Outside a classroom the channel's list blocks (the desktop's Transmit
/// Control in any channel): stopping Bob's voice lists him; allowing it
/// again takes him off; "everyone" is for classrooms only.
#[test]
fn transmit_control_blocks_in_an_ordinary_channel() {
    let server = Server::start();
    let v = in_root(&server, &["admin", "alice", "bob"]);
    let (admin, a, b) = (&v[0], &v[1], &v[2]);
    for c in [admin, a, b] {
        c.client.init_audio(AudioDevices::Virtual).unwrap();
    }
    let root = admin.client.snapshot().my_channel_id;
    let bob = me(b);
    b.client.set_test_tone(440).unwrap();
    b.client.set_transmitting(true).unwrap();
    a.wait_for("Bob talking", |e| {
        matches!(e, Event::TalkingChanged { user_id, talking: true } if *user_id == bob).then_some(())
    });

    admin
        .client
        .set_transmit_allowed(root, bob, TransmitStream::Voice, false)
        .expect("blocked");
    a.wait_for("Bob silenced", |e| {
        matches!(e, Event::TalkingChanged { user_id, talking: false } if *user_id == bob).then_some(())
    });
    let ch = admin.client.snapshot().channel(root).cloned().unwrap();
    assert!(
        ch.transmit
            .iter()
            .any(|t| t.user_id == bob && t.allows(TransmitStream::Voice)),
        "listed, which blocks outside a classroom"
    );

    admin
        .client
        .set_transmit_allowed(root, bob, TransmitStream::Voice, true)
        .expect("allowed again");
    a.wait_for("Bob talking again", |e| {
        matches!(e, Event::TalkingChanged { user_id, talking: true } if *user_id == bob).then_some(())
    });
    assert!(
        !admin
            .client
            .snapshot()
            .channel(root)
            .unwrap()
            .transmit
            .iter()
            .any(|t| t.user_id == bob)
    );

    let everyone = admin.client.set_transmit_allowed(root, 0, TransmitStream::Voice, false);
    assert!(matches!(everyone, Err(Error::Refused(_))), "{everyone:?}");
}

#[test]
fn channel_bans() {
    let server = Server::start();
    let v = in_root(&server, &["admin", "bob"]);
    let (admin, b) = (&v[0], &v[1]);
    let root = admin.client.snapshot().my_channel_id;
    admin.client.ban_from_channel(me(b), BanKind::Username).expect("banned");
    admin.client.kick_user(me(b), true).unwrap();
    b.wait_for("the kick", |e| {
        matches!(e, Event::Kicked { channel_id, .. } if *channel_id == root).then_some(())
    });
    let refused = b.client.join_channel(root, "");
    assert!(
        matches!(&refused, Err(Error::Server { message, .. }) if message == "Banned from channel"),
        "{refused:?}"
    );
    let bans = admin.client.list_channel_bans(root).unwrap();
    assert_eq!(bans.len(), 1, "{bans:?}");
    assert_eq!((bans[0].username.as_str(), bans[0].channel_path.as_str()), ("bob", "/"));
    assert!(admin.client.list_bans().unwrap().is_empty(), "not a server ban");
    admin.client.unban(&bans[0]).unwrap();
    b.client.join_channel(root, "").expect("welcome back");
}

#[test]
fn statistics_and_relaying() {
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
            name: "Other".into(),
            permanent: true,
            ..Default::default()
        })
        .unwrap();
    let v = in_root(&server, &["alice", "bob"]);
    let (a, b) = (&v[0], &v[1]);
    let carol = TestClient::logged_in(&server, "carol");
    carol.client.join_channel_path("/Other/", "").unwrap();
    for c in [a, b, &carol] {
        c.client.init_audio(AudioDevices::Virtual).unwrap();
    }
    // Alice relays Bob's voice into her channel (the root, where Bob also
    // is): Bob hears Alice sending it. Carol, elsewhere, just has sound open.
    let bob = me(b);
    b.client.set_test_tone(300).unwrap();
    b.client.set_transmitting(true).unwrap();
    a.wait_for("Bob talking", |e| {
        matches!(e, Event::TalkingChanged { user_id, talking: true } if *user_id == bob).then_some(())
    });
    std::thread::sleep(Duration::from_millis(500));
    let st = a.client.user_statistics(bob).unwrap();
    assert!(st.voice_packets_received > 0, "{st:?}");

    a.client.set_relay(Some((bob, AudioStream::Voice))).expect("relaying");
    assert_eq!(a.client.snapshot().relaying, Some((bob, AudioStream::Voice)));
    let alice = me(a);
    b.wait_for("Alice sending Bob's voice", |e| {
        matches!(e, Event::TalkingChanged { user_id, talking: true } if *user_id == alice).then_some(())
    });
    a.client.set_relay(None).unwrap();
    assert_eq!(a.client.snapshot().relaying, None);
}
