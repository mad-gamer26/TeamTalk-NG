//! Outside audio, in and out (AudioNet): audio the app gives is sent as this
//! login's voice (it replaces the microphone, so it's meant for a login of
//! its own); and the channel's sound (what this client plays, everyone
//! mixed) and my microphone are captured for the app to read.

use super::*;
use std::collections::VecDeque;

/// What can be captured for the app.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Capture {
    /// Everyone I hear, mixed, as it's played.
    Channel,
    /// My microphone (as the sound device gives it).
    Microphone,
}

/// Captured audio: 16-bit samples, interleaved.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct CapturedAudio {
    pub samples: Vec<i16>,
    pub sample_rate: u32,
    pub channels: u32,
}

/// At most this much is kept for a slow reader (the oldest goes).
const KEEP_SECONDS: usize = 2;

#[derive(Default)]
struct Ring {
    buf: VecDeque<i16>,
    rate: u32,
    channels: u32,
}

/// The captures, shared between the SDK's thread (which fills them) and
/// the app (which reads them).
#[derive(Default)]
pub(super) struct Captured {
    channel: Mutex<Option<Ring>>,
    microphone: Mutex<Option<Ring>>,
}

impl Captured {
    fn slot(&self, c: Capture) -> &Mutex<Option<Ring>> {
        match c {
            Capture::Channel => &self.channel,
            Capture::Microphone => &self.microphone,
        }
    }

    fn set(&self, c: Capture, on: bool) {
        if let Ok(mut s) = self.slot(c).lock() {
            *s = on.then(Ring::default);
        }
    }

    pub(super) fn is_on(&self, c: Capture) -> bool {
        self.slot(c).lock().map(|s| s.is_some()).unwrap_or(false)
    }

    fn push(&self, c: Capture, samples: &[i16], rate: u32, channels: u32) {
        let Ok(mut s) = self.slot(c).lock() else { return };
        let Some(r) = s.as_mut() else { return };
        if r.rate != rate || r.channels != channels {
            r.buf.clear();
            r.rate = rate;
            r.channels = channels;
        }
        r.buf.extend(samples.iter().copied());
        let keep = rate as usize * channels as usize * KEEP_SECONDS;
        let over = r.buf.len().saturating_sub(keep);
        r.buf.drain(..over);
    }

    /// Everything captured since the last read.
    pub(super) fn read(&self, c: Capture) -> CapturedAudio {
        let Ok(mut s) = self.slot(c).lock() else {
            return CapturedAudio::default();
        };
        let Some(r) = s.as_mut() else {
            return CapturedAudio::default();
        };
        CapturedAudio {
            samples: r.buf.drain(..).collect(),
            sample_rate: r.rate,
            channels: r.channels,
        }
    }
}

pub(super) enum AudioIoRequest {
    Insert {
        samples: Vec<i16>,
        sample_rate: u32,
        channels: u32,
    },
    EndInsert,
    Capture(Capture, bool),
}

fn capture_target(c: Capture) -> (i32, u32) {
    match c {
        Capture::Channel => (
            sys::TT_MUXED_USERID as i32,
            sys::StreamType_STREAMTYPE_VOICE | sys::StreamType_STREAMTYPE_MEDIAFILE_AUDIO,
        ),
        Capture::Microphone => (sys::TT_LOCAL_USERID as i32, sys::StreamType_STREAMTYPE_VOICE),
    }
}

impl Worker {
    pub(super) fn handle_audio_io(&mut self, req: AudioIoRequest) -> Result<()> {
        match req {
            AudioIoRequest::Insert {
                samples,
                sample_rate,
                channels,
            } => {
                if !self.logged_in() {
                    return Err(Error::NotConnected);
                }
                let channels = channels.clamp(1, 2);
                if samples.is_empty() || sample_rate == 0 {
                    return Ok(());
                }
                // SAFETY: a plain C struct; every field is set or zero.
                let mut block: sys::AudioBlock = unsafe { std::mem::zeroed() };
                block.nStreamID = 1;
                block.nSampleRate = sample_rate as i32;
                block.nChannels = channels as i32;
                block.nSamples = (samples.len() / channels as usize) as i32;
                block.lpRawAudio = samples.as_ptr() as *mut std::ffi::c_void;
                // SAFETY: inst is live; the SDK copies the block before returning.
                if unsafe { sys::TT_InsertAudioBlock(self.inst, &block) } == 0 {
                    return Err(Error::Refused("The audio queue is full.".into()));
                }
                Ok(())
            }
            AudioIoRequest::EndInsert => {
                // SAFETY: inst is live; a null block ends the inserted audio.
                unsafe { sys::TT_InsertAudioBlock(self.inst, ptr::null()) };
                Ok(())
            }
            AudioIoRequest::Capture(c, on) => {
                let (user, streams) = capture_target(c);
                // SAFETY: inst is live.
                if unsafe { sys::TT_EnableAudioBlockEvent(self.inst, user, streams, on as i32) } == 0 && on {
                    return Err(Error::Refused("That sound can't be captured now.".into()));
                }
                self.captured.set(c, on);
                Ok(())
            }
        }
    }

    /// An audio block for a capture; false when it isn't one.
    pub(super) fn on_captured_block(&mut self, user_id: i32, stream: u32) -> bool {
        let c = if user_id == sys::TT_MUXED_USERID as i32 {
            Capture::Channel
        } else if user_id == sys::TT_LOCAL_USERID as i32 {
            Capture::Microphone
        } else {
            return false;
        };
        if !self.captured.is_on(c) {
            return false;
        }
        // SAFETY: inst is live; the block is released below.
        let block = unsafe { sys::TT_AcquireUserAudioBlock(self.inst, stream, user_id) };
        if block.is_null() {
            return true;
        }
        // SAFETY: a live block from the SDK; its samples are nSamples × nChannels i16.
        unsafe {
            let b = &*block;
            if !b.lpRawAudio.is_null() && b.nSamples > 0 && b.nChannels > 0 {
                let n = b.nSamples as usize * b.nChannels as usize;
                let samples = std::slice::from_raw_parts(b.lpRawAudio as *const i16, n);
                self.captured.push(c, samples, b.nSampleRate as u32, b.nChannels as u32);
            }
            sys::TT_ReleaseUserAudioBlock(self.inst, block);
        }
        true
    }
}
