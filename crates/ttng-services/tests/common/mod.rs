#![allow(dead_code)]
//! A private copy of the real service (ngmon) on a free local port with its
//! own data, mail written to an outbox folder. Needs the ngmon binary:
//! NGMON_BIN, or ~/ngmon/bin/ngmon; tests skip without it.

use std::net::TcpListener;
use std::path::PathBuf;
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant};

use ttng_services::*;

pub struct Ngmon {
    pub url: String,
    dir: PathBuf,
    child: Child,
}

impl Ngmon {
    pub fn start() -> Option<Ngmon> {
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
    pub fn code(&self, email: &str) -> String {
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

pub const PW: &str = "correct horse battery";

pub fn signed_up(ng: &Ngmon, email: &str, install: &str) -> (NgAccount, Session) {
    let mut a = NgAccount::new(&ng.url, install, "Test iPhone");
    a.sign_up(email, PW).expect("sign-up accepted");
    let s = a.verify(email, &ng.code(email)).expect("verified");
    (a, s)
}

pub fn signed_in(ng: &Ngmon, email: &str, install: &str) -> NgAccount {
    let mut a = NgAccount::new(&ng.url, install, "Test iPad");
    a.sign_in(email, PW).expect("signed in");
    a
}
