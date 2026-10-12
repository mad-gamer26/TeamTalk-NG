//! Reading the sounds out of a zipped sound pack.

use std::io::Read;
use std::path::Path;

use anyhow::Context;

/// Every file in the zip, by its own name (folders left out), up to
/// 25 MB each.
pub fn sounds(path: &Path) -> anyhow::Result<Vec<(String, Vec<u8>)>> {
    let file = std::fs::File::open(path).with_context(|| format!("Could not open {}", path.display()))?;
    let mut zip = ::zip::ZipArchive::new(file).with_context(|| format!("{} is not a zip", path.display()))?;
    let mut out = Vec::new();
    for i in 0..zip.len() {
        let mut entry = zip.by_index(i)?;
        if entry.is_dir() || entry.size() > crate::packs::MAX_PACK_BYTES as u64 {
            continue;
        }
        let Some(name) = entry.enclosed_name().and_then(|p| p.file_name().map(|n| n.to_string_lossy().into_owned())) else {
            continue;
        };
        if name.starts_with('.') {
            continue;
        }
        let mut data = Vec::new();
        entry.read_to_end(&mut data)?;
        out.push((name, data));
    }
    Ok(out)
}

/// A zip of `files` (name, contents), stored without compression: sounds
/// are mostly compressed already.
pub fn write(files: &[(String, Vec<u8>)]) -> anyhow::Result<Vec<u8>> {
    use std::io::Write;
    let mut zip = ::zip::ZipWriter::new(std::io::Cursor::new(Vec::new()));
    let options = ::zip::write::SimpleFileOptions::default().compression_method(::zip::CompressionMethod::Stored);
    for (name, data) in files {
        zip.start_file(name.as_str(), options)?;
        zip.write_all(data)?;
    }
    Ok(zip.finish()?.into_inner())
}
