import Foundation
import SwiftUI

/// Opt-in iCloud sync of the settings and server list (the old app's): the
/// app's whole settings store goes to iCloud's key-value store as one
/// snapshot with a time, as it changes; a newer snapshot from another
/// device is applied when the app starts (before anything loads them).
/// Passwords stay in this iPhone's keychain (NG Account carries those).
@MainActor
final class ICloudSync {
    static let shared = ICloudSync()
    static let enabledKey = "icloudSync"
    private let snapshotKey = "settingsSnapshot"
    private let timeKey = "settingsSnapshotTime"
    private let appliedKey = "icloudAppliedTime"
    private let store = NSUbiquitousKeyValueStore.default
    private let defaults = UserDefaults.standard
    private var publishing: Task<Void, Never>?
    /// Changes from another device, waiting for the next launch.
    private(set) var pendingFromCloud = false

    var enabled: Bool { defaults.bool(forKey: Self.enabledKey) }

    /// What isn't synced: this install's own values.
    private func shared(_ key: String) -> Bool {
        !(key.hasPrefix("Apple") || key.hasPrefix("NS") || key.hasPrefix("com.apple") || key.hasPrefix("WebKit")
          || [Self.enabledKey, appliedKey, "installId", "setUp", "ngEmail", "ngSyncState", "soundPacks", "soundPack"].contains(key))
    }

    private var domain: [String: Any] {
        defaults.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "") ?? [:]
    }

    /// At launch, before the settings are read: applies a newer snapshot.
    func startAtLaunch() {
        guard enabled else { return }
        store.synchronize()
        applyIfNewer()
        observe()
    }

    /// Turning it on: keep this iPhone's settings (they go to iCloud) or
    /// take iCloud's (applied when the app next starts).
    func enable(keepThisPhone: Bool) {
        defaults.set(true, forKey: Self.enabledKey)
        store.synchronize()
        if keepThisPhone || store.data(forKey: snapshotKey) == nil {
            publish()
        } else {
            pendingFromCloud = true
            defaults.set(0, forKey: appliedKey)
        }
        observe()
    }

    func disable() {
        defaults.set(false, forKey: Self.enabledKey)
        NotificationCenter.default.removeObserver(self)
    }

    var cloudHasSettings: Bool { store.synchronize(); return store.data(forKey: snapshotKey) != nil }

    private var observing = false
    private func observe() {
        guard !observing else { return }
        observing = true
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: defaults, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.schedulePublish() }
        }
        NotificationCenter.default.addObserver(forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification, object: store, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.enabled, self.store.double(forKey: self.timeKey) > self.defaults.double(forKey: self.appliedKey) else { return }
                self.pendingFromCloud = true
                announce("Settings changed on another device; they apply the next time the app starts.")
            }
        }
    }

    private func schedulePublish() {
        guard enabled, !pendingFromCloud else { return }
        publishing?.cancel()
        publishing = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            publish()
        }
    }

    private func publish() {
        let snapshot = domain.filter { shared($0.key) }
        guard let data = try? PropertyListSerialization.data(fromPropertyList: snapshot, format: .binary, options: 0) else { return }
        if data == store.data(forKey: snapshotKey) { return }
        let now = Date().timeIntervalSince1970
        store.set(data, forKey: snapshotKey)
        store.set(now, forKey: timeKey)
        defaults.set(now, forKey: appliedKey)
        store.synchronize()
    }

    private func applyIfNewer() {
        let time = store.double(forKey: timeKey)
        guard time > defaults.double(forKey: appliedKey), let data = store.data(forKey: snapshotKey),
              let snapshot = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return }
        SettingsBackup.save(reason: "Before iCloud's settings")
        var mine = domain.filter { !shared($0.key) }
        for (k, v) in snapshot where shared(k) { mine[k] = v }
        defaults.setPersistentDomain(mine, forName: Bundle.main.bundleIdentifier ?? "")
        defaults.set(time, forKey: appliedKey)
        pendingFromCloud = false
    }
}

/// Settings → iCloud sync.
struct ICloudSyncView: View {
    @State private var on = ICloudSync.shared.enabled
    @State private var asking = false
    @State private var pending = ICloudSync.shared.pendingFromCloud

    var body: some View {
        Form {
            Section {
                Toggle("Sync settings and servers with iCloud", isOn: Binding(get: { on }, set: { want in
                    if want {
                        if ICloudSync.shared.cloudHasSettings { asking = true } else { ICloudSync.shared.enable(keepThisPhone: true); on = true }
                    } else {
                        ICloudSync.shared.disable(); on = false
                    }
                }))
            } footer: {
                Text("Your settings and server list go to your iCloud account and to your other devices with this app. Passwords stay on each device, and sound packs and your NG Account stay too. Changes from another device apply the next time the app starts.")
            }
            if pending {
                Section {
                    Text("Settings from iCloud apply the next time the app starts.")
                }
            }
        }
        .navigationTitle("iCloud sync")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("iCloud already has settings", isPresented: $asking, titleVisibility: .visible) {
            Button("Use iCloud's settings") { ICloudSync.shared.enable(keepThisPhone: false); on = true; pending = true }
            Button("Keep this iPhone's settings") { ICloudSync.shared.enable(keepThisPhone: true); on = true }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Use the settings saved in iCloud (from the next start), or replace them with this iPhone's?")
        }
    }
}
