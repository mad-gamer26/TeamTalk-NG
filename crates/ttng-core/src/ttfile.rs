//! TeamTalk's server descriptions, as the desktop clients read and write
//! them: `.tt` files (XML, also BearWare's public server list) and `tt://`
//! links.

use std::fmt::Write as _;

/// A server, as a `.tt` file or `tt://` link describes it.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct HostEntry {
    pub name: String,
    pub host: String,
    pub tcp_port: u16,
    pub udp_port: u16,
    pub encrypted: bool,
    pub username: String,
    pub password: String,
    pub nickname: String,
    pub status_message: String,
    /// A channel to join ("/Lobby/").
    pub channel: String,
    pub channel_password: String,
    /// The trusted certificates (PEM), for encrypted servers.
    pub ca_pem: String,
    pub cert_pem: String,
    pub key_pem: String,
    pub verify_peer: bool,
    /// From BearWare's list: the join code, which listing (official,
    /// public, unofficial), and its stats.
    pub join_code: String,
    pub listing: String,
    pub user_count: i32,
    pub country: String,
    pub server_name: String,
    pub motd: String,
}

const DEFAULT_PORT: u16 = 10333;

/// Every `<host>` in a `.tt` file (or BearWare's list). Errors say why.
pub fn parse_tt_file(xml: &str) -> Result<Vec<HostEntry>, String> {
    let doc = roxmltree::Document::parse(xml).map_err(|e| format!("That isn't a TeamTalk file ({e})."))?;
    let root = doc.root_element();
    if root.tag_name().name() != "teamtalk" {
        return Err("That isn't a TeamTalk file.".into());
    }
    fn child<'a, 'i>(n: roxmltree::Node<'a, 'i>, name: &str) -> Option<roxmltree::Node<'a, 'i>> {
        n.children().find(|c| c.tag_name().name() == name)
    }
    fn text(n: roxmltree::Node, name: &str) -> String {
        child(n, name).and_then(|c| c.text()).unwrap_or_default().to_owned()
    }
    fn flag(n: roxmltree::Node, name: &str) -> bool {
        let t = text(n, name);
        t.eq_ignore_ascii_case("true") || t == "1"
    }
    fn port(n: roxmltree::Node, name: &str) -> u16 {
        text(n, name).trim().parse::<u16>().unwrap_or(DEFAULT_PORT)
    }
    let mut out = Vec::new();
    for h in root.children().filter(|c| c.tag_name().name() == "host") {
        let mut e = HostEntry {
            name: text(h, "name"),
            host: text(h, "address").trim().to_owned(),
            tcp_port: port(h, "tcpport"),
            udp_port: port(h, "udpport"),
            encrypted: flag(h, "encrypted"),
            join_code: text(h, "joincode"),
            listing: text(h, "listing"),
            ..Default::default()
        };
        if let Some(t) = child(h, "trusted-certificate") {
            e.ca_pem = text(t, "certificate-authority-pem");
            e.cert_pem = text(t, "client-certificate-pem");
            e.key_pem = text(t, "client-private-key-pem");
            e.verify_peer = flag(t, "verify-peer");
        }
        if let Some(a) = child(h, "auth") {
            e.username = text(a, "username");
            e.password = text(a, "password");
            e.nickname = text(a, "nickname");
            e.status_message = text(a, "statusmsg");
        }
        if let Some(j) = child(h, "join") {
            e.channel = text(j, "channel");
            e.channel_password = text(j, "password");
        }
        if let Some(c) = child(h, "clientsetup") {
            let n = text(c, "nickname");
            if !n.is_empty() {
                e.nickname = n;
            }
        }
        if let Some(s) = child(h, "stats") {
            e.user_count = text(s, "user-count").parse().unwrap_or(0);
            e.country = text(s, "country");
            e.server_name = text(s, "servername");
            e.motd = text(s, "motd");
        }
        if !e.host.is_empty() {
            out.push(e);
        }
    }
    Ok(out)
}

fn esc(s: &str) -> String {
    s.replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;")
}

/// A `.tt` file for one server, as the desktop writes it.
pub fn to_tt_file(e: &HostEntry) -> String {
    to_tt_file_many(std::slice::from_ref(e))
}

/// A `.tt` file with several servers: the desktop's "Export Server list to
/// .tt File".
pub fn to_tt_file_many(entries: &[HostEntry]) -> String {
    let mut x = String::from("<?xml version=\"1.0\" encoding=\"UTF-8\" ?>\n<teamtalk version=\"5.0\">\n");
    for e in entries {
        host_xml(&mut x, e);
    }
    x.push_str("</teamtalk>\n");
    x
}

