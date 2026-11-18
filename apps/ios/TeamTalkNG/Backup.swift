import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    /// A TeamTalk NG backup (.ttng): Files opens it in the app, to restore.
    static let ttngBackup = UTType(exportedAs: "com.matthewdovi.teamtalk-ng.backup")
}

/// A backup of the app in one .ttng file (a property list): its servers
/// (with each one's last channel), their passwords, its settings, its sound
/// packs (and sounds of my own), each part chosen
/// when the backup is made and again when it's restored. Not NG Account,
/// iCloud sync, AudioNet sign-ins or this install's own markers. Restoring
/// a part replaces what the app has of it.
enum Backup {
    struct Parts: Equatable {
        var servers = true
        var passwords = true
        var settings = true
        var soundPacks = true
    }

    /// What a backup file holds.
    struct Contents: Identifiable {
        let id = UUID()
        let created: Date
        let servers: Int?
        let passwords: Int?
        let settings: Bool
        let soundPacks: Int?
        fileprivate let root: [String: Any]

        var has: Parts {
            Parts(servers: servers != nil, passwords: passwords != nil, settings: settings,
                  soundPacks: soundPacks != nil)
        }
    }

    struct Problem: Error { let text: String }

    private static let format = "TeamTalk NG backup"
    private static var defaults: UserDefaults { .standard }
    private static var domainName: String { Bundle.main.bundleIdentifier ?? "" }
    private static var support: URL { FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0] }
    private static var soundPacksDir: URL { support.appendingPathComponent("SoundPacks", isDirectory: true) }

    /// Keys that are never in a backup: NG Account, iCloud sync, this
    /// install's own, and the system's.
    private static func never(_ k: String) -> Bool {
        ["ngEmail", "ngSyncState", "ngSyncPacks", "icloudSync", "icloudAppliedTime", "settingsSnapshot",
         "settingsSnapshotTime", "installId", "setUp"].contains(k)
            || k.hasPrefix("Apple") || k.hasPrefix("NS") || k.hasPrefix("com.apple") || k.hasPrefix("WebKit")
    }
    private static func isServerKey(_ k: String) -> Bool { k == "servers" || k.hasPrefix("lastChannel-") }
    private static func isSoundPackKey(_ k: String) -> Bool { k == "soundPacks" || k == "soundPack" }
    private static func isSettingKey(_ k: String) -> Bool { !never(k) && !isServerKey(k) && !isSoundPackKey(k) }

    private static var domain: [String: Any] { defaults.persistentDomain(forName: domainName) ?? [:] }

    private static func savedServers() -> [SavedServer] {
        defaults.data(forKey: "servers").flatMap { try? JSONDecoder().decode([SavedServer].self, from: $0) } ?? []
    }

    /// Every file under a folder, by its path inside it.
    private static func files(in dir: URL) -> [String: Data] {
        guard let walker = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey]) else { return [:] }
        var out: [String: Data] = [:]
        let base = dir.standardizedFileURL.path + "/"
        for case let u as URL in walker {
            guard (try? u.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true,
                  let d = try? Data(contentsOf: u) else { continue }
            out[String(u.standardizedFileURL.path.dropFirst(base.count))] = d
        }
        return out
    }

    /// Makes a backup file of the chosen parts (in a temporary folder, to
    /// be shared or saved to Files).
    static func make(_ parts: Parts) throws -> URL {
        var root: [String: Any] = ["format": format, "version": 1, "created": Date(),
                                   "app": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""]
        let d = domain
        let servers = savedServers()
        if parts.servers {
            root["servers"] = d.filter { isServerKey($0.key) }
        }
        if parts.passwords {
            var pw: [String: String] = [:]
            for s in servers {
                let p = Passwords.get(s.id)
                if !p.isEmpty { pw[s.id.uuidString] = p }
            }
            root["passwords"] = pw
        }
        if parts.settings { root["settings"] = d.filter { isSettingKey($0.key) } }
        if parts.soundPacks {
            root["soundPacks"] = ["keys": d.filter { isSoundPackKey($0.key) }, "files": files(in: soundPacksDir)] as [String: Any]
        }
        let data = try PropertyListSerialization.data(fromPropertyList: root, format: .binary, options: 0)
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH.mm"
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("TeamTalk NG backup \(f.string(from: Date())).ttng")
        try data.write(to: url, options: .completeFileProtectionUntilFirstUserAuthentication)
        return url
    }

    /// Reads a backup file (one opened from Files, or chosen).
    static func read(_ url: URL) throws -> Contents {
        let reading = url.startAccessingSecurityScopedResource()
        defer { if reading { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { throw Problem(text: "That file couldn't be read.") }
        guard let root = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              root["format"] as? String == format
        else { throw Problem(text: "That isn't a TeamTalk NG backup.") }
        guard (root["version"] as? Int ?? 0) <= 1 else {
            throw Problem(text: "That backup is from a newer TeamTalk NG. Update the app to restore it.")
        }
        let servers = (root["servers"] as? [String: Any]).map { s -> Int in
            (s["servers"] as? Data).flatMap { try? JSONDecoder().decode([SavedServer].self, from: $0) }?.count ?? 0
        }
        let packs = (root["soundPacks"] as? [String: Any]).map { p -> Int in
            ((p["keys"] as? [String: Any])?["soundPacks"] as? Data)
                .flatMap { try? JSONDecoder().decode([InstalledPack].self, from: $0) }?.count ?? 0
        }
        return Contents(created: root["created"] as? Date ?? .distantPast, servers: servers,
                        passwords: (root["passwords"] as? [String: String])?.count,
                        settings: root["settings"] is [String: Any], soundPacks: packs, root: root)
    }

    /// Replaces the chosen parts with the backup's (the app's model is made
    /// again afterwards, so everything reads them).
    static func restore(_ c: Contents, _ parts: Parts) {
        let root = c.root
        var d = domain
        if parts.servers, let s = root["servers"] as? [String: Any] {
            d = d.filter { !isServerKey($0.key) }
            for (k, v) in s where isServerKey(k) { d[k] = v }
        }
        if parts.settings, let s = root["settings"] as? [String: Any] {
            d = d.filter { !isSettingKey($0.key) }
            for (k, v) in s where isSettingKey(k) { d[k] = v }
        }
        if parts.soundPacks, let p = root["soundPacks"] as? [String: Any] {
            d = d.filter { !isSoundPackKey($0.key) }
            for (k, v) in (p["keys"] as? [String: Any]) ?? [:] where isSoundPackKey(k) { d[k] = v }
            replaceFiles(soundPacksDir, with: p["files"] as? [String: Data] ?? [:])
        }
        defaults.setPersistentDomain(d, forName: domainName)
        if parts.passwords, let pw = root["passwords"] as? [String: String] {
            for (id, p) in pw { if let u = UUID(uuidString: id) { Passwords.set(p, for: u) } }
        }
    }

    private static func replaceFiles(_ dir: URL, with files: [String: Data]) {
        let fm = FileManager.default
        try? fm.removeItem(at: dir)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        for (path, data) in files {
            // Only inside the folder.
            guard !path.split(separator: "/").contains(".."), !path.hasPrefix("/") else { continue }
            let u = dir.appendingPathComponent(path)
            try? fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: u, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
    }
}

extension Notification.Name {
    /// A backup was restored: the app makes its model again.
    static let ttngRestored = Notification.Name("ttngRestored")
}

/// Settings → Backup and Restore.
struct BackupView: View {
    @State private var parts = Backup.Parts()
    @State private var choosing = false
    @State private var problem: String?
    @State private var restoring: Backup.Contents?

    var body: some View {
        Form {
            Section {
                Toggle("Servers", isOn: $parts.servers)
                Toggle("Server passwords", isOn: $parts.passwords)
                Toggle("Settings", isOn: $parts.settings)
                Toggle("Sound packs", isOn: $parts.soundPacks)
                Button("Make a backup") {
                    do {
                        presentShareSheet([try Backup.make(parts)])
                    } catch {
                        problem = "The backup couldn't be made: \(error.localizedDescription)"
                    }
                }
                .disabled(parts == Backup.Parts(servers: false, passwords: false, settings: false, soundPacks: false))
            } header: {
                Text("Back up")
            } footer: {
                Text(parts.passwords
                     ? "Makes a .ttng file to save in Files or send. With Server passwords on, the file holds your servers' passwords, readable by anyone who has it. NG Account and iCloud sync aren't part of a backup."
                     : "Makes a .ttng file to save in Files or send. NG Account and iCloud sync aren't part of a backup.")
            }
            Section {
                Button("Restore a backup") { choosing = true }
            } footer: {
                Text("Choose a .ttng file, or open one from the Files app.")
            }
        }
        .navigationTitle("Backup and Restore")
        .navigationBarTitleDisplayMode(.inline)
        .fileImporter(isPresented: $choosing, allowedContentTypes: [.ttngBackup]) { r in
            guard case .success(let url) = r else { return }
            do { restoring = try Backup.read(url) } catch let p as Backup.Problem { problem = p.text } catch { problem = "\(error)" }
        }
        .sheet(item: $restoring) { c in RestoreBackupView(contents: c) }
        .alert("Backup and Restore", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
            Button("OK") {}
        } message: { Text(problem ?? "") }
    }
}

/// Restoring a backup: what it holds, chosen part by part, asked first.
struct RestoreBackupView: View {
    let contents: Backup.Contents
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var parts = Backup.Parts()
    @State private var confirming = false

    private func count(_ n: Int?, _ one: String, _ many: String) -> String {
        guard let n else { return "" }
        return n == 1 ? "1 \(one)" : "\(n) \(many)"
    }

    var body: some View {
        let has = contents.has
        NavigationStack {
            Form {
                Section {
                    Text("Made \(contents.created.formatted(date: .abbreviated, time: .shortened)).")
                }
                Section {
                    if has.servers { Toggle("Servers (\(count(contents.servers, "server", "servers")))", isOn: $parts.servers) }
                    if has.passwords { Toggle("Server passwords (\(count(contents.passwords, "password", "passwords")))", isOn: $parts.passwords) }
                    if has.settings { Toggle("Settings", isOn: $parts.settings) }
                    if has.soundPacks { Toggle("Sound packs (\(count(contents.soundPacks, "pack", "packs")))", isOn: $parts.soundPacks) }
                } header: {
                    Text("Restore")
                } footer: {
                    Text("Each part you restore replaces what the app has of it now. You're disconnected from every server first.")
                }
            }
            .navigationTitle("Restore a backup")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Restore") { confirming = true }
                        .disabled(!chosen.servers && !chosen.passwords && !chosen.settings && !chosen.soundPacks)
                }
            }
            .confirmationDialog("Restore this backup?", isPresented: $confirming, titleVisibility: .visible) {
                Button("Restore", role: .destructive) {
                    model.retireForRestore()
                    Backup.restore(contents, chosen)
                    dismiss()
                    NotificationCenter.default.post(name: .ttngRestored, object: nil)
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("What you chose replaces what's in the app now.")
            }
        }
    }

    /// What's chosen, of what the backup has.
    private var chosen: Backup.Parts {
        let h = contents.has
        return Backup.Parts(servers: parts.servers && h.servers, passwords: parts.passwords && h.passwords,
                            settings: parts.settings && h.settings, soundPacks: parts.soundPacks && h.soundPacks)
    }
}
