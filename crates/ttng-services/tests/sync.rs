//! Syncing saved servers between devices through NG Account.

mod common;

use common::*;
use ttng_services::*;

fn server(name: &str, host: &str, user: &str) -> SyncedServer {
    SyncedServer {
        name: name.into(),
        host: host.into(),
        tcp_port: 10333,
        udp_port: 10333,
        username: user.into(),
        password: format!("{user}-pw"),
        sync_password: true,
        ..Default::default()
    }
}

fn local(key: &str, s: SyncedServer) -> LocalServer {
    LocalServer {
        key: key.into(),
        server: s,
    }
}

fn names(o: &SyncOutcome) -> Vec<&str> {
    o.servers.iter().map(|l| l.server.name.as_str()).collect()
}

#[test]
fn two_devices_end_up_with_the_same_servers() {
    let Some(ng) = Ngmon::start() else { return };
    let (phone, _) = signed_up(&ng, "sync@example.com", "phone");
    let ipad = signed_in(&ng, "sync@example.com", "ipad");
    let (mut sp, mut si) = (SyncState::default(), SyncState::default());

    // The phone has two; the iPad has one of them (added by hand) and another.
    let p = sync(
        &phone,
        &mut sp,
        vec![
            local("a", server("Home", "home.example.com", "me")),
            local("b", server("Work", "work.example.com", "me")),
        ],
    )
    .unwrap();
    assert!(!p.changed);
    let i = sync(
        &ipad,
        &mut si,
        vec![
            local("x", server("My home", "HOME.example.com", "me")),
            local("y", server("Club", "club.example.com", "me")),
        ],
    )
    .unwrap();
    // The iPad's copy of Home became the account's (no duplicate), Work
    // arrived, Club stays.
    assert_eq!(i.rekeyed, vec![("x".to_owned(), "a".to_owned())]);
    let mut got = names(&i);
    got.sort();
    assert_eq!(got, ["Club", "Home", "Work"]);
    assert_eq!(
        i.servers.iter().find(|l| l.key == "b").unwrap().server.password,
        "me-pw"
    );

    // The phone gets Club; both have the same list in the same order now.
    let p = sync(&phone, &mut sp, p.servers).unwrap();
    assert!(p.changed);
    let i = sync(&ipad, &mut si, i.servers).unwrap();
    assert_eq!(names(&p), names(&i));
    assert_eq!(p.servers.len(), 3);

    // Nothing more to do: no changes either way.
    let p2 = sync(&phone, &mut sp, p.servers.clone()).unwrap();
    assert!(!p2.changed);
    assert_eq!(phone.pull(sp.last_rev).unwrap().records.len(), 0);

    // A removal and a reorder on the phone reach the iPad.
    let mut list = p.servers.clone();
    list.retain(|l| l.server.name != "Work");
    list.reverse();
    let order: Vec<String> = list.iter().map(|l| l.server.name.clone()).collect();
    sp.deleted("b");
    sync(&phone, &mut sp, list).unwrap();
    let i = sync(&ipad, &mut si, i.servers).unwrap();
    assert_eq!(names(&i), order.iter().map(String::as_str).collect::<Vec<_>>());
}

