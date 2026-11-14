//! A connection to one TeamTalk server.
//!
//! One thread owns the SDK instance and makes every SDK call: it pumps the
//! SDK's messages, keeps the model up to date and reconnects. `Client`'s
//! methods send it requests and wait for the answer (a server command waits
//! for the server's reply to that command). Events reach the listener on a
//! separate thread, in order, so a listener may call the client.

use std::collections::HashMap;
use std::ptr;
use std::sync::mpsc::{self, Receiver, RecvTimeoutError, Sender};
use std::sync::{Arc, Mutex};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

use ttng_sys as sys;

mod channels;
mod people;
use channels::ChannelRequest;
pub use channels::media_file_info;
use people::PeopleRequest;

use crate::error::{Error, Result};
use crate::model::*;
use crate::text::{arg, from_tt, split_message, to_tt};

/// How long a call waits for the server's answer.
const ANSWER_TIMEOUT: Duration = Duration::from_secs(20);
/// How long the SDK thread waits for a message before checking for requests.
const PUMP_MS: i32 = 20;
/// How often transfers report progress.
const PROGRESS_EVERY: Duration = Duration::from_millis(250);
/// The longest wait between reconnection attempts.
const MAX_BACKOFF: Duration = Duration::from_secs(30);

/// Where to connect, and as whom.
#[derive(Clone, Debug)]
pub struct ConnectOptions {
    pub host: String,
    pub tcp_port: u16,
    pub udp_port: u16,
    pub encrypted: bool,
    pub nickname: String,
    pub username: String,
    pub password: String,
    /// What other clients see as this client's name.
    pub client_name: String,
    /// A channel to join after logging in: its path ("/Lobby/") and password.
    pub join_channel: Option<(String, String)>,
    /// Reconnect (and rejoin the channel) when the connection drops.
    pub reconnect: bool,
}

/// Which sound devices to use.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum AudioDevices {
    /// The system's default input and output.
    Default,
    /// The default devices, shared with other connections (several servers
    /// at once; each `Client` opens them in this mode).
    Shared,
    /// The SDK's virtual device: no hardware (tests, and listening without
    /// a microphone).
    Virtual,
}

/// Receives events (on the client's event thread, one at a time, in order).
pub trait EventListener: Send + Sync + 'static {
    fn on_event(&self, event: Event);
}

impl<F: Fn(Event) + Send + Sync + 'static> EventListener for F {
    fn on_event(&self, event: Event) {
        self(event)
    }
}

type Reply = Sender<Result<()>>;

enum Request {
    Connect(Box<ConnectOptions>, Reply),
    Disconnect(Reply),
    JoinChannel {
        id: i32,
        password: String,
        reply: Reply,
    },
    JoinPath {
        path: String,
        password: String,
        reply: Reply,
    },
    LeaveChannel(Reply),
    SendMessage {
        target: MessageTarget,
        text: String,
        reply: Reply,
    },
    SetStatus {
        mode: StatusMode,
        message: String,
        reply: Reply,
    },
    SetNickname(String, Reply),
    InitAudio(AudioDevices, Reply),
    SetTransmitting(bool, Reply),
    SetVoiceActivation {
        on: bool,
        level: i32,
        stop_delay_ms: i32,
        reply: Reply,
    },
    SetUserVolume {
        user_id: i32,
        volume: i32,
        reply: Reply,
    },
    SetUserMuted {
        user_id: i32,
        muted: bool,
        reply: Reply,
    },
    TestTone(i32, Reply),
    Upload {
        channel_id: i32,
        path: String,
        reply: Reply,
    },
    Download {
        channel_id: i32,
        file_id: i32,
        path: String,
        reply: Reply,
    },
    DeleteFile {
        channel_id: i32,
        file_id: i32,
        reply: Reply,
    },
    CancelTransfer(i32, Reply),
    Kick {
        user_id: i32,
        from_channel: bool,
        reply: Reply,
    },
    BanUser {
        user_id: i32,
        kind: BanKind,
        reply: Reply,
    },
    ListBans(Sender<Result<Vec<Ban>>>),
    Unban(Box<Ban>, Reply),
    MoveUser {
        user_id: i32,
        channel_id: i32,
        reply: Reply,
    },
    MakeChannel {
        spec: Box<ChannelSpec>,
        join: bool,
        reply: Reply,
    },
    UpdateChannel {
        id: i32,
        spec: Box<ChannelSpec>,
        reply: Reply,
    },
    RemoveChannel(i32, Reply),
    UpdateServer {
        name: String,
        motd: String,
        reply: Reply,
    },
    StartRecording {
        path: String,
        format: RecordingFormat,
        reply: Reply,
    },
    StopRecording(Reply),
    /// Channels (see channels.rs).
    Channels(ChannelRequest, Reply),
    /// People (see people.rs); `None` when the request answers itself.
    People(PeopleRequest, Option<Reply>),
    Quit,
}

/// The model, shared with `Client::snapshot` (the SDK thread writes it).
#[derive(Default)]
struct Model {
    state: Option<ConnectionState>,
    server: ServerInfo,
    my_user_id: i32,
    my_channel_id: i32,
    my_rights: MyRights,
    channels: HashMap<i32, Channel>,
    users: HashMap<i32, User>,
    files: HashMap<i32, RemoteFile>,
    transfers: HashMap<i32, Transfer>,
    /// The channel being recorded, and the file.
    recording: Option<(i32, String)>,
    muted_all: bool,
    relaying: Option<(i32, AudioStream)>,
    streaming: Option<MediaStream>,
}

/// A connection to one TeamTalk server. Dropping it disconnects.
pub struct Client {
    tx: Sender<Request>,
    model: Arc<Mutex<Model>>,
    level: Arc<std::sync::atomic::AtomicI32>,
    worker: Option<JoinHandle<()>>,
}

impl std::fmt::Debug for Client {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Client").finish_non_exhaustive()
    }
}

impl Client {
    /// A client, not connected yet. `listener` gets every event.
    pub fn new(listener: impl EventListener) -> Client {
        let (tx, rx) = mpsc::channel();
        let (etx, erx) = mpsc::channel::<Event>();
        let model = Arc::new(Mutex::new(Model {
            state: Some(ConnectionState::Disconnected),
            ..Default::default()
        }));
        let listener = Arc::new(listener);
        thread::Builder::new()
            .name("ttng-events".into())
            .spawn(move || {
                for e in erx {
                    listener.on_event(e);
                }
            })
            .expect("can't start the event thread");
        let m = Arc::clone(&model);
        let level = Arc::new(std::sync::atomic::AtomicI32::new(0));
        let l = Arc::clone(&level);
        let worker = thread::Builder::new()
            .name("ttng-sdk".into())
            .spawn(move || Worker::new(rx, etx, m, l).run())
            .expect("can't start the SDK thread");
        Client {
            tx,
            model,
            level,
            worker: Some(worker),
        }
    }

    fn ask(&self, make: impl FnOnce(Reply) -> Request) -> Result<()> {
        let (rtx, rrx) = mpsc::channel();
        self.tx.send(make(rtx)).map_err(|_| Error::NotConnected)?;
        match rrx.recv_timeout(ANSWER_TIMEOUT) {
            Ok(r) => r,
            Err(RecvTimeoutError::Timeout) => Err(Error::Timeout),
            Err(RecvTimeoutError::Disconnected) => Err(Error::NotConnected),
        }
    }

    /// Connects and logs in; returns once logged in (and in the channel to
    /// join, if any), or with why not.
    pub fn connect(&self, options: ConnectOptions) -> Result<()> {
        self.ask(|r| Request::Connect(Box::new(options), r))
    }

    pub fn disconnect(&self) -> Result<()> {
        self.ask(Request::Disconnect)
    }

    pub fn join_channel(&self, id: i32, password: &str) -> Result<()> {
        self.ask(|reply| Request::JoinChannel {
            id,
            password: password.into(),
            reply,
        })
    }

    /// Joins a channel by its path ("/Lobby/Music/").
    pub fn join_channel_path(&self, path: &str, password: &str) -> Result<()> {
        self.ask(|reply| Request::JoinPath {
            path: path.into(),
            password: password.into(),
            reply,
        })
    }

    pub fn leave_channel(&self) -> Result<()> {
        self.ask(Request::LeaveChannel)
    }

    /// Sends a text message (long ones as several parts, joined again by
    /// TeamTalk clients).
    pub fn send_message(&self, target: MessageTarget, text: &str) -> Result<()> {
        self.ask(|reply| Request::SendMessage {
            target,
            text: text.into(),
            reply,
        })
    }

    pub fn set_status(&self, mode: StatusMode, message: &str) -> Result<()> {
        self.ask(|reply| Request::SetStatus {
            mode,
            message: message.into(),
            reply,
        })
    }

    pub fn set_nickname(&self, nickname: &str) -> Result<()> {
        self.ask(|r| Request::SetNickname(nickname.into(), r))
    }

    /// Opens the sound devices (needed to hear and talk).
    pub fn init_audio(&self, devices: AudioDevices) -> Result<()> {
        self.ask(|r| Request::InitAudio(devices, r))
    }

