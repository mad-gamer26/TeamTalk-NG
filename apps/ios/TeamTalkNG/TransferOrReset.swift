import Security
import SwiftUI
import UserNotifications

/// Settings → Transfer or Reset (as the iPhone's own Settings): Backup and
/// Restore, Reset All Settings, and Erase All Data & Settings.
struct TransferOrResetView: View {
    @Environment(AppModel.self) private var model
    @State private var resetting = false
    @State private var erasing = false
    @State private var reallyErasing = false

    var body: some View {
        Form {
            Section {
                NavigationLink("Backup and Restore") { BackupView() }
            } footer: {
                Text("Save your servers, passwords, settings and sound packs to a file, or bring them back from one, to move them to another iPhone or keep them safe.")
            }
            Section {
                Button("Reset All Settings", role: .destructive) { resetting = true }
            } footer: {
                Text("Settings go back to how they were at first. Servers, your NG Account and sound packs stay.")
            }
            Section {
                Button("Erase All Data & Settings", role: .destructive) { erasing = true }
            } footer: {
                Text("Everything TeamTalk NG keeps on this iPhone goes: servers and their passwords, settings, sound packs, recordings, chat logs, your NG Account sign-in and the Monitor here. What's in iCloud and on your other devices stays; iCloud sync is turned off on this iPhone, so nothing comes back until you turn it on again.")
            }
        }
        .navigationTitle("Transfer or Reset")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Reset all settings?", isPresented: $resetting, titleVisibility: .visible) {
            Button("Reset All Settings", role: .destructive) { model.resetPreferences(); announce("Settings reset") }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Servers, your NG Account and sound packs stay.")
        }
        .confirmationDialog("Erase all data and settings?", isPresented: $erasing, titleVisibility: .visible) {
            Button("Continue", role: .destructive) { reallyErasing = true }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Everything TeamTalk NG keeps on this iPhone goes. iCloud and your other devices keep their copies.")
        }
        .confirmationDialog("This can't be undone", isPresented: $reallyErasing, titleVisibility: .visible) {
            Button("Erase All Data & Settings", role: .destructive) {
                Task { await EraseAll.run(model) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("To keep anything, make a backup first (Backup and Restore).")
        }
    }
}

extension Notification.Name {
    /// Everything was erased: the app starts again as a fresh install.
    static let ttngErased = Notification.Name("ttngErased")
}

/// Erase All Data & Settings: this iPhone only (the owner's choice). What's
/// in iCloud (iCloud Keychain, the settings copy, own packs in iCloud
/// Drive) is left alone, and iCloud sync is turned off here so none of it
/// comes back by itself. The Monitor is only forgotten here; it keeps
/// watching for other devices.
enum EraseAll {
    @MainActor static func run(_ model: AppModel) async {
        // Off the servers, and out of NG Account (this session only).
        model.retireForRestore()
        if model.account.signedIn { await model.account.signOut() }
        LiveActivities.shared.endLeftovers()
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
        UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
        ICloudSync.shared.stopForErase()
        model.sounds.stopWatchingCloud()
        wipeStored()
        NotificationCenter.default.post(name: .ttngErased, object: nil)
    }

    /// What the app keeps on this iPhone, gone (iCloud's copies stay).
    static func wipeStored() {
        let d = UserDefaults.standard
        if let id = Bundle.main.bundleIdentifier { d.removePersistentDomain(forName: id) }
        // Off here, so iCloud's copies stay there (and nothing comes back).
        d.set(false, forKey: ICloudSync.enabledKey)
        if let g = Bundle.main.object(forInfoDictionaryKey: "TTNGAppGroup") as? String, let gd = UserDefaults(suiteName: g) {
            for k in gd.dictionaryRepresentation().keys { gd.removeObject(forKey: k) }
        }
        // Keychain items only on this iPhone; those in iCloud Keychain stay
        // (deleting one there deletes it on every device), and the app
        // doesn't read them while iCloud sync is off.
        SecItemDelete([kSecClass as String: kSecClassGenericPassword,
                       kSecAttrSynchronizable as String: kCFBooleanFalse!] as CFDictionary)
        let fm = FileManager.default
        for dir in [FileManager.SearchPathDirectory.documentDirectory, .applicationSupportDirectory, .cachesDirectory] {
            if let u = fm.urls(for: dir, in: .userDomainMask).first,
               let items = try? fm.contentsOfDirectory(at: u, includingPropertiesForKeys: nil) {
                for i in items { try? fm.removeItem(at: i) }
            }
        }
        for i in (try? fm.contentsOfDirectory(at: fm.temporaryDirectory, includingPropertiesForKeys: nil)) ?? [] {
            try? fm.removeItem(at: i)
        }
    }
}
