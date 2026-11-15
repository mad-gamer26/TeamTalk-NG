//! MP3 recordings. BearWare's SDK encodes MP3 only on Windows (with Media
//! Foundation), so recordings are made as WAV and turned into MP3 here,
//! with LAME, when they're finished.

use std::io::Read;
use std::path::Path;

use mp3lame_encoder::{Bitrate, Builder, FlushNoGap, InterleavedPcm, MonoPcm, Quality};

/// A 16-bit PCM WAV's format and where its samples start and end.
struct Wav {
    channels: u16,
    rate: u32,
    data: std::ops::Range<usize>,
}

fn parse_wav(b: &[u8]) -> Result<Wav, String> {
    if b.len() < 12 || &b[..4] != b"RIFF" || &b[8..12] != b"WAVE" {
        return Err("The recording isn't a WAV file.".into());
    }
    let (mut at, mut fmt) = (12, None);
    while at + 8 <= b.len() {
        let id = &b[at..at + 4];
        let size = u32::from_le_bytes([b[at + 4], b[at + 5], b[at + 6], b[at + 7]]) as usize;
        let body = at + 8;
        if id == b"fmt " && body + 16 <= b.len() {
            let ch = u16::from_le_bytes([b[body + 2], b[body + 3]]);
            let rate = u32::from_le_bytes([b[body + 4], b[body + 5], b[body + 6], b[body + 7]]);
            let bits = u16::from_le_bytes([b[body + 14], b[body + 15]]);
            if bits != 16 {
                return Err("The recording isn't 16-bit.".into());
            }
            fmt = Some((ch, rate));
        } else if id == b"data" {
            let (channels, rate) = fmt.ok_or("The recording has no format.")?;
            // A file still being written may say 0 (or too much): take what's there.
            let end = if size == 0 { b.len() } else { (body + size).min(b.len()) };
            return Ok(Wav {
                channels,
                rate,
                data: body..end,
            });
        }
        at = body + size + (size & 1);
    }
    Err("The recording has no sound in it.".into())
}

fn bitrate(kbps: u32) -> Bitrate {
    match kbps {
        0..=40 => Bitrate::Kbps32,
        41..=72 => Bitrate::Kbps64,
        73..=144 => Bitrate::Kbps128,
        145..=224 => Bitrate::Kbps192,
        225..=288 => Bitrate::Kbps256,
        _ => Bitrate::Kbps320,
    }
}

/// Turns a WAV file into an MP3 at `kbps` (deleting the WAV when `delete`).
pub fn wav_to_mp3(wav: &Path, mp3: &Path, kbps: u32, delete: bool) -> Result<(), String> {
    let mut raw = Vec::new();
    std::fs::File::open(wav)
        .and_then(|mut f| f.read_to_end(&mut raw))
        .map_err(|e| format!("The recording couldn't be read ({e})."))?;
    let w = parse_wav(&raw)?;
    let samples: Vec<i16> = raw[w.data.clone()]
        .as_chunks::<2>()
        .0
        .iter()
        .map(|c| i16::from_le_bytes(*c))
        .collect();
    let channels = w.channels.clamp(1, 2) as u8;
    let mut b = Builder::new().ok_or("The MP3 encoder couldn't start.")?;
    b.set_num_channels(channels).map_err(|e| format!("MP3: {e:?}"))?;
    b.set_sample_rate(w.rate).map_err(|e| format!("MP3: {e:?}"))?;
    b.set_brate(bitrate(kbps)).map_err(|e| format!("MP3: {e:?}"))?;
    b.set_quality(Quality::Good).map_err(|e| format!("MP3: {e:?}"))?;
    let mut enc = b
        .build()
        .map_err(|e| format!("The MP3 encoder couldn't start ({e:?})."))?;
    let mut out = Vec::with_capacity(samples.len() / 4 + 8192);
    // In pieces of a second, so the buffer stays small.
    let piece = w.rate as usize * channels as usize;
    for part in samples.chunks(piece.max(1)) {
        out.reserve(mp3lame_encoder::max_required_buffer_size(part.len()));
        let r = if channels == 1 {
            enc.encode_to_vec(MonoPcm(part), &mut out)
        } else {
            enc.encode_to_vec(InterleavedPcm(part), &mut out)
        };
        r.map_err(|e| format!("The MP3 couldn't be made ({e:?})."))?;
    }
    out.reserve(7200);
    enc.flush_to_vec::<FlushNoGap>(&mut out)
        .map_err(|e| format!("The MP3 couldn't be finished ({e:?})."))?;
    std::fs::write(mp3, &out).map_err(|e| format!("The MP3 couldn't be saved ({e})."))?;
    if delete {
        let _ = std::fs::remove_file(wav);
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tone(path: &Path, channels: u16, secs: u32) {
        let rate = 48000u32;
        let n = rate * secs * channels as u32;
        let mut w = Vec::new();
        w.extend_from_slice(b"RIFF");
        w.extend_from_slice(&(36 + n * 2).to_le_bytes());
        w.extend_from_slice(b"WAVEfmt ");
        w.extend_from_slice(&16u32.to_le_bytes());
        w.extend_from_slice(&1u16.to_le_bytes());
        w.extend_from_slice(&channels.to_le_bytes());
        w.extend_from_slice(&rate.to_le_bytes());
        w.extend_from_slice(&(rate * 2 * channels as u32).to_le_bytes());
        w.extend_from_slice(&(2 * channels).to_le_bytes());
        w.extend_from_slice(&16u16.to_le_bytes());
        w.extend_from_slice(b"data");
        w.extend_from_slice(&(n * 2).to_le_bytes());
        for i in 0..n {
            let v = ((i as f32 * 0.05).sin() * 10000.0) as i16;
            w.extend_from_slice(&v.to_le_bytes());
        }
        std::fs::write(path, w).unwrap();
    }

    #[test]
    fn wavs_become_mp3s() {
        let dir = std::env::temp_dir().join(format!("ttng-mp3-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        for ch in [1u16, 2] {
            let (wav, mp3) = (dir.join(format!("t{ch}.wav")), dir.join(format!("t{ch}.mp3")));
            tone(&wav, ch, 2);
            wav_to_mp3(&wav, &mp3, 128, true).unwrap();
            let b = std::fs::read(&mp3).unwrap();
            // An MP3 frame header (sync bits), and about 2 s at 128 kbit/s.
            assert!(b.windows(2).any(|w| w[0] == 0xff && w[1] & 0xe0 == 0xe0), "MP3 frames");
            assert!((25_000..45_000).contains(&b.len()), "{} bytes", b.len());
            assert!(!wav.exists(), "the WAV goes");
        }
        assert!(wav_to_mp3(&dir.join("none.wav"), &dir.join("none.mp3"), 128, false).is_err());
        std::fs::write(dir.join("junk.wav"), b"not a wav").unwrap();
        assert_eq!(
            wav_to_mp3(&dir.join("junk.wav"), &dir.join("junk.mp3"), 128, false),
            Err("The recording isn't a WAV file.".into())
        );
        let _ = std::fs::remove_dir_all(&dir);
    }
}
