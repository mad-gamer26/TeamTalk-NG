//! Sound settings, client statistics and recording options for the apps.

use ttng_core as core;

use crate::{RecordingFormat, Result, TtClient};

/// The desktop's Sound System settings.
#[derive(Clone, Copy, Debug, PartialEq, Eq, uniffi::Record)]
pub struct AudioSettings {
    pub echo_cancellation: bool,
    pub gain_control: bool,
    pub noise_suppression: bool,
    /// Percent (100 as it is).
    pub mic_gain: i32,
    pub output_volume: i32,
    /// Everyone's media files, in percent of their voice.
    pub media_volume: i32,
}

impl From<core::AudioSettings> for AudioSettings {
    fn from(s: core::AudioSettings) -> Self {
        AudioSettings {
            echo_cancellation: s.echo_cancellation,
            gain_control: s.gain_control,
            noise_suppression: s.noise_suppression,
            mic_gain: s.mic_gain,
            output_volume: s.output_volume,
            media_volume: s.media_volume,
        }
    }
}

impl From<AudioSettings> for core::AudioSettings {
    fn from(s: AudioSettings) -> Self {
        core::AudioSettings {
            echo_cancellation: s.echo_cancellation,
            gain_control: s.gain_control,
            noise_suppression: s.noise_suppression,
            mic_gain: s.mic_gain,
            output_volume: s.output_volume,
            media_volume: s.media_volume,
        }
    }
}

/// The settings a new install starts with.
#[uniffi::export]
pub fn default_audio_settings() -> AudioSettings {
    core::AudioSettings::default().into()
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, uniffi::Record)]
pub struct ClientStatistics {
    pub udp_bytes_sent: i64,
    pub udp_bytes_received: i64,
    pub voice_bytes_sent: i64,
    pub voice_bytes_received: i64,
    pub media_file_bytes_sent: i64,
    pub media_file_bytes_received: i64,
    pub video_bytes_sent: i64,
    pub video_bytes_received: i64,
    pub desktop_bytes_sent: i64,
    pub desktop_bytes_received: i64,
    pub udp_ping_ms: i32,
    pub tcp_ping_ms: i32,
    pub udp_silence_s: i32,
    pub tcp_silence_s: i32,
}

fn format(f: RecordingFormat) -> core::RecordingFormat {
    match f {
        RecordingFormat::Wave => core::RecordingFormat::Wave,
        RecordingFormat::Mp3 => core::RecordingFormat::Mp3,
    }
}

#[uniffi::export]
impl TtClient {
    pub fn set_audio_settings(&self, settings: AudioSettings) -> Result<()> {
        Ok(self.inner.set_audio_settings(settings.into())?)
    }

    pub fn audio_settings(&self) -> AudioSettings {
        self.inner.snapshot().audio.into()
    }

    pub fn client_statistics(&self) -> Result<ClientStatistics> {
        let s = self.inner.client_statistics()?;
        Ok(ClientStatistics {
            udp_bytes_sent: s.udp_bytes_sent,
            udp_bytes_received: s.udp_bytes_received,
            voice_bytes_sent: s.voice_bytes_sent,
            voice_bytes_received: s.voice_bytes_received,
            media_file_bytes_sent: s.media_file_bytes_sent,
            media_file_bytes_received: s.media_file_bytes_received,
            video_bytes_sent: s.video_bytes_sent,
            video_bytes_received: s.video_bytes_received,
            desktop_bytes_sent: s.desktop_bytes_sent,
            desktop_bytes_received: s.desktop_bytes_received,
            udp_ping_ms: s.udp_ping_ms,
            tcp_ping_ms: s.tcp_ping_ms,
            udp_silence_s: s.udp_silence_s,
            tcp_silence_s: s.tcp_silence_s,
        })
    }

    /// Records my channel; `include_media` mixes in media files too.
    pub fn start_recording_with(&self, path: String, format_: RecordingFormat, include_media: bool) -> Result<()> {
        Ok(self.inner.start_recording_with(&path, format(format_), include_media)?)
    }

    /// Records each person to their own files in `folder`; nil stops.
    pub fn set_record_each(&self, folder: Option<String>, format_: RecordingFormat) -> Result<()> {
        Ok(self
            .inner
            .set_record_each(folder.as_deref().map(|f| (f, format(format_))))?)
    }

    /// The folder each person is recorded to, when on.
    pub fn recording_each(&self) -> Option<String> {
        self.inner.snapshot().recording_each
    }
}

/// The desktop's "Test Selected": the microphone played back through the
/// speakers with these settings, until stopped.
#[derive(Debug, uniffi::Object)]
pub struct TtSoundLoop {
    running: std::sync::Mutex<Option<core::loopback::SoundLoop>>,
}

#[uniffi::export]
impl TtSoundLoop {
    pub fn stop(&self) {
        if let Ok(mut r) = self.running.lock() {
            r.take();
        }
    }
}

/// Starts a sound test (see TtSoundLoop).
#[uniffi::export]
pub fn start_sound_test(devices: crate::AudioDevices, settings: AudioSettings) -> Result<std::sync::Arc<TtSoundLoop>> {
    let l = core::loopback::start(devices.into(), &settings.into())?;
    Ok(std::sync::Arc::new(TtSoundLoop {
        running: std::sync::Mutex::new(Some(l)),
    }))
}
