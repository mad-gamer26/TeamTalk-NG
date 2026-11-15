import Foundation
import Observation
import UIKit

/// NG Account: signing in, and keeping saved servers the same on every
/// device signed in to the account (the old app included).
@MainActor @Observable
final class NGAccountStore {
    private unowned let app: AppModel
    private var client: NgAccountClient

    private(set) var email: String?
    private(set) var syncing = false
    private(set) var lastSynced: Date?
    private(set) var problem: String?

    var signedIn: Bool { email != nil }

    /// The session's token (the Monitor accepts it too).
    var sessionToken: String? {
        guard signedIn else { return nil }
        let t = Passwords.secret(Self.keychainService, "token")
        return t.isEmpty ? nil : t
    }

    /// What sync knows, kept between launches (no secrets: the core keeps
    /// content hashes only).
    private var state = ""
    private var again = false
    /// Installing or removing the account's packs here (not sent meanwhile).
    private var applyingPacks = false

    /// Sound packs follow the account (the old app's): which catalog packs
    /// are installed and which is chosen, as the old app's settings.
    var syncPacks: Bool = UserDefaults.standard.object(forKey: "ngSyncPacks") as? Bool ?? true {
        didSet { defaults.set(syncPacks, forKey: "ngSyncPacks"); if syncPacks { changed() } }
    }
    static let installedPacksKey = "ng_installed_catalog_packs"
    static let chosenPackKey = "ng_selected_sound_pack"
    private let defaults = UserDefaults.standard
    private static let keychainService = "TeamTalk NG account"

    init(app: AppModel) {
        self.app = app
        let token = Passwords.secret(Self.keychainService, "token")
        client = Self.makeClient(token: token.isEmpty ? nil : token)
        email = defaults.string(forKey: "ngEmail")
        if email != nil, token.isEmpty { email = nil }
        state = defaults.string(forKey: "ngSyncState") ?? ""
        if signedIn { Task { await sync() } }
    }