    /// Starts or stops sending my voice (push to talk).
    pub fn set_transmitting(&self, on: bool) -> Result<()> {
        self.ask(|r| Request::SetTransmitting(on, r))
    }

    /// Voice activation: talks while the microphone's level (0 to 100) is at
    /// or above `level`, and for `stop_delay_ms` after it drops. Turning it
    /// on may send for about `stop_delay_ms` even in silence (the SDK can
    /// start it active).
    pub fn set_voice_activation(&self, on: bool, level: i32, stop_delay_ms: i32) -> Result<()> {
        self.ask(|reply| Request::SetVoiceActivation {
            on,
            level,
            stop_delay_ms,
            reply,
        })
    }

    /// Someone's volume for me only, in percent: 100 is as they send it, up
    /// to 400.
    pub fn set_user_volume(&self, user_id: i32, percent: i32) -> Result<()> {
        let volume = (percent.clamp(0, 400) * sys::SoundLevel_SOUND_VOLUME_DEFAULT as i32) / 100;
        self.ask(|reply| Request::SetUserVolume { user_id, volume, reply })
    }

    /// The microphone's level right now, 0 to 100 (for a meter, and for
    /// choosing a voice activation level).
    pub fn input_level(&self) -> i32 {
        self.level.load(std::sync::atomic::Ordering::Relaxed)
    }

    /// Mutes someone for me only.
    pub fn set_user_muted(&self, user_id: i32, muted: bool) -> Result<()> {
        self.ask(|reply| Request::SetUserMuted { user_id, muted, reply })
    }

    /// Replaces the microphone with a tone (`hz`; 0 turns it off). For tests
    /// and checking a connection without speaking.
    pub fn set_test_tone(&self, hz: i32) -> Result<()> {
        self.ask(|r| Request::TestTone(hz, r))
    }

    /// Uploads a file on this device to a channel's files. Returns once the
    /// server accepts it; the transfer itself is reported in
    /// `Event::TransferChanged`.
    pub fn upload_file(&self, channel_id: i32, local_path: &str) -> Result<()> {
        self.ask(|reply| Request::Upload {
            channel_id,
            path: local_path.into(),
            reply,
        })
    }

    /// Downloads a channel's file to `local_path` (replacing what's there).
    /// Returns once the server accepts; progress in `Event::TransferChanged`.
    pub fn download_file(&self, channel_id: i32, file_id: i32, local_path: &str) -> Result<()> {
        self.ask(|reply| Request::Download {
            channel_id,
            file_id,
            path: local_path.into(),
            reply,
        })
    }

    pub fn delete_file(&self, channel_id: i32, file_id: i32) -> Result<()> {
        self.ask(|reply| Request::DeleteFile {
            channel_id,
            file_id,
            reply,
        })
    }

    /// Stops an upload or download (a partial download is left behind).
    pub fn cancel_transfer(&self, transfer_id: i32) -> Result<()> {
        self.ask(|r| Request::CancelTransfer(transfer_id, r))
    }

    /// Kicks someone out of their channel, or (`from_channel` false) off the
    /// server.
    pub fn kick_user(&self, user_id: i32, from_channel: bool) -> Result<()> {
        self.ask(|reply| Request::Kick {
            user_id,
            from_channel,
            reply,
        })
    }

    /// Bans someone from the server (kick them too, or they stay until they
    /// leave).
    pub fn ban_user(&self, user_id: i32, kind: BanKind) -> Result<()> {
        self.ask(|reply| Request::BanUser { user_id, kind, reply })
    }

    /// The server's bans.
    pub fn list_bans(&self) -> Result<Vec<Ban>> {
        let (rtx, rrx) = mpsc::channel();
        self.tx.send(Request::ListBans(rtx)).map_err(|_| Error::NotConnected)?;
        match rrx.recv_timeout(ANSWER_TIMEOUT) {
            Ok(r) => r,
            Err(RecvTimeoutError::Timeout) => Err(Error::Timeout),
            Err(RecvTimeoutError::Disconnected) => Err(Error::NotConnected),
        }
    }

    pub fn unban(&self, ban: &Ban) -> Result<()> {
        self.ask(|r| Request::Unban(Box::new(ban.clone()), r))
    }

    /// Moves someone into a channel.
    pub fn move_user(&self, user_id: i32, channel_id: i32) -> Result<()> {
        self.ask(|reply| Request::MoveUser {
            user_id,
            channel_id,
            reply,
        })
    }

    /// Makes a channel (needs the right to modify channels), with the
    /// parent channel's audio settings.
    pub fn make_channel(&self, spec: &ChannelSpec) -> Result<()> {
        self.ask(|reply| Request::MakeChannel {
            spec: Box::new(spec.clone()),
            join: false,
            reply,
        })
    }

    /// Makes a temporary channel and joins it (it goes when the last person
    /// leaves); for people who may make temporary channels.
    pub fn join_new_channel(&self, spec: &ChannelSpec) -> Result<()> {
        self.ask(|reply| Request::MakeChannel {
            spec: Box::new(ChannelSpec {
                permanent: false,
                ..spec.clone()
            }),
            join: true,
            reply,
        })
    }

    /// Changes a channel's settings (name, topic, password, flags).
    pub fn update_channel(&self, id: i32, spec: &ChannelSpec) -> Result<()> {
        self.ask(|reply| Request::UpdateChannel {
            id,
            spec: Box::new(spec.clone()),
            reply,
        })
    }

    pub fn remove_channel(&self, id: i32) -> Result<()> {
        self.ask(|r| Request::RemoveChannel(id, r))
    }

    /// Changes the server's name and message of the day.
    pub fn update_server(&self, name: &str, motd: &str) -> Result<()> {
        self.ask(|reply| Request::UpdateServer {
            name: name.into(),
            motd: motd.into(),
            reply,
        })
    }

    /// Records my channel's voices (mine included) to `path`, until
    /// stopped or I leave the channel.
    pub fn start_recording(&self, path: &str, format: RecordingFormat) -> Result<()> {
        self.ask(|reply| Request::StartRecording {
            path: path.into(),
            format,
            reply,
        })
    }

    pub fn stop_recording(&self) -> Result<()> {
        self.ask(Request::StopRecording)
    }

    fn people(&self, req: PeopleRequest) -> Result<()> {
        self.ask(|r| Request::People(req, Some(r)))
    }

    /// Receive (or stop receiving) one kind of thing from someone. The
    /// intercepts (admins) get theirs even outside my channel.
    pub fn set_subscription(&self, user_id: i32, what: Subscription, on: bool) -> Result<()> {
        self.people(PeopleRequest::Subscribe { user_id, what, on })
    }

    /// Hear my own voice (as the others do).
    pub fn set_hear_myself(&self, on: bool) -> Result<()> {
        let me = self.snapshot().my_user_id;
        if me == 0 {
            return Err(Error::NotConnected);
        }
        self.set_subscription(me, Subscription::Voice, on)
    }

    /// Someone's media file volume for me, in percent (up to 400).
    pub fn set_user_media_volume(&self, user_id: i32, percent: i32) -> Result<()> {
        self.people(PeopleRequest::MediaVolume { user_id, percent })
    }

    pub fn set_user_media_muted(&self, user_id: i32, muted: bool) -> Result<()> {
        self.people(PeopleRequest::MediaMuted { user_id, muted })
    }

    /// Which of my speakers play someone's voice or media.
    pub fn set_user_stereo(&self, user_id: i32, stream: AudioStream, left: bool, right: bool) -> Result<()> {
        self.people(PeopleRequest::Stereo {
            user_id,
            stream,
            left,
            right,
        })
    }

    /// Mutes everyone, for me.
    pub fn set_mute_all(&self, on: bool) -> Result<()> {
        self.people(PeopleRequest::MuteAll(on))
    }

    /// Makes someone a channel operator, or not. `password`: the channel's
    /// operator password, for those who aren't allowed otherwise.
    pub fn set_operator(&self, user_id: i32, channel_id: i32, password: &str, on: bool) -> Result<()> {
        self.people(PeopleRequest::Operator {
            user_id,
            channel_id,
            password: password.into(),
            on,
        })
    }

    /// In a classroom channel: whether someone (`user_id` 0: everyone) may
    /// send a kind of stream.
    pub fn set_transmit_allowed(
        &self,
        channel_id: i32,
        user_id: i32,
        stream: TransmitStream,
        allowed: bool,
    ) -> Result<()> {
        self.people(PeopleRequest::Transmit {
            channel_id,
            user_id,
            stream,
            allowed,
        })
    }

    /// Bans someone from their channel (kick them from it too).
    pub fn ban_from_channel(&self, user_id: i32, kind: BanKind) -> Result<()> {
        self.people(PeopleRequest::ChannelBan { user_id, kind })
    }

    /// A channel's bans.
    pub fn list_channel_bans(&self, channel_id: i32) -> Result<Vec<Ban>> {
        let (rtx, rrx) = mpsc::channel();
        self.tx
            .send(Request::People(PeopleRequest::ListChannelBans(channel_id, rtx), None))
            .map_err(|_| Error::NotConnected)?;
        rrx.recv_timeout(ANSWER_TIMEOUT).unwrap_or(Err(Error::Timeout))
    }

