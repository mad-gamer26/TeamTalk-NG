//! Server administration through the Monitor, end to end: a private ngmon
//! logged in as the server's admin on a private tt5srv, through the app's
//! own calls (accounts, bans, settings, statistics).

#[path = "../../ttng-services/tests/common/mod.rs"]
mod ng;
#[path = "../../ttng-core/tests/common/mod.rs"]
mod tt;

use std::time::{Duration, Instant};

use ttng_ffi::*;

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
fn the_monitor_administers_the_server() {
    let Some(ngmon) = ng::Ngmon::start() else { return };
    let server = tt::Server::start();
    let mon = MonitorClient::new(ngmon.url.clone(), None);
    mon.register("Test iPhone".into()).expect("registered");
    let id = mon
        .add_server(MonitorServerInput {
            name: "Test".into(),
            host: "127.0.0.1".into(),
            tcp_port: server.port,
            encrypted: false,
            nickname: "Admin (monitor)".into(),
            username: "admin".into(),
            password: "admin-pw".into(),
            status_msg: String::new(),
            status_mode: 0,
            channel: String::new(),
            channel_password: String::new(),
            enabled: true,
        })
        .expect("added");
    until("the monitor logging in", || {
        mon.servers()
            .unwrap()
            .into_iter()
            .find(|s| s.id == id && s.status == "logged_in")
    });

    let view = mon.view(id).unwrap();
    assert_eq!(view.my_user_type, 2, "the monitor is the admin");

    // Accounts: listed, one added with its rights, changed, deleted.
    let accounts = mon.admin_accounts(id).expect("accounts");
    assert!(accounts.iter().any(|a| a.username == "alice" && !a.admin));
    assert!(accounts.iter().any(|a| a.username == "admin" && a.admin));
    let dave = UserAccount {
        username: "dave".into(),
        password: "dave-pw".into(),
        rights: vec![
            UserRight::MultiLogin,
            UserRight::TransmitVoice,
            UserRight::TextMessageChannel,
        ],
        note: "From the Monitor".into(),
        initial_channel: "/".into(),
        commands_limit: 10,
        commands_interval_ms: 1000,
        ..Default::default()
    };
    mon.admin_save_account(id, dave.clone()).expect("added dave");
    let got = mon
        .admin_accounts(id)
        .unwrap()
        .into_iter()
        .find(|a| a.username == "dave")
        .expect("dave listed");
    assert_eq!(got.note, "From the Monitor");
    assert_eq!(got.password, "dave-pw");
    assert_eq!(got.initial_channel, "/");
    assert_eq!((got.commands_limit, got.commands_interval_ms), (10, 1000));
    let mut rights = got.rights.clone();
    rights.sort_by_key(|r| format!("{r:?}"));
    let mut want = dave.rights.clone();
    want.sort_by_key(|r| format!("{r:?}"));
    assert_eq!(rights, want);
    mon.admin_save_account(
        id,
        UserAccount {
            note: "Changed".into(),
            ..dave.clone()
        },
    )
    .expect("changed dave");
    let got = mon
        .admin_accounts(id)
        .unwrap()
        .into_iter()
        .find(|a| a.username == "dave")
        .unwrap();
    assert_eq!(got.note, "Changed");
    mon.admin_delete_account(id, "dave".into()).expect("deleted");
    assert!(!mon.admin_accounts(id).unwrap().iter().any(|a| a.username == "dave"));

    // Bans by hand: an address and a username, then removed.
    mon.admin_ban(id, "10.1.2.3".into(), String::new(), String::new())
        .expect("ip ban");
    mon.admin_ban(id, String::new(), "mallory".into(), String::new())
        .expect("username ban");
    let bans = mon.admin_bans(id).expect("bans");
    let ip = bans
        .iter()
        .find(|b| b.ip_address == "10.1.2.3")
        .expect("ip ban listed")
        .clone();
    assert!(ip.by_ip_address && !ip.by_username);
    assert_eq!(ip.owner, "admin");
    assert!(
        ip.time.parse::<i64>().unwrap() > 1_700_000_000,
        "Unix seconds: {:?}",
        ip.time
    );
    let user = bans
        .iter()
        .find(|b| b.username == "mallory")
        .expect("username ban listed")
        .clone();
    assert!(user.by_username && !user.by_ip_address, "a username ban: {user:?}");
    mon.admin_unban(id, ip).expect("unbanned ip");
    mon.admin_unban(id, user).expect("unbanned username");
    assert!(mon.admin_bans(id).unwrap().is_empty(), "both bans gone");

    // Server settings: as the server has them; changed.
    let s = mon.admin_server_settings(id).expect("settings");
    assert_eq!(s.name, "TTNG Test");
    assert!(s.max_users > 0);
    mon.admin_update_server(
        id,
        ServerSettings {
            name: "Renamed".into(),
            ..s.clone()
        },
    )
    .expect("updated");
    let s = until("the new name", || {
        mon.admin_server_settings(id).ok().filter(|s| s.name == "Renamed")
    });
    assert!(s.max_users > 0, "the rest stayed");

    let st = mon.admin_statistics(id).expect("statistics");
    assert!(st.uptime_ms > 0, "{st:?}");
    assert!(st.users_served >= 1);
    mon.admin_save_config(id).expect("saved");
}
