//! Test helpers: BearWare's `tt5srv` (from the downloaded SDK) on a free
//! local port with test accounts, and clients whose events can be awaited.
#![allow(dead_code)]

use std::net::{TcpListener, TcpStream, UdpSocket};
use std::path::PathBuf;
use std::process::{Child, Command, Stdio};
use std::sync::mpsc::{self, Receiver};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use ttng_core::*;

/// Normal users' rights (BearWare's defaults for a new account).
const USER_RIGHTS: u32 = 259591;

pub struct Server {
    pub port: u16,
    dir: PathBuf,
    child: Option<Child>,
}

fn tt5srv() -> PathBuf {
    let sdk = std::env::var_os("TTNG_SDK_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../sdk/linux"));
    sdk.join("Server/tt5srv")
}

/// A port free for both TCP and UDP.
fn free_port() -> u16 {
    loop {
        let t = TcpListener::bind("127.0.0.1:0").unwrap();
        let port = t.local_addr().unwrap().port();
        if UdpSocket::bind(("127.0.0.1", port)).is_ok() {
            return port;
        }
    }
}

fn account(name: &str, admin: bool) -> String {
    format!(
        "<user><username>{name}</username><password>{name}-pw</password><user-type>{}</user-type><user-rights>{}</user-rights><note /><userdata>0</userdata><init-channel /><audiocodec-bps-limit>0</audiocodec-bps-limit><channel-operator /></user>",
        if admin { 2 } else { 1 },
        if admin { 0 } else { USER_RIGHTS }
    )
}

impl Server {
    /// A server with accounts admin, alice, bob and carol (password:
    /// "<name>-pw"), running until dropped.
    pub fn start() -> Server {
        Server::start_with("")
    }

    /// A server with more `<general>` settings (encryption, say).
    pub fn start_with(general: &str) -> Server {
        let port = free_port();
        let dir = std::env::temp_dir().join(format!("ttng-test-{}-{port}", std::process::id()));
        std::fs::create_dir_all(dir.join("files")).unwrap();
        let users: String = [("admin", true), ("alice", false), ("bob", false), ("carol", false)]
            .iter()
            .map(|(n, a)| account(n, *a))
            .collect();
        let xml = format!(
            r#"<?xml version="1.0" encoding="UTF-8"?>
<teamtalk version="5.2">
  <general>
    <server-name>TTNG Test</server-name><motd>Welcome to the test server</motd>
    <max-users>100</max-users><auto-save>false</auto-save><bind-ip>127.0.0.1</bind-ip>
    <tcpport>{port}</tcpport><udpport>{port}</udpport><upnp>false</upnp>
    <login-attempts>0</login-attempts><max-logins-per-ipaddr>0</max-logins-per-ipaddr>
    <user-timeout>10</user-timeout><login-delay-msec>0</login-delay-msec>
    {general}
  </general>
  <file-storage><files-root>files</files-root><max-diskusage>1000000000</max-diskusage><channel-diskquota>100000000</channel-diskquota></file-storage>
  <logging><server-log-maxsize>-1</server-log-maxsize></logging>
  <users>{users}</users>
</teamtalk>"#
        );
        std::fs::write(dir.join("tt5srv.xml"), xml).unwrap();
        let mut s = Server { port, dir, child: None };
        s.run();
        s
    }

    fn run(&mut self) {
        let child = Command::new(tt5srv())
            .args(["-nd", "-wd"])
            .arg(&self.dir)
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .expect("tt5srv didn't start (run scripts/fetch-sdk.sh linux)");
        self.child = Some(child);
        let end = Instant::now() + Duration::from_secs(10);
        while TcpStream::connect(("127.0.0.1", self.port)).is_err() {
            assert!(Instant::now() < end, "tt5srv didn't start listening");
            std::thread::sleep(Duration::from_millis(50));
        }
    }

    /// Stops the server (as a crash would look to clients).
    pub fn stop(&mut self) {
        if let Some(mut c) = self.child.take() {
            let _ = c.kill();
            let _ = c.wait();
        }
    }

    /// Starts it again on the same port.
    pub fn restart(&mut self) {
        self.stop();
        self.run();
    }

    /// The folder the server runs in (for its certificates).
    pub fn dir(&self) -> &std::path::Path {
        &self.dir
    }

    pub fn options(&self, user: &str) -> ConnectOptions {
        ConnectOptions {
            host: "127.0.0.1".into(),
            tcp_port: self.port,
            udp_port: self.port,
            encrypted: false,
            nickname: format!("{}{}", user[..1].to_uppercase(), &user[1..]),
            username: user.into(),
            password: format!("{user}-pw"),
            client_name: "TeamTalk NG".into(),
            join_channel: None,
            reconnect: false,
            encryption: None,
            web_login: None,
        }
    }
}

impl Drop for Server {
    fn drop(&mut self) {
        self.stop();
        let _ = std::fs::remove_dir_all(&self.dir);
    }
}

/// A client and its events.
pub struct TestClient {
    pub client: Client,
    events: Receiver<Event>,
    pub seen: Arc<Mutex<Vec<Event>>>,
}

impl TestClient {
    pub fn new() -> TestClient {
        let (tx, rx) = mpsc::channel();
        let seen = Arc::new(Mutex::new(Vec::new()));
        let s = Arc::clone(&seen);
        let tx = Mutex::new(tx);
        let client = Client::new(move |e: Event| {
            s.lock().unwrap().push(e.clone());
            let _ = tx.lock().unwrap().send(e);
        });
        TestClient {
            client,
            events: rx,
            seen,
        }
    }

    /// A client logged in as `user`.
    pub fn logged_in(server: &Server, user: &str) -> TestClient {
        let c = TestClient::new();
        c.client.connect(server.options(user)).expect("log in");
        c
    }

    /// Waits for an event `pick` accepts (others are skipped), up to 10 s.
    pub fn wait_for<T>(&self, what: &str, mut pick: impl FnMut(&Event) -> Option<T>) -> T {
        let end = Instant::now() + Duration::from_secs(10);
        loop {
            let left = end.saturating_duration_since(Instant::now());
            match self.events.recv_timeout(left) {
                Ok(e) => {
                    if let Some(v) = pick(&e) {
                        return v;
                    }
                }
                Err(_) => panic!("no {what} within 10 s; events so far: {:#?}", self.seen.lock().unwrap()),
            }
        }
    }

    /// Forgets the events so far (later waits only see newer ones).
    pub fn drain(&self) {
        while self.events.try_recv().is_ok() {}
    }

    /// Waits (up to 10 s) until the snapshot is as `ok` wants it.
    pub fn wait_until(&self, ok: impl Fn(&Snapshot) -> bool) -> Snapshot {
        let end = Instant::now() + Duration::from_secs(10);
        loop {
            let s = self.client.snapshot();
            if ok(&s) {
                return s;
            }
            assert!(Instant::now() < end, "the snapshot never got there: {s:#?}");
            std::thread::sleep(Duration::from_millis(50));
        }
    }

    pub fn user_named(&self, nickname: &str) -> User {
        self.client
            .snapshot()
            .users
            .into_iter()
            .find(|u| u.nickname == nickname)
            .unwrap_or_else(|| panic!("no user {nickname}"))
    }
}
