//! People: what I receive from them (subscriptions and intercepts), how I
//! hear them (volume, stereo, muting), channel operators, who may send in
//! classroom channels, channel bans, statistics, and relaying someone's
//! audio into my channel.

use super::*;

pub(super) enum PeopleRequest {
    Subscribe {
        user_id: i32,
        what: Subscription,
        on: bool,
    },
    MediaVolume {
        user_id: i32,
        percent: i32,
    },
    MediaMuted {
        user_id: i32,
        muted: bool,
    },
    Stereo {
        user_id: i32,
        stream: AudioStream,
        left: bool,
        right: bool,
    },
    MuteAll(bool),
    Operator {
        user_id: i32,
        channel_id: i32,
        password: String,
        on: bool,
    },
    Transmit {
        channel_id: i32,
        user_id: i32,
        stream: TransmitStream,
        allowed: bool,
    },
    ChannelBan {
        user_id: i32,
        kind: BanKind,
    },
    ListChannelBans(i32, Sender<Result<Vec<Ban>>>),
    Gender(Gender),
    Statistics(i32, Sender<Result<UserStatistics>>),
    Relay(Option<(i32, AudioStream)>),
}

impl PeopleRequest {
    /// Answers a request that carries its own channel (the SDK didn't start).
    pub(super) fn fail(self, why: Error) {
        match self {
            PeopleRequest::ListChannelBans(_, r) => {
                let _ = r.send(Err(why));
            }
            PeopleRequest::Statistics(_, r) => {
                let _ = r.send(Err(why));
            }
            _ => {}
        }
    }
}

fn percent_to_volume(percent: i32) -> i32 {
    crate::volume::level(percent)
}

