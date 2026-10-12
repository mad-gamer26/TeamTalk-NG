/*
 * Syncing saved servers and settings with the NG Account. Each phone
 * remembers what it last synced, so it only sends what changed on it and
 * never overwrites newer data it didn't touch; when two phones change the
 * same thing, the latest change wins.
 */

import CryptoKit
import Foundation
import UIKit

extension Notification.Name {
    /// The saved server list was saved (by this app).
    static let localServersSaved = Notification.Name("LocalServersSaved")
    /// Synced servers or settings from the account were applied here.
    static let ngSyncApplied = Notification.Name("NGSyncApplied")
}

@MainActor
final class NGSync {
    static let shared = NGSync()

    /// Saved in the app's settings but not settings, or synced another way.
    private static let notSettings: Set<String> = [
        SERVER_LIST_KEY,                   // synced as servers
        "settings.selectedSoundPackID",    // sound pack sync chooses the pack
        ICloudSync.enabledKey,
        PREF_GENERAL_GENDER_NEUTRAL_MIGRATED, PREF_GENERAL_GENDER_ORDER_MIGRATED,
    ]
    /// What iOS itself keeps in an app's settings.
    private static let systemPrefixes = ["Apple", "NS", "com.apple.", "WebKit", "AK", "PK", "MSV", "INNext", "_"]

    private static let packKeys = [NGPackSync.installedCatalogKey, NGPackSync.selectedPackKey]

    /// Every setting syncs (as iCloud sync did), however particular to an
    /// iPhone: one another iPhone can't use (a voice it doesn't have, a
    /// microphone it doesn't have) falls back to the default there.
    static func isSetting(_ key: String) -> Bool {
        !notSettings.contains(key) && !packKeys.contains(key) && !systemPrefixes.contains { key.hasPrefix($0) }
    }