    pub fn set_gender(&self, gender: Gender) -> Result<()> {
        self.people(PeopleRequest::Gender(gender))
    }

    /// How someone's audio and video arrive.
    pub fn user_statistics(&self, user_id: i32) -> Result<UserStatistics> {
        let (rtx, rrx) = mpsc::channel();
        self.tx
            .send(Request::People(PeopleRequest::Statistics(user_id, rtx), None))
            .map_err(|_| Error::NotConnected)?;
        rrx.recv_timeout(ANSWER_TIMEOUT).unwrap_or(Err(Error::Timeout))
    }

    /// Sends someone's voice or media (from any channel I hear them in)
    /// into my channel; `None` stops.
    pub fn set_relay(&self, who: Option<(i32, AudioStream)>) -> Result<()> {
        self.people(PeopleRequest::Relay(who))
    }

    /// Joins a channel by its path, hidden ones included (they're known
    /// by name only).
    pub fn join_hidden_channel(&self, path: &str, password: &str) -> Result<()> {
        self.ask(|r| {
            Request::Channels(
                ChannelRequest::JoinHidden {
                    path: path.into(),
                    password: password.into(),
                },
                r,
            )
        })
    }

    /// Streams a media file (audio or video) to my channel, from
    /// `offset_ms`; `looping` starts it again when it ends.
    pub fn stream_media_file(&self, path: &str, offset_ms: u32, paused: bool, looping: bool) -> Result<()> {
        self.ask(|r| {
            Request::Channels(
                ChannelRequest::Stream {
                    path: path.into(),
                    offset_ms,
                    paused,
                    looping,
                },
                r,
            )
        })
    }

    /// Pauses or resumes the stream, and moves it (`offset_ms`).
    pub fn update_stream(&self, offset_ms: Option<u32>, paused: bool) -> Result<()> {
        self.ask(|r| Request::Channels(ChannelRequest::UpdateStream { offset_ms, paused }, r))
    }

    pub fn stop_stream(&self) -> Result<()> {
        self.ask(|r| Request::Channels(ChannelRequest::StopStream, r))
    }

    /// Everything known right now.
    pub fn snapshot(&self) -> Snapshot {
        let m = self.model.lock().unwrap_or_else(|e| e.into_inner());
        let mut channels: Vec<Channel> = m.channels.values().cloned().collect();
        channels.sort_by_key(|c| c.id);
        let mut users: Vec<User> = m.users.values().cloned().collect();
        users.sort_by_key(|u| u.id);
        let mut files: Vec<RemoteFile> = m.files.values().cloned().collect();
        files.sort_by_key(|f| f.id);
        let mut transfers: Vec<Transfer> = m.transfers.values().cloned().collect();
        transfers.sort_by_key(|t| t.id);
        Snapshot {
            state: m.state.clone(),
            server: m.server.clone(),
            my_user_id: m.my_user_id,
            my_channel_id: m.my_channel_id,
            my_rights: m.my_rights,
            channels,
            users,
            files,
            transfers,
            recording_path: m.recording.as_ref().map(|(_, p)| p.clone()).unwrap_or_default(),
            muted_all: m.muted_all,
            streaming: m.streaming.clone(),
            relaying: m.relaying,
        }
    }
}

impl Drop for Client {
    fn drop(&mut self) {
        let _ = self.tx.send(Request::Quit);
        if let Some(w) = self.worker.take() {
            let _ = w.join();
        }
    }
}

/// What a pending server command is for.
enum Pending {
    /// Someone waits for the answer.
    Reply(Reply),
    /// The login of a connection attempt.
    Login,
    /// The rejoin after reconnecting.
    Rejoin,
    /// An earlier part of a long message (only the last part answers).
    Part,
    /// A ban list being collected.
    Bans(Vec<Ban>, Sender<Result<Vec<Ban>>>),
    /// Someone waits, and the person changed (re-read them after).
    Refresh(i32, Reply),
}

/// A connection being made: who asked (if anyone is waiting), and what for.
struct Attempt {
    reply: Option<Reply>,
}

struct Worker {
    inst: *mut sys::TTInstance,
    rx: Receiver<Request>,
    events: Sender<Event>,
    model: Arc<Mutex<Model>>,
    pending: HashMap<i32, (Pending, Instant)>,
    options: Option<ConnectOptions>,
    attempt: Option<Attempt>,
    /// The channel to rejoin after reconnecting (path, password).
    rejoin: Option<(String, String)>,
    retry: Option<(Instant, u32)>,
    /// Long incoming messages being joined, by (type, from, channel).
    partial: HashMap<(u32, i32, i32), String>,
    /// Set when the server kicked or logged us out (don't reconnect).
    no_reconnect: bool,
    /// The microphone's level, refreshed while the sound devices are open.
    level: Arc<std::sync::atomic::AtomicI32>,
    audio_open: bool,
    last_level: Instant,
    last_progress: Instant,
    last_stream_note: Instant,
}

impl Worker {
    fn new(
        rx: Receiver<Request>,
        events: Sender<Event>,
        model: Arc<Mutex<Model>>,
        level: Arc<std::sync::atomic::AtomicI32>,
    ) -> Worker {
        // SAFETY: creates an SDK instance; it's used and closed on this thread only.
        let inst = unsafe { sys::TT_InitTeamTalkPoll() };
        Worker {
            inst,
            rx,
            events,
            model,
            pending: HashMap::new(),
            options: None,
            attempt: None,
            rejoin: None,
            retry: None,
            partial: HashMap::new(),
            no_reconnect: false,
            level,
            audio_open: false,
            last_level: Instant::now(),
            last_progress: Instant::now(),
            last_stream_note: Instant::now(),
        }
    }

    fn run(mut self) {
        if self.inst.is_null() {
            // Every request is answered with the reason.
            for req in self.rx.iter() {
                if let Some(reply) = reply_of(req) {
                    let _ = reply.send(Err(Error::Refused("The TeamTalk SDK couldn't start.".into())));
                }
            }
            return;
        }
        loop {
            loop {
                match self.rx.try_recv() {
                    Ok(Request::Quit) => return self.close(),
                    Ok(req) => self.handle(req),
                    Err(mpsc::TryRecvError::Empty) => break,
                    Err(mpsc::TryRecvError::Disconnected) => return self.close(),
                }
            }
            if let Some((at, n)) = self.retry
                && Instant::now() >= at
            {
                self.retry = None;
                self.start_connect(n);
            }
            self.expire_pending();
            if self.audio_open && self.last_level.elapsed() >= Duration::from_millis(50) {
                self.last_level = Instant::now();
                // SAFETY: inst is live.
                let l = unsafe { sys::TT_GetSoundInputLevel(self.inst) };
                self.level.store(l, std::sync::atomic::Ordering::Relaxed);
            }
            if self.last_progress.elapsed() >= PROGRESS_EVERY {
                self.last_progress = Instant::now();
                self.poll_transfers();
            }
            let mut msg = sys::TTMessage::default();
            // SAFETY: inst is live; msg is a valid TTMessage for the SDK to fill.
            let got = unsafe { sys::TT_GetMessage(self.inst, &mut msg, &PUMP_MS) } != 0;
            if got {
                self.on_message(&msg);
            }
        }
    }

    fn close(&mut self) {
        // SAFETY: inst is live and not used after this.
        unsafe {
            sys::TT_Disconnect(self.inst);
            sys::TT_CloseTeamTalk(self.inst);
        }
        self.inst = ptr::null_mut();
    }

    fn emit(&self, e: Event) {
        let _ = self.events.send(e);
    }

    fn set_state(&self, s: ConnectionState) {
        let mut m = self.model.lock().unwrap_or_else(|e| e.into_inner());
        if m.state.as_ref() == Some(&s) {
            return;
        }
        m.state = Some(s.clone());
        drop(m);
        self.emit(Event::ConnectionChanged(s));
    }

    fn logged_in(&self) -> bool {
        self.model
            .lock()
            .map(|m| m.state == Some(ConnectionState::LoggedIn))
            .unwrap_or(false)
    }

    /// Records a command the server will answer (`id` > 0), or answers at
    /// once that the SDK refused it.
    fn track(&mut self, id: i32, p: Pending, what: &str) {
        if id > 0 {
            self.pending.insert(id, (p, Instant::now()));
        } else if let Pending::Reply(r) | Pending::Refresh(_, r) = p {
            let e = if self.logged_in() {
                Error::Refused(format!("{what} isn't possible right now."))
            } else {
                Error::NotConnected
            };
            let _ = r.send(Err(e));
        }
    }

    fn expire_pending(&mut self) {
        let old: Vec<i32> = self
            .pending
            .iter()
            .filter(|(_, (_, at))| at.elapsed() > ANSWER_TIMEOUT + Duration::from_secs(10))
            .map(|(id, _)| *id)
            .collect();
        for id in old {
            if let Some((Pending::Reply(r), _)) = self.pending.remove(&id) {
                let _ = r.send(Err(Error::Timeout));
            }
        }
    }

