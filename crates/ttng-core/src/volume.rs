//! Volumes as BearWare's desktop client has them (qtTeamTalk's
//! utilsound.cpp): a percent from 0 to 100 on a curve, 50 being the SDK's
//! default level, so a step of 1 sounds alike anywhere on the scale. The
//! same curve serves people's voice and media volumes, the output volume
//! and the microphone's gain.

use ttng_sys as sys;

/// The desktop's refVolume: a percent (0–100) to the SDK's volume.
pub fn level(percent: i32) -> i32 {
    if percent <= 0 {
        return 0;
    }
    let p = f64::from(percent.min(100));
    ((82.832 * (0.0508 * p).exp() - 50.0) as i32).min(sys::SoundLevel_SOUND_VOLUME_MAX as i32)
}

/// The desktop's refVolumeToPercent: the SDK's volume to a percent.
pub fn percent(level: i32) -> i32 {
    if level <= 0 {
        return 0;
    }
    let d = ((f64::from(level) + 50.0) / 82.832).ln() / 0.0508;
    ((d + 0.5) as i32).clamp(0, 100)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_desktops_curve() {
        // 50 is the SDK's default level (1000), as on the desktop.
        assert!(
            (level(50) - sys::SoundLevel_SOUND_VOLUME_DEFAULT as i32).abs() <= 2,
            "{}",
            level(50)
        );
        assert_eq!(level(0), 0);
        assert!(level(100) > 13_000 && level(100) <= sys::SoundLevel_SOUND_VOLUME_MAX as i32);
        // Every percent comes back as itself.
        for p in 0..=100 {
            assert_eq!(percent(level(p)), p, "{p}");
        }
        assert_eq!(percent(sys::SoundLevel_SOUND_VOLUME_DEFAULT as i32), 50);
    }
}