#[test]
fn the_account_wins_a_conflict_and_unsynced_passwords_stay_home() {
    let Some(ng) = Ngmon::start() else { return };
    let (phone, _) = signed_up(&ng, "conflict@example.com", "phone");
    let ipad = signed_in(&ng, "conflict@example.com", "ipad");
    let (mut sp, mut si) = (SyncState::default(), SyncState::default());
    let private = SyncedServer {
        sync_password: false,
        password: "only-on-the-phone".into(),
        ..server("Private", "private.example.com", "me")
    };
    let p = sync(
        &phone,
        &mut sp,
        vec![
            local("a", server("Home", "home.example.com", "me")),
            local("p", private),
        ],
    )
    .unwrap();
    let i = sync(&ipad, &mut si, vec![]).unwrap();
    let on_ipad = &i.servers.iter().find(|l| l.key == "p").unwrap().server;
    assert_eq!(on_ipad.password, "", "the password didn't leave the phone");

    // The iPad sets its own password for it; the phone's stays.
    let mut list = i.servers.clone();
    list.iter_mut().find(|l| l.key == "p").unwrap().server.password = "ipad-pw".into();
    let i = sync(&ipad, &mut si, list).unwrap();
    let p = sync(&phone, &mut sp, p.servers).unwrap();
    assert_eq!(
        p.servers.iter().find(|l| l.key == "p").unwrap().server.password,
        "only-on-the-phone"
    );
    assert_eq!(
        i.servers.iter().find(|l| l.key == "p").unwrap().server.password,
        "ipad-pw"
    );

    // Both rename Home before syncing: the phone's arrives first and wins.
    let rename = |list: &[LocalServer], name: &str| -> Vec<LocalServer> {
        list.iter()
            .map(|l| {
                if l.key == "a" {
                    local(
                        "a",
                        SyncedServer {
                            name: name.into(),
                            ..l.server.clone()
                        },
                    )
                } else {
                    l.clone()
                }
            })
            .collect()
    };
    sync(&phone, &mut sp, rename(&p.servers, "Home (phone)")).unwrap();
    let i = sync(&ipad, &mut si, rename(&i.servers, "Home (iPad)")).unwrap();
    assert_eq!(
        i.servers.iter().find(|l| l.key == "a").unwrap().server.name,
        "Home (phone)"
    );
    let p = sync(&phone, &mut sp, vec![]).unwrap_or_else(|e| panic!("{e}"));
    // (An empty list on the phone isn't a delete: only `deleted` removes.)
    assert!(p.servers.iter().any(|l| l.key == "a"));
}

#[test]
fn settings_sync_between_devices_and_others_are_left_alone() {
    use serde_json::{Value, json};
    let Some(ng) = Ngmon::start() else { return };
    let (phone, _) = signed_up(&ng, "settings@example.com", "phone");
    let ipad = signed_in(&ng, "settings@example.com", "ipad");
    let (mut sp, mut si) = (SyncState::default(), SyncState::default());
    let keys = |packs: Option<Value>, chosen: Option<Value>| {
        vec![("packs".to_string(), packs), ("chosen".to_string(), chosen)]
    };

    // An old app's setting the new one doesn't sync.
    phone
        .push(&[SyncChange {
            kind: "setting".into(),
            key: "other".into(),
            base_rev: 0,
            deleted: false,
            data: Some(json!(1)),
        }])
        .unwrap();
    let p = sync_with_settings(
        &phone,
        &mut sp,
        vec![],
        keys(Some(json!(["rain"])), Some(json!("catalog:rain"))),
    )
    .unwrap();
    assert!(p.settings.is_empty(), "nothing came from the account");

    // The iPad gets them (and not "other").
    let i = sync_with_settings(&ipad, &mut si, vec![], keys(None, None)).unwrap();
    assert_eq!(i.settings.len(), 2);
    assert!(i.settings.contains(&("packs".into(), Some(json!(["rain"])))));
    assert!(i.settings.contains(&("chosen".into(), Some(json!("catalog:rain")))));

    // In step: nothing either way.
    let i = sync_with_settings(
        &ipad,
        &mut si,
        vec![],
        keys(Some(json!(["rain"])), Some(json!("catalog:rain"))),
    )
    .unwrap();
    assert!(i.settings.is_empty());

    // The iPad changes the choice and removes the list; the phone follows.
    sync_with_settings(&ipad, &mut si, vec![], keys(None, Some(json!("default")))).unwrap();
    let p = sync_with_settings(
        &phone,
        &mut sp,
        vec![],
        keys(Some(json!(["rain"])), Some(json!("catalog:rain"))),
    )
    .unwrap();
    assert!(p.settings.contains(&("chosen".into(), Some(json!("default")))));
    assert!(p.settings.contains(&("packs".into(), None)));

    // Both change it before syncing: the first to arrive wins.
    sync_with_settings(
        &phone,
        &mut sp,
        vec![],
        keys(Some(json!(["a"])), Some(json!("catalog:a"))),
    )
    .unwrap();
    let i = sync_with_settings(
        &ipad,
        &mut si,
        vec![],
        keys(Some(json!(["b"])), Some(json!("catalog:b"))),
    )
    .unwrap();
    assert!(i.settings.contains(&("chosen".into(), Some(json!("catalog:a")))));
    let p = sync_with_settings(
        &phone,
        &mut sp,
        vec![],
        keys(Some(json!(["a"])), Some(json!("catalog:a"))),
    )
    .unwrap();
    assert!(p.settings.is_empty());

    // The old app's setting is still in the account.
    let all = phone.pull(0).unwrap();
    assert!(all.records.iter().any(|r| r.kind == "setting" && r.key == "other"));
}