    fn handle(&mut self, req: Request) {
        match req {
            Request::Connect(opts, reply) => {
                // SAFETY: inst is live.
                unsafe { sys::TT_Disconnect(self.inst) };
                self.clear_model();
                self.no_reconnect = false;
                self.retry = None;
                self.rejoin = opts.join_channel.clone();
                self.options = Some(*opts);
                self.attempt = Some(Attempt { reply: Some(reply) });
                self.start_connect(0);
            }
            Request::Disconnect(reply) => {
                self.options = None;
                self.retry = None;
                self.rejoin = None;
                // SAFETY: inst is live.
                unsafe { sys::TT_Disconnect(self.inst) };
                self.fail_attempt(Error::Connection("Disconnected.".into()));
                self.clear_model();
                self.set_state(ConnectionState::Disconnected);
                let _ = reply.send(Ok(()));
            }
            Request::JoinChannel { id, password, reply } => {
                let pw = arg(&password);
                // SAFETY: inst is live; pw is NUL-terminated and outlives the call.
                let cmd = unsafe { sys::TT_DoJoinChannelByID(self.inst, id, pw.as_ptr()) };
                self.track(cmd, Pending::Reply(reply), "Joining that channel");
            }
            Request::JoinPath { path, password, reply } => match self.channel_id(&path) {
                Some(id) => self.handle(Request::JoinChannel { id, password, reply }),
                None => {
                    let _ = reply.send(Err(Error::Refused(format!("There's no channel {path}."))));
                }
            },
            Request::LeaveChannel(reply) => {
                // SAFETY: inst is live.
                let cmd = unsafe { sys::TT_DoLeaveChannel(self.inst) };
                self.track(cmd, Pending::Reply(reply), "Leaving the channel");
            }
            Request::SendMessage { target, text, reply } => self.send_message(target, &text, reply),
            Request::SetStatus { mode, message, reply } => {
                let msg = arg(&message);
                // The mode changes; the flags (gender, streaming…) stay.
                let raw = (self.my_status().0 & !0xff) | mode.raw();
                // SAFETY: inst is live; msg is NUL-terminated and outlives the call.
                let cmd = unsafe { sys::TT_DoChangeStatus(self.inst, raw, msg.as_ptr()) };
                self.track(cmd, Pending::Reply(reply), "Changing the status");
            }
            Request::SetNickname(nick, reply) => {
                let n = arg(&nick);
                // SAFETY: inst is live; n is NUL-terminated and outlives the call.
                let cmd = unsafe { sys::TT_DoChangeNickname(self.inst, n.as_ptr()) };
                self.track(cmd, Pending::Reply(reply), "Changing the nickname");
            }
            Request::InitAudio(devices, reply) => {
                let _ = reply.send(self.init_audio(devices));
            }
            Request::SetTransmitting(on, reply) => {
                // SAFETY: inst is live.
                let ok = unsafe { sys::TT_EnableVoiceTransmission(self.inst, on as sys::TTBOOL) } != 0;
                let _ = reply.send(if ok {
                    Ok(())
                } else {
                    Err(Error::Refused(
                        "Talking isn't possible: the microphone isn't open.".into(),
                    ))
                });
            }
            Request::SetVoiceActivation {
                on,
                level,
                stop_delay_ms,
                reply,
            } => {
                // SAFETY: inst is live (for all three calls).
                let ok = unsafe {
                    sys::TT_SetVoiceActivationLevel(self.inst, level.clamp(0, 100)) != 0
                        && sys::TT_SetVoiceActivationStopDelay(self.inst, stop_delay_ms.max(0)) != 0
                        && sys::TT_EnableVoiceActivation(self.inst, on as sys::TTBOOL) != 0
                };
                let _ = reply.send(if ok {
                    Ok(())
                } else {
                    Err(Error::Refused(
                        "Voice activation isn't possible: the microphone isn't open.".into(),
                    ))
                });
            }
            Request::SetUserVolume { user_id, volume, reply } => {
                // SAFETY: inst is live.
                let ok =
                    unsafe { sys::TT_SetUserVolume(self.inst, user_id, sys::StreamType_STREAMTYPE_VOICE, volume) } != 0;
                let _ = reply.send(if ok {
                    Ok(())
                } else {
                    Err(Error::Refused("That person's volume can't be set.".into()))
                });
            }
            Request::SetUserMuted { user_id, muted, reply } => {
                // SAFETY: inst is live.
                let ok = unsafe {
                    sys::TT_SetUserMute(
                        self.inst,
                        user_id,
                        sys::StreamType_STREAMTYPE_VOICE,
                        muted as sys::TTBOOL,
                    )
                } != 0;
                let _ = reply.send(if ok {
                    Ok(())
                } else {
                    Err(Error::Refused("That person can't be muted.".into()))
                });
            }
            Request::TestTone(hz, reply) => {
                // SAFETY: inst is live.
                let ok = unsafe { sys::TT_DBG_SetSoundInputTone(self.inst, sys::StreamType_STREAMTYPE_VOICE, hz) } != 0;
                let _ = reply.send(if ok {
                    Ok(())
                } else {
                    Err(Error::Refused("The test tone couldn't be set.".into()))
                });
            }
            Request::Upload {
                channel_id,
                path,
                reply,
            } => {
                if !std::path::Path::new(&path).is_file() {
                    let _ = reply.send(Err(Error::Refused(format!("There's no file at {path}."))));
                    return;
                }
                let p = arg(&path);
                // SAFETY: inst is live; p is NUL-terminated and outlives the call.
                let cmd = unsafe { sys::TT_DoSendFile(self.inst, channel_id, p.as_ptr()) };
                self.track(cmd, Pending::Reply(reply), "Uploading that file");
            }
            Request::Download {
                channel_id,
                file_id,
                path,
                reply,
            } => {
                if !self.has_file(channel_id, file_id) {
                    let _ = reply.send(Err(self.missing_file()));
                    return;
                }
                let p = arg(&path);
                // SAFETY: inst is live; p is NUL-terminated and outlives the call.
                let cmd = unsafe { sys::TT_DoRecvFile(self.inst, channel_id, file_id, p.as_ptr()) };
                self.track(cmd, Pending::Reply(reply), "Downloading that file");
            }
            Request::DeleteFile {
                channel_id,
                file_id,
                reply,
            } => {
                if !self.has_file(channel_id, file_id) {
                    let _ = reply.send(Err(self.missing_file()));
                    return;
                }
                // SAFETY: inst is live.
                let cmd = unsafe { sys::TT_DoDeleteFile(self.inst, channel_id, file_id) };
                self.track(cmd, Pending::Reply(reply), "Deleting that file");
            }
            Request::CancelTransfer(id, reply) => {
                // SAFETY: inst is live.
                let ok = unsafe { sys::TT_CancelFileTransfer(self.inst, id) } != 0;
                let ended = self.model.lock().ok().and_then(|mut m| m.transfers.remove(&id));
                match ended {
                    Some(mut t) if ok => {
                        t.status = TransferStatus::Cancelled;
                        self.emit(Event::TransferChanged(t));
                        let _ = reply.send(Ok(()));
                    }
                    _ => {
                        let _ = reply.send(Err(Error::Refused("That transfer isn't running.".into())));
                    }
                }
            }
            Request::Kick {
                user_id,
                from_channel,
                reply,
            } => {
                let channel = if from_channel {
                    self.model
                        .lock()
                        .ok()
                        .and_then(|m| m.users.get(&user_id).map(|u| u.channel_id))
                        .unwrap_or(0)
                } else {
                    0
                };
                if from_channel && channel == 0 {
                    let _ = reply.send(Err(Error::Refused("They're not in a channel.".into())));
                    return;
                }
                // SAFETY: inst is live.
                let cmd = unsafe { sys::TT_DoKickUser(self.inst, user_id, channel) };
                self.track(cmd, Pending::Reply(reply), "Kicking");
            }
            Request::BanUser { user_id, kind, reply } => {
                let types = match kind {
                    BanKind::IpAddress => sys::BanType_BANTYPE_IPADDR,
                    BanKind::Username => sys::BanType_BANTYPE_USERNAME,
                };
                // SAFETY: inst is live.
                let cmd = unsafe { sys::TT_DoBanUserEx(self.inst, user_id, types) };
                self.track(cmd, Pending::Reply(reply), "Banning");
            }
            Request::ListBans(reply) => {
                // SAFETY: inst is live.
                let cmd = unsafe { sys::TT_DoListBans(self.inst, 0, 0, 100_000) };
                if cmd > 0 {
                    self.pending
                        .insert(cmd, (Pending::Bans(Vec::new(), reply), Instant::now()));
                } else {
                    let _ = reply.send(Err(if self.logged_in() {
                        Error::Refused("The bans can't be listed right now.".into())
                    } else {
                        Error::NotConnected
                    }));
                }
            }
            Request::Unban(ban, reply) => {
                let b = sys::BannedUser {
                    szIPAddress: to_tt(&ban.ip_address),
                    szUsername: to_tt(&ban.username),
                    szChannelPath: to_tt(&ban.channel_path),
                    uBanTypes: ban.raw_types,
                    ..Default::default()
                };
                // SAFETY: inst is live; b is a valid BannedUser.
                let cmd = unsafe { sys::TT_DoUnBanUserEx(self.inst, &b) };
                self.track(cmd, Pending::Reply(reply), "Removing the ban");
            }
            Request::MoveUser {
                user_id,
                channel_id,
                reply,
            } => {
                // SAFETY: inst is live.
                let cmd = unsafe { sys::TT_DoMoveUser(self.inst, user_id, channel_id) };
                self.track(cmd, Pending::Reply(reply), "Moving");
            }
            Request::MakeChannel { spec, join, reply } => {
                let mut c = sys::Channel::default();
                // The parent's audio settings (a channel needs a codec).
                // SAFETY: inst is live; c is a valid Channel for the SDK to fill.
                if unsafe { sys::TT_GetChannel(self.inst, spec.parent_id, &mut c) } == 0 {
                    let _ = reply.send(Err(self.missing_channel()));
                    return;
                }
                c.nParentID = spec.parent_id;
                c.nChannelID = 0;
                c.szOpPassword = [0; 512];
                c.nDiskQuota = 0;
                c.transmitUsers = [[0; 2]; 128];
                c.transmitUsersQueue = [0; 16];
                apply_spec(&mut c, &spec, true);
                // SAFETY: inst is live; c is a valid Channel.
                let cmd = unsafe {
                    if join {
                        sys::TT_DoJoinChannel(self.inst, &c)
                    } else {
                        sys::TT_DoMakeChannel(self.inst, &c)
                    }
                };
                self.track(cmd, Pending::Reply(reply), "Making the channel");
            }
            Request::UpdateChannel { id, spec, reply } => {
                let mut c = sys::Channel::default();
                // SAFETY: inst is live; c is a valid Channel for the SDK to fill.
                if unsafe { sys::TT_GetChannel(self.inst, id, &mut c) } == 0 {
                    let _ = reply.send(Err(self.missing_channel()));
                    return;
                }
                apply_spec(&mut c, &spec, false);
                // SAFETY: inst is live; c is a valid Channel.
                let cmd = unsafe { sys::TT_DoUpdateChannel(self.inst, &c) };
                self.track(cmd, Pending::Reply(reply), "Changing the channel");
            }
            Request::RemoveChannel(id, reply) => {
                // SAFETY: inst is live.
                let cmd = unsafe { sys::TT_DoRemoveChannel(self.inst, id) };
                self.track(cmd, Pending::Reply(reply), "Removing the channel");
            }
            Request::UpdateServer { name, motd, reply } => {
                let mut p = sys::ServerProperties::default();
                // SAFETY: inst is live; p is valid for the SDK to fill.
                if unsafe { sys::TT_GetServerProperties(self.inst, &mut p) } == 0 {
                    let _ = reply.send(Err(Error::NotConnected));
                    return;
                }
                p.szServerName = to_tt(&name);
                p.szMOTDRaw = to_tt(&motd);
                // SAFETY: inst is live; p is valid.
                let cmd = unsafe { sys::TT_DoUpdateServer(self.inst, &p) };
                self.track(cmd, Pending::Reply(reply), "Changing the server");
            }
            Request::StartRecording { path, format, reply } => {
                let (channel, no_recording, already) = self
                    .model
                    .lock()
                    .map(|m| {
                        (
                            m.my_channel_id,
                            m.channels.get(&m.my_channel_id).is_some_and(|c| c.no_recording),
                            m.recording.is_some(),
                        )
                    })
                    .unwrap_or((0, false, false));
                let refuse = |why: &str| Err(Error::Refused(why.into()));
                let answer = if !self.logged_in() {
                    Err(Error::NotConnected)
                } else if channel == 0 {
                    refuse("Join a channel to record it.")
                } else if no_recording {
                    refuse("This channel doesn't allow recording.")
                } else if already {
                    refuse("Already recording.")
                } else {
                    let p = arg(&path);
                    let aff = match format {
                        RecordingFormat::Wave => sys::AudioFileFormat_AFF_WAVE_FORMAT,
                        RecordingFormat::Mp3 => sys::AudioFileFormat_AFF_MP3_128KBIT_FORMAT,
                    };
                    // SAFETY: inst is live; p is NUL-terminated and outlives the call.
                    if unsafe { sys::TT_StartRecordingMuxedAudioFileEx(self.inst, channel, p.as_ptr(), aff) } != 0 {
                        if let Ok(mut m) = self.model.lock() {
                            m.recording = Some((channel, path.clone()));
                        }
                        self.emit(Event::RecordingChanged {
                            path,
                            active: true,
                            error: None,
                        });
                        Ok(())
                    } else {
                        refuse("The recording couldn't start (can the file be written there?).")
                    }
                };
                let _ = reply.send(answer);
            }
            Request::StopRecording(reply) => {
                let stopped = self.stop_recording(None);
                let _ = reply.send(if stopped {
                    Ok(())
                } else {
                    Err(Error::Refused("Nothing is being recorded.".into()))
                });
            }
            Request::People(req, reply) => self.handle_people(req, reply),
            Request::Channels(req, reply) => self.handle_channels(req, reply),
            Request::Quit => {}
        }
    }

