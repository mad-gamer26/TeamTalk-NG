//! Decoding MP3 recordings in tests.

/// An MP3 file's samples (interleaved) and its channels, decoded.
pub fn decode_mp3(path: &std::path::Path) -> (Vec<i16>, usize) {
    use symphonia::core::{
        audio::SampleBuffer, codecs::DecoderOptions, formats::FormatOptions, io::MediaSourceStream,
        meta::MetadataOptions, probe::Hint,
    };
    let file = std::fs::File::open(path).expect("the MP3");
    let mss = MediaSourceStream::new(Box::new(file), Default::default());
    let mut hint = Hint::new();
    hint.with_extension("mp3");
    let mut format = symphonia::default::get_probe()
        .format(&hint, mss, &FormatOptions::default(), &MetadataOptions::default())
        .expect("an MP3")
        .format;
    let track = format.default_track().expect("a track");
    let (id, channels) = (track.id, track.codec_params.channels.map(|c| c.count()).unwrap_or(1));
    let mut dec = symphonia::default::get_codecs()
        .make(&track.codec_params, &DecoderOptions::default())
        .expect("an MP3 decoder");
    let mut out = Vec::new();
    while let Ok(p) = format.next_packet() {
        if p.track_id() != id {
            continue;
        }
        let Ok(buf) = dec.decode(&p) else { continue };
        let mut sb = SampleBuffer::<i16>::new(buf.capacity() as u64, *buf.spec());
        sb.copy_interleaved_ref(buf);
        out.extend_from_slice(sb.samples());
    }
    (out, channels)
}