impl Worker {
    pub(super) fn handle_people(&mut self, req: PeopleRequest, reply: Option<Reply>) {
        let answer = |r: Result<()>| {
            if let Some(reply) = &reply {
                let _ = reply.send(r);
            }
        };
        match req {
            PeopleRequest::Subscribe { user_id, what, on } => {
                // SAFETY: inst is live.
                let cmd = unsafe {
                    if on {
                        sys::TT_DoSubscribe(self.inst, user_id, what.bit())
                    } else {
                        sys::TT_DoUnsubscribe(self.inst, user_id, what.bit())
                    }
                };
                if let Some(r) = reply {
                    self.track(cmd, Pending::Refresh(user_id, r), "Changing that subscription");
                }
            }
            PeopleRequest::MediaVolume { user_id, percent } => {
                // SAFETY: inst is live.
                let ok = unsafe {
                    sys::TT_SetUserVolume(
                        self.inst,
                        user_id,
                        sys::StreamType_STREAMTYPE_MEDIAFILE_AUDIO,
                        percent_to_volume(percent),
                    )
                } != 0;
                self.refresh_user(user_id);
                answer(
                    ok.then_some(())
                        .ok_or_else(|| Error::Refused("That person's volume can't be set.".into())),
                );
            }
            PeopleRequest::MediaMuted { user_id, muted } => {
                // SAFETY: inst is live.
                let ok = unsafe {
                    sys::TT_SetUserMute(
                        self.inst,
                        user_id,
                        sys::StreamType_STREAMTYPE_MEDIAFILE_AUDIO,
                        muted as sys::TTBOOL,
                    )
                } != 0;
                self.refresh_user(user_id);
                answer(
                    ok.then_some(())
                        .ok_or_else(|| Error::Refused("That person can't be muted.".into())),
                );
            }
            PeopleRequest::Stereo {
                user_id,
                stream,
                left,
                right,
            } => {
                let st = match stream {
                    AudioStream::Voice => sys::StreamType_STREAMTYPE_VOICE,
                    AudioStream::MediaFile => sys::StreamType_STREAMTYPE_MEDIAFILE_AUDIO,
                };
                // SAFETY: inst is live.
                let ok =
                    unsafe { sys::TT_SetUserStereo(self.inst, user_id, st, left as sys::TTBOOL, right as sys::TTBOOL) }
                        != 0;
                self.refresh_user(user_id);
                answer(
                    ok.then_some(())
                        .ok_or_else(|| Error::Refused("That can't be set for them.".into())),
                );
            }
            PeopleRequest::MuteAll(on) => {
                // SAFETY: inst is live.
                let ok = unsafe { sys::TT_SetSoundOutputMute(self.inst, on as sys::TTBOOL) } != 0;
                if ok && let Ok(mut m) = self.model.lock() {
                    m.muted_all = on;
                }
                answer(
                    ok.then_some(())
                        .ok_or_else(|| Error::Refused("Sound isn't open.".into())),
                );
            }
            PeopleRequest::Operator {
                user_id,
                channel_id,
                password,
                on,
            } => {
                let pw = arg(&password);
                // SAFETY: inst is live; pw is NUL-terminated and outlives the call.
                let cmd =
                    unsafe { sys::TT_DoChannelOpEx(self.inst, user_id, channel_id, pw.as_ptr(), on as sys::TTBOOL) };
                if let Some(r) = reply {
                    self.track(cmd, Pending::Reply(r), "Changing operators");
                }
            }
            PeopleRequest::Transmit {
                channel_id,
                user_id,
                stream,
                allowed,
            } => {
                let mut c = sys::Channel::default();
                // SAFETY: inst is live; c is valid for the SDK to fill.
                if unsafe { sys::TT_GetChannel(self.inst, channel_id, &mut c) } == 0 {
                    return answer(Err(self.missing_channel()));
                }
                let who = if user_id == 0 {
                    sys::TT_TRANSMITUSERS_FREEFORALL as i32
                } else {
                    user_id
                };
                // A classroom channel lists who may send; any other channel
                // lists who may not (as the desktop's Transmit Control).
                let classroom = c.uChannelType & sys::ChannelType_CHANNEL_CLASSROOM != 0;
                if !classroom && user_id == 0 {
                    return answer(Err(Error::Refused(
                        "Allowing everyone is for classroom channels.".into(),
                    )));
                }
                let listed = if classroom { allowed } else { !allowed };
                let list = &mut c.transmitUsers;
                let at = list.iter().position(|e| e[0] == who);
                let bits = stream.bits() as i32;
                match (at, listed) {
                    (Some(i), true) => list[i][1] |= bits,
                    (Some(i), false) => {
                        list[i][1] &= !bits;
                        if list[i][1] == 0 {
                            // Close the gap: the list ends at the first empty entry.
                            for j in i..list.len() - 1 {
                                list[j] = list[j + 1];
                            }
                            list[list.len() - 1] = [0, 0];
                        }
                    }
                    (None, true) => match list.iter().position(|e| e[0] == 0) {
                        Some(free) => list[free] = [who, bits],
                        None => {
                            return answer(Err(Error::Refused(
                                "The channel's list of people who may talk is full.".into(),
                            )));
                        }
                    },
                    (None, false) => return answer(Ok(())),
                }
                // SAFETY: inst is live; c is a valid Channel.
                let cmd = unsafe { sys::TT_DoUpdateChannel(self.inst, &c) };
                if let Some(r) = reply {
                    self.track(cmd, Pending::Reply(r), "Changing who may talk");
                }
            }
            PeopleRequest::ChannelBan { user_id, kind } => {
                let types = sys::BanType_BANTYPE_CHANNEL
                    | match kind {
                        BanKind::IpAddress => sys::BanType_BANTYPE_IPADDR,
                        BanKind::Username => sys::BanType_BANTYPE_USERNAME,
                    };
                // SAFETY: inst is live.
                let cmd = unsafe { sys::TT_DoBanUserEx(self.inst, user_id, types) };
                if let Some(r) = reply {
                    self.track(cmd, Pending::Reply(r), "Banning from the channel");
                }
            }
            PeopleRequest::ListChannelBans(channel_id, r) => {
                // SAFETY: inst is live.
                let cmd = unsafe { sys::TT_DoListBans(self.inst, channel_id, 0, 100_000) };
                if cmd > 0 {
                    self.pending.insert(cmd, (Pending::Bans(Vec::new(), r), Instant::now()));
                } else {
                    let _ = r.send(Err(if self.logged_in() {
                        Error::Refused("That channel's bans can't be listed.".into())
                    } else {
                        Error::NotConnected
                    }));
                }
            }
            PeopleRequest::Gender(g) => {
                let (mode, message) = self.my_status();
                let raw = (mode & !(0x100 | 0x1000)) | g.bits();
                let cmd = self.change_status(raw, &message);
                if let Some(r) = reply {
                    self.track(cmd, Pending::Reply(r), "Changing the gender");
                }
            }
            PeopleRequest::Statistics(user_id, r) => {
                let mut st = sys::UserStatistics::default();
                // SAFETY: inst is live; st is valid for the SDK to fill.
                let ok = unsafe { sys::TT_GetUserStatistics(self.inst, user_id, &mut st) } != 0;
                let _ = r.send(if ok {
                    Ok(UserStatistics {
                        voice_packets_received: st.nVoicePacketsRecv,
                        voice_packets_lost: st.nVoicePacketsLost,
                        media_audio_packets_received: st.nMediaFileAudioPacketsRecv,
                        media_audio_packets_lost: st.nMediaFileAudioPacketsLost,
                        video_packets_received: st.nVideoCapturePacketsRecv,
                        video_frames_received: st.nVideoCaptureFramesRecv,
                        video_frames_lost: st.nVideoCaptureFramesLost,
                    })
                } else {
                    Err(Error::Refused("There are no statistics for them.".into()))
                });
            }
            PeopleRequest::Relay(who) => answer(self.relay(who)),
        }
    }

