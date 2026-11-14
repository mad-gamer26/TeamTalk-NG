import AVFoundation
import CryptoKit
import Foundation
import Observation

/// The sounds a pack can have (TeamTalk's file names, shared by every pack).
enum SoundEvent: String, CaseIterable, Identifiable, Codable {
    case on, off
    case channelMessage = "channel_msg", privateMessage = "user_msg", broadcastMessage = "broadcast_msg"
    case serverLost = "serverlost"
    case userJoined = "newuser", userLeft = "removeuser"
    case loggedIn = "logged_on", loggedOut = "logged_off"
    case fileUpdate = "fileupdate", transferComplete = "filetx_complete"

    var id: Self { self }
    var fileName: String { rawValue + ".wav" }

    var label: String {
        switch self {
        case .on: "Talking starts"
        case .off: "Talking stops"
        case .channelMessage: "Channel message"
        case .privateMessage: "Private message"
        case .broadcastMessage: "Broadcast message"
        case .serverLost: "Connection lost"
        case .userJoined: "Someone joins your channel"
        case .userLeft: "Someone leaves your channel"
        case .loggedIn: "Someone logs in to the server"
        case .loggedOut: "Someone logs out of the server"
        case .fileUpdate: "Channel files change"
        case .transferComplete: "Transfer finished"
        }
    }
}

/// A pack in the catalog (ttmonitor.mad-gamer.com).
struct CatalogPack: Decodable, Identifiable, Hashable {
    struct File: Decodable, Hashable {
        let name: String
        let size: Int
        let hash: String
    }
    let id: String
    let name: String
    let author: String
    let description: String
    let version: String
    let official: Bool
    let size: Int
    let files: [File]
}

/// A pack on this iPhone: the built-in one, or one from the catalog.
struct InstalledPack: Codable, Identifiable, Hashable {
    let id: String
    var name: String
    var author: String
    var version: String

    static let builtIn = InstalledPack(id: "default", name: "TeamTalk (built in)", author: "BearWare.dk", version: "")
}

/// Sound packs, the chosen one, volume and which events sound; plays them.
@MainActor @Observable
final class SoundStore {
    static let catalogBase = URL(string: "https://ttmonitor.mad-gamer.com")!

    private(set) var installed: [InstalledPack] = []
    var selectedId: String = InstalledPack.builtIn.id { didSet { save() } }
    /// 0–1.
    var volume: Double = 0.8 { didSet { save() } }
    private(set) var disabled: Set<SoundEvent> = []

    private let defaults = UserDefaults.standard
    private var players: [AVAudioPlayer] = []

    init() {
        if let d = defaults.data(forKey: "soundPacks"), let p = try? JSONDecoder().decode([InstalledPack].self, from: d) {
            installed = p
        }
        selectedId = defaults.string(forKey: "soundPack") ?? InstalledPack.builtIn.id
        volume = defaults.object(forKey: "soundVolume") as? Double ?? 0.8
        disabled = Set((defaults.stringArray(forKey: "soundsOff") ?? []).compactMap(SoundEvent.init(rawValue:)))
    }

    var packs: [InstalledPack] { [InstalledPack.builtIn] + installed }
    var selected: InstalledPack { packs.first { $0.id == selectedId } ?? .builtIn }

    private func save() {
        defaults.set(try? JSONEncoder().encode(installed), forKey: "soundPacks")
        defaults.set(selectedId, forKey: "soundPack")
        defaults.set(volume, forKey: "soundVolume")
        defaults.set(disabled.map(\.rawValue), forKey: "soundsOff")
    }

    func isOn(_ e: SoundEvent) -> Bool { !disabled.contains(e) }

    func setOn(_ e: SoundEvent, _ on: Bool) {
        if on { disabled.remove(e) } else { disabled.insert(e) }
        save()
    }

    // MARK: Playing

    /// Plays an event's sound (if it's on), mixed with the voices.
    func play(_ e: SoundEvent) {
        guard isOn(e) else { return }
        preview(e)
    }

    /// Plays it whether it's on or not (trying sounds in Settings).
    func preview(_ e: SoundEvent, pack: InstalledPack? = nil) {
        guard let url = url(for: e, in: pack ?? selected), let p = try? AVAudioPlayer(contentsOf: url) else { return }
        p.volume = Float(volume)
        players.removeAll { !$0.isPlaying }
        players.append(p)
        p.play()
    }

    /// The pack's sound, or the built-in one where it has none.
    private func url(for e: SoundEvent, in pack: InstalledPack) -> URL? {
        if pack.id != InstalledPack.builtIn.id {
            let f = Self.directory(pack.id).appendingPathComponent(e.fileName)
            if FileManager.default.fileExists(atPath: f.path) { return f }
        }
        return Bundle.main.url(forResource: e.rawValue, withExtension: "wav")
    }

    // MARK: The catalog

    func catalog() async throws -> [CatalogPack] {
        struct Answer: Decodable { let packs: [CatalogPack] }
        let (data, response) = try await URLSession.shared.data(from: Self.catalogBase.appendingPathComponent("v1/catalog"))
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return try d.decode(Answer.self, from: data).packs
    }

    func installedVersion(of pack: CatalogPack) -> String? {
        installed.first { $0.id == pack.id }?.version
    }

    /// Downloads a pack's sounds (each checked against the catalog's hash)
    /// and chooses it.
    func install(_ pack: CatalogPack) async throws {
        let dir = Self.directory(pack.id)
        let staging = dir.deletingLastPathComponent().appendingPathComponent(".\(pack.id)-new")
        try? FileManager.default.removeItem(at: staging)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        for f in pack.files where SoundEvent.allCases.contains(where: { $0.fileName == f.name }) || f.name.hasSuffix(".wav") {
            // Names come from the catalog: keep them to plain file names.
            guard !f.name.contains("/"), !f.name.hasPrefix(".") else { continue }
            let url = Self.catalogBase.appendingPathComponent("v1/packs/\(pack.id)/files/\(f.name)")
            let (data, response) = try await URLSession.shared.data(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
            let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard hash == f.hash else { throw URLError(.cannotDecodeContentData) }
            try data.write(to: staging.appendingPathComponent(f.name))
        }
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.moveItem(at: staging, to: dir)
        installed.removeAll { $0.id == pack.id }
        installed.append(InstalledPack(id: pack.id, name: pack.name, author: pack.author, version: pack.version))
        installed.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        selectedId = pack.id
        save()
        // Counted in the catalog (best effort).
        var req = URLRequest(url: Self.catalogBase.appendingPathComponent("v1/catalog/\(pack.id)/installed"))
        req.httpMethod = "POST"
        _ = try? await URLSession.shared.data(for: req)
    }

    func remove(_ pack: InstalledPack) {
        guard pack.id != InstalledPack.builtIn.id else { return }
        try? FileManager.default.removeItem(at: Self.directory(pack.id))
        installed.removeAll { $0.id == pack.id }
        if selectedId == pack.id { selectedId = InstalledPack.builtIn.id }
        save()
    }

    private static func directory(_ id: String) -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SoundPacks", isDirectory: true)
            .appendingPathComponent(id, isDirectory: true)
    }
}
