//! The UI tests' world (scripts/test-ios-ui.sh): a throwaway TeamTalk
//! server (BearWare's tt5srv on a free local port, accounts admin, alice,
//! bob and carol with "<name>-pw"), its channels (Lobby, Secret with the
//! password "sesame", a hidden Hidden, a classroom Class), and people the
//! tests make act: bob and carol logged in, admin for admin's things.
//! Commands over HTTP on 127.0.0.1 (the port is printed first, as JSON):
//!
//!   /state?bot=bob             what bob sees (people, channels, messages)
//!   /join?bot=bob&path=/Lobby/&password=
//!   /say?bot=bob&text=…        to bob's channel
//!   /pm?bot=bob&to=Alice&text=…  privately, by nickname
//!   /broadcast?text=…          as admin
//!   /talk?bot=bob&on=1         a test tone as bob's voice
//!   /stream?bot=bob            a three-second tone file to bob's channel
//!   /nick?bot=bob&name=…
//!   /upload?bot=bob&name=notes.txt   a small file to bob's channel
//!   /logout?bot=bob, /login?bot=bob
//!   /server?do=stop|start      the server stops (as a crash) or starts again
//!   /quit
//!
//! Throwaway accounts on a throwaway server, on localhost only.

#[path = "../tests/common/mod.rs"]
mod common;

use std::collections::HashMap;
use std::io::{BufRead, BufReader, Write};
use std::net::TcpListener;
use std::time::Duration;

use common::{Server, TestClient};
use serde_json::{Value, json};
use ttng_core::*;

fn query(q: &str) -> HashMap<String, String> {
    q.split('&')
        .filter_map(|kv| kv.split_once('=').or(Some((kv, ""))))
        .filter(|(k, _)| !k.is_empty())
        .map(|(k, v)| (k.to_owned(), decode(v)))
        .collect()
}

