//! Sound packs published through NG Account, through the calls the app
//! makes, on a private copy of the real service (ngmon): a pack backed up,
//! its sounds uploaded, published under its name and author, changed,
//! unpublished, deleted; the catalog everyone browses shows it meanwhile.

#[path = "../../ttng-services/tests/common/mod.rs"]
mod ng;

use ttng_ffi::*;

/// A short valid WAV (the service checks that sounds look like audio).
fn wav(tone: u8) -> Vec<u8> {
    let samples: Vec<u8> = (0..800u32)
        .flat_map(|i| (((i % 40) as i16 - 20) * tone as i16 * 50).to_le_bytes())
        .collect();
    let mut w = Vec::new();
    w.extend_from_slice(b"RIFF");
    w.extend_from_slice(&(36 + samples.len() as u32).to_le_bytes());
    w.extend_from_slice(b"WAVEfmt ");
    w.extend_from_slice(&16u32.to_le_bytes());
    w.extend_from_slice(&1u16.to_le_bytes());
    w.extend_from_slice(&1u16.to_le_bytes());
    w.extend_from_slice(&16000u32.to_le_bytes());
    w.extend_from_slice(&32000u32.to_le_bytes());
    w.extend_from_slice(&2u16.to_le_bytes());
    w.extend_from_slice(&16u16.to_le_bytes());
    w.extend_from_slice(b"data");
    w.extend_from_slice(&(samples.len() as u32).to_le_bytes());
    w.extend_from_slice(&samples);
    w
}

fn catalog(url: &str) -> Vec<serde_json::Value> {
    let body = ureq::get(format!("{url}/v1/catalog"))
        .call()
        .unwrap()
        .body_mut()
        .read_to_string()
        .unwrap();
    let v: serde_json::Value = serde_json::from_str(&body).unwrap();
    v["packs"].as_array().cloned().unwrap_or_default()
}

#[test]
fn a_pack_is_published_changed_and_withdrawn() {
    let Some(svc) = ng::Ngmon::start() else { return };
    let email = "packs@example.com";
    let me = NgAccountClient::new(svc.url.clone(), "install-packs".into(), "iPhone".into(), None);
    me.sign_up(email.into(), "correct horse battery".into()).unwrap();
    me.verify(email.into(), svc.code(email)).unwrap();

    // Backed up (privately), its sounds in it.
    let p = me
        .backup_pack("own-1234".into(), "Soft beeps".into())
        .expect("backed up");
    assert_eq!((p.local_id.as_str(), p.public), ("own-1234", false));
    me.upload_pack_file(p.id.clone(), "logged_on.wav".into(), wav(3))
        .expect("a sound");
    let p = me
        .upload_pack_file(p.id.clone(), "vox_me_enable.wav".into(), wav(5))
        .expect("another");
    assert_eq!(p.files.len(), 2);
    // Backing up again finds the same one.
    assert_eq!(me.backup_pack("own-1234".into(), "Soft beeps".into()).unwrap().id, p.id);
    assert!(
        catalog(&svc.url).iter().all(|c| c["id"] != p.id.as_str()),
        "not in the catalog yet"
    );

    // Published under its name and author.
    let p = me
        .change_pack(
            p.id.clone(),
            Some("Soft beeps".into()),
            Some("Matt".into()),
            Some("Quiet sounds.".into()),
            Some(true),
        )
        .expect("published");
    assert!(p.public);
    let listed = catalog(&svc.url);
    let c = listed
        .iter()
        .find(|c| c["id"] == p.id.as_str())
        .expect("in the catalog");
    assert_eq!(
        (c["name"].as_str(), c["author"].as_str()),
        (Some("Soft beeps"), Some("Matt"))
    );

    // Changed: a sound gone, the name new.
    let p = me
        .remove_pack_file(p.id.clone(), "vox_me_enable.wav".into())
        .expect("removed");
    assert_eq!(p.files.len(), 1);
    me.change_pack(p.id.clone(), Some("Softer beeps".into()), None, None, None)
        .unwrap();
    let mine = me.my_packs().unwrap();
    assert_eq!(mine.len(), 1);
    assert_eq!(
        (mine[0].name.as_str(), mine[0].author.as_str(), mine[0].public),
        ("Softer beeps", "Matt", true)
    );

    // Withdrawn, then deleted.
    me.change_pack(p.id.clone(), None, None, None, Some(false)).unwrap();
    assert!(
        catalog(&svc.url).iter().all(|c| c["id"] != p.id.as_str()),
        "out of the catalog"
    );
    me.delete_pack(p.id.clone()).expect("deleted");
    assert!(me.my_packs().unwrap().is_empty());
}
