import AVFoundation
import CryptoKit
import Foundation
import Observation

/// The sounds a pack can have (TeamTalk's file names, shared by every
/// pack): every sound event the desktop client has.
enum SoundEvent: String, CaseIterable, Identifiable, Codable {
    case on, off
    case channelMessage = "channel_msg", channelMessageSent = "channel_msg_sent"
    case privateMessage = "user_msg", privateMessageSent = "user_msg_sent"
    case broadcastMessage = "broadcast_msg"
    case serverLost = "serverlost"
    case userJoined = "newuser", userLeft = "removeuser"
    case loggedIn = "logged_on", loggedOut = "logged_off"
    case fileUpdate = "fileupdate", transferComplete = "filetx_complete"
    case questionMode = "questionmode"
    case voiceActivationOn = "vox_enable", voiceActivationOff = "vox_disable"
    case voiceActivationStarts = "voiceact_on", voiceActivationStops = "voiceact_off"
    case muteAllOn = "mute_all", muteAllOff = "unmute_all"
    case yourTurn = "txqueue_start", turnOver = "txqueue_stop"
    case intercepted = "intercept", interceptEnded = "interceptEnd"
    case typing = "typing"
    case newVideo = "videosession", newDesktop = "desktopsession"

    var id: Self { self }
    var fileName: String { rawValue + ".wav" }

    var label: String {
        switch self {
        case .on: "Talking starts (push to talk)"
        case .off: "Talking stops (push to talk)"
        case .channelMessage: "Channel message"
        case .channelMessageSent: "Channel message sent"
        case .privateMessage: "Private message"
        case .privateMessageSent: "Private message sent"
        case .broadcastMessage: "Broadcast message"
        case .serverLost: "Connection lost"
        case .userJoined: "Someone joins your channel"
        case .userLeft: "Someone leaves your channel"
        case .loggedIn: "Someone logs in to the server"
        case .loggedOut: "Someone logs out of the server"
        case .fileUpdate: "Channel files change"
        case .transferComplete: "Transfer finished"
        case .questionMode: "Someone has a question"
        case .voiceActivationOn: "Voice activation turned on"
        case .voiceActivationOff: "Voice activation turned off"
        case .voiceActivationStarts: "Voice activation starts sending"
        case .voiceActivationStops: "Voice activation stops sending"
        case .muteAllOn: "Everyone muted"
        case .muteAllOff: "Everyone unmuted"
        case .yourTurn: "Your turn to talk (one at a time)"
        case .turnOver: "Your turn is over (one at a time)"
        case .intercepted: "Someone intercepts you"
        case .interceptEnded: "Someone stops intercepting you"
        case .typing: "Someone is typing to you"
        case .newVideo: "Someone sends video"
        case .newDesktop: "Someone shares a desktop"
        }
    }

    /// On unless the desktop has it off by default.
    /// The desktop has every sound event on by default (SOUNDEVENT_ACTIVEEVENTS).
    var onByDefault: Bool { true }
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
    static var catalogBase: URL { Service.baseURL }

    private(set) var installed: [InstalledPack] = []
    var selectedId: String = InstalledPack.builtIn.id { didSet { save() } }
    /// 0–1.
    var volume: Double = 0.8 { didSet { save() } }
    private(set) var disabled: Set<SoundEvent> = []

    private let defaults = UserDefaults.standard
    private var players: [AVAudioPlayer] = []

    @ObservationIgnored private var loading = true

    init() {
        if let d = defaults.data(forKey: "soundPacks"), let p = try? JSONDecoder().decode([InstalledPack].self, from: d) {
            installed = p
        }
        selectedId = defaults.string(forKey: "soundPack") ?? InstalledPack.builtIn.id
        playbackMode = PlaybackMode(rawValue: defaults.string(forKey: "soundPlaybackMode") ?? "") ?? .standard
        enabled = defaults.object(forKey: "soundEventsEnabled") as? Bool ?? true
        volume = defaults.object(forKey: "soundVolume") as? Double ?? 0.8
        if let off = defaults.stringArray(forKey: "soundsOff") {
            disabled = Set(off.compactMap(SoundEvent.init(rawValue:)))
            // Once: this app's earlier defaults (five off) become the
            // desktop's (all on); a list changed by hand stays.
            if !defaults.bool(forKey: "soundsDesktopDefaults") {
                defaults.set(true, forKey: "soundsDesktopDefaults")
                let oldDefault: Set<String> = ["voiceact_on", "voiceact_off", "intercept", "interceptEnd", "typing"]
                if Set(off) == oldDefault { disabled = [] }
            }
        } else {
            disabled = Set(SoundEvent.allCases.filter { !$0.onByDefault })
        }
        // Events added since the list was saved start as the desktop has them.
        let known = Set(defaults.stringArray(forKey: "soundsKnown") ?? SoundEvent.allCases.map(\.rawValue))
        for e in SoundEvent.allCases where !known.contains(e.rawValue) && !e.onByDefault { disabled.insert(e) }
        defaults.set(SoundEvent.allCases.map(\.rawValue), forKey: "soundsKnown")
        finished = PlayerFinished { [weak self] in self?.playNext() }
        loading = false
        save()
    }

