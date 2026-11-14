//! NG Account against a private copy of the real service (ngmon), on a
//! free local port with its own data, mail written to an outbox folder.

mod common;

use common::*;
use serde_json::json;
use ttng_services::*;

#[test]
fn accounts_sign_up_in_and_out() {
    let Some(ng) = Ngmon::start() else { return };
    let (mut a, s) = signed_up(&ng, "alice@example.com", "install-a");
    assert_eq!(s.account.email, "alice@example.com");
    assert!(!s.token.is_empty());
    assert_eq!(a.account().unwrap().account.email, "alice@example.com");

    // A second install signs in; a wrong password says so.
    let mut b = NgAccount::new(&ng.url, "install-b", "Test iPad");
    let wrong = b.sign_in("alice@example.com", "nope").unwrap_err();
    assert!(matches!(&wrong, ServiceError::Refused { status: 401, .. }), "{wrong:?}");
    assert!(!wrong.to_string().is_empty());
    b.sign_in("alice@example.com", PW).expect("signed in");

    // Signed out: the old token stops working.
    let token = s.token.clone();
    a.sign_out().unwrap();
    let stale = NgAccount::new(&ng.url, "install-a", "Test iPhone").with_token(&token);
    assert!(matches!(stale.account(), Err(ServiceError::SignedOut(_))));
}

#[test]
fn servers_sync_between_devices_with_conflicts() {
    let Some(ng) = Ngmon::start() else { return };
    let (a, _) = signed_up(&ng, "bob@example.com", "install-a");
    let mut b = NgAccount::new(&ng.url, "install-b", "Test iPad");
    b.sign_in("bob@example.com", PW).unwrap();

    let home = SyncedServer {
        name: "Home".into(),
        host: "tt.example.com".into(),
        tcp_port: 10333,
        udp_port: 10333,
        username: "bob".into(),
        password: "secret".into(),
        sync_password: true,
        ..Default::default()
    };
    let applied = a
        .push(&[SyncChange {
            kind: "server".into(),
            key: "home-1".into(),
            base_rev: 0,
            deleted: false,
            data: Some(home.to_json()),
        }])
        .unwrap();
    assert_eq!(applied.applied.len(), 1);
    assert!(applied.conflicts.is_empty());
    let rev = applied.applied[0].rev;

    // The other device gets it, password included.
    let pulled = b.pull(0).unwrap();
    let rec = pulled.records.iter().find(|r| r.key == "home-1").expect("the server");
    assert_eq!(SyncedServer::from_json(rec.data.as_ref().unwrap()), home);
    assert!(b.pull(pulled.rev).unwrap().records.is_empty(), "nothing new since");

    // Both change it from the same revision: the second gets a conflict.
    let change = |name: &str| SyncChange {
        kind: "server".into(),
        key: "home-1".into(),
        base_rev: rev,
        deleted: false,
        data: Some(json!(
            SyncedServer {
                name: name.into(),
                ..home.clone()
            }
            .to_json()
        )),
    };
    assert!(a.push(&[change("Home (phone)")]).unwrap().conflicts.is_empty());
    let second = b.push(&[change("Home (iPad)")]).unwrap();
    assert_eq!(second.conflicts.len(), 1);
    assert_eq!(
        SyncedServer::from_json(second.conflicts[0].data.as_ref().unwrap()).name,
        "Home (phone)"
    );
}
