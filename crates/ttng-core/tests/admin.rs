//! Administration against a real TeamTalk server: rights, channels,
//! kicking, banning, moving, the server's settings.

mod common;

use common::{Server, TestClient};
use ttng_core::*;

fn spec(parent_id: i32, name: &str) -> ChannelSpec {
    ChannelSpec {
        parent_id,
        name: name.into(),
        ..Default::default()
    }
}

#[test]
fn rights_follow_the_account() {
    let server = Server::start();
    let admin = TestClient::logged_in(&server, "admin");
    let alice = TestClient::logged_in(&server, "alice");
    let r = admin.client.snapshot().my_rights;
    assert!(r.admin && r.kick && r.ban && r.move_users && r.modify_channels && r.update_server);
    let r = alice.client.snapshot().my_rights;
    assert!(!r.admin && !r.kick && !r.ban && !r.modify_channels);
    assert!(r.upload_files && r.download_files && r.create_temporary_channels);
}

#[test]
fn channels_are_made_changed_and_removed() {
    let server = Server::start();
    let admin = TestClient::logged_in(&server, "admin");
    let alice = TestClient::logged_in(&server, "alice");
    let root = admin
        .client
        .snapshot()
        .channels
        .iter()
        .find(|c| c.parent_id == 0)
        .unwrap()
        .id;

    // A permanent channel with a password.
    admin
        .client
        .make_channel(&ChannelSpec {
            topic: "Tunes".into(),
            password: Some("secret".into()),
            permanent: true,
            ..spec(root, "Music")
        })
        .expect("made");
    let music = alice.wait_for("the new channel", |e| match e {
        Event::ChannelAdded(c) if c.name == "Music" => Some(c.clone()),
        _ => None,
    });
    assert!(music.has_password && music.permanent && music.topic == "Tunes");
    assert_eq!(alice.client.snapshot().channel_path(music.id), "/Music/");
    let wrong = alice.client.join_channel(music.id, "wrong");
    assert!(
        matches!(&wrong, Err(Error::Server { message, .. }) if message == "The channel's password is wrong."),
        "{wrong:?}"
    );
    alice
        .client
        .join_channel(music.id, "secret")
        .expect("the right password");

    // The same name twice.
    let again = admin.client.make_channel(&spec(root, "Music"));
    assert!(
        matches!(&again, Err(Error::Server { message, .. }) if message == "There's already a channel with that name there."),
        "{again:?}"
    );
    // Not for normal people.
    let refused = alice.client.make_channel(&spec(root, "Mine"));
    assert!(
        matches!(&refused, Err(Error::Server { message, .. }) if message == "You're not allowed to do that on this server."),
        "{refused:?}"
    );

    // A new topic, no password; the name and the rest stay.
    admin
        .client
        .update_channel(
            music.id,
            &ChannelSpec {
                topic: "Only the best".into(),
                password: Some(String::new()),
                permanent: true,
                ..spec(0, "Music")
            },
        )
        .expect("changed");
    let changed = alice.wait_for("the change", |e| match e {
        Event::ChannelUpdated(c) if c.id == music.id && c.topic == "Only the best" => Some(c.clone()),
        _ => None,
    });
    assert!(!changed.has_password && changed.permanent);

    alice.client.leave_channel().unwrap();
    admin.client.remove_channel(music.id).expect("removed");
    alice.wait_for("the channel going", |e| {
        matches!(e, Event::ChannelRemoved(c) if c.id == music.id).then_some(())
    });
}

#[test]
fn people_make_temporary_channels_that_go_when_empty() {
    let server = Server::start();
    let alice = TestClient::logged_in(&server, "alice");
    let bob = TestClient::logged_in(&server, "bob");
    let root = alice
        .client
        .snapshot()
        .channels
        .iter()
        .find(|c| c.parent_id == 0)
        .unwrap()
        .id;
    alice
        .client
        .join_new_channel(&spec(root, "Alice's room"))
        .expect("made and joined");
    let s = alice.client.snapshot();
    let room = s.channel(s.my_channel_id).expect("I'm in it").clone();
    assert_eq!((room.name.as_str(), room.permanent), ("Alice's room", false));
    alice.client.leave_channel().unwrap();
    bob.wait_for("the room going", |e| {
        matches!(e, Event::ChannelRemoved(c) if c.id == room.id).then_some(())
    });
}

