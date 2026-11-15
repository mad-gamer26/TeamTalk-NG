//! Server administration as the desktop's Server menu has it: user
//! accounts, every server setting, saving the configuration, statistics,
//! and banning an address by hand.

use super::*;

pub(super) enum ServerRequest {
    ListAccounts(Sender<Result<Vec<UserAccount>>>),
    SaveAccount(Box<UserAccount>, Reply),
    DeleteAccount(String, Reply),
    Settings(Sender<Result<ServerSettings>>),
    UpdateSettings(Box<ServerSettings>, Reply),
    SaveConfig(Reply),
    Statistics(Sender<Result<ServerStatistics>>),
    BanAddress {
        address: String,
        channel_path: String,
        reply: Reply,
    },
    /// The desktop's "Ban Username" in Banned Users.
    BanUsername {
        username: String,
        channel_path: String,
        reply: Reply,
    },
}

impl ServerRequest {
    pub(super) fn fail(self, why: Error) {
        match self {
            ServerRequest::ListAccounts(r) => drop(r.send(Err(why))),
            ServerRequest::Settings(r) => drop(r.send(Err(why))),
            ServerRequest::Statistics(r) => drop(r.send(Err(why))),
            ServerRequest::SaveAccount(_, r)
            | ServerRequest::DeleteAccount(_, r)
            | ServerRequest::UpdateSettings(_, r)
            | ServerRequest::SaveConfig(r)
            | ServerRequest::BanAddress { reply: r, .. }
            | ServerRequest::BanUsername { reply: r, .. } => drop(r.send(Err(why))),
        }
    }
}

impl Worker {
    fn refused(&self, what: &str) -> Error {
        if self.logged_in() {
            Error::Refused(format!("{what} isn't possible right now."))
        } else {
            Error::NotConnected
        }
    }

    pub(super) fn handle_server(&mut self, req: ServerRequest) {
        match req {
            ServerRequest::ListAccounts(r) => {
                // SAFETY: inst is live.
                let cmd = unsafe { sys::TT_DoListUserAccounts(self.inst, 0, 100_000) };
                if cmd > 0 {
                    self.pending
                        .insert(cmd, (Pending::Accounts(Vec::new(), r), Instant::now()));
                } else {
                    let _ = r.send(Err(self.refused("Listing the accounts")));
                }
            }
            ServerRequest::SaveAccount(a, reply) => {
                let raw = a.to_sys();
                // SAFETY: inst is live; raw is a valid UserAccount.
                let cmd = unsafe { sys::TT_DoNewUserAccount(self.inst, &raw) };
                self.track(cmd, Pending::Reply(reply), "Saving the account");
            }
            ServerRequest::DeleteAccount(name, reply) => {
                let n = arg(&name);
                // SAFETY: inst is live; n outlives the call.
                let cmd = unsafe { sys::TT_DoDeleteUserAccount(self.inst, n.as_ptr()) };
                self.track(cmd, Pending::Reply(reply), "Deleting the account");
            }
            ServerRequest::Settings(r) => {
                let mut p = sys::ServerProperties::default();
                // SAFETY: inst is live; p is valid for the SDK to fill.
                let ok = unsafe { sys::TT_GetServerProperties(self.inst, &mut p) } != 0;
                let _ = r.send(if ok {
                    Ok(ServerSettings::from(&p))
                } else {
                    Err(Error::NotConnected)
                });
            }
            ServerRequest::UpdateSettings(s, reply) => {
                let mut p = sys::ServerProperties::default();
                // SAFETY: inst is live; p is valid for the SDK to fill.
                if unsafe { sys::TT_GetServerProperties(self.inst, &mut p) } == 0 {
                    let _ = reply.send(Err(Error::NotConnected));
                    return;
                }
                p.szServerName = to_tt(&s.name);
                p.szMOTDRaw = to_tt(&s.motd);
                p.nMaxUsers = s.max_users.max(1);
                p.nMaxLoginAttempts = s.max_login_attempts.max(0);
                p.nMaxLoginsPerIPAddress = s.max_logins_per_address.max(0);
                p.nLoginDelayMSec = s.login_delay_ms.max(0);
                p.nMaxVoiceTxPerSecond = s.voice_limit.max(0);
                p.nMaxVideoCaptureTxPerSecond = s.video_limit.max(0);
                p.nMaxMediaFileTxPerSecond = s.media_file_limit.max(0);
                p.nMaxDesktopTxPerSecond = s.desktop_limit.max(0);
                p.nMaxTotalTxPerSecond = s.total_limit.max(0);
                p.bAutoSave = s.auto_save as sys::TTBOOL;
                p.nTcpPort = s.tcp_port;
                p.nUdpPort = s.udp_port;
                p.nUserTimeout = s.user_timeout.max(1);
                p.uServerLogEvents = s.log_events;
                // SAFETY: inst is live; p is valid.
                let cmd = unsafe { sys::TT_DoUpdateServer(self.inst, &p) };
                self.track(cmd, Pending::Reply(reply), "Changing the server");
            }
            ServerRequest::SaveConfig(reply) => {
                // SAFETY: inst is live.
                let cmd = unsafe { sys::TT_DoSaveConfig(self.inst) };
                self.track(cmd, Pending::Reply(reply), "Saving the server's configuration");
            }
            ServerRequest::Statistics(r) => {
                // SAFETY: inst is live.
                let cmd = unsafe { sys::TT_DoQueryServerStats(self.inst) };
                if cmd > 0 {
                    self.pending.insert(cmd, (Pending::Stats(None, r), Instant::now()));
                } else {
                    let _ = r.send(Err(self.refused("Asking for statistics")));
                }
            }
            ServerRequest::BanAddress {
                address,
                channel_path,
                reply,
            } => {
                let b = sys::BannedUser {
                    szIPAddress: to_tt(address.trim()),
                    szChannelPath: to_tt(&channel_path),
                    uBanTypes: sys::BanType_BANTYPE_IPADDR
                        | if channel_path.is_empty() {
                            0
                        } else {
                            sys::BanType_BANTYPE_CHANNEL
                        },
                    ..Default::default()
                };
                // SAFETY: inst is live; b is a valid BannedUser.
                let cmd = unsafe { sys::TT_DoBan(self.inst, &b) };
                self.track(cmd, Pending::Reply(reply), "Banning that address");
            }
            ServerRequest::BanUsername {
                username,
                channel_path,
                reply,
            } => {
                let b = sys::BannedUser {
                    szUsername: to_tt(username.trim()),
                    szChannelPath: to_tt(&channel_path),
                    uBanTypes: sys::BanType_BANTYPE_USERNAME
                        | if channel_path.is_empty() {
                            0
                        } else {
                            sys::BanType_BANTYPE_CHANNEL
                        },
                    ..Default::default()
                };
                // SAFETY: inst is live; b is a valid BannedUser.
                let cmd = unsafe { sys::TT_DoBan(self.inst, &b) };
                self.track(cmd, Pending::Reply(reply), "Banning that username");
            }
        }
    }
}
