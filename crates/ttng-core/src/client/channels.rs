//! Channels beyond joining: hidden channels (known by path only), and
//! streaming a media file to my channel.

use super::*;

pub(super) enum ChannelRequest {
    HearOwnStream(bool),
    JoinHidden {
        path: String,
        password: String,
    },
    Stream {
        path: String,
        offset_ms: u32,
        paused: bool,
        looping: bool,
    },
    UpdateStream {
        offset_ms: Option<u32>,
        paused: bool,
    },
    StopStream,
}

/// The SDK's status bits for streaming (in my status).
const STATUS_STREAMING: i32 = 0x800;
const STATUS_STREAM_PAUSED: i32 = 0x2000;

fn playback(offset_ms: Option<u32>, paused: bool) -> sys::MediaFilePlayback {
    sys::MediaFilePlayback {
        // The SDK's "don't move" offset.
        uOffsetMSec: offset_ms.unwrap_or(u32::MAX),
        bPaused: paused as sys::TTBOOL,
        ..Default::default()
    }
}

impl Worker {
    pub(super) fn handle_channels(&mut self, req: ChannelRequest, reply: Reply) {
        match req {
            ChannelRequest::JoinHidden { path, password } => {
                let trimmed = path.trim_matches('/');
                let (parent_path, name) = match trimmed.rsplit_once('/') {
                    Some((p, n)) => (format!("/{p}/"), n.to_owned()),
                    None => ("/".to_owned(), trimmed.to_owned()),
                };
                let Some(parent) = self.channel_id(&parent_path) else {
                    let _ = reply.send(Err(Error::Refused(format!("There's no channel {parent_path}."))));
                    return;
                };
                if name.is_empty() {
                    let _ = reply.send(Err(Error::Refused("Say which channel.".into())));
                    return;
                }
                let c = sys::Channel {
                    nParentID: parent,
                    szName: to_tt(&name),
                    szPassword: to_tt(&password),
                    ..Default::default()
                };
                // SAFETY: inst is live; c is a valid Channel.
                let cmd = unsafe { sys::TT_DoJoinChannel(self.inst, &c) };
                self.track(cmd, Pending::Reply(reply), "Joining that channel");
            }
            ChannelRequest::HearOwnStream(on) => {
                self.hear_own_stream = on;
                let _ = reply.send(Ok(()));
            }
            ChannelRequest::Stream {
                path,
                offset_ms,
                paused,
                looping,
            } => {
                let _ = reply.send(self.start_stream(&path, offset_ms, paused, looping));
            }
            ChannelRequest::UpdateStream { offset_ms, paused } => {
                let Some(mut st) = self.model.lock().ok().and_then(|m| m.streaming.clone()) else {
                    let _ = reply.send(Err(Error::Refused("Nothing is being streamed.".into())));
                    return;
                };
                let pb = playback(offset_ms, paused);
                // SAFETY: inst is live; pb is valid; no video codec.
                let ok = unsafe { sys::TT_UpdateStreamingMediaFileToChannel(self.inst, &pb, ptr::null()) } != 0;
                if ok && self.local_playback > 0 {
                    // SAFETY: inst is live; pb is valid.
                    unsafe { sys::TT_UpdateLocalPlayback(self.inst, self.local_playback, &pb) };
                }
                if ok {
                    st.status = if paused {
                        StreamStatus::Paused
                    } else {
                        StreamStatus::Playing
                    };
                    if let Some(o) = offset_ms {
                        st.elapsed_ms = o;
                    }
                    self.set_stream(Some(st));
                }
                let _ = reply.send(
                    ok.then_some(())
                        .ok_or_else(|| Error::Refused("The stream couldn't be changed.".into())),
                );
            }
            ChannelRequest::StopStream => {
                let had = self.model.lock().ok().and_then(|m| m.streaming.clone());
                // SAFETY: inst is live.
                unsafe { sys::TT_StopStreamingMediaFileToChannel(self.inst) };
                self.stop_local_playback();
                if let Some(mut st) = had {
                    st.status = StreamStatus::Stopped;
                    self.set_stream(None);
                    self.emit(Event::StreamChanged(st));
                    let _ = reply.send(Ok(()));
                } else {
                    let _ = reply.send(Err(Error::Refused("Nothing is being streamed.".into())));
                }
            }
        }
    }

