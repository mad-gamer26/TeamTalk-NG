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

    /// `keepThisPhone`: this iPhone's settings and servers become iCloud's
    /// (coming from NG Account, they're newer than any snapshot iCloud kept
    /// from before).
    func setEnabled(_ enabled: Bool, keepThisPhone: Bool = false) {
        applyingRemote = true
        defaults.set(enabled, forKey: Self.enabledKey)
        applyingRemote = false
        guard enabled else { return }
        store.synchronize()
        if !keepThisPhone, let snapshot = store.dictionary(forKey: snapshotKey) {
            apply(snapshot: snapshot)
        } else {
            publish()
        }
    }

    /// What iCloud has, if it has anything.
    func cloudSnapshot() -> [String: Any]? {
        store.synchronize()
        return store.dictionary(forKey: snapshotKey)
    }

    private var notSettings: Set<String> { [SERVER_LIST_KEY, Self.enabledKey, selectedSoundPackIDKey] }

    private func servers(in snapshot: [String: Any]) -> [Server] {
        (snapshot[SERVER_LIST_KEY] as? [Data] ?? []).compactMap { NSKeyedUnarchiver.unarchiveObject(with: $0) as? Server }
    }

    /// The same server in another list: by its sync ID, or by its login.
    private func match(_ server: Server, in list: [Server]) -> Server? {
        list.first { !server.syncID.isEmpty && $0.syncID == server.syncID }
            ?? list.first {
                $0.ipaddr.caseInsensitiveCompare(server.ipaddr) == .orderedSame && $0.tcpport == server.tcpport && $0.username == server.username
            }
    }

    private func sameDetails(_ a: Server, _ b: Server) -> Bool {
        a.name == b.name && a.ipaddr == b.ipaddr && a.tcpport == b.tcpport && a.udpport == b.udpport
            && a.username == b.username && a.password == b.password && a.nickname == b.nickname
            && a.statusmsg == b.statusmsg && a.channel == b.channel && a.chanpasswd == b.chanpasswd
            && a.encrypted == b.encrypted && a.cacertdata == b.cacertdata && a.certdata == b.certdata
            && a.certprivkeydata == b.certprivkeydata && a.certverifypeer == b.certverifypeer
    }

    /// Whether iCloud's snapshot and this iPhone disagree about anything
    /// both have: a setting with another value, or the same server with
    /// other details. What only one side has is kept either way, and order
    /// alone doesn't count.
    func differs(from snapshot: [String: Any]) -> Bool {
        let local = defaults.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "") ?? [:]
        // Settings only: not what iOS keeps in the app's settings, and not
        // internal markers.
        for (key, value) in snapshot where !notSettings.contains(key) && NGSync.isSetting(key) {
            if let mine = local[key], !(mine as AnyObject).isEqual(value) {
                return true
            }
        }
        let mine = loadLocalServers()
        return servers(in: snapshot).contains { server in
            match(server, in: mine).map { !sameDetails($0, server) } ?? false
        }
    }

    /// Turn iCloud sync on, joining what iCloud has with this iPhone's:
    /// servers are combined (no duplicates); settings and servers both sides
    /// have come from this iPhone (`keepThisPhone`) or from iCloud; what
    /// only one side has is kept. The result is what iCloud syncs from now on.
    func join(keepThisPhone: Bool) {
        let snapshot = cloudSnapshot() ?? [:]
        let mine = loadLocalServers()
        let theirs = servers(in: snapshot)
        let combined = keepThisPhone
            ? mine + theirs.filter { match($0, in: mine) == nil }
            : theirs + mine.filter { match($0, in: theirs) == nil }
        applyingRemote = true
        defaults.set(true, forKey: Self.enabledKey)
        if !keepThisPhone {
            for (key, value) in snapshot where !notSettings.contains(key) && NGSync.isSetting(key) {
                defaults.set(value, forKey: key)
            }
        }
        saveLocalServers(combined)
        applyingRemote = false
        publish()
        SoundPackStore.shared.reloadFromDisk()
        NotificationCenter.default.post(name: .iCloudSettingsDidApply, object: nil)
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
