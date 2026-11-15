//! The desktop's Server menu: user accounts, every server setting, saving
//! the configuration, statistics, and banning an address.

mod common;

use common::{Server, TestClient};
use ttng_core::*;

#[test]
fn accounts_are_added_changed_and_deleted() {
    let server = Server::start();
    let admin = TestClient::logged_in(&server, "admin");
    let names: Vec<String> = admin
        .client
        .list_accounts()
        .unwrap()
        .into_iter()
        .map(|a| a.username)
        .collect();
    for n in ["admin", "alice", "bob", "carol"] {
        assert!(names.contains(&n.to_owned()), "{names:?}");
    }
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
            name: "Lobby".into(),
            permanent: true,
            ..Default::default()
        })
        .unwrap();
    let lobby = admin
        .wait_until(|s| s.channels.iter().any(|c| c.name == "Lobby"))
        .channels
        .into_iter()
        .find(|c| c.name == "Lobby")
        .unwrap()
        .id;
    let dave = UserAccount {
        username: "dave".into(),
        password: "dave-pw".into(),
        rights: UserRight::defaults(),
        note: "Joined in November".into(),
        initial_channel: "/Lobby/".into(),
        auto_operator_channels: vec![lobby],
        bitrate_limit: 64000,
        commands_limit: 20,
        commands_interval_ms: 10_000,
        ..Default::default()
    };
    admin.client.save_account(&dave).expect("added");
    let got = admin
        .client
        .list_accounts()
        .unwrap()
        .into_iter()
        .find(|a| a.username == "dave")
        .expect("listed");
    assert_eq!(
        (
            got.note.as_str(),
            got.initial_channel.as_str(),
            got.bitrate_limit,
            got.commands_limit
        ),
        ("Joined in November", "/Lobby/", 64000, 20)
    );
    assert_eq!(got.auto_operator_channels, vec![lobby]);
    assert!(
        !got.admin && got.rights.contains(&UserRight::TransmitVoice) && !got.rights.contains(&UserRight::KickUsers)
    );

    // Dave logs in: he lands in the initial channel, as its operator.
    let d = TestClient::new();
    let mut o = server.options("dave");
    o.password = "dave-pw".into();
    d.client.connect(o).expect("Dave logs in");
    let s = d.wait_until(|s| s.my_channel_id == lobby);
    assert!(s.user(s.my_user_id).unwrap().operator, "auto-operator");
    assert!(!s.my_rights.kick);

    // A change (now he may kick), then away with him.
    admin
        .client
        .save_account(&UserAccount {
            rights: [UserRight::defaults(), vec![UserRight::KickUsers]].concat(),
            ..dave.clone()
        })
        .unwrap();
    let changed = admin
        .client
        .list_accounts()
        .unwrap()
        .into_iter()
        .find(|a| a.username == "dave")
        .unwrap();
    assert!(changed.rights.contains(&UserRight::KickUsers));
    admin.client.delete_account("dave").expect("deleted");
    assert!(
        !admin
            .client
            .list_accounts()
            .unwrap()
            .iter()
            .any(|a| a.username == "dave")
    );

    // Not for normal people.
    let alice = TestClient::logged_in(&server, "alice");
    assert!(alice.client.list_accounts().is_err());
    assert!(alice.client.save_account(&dave).is_err());
}

#[test]
fn every_server_setting_round_trips() {
    let server = Server::start();
    let admin = TestClient::logged_in(&server, "admin");
    let before = admin.client.server_settings().unwrap();
    assert_eq!(before.name, "TTNG Test");
    assert!(before.version.starts_with('5'), "{before:?}");
    let wanted = ServerSettings {
        name: "Renamed".into(),
        motd: "Hello %users% people".into(),
        max_users: 42,
        max_login_attempts: 5,
        max_logins_per_address: 3,
        login_delay_ms: 250,
        voice_limit: 64_000,
        video_limit: 128_000,
        media_file_limit: 96_000,
        desktop_limit: 32_000,
        total_limit: 512_000,
        user_timeout: 30,
        ..before.clone()
    };
    admin.client.update_server_settings(&wanted).expect("updated");
    admin.wait_for("the update", |e| {
        matches!(e, Event::ServerUpdated(s) if s.name == "Renamed").then_some(())
    });
    let after = admin.client.server_settings().unwrap();
    assert_eq!(
        ServerSettings {
            version: String::new(),
            protocol_version: String::new(),
            ..after.clone()
        },
        ServerSettings {
            version: String::new(),
            protocol_version: String::new(),
            ..wanted
        }
    );
    admin.client.save_server_config().expect("saved");
    let alice = TestClient::logged_in(&server, "alice");
    assert!(alice.client.save_server_config().is_err());
    assert!(alice.client.update_server_settings(&after).is_err());
}