    fn start_stream(&mut self, path: &str, offset_ms: u32, paused: bool, looping: bool) -> Result<()> {
        if !self.logged_in() {
            return Err(Error::NotConnected);
        }
        if self.model.lock().map(|m| m.my_channel_id).unwrap_or(0) == 0 {
            return Err(Error::Refused("Join a channel to stream to it.".into()));
        }
        let info = media_file_info(path).ok_or_else(|| Error::Refused("That file can't be played.".into()))?;
        if info.sample_rate == 0 && info.video_width == 0 {
            return Err(Error::Refused("That file has no sound TeamTalk can play.".into()));
        }
        let p = arg(path);
        let pb = playback(Some(offset_ms), paused);
        // Its video too when asked (and it has some), as VP8.
        let vc = sys::VideoCodec {
            nCodec: sys::Codec_WEBM_VP8_CODEC,
            __bindgen_anon_1: sys::VideoCodec__bindgen_ty_1 {
                webm_vp8: sys::WebMVP8Codec {
                    __bindgen_anon_1: sys::WebMVP8Codec__bindgen_ty_1 { nRcTargetBitrate: 256 },
                    nEncodeDeadline: sys::WEBM_VPX_DL_REALTIME,
                },
            },
        };
        let video = if self.stream_video && info.video_width > 0 {
            &vc as *const _
        } else {
            ptr::null()
        };
        // SAFETY: inst is live; p, pb and vc outlive the call.
        if unsafe { sys::TT_StartStreamingMediaFileToChannelEx(self.inst, p.as_ptr(), &pb, video) } == 0 {
            return Err(Error::Refused("The file couldn't be streamed.".into()));
        }
        self.stop_local_playback();
        if self.hear_own_stream {
            // The SDK never plays my own stream back to me: play the file
            // here too, kept in step (pause, seek, stop).
            // SAFETY: inst is live; p and pb outlive the call.
            self.local_playback = unsafe { sys::TT_InitLocalPlayback(self.inst, p.as_ptr(), &pb) }.max(0);
        }
        self.set_stream(Some(MediaStream {
            path: path.into(),
            status: StreamStatus::Started,
            elapsed_ms: offset_ms,
            duration_ms: info.duration_ms,
            looping,
        }));
        Ok(())
    }

    pub(super) fn stop_local_playback(&mut self) {
        if self.local_playback > 0 {
            // SAFETY: inst is live.
            unsafe { sys::TT_StopLocalPlayback(self.inst, self.local_playback) };
            self.local_playback = 0;
        }
    }

    /// Keeps the model and my status's streaming flags up to date.
    fn set_stream(&mut self, st: Option<MediaStream>) {
        let flags = match &st {
            Some(s) if s.status == StreamStatus::Paused => STATUS_STREAMING | STATUS_STREAM_PAUSED,
            Some(_) => STATUS_STREAMING,
            None => 0,
        };
        if let Ok(mut m) = self.model.lock() {
            m.streaming = st;
        }
        let (mode, message) = self.my_status();
        let raw = (mode & !(STATUS_STREAMING | STATUS_STREAM_PAUSED)) | flags;
        if raw != mode && self.logged_in() {
            let msg = arg(&message);
            // SAFETY: inst is live; msg outlives the call.
            let cmd = unsafe { sys::TT_DoChangeStatus(self.inst, raw, msg.as_ptr()) };
            if cmd > 0 {
                self.pending.insert(cmd, (Pending::Part, Instant::now()));
            }
        }
    }

    /// The SDK's news about my stream.
    pub(super) fn on_stream(&mut self, info: &sys::MediaFileInfo) {
        let Some(mut st) = self.model.lock().ok().and_then(|m| m.streaming.clone()) else {
            return;
        };
        st.elapsed_ms = info.uElapsedMSec;
        if info.uDurationMSec > 0 {
            st.duration_ms = info.uDurationMSec;
        }
        let status = match info.nStatus {
            sys::MediaFileStatus_MFS_STARTED => StreamStatus::Started,
            sys::MediaFileStatus_MFS_PLAYING => StreamStatus::Playing,
            sys::MediaFileStatus_MFS_PAUSED => StreamStatus::Paused,
            sys::MediaFileStatus_MFS_FINISHED => StreamStatus::Finished,
            sys::MediaFileStatus_MFS_ERROR => StreamStatus::Failed,
            _ => StreamStatus::Stopped,
        };
        let moved = status != st.status || self.last_stream_note.elapsed() >= Duration::from_secs(1);
        st.status = status;
        match status {
            StreamStatus::Finished if st.looping => {
                let (path, looping) = (st.path.clone(), st.looping);
                self.emit(Event::StreamChanged(st));
                if self.start_stream(&path, 0, false, looping).is_err() {
                    self.set_stream(None);
                }
            }
            StreamStatus::Finished | StreamStatus::Failed | StreamStatus::Stopped => {
                self.stop_local_playback();
                self.set_stream(None);
                self.emit(Event::StreamChanged(st));
            }
            _ => {
                if let Ok(mut m) = self.model.lock() {
                    m.streaming = Some(st.clone());
                }
                if moved {
                    self.last_stream_note = Instant::now();
                    self.emit(Event::StreamChanged(st));
                }
            }
        }
    }
}

/// A media file's properties (None when the SDK can't play it).
pub fn media_file_info(path: &str) -> Option<MediaFileInfo> {
    let p = arg(path);
    let mut info = sys::MediaFileInfo::default();
    // SAFETY: p is NUL-terminated; info is valid for the SDK to fill.
    if unsafe { sys::TT_GetMediaFileInfo(p.as_ptr(), &mut info) } == 0 {
        return None;
    }
    Some(MediaFileInfo {
        duration_ms: info.uDurationMSec,
        sample_rate: info.audioFmt.nSampleRate,
        channels: info.audioFmt.nChannels,
        video_width: info.videoFmt.nWidth,
        video_height: info.videoFmt.nHeight,
    })
}
