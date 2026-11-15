//! Connecting as the desktop does: encrypted servers with certificates,
//! BearWare.dk web logins (against a local stand-in for bearware.dk).

mod common;

use std::io::{BufRead, BufReader, Write};
use std::net::TcpListener;
use std::path::PathBuf;
use std::process::Command;

use common::{Server, TestClient};
use ttng_core::*;

/// A certificate authority and a server certificate it signed (openssl).
struct Certs {
    dir: PathBuf,
}

impl Certs {
    fn make(tag: &str) -> Certs {
        let dir = std::env::temp_dir().join(format!("ttng-certs-{}-{tag}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let run = |args: &[&str]| {
            let ok = Command::new(std::env::var("OPENSSL").unwrap_or_else(|_| "openssl".into()))
                .args(args)
                .current_dir(&dir)
                .output()
                .expect("openssl")
                .status
                .success();
            assert!(ok, "openssl {args:?}");
        };
        run(&[
            "req",
            "-x509",
            "-newkey",
            "rsa:2048",
            "-nodes",
            "-keyout",
            "ca.key",
            "-out",
            "ca.pem",
            "-days",
            "2",
            "-subj",
            "/CN=TTNG Test CA",
        ]);
        run(&[
            "req",
            "-newkey",
            "rsa:2048",
            "-nodes",
            "-keyout",
            "srv.key",
            "-out",
            "srv.csr",
            "-subj",
            "/CN=127.0.0.1",
        ]);
        run(&[
            "x509",
            "-req",
            "-in",
            "srv.csr",
            "-CA",
            "ca.pem",
            "-CAkey",
            "ca.key",
            "-CAcreateserial",
            "-out",
            "srv.pem",
            "-days",
            "2",
        ]);
        Certs { dir }
    }
    fn path(&self, f: &str) -> String {
        self.dir.join(f).to_string_lossy().into_owned()
    }
    fn pem(&self, f: &str) -> String {
        std::fs::read_to_string(self.dir.join(f)).unwrap()
    }
}

impl Drop for Certs {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.dir);
    }
}

/// A TLS server with the certificates (`openssl s_server`): BearWare's
/// standard SDK server doesn't encrypt (that's the Professional SDK's
/// tt5prosrv), so the handshake, where certificates are checked, is what's
/// tested here.
struct TlsServer {
    port: u16,
    child: std::process::Child,
}

impl TlsServer {
    fn start(certs: &Certs) -> TlsServer {
        let port = TcpListener::bind("127.0.0.1:0").unwrap().local_addr().unwrap().port();
        let child = Command::new(std::env::var("OPENSSL").unwrap_or_else(|_| "openssl".into()))
            .args(["s_server", "-quiet", "-accept"])
            .arg(format!("127.0.0.1:{port}"))
            .args(["-cert", &certs.path("srv.pem"), "-key", &certs.path("srv.key")])
            .stdin(std::process::Stdio::piped())
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .spawn()
            .expect("openssl s_server");
        let end = std::time::Instant::now() + std::time::Duration::from_secs(10);
        while std::net::TcpStream::connect(("127.0.0.1", port)).is_err() {
            assert!(std::time::Instant::now() < end, "s_server didn't start");
            std::thread::sleep(std::time::Duration::from_millis(50));
        }
        TlsServer { port, child }
    }
}