    /// Ends a recording, if there is one (`error`: why it broke off).
    fn stop_recording(&mut self, error: Option<String>) -> bool {
        let Some((channel, path)) = self.model.lock().ok().and_then(|mut m| m.recording.take()) else {
            return false;
        };
        // SAFETY: inst is live.
        unsafe { sys::TT_StopRecordingMuxedAudioFileEx(self.inst, channel) };
        self.emit(Event::RecordingChanged {
            path,
            active: false,
            error,
        });
        true
    }

    fn missing_channel(&self) -> Error {
        if self.logged_in() {
            Error::Refused("That channel isn't there any more.".into())
        } else {
            Error::NotConnected
        }
    }

    fn has_file(&self, channel_id: i32, file_id: i32) -> bool {
        self.model
            .lock()
            .map(|m| m.files.get(&file_id).is_some_and(|f| f.channel_id == channel_id))
            .unwrap_or(false)
    }

    fn missing_file(&self) -> Error {
        if self.logged_in() {
            Error::Refused("That file isn't there any more.".into())
        } else {
            Error::NotConnected
        }
    }

    /// Progress of the transfers under way, for those that moved on.
    fn poll_transfers(&mut self) {
        let ids: Vec<(i32, i64)> = match self.model.lock() {
            Ok(m) if !m.transfers.is_empty() => m.transfers.values().map(|t| (t.id, t.transferred)).collect(),
            _ => return,
        };
        for (id, before) in ids {
            let mut info = sys::FileTransfer::default();
            // SAFETY: inst is live; info is a valid FileTransfer for the SDK to fill.
            if unsafe { sys::TT_GetFileTransferInfo(self.inst, id, &mut info) } == 0 {
                continue;
            }
            let t = Transfer::from(&info);
            if t.transferred != before && t.status == TransferStatus::Active {
                if let Ok(mut m) = self.model.lock() {
                    m.transfers.insert(id, t.clone());
                }
                self.emit(Event::TransferChanged(t));
            }
        }
    }

    fn init_audio(&mut self, devices: AudioDevices) -> Result<()> {
        let (mut input, mut output) = (0, 0);
        match devices {
            AudioDevices::Virtual => {
                input = sys::TT_SOUNDDEVICE_ID_TEAMTALK_VIRTUAL as i32;
                output = input;
            }
            AudioDevices::Default | AudioDevices::Shared => {
                // SAFETY: both pointers are valid for the SDK to write.
                if unsafe { sys::TT_GetDefaultSoundDevices(&mut input, &mut output) } == 0 {
                    return Err(Error::Refused("No sound devices were found.".into()));
                }
                if devices == AudioDevices::Shared {
                    input |= sys::TT_SOUNDDEVICE_ID_SHARED_FLAG as i32;
                    output |= sys::TT_SOUNDDEVICE_ID_SHARED_FLAG as i32;
                }
            }
        }
        // SAFETY: inst is live.
        unsafe {
            sys::TT_CloseSoundInputDevice(self.inst);
            sys::TT_CloseSoundOutputDevice(self.inst);
            if sys::TT_InitSoundInputDevice(self.inst, input) == 0 {
                return Err(Error::Refused("The microphone couldn't be opened.".into()));
            }
            if sys::TT_InitSoundOutputDevice(self.inst, output) == 0 {
                return Err(Error::Refused("The speakers couldn't be opened.".into()));
            }
        }
        self.audio_open = true;
        Ok(())
    }

