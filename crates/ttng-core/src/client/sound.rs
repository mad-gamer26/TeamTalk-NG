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
        // Always WAV: MP3s are converted when each file is done (see below).
        let (folder, aff) = match &self.record_each {
            Some((f, _)) => (f.clone(), sys::AudioFileFormat_AFF_WAVE_FORMAT),
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
            // The desktop's refGain: the same curve (50: the SDK's default).
            crate::volume::level(s.mic_gain).min(sys::SoundLevel_SOUND_GAIN_MAX as i32)
        };
        // SAFETY: inst is live; p is a valid preprocessor.
        unsafe {
            sys::TT_SetSoundInputGainLevel(self.inst, gain);
            sys::TT_SetSoundInputPreprocessEx(self.inst, &p);
            sys::TT_SetSoundOutputVolume(self.inst, crate::volume::level(s.output_volume));
        }
    }

    /// Everyone's media file volume, from the settings (for someone new).
    pub(super) fn apply_media_volume(&self, user_id: i32) {
        // The desktop's "Media file vs. voice volume": a percent of the
        // default level (100: as loud as voices).
        let pct = self.model.lock().map(|m| m.audio.media_volume).unwrap_or(100);
        if pct != 100 {
            // SAFETY: inst is live.
            unsafe {
                sys::TT_SetUserVolume(
                    self.inst,
                    user_id,
                    sys::StreamType_STREAMTYPE_MEDIAFILE_AUDIO,
                    crate::volume::level(50) * pct.clamp(0, 100) / 100,
                )
            };
        }
    }
}

impl Worker {
    /// Someone's recorded file is done: when recording each person as
    /// MP3, it becomes an MP3 beside it (on another thread).
    pub(super) fn on_user_recorded(&self, info: &sys::MediaFileInfo) {
        if info.nStatus != sys::MediaFileStatus_MFS_FINISHED
            || !matches!(self.record_each, Some((_, RecordingFormat::Mp3)))
        {
            return;
        }
        let wav = std::path::PathBuf::from(from_tt(&info.szFileName));
        if wav.extension().is_none_or(|e| !e.eq_ignore_ascii_case("wav")) {
            return;
        }
        let mp3 = wav.with_extension("mp3");
        std::thread::spawn(move || {
            // If it fails the WAV stays, so nothing is lost.
            let _ = crate::mp3::wav_to_mp3(&wav, &mp3, 128, true);
        });
    }
}
