import Foundation
import SwiftUI

/// Whether the app's saved settings can be read. After the iPhone
/// restarts, nothing protected "until first unlock" (the app's settings,
/// keychain passwords, its files) can be read until the person unlocks it
/// once; an app started in the background before then (by a Live Activity,
/// a push, Siri or a Control Center control) sees empty settings, and
/// saving then replaces the real ones with nothing. That happened on
/// 2026-11-16: a Live Activity restarted the app 18 seconds before the
/// first unlock, and its empty server list was saved once the phone was
/// unlocked.
///
/// Not `UIApplication.isProtectedDataAvailable`: that is false whenever the
/// phone is locked, but the settings stay readable once it has been
/// unlocked after a restart (Siri and Control Center work while locked).
/// The test is a file with the settings' own protection class.
enum SettingsAccess {
    private static var probe: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("unlock-probe")
    }

    /// True once the iPhone has been unlocked since it last restarted.
    static var readable: Bool {
        let fm = FileManager.default
        if fm.fileExists(atPath: probe.path) {
            return (try? Data(contentsOf: probe)) != nil
        }
        // First run: creating it fails before the first unlock as well.
        try? fm.createDirectory(at: probe.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            try Data("ok".utf8).write(to: probe, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            return true
        } catch {
            return false
        }
    }
}