/// A device that first synced an empty account asks for everything again
/// (from revision 0), where the service leaves deleted records out: what
/// it synced before and isn't listed was deleted elsewhere.
#[test]
fn a_deletion_reaches_a_device_that_started_on_an_empty_account() {
    let Some(ng) = Ngmon::start() else { return };
    let (phone, _) = signed_up(&ng, "deleted@example.com", "phone");
    let ipad = signed_in(&ng, "deleted@example.com", "ipad");
    let (mut sp, mut si) = (SyncState::default(), SyncState::default());
    let p = sync(
        &phone,
        &mut sp,
        vec![
            local("a", server("Home", "home.example.com", "me")),
            local("b", server("Work", "work.example.com", "me")),
        ],
    )
    .unwrap();
    assert_eq!(sp.last_rev, 0, "it pulled before anything was there");
    let i = sync(&ipad, &mut si, vec![]).unwrap();
    si.deleted("b");
    sync(&ipad, &mut si, i.servers.into_iter().filter(|l| l.key != "b").collect()).unwrap();
    let p = sync(&phone, &mut sp, p.servers).unwrap();
    assert!(p.changed);
    assert_eq!(names(&p), ["Home"], "Work is gone on the phone too");
    // And it isn't sent back.
    let i = sync(
        &ipad,
        &mut si,
        vec![local("a", server("Home", "home.example.com", "me"))],
    )
    .unwrap();
    assert_eq!(names(&i), ["Home"]);
}

/// A device's own last push comes back in its next pull: it isn't applied
/// over a newer choice made since (the chosen pack sprang back to the old
/// one and never reached the account), and the newer choice is sent.
#[test]
fn a_settings_own_echo_does_not_undo_a_newer_choice() {
    use serde_json::json;
    let Some(ng) = Ngmon::start() else { return };
    let (phone, _) = signed_up(&ng, "echo@example.com", "phone");
    let ipad = signed_in(&ng, "echo@example.com", "ipad");
    let mut sp = SyncState::default();
    let keys = |chosen: &str| vec![("chosen".to_string(), Some(json!(chosen)))];

    let p = sync_with_settings(&phone, &mut sp, vec![], keys("default")).unwrap();
    assert!(p.settings.is_empty());
    // Chosen anew here: nothing comes back to undo it, and it's sent.
    let p = sync_with_settings(&phone, &mut sp, vec![], keys("local:own-1")).unwrap();
    assert!(
        p.settings.is_empty(),
        "its own earlier push isn't applied over the new choice: {:?}",
        p.settings
    );
    let mut si = SyncState::default();
    let i = sync_with_settings(&ipad, &mut si, vec![], vec![("chosen".to_string(), None)]).unwrap();
    assert!(
        i.settings.contains(&("chosen".into(), Some(json!("local:own-1")))),
        "the account has it: {:?}",
        i.settings
    );
    // And a change made on the iPad still reaches the phone.
    sync_with_settings(&ipad, &mut si, vec![], keys("catalog:rain")).unwrap();
    let p = sync_with_settings(&phone, &mut sp, vec![], keys("local:own-1")).unwrap();
    assert!(
        p.settings.contains(&("chosen".into(), Some(json!("catalog:rain")))),
        "{:?}",
        p.settings
    );
}