    var packs: [InstalledPack] { [InstalledPack.builtIn] + installed }
    var selected: InstalledPack { packs.first { $0.id == selectedId } ?? .builtIn }

    private func save() {
        // Not while loading (see AppModel.save).
        guard !loading else { return }
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

    func setAll(_ on: Bool) {
        disabled = on ? [] : Set(SoundEvent.allCases)
        save()
    }

    /// As the desktop has them: on and off, and no files of my own.
    func revert() {
        disabled = Set(SoundEvent.allCases.filter { !$0.onByDefault })
        for e in SoundEvent.allCases { resetFile(e) }
        save()
    }

    // MARK: A file of my own for an event

    private static var customDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SoundPacks/custom", isDirectory: true)
    }

    func hasOwnFile(_ e: SoundEvent) -> Bool {
        FileManager.default.fileExists(atPath: Self.customDirectory.appendingPathComponent(e.fileName).path)
    }

    /// Uses a picked audio file for this event (whichever pack is chosen).
    func setFile(_ e: SoundEvent, from url: URL) -> Bool {
        let reading = url.startAccessingSecurityScopedResource()
        defer { if reading { url.stopAccessingSecurityScopedResource() } }
        guard (try? AVAudioPlayer(contentsOf: url)) != nil else { return false }
        try? FileManager.default.createDirectory(at: Self.customDirectory, withIntermediateDirectories: true)
        let dest = Self.customDirectory.appendingPathComponent(e.fileName)
        try? FileManager.default.removeItem(at: dest)
        return (try? FileManager.default.copyItem(at: url, to: dest)) != nil
    }

    func resetFile(_ e: SoundEvent) {
        try? FileManager.default.removeItem(at: Self.customDirectory.appendingPathComponent(e.fileName))
    }

    // MARK: Playing

    /// The desktop's "Enable Sound Events" (all of them at once).
    var enabled = true { didSet { defaults.set(enabled, forKey: "soundEventsEnabled") } }

    /// Plays an event's sound (if it's on), mixed with the voices.
    func play(_ e: SoundEvent) {
        guard enabled, isOn(e) else { return }
        preview(e)
    }

    /// Plays it whether it's on or not (trying sounds in Settings).
    func preview(_ e: SoundEvent, pack: InstalledPack? = nil) {
        guard let url = url(for: e, in: pack ?? selected), let p = try? AVAudioPlayer(contentsOf: url) else { return }
        p.volume = Float(volume)
        p.delegate = finished
        players.removeAll { !$0.isPlaying }
        switch playbackMode {
        case .standard:
            // The desktop's default: a new sound stops the one playing.
            players.forEach { $0.stop() }
            players = [p]
            p.play()
        case .oneByOne:
            // Truly one after another: it waits its turn in the queue.
            if players.contains(where: \.isPlaying) {
                waiting.append(p)
            } else {
                players.append(p)
                p.play()
            }
        case .overlapping:
            players.append(p)
            p.play()
        }
    }

    /// One by One: the sounds waiting for the one playing to finish.
    @ObservationIgnored private var waiting: [AVAudioPlayer] = []
    @ObservationIgnored private var finished: PlayerFinished?

    private func playNext() {
        players.removeAll { !$0.isPlaying }
        guard playbackMode == .oneByOne, !players.contains(where: \.isPlaying), !waiting.isEmpty else { return }
        let next = waiting.removeFirst()
        players.append(next)
        next.play()
    }

    /// The desktop's sound event "Playback mode".
    enum PlaybackMode: String, CaseIterable, Identifiable {
        case standard = "default", oneByOne, overlapping
        var id: Self { self }
        var label: String {
            switch self {
            case .standard: "Default"
            case .oneByOne: "One by One"
            case .overlapping: "Overlapping"
            }
        }
    }
    var playbackMode = PlaybackMode.standard {
        didSet { defaults.set(playbackMode.rawValue, forKey: "soundPlaybackMode") }
    }

    /// The pack's sound, or the built-in one where it has none.
    private func url(for e: SoundEvent, in pack: InstalledPack) -> URL? {
        let own = Self.customDirectory.appendingPathComponent(e.fileName)
        if FileManager.default.fileExists(atPath: own.path) { return own }
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

/// Tells the sound store a sound finished (for One by One).
final class PlayerFinished: NSObject, AVAudioPlayerDelegate {
    private let done: @MainActor () -> Void
    init(_ done: @escaping @MainActor () -> Void) { self.done = done }
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in done() }
    }
    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor in done() }
    }
}
