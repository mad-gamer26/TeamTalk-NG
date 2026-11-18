//! NG Account end to end, through the calls the app makes (the FFI), on a
//! private copy of the real service (ngmon, mail to an outbox): an iPhone
//! and an iPad on one account — signing up and in, servers and their
//! passwords, sound pack settings, the Monitor through the account, the
//! password changed and reset, signing out.

#[path = "../../ttng-services/tests/common/mod.rs"]
mod ng;

use ttng_ffi::*;

fn server(name: &str, host: &str, password: &str, sync_password: bool) -> SyncedServer {
    SyncedServer {
        name: name.into(),
        host: host.into(),
        tcp_port: 10333,
        udp_port: 10333,
        username: "me".into(),
        password: password.into(),
        nickname: "Matt".into(),
        sync_password,
        ..Default::default()
    }
}

fn local(key: &str, s: SyncedServer) -> LocalServer {
    LocalServer {
        key: key.into(),
        server: s,
    }
}

fn setting(key: &str, json: Option<&str>) -> SyncSetting {
    SyncSetting {
        key: key.into(),
        json: json.map(Into::into),
    }
}

fn refused(r: Result<impl std::fmt::Debug, NgError>) -> bool {
    matches!(r, Err(NgError::Refused { .. }))
}

const PACKS: &str = "ng_installed_catalog_packs";
const CHOSEN: &str = "ng_selected_sound_pack";

