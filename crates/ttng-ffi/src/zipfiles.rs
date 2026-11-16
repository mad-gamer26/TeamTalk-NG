//! Sound packs as .zip files (the desktop's sounds, flat, by their names):
//! one written for sharing, and one read when imported.

use std::fs;
use std::io::{Read, Write};
use std::path::Path;

use crate::{Result, TtError};

fn refused(message: impl Into<String>) -> TtError {
    TtError::Refused {
        message: message.into(),
    }
}

/// Zips the files directly in `folder` (not its folders or hidden files)
/// into `zip_path`; how many went in.
#[uniffi::export]
pub fn zip_folder(folder: String, zip_path: String) -> Result<u32> {
    let out = fs::File::create(&zip_path).map_err(|e| refused(format!("The zip couldn't be made ({e}).")))?;
    let mut zip = zip::ZipWriter::new(out);
    let options = zip::write::SimpleFileOptions::default().compression_method(zip::CompressionMethod::Deflated);
    let mut entries: Vec<_> = fs::read_dir(&folder)
        .map_err(|e| refused(format!("The pack couldn't be read ({e}).")))?
        .filter_map(|e| e.ok())
        .filter(|e| e.file_type().map(|t| t.is_file()).unwrap_or(false))
        .collect();
    entries.sort_by_key(|e| e.file_name());
    let mut n = 0;
    for e in entries {
        let name = e.file_name().to_string_lossy().into_owned();
        if name.starts_with('.') {
            continue;
        }
        let data = fs::read(e.path()).map_err(|e| refused(format!("{name} couldn't be read ({e}).")))?;
        zip.start_file(name.as_str(), options)
            .map_err(|e| refused(format!("The zip couldn't be made ({e}).")))?;
        zip.write_all(&data)
            .map_err(|e| refused(format!("The zip couldn't be made ({e}).")))?;
        n += 1;
    }
    zip.finish()
        .map_err(|e| refused(format!("The zip couldn't be made ({e}).")))?;
    Ok(n)
}

/// Unzips the files in `zip_path` into `folder`, flat: each by its own
/// name only (whatever folders it was in), never a hidden file or one of
/// macOS's resource forks; at most 64 MB in all. How many came out.
#[uniffi::export]
pub fn unzip_flat(zip_path: String, folder: String) -> Result<u32> {
    let f = fs::File::open(&zip_path).map_err(|e| refused(format!("The zip couldn't be read ({e}).")))?;
    let mut zip = zip::ZipArchive::new(f).map_err(|_| refused("That isn't a zip file."))?;
    fs::create_dir_all(&folder).map_err(|e| refused(format!("The pack couldn't be made ({e}).")))?;
    let mut n = 0;
    let mut total: u64 = 0;
    for i in 0..zip.len() {
        let mut entry = zip.by_index(i).map_err(|_| refused("The zip is damaged."))?;
        let path = entry.name().map(|n| n.into_owned()).unwrap_or_default();
        if !entry.is_file() || path.is_empty() || path.contains("__MACOSX") {
            continue;
        }
        let Some(name) = Path::new(&path).file_name().map(|n| n.to_string_lossy().into_owned()) else {
            continue;
        };
        if name.starts_with('.') || name.is_empty() {
            continue;
        }
        total += entry.size();
        if total > 64 * 1024 * 1024 {
            return Err(refused("The zip is too large for a sound pack."));
        }
        let mut data = Vec::with_capacity(entry.size() as usize);
        entry
            .read_to_end(&mut data)
            .map_err(|_| refused("The zip is damaged."))?;
        fs::write(Path::new(&folder).join(&name), data)
            .map_err(|e| refused(format!("{name} couldn't be written ({e}).")))?;
        n += 1;
    }
    Ok(n)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_folder_zips_and_unzips_flat() {
        let base = std::env::temp_dir().join(format!("ttng-zip-{}", std::process::id()));
        let src = base.join("src");
        fs::create_dir_all(src.join("sub")).unwrap();
        fs::write(src.join("logged_on.wav"), b"RIFF one").unwrap();
        fs::write(src.join("vox_me_enable.mp3"), b"two").unwrap();
        fs::write(src.join(".hidden"), b"no").unwrap();
        fs::write(src.join("sub").join("inner.wav"), b"no").unwrap();
        let z = base.join("pack.zip");
        assert_eq!(
            zip_folder(src.to_string_lossy().into(), z.to_string_lossy().into()).unwrap(),
            2
        );
        let out = base.join("out");
        assert_eq!(
            unzip_flat(z.to_string_lossy().into(), out.to_string_lossy().into()).unwrap(),
            2
        );
        assert_eq!(fs::read(out.join("logged_on.wav")).unwrap(), b"RIFF one");
        assert!(out.join("vox_me_enable.mp3").exists() && !out.join(".hidden").exists());
        assert!(
            unzip_flat(
                src.join("logged_on.wav").to_string_lossy().into(),
                out.to_string_lossy().into()
            )
            .is_err()
        );
        let _ = fs::remove_dir_all(&base);
    }
}
