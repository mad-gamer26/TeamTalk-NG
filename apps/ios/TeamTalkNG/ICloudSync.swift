import Foundation
import SwiftUI

/// iCloud sync (on unless turned off): the app's whole settings store and
/// server list go to iCloud's key-value store as one snapshot with a time,
/// as they change; a newer snapshot from another device is applied when
/// the app starts (before anything loads them). Server passwords and the
/// paired Monitor go through iCloud Keychain (Passwords), end to end
/// encrypted by Apple; your own sound packs through iCloud Drive.
@MainActor
final class ICloudSync {
    static let shared = ICloudSync()
    nonisolated static let enabledKey = "icloudSync"
    private let snapshotKey = "settingsSnapshot"
    private let timeKey = "settingsSnapshotTime"
    private let appliedKey = "icloudAppliedTime"
    /// Earlier copies were kept here for a while (2026-11-19); now only the
    /// current one is, like other apps: removed if present.
    private let oldHistoryKey = "settingsSnapshotHistory"
    private let store = NSUbiquitousKeyValueStore.default
    private let defaults = UserDefaults.standard
    private var publishing: Task<Void, Never>?
    /// Changes from another device, waiting for the next launch.
    private(set) var pendingFromCloud = false

    var enabled: Bool { Self.isOn }

    /// On unless turned off, and only with an iCloud account.
    nonisolated static var isOn: Bool {
        #if DEBUG
        // UI tests: on without an iCloud account (the key-value store still
        // keeps what's set, on this device).
        if forceOnForTests { return UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
        #endif
        return (UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true) && FileManager.default.ubiquityIdentityToken != nil
    }
    #if DEBUG
    nonisolated(unsafe) static var forceOnForTests = false
    #endif

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
        if defaults.object(forKey: Self.enabledKey) == nil {
            // On for the first time (now the default). A new install takes
            // what iCloud has (a new device); one already in use keeps its
            // own settings and servers and sends them, rather than taking an
            // older snapshot over them.
            defaults.set(true, forKey: Self.enabledKey)
            let fresh = !defaults.bool(forKey: "setUp") && defaults.data(forKey: "servers") == nil
            if fresh || store.data(forKey: snapshotKey) == nil { applyIfNewer() } else { publish() }
            Passwords.resync()
        } else {
            applyIfNewer()
        }
        observe()
    }

    /// Turning it on: keep this iPhone's settings (they go to iCloud) or
    /// take iCloud's (applied when the app next starts).
    func enable(keepThisPhone: Bool) {
        defaults.set(true, forKey: Self.enabledKey)
        Passwords.resync()
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
        Passwords.resync()
        NotificationCenter.default.removeObserver(self)
    }

    /// Erase All Data & Settings: off here, without copying iCloud
    /// Keychain's items back to this iPhone (as `disable` does) and without
    /// taking anything from iCloud afterwards.
    func stopForErase() {
        // A send already waiting (a change just before) must not go: it
        // would put the erased, empty settings in iCloud.
        publishing?.cancel()
        publishing = nil
        defaults.set(false, forKey: Self.enabledKey)
        NotificationCenter.default.removeObserver(self)
        observing = false
        pendingFromCloud = false
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
        // Only while on, and never over a copy from iCloud waiting to apply.
        guard enabled, !pendingFromCloud else { return }
        let snapshot = domain.filter { shared($0.key) }
        guard let data = try? PropertyListSerialization.data(fromPropertyList: snapshot, format: .binary, options: 0) else { return }
        if data == store.data(forKey: snapshotKey) { return }
        store.removeObject(forKey: oldHistoryKey)
        let now = Date().timeIntervalSince1970
        store.set(data, forKey: snapshotKey)
        store.set(now, forKey: timeKey)
        defaults.set(now, forKey: appliedKey)
        store.synchronize()
    }

    #if DEBUG
    private static func serverCount(_ data: Data) -> Int {
        guard let snap = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return 0 }
        if let d = snap["servers"] as? Data, let list = try? JSONSerialization.jsonObject(with: d) as? [Any] { return list.count }
        if let list = snap["servers"] as? [Any] { return list.count }
        return 0
    }

    #endif

    #if DEBUG
    /// UI test: a change sent to iCloud, then another change and Erase at
    /// once (as on 2026-11-19, when the waiting send put the erased, empty
    /// settings in iCloud): iCloud must keep the server. Says what happened.
    func eraseSafetyTest() async -> String {
        Self.forceOnForTests = true
        defer { Self.forceOnForTests = false }
        store.removeObject(forKey: snapshotKey); store.removeObject(forKey: timeKey)
        defaults.set(true, forKey: Self.enabledKey)
        let one = try! JSONSerialization.data(withJSONObject: [["name": "Kept server"]])
        defaults.set(one, forKey: "servers")
        pendingFromCloud = false
        publish()
        let sent = store.data(forKey: snapshotKey).map(Self.serverCount) ?? -1
        // A change (waiting 2 s to be sent), then Erase at once.
        defaults.set("someone", forKey: "nickname")
        schedulePublish()
        stopForErase()
        defaults.removeObject(forKey: "servers")
        try? await Task.sleep(for: .seconds(3))
        let afterErase = store.data(forKey: snapshotKey).map(Self.serverCount) ?? -1
        return "Erase safety: sent \(sent), after erase \(afterErase)"
    }
    #endif

    private func applyIfNewer() {
        let time = store.double(forKey: timeKey)
        guard time > defaults.double(forKey: appliedKey), let data = store.data(forKey: snapshotKey),
              let snapshot = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return }
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
                if FileManager.default.ubiquityIdentityToken == nil {
                    Text("Sign in to iCloud in the Settings app to sync.")
                } else {
                    Text("Your settings, servers and their passwords, your own sound packs and your paired Monitor go to your iCloud account and to your other devices with this app. Passwords travel through iCloud Keychain, end-to-end encrypted. Settings changed on another device apply the next time the app starts.")
                }
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
