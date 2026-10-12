/*
 * Sound packs and the NG Account: packs made on this iPhone are backed up
 * privately to the account and come back on a new iPhone; deleting one
 * deletes it everywhere. Packs from the catalog aren't uploaded: which are
 * installed, and which pack is chosen, sync as settings, and a new iPhone
 * downloads them again.
 */

import CryptoKit
import Foundation
import UIKit

@MainActor
final class NGPackSync {
    static let shared = NGPackSync()

    /// Settings this keeps up to date for syncing: installed catalog packs,
    /// and the chosen pack ("catalog:<id>", "account:<pack id>" or
    /// "default").
    static let installedCatalogKey = "ng_installed_catalog_packs"
    static let selectedPackKey = "ng_selected_sound_pack"

    /// What this iPhone last backed up: the account's pack for each of its
    /// packs, and each sound's hash.
    private struct State: Codable {
        var email: String
        var packs: [String: BackedUp] = [:]
        /// Catalog packs this account owns, by catalog ID: their sounds as
        /// last synced here.
        var catalog: [String: BackedUp]?
    }

    private struct BackedUp: Codable {
        var packID: String
        var files: [String: String]
        var name: String
    }

    /// Catalog packs installed here that belong to this account, by
    /// catalog ID: their owner can publish, change and delete them.
    private(set) var ownedCatalogPacks: [String: NGPack] = [:]

    /// The account's packs as of the last sync, by this iPhone's pack ID.
    private(set) var accountPacks: [String: NGPack] = [:]

    /// The account's copy of one of this iPhone's packs, if it has one.
    func accountPack(forLocal id: String) -> NGPack? {
        guard enabled, loadState()?.packs[id] != nil else { return nil }
        return accountPacks[id]
    }

    func owns(catalogID: String?) -> Bool {
        catalogID.map { ownedCatalogPacks[$0] != nil } ?? false
    }

    private var running = false
    private var again = false
    private var pending: DispatchWorkItem?
    private var applying = false

