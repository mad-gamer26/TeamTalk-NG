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

/// Copies of the settings and server list, kept in the app's files: one
/// each time the app starts with a different server list or settings than
/// the last copy, and one before iCloud's settings replace them. The last
/// ten are kept; Settings → Settings backups restores one (at the next
/// start, before anything reads the settings).
enum SettingsBackup {
    struct Entry: Identifiable, Hashable {
        let url: URL
        let date: Date
        let servers: Int
        let reason: String
        var id: URL { url }
    }

    private static let keep = 10
    private static var dir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Settings backups", isDirectory: true)
    }
    private static var pendingRestore: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("restore-settings.plist")
    }

    private static var domain: [String: Any] {
        UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "") ?? [:]
    }

    private static func serverCount(_ d: [String: Any]) -> Int {
        guard let data = d["servers"] as? Data,
              let list = try? JSONSerialization.jsonObject(with: data) as? [Any] else { return 0 }
        return list.count
    }

    /// Saves a copy of the settings now (only when they hold something and
    /// differ from the newest copy).
    static func save(reason: String) {
        let d = domain
        guard !d.isEmpty, let data = try? PropertyListSerialization.data(fromPropertyList: d, format: .binary, options: 0)
        else { return }
        let fm = FileManager.default
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        if let newest = all().first, let old = try? Data(contentsOf: newest.url), (try? payload(old)) == data { return }
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let wrapper: [String: Any] = ["reason": reason, "date": Date(), "settings": data]
        guard let file = try? PropertyListSerialization.data(fromPropertyList: wrapper, format: .binary, options: 0) else { return }
        try? file.write(to: dir.appendingPathComponent("\(stamp).plist"),
                        options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        for old in all().dropFirst(keep) { try? fm.removeItem(at: old.url) }
    }

    private static func payload(_ file: Data) throws -> Data? {
        let o = try PropertyListSerialization.propertyList(from: file, format: nil) as? [String: Any]
        return o?["settings"] as? Data
    }

    /// The copies, newest first.
    static func all() -> [Entry] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return urls.compactMap { u -> Entry? in
            guard u.pathExtension == "plist", let file = try? Data(contentsOf: u),
                  let o = try? PropertyListSerialization.propertyList(from: file, format: nil) as? [String: Any],
                  let data = o["settings"] as? Data,
                  let settings = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
            else { return nil }
            return Entry(url: u, date: o["date"] as? Date ?? .distantPast, servers: serverCount(settings),
                         reason: o["reason"] as? String ?? "")
        }
        .sorted { $0.date > $1.date }
    }

    /// Restores a copy the next time the app starts.
    static func restoreAtNextStart(_ e: Entry) -> Bool {
        try? FileManager.default.removeItem(at: pendingRestore)
        return (try? FileManager.default.copyItem(at: e.url, to: pendingRestore)) != nil
    }

    static var restorePending: Bool { FileManager.default.fileExists(atPath: pendingRestore.path) }

    /// At start, before anything reads the settings: a restore asked for.
    static func applyPendingRestore() {
        guard let file = try? Data(contentsOf: pendingRestore),
              let data = try? payload(file),
              let settings = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return }
        save(reason: "Before restoring a backup")
        UserDefaults.standard.setPersistentDomain(settings, forName: Bundle.main.bundleIdentifier ?? "")
        try? FileManager.default.removeItem(at: pendingRestore)
    }
}

/// Settings → Settings backups.
struct SettingsBackupsView: View {
    @State private var entries = SettingsBackup.all()
    @State private var chosen: SettingsBackup.Entry?
    @State private var pending = SettingsBackup.restorePending

    var body: some View {
        Form {
            if pending {
                Section { Text("The backup you chose is restored the next time the app starts.") }
            }
            Section {
                if entries.isEmpty { Text("No backups yet.").foregroundStyle(.secondary) }
                ForEach(entries) { e in
                    Button {
                        chosen = e
                    } label: {
                        VStack(alignment: .leading) {
                            Text(e.date.formatted(date: .abbreviated, time: .shortened))
                            Text("\(e.servers == 1 ? "1 server" : "\(e.servers) servers")\(e.reason.isEmpty ? "" : ", \(e.reason.lowercased())")")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            } footer: {
                Text("A copy of your settings and server list is kept each time the app starts with changes, and before iCloud's settings replace them (the last ten). Passwords stay in the keychain and aren't part of a backup.")
            }
        }
        .navigationTitle("Settings backups")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Restore this backup?", isPresented: Binding(get: { chosen != nil }, set: { if !$0 { chosen = nil } }),
                            titleVisibility: .visible, presenting: chosen) { e in
            Button("Restore") {
                pending = SettingsBackup.restoreAtNextStart(e)
                announce(pending ? "Restored the next time the app starts." : "The backup couldn't be restored.")
            }
            Button("Cancel", role: .cancel) {}
        } message: { e in
            Text("Your settings and servers become those of \(e.date.formatted(date: .abbreviated, time: .shortened)) the next time the app starts. Your current ones are backed up first.")
        }
    }
}
