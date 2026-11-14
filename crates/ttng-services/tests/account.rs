//! NG Account against a private copy of the real service (ngmon), on a
//! free local port with its own data, mail written to an outbox folder.
//! Needs the ngmon binary: NGMON_BIN, or ~/ngmon/bin/ngmon; skipped
//! without it.

use std::net::TcpListener;
use std::path::PathBuf;
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant};

use serde_json::json;
use ttng_services::*;

struct Ngmon {
    url: String,
    dir: PathBuf,
    child: Child,
}

impl Ngmon {
    fn start() -> Option<Ngmon> {
        let bin = std::env::var_os("NGMON_BIN")
            .map(PathBuf::from)
            .or_else(|| std::env::var_os("HOME").map(|h| PathBuf::from(h).join("ngmon/bin/ngmon")))?;
        if !bin.exists() {
            eprintln!("skipped: no ngmon at {}", bin.display());
            return None;
        }
        let port = TcpListener::bind("127.0.0.1:0").unwrap().local_addr().unwrap().port();
        let dir = std::env::temp_dir().join(format!("ttng-ngmon-{}-{port}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(
            dir.join("ngmon.toml"),
            format!(
                "listen = \"127.0.0.1:{port}\"\ndata_dir = \"data\"\npacks_dir = \"packs\"\nsecret_key_file = \"secret.key\"\n\
                 [push]\nmode = \"none\"\n[mail]\nmode = \"outbox\"\noutbox = \"outbox\"\n"
            ),
        )
        .unwrap();
        let child = Command::new(bin)
            .arg("--config")
            .arg(dir.join("ngmon.toml"))
            .arg("serve")
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .expect("ngmon starts");
        let end = Instant::now() + Duration::from_secs(10);
        while std::net::TcpStream::connect(("127.0.0.1", port)).is_err() {
            assert!(Instant::now() < end, "ngmon didn't start listening");
            std::thread::sleep(Duration::from_millis(50));
        }
        Some(Ngmon {
            url: format!("http://127.0.0.1:{port}"),
            dir,
            child,
        })
    }

    /// The last code mailed to `email`.
    fn code(&self, email: &str) -> String {
        let end = Instant::now() + Duration::from_secs(5);
        loop {
            let mut found: Vec<(String, String)> = std::fs::read_dir(self.dir.join("outbox"))
                .into_iter()
                .flatten()
                .flatten()
                .filter_map(|e| {
                    let v: serde_json::Value = serde_json::from_slice(&std::fs::read(e.path()).ok()?).ok()?;
                    if v["to"] != email {
                        return None;
                    }
                    Some((
                        e.file_name().to_string_lossy().into_owned(),
                        v["code"].as_str()?.to_owned(),
                    ))
                })
                .collect();
            found.sort();
            if let Some((_, c)) = found.pop() {
                return c;
            }
            assert!(Instant::now() < end, "no code mailed to {email}");
            std::thread::sleep(Duration::from_millis(50));
        }
    }
}

impl Drop for Ngmon {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
        let _ = std::fs::remove_dir_all(&self.dir);
    }
}

const PW: &str = "correct horse battery";

fn signed_up(ng: &Ngmon, email: &str, install: &str) -> (NgAccount, Session) {
    let mut a = NgAccount::new(&ng.url, install, "Test iPhone");
    a.sign_up(email, PW).expect("sign-up accepted");
    let s = a.verify(email, &ng.code(email)).expect("verified");
    (a, s)
}

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
