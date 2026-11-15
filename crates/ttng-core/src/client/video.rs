//! Seeing what others send: their camera, the video of media files they
//! stream, their shared desktops; and sending a picture as a desktop (for
//! tests, and computers). The SDK only captures video on Mac, Windows and
//! Linux (and can't take frames from outside), so phones receive video
//! but can't send their camera.

use super::*;

/// How often a new picture of the same video is announced.
const FRAME_EVERY: Duration = Duration::from_millis(200);

impl Worker {
    /// The SDK has a new picture for someone (`kind`): copy it out.
    pub(super) fn on_video(&mut self, user_id: i32, kind: VideoKind) {
        let frame = match kind {
            VideoKind::Camera | VideoKind::MediaFile => {
                // SAFETY: inst is live; the frame is released below.
                let f = unsafe {
                    if kind == VideoKind::Camera {
                        sys::TT_AcquireUserVideoCaptureFrame(self.inst, user_id)
                    } else {
                        sys::TT_AcquireUserMediaVideoFrame(self.inst, user_id)
                    }
                };
                if f.is_null() {
                    return;
                }
                // SAFETY: f is a live frame; its buffer holds nFrameBufferSize bytes.
                let out = unsafe {
                    let v = &*f;
                    let bytes =
                        std::slice::from_raw_parts(v.frameBuffer as *const u8, v.nFrameBufferSize.max(0) as usize);
                    VideoFrame {
                        width: v.nWidth,
                        height: v.nHeight,
                        bgra: bytes.to_vec(),
                    }
                };
                // SAFETY: f came from the matching acquire.
                unsafe {
                    if kind == VideoKind::Camera {
                        sys::TT_ReleaseUserVideoCaptureFrame(self.inst, f);
                    } else {
                        sys::TT_ReleaseUserMediaVideoFrame(self.inst, f);
                    }
                }
                out
            }
            VideoKind::Desktop => {
                // SAFETY: inst is live; the window is released below.
                let w = unsafe { sys::TT_AcquireUserDesktopWindowEx(self.inst, user_id, sys::BitmapFormat_BMP_RGB32) };
                if w.is_null() {
                    return;
                }
                // SAFETY: w is a live window; rows are nBytesPerLine apart.
                let out = unsafe {
                    let d = &*w;
                    let (wd, ht, stride) = (
                        d.nWidth.max(0) as usize,
                        d.nHeight.max(0) as usize,
                        d.nBytesPerLine.max(0) as usize,
                    );
                    let all =
                        std::slice::from_raw_parts(d.frameBuffer as *const u8, d.nFrameBufferSize.max(0) as usize);
                    let mut bgra = Vec::with_capacity(wd * ht * 4);
                    for row in 0..ht {
                        let start = row * stride;
                        if let Some(line) = all.get(start..start + wd * 4) {
                            bgra.extend_from_slice(line);
                        }
                    }
                    VideoFrame {
                        width: d.nWidth,
                        height: d.nHeight,
                        bgra,
                    }
                };
                // SAFETY: w came from the acquire above.
                unsafe { sys::TT_ReleaseUserDesktopWindow(self.inst, w) };
                out
            }
        };
        let (w, h) = (frame.width, frame.height);
        if let Ok(mut f) = self.frames.lock() {
            f.insert((user_id, kind), frame);
        }
        let due = self
            .last_frame_note
            .get(&(user_id, kind))
            .is_none_or(|t| t.elapsed() >= FRAME_EVERY);
        if due {
            self.last_frame_note.insert((user_id, kind), Instant::now());
            self.emit(Event::VideoFrame {
                user_id,
                kind,
                width: w,
                height: h,
            });
        }
    }

    /// Sends a picture as my shared desktop.
    pub(super) fn send_desktop(&mut self, width: i32, height: i32, bgra: &[u8]) -> Result<()> {
        if !self.logged_in() {
            return Err(Error::NotConnected);
        }
        if width <= 0 || height <= 0 || bgra.len() < (width * height * 4) as usize {
            return Err(Error::Refused("That picture isn't complete.".into()));
        }
        let w = sys::DesktopWindow {
            nWidth: width,
            nHeight: height,
            bmpFormat: sys::BitmapFormat_BMP_RGB32,
            nBytesPerLine: width * 4,
            nSessionID: 0,
            nProtocol: sys::DesktopProtocol_DESKTOPPROTOCOL_ZLIB_1,
            frameBuffer: bgra.as_ptr() as *mut _,
            nFrameBufferSize: (width * height * 4),
        };
        // SAFETY: inst is live; w points at `bgra`, which outlives the call.
        let r = unsafe { sys::TT_SendDesktopWindow(self.inst, &w, sys::BitmapFormat_BMP_RGB32) };
        if r < 0 {
            return Err(Error::Refused("The desktop couldn't be shared.".into()));
        }
        Ok(())
    }
}
