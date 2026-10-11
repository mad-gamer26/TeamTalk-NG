import Foundation

/// Opt-in synchronization of the app's persisted preferences and server list.
/// UserDefaults remains the local source of truth; iCloud KVS carries a plist-safe
/// snapshot so all existing settings (including dynamically-created audio keys)
/// are covered without maintaining a second list of preferences.
final class ICloudSync {
    static let shared = ICloudSync()
    static let enabledKey = "icloud_sync_enabled"

    private let snapshotKey = "teamtalk_settings_snapshot_v1"
    private let timestampKey = "teamtalk_settings_snapshot_timestamp_v1"
    private let selectedSoundPackIDKey = "settings.selectedSoundPackID"
    private let defaults = UserDefaults.standard
    private let store = NSUbiquitousKeyValueStore.default
    private var applyingRemote = false

    private init() {
        NotificationCenter.default.addObserver(self, selector: #selector(defaultsChanged), name: UserDefaults.didChangeNotification, object: defaults)
        NotificationCenter.default.addObserver(self, selector: #selector(ubiquitousStoreChanged(_:)), name: NSUbiquitousKeyValueStore.didChangeExternallyNotification, object: store)
    }

    var isEnabled: Bool { defaults.bool(forKey: Self.enabledKey) }

    func startIfEnabled() {
        guard isEnabled else { return }
        store.synchronize()
        if store.object(forKey: timestampKey) != nil, let snapshot = store.dictionary(forKey: snapshotKey) {
            apply(snapshot: snapshot)
        } else {
            publish()
        }
    }

    func setEnabled(_ enabled: Bool) {
        applyingRemote = true
        defaults.set(enabled, forKey: Self.enabledKey)
        applyingRemote = false
        guard enabled else { return }
        store.synchronize()
        if let snapshot = store.dictionary(forKey: snapshotKey) {
            apply(snapshot: snapshot)
        } else {
            publish()
        }
    }

    @objc private func defaultsChanged() {
        guard isEnabled, applyingRemote == false else { return }
        publish()
    }

    @objc private func ubiquitousStoreChanged(_ notification: Notification) {
        // KVS delivers this on a background queue; observers of .iCloudSettingsDidApply update UI.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isEnabled, self.applyingRemote == false,
                  let snapshot = self.store.dictionary(forKey: self.snapshotKey) else { return }
            self.apply(snapshot: snapshot)
        }
    }

    private func publish() {
        guard let domain = defaults.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "") else { return }
        var snapshot = domain
        snapshot.removeValue(forKey: Self.enabledKey)
        snapshot.removeValue(forKey: selectedSoundPackIDKey)
        store.set(snapshot, forKey: snapshotKey)
        store.set(Date().timeIntervalSince1970, forKey: timestampKey)
        store.synchronize()
    }

    private func apply(snapshot: [String: Any]) {
        applyingRemote = true
        defer { applyingRemote = false }
        var restoredDomain = snapshot
        restoredDomain[Self.enabledKey] = true
        if let localPackID = defaults.string(forKey: selectedSoundPackIDKey) {
            restoredDomain[selectedSoundPackIDKey] = localPackID
        } else {
            restoredDomain.removeValue(forKey: selectedSoundPackIDKey)
        }
        defaults.setPersistentDomain(restoredDomain, forName: Bundle.main.bundleIdentifier ?? "")
        defaults.synchronize()
        SoundPackStore.shared.reloadFromDisk()
        saveControlCenterServers(loadLocalServers())
        NotificationCenter.default.post(name: .iCloudSettingsDidApply, object: nil)
    }
}

extension Notification.Name {
    static let iCloudSettingsDidApply = Notification.Name("iCloudSettingsDidApply")
    static let ttsVoiceDidChange = Notification.Name("ttsVoiceDidChange")
    static let fileSortPreferenceDidChange = Notification.Name("fileSortPreferenceDidChange")
}