fn decode(s: &str) -> String {
    let b = s.as_bytes();
    let mut out = Vec::new();
    let mut i = 0;
    while i < b.len() {
        match b[i] {
            b'+' => out.push(b' '),
            b'%' if i + 2 < b.len() => {
                if let Ok(v) = u8::from_str_radix(&s[i + 1..i + 3], 16) {
                    out.push(v);
                    i += 2;
                }
            }
            c => out.push(c),
        }
        i += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

fn path_of(s: &Snapshot, id: i32) -> String {
    let mut parts = Vec::new();
    let mut at = s.channels.iter().find(|c| c.id == id);
    while let Some(c) = at {
        if c.parent_id == 0 {
            break;
        }
        parts.insert(0, c.name.clone());
        at = s.channels.iter().find(|p| p.id == c.parent_id);
    }
    if id == 0 {
        String::new()
    } else {
        format!("/{}", parts.iter().map(|p| format!("{p}/")).collect::<String>())
    }
}

fn state(c: &TestClient) -> Value {
    let s = c.client.snapshot();
    let users: Vec<Value> = s
        .users
        .iter()
        .map(|u| {
            json!({ "nickname": u.nickname, "username": u.username, "channel": path_of(&s, u.channel_id),
                    "talking": u.talking, "streaming": u.streaming_media, "status": format!("{:?}", u.status),
                    "status_message": u.status_message, "gender": format!("{:?}", u.gender), "operator": u.operator })
        })
        .collect();
    let messages: Vec<Value> = c
        .seen
        .lock()
        .unwrap()
        .iter()
        .filter_map(|e| match e {
            Event::MessageReceived(m) => {
                let from = s
                    .users
                    .iter()
                    .find(|u| u.id == m.from_user_id)
                    .map(|u| u.nickname.clone())
                    .unwrap_or_default();
                let kind = match m.target {
                    MessageTarget::Channel(_) => "channel",
                    MessageTarget::User(_) => "private",
                    MessageTarget::Broadcast => "broadcast",
                };
                Some(json!({ "kind": kind, "from": from, "text": m.text }))
            }
            _ => None,
        })
        .collect();
    let kicked = c.seen.lock().unwrap().iter().any(|e| matches!(e, Event::Kicked { .. }));
    json!({
        "connected": s.state == Some(ConnectionState::LoggedIn),
        "me": path_of(&s, s.my_channel_id),
        "users": users,
        "channels": s.channels.iter().map(|c| path_of(&s, c.id)).collect::<Vec<_>>(),
        "messages": messages,
        "kicked": kicked,
        "files": s.files.iter().map(|f| f.name.clone()).collect::<Vec<_>>(),
    })
}

fn tone_wav(path: &std::path::Path, secs: u32) {
    let rate = 48000u32;
    let n = rate * secs;
    let mut w = Vec::new();
    w.extend_from_slice(b"RIFF");
    w.extend_from_slice(&(36 + n * 2).to_le_bytes());
    w.extend_from_slice(b"WAVEfmt ");
    w.extend_from_slice(&16u32.to_le_bytes());
    w.extend_from_slice(&1u16.to_le_bytes());
    w.extend_from_slice(&1u16.to_le_bytes());
    w.extend_from_slice(&rate.to_le_bytes());
    w.extend_from_slice(&(rate * 2).to_le_bytes());
    w.extend_from_slice(&2u16.to_le_bytes());
    w.extend_from_slice(&16u16.to_le_bytes());
    w.extend_from_slice(b"data");
    w.extend_from_slice(&(n * 2).to_le_bytes());
    for i in 0..n {
        let v = ((i as f32 * 440.0 * std::f32::consts::TAU / rate as f32).sin() * 12000.0) as i16;
        w.extend_from_slice(&v.to_le_bytes());
    }
    std::fs::write(path, w).unwrap();
}

fn bot(server: &Server, name: &str) -> TestClient {
    let c = TestClient::logged_in(server, name);
    c.client.init_audio(AudioDevices::Virtual).unwrap();
    c
}

/// admin (who makes the channels: the server keeps none), bob and carol,
/// logged in and in the root channel.
fn people(server: &Server) -> HashMap<String, TestClient> {
    let admin = bot(server, "admin");
    let root = admin
        .wait_until(|s| s.channels.iter().any(|c| c.parent_id == 0))
        .channels
        .iter()
        .find(|c| c.parent_id == 0)
        .unwrap()
        .id;
    for spec in [
        ChannelSpec {
            parent_id: root,
            name: "Lobby".into(),
            permanent: true,
            ..Default::default()
        },
        ChannelSpec {
            parent_id: root,
            name: "Secret".into(),
            password: Some("sesame".into()),
            permanent: true,
            ..Default::default()
        },
        ChannelSpec {
            parent_id: root,
            name: "Hidden".into(),
            hidden: true,
            permanent: true,
            ..Default::default()
        },
        ChannelSpec {
            parent_id: root,
            name: "Class".into(),
            classroom: true,
            permanent: true,
            ..Default::default()
        },
    ] {
        let _ = admin.client.make_channel(&spec);
    }
    admin.wait_until(|s| s.channels.len() >= 5);
    admin.client.join_channel_path("/", "").unwrap();
    let mut bots: HashMap<String, TestClient> = HashMap::new();
    bots.insert("admin".into(), admin);
    for name in ["bob", "carol"] {
        let c = bot(server, name);
        c.client.join_channel_path("/", "").unwrap();
        bots.insert(name.into(), c);
    }
    bots
}

fn main() {
    let mut server = Server::start();
    let work = std::env::temp_dir().join(format!("ttng-uitest-{}", std::process::id()));
    std::fs::create_dir_all(&work).unwrap();

    let mut bots = people(&server);
    let http = TcpListener::bind("127.0.0.1:0").unwrap();
    println!(
        "{}",
        json!({ "tt_port": server.port, "control_port": http.local_addr().unwrap().port() })
    );
    std::io::stdout().flush().unwrap();

    for stream in http.incoming() {
        let Ok(mut stream) = stream else { continue };
        let mut line = String::new();
        if BufReader::new(&stream).read_line(&mut line).is_err() {
            continue;
        }
        let target = line.split_whitespace().nth(1).unwrap_or("/").to_owned();
        let (path, q) = target.split_once('?').unwrap_or((&target, ""));
        let q = query(q);
        let who = q.get("bot").cloned().unwrap_or_else(|| "bob".into());
        let result: std::result::Result<Value, String> = (|| {
            let c = || bots.get(&who).ok_or(format!("no bot {who}"));
            let ok = |r: ttng_core::Result<()>| r.map(|_| json!({ "ok": true })).map_err(|e| format!("{e:?}"));
            match path {
                "/state" => Ok(state(c()?)),
                "/join" => ok(c()?
                    .client
                    .join_channel_path(&q["path"], q.get("password").map_or("", |s| s))),
                "/say" => {
                    let id = c()?.client.snapshot().my_channel_id;
                    ok(c()?.client.send_message(MessageTarget::Channel(id), &q["text"]))
                }
                "/pm" => {
                    let to = c()?.user_named(&q["to"]).id;
                    ok(c()?.client.send_message(MessageTarget::User(to), &q["text"]))
                }
                "/broadcast" => ok(bots["admin"].client.send_message(MessageTarget::Broadcast, &q["text"])),
                "/talk" => {
                    let on = q.get("on").map(|v| v == "1").unwrap_or(true);
                    c()?.client
                        .set_test_tone(if on { 440 } else { 0 })
                        .map_err(|e| format!("{e:?}"))?;
                    ok(c()?.client.set_transmitting(on))
                }
                "/stream" => {
                    let f = work.join("tone.wav");
                    tone_wav(&f, 3);
                    ok(c()?.client.stream_media_file(f.to_str().unwrap(), 0, false, false))
                }
                "/nick" => ok(c()?.client.set_nickname(&q["name"])),
                "/upload" => {
                    let f = work.join(q.get("name").map_or("notes.txt", |s| s));
                    std::fs::write(&f, b"Notes from the UI tests\n").unwrap();
                    let id = c()?.client.snapshot().my_channel_id;
                    ok(c()?.client.upload_file(id, f.to_str().unwrap()))
                }
                "/logout" => ok(c()?.client.disconnect()),
                "/login" => {
                    let nc = bot(&server, &who);
                    nc.client.join_channel_path("/", "").unwrap();
                    bots.insert(who.clone(), nc);
                    Ok(json!({ "ok": true }))
                }
                "/server" => {
                    match q.get("do").map(String::as_str) {
                        Some("stop") => server.stop(),
                        Some("start") => {
                            server.restart();
                            std::thread::sleep(Duration::from_millis(300));
                            // As a server that kept its channels, with its people back.
                            bots = people(&server);
                        }
                        _ => return Err("do=stop or do=start".into()),
                    }
                    Ok(json!({ "ok": true }))
                }
                "/reset" => {
                    // Between tests: everyone logged in (kicked or not), back in the
                    // root channel, as themselves.
                    let gone: Vec<String> = bots
                        .iter()
                        .filter(|(_, b)| b.client.snapshot().state != Some(ConnectionState::LoggedIn))
                        .map(|(n, _)| n.clone())
                        .collect();
                    for name in gone {
                        let nc = bot(&server, &name);
                        bots.insert(name, nc);
                    }
                    for (name, b) in &bots {
                        let _ = b.client.join_channel_path("/", "");
                        let nick = format!("{}{}", name[..1].to_uppercase(), &name[1..]);
                        let _ = b.client.set_nickname(&nick);
                        let _ = b.client.set_transmitting(false);
                        b.seen.lock().unwrap().clear();
                    }
                    Ok(json!({ "ok": true }))
                }
                "/quit" => std::process::exit(0),
                _ => Err(format!("unknown command {path}")),
            }
        })();
        let (status, body) = match result {
            Ok(v) => ("200 OK", v),
            Err(e) => ("400 Bad Request", json!({ "error": e })),
        };
        let body = body.to_string();
        let _ = write!(
            stream,
            "HTTP/1.1 {status}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
            body.len()
        );
    }
}