#[test]
fn an_iphone_and_an_ipad_share_one_ng_account() {
    let Some(svc) = ng::Ngmon::start() else { return };
    let email = "matt@example.com";
    let phone = NgAccountClient::new(svc.url.clone(), "install-phone".into(), "iPhone".into(), None);
    let ipad = NgAccountClient::new(svc.url.clone(), "install-ipad".into(), "iPad".into(), None);

    // Signing up: a code by email; a wrong one is refused.
    phone
        .sign_up(email.into(), "correct horse battery".into())
        .expect("signed up");
    assert!(
        refused(phone.verify(email.into(), "000000".into())),
        "a wrong code is refused"
    );
    let code = svc.code(email);
    let s = phone.verify(email.into(), code).expect("verified");
    assert_eq!(s.email, email);
    assert!(phone.signed_in());
    assert_eq!(s.push_key.len(), 44, "a 32-byte push key in base64");
    assert_eq!(phone.account().unwrap().email, email);

    // The iPad signs in (a wrong password is refused).
    assert!(refused(ipad.sign_in(email.into(), "wrong".into())));
    let si = ipad
        .sign_in(email.into(), "correct horse battery".into())
        .expect("iPad signed in");
    assert_ne!(si.session_id, s.session_id, "a session per device");

    // The iPhone's servers and sound packs go to the account; one keeps
    // its password at home.
    let p = ng_sync(
        phone.clone(),
        String::new(),
        vec![
            local("home", server("Home", "home.example.com", "home-pw", true)),
            local("work", server("Work", "work.example.com", "work-pw", false)),
        ],
        vec![
            setting(PACKS, Some(r#"["rain"]"#)),
            setting(CHOSEN, Some(r#""catalog:rain""#)),
        ],
    )
    .expect("iPhone synced");
    assert!(!p.changed && p.settings.is_empty(), "nothing came from the account yet");

    // The iPad gets them all.
    let i = ng_sync(
        ipad.clone(),
        String::new(),
        vec![],
        vec![setting(PACKS, None), setting(CHOSEN, None)],
    )
    .expect("iPad synced");
    assert!(i.changed);
    let names: Vec<&str> = i.servers.iter().map(|l| l.server.name.as_str()).collect();
    assert_eq!(names, ["Home", "Work"], "in the iPhone's order");
    let get = |o: &SyncOutcome, k: &str| o.servers.iter().find(|l| l.key == k).unwrap().server.clone();
    assert_eq!(get(&i, "home").password, "home-pw", "a synced password arrives");
    assert_eq!(get(&i, "work").password, "", "an unsynced one doesn't");
    assert_eq!(get(&i, "home").nickname, "Matt");
    assert!(i.settings.contains(&setting(PACKS, Some(r#"["rain"]"#))));
    assert!(i.settings.contains(&setting(CHOSEN, Some(r#""catalog:rain""#))));

    // The iPad renames Home, removes Work, adds Club, chooses no pack.
    let mut list: Vec<LocalServer> = i.servers.iter().filter(|l| l.key != "work").cloned().collect();
    list[0].server.name = "Home (renamed)".into();
    list.push(local("club", server("Club", "club.example.com", "club-pw", true)));
    let ist = ng_sync_deleted(i.state_json.clone(), "work".into());
    let i = ng_sync(
        ipad.clone(),
        ist,
        list,
        vec![
            setting(PACKS, Some(r#"["rain"]"#)),
            setting(CHOSEN, Some(r#""default""#)),
        ],
    )
    .expect("iPad's changes sent");

    // The iPhone follows; its Work password never left it.
    let p = ng_sync(
        phone.clone(),
        p.state_json,
        p.servers,
        vec![
            setting(PACKS, Some(r#"["rain"]"#)),
            setting(CHOSEN, Some(r#""catalog:rain""#)),
        ],
    )
    .expect("iPhone synced again");
    assert!(p.changed);
    let names: Vec<&str> = p.servers.iter().map(|l| l.server.name.as_str()).collect();
    assert_eq!(names, ["Home (renamed)", "Club"]);
    assert_eq!(get(&p, "club").password, "club-pw");
    assert_eq!(
        p.settings,
        vec![setting(CHOSEN, Some(r#""default""#))],
        "only the choice changed"
    );

    // In step: nothing either way.
    let again = ng_sync(
        phone.clone(),
        p.state_json.clone(),
        p.servers.clone(),
        vec![
            setting(PACKS, Some(r#"["rain"]"#)),
            setting(CHOSEN, Some(r#""default""#)),
        ],
    )
    .unwrap();
    assert!(!again.changed && again.settings.is_empty());
    let _ = i;

    // The Monitor through the account: a server the iPhone adds is the
    // iPad's too.
    let mp = MonitorClient::new(svc.url.clone(), Some(s.token.clone()));
    let mi = MonitorClient::new(svc.url.clone(), Some(si.token.clone()));
    let id = mp
        .add_server(MonitorServerInput {
            name: "Watched".into(),
            host: "127.0.0.1".into(),
            tcp_port: 9,
            encrypted: false,
            nickname: "Monitor".into(),
            username: String::new(),
            password: String::new(),
            status_msg: String::new(),
            status_mode: 0,
            channel: String::new(),
            channel_password: String::new(),
            enabled: false,
        })
        .expect("monitored");
    assert!(
        mi.servers().unwrap().iter().any(|m| m.id == id && m.name == "Watched"),
        "the iPad sees it"
    );
    mi.remove_server(id).expect("the iPad stops it");
    assert!(mp.servers().unwrap().is_empty(), "gone for the iPhone too");

    // A new password: the old one no longer signs in, and the other
    // devices are signed out (the one that changed it stays in).
    phone
        .change_password("correct horse battery".into(), "a new password here".into())
        .expect("changed");
    assert!(
        refused(phone.change_password("wrong".into(), "whatever 123456".into())),
        "a wrong current password is refused, not signed out"
    );
    assert!(phone.account().is_ok(), "the iPhone stays signed in");
    assert!(
        matches!(ipad.account(), Err(NgError::SignedOut { .. })),
        "the iPad is signed out"
    );
    let mac = NgAccountClient::new(svc.url.clone(), "install-mac".into(), "Mac".into(), None);
    assert!(
        refused(mac.sign_in(email.into(), "correct horse battery".into())),
        "the old password is refused"
    );
    mac.sign_in(email.into(), "a new password here".into())
        .expect("the new one works");

    // Forgotten on the iPad: a code by email, a new password, signed in;
    // every other device is signed out.
    ipad.forgot_password(email.into()).expect("code sent");
    let code = svc.code(email);
    ipad.reset_password(email.into(), code, "reset password 123".into())
        .expect("reset");
    assert!(ipad.account().is_ok(), "the iPad is signed in again");
    assert!(
        matches!(phone.account(), Err(NgError::SignedOut { .. })),
        "the iPhone is signed out"
    );
    assert!(matches!(mac.account(), Err(NgError::SignedOut { .. })), "so is the Mac");
    let tv = NgAccountClient::new(svc.url.clone(), "install-tv".into(), "Apple TV".into(), None);
    assert!(
        refused(tv.sign_in(email.into(), "a new password here".into())),
        "the password before the reset is refused"
    );
    tv.sign_in(email.into(), "reset password 123".into())
        .expect("the reset one works");

    // The iPad's servers are still the account's after all that.
    let i = ng_sync(ipad.clone(), String::new(), vec![], vec![]).expect("synced after the reset");
    let names: Vec<&str> = i.servers.iter().map(|l| l.server.name.as_str()).collect();
    assert_eq!(names, ["Home (renamed)", "Club"]);

    // Signing out ends that session only.
    tv.sign_out().expect("signed out");
    assert!(!tv.signed_in());
    assert!(ipad.account().is_ok(), "the iPad's session goes on");
}