fn host_xml(x: &mut String, e: &HostEntry) {
    x.push_str("  <host>\n");
    let _ = writeln!(*x, "    <name>{}</name>", esc(&e.name));
    let _ = writeln!(*x, "    <address>{}</address>", esc(&e.host));
    let _ = writeln!(*x, "    <tcpport>{}</tcpport>", e.tcp_port);
    let _ = writeln!(*x, "    <udpport>{}</udpport>", e.udp_port);
    let _ = writeln!(*x, "    <encrypted>{}</encrypted>", e.encrypted);
    if e.encrypted {
        let _ = writeln!(
            *x,
            "    <trusted-certificate>\n      <certificate-authority-pem>{}</certificate-authority-pem>\n      <client-certificate-pem>{}</client-certificate-pem>\n      <client-private-key-pem>{}</client-private-key-pem>\n      <verify-peer>{}</verify-peer>\n    </trusted-certificate>",
            esc(&e.ca_pem),
            esc(&e.cert_pem),
            esc(&e.key_pem),
            e.verify_peer
        );
    }
    if !e.username.is_empty() {
        let _ = writeln!(
            *x,
            "    <auth>\n      <username>{}</username>\n      <password>{}</password>\n      <nickname>{}</nickname>\n      <statusmsg>{}</statusmsg>\n    </auth>",
            esc(&e.username),
            esc(&e.password),
            esc(&e.nickname),
            esc(&e.status_message)
        );
    }
    if !e.channel.is_empty() {
        let _ = writeln!(
            *x,
            "    <join>\n      <channel>{}</channel>\n      <password>{}</password>\n      <join-last-channel>false</join-last-channel>\n    </join>",
            esc(&e.channel),
            esc(&e.channel_password)
        );
    }
    if !e.nickname.is_empty() {
        let _ = writeln!(
            *x,
            "    <clientsetup>\n      <nickname>{}</nickname>\n    </clientsetup>",
            esc(&e.nickname)
        );
    }
    x.push_str("  </host>\n");
}

fn pct(s: &str) -> String {
    let mut out = String::new();
    for b in s.bytes() {
        if b.is_ascii_alphanumeric() || b"-._~/".contains(&b) {
            out.push(b as char);
        } else {
            let _ = write!(out, "%{b:02X}");
        }
    }
    out
}

fn unpct(s: &str) -> String {
    let b = s.as_bytes();
    let mut out = Vec::with_capacity(b.len());
    let mut i = 0;
    while i < b.len() {
        let hex = (b[i] == b'%' && i + 2 < b.len())
            .then(|| {
                std::str::from_utf8(&b[i + 1..i + 3])
                    .ok()
                    .and_then(|h| u8::from_str_radix(h, 16).ok())
            })
            .flatten();
        match (b[i], hex) {
            (_, Some(v)) => {
                out.push(v);
                i += 3;
            }
            (b'+', None) => {
                out.push(b' ');
                i += 1;
            }
            (c, None) => {
                out.push(c);
                i += 1;
            }
        }
    }
    String::from_utf8_lossy(&out).into_owned()
}

/// A `tt://` link (tt://host?tcpport=…&udpport=…&username=…&password=…&
/// channel=…&chanpasswd=…&encrypted=…), as the desktop opens them.
pub fn parse_tt_link(link: &str) -> Option<HostEntry> {
    let rest = link.trim();
    let rest = rest.strip_prefix("tt:").or_else(|| rest.strip_prefix("TT:"))?;
    let rest = rest.trim_start_matches('/');
    let (host, query) = rest.split_once('?').unwrap_or((rest, ""));
    let host = host.trim_end_matches('/');
    if host.is_empty() {
        return None;
    }
    let mut e = HostEntry {
        name: host.to_owned(),
        host: host.to_owned(),
        tcp_port: DEFAULT_PORT,
        udp_port: DEFAULT_PORT,
        ..Default::default()
    };
    for pair in query.split('&').filter(|p| !p.is_empty()) {
        let (k, v) = pair.split_once('=').unwrap_or((pair, ""));
        let v = unpct(v);
        match k {
            "tcpport" => e.tcp_port = v.parse().unwrap_or(DEFAULT_PORT),
            "udpport" => e.udp_port = v.parse().unwrap_or(DEFAULT_PORT),
            "username" => e.username = v,
            "password" => e.password = v,
            "channel" => e.channel = v,
            "chanpasswd" => e.channel_password = v,
            "encrypted" => e.encrypted = v.eq_ignore_ascii_case("true") || v == "1",
            _ => {}
        }
    }
    Some(e)
}

/// A `tt://` link for a server (and channel), as the desktop makes them.
/// Passwords go in only when given.
pub fn to_tt_link(e: &HostEntry) -> String {
    let mut l = format!(
        "tt://{}?tcpport={}&udpport={}&encrypted={}",
        e.host, e.tcp_port, e.udp_port, e.encrypted
    );
    if !e.username.is_empty() {
        let _ = write!(l, "&username={}", pct(&e.username));
        if !e.password.is_empty() {
            let _ = write!(l, "&password={}", pct(&e.password));
        }
    }
    if !e.channel.is_empty() {
        let _ = write!(l, "&channel={}", pct(&e.channel));
        if !e.channel_password.is_empty() {
            let _ = write!(l, "&chanpasswd={}", pct(&e.channel_password));
        }
    }
    l
}