impl Drop for TlsServer {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

fn tls_options(port: u16, ca_pem: &str) -> ConnectOptions {
    ConnectOptions {
        host: "127.0.0.1".into(),
        tcp_port: port,
        udp_port: port,
        encrypted: true,
        nickname: "Alice".into(),
        username: "alice".into(),
        password: "alice-pw".into(),
        client_name: "TeamTalk NG".into(),
        join_channel: None,
        reconnect: false,
        encryption: Some(Encryption {
            ca_pem: ca_pem.into(),
            verify_peer: true,
            ..Default::default()
        }),
        web_login: None,
    }
}

#[test]
fn encrypted_connections_check_the_servers_certificate() {
    let certs = Certs::make("good");
    let other = Certs::make("other");
    let tls = TlsServer::start(&certs);

    // Another authority: refused at the handshake, saying why.
    let c = TestClient::new();
    let refused = c.client.connect(tls_options(tls.port, &other.pem("ca.pem")));
    assert!(
        matches!(&refused, Err(Error::Connection(m)) if m.starts_with("The secure connection failed") && m.contains("certificate verify failed")),
        "{refused:?}"
    );

    // The server's own authority: past the handshake (this server then
    // isn't TeamTalk, so it ends some other way, not over the certificate).
    let tls2 = TlsServer::start(&certs);
    let a = TestClient::new();
    let past = a.client.connect(tls_options(tls2.port, &certs.pem("ca.pem")));
    assert!(
        !matches!(&past, Err(Error::Connection(m)) if m.contains("certificate")),
        "{past:?}"
    );
}

/// A stand-in for bearware.dk's web login, answering `username` (or
/// nothing) to every request, and noting what was asked.
fn fake_bearware(username: &'static str) -> (String, std::sync::mpsc::Receiver<String>) {
    let l = TcpListener::bind("127.0.0.1:0").unwrap();
    let url = format!("http://127.0.0.1:{}/weblogin.php", l.local_addr().unwrap().port());
    let (tx, rx) = std::sync::mpsc::channel();
    std::thread::spawn(move || {
        for s in l.incoming().flatten() {
            let mut r = BufReader::new(s.try_clone().unwrap());
            let mut first = String::new();
            let _ = r.read_line(&mut first);
            let mut h = String::new();
            while r.read_line(&mut h).is_ok_and(|n| n > 2) {
                h.clear();
            }
            let _ = tx.send(first);
            let body = if username.is_empty() {
                "<teamtalk></teamtalk>".to_owned()
            } else {
                format!(
                    "<?xml version=\"1.0\"?><teamtalk><bearware><username>{username}</username><nickname>Alice</nickname><token>tok-123</token></bearware></teamtalk>"
                )
            };
            let mut s = s;
            let _ = write!(
                s,
                "HTTP/1.1 200 OK\r\nContent-Type: text/xml\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                body.len()
            );
        }
    });
    (url, rx)
}

#[test]
fn bearware_web_logins() {
    // One test sets the address for the whole program, so the steps stay
    // in one test.
    let (url, asked) = fake_bearware("alice");
    // SAFETY: no other thread reads the environment at this point.
    unsafe { std::env::set_var("TTNG_WEBLOGIN_URL", &url) };

    let account = bearware::bearware_sign_in("alice@example.com", "secret").expect("signed in");
    assert_eq!(
        (account.username.as_str(), account.token.as_str()),
        ("alice", "tok-123")
    );
    let first = asked.recv().unwrap();
    assert!(
        first.contains("action=auth") && first.contains("client=TeamTalkNG"),
        "{first}"
    );

    // Connecting with it: BearWare gives the name the server sees.
    let server = Server::start();
    let a = TestClient::new();
    a.client
        .connect(ConnectOptions {
            username: "bearware".into(),
            web_login: Some(WebLogin {
                username: account.username.clone(),
                token: account.token.clone(),
            }),
            ..server.options("alice")
        })
        .expect("logged in through BearWare");
    let s = a.client.snapshot();
    assert_eq!(s.user(s.my_user_id).unwrap().username, "alice");
    let asked_auth = asked.recv().unwrap();
    assert!(
        asked_auth.contains("action=clientauth") && asked_auth.contains("token=tok-123"),
        "{asked_auth}"
    );

    // BearWare refusing: the connection fails, saying so, and isn't retried.
    let (refusing, _asked) = fake_bearware("");
    // SAFETY: as above.
    unsafe { std::env::set_var("TTNG_WEBLOGIN_URL", &refusing) };
    let wrong = bearware::bearware_sign_in("alice@example.com", "wrong");
    assert_eq!(
        wrong,
        Err("BearWare.dk didn't accept that username and password.".into())
    );
    let b = TestClient::new();
    let refused = b.client.connect(ConnectOptions {
        username: "bearware".into(),
        reconnect: true,
        web_login: Some(WebLogin {
            username: "alice".into(),
            token: "expired".into(),
        }),
        ..server.options("alice")
    });
    assert_eq!(
        refused,
        Err(Error::Connection("BearWare.dk didn't confirm the account.".into()))
    );
}