#[test]
fn kicking_moving_and_banning() {
    let server = Server::start();
    let admin = TestClient::logged_in(&server, "admin");
    let bob = TestClient::logged_in(&server, "bob");
    let carol = TestClient::logged_in(&server, "carol");
    let root = admin
        .client
        .snapshot()
        .channels
        .iter()
        .find(|c| c.parent_id == 0)
        .unwrap()
        .id;
    let bob_id = bob.client.snapshot().my_user_id;
    let carol_id = carol.client.snapshot().my_user_id;

    // Moving Carol into a channel she wasn't in.
    admin
        .client
        .make_channel(&ChannelSpec {
            permanent: true,
            ..spec(root, "Hall")
        })
        .unwrap();
    let hall = carol.wait_for("the hall", |e| match e {
        Event::ChannelAdded(c) if c.name == "Hall" => Some(c.id),
        _ => None,
    });
    admin.client.move_user(carol_id, hall).expect("moved");
    carol.wait_for("being moved", |e| {
        matches!(e, Event::UserJoined { user, channel_id } if user.id == carol_id && *channel_id == hall).then_some(())
    });
    assert_eq!(carol.client.snapshot().my_channel_id, hall);

    // Kicked from the channel: still on the server.
    admin.client.kick_user(carol_id, true).expect("kicked from the channel");
    carol.wait_for("the channel kick", |e| {
        matches!(e, Event::Kicked { channel_id, .. } if *channel_id == hall).then_some(())
    });
    assert_eq!(carol.client.snapshot().state, Some(ConnectionState::LoggedIn));
    assert_eq!(
        admin.client.kick_user(carol_id, true),
        Err(Error::Refused("They're not in a channel.".into()))
    );

    // Banned by username, then kicked off the server: can't come back.
    admin.client.ban_user(bob_id, BanKind::Username).expect("banned");
    admin.client.kick_user(bob_id, false).expect("kicked off");
    bob.wait_for("the server kick", |e| {
        matches!(e, Event::Kicked { channel_id: 0, .. }).then_some(())
    });
    let bans = admin.client.list_bans().expect("the bans");
    assert_eq!(bans.len(), 1, "{bans:?}");
    assert!(bans[0].by_username && bans[0].username == "bob", "{bans:?}");
    let back = TestClient::new();
    let refused = back.client.connect(server.options("bob"));
    assert!(
        matches!(&refused, Err(Error::Server { message, .. }) if message == "You're banned from this server."),
        "{refused:?}"
    );

    // Unbanned: back in.
    admin.client.unban(&bans[0]).expect("unbanned");
    assert!(admin.client.list_bans().unwrap().is_empty());
    TestClient::logged_in(&server, "bob");

    // Normal people can't.
    let refused = carol.client.kick_user(admin.client.snapshot().my_user_id, false);
    assert!(matches!(refused, Err(Error::Server { .. })), "{refused:?}");
}

#[test]
fn the_server_gets_a_new_name_and_motd() {
    let server = Server::start();
    let admin = TestClient::logged_in(&server, "admin");
    let alice = TestClient::logged_in(&server, "alice");
    admin.client.update_server("Renamed", "Hello again").expect("updated");
    let s = alice.wait_for("the update", |e| match e {
        Event::ServerUpdated(s) if s.name == "Renamed" => Some(s.clone()),
        _ => None,
    });
    assert_eq!(s.motd, "Hello again");
    let refused = alice.client.update_server("Mine", "");
    assert!(matches!(refused, Err(Error::Server { .. })), "{refused:?}");
}