#[cfg(test)]
mod tests {
    use super::*;

    const LIST: &str = r#"<?xml version="1.0" encoding="UTF-8" ?><teamtalk version="5.0"><host><id>205</id><joincode>abcdefgh</joincode><listing>official</listing><name>TeamTalk 5 Official Server (EU)</name><address>tt5eu.bearware.dk</address><tcpport>10335</tcpport><udpport>10335</udpport><encrypted>false</encrypted><trusted-certificate><certificate-authority-pem></certificate-authority-pem><client-certificate-pem></client-certificate-pem><client-private-key-pem></client-private-key-pem><verify-peer>false</verify-peer></trusted-certificate><auth><username>guest</username><password>guest</password></auth><join><channel>/</channel><password></password></join><stats><user-count>8</user-count><country>DE</country><servername>TeamTalk 5 Server (EU)</servername><motd>Welcome &amp; hello</motd><active>true</active></stats></host><host><name>Two</name><address>two.example</address><tcpport>10443</tcpport><udpport>10443</udpport><encrypted>true</encrypted><trusted-certificate><certificate-authority-pem>-----BEGIN CERTIFICATE-----
MIIF
-----END CERTIFICATE-----</certificate-authority-pem><verify-peer>true</verify-peer></trusted-certificate></host></teamtalk>"#;

    #[test]
    fn bearwares_list_reads() {
        let l = parse_tt_file(LIST).unwrap();
        assert_eq!(l.len(), 2);
        let a = &l[0];
        assert_eq!(
            (
                a.name.as_str(),
                a.host.as_str(),
                a.tcp_port,
                a.username.as_str(),
                a.channel.as_str()
            ),
            (
                "TeamTalk 5 Official Server (EU)",
                "tt5eu.bearware.dk",
                10335,
                "guest",
                "/"
            )
        );
        assert_eq!(
            (
                a.join_code.as_str(),
                a.listing.as_str(),
                a.user_count,
                a.country.as_str()
            ),
            ("abcdefgh", "official", 8, "DE")
        );
        assert_eq!(a.motd, "Welcome & hello");
        assert!(l[1].encrypted && l[1].verify_peer && l[1].ca_pem.contains("BEGIN CERTIFICATE"));
    }

    #[test]
    fn several_servers_in_one_file() {
        let a = HostEntry {
            name: "A".into(),
            host: "a.example".into(),
            tcp_port: 10333,
            udp_port: 10333,
            ..Default::default()
        };
        let b = HostEntry {
            name: "B".into(),
            host: "b.example".into(),
            tcp_port: 10334,
            udp_port: 10334,
            ..Default::default()
        };
        let back = parse_tt_file(&to_tt_file_many(&[a.clone(), b.clone()])).unwrap();
        assert_eq!(back.iter().map(|e| e.name.as_str()).collect::<Vec<_>>(), ["A", "B"]);
        assert_eq!(back[1].tcp_port, 10334);
    }

    #[test]
    fn tt_files_round_trip() {
        let e = HostEntry {
            name: "Home <& friends>".into(),
            host: "tt.example.com".into(),
            tcp_port: 10335,
            udp_port: 10336,
            encrypted: true,
            username: "me".into(),
            password: "p&w".into(),
            nickname: "Mé".into(),
            status_message: "hi".into(),
            channel: "/Lobby/".into(),
            channel_password: "c".into(),
            ca_pem: "CA".into(),
            cert_pem: "CERT".into(),
            key_pem: "KEY".into(),
            verify_peer: true,
            ..Default::default()
        };
        assert_eq!(parse_tt_file(&to_tt_file(&e)).unwrap(), vec![e]);
        assert!(parse_tt_file("<html/>").is_err());
        assert!(parse_tt_file("not xml").is_err());
    }

    #[test]
    fn tt_links_round_trip_like_the_desktops() {
        let e = parse_tt_link("tt://tt5eu.bearware.dk?tcpport=10335&udpport=10335&encrypted=false&username=guest&password=g%26st&channel=/Main%20Room/&chanpasswd=x").unwrap();
        assert_eq!(
            (
                e.host.as_str(),
                e.tcp_port,
                e.username.as_str(),
                e.password.as_str(),
                e.channel.as_str(),
                e.channel_password.as_str()
            ),
            ("tt5eu.bearware.dk", 10335, "guest", "g&st", "/Main Room/", "x")
        );
        assert_eq!(
            parse_tt_link(&to_tt_link(&e)).unwrap(),
            HostEntry {
                name: e.host.clone(),
                ..e.clone()
            }
        );
        let bare = parse_tt_link("tt://example.org").unwrap();
        assert_eq!((bare.tcp_port, bare.udp_port), (10333, 10333));
        assert!(parse_tt_link("http://x").is_none());
        assert!(parse_tt_link("tt://").is_none());
    }
}
