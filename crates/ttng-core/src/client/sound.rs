//! Sound as the desktop's Sound System settings have it: echo
//! cancellation, gain control and noise suppression (WebRTC's, as the
//! desktop uses), the channel's fixed volume, microphone gain, output and
//! media volume; my connection's statistics; and recording each person to
//! a file of their own.

use super::*;

/// The WebRTC gain controller's strongest fixed gain (dB).
const FIXED_GAIN_MAX_DB: f32 = 49.9;

pub(super) enum SoundRequest {
    Settings(AudioSettings),
    Statistics(Sender<Result<ClientStatistics>>),
    RecordEach(Option<(String, RecordingFormat)>),
}

impl SoundRequest {
    pub(super) fn fail(self, why: Error) {
        if let SoundRequest::Statistics(r) = self {
            let _ = r.send(Err(why));
        }
    }
}

fn percent_of(default: u32, percent: i32) -> i32 {
    percent.clamp(0, 400) * default as i32 / 100
}

/// WebRTC as the desktop sets it up, with the parts chosen.
fn webrtc(echo: bool, denoise: bool, agc: bool) -> sys::AudioPreprocessor {
    let mut p = sys::AudioPreprocessor {
        nPreprocessor: sys::AudioPreprocessorType_WEBRTC_AUDIOPREPROCESSOR,
        ..Default::default()
    };
    // SAFETY: nPreprocessor says the union holds the WebRTC member; every
    // field is plain data.
    let w = unsafe { &mut p.__bindgen_anon_1.webrtc };
    w.preamplifier.bEnable = 0;
    w.preamplifier.fFixedGainFactor = 1.0;
    w.echocanceller.bEnable = echo as sys::TTBOOL;
    w.noisesuppression.bEnable = denoise as sys::TTBOOL;
    w.noisesuppression.nLevel = 2;
    w.gaincontroller2.bEnable = agc as sys::TTBOOL;
    w.gaincontroller2.fixeddigital.fGainDB = 0.0;
    let a = &mut w.gaincontroller2.adaptivedigital;
    a.bEnable = 1;
    a.fHeadRoomDB = 5.0;
    a.fMaxGainDB = 50.0;
    a.fInitialGainDB = 15.0;
    a.fMaxGainChangeDBPerSecond = 6.0;
    a.fMaxOutputNoiseLevelDBFS = -50.0;
    p
}

impl Worker {
    pub(super) fn handle_sound(&mut self, req: SoundRequest, reply: Option<Reply>) {
        match req {
            SoundRequest::Settings(s) => {
                let was = self.model.lock().map(|m| m.audio).unwrap_or_default();
                if let Ok(mut m) = self.model.lock() {
                    m.audio = s;
                }
                // Echo cancellation needs the devices opened together.
                let reopen = self.audio_open && was.echo_cancellation != s.echo_cancellation;
                let r = if reopen {
                    match self.audio_devices {
                        Some(d) => self.init_audio(d),
                        None => Ok(()),
                    }
                } else {
                    self.apply_audio();
                    Ok(())
                };
                if let Some(reply) = reply {
                    let _ = reply.send(r);
                }
            }
            SoundRequest::Statistics(r) => {
                let mut st = sys::ClientStatistics::default();
                // SAFETY: inst is live; st is valid for the SDK to fill.
                let ok = unsafe { sys::TT_GetClientStatistics(self.inst, &mut st) } != 0;
                let _ = r.send(if ok {
                    Ok(ClientStatistics {
                        udp_bytes_sent: st.nUdpBytesSent,
                        udp_bytes_received: st.nUdpBytesRecv,
                        voice_bytes_sent: st.nVoiceBytesSent,
                        voice_bytes_received: st.nVoiceBytesRecv,
                        media_file_bytes_sent: st.nMediaFileAudioBytesSent,
                        media_file_bytes_received: st.nMediaFileAudioBytesRecv,
                        video_bytes_sent: st.nVideoCaptureBytesSent,
                        video_bytes_received: st.nVideoCaptureBytesRecv,
                        desktop_bytes_sent: st.nDesktopBytesSent,
                        desktop_bytes_received: st.nDesktopBytesRecv,
                        udp_ping_ms: st.nUdpPingTimeMs,
                        tcp_ping_ms: st.nTcpPingTimeMs,
                        udp_silence_s: st.nUdpServerSilenceSec,
                        tcp_silence_s: st.nTcpServerSilenceSec,
                    })
                } else {
                    Err(Error::NotConnected)
                });
            }
            SoundRequest::RecordEach(each) => {
                let users: Vec<i32> = self
                    .model
                    .lock()
                    .map(|m| m.users.keys().copied().collect())
                    .unwrap_or_default();
                if let Ok(mut m) = self.model.lock() {
                    m.recording_each = each.as_ref().map(|(f, _)| f.clone());
                }
                self.record_each = each;
                for u in users {
                    self.record_user(u);
                }
                if let Some(reply) = reply {
                    let _ = reply.send(Ok(()));
                }
            }
        }
    }