    private static var stateURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?.appendingPathComponent("NGPackSync.json")
    }

    private init() {
        NotificationCenter.default.addObserver(forName: .soundPacksChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.applying else { return }
                self.noteSelection()
                self.syncSoon(delay: 2)
            }
        }
        // The installed or chosen packs arrived from another device.
        NotificationCenter.default.addObserver(forName: .ngSyncApplied, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncSoon() }
        }
    }

    var enabled: Bool { NGAccountCenter.shared.isSignedIn && NGAccountCenter.shared.isSyncing(.soundPacks) }

    func start() {
        noteSelection()
        syncSoon()
    }

    func syncSoon(delay: TimeInterval = 0.5) {
        guard enabled else { return }
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in await self?.syncNow() }
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func signedOut() {
        pending?.cancel()
        if let url = Self.stateURL { try? FileManager.default.removeItem(at: url) }
    }

    /// Signing out with "remove": this iPhone's packs that are in the
    /// account go, and so do packs from the catalog (the account knows which
    /// were installed, so signing in again downloads them). Packs not yet
    /// backed up stay, so nothing is lost.
    func removeLocalCopy() {
        let store = SoundPackStore.shared
        let backedUp = Set(loadState()?.packs.keys.map { $0 } ?? [])
        applying = true
        for pack in store.customPacks where backedUp.contains(pack.id) || pack.catalogID != nil {
            try? store.deletePack(pack.id)
        }
        applying = false
    }

    private func loadState() -> State? {
        guard let url = Self.stateURL, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(State.self, from: data)
    }

    private func saveState(_ s: State) {
        guard let url = Self.stateURL, let data = try? JSONEncoder().encode(s) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    // MARK: The installed and chosen packs, as settings

    /// Write which catalog packs are installed and which pack is chosen
    /// where NG Account's settings sync picks them up.
    private func noteSelection() {
        let store = SoundPackStore.shared
        let catalog = store.customPacks.compactMap(\.catalogID).sorted()
        let defaults = UserDefaults.standard
        if defaults.stringArray(forKey: Self.installedCatalogKey) != catalog {
            defaults.set(catalog, forKey: Self.installedCatalogKey)
        }
        let selected: String
        if let pack = store.pack(for: store.selectedPackID), !pack.isDefault {
            if let c = pack.catalogID {
                selected = "catalog:" + c
            } else if let backed = loadState()?.packs[pack.id] {
                selected = "account:" + backed.packID
            } else {
                selected = "local:" + pack.id
            }
        } else {
            selected = "default"
        }
        if defaults.string(forKey: Self.selectedPackKey) != selected {
            defaults.set(selected, forKey: Self.selectedPackKey)
        }
    }

    // MARK: Syncing

    func syncNow() async {
        guard enabled, let email = NGAccountCenter.shared.email else { return }
        if running {
            again = true
            return
        }
        running = true
        defer { running = false }
        repeat {
            again = false
            do {
                try await backUpAndRestore(email: email)
                await installCatalogPacks()
                applySelection()
            } catch NGAccountError.signedOut {
                return
            } catch {
                print("NG Account sound pack sync failed: \(error.localizedDescription)")
                return
            }
        } while again
    }

    private func backUpAndRestore(email: String) async throws {
        var s = loadState().flatMap { $0.email == email ? $0 : nil } ?? State(email: email)
        let store = SoundPackStore.shared
        let remote = try await NGAccountCenter.shared.signed { try await $0.packs() }.packs
        let byLocal = Dictionary(remote.map { ($0.localId, $0) }, uniquingKeysWith: { a, _ in a })
        let mine = store.customPacks.filter { $0.catalogID == nil }
        let owned = Dictionary(remote.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        ownedCatalogPacks = Dictionary(store.customPacks.compactMap { p in p.catalogID.flatMap { owned[$0] }.map { ($0.id, $0) } },
                                       uniquingKeysWith: { a, _ in a })

        // Deleted on another device: delete here too.
        for (localID, backed) in s.packs where !remote.contains(where: { $0.id == backed.packID }) {
            if store.pack(for: localID) != nil {
                applying = true
                try? store.deletePack(localID)
                applying = false
            }
            s.packs[localID] = nil
        }
        // Deleted here: delete from the account.
        for p in remote where s.packs[p.localId] != nil && store.pack(for: p.localId) == nil {
            try await NGAccountCenter.shared.signed { try await $0.deletePack(p.id) }
            s.packs[p.localId] = nil
        }
        saveState(s)

        // This iPhone's packs and the account's copies, kept the same:
        // what changed here goes up, what changed in the account comes
        // down (by each sound's hash as last synced here).
        for pack in mine {
            var a = byLocal[pack.id]
            if a == nil {
                a = try await NGAccountCenter.shared.signed { try await $0.backupPack(localID: pack.id, name: pack.name) }
            }
            guard var account = a else { continue }
            let base = s.packs[pack.id]
            var name = pack.name
            if let base, base.name == pack.name, account.name != pack.name {
                // Renamed on another device.
                applying = true
                try? store.renamePack(pack.id, to: account.name)
                applying = false
                name = account.name
            } else if account.name != pack.name {
                account = try await NGAccountCenter.shared.signed { [account] in try await $0.changePack(account.id, NGPackChange(name: pack.name)) }
            }
            let (synced, files) = try await reconcile(pack.id, with: account, base: base?.files)
            s.packs[pack.id] = BackedUp(packID: synced.id, files: files, name: name)
            accountPacks[pack.id] = synced
            saveState(s)
        }

        // Catalog packs this account owns: the same, so sounds changed
        // here are published as a new version for everyone who installed
        // the pack, and the owner's other iPhones follow.
        var catalogState = s.catalog ?? [:]
        for pack in store.customPacks {
            guard let catalogID = pack.catalogID, let account = ownedCatalogPacks[catalogID] else { continue }
            // Not synced here before: as installed, it was the account's
            // version, or an older one to bring up to date.
            let base = catalogState[catalogID]?.files
                ?? (pack.version == account.version
                    ? Dictionary(account.files.map { ($0.name, $0.hash) }, uniquingKeysWith: { a, _ in a })
                    : localHashes(pack.id))
            let (synced, files) = try await reconcile(pack.id, with: account, base: base)
            ownedCatalogPacks[catalogID] = synced
            catalogState[catalogID] = BackedUp(packID: synced.id, files: files, name: synced.name)
            if pack.version != synced.version {
                applying = true
                try? store.setVersion(synced.version, for: pack.id)
                applying = false
            }
        }
        s.catalog = catalogState
        saveState(s)

        // The account's packs this iPhone doesn't have: restore them. Not
        // Official ones or ones from the catalog: those install from the
        // catalog, like anyone's.
        for p in remote where store.pack(for: p.localId) == nil && s.packs[p.localId] == nil && !p.files.isEmpty
            && !p.official && store.installedPack(catalogID: p.id) == nil {
            let zip = try await NGAccountCenter.shared.signed { try await $0.packZip(p.id) }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".zip")
            try zip.write(to: url)
            defer { try? FileManager.default.removeItem(at: url) }
            applying = true
            defer { applying = false }
            _ = try store.restorePackArchive(from: url, id: p.localId, name: p.name)
            s.packs[p.localId] = BackedUp(packID: p.id, files: Dictionary(p.files.map { ($0.name, $0.hash) }, uniquingKeysWith: { a, _ in a }), name: p.name)
            accountPacks[p.localId] = p
            saveState(s)
        }
    }

    private func localHashes(_ packID: String) -> [String: String] {
        var hashes = [String: String]()
        for (name, url) in SoundPackStore.shared.customSoundFiles(in: packID) {
            if let data = try? Data(contentsOf: url) {
                hashes[name] = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            }
        }
        return hashes
    }

    /// Make one of this iPhone's packs and the account's copy the same,
    /// sound by sound. Against `base` (each sound as last synced here): a
    /// sound changed here goes up, one changed in the account comes down,
    /// and with no base this iPhone's sounds win. Returns the account's
    /// pack and the sounds' hashes now.
    private func reconcile(_ packID: String, with account: NGPack, base: [String: String]?) async throws -> (NGPack, [String: String]) {
        let store = SoundPackStore.shared
        var a = account
        let local = Dictionary(store.customSoundFiles(in: packID).map { ($0.name, $0.url) }, uniquingKeysWith: { x, _ in x })
        let localHash = localHashes(packID)
        let remote = Dictionary(a.files.map { ($0.name, $0.hash) }, uniquingKeysWith: { x, _ in x })
        // A sound is one file whatever its format: compare by sound name.
        func stem(_ n: String) -> String { (n as NSString).deletingPathExtension }
        var sounds = Set<String>()
        for n in Array(localHash.keys) + Array(remote.keys) + Array((base ?? [:]).keys) { sounds.insert(stem(n)) }
        func file(_ m: [String: String], _ sound: String) -> (name: String, hash: String)? {
            m.first { stem($0.key) == sound }.map { ($0.key, $0.value) }
        }
        var now = [String: String]()
        for sound in sounds {
            let l = file(localHash, sound), r = file(remote, sound), b = base.flatMap { file($0, sound) }
            if l?.hash == r?.hash {
                if let l { now[l.name] = l.hash }
                continue
            }
            let changedHere = base == nil || l?.hash != b?.hash
            if changedHere {
                if let l, let url = local[l.name], let data = try? Data(contentsOf: url) {
                    do {
                        a = try await NGAccountCenter.shared.signed { [a] in try await $0.uploadSound(pack: a.id, name: l.name, data: data) }
                        now[l.name] = l.hash
                    } catch NGAccountError.refused(let why) {
                        // This one sound (not the rest of the pack): left
                        // out of what's synced, so it's tried again.
                        print("NG Account: \(l.name) was not backed up: \(why)")
                        if let b { now[b.name] = b.hash }
                    }
                } else if let r {
                    a = try await NGAccountCenter.shared.signed { [a] in try await $0.removeSound(pack: a.id, name: r.name) }
                }
            } else {
                applying = true
                defer { applying = false }
                if let r {
                    let data = try await NGAccountCenter.shared.signed { [a] in try await $0.downloadSound(pack: a.id, name: r.name) }
                    try store.writeSound(data, fileName: r.name, in: packID)
                    now[r.name] = r.hash
                } else if let l {
                    store.removeSound(fileName: l.name, in: packID)
                }
            }
        }
        return (a, now)
    }

    /// Catalog packs installed on another device, downloaded here too.
    private func installCatalogPacks() async {
        let wanted = UserDefaults.standard.stringArray(forKey: Self.installedCatalogKey) ?? []
        let store = SoundPackStore.shared
        let missing = wanted.filter { store.installedPack(catalogID: $0) == nil }
        guard !missing.isEmpty, let catalog = try? await store.catalog() else { return }
        for pack in catalog where missing.contains(pack.id) {
            guard let archive = try? await store.downloadCatalogPack(pack) else { continue }
            applying = true
            _ = try? store.importCatalogPackArchive(from: archive, remotePack: pack, selectAfterImport: false)
            applying = false
            try? FileManager.default.removeItem(at: archive)
        }
    }

    /// The pack chosen on another device, chosen here too.
    private func applySelection() {
        guard let selected = UserDefaults.standard.string(forKey: Self.selectedPackKey) else { return }
        let store = SoundPackStore.shared
        let state = loadState()
        var target: String?
        if selected == "default" {
            target = SoundPackStore.defaultSoundPackID
        } else if selected.hasPrefix("catalog:") {
            target = store.installedPack(catalogID: String(selected.dropFirst("catalog:".count)))?.id
        } else if selected.hasPrefix("account:") {
            let id = String(selected.dropFirst("account:".count))
            target = state?.packs.first { $0.value.packID == id }?.key
        } else if selected.hasPrefix("local:") {
            target = store.pack(for: String(selected.dropFirst("local:".count)))?.id
        }
        if let target, target != store.selectedPackID {
            applying = true
            store.selectPack(target)
            applying = false
        }
    }
}