    fn send_message(&mut self, target: MessageTarget, text: &str, reply: Reply) {
        let my_id = self.model.lock().map(|m| m.my_user_id).unwrap_or(0);
        let parts = split_message(text);
        let last = parts.len() - 1;
        let mut reply = Some(reply);
        for (i, part) in parts.iter().enumerate() {
            let mut m = sys::TextMessage::default();
            let (kind, channel, to) = match target {
                MessageTarget::Channel(c) => (sys::TextMsgType_MSGTYPE_CHANNEL, c, 0),
                MessageTarget::User(u) => (sys::TextMsgType_MSGTYPE_USER, 0, u),
                MessageTarget::Broadcast => (sys::TextMsgType_MSGTYPE_BROADCAST, 0, 0),
            };
            m.nMsgType = kind;
            m.nFromUserID = my_id;
            m.nChannelID = channel;
            m.nToUserID = to;
            m.szMessage = to_tt(part);
            m.bMore = (i < last) as sys::TTBOOL;
            // SAFETY: inst is live; m is a complete TextMessage.
            let cmd = unsafe { sys::TT_DoTextMessage(self.inst, &m) };
            let p = if i == last {
                Pending::Reply(reply.take().unwrap())
            } else {
                Pending::Part
            };
            if cmd <= 0 {
                if let Some(r) = reply.take() {
                    let _ = r.send(Err(if self.logged_in() {
                        Error::Refused("The message couldn't be sent.".into())
                    } else {
                        Error::NotConnected
                    }));
                }
                return;
            }
            self.track(cmd, p, "Sending the message");
        }
    }

    fn channel_id(&self, path: &str) -> Option<i32> {
        let p = arg(path);
        // SAFETY: inst is live; p is NUL-terminated.
        let id = unsafe { sys::TT_GetChannelIDFromPath(self.inst, p.as_ptr()) };
        (id > 0).then_some(id)
    }

    fn start_connect(&mut self, attempt: u32) {
        let Some(o) = self.options.clone() else { return };
        self.set_state(if attempt == 0 {
            ConnectionState::Connecting
        } else {
            ConnectionState::Reconnecting { attempt }
        });
        let host = arg(&o.host);
        // SAFETY: inst is live; host is NUL-terminated and outlives the call.
        let ok = unsafe {
            sys::TT_Connect(
                self.inst,
                host.as_ptr(),
                o.tcp_port as i32,
                o.udp_port as i32,
                0,
                0,
                o.encrypted as sys::TTBOOL,
            )
        } != 0;
        if !ok {
            self.connect_failed(format!("Couldn't start connecting to {}.", o.host));
        }
        if self.attempt.is_none() {
            self.attempt = Some(Attempt { reply: None });
        }
    }

    /// A connection attempt failed: answer whoever waits, and retry if this
    /// was a reconnection.
    fn connect_failed(&mut self, why: String) {
        // SAFETY: inst is live.
        unsafe { sys::TT_Disconnect(self.inst) };
        let reconnecting = matches!(
            self.model.lock().map(|m| m.state.clone()).ok().flatten(),
            Some(ConnectionState::Reconnecting { .. })
        );
        if let Some(a) = self.attempt.take()
            && let Some(r) = a.reply
        {
            let _ = r.send(Err(Error::Connection(why.clone())));
        }
        if reconnecting && self.options.as_ref().is_some_and(|o| o.reconnect) && !self.no_reconnect {
            let n = match self.model.lock().map(|m| m.state.clone()).ok().flatten() {
                Some(ConnectionState::Reconnecting { attempt }) => attempt + 1,
                _ => 1,
            };
            self.schedule_retry(n);
        } else {
            self.options = None;
            self.clear_model();
            self.set_state(ConnectionState::Disconnected);
            self.emit(Event::ConnectionFailed(why));
        }
    }

    fn schedule_retry(&mut self, attempt: u32) {
        let wait = Duration::from_secs(1u64 << attempt.min(5).saturating_sub(1)).min(MAX_BACKOFF);
        self.retry = Some((Instant::now() + wait, attempt));
        self.set_state(ConnectionState::Reconnecting { attempt });
    }

    fn fail_attempt(&mut self, e: Error) {
        if let Some(a) = self.attempt.take()
            && let Some(r) = a.reply
        {
            let _ = r.send(Err(e));
        }
        for (_, (p, _)) in self.pending.drain() {
            if let Pending::Reply(r) = p {
                let _ = r.send(Err(Error::NotConnected));
            }
        }
    }

    fn clear_model(&mut self) {
        if self.model.lock().map(|m| m.recording.is_some()).unwrap_or(false) {
            self.stop_recording(Some("Disconnected.".into()));
        }
        let mut m = self.model.lock().unwrap_or_else(|e| e.into_inner());
        m.channels.clear();
        m.users.clear();
        m.files.clear();
        m.transfers.clear();
        m.my_user_id = 0;
        m.my_channel_id = 0;
        m.my_rights = MyRights::default();
        m.relaying = None;
        m.streaming = None;
        m.server = ServerInfo::default();
        self.partial.clear();
    }

