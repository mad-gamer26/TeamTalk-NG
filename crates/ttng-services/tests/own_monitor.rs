//! Your own Monitor end to end, through the app's own client: the NG
//! service (its relay) and `ng-monitor` from ~/ng-service, run privately on
//! local ports, a private TeamTalk server, pairing with the code the Monitor
//! shows, and everything that must fail (wrong codes, an unpaired phone, an
//! impostor, the Monitor stopped). NG_SERVICE_BIN and NG_MONITOR_BIN choose
//! the builds (default ~/ng-service/target/debug/…); skipped without them.

#[path = "../../ttng-core/tests/common/mod.rs"]
mod tt;

use std::io::{BufRead, BufReader};
use std::net::TcpListener;
use std::path::PathBuf;
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant};

use ttng_services::*;

fn bin(var: &str, name: &str) -> Option<PathBuf> {
    let p = std::env::var_os(var)
        .map(PathBuf::from)
        .or_else(|| std::env::var_os("HOME").map(|h| PathBuf::from(h).join("ng-service/target/debug").join(name)))?;
    if p.exists() {
        Some(p)
    } else {
        eprintln!("skipped: no {name} at {}", p.display());
        None
    }
}

fn free_port() -> u16 {
    TcpListener::bind("127.0.0.1:0").unwrap().local_addr().unwrap().port()
}

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

/// A child process killed when dropped.
struct Proc(Child);

