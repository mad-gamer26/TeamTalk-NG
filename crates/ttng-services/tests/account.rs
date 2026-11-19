//! NG Account against a private copy of the real service (ngmon), on a
//! free local port with its own data, mail written to an outbox folder.

mod common;

use common::*;
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