    fn on_message(&mut self, msg: &sys::TTMessage) {
        // SAFETY (for every union read below): the SDK sets ttType to say
        // which member is valid, and each read checks it first.
        let union = &msg.__bindgen_anon_1;
        let user = || {
            (msg.ttType == sys::TTType___USER).then(|| {
                // SAFETY: ttType says the union holds a User.
                unsafe { User::from(&union.user) }
            })
        };
        let channel = || {
            (msg.ttType == sys::TTType___CHANNEL).then(|| {
                // SAFETY: ttType says the union holds a Channel.
                unsafe { Channel::from(&union.channel) }
            })
        };
        match msg.nClientEvent {
            sys::ClientEvent_CLIENTEVENT_CON_SUCCESS => {
                self.set_state(ConnectionState::LoggingIn);
                let Some(o) = self.options.clone() else { return };
                let (n, u, p, c) = (
                    arg(&o.nickname),
                    arg(&o.username),
                    arg(&o.password),
                    arg(&o.client_name),
                );
                // SAFETY: inst is live; the strings are NUL-terminated and outlive the call.
                let cmd = unsafe { sys::TT_DoLoginEx(self.inst, n.as_ptr(), u.as_ptr(), p.as_ptr(), c.as_ptr()) };
                if cmd > 0 {
                    self.pending.insert(cmd, (Pending::Login, Instant::now()));
                } else {
                    self.connect_failed("Couldn't log in.".into());
                }
            }
            sys::ClientEvent_CLIENTEVENT_CON_FAILED => {
                let host = self
                    .options
                    .as_ref()
                    .map(|o| format!("{}:{}", o.host, o.tcp_port))
                    .unwrap_or_default();
                self.connect_failed(format!("Couldn't connect to {host}."));
            }
            sys::ClientEvent_CLIENTEVENT_CON_CRYPT_ERROR => {
                self.connect_failed(
                    "The encrypted connection failed (the server's encryption settings don't match).".into(),
                );
            }
            sys::ClientEvent_CLIENTEVENT_CON_LOST => self.connection_lost(),
            sys::ClientEvent_CLIENTEVENT_CMD_SUCCESS => self.command_done(msg.nSource, Ok(())),
            sys::ClientEvent_CLIENTEVENT_CMD_ERROR => {
                let e = if msg.ttType == sys::TTType___CLIENTERRORMSG {
                    // SAFETY: checked ttType.
                    let em = unsafe { &union.clienterrormsg };
                    let text = from_tt(&em.szErrorMsg);
                    Error::Server {
                        code: em.nErrorNo,
                        message: server_error_text(em.nErrorNo, &text),
                    }
                } else {
                    Error::Refused("The server refused that.".into())
                };
                self.command_done(msg.nSource, Err(e));
            }
            sys::ClientEvent_CLIENTEVENT_CMD_MYSELF_LOGGEDIN => {
                if let Ok(mut m) = self.model.lock() {
                    m.my_user_id = msg.nSource;
                }
            }
            sys::ClientEvent_CLIENTEVENT_CMD_MYSELF_LOGGEDOUT => {
                self.no_reconnect = true;
            }
            sys::ClientEvent_CLIENTEVENT_CMD_MYSELF_KICKED => {
                let by = user().map(|u| u.id).unwrap_or(0);
                if msg.nSource == 0 {
                    self.no_reconnect = true;
                }
                self.emit(Event::Kicked {
                    by_user_id: by,
                    channel_id: msg.nSource,
                });
            }
            sys::ClientEvent_CLIENTEVENT_CMD_SERVER_UPDATE => {
                if msg.ttType == sys::TTType___SERVERPROPERTIES {
                    // SAFETY: checked ttType.
                    let s = ServerInfo::from(unsafe { &union.serverproperties });
                    if let Ok(mut m) = self.model.lock() {
                        m.server = s.clone();
                    }
                    self.emit(Event::ServerUpdated(s));
                }
            }
            sys::ClientEvent_CLIENTEVENT_CMD_CHANNEL_NEW | sys::ClientEvent_CLIENTEVENT_CMD_CHANNEL_UPDATE => {
                if let Some(c) = channel() {
                    let new = self
                        .model
                        .lock()
                        .map(|mut m| m.channels.insert(c.id, c.clone()).is_none())
                        .unwrap_or(true);
                    let id = c.id;
                    self.emit(if new {
                        Event::ChannelAdded(c)
                    } else {
                        Event::ChannelUpdated(c)
                    });
                    self.refresh_operators(id);
                }
            }
            sys::ClientEvent_CLIENTEVENT_CMD_CHANNEL_REMOVE => {
                if let Some(c) = channel() {
                    if let Ok(mut m) = self.model.lock() {
                        m.channels.remove(&c.id);
                    }
                    self.emit(Event::ChannelRemoved(c));
                }
            }
            sys::ClientEvent_CLIENTEVENT_CMD_USER_LOGGEDIN => {
                if let Some(u) = user().map(|u| self.with_operator(u)) {
                    if let Ok(mut m) = self.model.lock() {
                        m.users.insert(u.id, u.clone());
                    }
                    self.emit(Event::UserLoggedIn(u));
                }
            }
            sys::ClientEvent_CLIENTEVENT_CMD_USER_LOGGEDOUT => {
                if let Some(u) = user().map(|u| self.with_operator(u)) {
                    if let Ok(mut m) = self.model.lock() {
                        m.users.remove(&u.id);
                    }
                    self.emit(Event::UserLoggedOut(u));
                }
            }
            sys::ClientEvent_CLIENTEVENT_CMD_USER_UPDATE | sys::ClientEvent_CLIENTEVENT_USER_STATECHANGE => {
                if let Some(u) = user().map(|u| self.with_operator(u)) {
                    let before = self.model.lock().ok().and_then(|mut m| m.users.insert(u.id, u.clone()));
                    if before.as_ref().map(|b| b.talking) != Some(u.talking) {
                        self.emit(Event::TalkingChanged {
                            user_id: u.id,
                            talking: u.talking,
                        });
                    }
                    let media_changed = before.as_ref().map(|b| b.playing_media) != Some(u.playing_media);
                    if msg.nClientEvent == sys::ClientEvent_CLIENTEVENT_CMD_USER_UPDATE || media_changed {
                        self.emit(Event::UserUpdated(u));
                    }
                }
            }
            sys::ClientEvent_CLIENTEVENT_CMD_USER_JOINED => {
                if let Some(u) = user().map(|u| self.with_operator(u)) {
                    if let Ok(mut m) = self.model.lock() {
                        if u.id == m.my_user_id {
                            m.my_channel_id = u.channel_id;
                        }
                        m.users.insert(u.id, u.clone());
                    }
                    let channel_id = u.channel_id;
                    self.emit(Event::UserJoined { user: u, channel_id });
                }
            }
            sys::ClientEvent_CLIENTEVENT_CMD_USER_LEFT => {
                if let Some(mut u) = user().map(|u| self.with_operator(u)) {
                    let channel_id = msg.nSource;
                    u.channel_id = 0;
                    let me = self
                        .model
                        .lock()
                        .map(|mut m| {
                            let me = u.id == m.my_user_id;
                            if me {
                                m.my_channel_id = 0;
                            }
                            m.users.insert(u.id, u.clone());
                            me
                        })
                        .unwrap_or(false);
                    self.emit(Event::UserLeft { user: u, channel_id });
                    if me {
                        self.stop_recording(None);
                    }
                }
            }
            sys::ClientEvent_CLIENTEVENT_VOICE_ACTIVATION if msg.ttType == sys::TTType___TTBOOL => {
                // SAFETY: checked ttType.
                let on = unsafe { union.bActive } != 0;
                self.emit(Event::VoiceActivated(on));
            }
            sys::ClientEvent_CLIENTEVENT_STREAM_MEDIAFILE if msg.ttType == sys::TTType___MEDIAFILEINFO => {
                // SAFETY: checked ttType.
                let info = unsafe { union.mediafileinfo };
                self.on_stream(&info);
            }
            sys::ClientEvent_CLIENTEVENT_USER_AUDIOBLOCK if msg.ttType == sys::TTType___STREAMTYPE => {
                // SAFETY: checked ttType.
                let stream = unsafe { union.nStreamType };
                self.on_audio_block(msg.nSource, stream);
            }
            sys::ClientEvent_CLIENTEVENT_CMD_BANNEDUSER if msg.ttType == sys::TTType___BANNEDUSER => {
                // SAFETY: checked ttType.
                let ban = Ban::from(unsafe { &union.banneduser });
                // Bans arrive while their list command runs (one at a time).
                if let Some((Pending::Bans(list, _), _)) =
                    self.pending.values_mut().find(|(p, _)| matches!(p, Pending::Bans(..)))
                {
                    list.push(ban);
                }
            }
            sys::ClientEvent_CLIENTEVENT_CMD_FILE_NEW | sys::ClientEvent_CLIENTEVENT_CMD_FILE_REMOVE
                if msg.ttType == sys::TTType___REMOTEFILE =>
            {
                // SAFETY: checked ttType.
                let f = RemoteFile::from(unsafe { &union.remotefile });
                if let Ok(mut m) = self.model.lock() {
                    if msg.nClientEvent == sys::ClientEvent_CLIENTEVENT_CMD_FILE_NEW {
                        m.files.insert(f.id, f.clone());
                    } else {
                        m.files.remove(&f.id);
                    }
                }
                self.emit(if msg.nClientEvent == sys::ClientEvent_CLIENTEVENT_CMD_FILE_NEW {
                    Event::FileAdded(f)
                } else {
                    Event::FileRemoved(f)
                });
            }
            sys::ClientEvent_CLIENTEVENT_FILETRANSFER if msg.ttType == sys::TTType___FILETRANSFER => {
                // SAFETY: checked ttType.
                let t = Transfer::from(unsafe { &union.filetransfer });
                if let Ok(mut m) = self.model.lock() {
                    if t.status == TransferStatus::Active {
                        m.transfers.insert(t.id, t.clone());
                    } else if m.transfers.remove(&t.id).is_none() && t.status == TransferStatus::Cancelled {
                        // Already reported (cancelled here).
                        return;
                    }
                }
                self.emit(Event::TransferChanged(t));
            }
            sys::ClientEvent_CLIENTEVENT_CMD_USER_TEXTMSG if msg.ttType == sys::TTType___TEXTMESSAGE => {
                // SAFETY: checked ttType.
                let t = unsafe { &union.textmessage };
                self.on_text(t);
            }
            _ => {}
        }
    }

    fn on_text(&mut self, t: &sys::TextMessage) {
        let target = match t.nMsgType {
            sys::TextMsgType_MSGTYPE_CHANNEL => MessageTarget::Channel(t.nChannelID),
            // Incoming private messages carry no recipient: it's me.
            sys::TextMsgType_MSGTYPE_USER => {
                let me = self.model.lock().map(|m| m.my_user_id).unwrap_or(0);
                MessageTarget::User(if t.nToUserID > 0 { t.nToUserID } else { me })
            }
            sys::TextMsgType_MSGTYPE_BROADCAST => MessageTarget::Broadcast,
            _ => return, // custom messages: not for people
        };
        let key = (t.nMsgType, t.nFromUserID, t.nChannelID);
        let part = from_tt(&t.szMessage);
        let whole = self.partial.entry(key).or_default();
        whole.push_str(&part);
        if t.bMore != 0 {
            return;
        }
        let text = self.partial.remove(&key).unwrap_or_default();
        self.emit(Event::MessageReceived(TextMessage {
            target,
            from_user_id: t.nFromUserID,
            from_username: from_tt(&t.szFromUsername),
            text,
            received_at: now_ms(),
        }));
    }

    fn command_done(&mut self, id: i32, result: Result<()>) {
        let Some((p, _)) = self.pending.remove(&id) else { return };
        match p {
            Pending::Reply(r) => {
                let _ = r.send(result);
            }
            Pending::Part => {}
            Pending::Bans(bans, r) => {
                let _ = r.send(result.map(|()| bans));
            }
            Pending::Refresh(user_id, r) => {
                self.refresh_user(user_id);
                let _ = r.send(result);
            }
            Pending::Login => match result {
                Ok(()) => {
                    // SAFETY: inst is live.
                    let rights = unsafe {
                        MyRights::from_raw(
                            sys::TT_GetMyUserRights(self.inst),
                            sys::TT_GetMyUserType(self.inst) & sys::UserType_USERTYPE_ADMIN != 0,
                        )
                    };
                    if let Ok(mut m) = self.model.lock() {
                        m.my_rights = rights;
                    }
                    self.set_state(ConnectionState::LoggedIn);
                    match self.rejoin.clone() {
                        Some((path, password)) => self.join_after_login(&path, &password),
                        None => self.finish_attempt(Ok(())),
                    }
                }
                Err(e) => {
                    // A refused login isn't retried (wrong password, banned…).
                    self.no_reconnect = true;
                    self.options = None;
                    // SAFETY: inst is live.
                    unsafe { sys::TT_Disconnect(self.inst) };
                    self.finish_attempt(Err(e.clone()));
                    self.clear_model();
                    self.set_state(ConnectionState::Disconnected);
                    self.emit(Event::ConnectionFailed(e.to_string()));
                }
            },
            Pending::Rejoin => self.finish_attempt(result),
        }
    }