impl Drop for Proc {
    fn drop(&mut self) {
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}

/// The NG service (the relay) and a set-up home Monitor.
struct World {
    relay: String,
    _service: Proc,
    monitor_bin: PathBuf,
    home: PathBuf,
    monitor: Option<Proc>,
}

impl World {
    fn start() -> Option<World> {
        let service_bin = bin("NG_SERVICE_BIN", "ng-service")?;
        let monitor_bin = bin("NG_MONITOR_BIN", "ng-monitor")?;
        let port = free_port();
        let dir = std::env::temp_dir().join(format!("ttng-own-{}-{port}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(
            dir.join("ngmon.toml"),
            format!(
                "listen = \"127.0.0.1:{port}\"\nclient_name = \"Own Monitor test\"\ndata_dir = \"data\"\npacks_dir = \"packs\"\n\
                 secret_key_file = \"secret.key\"\n[push]\nmode = \"none\"\n[mail]\nmode = \"none\"\n"
            ),
        )
        .unwrap();
        let service = Proc(
            Command::new(service_bin)
                .arg("--config")
                .arg(dir.join("ngmon.toml"))
                .arg("serve")
                .current_dir(&dir)
                .stdout(Stdio::null())
                .stderr(Stdio::null())
                .spawn()
                .expect("the service starts"),
        );
        let end = Instant::now() + Duration::from_secs(10);
        while std::net::TcpStream::connect(("127.0.0.1", port)).is_err() {
            assert!(Instant::now() < end, "the service didn't start listening");
            std::thread::sleep(Duration::from_millis(50));
        }
        let relay = format!("http://127.0.0.1:{port}");
        let home = dir.join("monitor");
        let mut w = World {
            relay,
            _service: service,
            monitor_bin,
            home,
            monitor: None,
        };
        let out = w
            .cli(&[
                "setup",
                "--relay",
                &w.relay.clone(),
                "--name",
                "Home PC",
                "--no-service",
                "--no-pair",
            ])
            .output()
            .unwrap();
        assert!(out.status.success(), "setup: {}", String::from_utf8_lossy(&out.stderr));
        w.start_monitor();
        Some(w)
    }

    fn cli(&self, args: &[&str]) -> Command {
        let mut c = Command::new(&self.monitor_bin);
        c.args(args).env("NG_MONITOR_HOME", &self.home);
        c
    }

    fn start_monitor(&mut self) {
        self.monitor = Some(Proc(
            self.cli(&["run"])
                .stdout(Stdio::null())
                .stderr(Stdio::null())
                .spawn()
                .unwrap(),
        ));
        until("the Monitor connected", || {
            let out = self.cli(&["status"]).output().unwrap();
            String::from_utf8_lossy(&out.stdout)
                .contains("connected to the relay;")
                .then_some(())
        });
    }

    fn stop_monitor(&mut self) {
        self.monitor = None;
    }

    /// `ng-monitor pair`: the code it shows, and the command still waiting.
    fn code(&self) -> (String, Proc) {
        let mut child = Proc(
            self.cli(&["pair"])
                .stdout(Stdio::piped())
                .stderr(Stdio::null())
                .spawn()
                .unwrap(),
        );
        let out = child.0.stdout.take().unwrap();
        for line in BufReader::new(out).lines() {
            let line = line.unwrap();
            let t = line.trim();
            if t.len() == 14 && t.as_bytes()[4] == b'-' && t.as_bytes()[9] == b'-' {
                return (t.to_owned(), child);
            }
        }
        panic!("ng-monitor pair showed no code");
    }

    fn phones(&self) -> String {
        String::from_utf8_lossy(&self.cli(&["phones"]).output().unwrap().stdout).into_owned()
    }
}

fn message(e: ServiceError) -> String {
    e.to_string()
}

#[test]
fn pairing_then_monitoring_through_the_relay() {
    let Some(w) = World::start() else { return };
    let server = tt::Server::start();
    let key = new_phone_key();
    let (code, _waiting) = w.code();

    // Lower case and spaces are fine (people type codes).
    let typed = code.to_lowercase().replace('-', " ");
    let paired = pair_own_monitor(&w.relay, &typed, "Test iPhone", &key).expect("paired");
    assert_eq!(paired.name, "Home PC");
    assert!(w.phones().contains("1. Test iPhone"), "{}", w.phones());

    let mon = Monitor::own(&w.relay, paired.clone(), &key);
    let hello = mon.hello().expect("hello");
    assert_eq!(hello["name"], "Home PC");
    assert_eq!(hello["push_key"].as_str().map(str::len), Some(44), "{hello}");
    assert!(mon.servers().unwrap().is_empty());

    // A server on this computer (a home Monitor may watch local ones).
    let id = mon
        .add_server(&MonitorServerInput {
            name: "Local".into(),
            host: "127.0.0.1".into(),
            tcp_port: server.port,
            nickname: "Alice (monitor)".into(),
            username: "alice".into(),
            password: "alice-pw".into(),
            enabled: true,
            ..Default::default()
        })
        .expect("added");
    until("the home Monitor logging in", || {
        mon.servers()
            .unwrap()
            .into_iter()
            .find(|s| s.id == id && s.status == "logged_in")
    });
    let view = mon.view(id).expect("its view");
    assert!(view.users.iter().any(|u| u.username == "alice"), "{:?}", view.users);
    let events = mon.events(None, Some(id)).expect("events");
    assert!(events.last_seq > 0, "the login was an event");
    // Notifications go to this phone (a development build's token).
    mon.set_push(Some(&"ab".repeat(32)), true, "ref-1", "install-1")
        .expect("push token set");

    // Another phone of the same person pairs with its own code.
    let (code2, _waiting2) = w.code();
    let key2 = new_phone_key();
    let paired2 = pair_own_monitor(&w.relay, &code2, "Test iPad", &key2).expect("the second paired");
    assert_eq!(paired2.monitor_id, paired.monitor_id);
    let mon2 = Monitor::own(&w.relay, paired2, &key2);
    assert_eq!(mon2.servers().unwrap().len(), 1, "the same Monitor, the same servers");

    mon.remove_server(id).expect("removed");
    assert!(mon2.servers().unwrap().is_empty());
}

#[test]
fn wrong_and_expired_codes() {
    let Some(w) = World::start() else { return };
    let key = new_phone_key();

    let e = message(pair_own_monitor(&w.relay, "hello", "x", &key).unwrap_err());
    assert!(e.contains("isn't a pairing code"), "{e}");
    let e = message(pair_own_monitor(&w.relay, "ACDE-1234-5678", "x", &key).unwrap_err());
    assert!(e.contains("expired"), "an unknown code: {e}");

    let (code, _waiting) = w.code();
    let (id, secret) = code.split_at(4);
    let wrong_secret: String = secret
        .chars()
        .map(|c| {
            if c.is_ascii_digit() {
                char::from(b'0' + (c as u8 - b'0' + 1) % 10)
            } else {
                c
            }
        })
        .collect();
    // Three wrong tries end the code, then even the right one is refused.
    for _ in 0..3 {
        let e = message(pair_own_monitor(&w.relay, &format!("{id}{wrong_secret}"), "x", &key).unwrap_err());
        assert!(e.contains("isn't right") || e.contains("expired"), "{e}");
    }
    let e = message(pair_own_monitor(&w.relay, &code, "x", &key).unwrap_err());
    assert!(e.contains("expired"), "{e}");
    assert!(w.phones().contains("No phones"), "{}", w.phones());

    // A code works once.
    let (code, _waiting) = w.code();
    pair_own_monitor(&w.relay, &code, "First", &key).expect("paired");
    let e = message(pair_own_monitor(&w.relay, &code, "Second", &new_phone_key()).unwrap_err());
    assert!(e.contains("expired"), "{e}");
}

#[test]
fn unpaired_impostors_and_a_stopped_monitor() {
    let Some(mut w) = World::start() else { return };
    let key = new_phone_key();
    let (code, _waiting) = w.code();
    let paired = pair_own_monitor(&w.relay, &code, "Test iPhone", &key).expect("paired");
    let mon = Monitor::own(&w.relay, paired.clone(), &key);
    assert!(mon.servers().is_ok());

    // A phone that never paired, knowing the Monitor's ID and key.
    let stranger = Monitor::own(&w.relay, paired.clone(), &new_phone_key());
    let e = message(stranger.servers().unwrap_err());
    assert!(e.contains("didn't accept this iPhone"), "{e}");

    // Something else answering as the Monitor (the wrong key) is caught.
    let mut fake = paired.clone();
    fake.monitor_key = [7; 32];
    let e = message(Monitor::own(&w.relay, fake, &key).servers().unwrap_err());
    assert!(e.contains("Pair it again") || e.contains("didn't accept"), "{e}");

    // The Monitor stopped: said plainly; back: the same client works again.
    w.stop_monitor();
    let e = message(until("the stop noticed", || mon.servers().err()));
    assert!(
        e.contains("isn't connected right now") || e.contains("dropped") || e.contains("closed"),
        "{e}"
    );
    // A POST isn't repeated on a new connection (it might have arrived):
    // it fails, and the next one opens a new connection.
    let input = MonitorServerInput {
        name: "Nowhere".into(),
        host: "127.0.0.1".into(),
        tcp_port: 1,
        username: "x".into(),
        enabled: false,
        ..Default::default()
    };
    assert!(mon.add_server(&input).is_err(), "nothing to reach");
    w.start_monitor();
    until("working again", || mon.servers().ok());
    until("a POST again", || mon.add_server(&input).ok());
    assert_eq!(mon.servers().unwrap().len(), 1, "added once");

    // Unpaired at the Monitor: refused from then on.
    let out = w.cli(&["unpair", "1"]).output().unwrap();
    assert!(
        String::from_utf8_lossy(&out.stdout).contains("can no longer reach"),
        "{out:?}"
    );
    let e = message(until("the unpairing noticed", || mon.servers().err()));
    assert!(e.contains("unpaired") || e.contains("closed"), "{e}");
    let e = message(mon.servers().unwrap_err());
    assert!(e.contains("didn't accept this iPhone"), "{e}");
}