    /// The app's settings as saved on this iPhone (not the defaults it
    /// starts from).
    private static var saved: [String: Any] {
        UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "") ?? [:]
    }

    private func isSynced(_ key: String) -> Bool {
        Self.packKeys.contains(key) ? NGAccountCenter.shared.isSyncing(.soundPacks) : (syncsSettings && Self.isSetting(key))
    }

    /// The settings that sync now: those saved here, and those synced
    /// before (so a removed one is removed elsewhere too).
    private func syncedKeys(_ s: State) -> [String] {
        let known = s.records.keys.filter { $0.hasPrefix("setting:") }.map { String($0.dropFirst("setting:".count)) }
        return Set(Self.saved.keys).union(known).union(Self.packKeys).filter { isSynced($0) }.sorted()
    }

    /// What this iPhone last synced, kept between launches.
    private struct State: Codable {
        /// The account it belongs to; another account starts over.
        var email: String
        /// The account's revision as of the last pull.
        var rev: Int64 = 0
        /// Each record's revision and the hash of its data as last synced
        /// ("server:<id>", "setting:<key>").
        var records: [String: Synced] = [:]
    }

    private struct Synced: Codable {
        var rev: Int64
        var hash: String
    }

    private var state: State?
    private var running = false
    private var again = false
    private var pending: DispatchWorkItem?
    /// Applying the account's data here: these saves are not new changes.
    private var applying = false

    private static var stateURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?.appendingPathComponent("NGSync.json")
    }

    private init() {
        NotificationCenter.default.addObserver(forName: .localServersSaved, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.localChange() }
        }
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.localChange() }
        }
        NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncSoon() }
        }
    }

    /// Start syncing (at launch).
    func start() {
        guard NGAccountCenter.shared.isSignedIn else { return }
        syncSoon()
    }

    /// What synced settings and servers looked like at the last check, so
    /// changes to anything else (a volume, a sound device) cost nothing.
    private var lastFingerprint: String?

    private func fingerprint() -> String {
        let defaults = UserDefaults.standard
        let saved = Self.saved
        var parts = saved.keys.filter { Self.isSetting($0) || Self.packKeys.contains($0) }.sorted().map { "\($0)=\(saved[$0] ?? "-")" }
        parts.append((defaults.array(forKey: SERVER_LIST_KEY) as? [Data])?.map { $0.base64EncodedString() }.joined(separator: ",") ?? "")
        return Self.hash(parts.joined(separator: "\n"))
    }

    private func localChange() {
        guard !applying, NGAccountCenter.shared.isSignedIn else { return }
        let now = fingerprint()
        guard now != lastFingerprint else { return }
        lastFingerprint = now
        syncSoon(delay: 1.5)
    }

    /// Sync shortly, once, however many changes come meanwhile.
    func syncSoon(delay: TimeInterval = 0.3) {
        guard NGAccountCenter.shared.isSignedIn else { return }
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in await self?.syncNow() }
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Signed in: a new account takes this iPhone's servers and settings;
    /// an existing one brings its own, and this iPhone adds what it has
    /// that the account doesn't.
    func signedIn(newAccount: Bool) {
        state = nil
        if let url = Self.stateURL { try? FileManager.default.removeItem(at: url) }
        // iCloud sync is replaced by the account (its data is already here).
        if ICloudSync.shared.isEnabled {
            ICloudSync.shared.setEnabled(false)
        }
        syncSoon(delay: 0)
    }

    /// Servers or settings syncing turned back on: while it was off this
    /// iPhone kept up with the account's revision without applying anything,
    /// so that category is pulled from the start. The account's servers and
    /// settings arrive (servers matched to this iPhone's), and what only this
    /// iPhone has is sent.
    func turnedOn(_ category: NGAccountCenter.Category) {
        guard let email = NGAccountCenter.shared.email else { return }
        let prefix: String
        switch category {
        case .servers: prefix = "server:"
        case .settings: prefix = "setting:"
        case .soundPacks: return
        }
        var s = loadState(email: email)
        s.records = s.records.filter { !$0.key.hasPrefix(prefix) }
        s.rev = 0
        saveState(s)
        syncSoon(delay: 0)
    }

    func signedOut() {
        pending?.cancel()
        state = nil
        if let url = Self.stateURL { try? FileManager.default.removeItem(at: url) }
    }

    /// Signing out with "remove": the servers that came from the account go.
    func removeLocalCopy() {
        // What this iPhone synced, from memory or (right after launch,
        // before a sync) from what it saved.
        let saved = Self.stateURL.flatMap { try? Data(contentsOf: $0) }.flatMap { try? JSONDecoder().decode(State.self, from: $0) }
        guard let state = state ?? saved else { return }
        let synced = Set(state.records.keys.filter { $0.hasPrefix("server:") }.map { String($0.dropFirst("server:".count)) })
        applying = true
        saveLocalServers(loadLocalServers().filter { !synced.contains($0.syncID) })
        applying = false
        NotificationCenter.default.post(name: .ngSyncApplied, object: nil)
    }

    // MARK: Syncing

    func syncNow() async {
        guard let email = NGAccountCenter.shared.email else { return }
        if running {
            again = true
            return
        }
        running = true
        defer { running = false }
        repeat {
            again = false
            do {
                try await cycle(email: email)
            } catch NGAccountError.signedOut {
                return
            } catch {
                print("NG Account sync failed: \(error.localizedDescription)")
                return
            }
        } while again
    }

    private func loadState(email: String) -> State {
        if let state, state.email == email { return state }
        if let url = Self.stateURL, let data = try? Data(contentsOf: url),
           let s = try? JSONDecoder().decode(State.self, from: data), s.email == email {
            return s
        }
        return State(email: email)
    }

    private func saveState(_ s: State) {
        state = s
        if let url = Self.stateURL, let data = try? JSONEncoder().encode(s) {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
    }

    private var syncsServers: Bool { NGAccountCenter.shared.isSyncing(.servers) }
    private var syncsSettings: Bool { NGAccountCenter.shared.isSyncing(.settings) }

    private func cycle(email: String) async throws {
        var s = loadState(email: email)
        ensureServerIDs()

        // 1. What changed in the account.
        let pulled = try await NGAccountCenter.shared.signed { try await $0.pull(since: s.rev) }
        if pulled.reset {
            s = State(email: email)
        }
        apply(pulled.records, to: &s)
        s.rev = max(s.rev, pulled.rev)
        saveState(s)

        // 2. What changed here, sent; changed elsewhere meanwhile: this
        // phone's change is the latest, so it goes again from there.
        var changes = localChanges(s)
        for _ in 0..<2 where !changes.isEmpty {
            let result = try await NGAccountCenter.shared.signed { try await $0.push(changes) }
            for r in result.applied {
                if let hash = changes.first(where: { $0.kind == r.kind && $0.key == r.key }).map({ Self.hash($0.deleted ? nil : $0.data) }) {
                    s.records["\(r.kind):\(r.key)"] = Synced(rev: r.rev, hash: hash)
                }
            }
            s.rev = max(s.rev, result.rev)
            saveState(s)
            changes = result.conflicts.compactMap { conflict in
                changes.first { $0.kind == conflict.kind && $0.key == conflict.key }.map {
                    var c = $0
                    c.baseRev = conflict.rev
                    return c
                }
            }
        }
    }

    // MARK: Applying the account's data

    private func apply(_ records: [NGSyncRecord], to s: inout State) {
        var servers: [Server]?
        applying = true
        defer {
            applying = false
            // What was just applied is not a change to send back.
            lastFingerprint = fingerprint()
        }
        for r in records {
            let id = "\(r.kind):\(r.key)"
            switch r.kind {
            case "setting" where isSynced(r.key):
                if r.deleted {
                    UserDefaults.standard.removeObject(forKey: r.key)
                } else if let v = r.data, !(v is NSNull) {
                    UserDefaults.standard.set(v, forKey: r.key)
                }
                s.records[id] = Synced(rev: r.rev, hash: Self.hash(r.deleted ? nil : Self.settingValue(r.key)))
            case "server" where syncsServers:
                if servers == nil { servers = loadLocalServers() }
                if r.deleted {
                    servers?.removeAll { $0.syncID == r.key }
                    s.records[id] = Synced(rev: r.rev, hash: Self.hash(nil))
                } else if let data = r.data as? [String: Any] {
                    let server = servers?.first { $0.syncID == r.key }
                        ?? servers?.first { $0.servertype == .LOCAL && s.records["server:\($0.syncID)"] == nil && Self.sameLogin($0, data) }
                        ?? {
                            let new = Server()
                            servers?.append(new)
                            return new
                        }()
                    server.syncID = r.key
                    Self.fill(server, from: data)
                    var synced = Self.serverData(server)
                    synced["order"] = data["order"]
                    s.records[id] = Synced(rev: r.rev, hash: Self.hash(synced))
                }
            default:
                break
            }
        }
        if var list = servers {
            // The account's order, with servers it doesn't know where they were.
            let order = Dictionary(uniqueKeysWithValues: records.compactMap { r -> (String, Int)? in
                guard r.kind == "server", let o = (r.data as? [String: Any])?["order"] as? Int else { return nil }
                return (r.key, o)
            })
            if !order.isEmpty {
                let indexed = list.enumerated().map { ($0.offset, $0.element) }
                list = indexed.sorted { a, b in
                    (order[a.1.syncID] ?? a.0) < (order[b.1.syncID] ?? b.0)
                }.map(\.1)
            }
            saveLocalServers(list)
            NotificationCenter.default.post(name: .ngSyncApplied, object: nil)
        }
        if records.contains(where: { $0.kind == "setting" }) {
            NotificationCenter.default.post(name: .ngSyncApplied, object: nil)
        }
    }

    // MARK: This iPhone's changes

    private func localChanges(_ s: State) -> [NGSyncChange] {
        var changes = [NGSyncChange]()
        do {
            for key in syncedKeys(s) {
                let value = Self.settingValue(key)
                let id = "setting:\(key)"
                let hash = Self.hash(value)
                let known = s.records[id]
                if known?.hash == hash { continue }
                // Never set here and not in the account: nothing to say.
                if value == nil && known == nil { continue }
                changes.append(NGSyncChange(kind: "setting", key: key, baseRev: known?.rev ?? 0, deleted: value == nil, data: value))
            }
        }
        if syncsServers {
            let servers = loadLocalServers().filter { $0.servertype == .LOCAL }
            var present = Set<String>()
            for (i, server) in servers.enumerated() {
                present.insert(server.syncID)
                var data = Self.serverData(server)
                data["order"] = i
                let id = "server:\(server.syncID)"
                let known = s.records[id]
                if known?.hash == Self.hash(data) { continue }
                changes.append(NGSyncChange(kind: "server", key: server.syncID, baseRev: known?.rev ?? 0, deleted: false, data: data))
            }
            for (id, known) in s.records where id.hasPrefix("server:") && known.hash != Self.hash(nil) {
                let key = String(id.dropFirst("server:".count))
                if !present.contains(key) {
                    changes.append(NGSyncChange(kind: "server", key: key, baseRev: known.rev, deleted: true, data: nil))
                }
            }
        }
        return changes
    }

    /// A setting's value as saved, if JSON can carry it; nil when unset (or
    /// only at its default).
    private static func settingValue(_ key: String) -> Any? {
        guard let v = saved[key] else { return nil }
        if v is String || v is NSNumber { return v }
        if JSONSerialization.isValidJSONObject([v]) { return v }
        return nil
    }

    /// Servers saved before syncing had no ID: give them one, once.
    private func ensureServerIDs() {
        let servers = loadLocalServers()
        guard servers.contains(where: { $0.syncID.isEmpty }) else { return }
        for s in servers where s.syncID.isEmpty {
            s.syncID = UUID().uuidString
        }
        applying = true
        saveLocalServers(servers)
        applying = false
        lastFingerprint = fingerprint()
    }

    private static func serverData(_ s: Server) -> [String: Any] {
        var d: [String: Any] = [
            "name": s.name, "ipaddr": s.ipaddr, "tcpport": s.tcpport, "udpport": s.udpport,
            "username": s.username, "nickname": s.nickname, "statusmsg": s.statusmsg, "channel": s.channel,
            "encrypted": s.encrypted, "cacertdata": s.cacertdata, "certdata": s.certdata, "certverifypeer": s.certverifypeer,
            "sync_password": s.syncPassword,
        ]
        // Passwords (and the client certificate's key) only when allowed.
        if s.syncPassword {
            d["password"] = s.password
            d["chanpasswd"] = s.chanpasswd
            d["certprivkeydata"] = s.certprivkeydata
        }
        return d
    }

    private static func fill(_ s: Server, from d: [String: Any]) {
        s.name = d["name"] as? String ?? s.name
        s.ipaddr = d["ipaddr"] as? String ?? s.ipaddr
        s.tcpport = d["tcpport"] as? Int ?? s.tcpport
        s.udpport = d["udpport"] as? Int ?? s.udpport
        s.username = d["username"] as? String ?? s.username
        s.nickname = d["nickname"] as? String ?? s.nickname
        s.statusmsg = d["statusmsg"] as? String ?? s.statusmsg
        s.channel = d["channel"] as? String ?? s.channel
        s.encrypted = d["encrypted"] as? Bool ?? s.encrypted
        s.cacertdata = d["cacertdata"] as? String ?? s.cacertdata
        s.certdata = d["certdata"] as? String ?? s.certdata
        s.certverifypeer = d["certverifypeer"] as? Bool ?? s.certverifypeer
        s.syncPassword = d["sync_password"] as? Bool ?? true
        // Without them (not synced from that phone), keep this phone's.
        if let p = d["password"] as? String { s.password = p }
        if let p = d["chanpasswd"] as? String { s.chanpasswd = p }
        if let p = d["certprivkeydata"] as? String { s.certprivkeydata = p }
        s.servertype = .LOCAL
    }

    private static func sameLogin(_ s: Server, _ d: [String: Any]) -> Bool {
        s.ipaddr.caseInsensitiveCompare(d["ipaddr"] as? String ?? "") == .orderedSame
            && s.tcpport == d["tcpport"] as? Int
            && s.username == d["username"] as? String ?? ""
    }

    /// A stable hash of JSON-able data (nil: deleted or unset).
    private static func hash(_ value: Any?) -> String {
        guard let value, !(value is NSNull) else { return "-" }
        let data = (try? JSONSerialization.data(withJSONObject: [value], options: [.sortedKeys, .fragmentsAllowed])) ?? Data("\(value)".utf8)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