    fn join_after_login(&mut self, path: &str, password: &str) {
        match self.channel_id(path) {
            Some(id) => {
                let pw = arg(password);
                // SAFETY: inst is live; pw is NUL-terminated and outlives the call.
                let cmd = unsafe { sys::TT_DoJoinChannelByID(self.inst, id, pw.as_ptr()) };
                if cmd > 0 {
                    self.pending.insert(cmd, (Pending::Rejoin, Instant::now()));
                } else {
                    self.finish_attempt(Err(Error::Refused(format!("Couldn't join {path}."))));
                }
            }
            None => self.finish_attempt(Err(Error::Refused(format!(
                "Logged in, but there's no channel {path}."
            )))),
        }
    }

    fn finish_attempt(&mut self, result: Result<()>) {
        if let Some(a) = self.attempt.take()
            && let Some(r) = a.reply
        {
            let _ = r.send(result);
        }
    }

    fn connection_lost(&mut self) {
        // Remember the channel to rejoin.
        let rejoin = {
            let m = self.model.lock().unwrap_or_else(|e| e.into_inner());
            (m.my_channel_id > 0).then(|| m.my_channel_id)
        };
        if let Some(id) = rejoin {
            let mut path = vec![0 as sys::TTCHAR; sys::TT_STRLEN as usize];
            // SAFETY: inst is live; path has TT_STRLEN units for the SDK to fill.
            if unsafe { sys::TT_GetChannelPath(self.inst, id, path.as_mut_ptr()) } != 0 {
                let password = self.rejoin.as_ref().map(|(_, p)| p.clone()).unwrap_or_default();
                self.rejoin = Some((from_tt(&path), password));
            }
        }
        // SAFETY: inst is live.
        unsafe { sys::TT_Disconnect(self.inst) };
        for (_, (p, _)) in self.pending.drain() {
            if let Pending::Reply(r) = p {
                let _ = r.send(Err(Error::Connection("The connection was lost.".into())));
            }
        }
        self.clear_model();
        if self.options.as_ref().is_some_and(|o| o.reconnect) && !self.no_reconnect {
            self.schedule_retry(1);
        } else {
            self.options = None;
            self.set_state(ConnectionState::Disconnected);
            self.emit(Event::ConnectionFailed("The connection was lost.".into()));
        }
    }
}

fn reply_of(req: Request) -> Option<Reply> {
    Some(match req {
        Request::Connect(_, r)
        | Request::Disconnect(r)
        | Request::LeaveChannel(r)
        | Request::SetNickname(_, r)
        | Request::InitAudio(_, r)
        | Request::SetTransmitting(_, r)
        | Request::TestTone(_, r) => r,
        Request::SetVoiceActivation { reply, .. } => reply,
        Request::JoinChannel { reply, .. }
        | Request::JoinPath { reply, .. }
        | Request::SendMessage { reply, .. }
        | Request::SetStatus { reply, .. }
        | Request::SetUserVolume { reply, .. }
        | Request::SetUserMuted { reply, .. }
        | Request::Upload { reply, .. }
        | Request::Download { reply, .. }
        | Request::DeleteFile { reply, .. } => reply,
        Request::Kick { reply, .. }
        | Request::BanUser { reply, .. }
        | Request::MoveUser { reply, .. }
        | Request::MakeChannel { reply, .. }
        | Request::UpdateChannel { reply, .. }
        | Request::UpdateServer { reply, .. }
        | Request::StartRecording { reply, .. } => reply,
        Request::StopRecording(r) => r,
        Request::People(_, Some(r)) => r,
        Request::Channels(_, r) => r,
        Request::People(req, None) => {
            req.fail(Error::Refused("The TeamTalk SDK couldn't start.".into()));
            return None;
        }
        Request::CancelTransfer(_, r) | Request::Unban(_, r) | Request::RemoveChannel(_, r) => r,
        Request::ListBans(r) => {
            let _ = r.send(Err(Error::Refused("The TeamTalk SDK couldn't start.".into())));
            return None;
        }
        Request::Quit => return None,
    })
}

/// The server's error, in plain words where TeamTalk's own text is terse.
fn server_error_text(code: i32, server_text: &str) -> String {
    let plain = match code as sys::ClientError {
        sys::ClientError_CMDERR_INVALID_ACCOUNT => "The username or password is wrong.",
        sys::ClientError_CMDERR_INCORRECT_CHANNEL_PASSWORD => "The channel's password is wrong.",
        sys::ClientError_CMDERR_SERVER_BANNED => "You're banned from this server.",
        sys::ClientError_CMDERR_CHANNEL_BANNED => "You're banned from that channel.",
        sys::ClientError_CMDERR_NOT_AUTHORIZED => "You're not allowed to do that on this server.",
        sys::ClientError_CMDERR_MAX_SERVER_USERS_EXCEEDED => "The server is full.",
        sys::ClientError_CMDERR_MAX_CHANNEL_USERS_EXCEEDED => "The channel is full.",
        sys::ClientError_CMDERR_MAX_LOGINS_PER_IPADDRESS_EXCEEDED => "Too many people are logged in from your address.",
        sys::ClientError_CMDERR_COMMAND_FLOOD => "Too many commands too quickly; wait a moment.",
        sys::ClientError_CMDERR_CHANNEL_NOT_FOUND => "That channel doesn't exist any more.",
        sys::ClientError_CMDERR_USER_NOT_FOUND => "That person isn't on the server any more.",
        sys::ClientError_CMDERR_ALREADY_IN_CHANNEL => "You're already in that channel.",
        sys::ClientError_CMDERR_NOT_IN_CHANNEL => "You're not in a channel.",
        sys::ClientError_CMDERR_CHANNEL_ALREADY_EXISTS => "There's already a channel with that name there.",
        sys::ClientError_CMDERR_CHANNEL_HAS_USERS => "That channel still has people in it.",
        sys::ClientError_CMDERR_BAN_NOT_FOUND => "That ban isn't there any more.",
        sys::ClientError_CMDERR_MAX_DISKUSAGE_EXCEEDED => "There's no room for that file on the server.",
        sys::ClientError_CMDERR_FILE_ALREADY_EXISTS => "That channel already has a file with that name.",
        sys::ClientError_CMDERR_FILESHARING_DISABLED => "This server doesn't share files.",
        sys::ClientError_CMDERR_MAX_CHANNELS_EXCEEDED => "The server has as many channels as it allows.",
        sys::ClientError_CMDERR_INCOMPATIBLE_PROTOCOLS => "The server's TeamTalk version is incompatible.",
        _ => "",
    };
    if !plain.is_empty() {
        plain.to_owned()
    } else if server_text.is_empty() {
        format!("The server refused that (error {code}).")
    } else {
        server_text.to_owned()
    }
}

/// Sets a channel's settings from a spec (`making`: a new channel, where
/// no password means none).
fn apply_spec(c: &mut sys::Channel, spec: &ChannelSpec, making: bool) {
    c.szName = to_tt(&spec.name);
    c.szTopic = to_tt(&spec.topic);
    match (&spec.password, making) {
        (Some(p), _) => c.szPassword = to_tt(p),
        (None, true) => c.szPassword = [0; 512],
        (None, false) => {}
    }
    // 0 keeps the limit there is (the parent's, for a new channel): to
    // TeamTalk, 0 would mean nobody may join.
    if spec.max_users > 0 {
        c.nMaxUsers = spec.max_users;
    }
    let flags = [
        (spec.permanent, sys::ChannelType_CHANNEL_PERMANENT),
        (spec.solo_transmit, sys::ChannelType_CHANNEL_SOLO_TRANSMIT),
        (spec.classroom, sys::ChannelType_CHANNEL_CLASSROOM),
        (spec.operator_receive_only, sys::ChannelType_CHANNEL_OPERATOR_RECVONLY),
        (spec.no_voice_activation, sys::ChannelType_CHANNEL_NO_VOICEACTIVATION),
        (spec.no_recording, sys::ChannelType_CHANNEL_NO_RECORDING),
        (spec.hidden, sys::ChannelType_CHANNEL_HIDDEN),
    ];
    for (on, flag) in flags {
        if on {
            c.uChannelType |= flag;
        } else {
            c.uChannelType &= !flag;
        }
    }
    if let Some(p) = &spec.operator_password {
        c.szOpPassword = to_tt(p);
    }
    if let Some(q) = spec.disk_quota {
        c.nDiskQuota = q.max(0);
    }
    if let Some(codec) = &spec.codec {
        codec.write(&mut c.audiocodec);
    }
    if let Some((on, level)) = spec.fixed_volume {
        c.audiocfg.bEnableAGC = on as sys::TTBOOL;
        c.audiocfg.nGainLevel = level.clamp(0, 400) * sys::SoundLevel_SOUND_GAIN_DEFAULT as i32 / 100;
    }
    if let Some(t) = spec.voice_timeout_ms {
        c.nTimeOutTimerVoiceMSec = t.max(0);
    }
    if let Some(t) = spec.media_timeout_ms {
        c.nTimeOutTimerMediaFileMSec = t.max(0);
    }
}
