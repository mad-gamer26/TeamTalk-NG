//! BearWare.dk's web services, as the desktop clients use them: signing in
//! with a BearWare.dk account (web login), the public server list, and
//! join codes. Blocking: call off the main thread.

use crate::ttfile::{HostEntry, parse_tt_file};

const WEBLOGIN: &str = "https://www.bearware.dk/teamtalk/weblogin.php";
const SERVERS: &str = "https://www.bearware.dk/teamtalk/tt5servers.php";

/// How this client introduces itself to BearWare (its own name, not
/// BearWare's apps').
fn client() -> String {
    let os = if cfg!(target_os = "ios") {
        "iOS"
    } else if cfg!(target_os = "android") {
        "Android"
    } else if cfg!(target_os = "macos") {
        "Mac"
    } else if cfg!(windows) {
        "Windows"
    } else {
        "Linux"
    };
    format!(
        "client=TeamTalkNG&version={}&dllversion={}&os={os}",
        env!("CARGO_PKG_VERSION"),
        crate::sdk_version()
    )
}

/// The services' addresses (tests point them at a local fake).
fn base(var: &str, default: &str) -> String {
    std::env::var(var).unwrap_or_else(|_| default.to_owned())
}

fn get(url: &str) -> Result<String, String> {
    let agent: ureq::Agent = ureq::Agent::config_builder()
        .timeout_global(Some(std::time::Duration::from_secs(20)))
        .build()
        .into();
    agent
        .get(url)
        .call()
        .map_err(|e| format!("BearWare.dk couldn't be reached ({e})."))?
        .body_mut()
        .read_to_string()
        .map_err(|e| format!("BearWare.dk's answer couldn't be read ({e})."))
}

fn enc(s: &str) -> String {
    let mut out = String::new();
    for b in s.bytes() {
        if b.is_ascii_alphanumeric() || b"-._~".contains(&b) {
            out.push(b as char);
        } else {
            out.push_str(&format!("%{b:02X}"));
        }
    }
    out
}

/// A BearWare.dk account, signed in (keep the token in the keychain).
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct BearWareAccount {
    /// As servers know it ("someone@bearware.dk").
    pub username: String,
    pub nickname: String,
    pub token: String,
}

fn bearware_field(xml: &str, name: &str) -> String {
    roxmltree::Document::parse(xml)
        .ok()
        .and_then(|d| {
            d.descendants()
                .find(|n| n.tag_name().name() == "bearware")
                .and_then(|b| b.children().find(|c| c.tag_name().name() == name))
                .and_then(|n| n.text().map(str::to_owned))
        })
        .unwrap_or_default()
}

/// Signs in to a BearWare.dk account (the desktop's "BearWare.dk Web
/// Login"): for servers that take BearWare.dk accounts.
pub fn bearware_sign_in(username: &str, password: &str) -> Result<BearWareAccount, String> {
    let url = format!(
        "{}?{}&service=bearware&action=auth&username={}&password={}",
        base("TTNG_WEBLOGIN_URL", WEBLOGIN),
        client(),
        enc(username),
        enc(password)
    );
    let xml = get(&url)?;
    let a = BearWareAccount {
        username: bearware_field(&xml, "username"),
        nickname: bearware_field(&xml, "nickname"),
        token: bearware_field(&xml, "token"),
    };
    if a.username.is_empty() {
        return Err("BearWare.dk didn't accept that username and password.".into());
    }
    Ok(a)
}

/// The username a server should see for this BearWare.dk account (asked
/// with the server's access token at each connection).
pub(crate) fn bearware_client_auth(username: &str, token: &str, access_token: &str) -> Result<String, String> {
    let url = format!(
        "{}?{}&service=bearware&action=clientauth&username={}&token={}&accesstoken={}",
        base("TTNG_WEBLOGIN_URL", WEBLOGIN),
        client(),
        enc(username),
        enc(token),
        enc(access_token)
    );
    let name = bearware_field(&get(&url)?, "username");
    if name.is_empty() {
        Err("BearWare.dk didn't confirm the account.".into())
    } else {
        Ok(name)
    }
}

/// BearWare's public server list: official servers, public ones, and (if
/// asked) unofficial ones.
pub fn public_servers(official: bool, unofficial: bool) -> Result<Vec<HostEntry>, String> {
    let url = format!(
        "{}?{}&official={}&unofficial={}",
        base("TTNG_SERVERS_URL", SERVERS),
        client(),
        official as u8,
        unofficial as u8
    );
    parse_tt_file(&get(&url)?)
}

/// The server a join code stands for.
pub fn server_for_join_code(code: &str) -> Result<HostEntry, String> {
    let url = format!(
        "{}?{}&action=joincode&joincode={}",
        base("TTNG_SERVERS_URL", SERVERS),
        client(),
        enc(code.trim())
    );
    parse_tt_file(&get(&url)?)?
        .into_iter()
        .next()
        .ok_or_else(|| "There's no server with that join code.".into())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn web_login_answers_read() {
        let xml = "<?xml version=\"1.0\"?><teamtalk><bearware><username>me@bearware.dk</username><nickname>Me</nickname><token>abc</token></bearware></teamtalk>";
        assert_eq!(bearware_field(xml, "username"), "me@bearware.dk");
        assert_eq!(bearware_field(xml, "token"), "abc");
        assert_eq!(bearware_field("<teamtalk/>", "username"), "");
        assert_eq!(enc("a b&c"), "a%20b%26c");
    }
}