    static var installId: String {
        if let id = UserDefaults.standard.string(forKey: "installId") { return id }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: "installId")
        return id
    }

    private static func makeClient(token: String?) -> NgAccountClient {
        NgAccountClient(baseUrl: Service.base, installId: installId, deviceName: UIDevice.current.name, token: token)
    }

    private func saveState() {
        defaults.set(state, forKey: "ngSyncState")
    }

    // MARK: Signing in

    /// Runs a blocking call off the main thread; failures in words.
    private func call<T: Sendable>(_ f: @escaping @Sendable (NgAccountClient) throws -> T) async -> Result<T, Error> {
        let c = client
        return await Task.detached { Result { try f(c) } }.value
    }

    static func words(_ e: Error) -> String {
        switch e as? NgError {
        case .Network(let m), .SignedOut(let m), .Unexpected(let m): m
        case .Refused(_, let m): m
        case nil: e.localizedDescription
        }
    }

    /// Returns why not, or nil when it worked.
    func signIn(email: String, password: String) async -> String? {
        let e = email.trimmingCharacters(in: .whitespaces)
        switch await call({ try $0.signIn(email: e, password: password) }) {
        case .success(let s): await signedIn(s); return nil
        case .failure(let err): return Self.words(err)
        }
    }

    /// Emails a code; then `verify`.
    func signUp(email: String, password: String) async -> String? {
        let e = email.trimmingCharacters(in: .whitespaces)
        switch await call({ try $0.signUp(email: e, password: password) }) {
        case .success: return nil
        case .failure(let err): return Self.words(err)
        }
    }

    func verify(email: String, code: String) async -> String? {
        let e = email.trimmingCharacters(in: .whitespaces), c = code.trimmingCharacters(in: .whitespaces)
        switch await call({ try $0.verify(email: e, code: c) }) {
        case .success(let s): await signedIn(s); return nil
        case .failure(let err): return Self.words(err)
        }
    }

    func forgotPassword(email: String) async -> String? {
        let e = email.trimmingCharacters(in: .whitespaces)
        switch await call({ try $0.forgotPassword(email: e) }) {
        case .success: return nil
        case .failure(let err): return Self.words(err)
        }
    }

    func resetPassword(email: String, code: String, password: String) async -> String? {
        let e = email.trimmingCharacters(in: .whitespaces), c = code.trimmingCharacters(in: .whitespaces)
        switch await call({ try $0.resetPassword(email: e, code: c, password: password) }) {
        case .success(let s): await signedIn(s); return nil
        case .failure(let err): return Self.words(err)
        }
    }

    func changePassword(current: String, new: String) async -> String? {
        switch await call({ try $0.changePassword(current: current, new: new) }) {
        case .success: return nil
        case .failure(let err): return Self.words(err)
        }
    }

    private func signedIn(_ s: NgSession) async {
        Passwords.setSecret(s.token, Self.keychainService, "token")
        // The account's session gets its own notifications key.
        Service.savePushKey(s.pushKey)
        email = s.email
        defaults.set(s.email, forKey: "ngEmail")
        // A different account (or a first sign-in): everything here is new
        // to it, and everything there is new here.
        state = ""
        saveState()
        app.monitor.accountChanged()
        await sync()
    }

    /// Signs out; servers stay on this iPhone.
    func signOut() async {
        _ = await call { try $0.signOut() }
        forget()
    }

    private func forget() {
        Passwords.setSecret("", Self.keychainService, "token")
        email = nil
        defaults.removeObject(forKey: "ngEmail")
        state = ""
        saveState()
        client = Self.makeClient(token: nil)
        app.monitor.accountChanged()
    }

    // MARK: Syncing

    /// A server was added, changed or moved here.
    func changed() {
        guard signedIn else { return }
        Task { await sync() }
    }

    func deleted(_ key: String) {
        guard signedIn else { return }
        state = ngSyncDeleted(stateJson: state, key: key)
        saveState()
        Task { await sync() }
    }

    /// Pulls the account's changes, then sends this iPhone's (the core's
    /// ng_sync). The account wins a conflict (it changed elsewhere first).
    func sync() async {
        guard signedIn else { return }
        guard !syncing else { again = true; return }
        syncing = true
        defer { syncing = false }
        repeat {
            again = false
            if let failed = await syncOnce() {
                problem = failed
                return
            }
        } while again
        problem = nil
        lastSynced = .now
    }

    private func syncOnce() async -> String? {
        let local = app.servers.map { LocalServer(key: $0.key, server: Self.synced($0)) }
        let c = client, st = state
        let settings = packSettings
        let result = await Task.detached { Result { try ngSync(client: c, stateJson: st, local: local, settings: settings) } }.value
        switch result {
        case .failure(let e):
            return failed(e)
        case .success(let outcome):
            state = outcome.stateJson
            saveState()
            if outcome.changed || !outcome.rekeyed.isEmpty { apply(outcome) }
            if !outcome.settings.isEmpty { applyPacks(outcome.settings) }
            return nil
        }
    }

    private func failed(_ e: Error) -> String {
        if case .SignedOut = e as? NgError {
            forget()
            return "You were signed out of NG Account. Sign in again to sync."
        }
        return Self.words(e)
    }

    /// The synced list, into this iPhone's servers.
    private func apply(_ outcome: SyncOutcome) {
        let renamed = Dictionary(uniqueKeysWithValues: outcome.rekeyed.map { ($0.newKey, $0.oldKey) })
        var passwords: [UUID: String] = [:]
        let list: [SavedServer] = outcome.servers.map { l in
            let r = l.server
            let oldKey = renamed[l.key] ?? l.key
            var s = app.servers.first { $0.key == oldKey } ?? {
                var n = SavedServer()
                if let u = UUID(uuidString: l.key) { n.id = u }
                return n
            }()
            s.syncKey = l.key == s.id.uuidString ? nil : l.key
            s.name = r.name
            s.host = r.host
            s.tcpPort = r.tcpPort
            s.udpPort = r.udpPort
            s.encrypted = r.encrypted
            s.username = r.username
            s.nickname = r.nickname
            s.joinChannel = r.channel
            s.syncPassword = r.syncPassword
            var other = Self.dictionary(r.otherJson)
            other["statusmsg"] = r.statusMessage.isEmpty ? nil : r.statusMessage
            other["chanpasswd"] = r.channelPassword.isEmpty ? nil : r.channelPassword
            s.syncOther = Self.json(other)
            passwords[s.id] = r.password
            return s
        }
        app.applySynced(list, passwords: passwords)
    }

    // MARK: Sound packs

    private var packSettings: [SyncSetting] {
        guard syncPacks, !applyingPacks else { return [] }
        let s = app.sounds
        // A pack imported from this iPhone's files isn't in the catalog: "local".
        let chosen = s.selectedId == InstalledPack.builtIn.id ? "default"
            : SoundStore.isImported(s.selectedId) ? "local:" + s.selectedId : "catalog:" + s.selectedId
        return [SyncSetting(key: Self.installedPacksKey, json: Self.fragment(s.installed.map(\.id).filter { !SoundStore.isImported($0) }.sorted())),
                SyncSetting(key: Self.chosenPackKey, json: Self.fragment(chosen))]
    }

    private static func fragment(_ v: Any) -> String? {
        (try? JSONSerialization.data(withJSONObject: v, options: [.fragmentsAllowed, .sortedKeys])).map { String(decoding: $0, as: UTF8.self) }
    }

    private static func value(_ json: String?) -> Any? {
        json.flatMap { $0.data(using: .utf8) }.flatMap { try? JSONSerialization.jsonObject(with: $0, options: .fragmentsAllowed) }
    }

    /// The account's packs here: downloads the missing ones from the
    /// catalog, removes those removed elsewhere, then chooses as chosen.
    private func applyPacks(_ settings: [SyncSetting]) {
        let packs = settings.first { $0.key == Self.installedPacksKey }.map { Self.value($0.json) as? [String] ?? [] }
        let chosen = settings.first { $0.key == Self.chosenPackKey }.flatMap { Self.value($0.json) as? String }
        applyingPacks = true
        Task {
            defer { applyingPacks = false; changed() }
            let s = app.sounds
            let selected = s.selectedId
            if let packs {
                let want = Set(packs)
                for p in s.installed where !want.contains(p.id) && !SoundStore.isImported(p.id) { s.remove(p) }
                let missing = want.subtracting(s.installed.map(\.id))
                if !missing.isEmpty, let catalog = try? await s.catalog() {
                    for p in catalog where missing.contains(p.id) { try? await s.install(p) }
                }
                // Installing chooses the pack; the choice stays as it was.
                if s.packs.contains(where: { $0.id == selected }) { s.selectedId = selected }
            }
            if let chosen {
                let id = chosen == "default" ? InstalledPack.builtIn.id : chosen.hasPrefix("catalog:") ? String(chosen.dropFirst(8)) : nil
                if let id, s.packs.contains(where: { $0.id == id }) { s.selectedId = id }
            }
        }
    }

    // MARK: The record format

    static func synced(_ s: SavedServer) -> SyncedServer {
        var other = dictionary(s.syncOther ?? "")
        let status = other.removeValue(forKey: "statusmsg") as? String ?? ""
        let channelPassword = other.removeValue(forKey: "chanpasswd") as? String ?? ""
        let syncPassword = s.syncPassword ?? true
        return SyncedServer(
            name: s.name, host: s.host, tcpPort: s.tcpPort, udpPort: s.udpPort, encrypted: s.encrypted,
            // The core leaves passwords out of the account unless synced.
            username: s.username, password: Passwords.get(s.id), nickname: s.nickname,
            statusMessage: status, channel: s.joinChannel, channelPassword: channelPassword,
            syncPassword: syncPassword, order: 0, otherJson: json(other))
    }

    private static func dictionary(_ json: String) -> [String: Any] {
        guard let d = json.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return [:] }
        return o
    }

    private static func json(_ o: [String: Any]) -> String {
        guard !o.isEmpty, let d = try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys]) else { return "" }
        return String(decoding: d, as: UTF8.self)
    }
}