#[test]
fn statistics_and_address_bans() {
    let server = Server::start();
    let admin = TestClient::logged_in(&server, "admin");
    let _alice = TestClient::logged_in(&server, "alice");
    let st = admin.client.server_statistics().expect("statistics");
    assert!(st.users_served >= 2 && st.users_peak >= 2, "{st:?}");
    assert!(st.uptime_ms > 0 && st.total_bytes_received > 0, "{st:?}");

    admin.client.ban_address("10.1.2.*", "").expect("banned");
    admin
        .client
        .ban_address("10.9.9.9", "/")
        .expect("banned from a channel");
    let server_bans = admin.client.list_bans().unwrap();
    assert!(
        server_bans
            .iter()
            .any(|b| b.ip_address == "10.1.2.*" && b.by_ip_address),
        "{server_bans:?}"
    );
    let root = admin
        .client
        .snapshot()
        .channels
        .iter()
        .find(|c| c.parent_id == 0)
        .unwrap()
        .id;
    let channel_bans = admin.client.list_channel_bans(root).unwrap();
    assert!(
        channel_bans.iter().any(|b| b.ip_address == "10.9.9.9"),
        "{channel_bans:?}"
    );

    // A username by hand (the desktop's "Ban Username"): carol can't log in.
    admin.client.ban_username("carol", "").expect("banned by username");
    let carol = TestClient::new();
    let refused = carol.client.connect(server.options("carol"));
    assert!(
        matches!(&refused, Err(Error::Server { message, .. }) if message == "Banned from server"),
        "{refused:?}"
    );
    assert!(admin.client.list_bans().unwrap().iter().any(|b| b.username == "carol"));
    for b in admin.client.list_bans().unwrap().iter().chain(&channel_bans) {
        admin.client.unban(b).unwrap();
    }
    assert!(admin.client.list_bans().unwrap().is_empty());
}

/// Kicked and banned from the server by username (the people menu's), the
/// ban removed: they log in and join channels again.
#[test]
fn a_kick_and_ban_from_the_server_removed_lets_them_back_in() {
    let server = Server::start();
    let admin = TestClient::logged_in(&server, "admin");
    let carol = TestClient::logged_in(&server, "carol");
    carol.client.join_channel_path("/", "").unwrap();
    let id = admin
        .wait_until(|s| s.users.iter().any(|u| u.username == "carol"))
        .users
        .iter()
        .find(|u| u.username == "carol")
        .unwrap()
        .id;
    admin.client.ban_user(id, BanKind::Username).expect("banned");
    admin.client.kick_user(id, false).expect("kicked");
    carol.wait_for("the kick", |e| matches!(e, Event::Kicked { .. }).then_some(()));
    let bans = admin.client.list_bans().unwrap();
    let ban = bans.iter().find(|b| b.username == "carol").expect("listed").clone();
    assert!(!ban.in_channel, "a server ban: {ban:?}");
    assert!(
        TestClient::new().client.connect(server.options("carol")).is_err(),
        "banned: can't log in"
    );
    admin.client.unban(&ban).expect("unbanned");
    assert!(admin.client.list_bans().unwrap().is_empty());
    let back = TestClient::logged_in(&server, "carol");
    back.client
        .join_channel_path("/", "")
        .expect("joins the root channel again");
    back.wait_until(|s| s.my_channel_id > 0);
}