    /// Points someone's recording at the folder (or stops it).
    pub(super) fn record_user(&self, user_id: i32) {
        let (folder, aff) = match &self.record_each {
            Some((f, RecordingFormat::Wave)) => (f.clone(), sys::AudioFileFormat_AFF_WAVE_FORMAT),
            Some((f, RecordingFormat::Mp3)) => (f.clone(), sys::AudioFileFormat_AFF_MP3_128KBIT_FORMAT),
            None => (String::new(), sys::AudioFileFormat_AFF_NONE),
        };
        let f = arg(&folder);
        // A file per talk: their nickname and the time.
        let vars = arg("%nickname% %starttime%");
        // SAFETY: inst is live; both strings outlive the call.
        unsafe { sys::TT_SetUserMediaStorageDir(self.inst, user_id, f.as_ptr(), vars.as_ptr(), aff) };
    }

    /// Sets the microphone's processing and the volumes from the settings
    /// and my channel (whose fixed volume, when on, sets the gain).
    pub(super) fn apply_audio(&self) {
        if !self.audio_open {
            return;
        }
        let (s, fixed) = self
            .model
            .lock()
            .map(|m| {
                let fixed = m
                    .channels
                    .get(&m.my_channel_id)
                    .filter(|c| c.fixed_volume)
                    .map(|c| c.fixed_volume_level);
                (m.audio, fixed)
            })
            .unwrap_or_default();
        let echo = s.echo_cancellation && self.duplex;
        let p = match fixed {
            Some(level) => {
                let mut p = webrtc(echo, s.noise_suppression, true);
                // SAFETY: webrtc() made the WebRTC member the valid one.
                let g = unsafe { &mut p.__bindgen_anon_1.webrtc.gaincontroller2 };
                g.fixeddigital.fGainDB = FIXED_GAIN_MAX_DB * level as f32 / 100.0;
                g.adaptivedigital.bEnable = 0;
                p
            }
            None if echo || s.noise_suppression || s.gain_control => webrtc(echo, s.noise_suppression, s.gain_control),
            None => sys::AudioPreprocessor {
                nPreprocessor: sys::AudioPreprocessorType_TEAMTALK_AUDIOPREPROCESSOR,
                __bindgen_anon_1: sys::AudioPreprocessor__bindgen_ty_1 {
                    ttpreprocessor: sys::TTAudioPreprocessor {
                        nGainLevel: sys::SoundLevel_SOUND_GAIN_DEFAULT as i32,
                        bMuteLeftSpeaker: 0,
                        bMuteRightSpeaker: 0,
                    },
                },
            },
        };
        let gain = if fixed.is_some() {
            sys::SoundLevel_SOUND_GAIN_DEFAULT as i32
        } else {
            percent_of(sys::SoundLevel_SOUND_GAIN_DEFAULT, s.mic_gain)
        };
        // SAFETY: inst is live; p is a valid preprocessor.
        unsafe {
            sys::TT_SetSoundInputGainLevel(self.inst, gain);
            sys::TT_SetSoundInputPreprocessEx(self.inst, &p);
            sys::TT_SetSoundOutputVolume(
                self.inst,
                percent_of(sys::SoundLevel_SOUND_VOLUME_DEFAULT, s.output_volume),
            );
        }
    }

    /// Everyone's media file volume, from the settings (for someone new).
    pub(super) fn apply_media_volume(&self, user_id: i32) {
        let pct = self.model.lock().map(|m| m.audio.media_volume).unwrap_or(100);
        if pct != 100 {
            // SAFETY: inst is live.
            unsafe {
                sys::TT_SetUserVolume(
                    self.inst,
                    user_id,
                    sys::StreamType_STREAMTYPE_MEDIAFILE_AUDIO,
                    percent_of(sys::SoundLevel_SOUND_VOLUME_DEFAULT, pct),
                )
            };
        }
    }
}