    /// My status mode (with its flags) and message, as the server has them.
    pub(super) fn my_status(&self) -> (i32, String) {
        if let Some(s) = &self.status_sent {
            return s.clone();
        }
        self.model
            .lock()
            .ok()
            .and_then(|m| {
                m.users
                    .get(&m.my_user_id)
                    .map(|u| (u.status_raw, u.status_message.clone()))
            })
            .unwrap_or((0, String::new()))
    }

    /// Changes my status (mode bits and message), remembered as sent.
    pub(super) fn change_status(&mut self, raw: i32, message: &str) -> i32 {
        let msg = arg(message);
        // SAFETY: inst is live; msg is NUL-terminated and outlives the call.
        let cmd = unsafe { sys::TT_DoChangeStatus(self.inst, raw, msg.as_ptr()) };
        if cmd > 0 {
            self.status_sent = Some((raw, message.to_owned()));
        }
        cmd
    }

    /// The person with their operator flag (for their channel).
    pub(super) fn with_operator(&self, mut u: User) -> User {
        // SAFETY: inst is live.
        u.operator = u.channel_id > 0 && unsafe { sys::TT_IsChannelOperator(self.inst, u.id, u.channel_id) } != 0;
        u
    }

    /// Re-reads someone from the SDK after a local change (volume, stereo,
    /// subscriptions), and tells the app.
    pub(super) fn refresh_user(&self, user_id: i32) {
        let mut raw = sys::User::default();
        // SAFETY: inst is live; raw is valid for the SDK to fill.
        if unsafe { sys::TT_GetUser(self.inst, user_id, &mut raw) } == 0 {
            return;
        }
        let u = self.with_operator(User::from(&raw));
        if let Ok(mut m) = self.model.lock() {
            m.users.insert(u.id, u.clone());
        }
        self.emit(Event::UserUpdated(u));
    }

    /// A channel changed: its people's operator flags may have.
    pub(super) fn refresh_operators(&self, channel_id: i32) {
        let people: Vec<User> = self
            .model
            .lock()
            .map(|m| {
                m.users
                    .values()
                    .filter(|u| u.channel_id == channel_id)
                    .cloned()
                    .collect()
            })
            .unwrap_or_default();
        for u in people {
            let was = u.operator;
            let now = self.with_operator(u);
            if now.operator != was {
                if let Ok(mut m) = self.model.lock() {
                    m.users.insert(now.id, now.clone());
                }
                self.emit(Event::UserUpdated(now));
            }
        }
    }

    /// Starts (or stops, with None) sending someone's audio into my channel.
    fn relay(&mut self, who: Option<(i32, AudioStream)>) -> Result<()> {
        let st = |s: AudioStream| match s {
            AudioStream::Voice => sys::StreamType_STREAMTYPE_VOICE,
            AudioStream::MediaFile => sys::StreamType_STREAMTYPE_MEDIAFILE_AUDIO,
        };
        let before = self.model.lock().ok().and_then(|m| m.relaying);
        if let Some((user, stream)) = before {
            // SAFETY: inst is live; a null block ends the inserted audio.
            unsafe {
                sys::TT_EnableAudioBlockEvent(self.inst, user, st(stream), 0);
                sys::TT_InsertAudioBlock(self.inst, ptr::null());
            }
        }
        if let Ok(mut m) = self.model.lock() {
            m.relaying = None;
        }
        let Some((user, stream)) = who else { return Ok(()) };
        if !self.audio_open {
            return Err(Error::Refused("Open the sound devices first.".into()));
        }
        // SAFETY: inst is live.
        if unsafe { sys::TT_EnableAudioBlockEvent(self.inst, user, st(stream), 1) } == 0 {
            return Err(Error::Refused("Their audio can't be relayed.".into()));
        }
        if let Ok(mut m) = self.model.lock() {
            m.relaying = Some((user, stream));
        }
        Ok(())
    }

    /// An audio block of the relayed person: into my channel it goes.
    pub(super) fn on_audio_block(&mut self, user_id: i32, stream: u32) {
        // SAFETY: inst is live; the block is released below.
        let block = unsafe { sys::TT_AcquireUserAudioBlock(self.inst, stream, user_id) };
        if block.is_null() {
            return;
        }
        // SAFETY: block is a live audio block from the SDK.
        unsafe {
            sys::TT_InsertAudioBlock(self.inst, block);
            sys::TT_ReleaseUserAudioBlock(self.inst, block);
        }
    }
}
