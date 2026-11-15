//! The desktop's "Test Selected" (Preferences → Sound System): the
//! microphone played straight back through the speakers, with the sound
//! settings' echo cancellation, gain and denoising, through the devices a
//! connection would use. Not tied to a server.

use ttng_sys as sys;

use crate::client::AudioDevices;
use crate::model::AudioSettings;
use crate::{Error, Result};

/// A running loopback test; stops when dropped.
#[derive(Debug)]
pub struct SoundLoop(*mut sys::TTSoundLoop);

// SAFETY: the SDK's sound loop handle may be closed from any thread.
unsafe impl Send for SoundLoop {}
// SAFETY: the handle isn't used through a shared reference.
unsafe impl Sync for SoundLoop {}

impl Drop for SoundLoop {
    fn drop(&mut self) {
        // SAFETY: the handle came from TT_StartSoundLoopbackTestEx and is
        // closed once.
        unsafe { sys::TT_CloseSoundLoopbackTest(self.0) };
    }
}

/// Starts the test with these devices and settings.
pub fn start(devices: AudioDevices, s: &AudioSettings) -> Result<SoundLoop> {
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
        }
    }
    let phone = cfg!(any(target_os = "ios", target_os = "android"));
    // As a connection: phones cancel echo in their own devices.
    if s.echo_cancellation && devices != AudioDevices::Virtual {
        if cfg!(target_os = "ios") {
            input = sys::TT_SOUNDDEVICE_ID_VOICEPREPROCESSINGIO as i32;
            output = input;
        } else if cfg!(target_os = "android") {
            input = sys::TT_SOUNDDEVICE_ID_OPENSLES_VOICECOM as i32;
        }
    }
    let duplex = s.echo_cancellation && !phone && devices != AudioDevices::Virtual;
    let p = if (s.echo_cancellation && duplex) || s.noise_suppression || s.gain_control {
        crate::client::sound::webrtc(s.echo_cancellation && duplex, s.noise_suppression, s.gain_control)
    } else {
        sys::AudioPreprocessor {
            nPreprocessor: sys::AudioPreprocessorType_TEAMTALK_AUDIOPREPROCESSOR,
            __bindgen_anon_1: sys::AudioPreprocessor__bindgen_ty_1 {
                ttpreprocessor: sys::TTAudioPreprocessor {
                    nGainLevel: crate::volume::level(s.mic_gain).min(sys::SoundLevel_SOUND_GAIN_MAX as i32),
                    bMuteLeftSpeaker: 0,
                    bMuteRightSpeaker: 0,
                },
            },
        }
    };
    let effects = sys::SoundDeviceEffects::default();
    // Stereo, so a stereo microphone (the iPhone's front or back one) is
    // heard as it is; the Voice-Processing unit is mono.
    let voice_processing = s.echo_cancellation && phone && devices != AudioDevices::Virtual;
    crate::client::sound::configure_shared(voice_processing);
    let channels = if voice_processing && cfg!(target_os = "ios") {
        1
    } else {
        2
    };
    // SAFETY: p and effects outlive the call; the SDK copies them.
    let h = unsafe {
        sys::TT_StartSoundLoopbackTestEx(input, output, 48000, channels, duplex as sys::TTBOOL, &p, &effects)
    };
    if h.is_null() {
        Err(Error::Refused("The sound devices couldn't be tested.".into()))
    } else {
        Ok(SoundLoop(h))
    }
}
