import AVFoundation
import CryptoKit
import Foundation
import Observation

/// The sounds a pack can have (TeamTalk's file names, shared by every
/// pack): every sound event the desktop client has.
enum SoundEvent: String, CaseIterable, Identifiable, Codable {
    // The desktop's sound events, in its order (soundeventsmodel.cpp), by
    // its file names (settings.h SOUNDEVENT_*_DEFAULT), so a desktop sound
    // pack works as it is. Not here: "Hotkey pressed" (the owner's choice:
    // talking starts and stops with vox_me_enable and vox_me_disable), "Channel silent" (no sound by default) and
    // "Desktop access request" (no desktop sharing on phones).
    case loggedIn = "logged_on", loggedOut = "logged_off"
    case userJoined = "newuser", userLeft = "removeuser"
    case serverLost = "serverlost"
    case privateMessage = "user_msg", privateMessageSent = "user_msg_sent"
    case typing = "typing"
    case channelMessage = "channel_msg", channelMessageSent = "channel_msg_sent"
    case broadcastMessage = "broadcast_msg"
    case newVideo = "videosession", newDesktop = "desktopsession"
    case fileUpdate = "fileupdate", transferComplete = "filetx_complete"
    case questionMode = "questionmode"
    case voiceActivationOn = "vox_enable", voiceActivationOff = "vox_disable"
    case voiceActivationMeOn = "vox_me_enable", voiceActivationMeOff = "vox_me_disable"
    case voiceActivationStarts = "voiceact_on", voiceActivationStops = "voiceact_off"
    case muteAllOn = "mute_all", muteAllOff = "unmute_all"
    case yourTurn = "txqueue_start", turnOver = "txqueue_stop"
    case intercepted = "intercept", interceptEnded = "interceptEnd"

    var id: Self { self }
    var fileName: String { rawValue + ".wav" }

    /// The desktop's names.
    var label: String {
        switch self {
        case .loggedIn: "User logged in"
        case .loggedOut: "User logged out"
        case .userJoined: "User joined channel"
        case .userLeft: "User left channel"
        case .serverLost: "Connection to server lost"
        case .privateMessage: "Private message received"
        case .privateMessageSent: "Private message sent"
        case .typing: "User is typing a private message in focused window"
        case .channelMessage: "Channel message received"
        case .channelMessageSent: "Channel message sent"
        case .broadcastMessage: "Broadcast message received"
        case .newVideo: "New video session"
        case .newDesktop: "New desktop session"
        case .fileUpdate: "Files updated"
        case .transferComplete: "File transfer completed"
        case .questionMode: "User enabled question mode"
        case .voiceActivationOn: "Voice activation enabled"
        case .voiceActivationOff: "Voice activation disabled"
        // The desktop's "Voice activation enabled/disabled via "Me" menu"
        // (vox_me_*): here the keyboard shortcut's, and whenever I turn my
        // microphone on or off (push to talk, mute).
        case .voiceActivationMeOn: "Voice activation enabled via keyboard shortcut"
        case .voiceActivationMeOff: "Voice activation disabled via keyboard shortcut"
        case .voiceActivationStarts: "Voice activation triggered"
        case .voiceActivationStops: "Voice activation stopped"
        case .muteAllOn: "Mute master volume"
        case .muteAllOff: "Unmute master volume"
        case .yourTurn: "Transmit ready in \"No interruption\" channel"
        case .turnOver: "Transmit stopped in \"No interruption\" channel"
        case .intercepted: "Interception by another user"
        case .interceptEnded: "End of interception by another user"
        }
    }

    /// Earlier names: this app's and the old app's talking sounds are the
    /// microphone on/off ones (vox_me_*) now.
    var olderNames: [String] {
        switch self {
        case .voiceActivationMeOn: ["on"]
        case .voiceActivationMeOff: ["off"]
        default: []
        }
    }

    /// The desktop's sound this app doesn't use: an imported pack's is left out.
    static let unused = ["hotkey"]

    /// The kinds of sound file a pack may have (the Monitor's catalog's).
    static let extensions = ["wav", "mp3", "caf", "aiff", "aif", "m4a", "aac"]

    /// The desktop has every sound event on by default (SOUNDEVENT_ACTIVEEVENTS).
    var onByDefault: Bool { true }
}

/// A pack in the catalog (packs.json at ttng-soundpacks.mad-gamer.com, the
/// format TeamTalk NG has always read, with the zip's checksum and size).
struct CatalogPack: Decodable, Identifiable, Hashable {
    let id: String
    let name: String
    let author: String
    let description: String
    let version: String
    let downloadUrl: URL
    let sha256: String?
    let size: Int?
    let official: Bool?
    /// Who published it, as the catalog's opaque name (nil from an older
    /// catalog; "" for packs whose account was deleted).
    let publisher: String?

    /// What blocking its publisher blocks: the catalog's name for them,
    /// else (an older catalog, a deleted account) the author's name.
    var blockKey: String { (publisher?.isEmpty == false) ? publisher! : "author:" + author }

    init(from decoder: Decoder) throws {
        enum K: String, CodingKey { case id, name, author, description, version, downloadUrl, sha256, size, official, publisher }
        let c = try decoder.container(keyedBy: K.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        author = try c.decodeIfPresent(String.self, forKey: .author) ?? ""
        description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
        // A number or a string.
        if let v = try? c.decode(String.self, forKey: .version) { version = v } else { version = String(try c.decodeIfPresent(Int.self, forKey: .version) ?? 0) }
        downloadUrl = try c.decode(URL.self, forKey: .downloadUrl)
        sha256 = try c.decodeIfPresent(String.self, forKey: .sha256)
        size = try c.decodeIfPresent(Int.self, forKey: .size)
        official = try c.decodeIfPresent(Bool.self, forKey: .official)
        publisher = try c.decodeIfPresent(String.self, forKey: .publisher)
    }
}

/// A pack on this iPhone: the built-in one, one from the catalog, one
/// imported, or one made here. Imported and made ones can be edited; the
/// others are edited through a copy (an update would undo changes).
struct InstalledPack: Codable, Identifiable, Hashable {
    let id: String
    var name: String
    var author: String
    var version: String
    /// Said in the catalog when published (made and imported packs).
    var description: String?

    static let builtIn = InstalledPack(id: "default", name: "TeamTalk (built in)", author: "BearWare.dk", version: "")

    enum Kind { case builtIn, catalog, imported, own }
    var kind: Kind {
        if id == Self.builtIn.id { return .builtIn }
        if id.hasPrefix("imported-") { return .imported }
        if id.hasPrefix("own-") { return .own }
        return .catalog
    }
    var editable: Bool { kind == .imported || kind == .own }
    var kindText: String {
        switch kind {
        case .builtIn: "built in"
        case .catalog: "from the catalog"
        case .imported: "imported"
        case .own: "yours"
        }
    }
}

/// Sound packs, the chosen one, volume and which events sound; plays them.
@MainActor @Observable
final class SoundStore {
    /// The catalog's packs.json (the build's TTNGCatalogURL in tests).
    static var catalogURL: URL {
        let set = (Bundle.main.object(forInfoDictionaryKey: "TTNGCatalogURL") as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        return URL(string: set.isEmpty ? "https://ttng-soundpacks.mad-gamer.com/packs.json" : set)!
    }

    private(set) var installed: [InstalledPack] = []
    var selectedId: String = InstalledPack.builtIn.id { didSet { save(); if !loading, oldValue != selectedId { packsChanged?() } } }
    /// Installed or chosen packs changed here.
    @ObservationIgnored var packsChanged: (() -> Void)?
    /// Syncing my packs with iCloud Drive now.
    @ObservationIgnored var cloudBusy = false
    @ObservationIgnored private var cloudSoon: Task<Void, Never>?
    /// A change while a sync ran: another sync right after it.
    @ObservationIgnored var cloudAgain = false
    /// Watches iCloud Drive for my packs arriving or changing from other
    /// devices (and asks for them to download).
    @ObservationIgnored var cloudQuery: NSMetadataQuery?
    @ObservationIgnored var cloudObservers: [NSObjectProtocol] = []
    /// 0–1; the desktop's default is 100 (SOUNDEVENT_VOLUME_DEFAULT).
    var volume: Double = 1 { didSet { save() } }
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
        volume = defaults.object(forKey: "soundVolume") as? Double ?? 1
        // Once: this app's earlier default (80) becomes the desktop's 100.
        if !defaults.bool(forKey: "soundVolumeDesktopDefault") {
            defaults.set(true, forKey: "soundVolumeDesktopDefault")
            if abs(volume - 0.8) < 0.001 { volume = 1 }
        }
        if let off = defaults.stringArray(forKey: "soundsOff") {
            disabled = Set(off.compactMap(SoundEvent.init(rawValue:)))
            // This app's talking on and off sounds are the voice activation ones now.
            if off.contains("on") { disabled.insert(.voiceActivationMeOn) }
            if off.contains("off") { disabled.insert(.voiceActivationMeOff) }
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
        // A sound file of my own for each event is gone (packs are made
        // and edited instead; the owner chose to drop those files).
        try? FileManager.default.removeItem(at: Self.customDirectory)
        // Packs installed before: their hotkey sound isn't used.
        for p in installed {
            for ext in SoundEvent.extensions {
                try? FileManager.default.removeItem(at: Self.directory(p.id).appendingPathComponent("hotkey.\(ext)"))
            }
        }
                finished = PlayerFinished { [weak self] in self?.playNext() }
        loading = false
        refreshNotificationSounds()
        save()
    }

    var packs: [InstalledPack] { [InstalledPack.builtIn] + installed }
    var selected: InstalledPack { packs.first { $0.id == selectedId } ?? .builtIn }

    private func save() {
        // Not while loading (see AppModel.save).
        guard !loading else { return }
        packsMayHaveChanged()
        defaults.set(try? JSONEncoder().encode(installed), forKey: "soundPacks")
        defaults.set(selectedId, forKey: "soundPack")
        defaults.set(volume, forKey: "soundVolume")
        defaults.set(disabled.map(\.rawValue), forKey: "soundsOff")
        refreshNotificationSounds()
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

    /// As the desktop has them: which play.
    func revert() {
        disabled = Set(SoundEvent.allCases.filter { !$0.onByDefault })
        save()
    }

    // MARK: A file of my own for an event

    private static var customDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SoundPacks/custom", isDirectory: true)
    }

    // MARK: Playing

    /// The desktop's "Enable Sound Events" (all of them at once).
    var enabled = true { didSet { defaults.set(enabled, forKey: "soundEventsEnabled"); if !loading { refreshNotificationSounds() } } }

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

    /// The chosen pack's sound for an event.
    func soundURL(_ e: SoundEvent) -> URL? { url(for: e, in: selected) }

    /// The pack's sound, or the built-in one where it has none.
    private func url(for e: SoundEvent, in pack: InstalledPack) -> URL? {
        if let own = packFile(e, in: pack) { return own }
        return Bundle.main.url(forResource: e.rawValue, withExtension: "wav")
    }

    /// The pack's own file for an event (the desktop's name in any kind of
    /// sound file, else an older name); nil when it uses the built-in one.
    func packFile(_ e: SoundEvent, in pack: InstalledPack) -> URL? {
        if pack.id != InstalledPack.builtIn.id {
            // The desktop's name in any kind of sound file, else an older name.
            let dir = Self.directory(pack.id)
            for name in [e.rawValue] + e.olderNames {
                for ext in SoundEvent.extensions {
                    let f = dir.appendingPathComponent("\(name).\(ext)")
                    if FileManager.default.fileExists(atPath: f.path) { return f }
                }
            }
        }
        return nil
    }

    // MARK: The catalog

    func catalog() async throws -> [CatalogPack] {
        struct Answer: Decodable { let packs: [CatalogPack] }
        var req = URLRequest(url: Self.catalogURL)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await URLSession.shared.data(for: req)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return try d.decode(Answer.self, from: data).packs
    }

    // MARK: Reporting and blocking

    /// Publishers whose packs I don't want to see: the catalog's name for
    /// each, with the author name to show.
    var blockedPublishers: [String: String] = UserDefaults.standard.dictionary(forKey: "blockedPublishers") as? [String: String] ?? [:] {
        didSet { defaults.set(blockedPublishers, forKey: "blockedPublishers") }
    }

    func block(_ pack: CatalogPack) { blockedPublishers[pack.blockKey] = pack.author }
    func unblock(_ key: String) { blockedPublishers[key] = nil }
    func isBlocked(_ pack: CatalogPack) -> Bool { pack.official != true && blockedPublishers[pack.blockKey] != nil }

    /// Reports a pack to TeamTalk NG (no NG Account needed). Why not, or nil.
    func report(_ pack: CatalogPack, reason: String) async -> String? {
        var req = URLRequest(url: Service.baseURL.appendingPathComponent("v1/catalog/\(pack.id)/report"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["reason": reason])
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if (200..<300).contains(status) { return nil }
            let said = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            return said ?? "The report couldn't be sent (\(status))."
        } catch {
            return error.localizedDescription
        }
    }

    func installedVersion(of pack: CatalogPack) -> String? {
        installed.first { $0.id == pack.id }?.version
    }

    /// Downloads a pack's zip (checked against the catalog's checksum),
    /// keeps its sounds (by the desktop's names) and chooses it.
    func install(_ pack: CatalogPack) async throws {
        let fm = FileManager.default
        let dir = Self.directory(pack.id)
        let work = fm.temporaryDirectory.appendingPathComponent("catalog-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: work) }
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        let (file, response) = try await URLSession.shared.download(from: pack.downloadUrl)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        let zip = work.appendingPathComponent("pack.zip")
        try fm.moveItem(at: file, to: zip)
        if let want = pack.sha256?.lowercased() {
            let data = try Data(contentsOf: zip)
            guard SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == want else { throw URLError(.cannotDecodeContentData) }
        }
        let unzipped = work.appendingPathComponent("files", isDirectory: true)
        _ = try unzipFlat(zipPath: zip.path, folder: unzipped.path)
        let staging = dir.deletingLastPathComponent().appendingPathComponent(".\(pack.id)-new")
        try? fm.removeItem(at: staging)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }
        var kept = 0
        for f in (try? fm.contentsOfDirectory(at: unzipped, includingPropertiesForKeys: nil)) ?? [] {
            let ext = f.pathExtension.lowercased(), base = f.deletingPathExtension().lastPathComponent
            guard SoundEvent.extensions.contains(ext), !base.hasPrefix("."), !SoundEvent.unused.contains(base.lowercased()) else { continue }
            try fm.moveItem(at: f, to: staging.appendingPathComponent(f.lastPathComponent))
            kept += 1
        }
        guard kept > 0 else { throw URLError(.cannotDecodeContentData) }
        try? fm.removeItem(at: dir)
        try fm.moveItem(at: staging, to: dir)
        installed.removeAll { $0.id == pack.id }
        installed.append(InstalledPack(id: pack.id, name: pack.name, author: pack.author, version: pack.version))
        installed.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        selectedId = pack.id
        save()
        packsChanged?()
        // Counted in the catalog (best effort).
        var req = URLRequest(url: Service.baseURL.appendingPathComponent("v1/catalog/\(pack.id)/installed"))
        req.httpMethod = "POST"
        _ = try? await URLSession.shared.data(for: req)
    }

    /// Packs that are only on this iPhone: imported, or made here (not the
    /// catalog's, which NG Account installs on the account's devices).
    static func isLocal(_ id: String) -> Bool { id.hasPrefix("imported-") || id.hasPrefix("own-") }

    /// Imports a sound pack from a folder (a desktop client's pack, such as
    /// one of its Sounds folders, or one unzipped in the Files app): its
    /// sounds by the desktop's names, in any kind of sound file; chooses it.
    /// A message saying what came in, or what's wrong.
    func importPack(from folder: URL) -> String {
        let reading = folder.startAccessingSecurityScopedResource()
        defer { if reading { folder.stopAccessingSecurityScopedResource() } }
        let fm = FileManager.default
        var dir = folder
        func files(_ d: URL) -> [URL] { (try? fm.contentsOfDirectory(at: d, includingPropertiesForKeys: [.isDirectoryKey])) ?? [] }
        func isDir(_ u: URL) -> Bool { (try? u.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false }
        // A zip unzipped often holds one folder with the sounds.
        var list = files(dir)
        if !list.contains(where: { !isDir($0) && SoundEvent.extensions.contains($0.pathExtension.lowercased()) }),
           let only = list.filter(isDir).first, list.filter(isDir).count == 1 {
            dir = only
            list = files(dir)
        }
        var found: [(SoundEvent, URL)] = []
        for e in SoundEvent.allCases {
            for name in [e.rawValue] + e.olderNames {
                if let f = list.first(where: { $0.deletingPathExtension().lastPathComponent.caseInsensitiveCompare(name) == .orderedSame
                    && SoundEvent.extensions.contains($0.pathExtension.lowercased()) }) {
                    found.append((e, f))
                    break
                }
            }
        }
        guard !found.isEmpty else {
            return "No sounds there: a pack's sounds are named as the desktop client's, such as logged_on.wav and vox_me_enable.wav."
        }
        let id = "imported-" + UUID().uuidString.prefix(8).lowercased()
        let target = Self.directory(id)
        try? fm.createDirectory(at: target, withIntermediateDirectories: true)
        var copied = 0
        for (e, f) in found where (try? fm.copyItem(at: f, to: target.appendingPathComponent("\(e.rawValue).\(f.pathExtension.lowercased())"))) != nil {
            copied += 1
        }
        guard copied > 0 else { try? fm.removeItem(at: target); return "The sounds couldn't be read." }
        // The desktop's hotkey sound isn't used here: not kept.
        let droppedHotkey = list.contains { SoundEvent.unused.contains($0.deletingPathExtension().lastPathComponent.lowercased()) }
        installed.append(InstalledPack(id: id, name: folder.lastPathComponent, author: "imported", version: ""))
        installed.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        selectedId = id
        save()
        let missing = SoundEvent.allCases.count - copied
        return "Imported \(folder.lastPathComponent): \(copied) sounds" + (missing > 0 ? ", the built-in ones for the other \(missing)." : ".")
            + (droppedHotkey ? " Its hotkey sound was left out: TeamTalk NG doesn't use it." : "")
    }

    func remove(_ pack: InstalledPack) {
        guard pack.id != InstalledPack.builtIn.id else { return }
        try? FileManager.default.removeItem(at: Self.directory(pack.id))
        installed.removeAll { $0.id == pack.id }
        if selectedId == pack.id { selectedId = InstalledPack.builtIn.id }
        save()
        packsChanged?()
    }

    // MARK: Making and editing packs

    private func add(_ p: InstalledPack) {
        installed.append(p)
        installed.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        save()
    }

    func pack(_ id: String) -> InstalledPack? { packs.first { $0.id == id } }

    /// A new pack of my own: empty, so every sound is the built-in one
    /// until a file is chosen for it.
    @discardableResult
    func createPack(name: String, author: String, id: String? = nil) -> InstalledPack {
        let p = InstalledPack(id: id ?? "own-" + UUID().uuidString.prefix(8).lowercased(),
                              name: name.trimmingCharacters(in: .whitespaces).nonEmpty ?? "My sound pack",
                              author: author.trimmingCharacters(in: .whitespaces), version: "", description: "")
        try? FileManager.default.createDirectory(at: Self.directory(p.id), withIntermediateDirectories: true)
        add(p)
        return p
    }

    /// A copy of any pack, mine to edit (the built-in one's copy starts
    /// empty: its sounds are the built-in ones anyway).
    @discardableResult
    func duplicate(_ source: InstalledPack, name: String, id: String? = nil) -> InstalledPack {
        let p = createPack(name: name, author: source.author, id: id)
        let fm = FileManager.default
        if source.kind != .builtIn {
            for f in (try? fm.contentsOfDirectory(at: Self.directory(source.id), includingPropertiesForKeys: nil)) ?? []
            where SoundEvent.extensions.contains(f.pathExtension.lowercased()) {
                try? fm.copyItem(at: f, to: Self.directory(p.id).appendingPathComponent(f.lastPathComponent))
            }
        }
        if let i = installed.firstIndex(where: { $0.id == p.id }) { installed[i].description = source.description }
        save()
        return p
    }

    /// Its name, author and description (editable packs).
    func update(_ id: String, name: String, author: String, description: String) {
        guard let i = installed.firstIndex(where: { $0.id == id }), installed[i].editable else { return }
        installed[i].name = name.trimmingCharacters(in: .whitespaces).nonEmpty ?? installed[i].name
        installed[i].author = author.trimmingCharacters(in: .whitespaces)
        installed[i].description = description
        installed.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        save()
    }

    /// Uses a picked sound file for an event in an editable pack, named as
    /// the desktop's (so the pack exports as one). False when it can't be played.
    func setSound(_ e: SoundEvent, in pack: InstalledPack, from url: URL) -> Bool {
        guard pack.editable else { return false }
        let reading = url.startAccessingSecurityScopedResource()
        defer { if reading { url.stopAccessingSecurityScopedResource() } }
        guard (try? AVAudioPlayer(contentsOf: url)) != nil else { return false }
        let ext = SoundEvent.extensions.contains(url.pathExtension.lowercased()) ? url.pathExtension.lowercased() : "wav"
        removeSound(e, in: pack)
        let dir = Self.directory(pack.id)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let ok = (try? FileManager.default.copyItem(at: url, to: dir.appendingPathComponent("\(e.rawValue).\(ext)"))) != nil
        refreshNotificationSounds()
        packEdited = UUID()
        return ok
    }

    /// The event goes back to the built-in sound in this pack.
    func removeSound(_ e: SoundEvent, in pack: InstalledPack) {
        guard pack.editable else { return }
        let dir = Self.directory(pack.id)
        for name in [e.rawValue] + e.olderNames {
            for ext in SoundEvent.extensions {
                try? FileManager.default.removeItem(at: dir.appendingPathComponent("\(name).\(ext)"))
            }
        }
        refreshNotificationSounds()
        packEdited = UUID()
    }

    /// Changes whenever a pack's sounds change (screens showing them follow).
    private(set) var packEdited = UUID() { didSet { packsMayHaveChanged() } }

    /// My packs go to iCloud Drive a moment after they change.
    private func packsMayHaveChanged() {
        guard ICloudSync.isOn else { return }
        // During a sync: once more after it (a change mustn't be lost).
        if cloudBusy { cloudAgain = true; return }
        cloudSoon?.cancel()
        cloudSoon = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            await self?.syncPacksWithCloud()
        }
    }

    /// The pack's own sounds by the desktop's names (for sharing and publishing).
    func soundFiles(_ pack: InstalledPack) -> [(name: String, url: URL)] {
        if pack.kind == .builtIn {
            return SoundEvent.allCases.compactMap { e in
                Bundle.main.url(forResource: e.rawValue, withExtension: "wav").map { ("\(e.rawValue).wav", $0) }
            }
        }
        return SoundEvent.allCases.compactMap { e in
            packFile(e, in: pack).map { ("\(e.rawValue).\($0.pathExtension.lowercased())", $0) }
        }
    }

    /// The pack as a .zip with the desktop's file names, for sharing (a
    /// desktop client or TeamTalk NG imports it as it is).
    func exportZip(_ pack: InstalledPack) -> URL? {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("pack-\(UUID().uuidString)", isDirectory: true)
        let folder = work.appendingPathComponent("files", isDirectory: true)
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        for f in soundFiles(pack) { try? fm.copyItem(at: f.url, to: folder.appendingPathComponent(f.name)) }
        let safe = pack.name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        let zip = work.appendingPathComponent("\(safe).zip")
        guard (try? zipFolder(folder: folder.path, zipPath: zip.path)) ?? 0 > 0 else { return nil }
        return zip
    }

    /// Imports a .zip of a pack (its sounds by the desktop's names, in any
    /// folder inside it), as importing a folder does.
    func importZip(_ url: URL) -> String {
        let reading = url.startAccessingSecurityScopedResource()
        defer { if reading { url.stopAccessingSecurityScopedResource() } }
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("unzip-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: work) }
        let folder = work.appendingPathComponent(url.deletingPathExtension().lastPathComponent, isDirectory: true)
        do { _ = try unzipFlat(zipPath: url.path, folder: folder.path) } catch { return words(error) }
        return importPack(from: folder)
    }

    /// Imports a pack from a link to its .zip (http or https). Dropbox's
    /// share links are fetched as the file itself.
    func importZip(fromLink text: String) async -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var parts = URLComponents(string: trimmed), let scheme = parts.scheme?.lowercased(),
              scheme == "https" || scheme == "http", parts.host?.isEmpty == false
        else { return "That isn't a web link. It starts with https://." }
        if parts.host?.lowercased().hasSuffix("dropbox.com") == true {
            var q = (parts.queryItems ?? []).filter { $0.name != "dl" }
            q.append(URLQueryItem(name: "dl", value: "1"))
            parts.queryItems = q
        }
        guard let url = parts.url else { return "That isn't a web link." }
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("download-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: work) }
        do {
            let (file, response) = try await URLSession.shared.download(from: url)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                return "The link didn't give a file (the server said \(http.statusCode))."
            }
            let size = (try? fm.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0
            guard size <= 200 * 1024 * 1024 else { return "That file is bigger than 200 MB." }
            // The pack is named after the file.
            var name = response.suggestedFilename ?? url.lastPathComponent
            if !name.lowercased().hasSuffix(".zip") { name = (name as NSString).deletingPathExtension + ".zip" }
            if name == ".zip" { name = "Sound pack.zip" }
            try fm.createDirectory(at: work, withIntermediateDirectories: true)
            let zip = work.appendingPathComponent(name)
            try fm.moveItem(at: file, to: zip)
            return importZip(zip)
        } catch {
            return "The pack couldn't be downloaded: \(error.localizedDescription)"
        }
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

// MARK: Monitor notification sounds

extension SoundStore {
    /// The sounds Monitor notifications use, by the Monitor's names.
    static let monitorEvents: [SoundEvent] = [.loggedIn, .loggedOut, .privateMessage, .channelMessage, .broadcastMessage, .serverLost]

    /// Brings the notification sounds in line with the chosen pack and the
    /// sound events (cheap when nothing changed).
    func refreshNotificationSounds() {
        let wanted: [(String, URL?)] = Self.monitorEvents.map { e in
            (e.rawValue, enabled && isOn(e) ? soundURL(e) : nil)
        }
        Task.detached(priority: .utility) { Self.exportNotificationSounds(wanted) }
    }

    nonisolated private static func exportNotificationSounds(_ wanted: [(String, URL?)]) {
        guard let dir = MonitorSound.directory else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let previous = MonitorSound.files
        var files: [String: String] = [:]
        for (name, source) in wanted {
            guard let source else { files[name] = ""; continue }
            // A new name when the source changes: iOS remembers sounds by name.
            let date = ((try? FileManager.default.attributesOfItem(atPath: source.path))?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            let file = "ttng-\(name)-\(String(stableHash("\(source.path)|\(date)"), radix: 36)).caf"
            if previous[name] == file, FileManager.default.fileExists(atPath: dir.appendingPathComponent(file).path) {
                files[name] = file
                continue
            }
            if (try? convertForNotification(source, to: dir.appendingPathComponent(file))) != nil { files[name] = file }
        }
        MonitorSound.files = files
        let keep = Set(files.values)
        for item in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [] where item.hasPrefix("ttng-") && !keep.contains(item) {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(item))
        }
    }

    /// 16-bit PCM CAF, at most 29 seconds, which iOS takes as a notification sound.
    nonisolated static func convertForNotification(_ source: URL, to destination: URL) throws {
        let input = try AVAudioFile(forReading: source)
        let format = input.processingFormat
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount, AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
        ]
        try? FileManager.default.removeItem(at: destination)
        let output = try AVAudioFile(forWriting: destination, settings: settings, commonFormat: format.commonFormat, interleaved: format.isInterleaved)
        var remaining = min(input.length, AVAudioFramePosition(format.sampleRate * 29))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8192) else { return }
        while remaining > 0 {
            try input.read(into: buffer, frameCount: AVAudioFrameCount(min(8192, remaining)))
            if buffer.frameLength == 0 { break }
            try output.write(from: buffer)
            remaining -= AVAudioFramePosition(buffer.frameLength)
        }
    }

    /// The same between launches (Swift's hashValue isn't).
    nonisolated private static func stableHash(_ s: String) -> UInt64 {
        var h: UInt64 = 1469598103934665603
        for b in s.utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
        return h
    }
}

// MARK: Your own packs through iCloud Drive

/// What iCloud Drive keeps of one of my packs (beside its sounds).
private struct CloudPackInfo: Codable {
    var id: String
    var name: String
    var author: String
    var description: String
    var fingerprint: String
    var updated: Double
}

extension SoundStore {
    /// My packs (made or imported) in the app's iCloud Drive folder, one
    /// folder each: sent when they change here, taken when they change on
    /// another device, gone everywhere when deleted. While iCloud sync is on.
    private static let syncedKey = "cloudPacks"

    /// The app's iCloud Drive folder for packs (nil: no iCloud). Not on the
    /// main thread: the first call can take a while.
    nonisolated private static func cloudRoot() -> URL? {
        FileManager.default.url(forUbiquityContainerIdentifier: nil)?
            .appendingPathComponent("Documents", isDirectory: true)
            .appendingPathComponent("Sound packs", isDirectory: true)
    }

    /// A pack's contents in one string: its sounds (names and sizes) and words.
    nonisolated private static func fingerprint(dir: URL, name: String, author: String, description: String) -> String {
        let fm = FileManager.default
        let sounds = ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey])) ?? [])
            .filter { SoundEvent.extensions.contains($0.pathExtension.lowercased()) }
            .map { "\($0.lastPathComponent):\((try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)" }
            .sorted()
        let all = ([name, author, description] + sounds).joined(separator: "\n")
        return SHA256.hash(data: Data(all.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    private var synced: [String: String] {
        get { (UserDefaults.standard.dictionary(forKey: Self.syncedKey) as? [String: String]) ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: Self.syncedKey) }
    }

    /// Sends what changed here, then takes what changed elsewhere.
    func syncPacksWithCloud() async {
        guard ICloudSync.isOn else { return }
        if cloudBusy { cloudAgain = true; return }
        cloudBusy = true
        defer {
            cloudBusy = false
            if cloudAgain { cloudAgain = false; packsMayHaveChanged() }
        }
        guard let root = await Task.detached(operation: { Self.cloudRoot() }).value else { return }
        watchCloud()
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let mine = installed.filter(\.editable)
        var known = synced

        // Taken: new or changed elsewhere (unchanged here since), and
        // deleted elsewhere (unchanged here).
        let cloud: [CloudPackInfo] = await Task.detached(operation: { Self.readCloud(root) }).value
        let cloudIds = Set(cloud.map(\.id))
        for c in cloud {
            let local = mine.first { $0.id == c.id }
            let here = local.map { Self.fingerprint(dir: Self.directory($0.id), name: $0.name, author: $0.author, description: $0.description ?? "") }
            if here == c.fingerprint { known[c.id] = c.fingerprint; continue }
            let unchangedHere = here == nil ? known[c.id] == nil : here == known[c.id]
            guard unchangedHere else { continue }  // changed here too: sent below
            let src = root.appendingPathComponent(c.id, isDirectory: true), dst = Self.directory(c.id)
            guard await Task.detached(operation: { Self.coordinated(reading: src) { Self.copySounds(from: $0, to: dst) } ?? false }).value else { continue }  // still downloading
            installed.removeAll { $0.id == c.id }
            installed.append(InstalledPack(id: c.id, name: c.name, author: c.author, version: "", description: c.description))
            installed.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            known[c.id] = c.fingerprint
            packEdited = UUID()
        }
        for (id, fp) in known where !cloudIds.contains(id) {
            guard let p = mine.first(where: { $0.id == id }) else { known[id] = nil; continue }
            if Self.fingerprint(dir: Self.directory(id), name: p.name, author: p.author, description: p.description ?? "") == fp {
                // Deleted on another device.
                try? FileManager.default.removeItem(at: Self.directory(id))
                installed.removeAll { $0.id == id }
                if selectedId == id { selectedId = InstalledPack.builtIn.id }
                known[id] = nil
            }
        }

        // Sent: changed here (or new), and deleted here.
        for p in installed.filter(\.editable) {
            let fp = Self.fingerprint(dir: Self.directory(p.id), name: p.name, author: p.author, description: p.description ?? "")
            guard known[p.id] != fp else { continue }
            let info = CloudPackInfo(id: p.id, name: p.name, author: p.author, description: p.description ?? "", fingerprint: fp, updated: Date().timeIntervalSince1970)
            let src = Self.directory(p.id), dst = root.appendingPathComponent(p.id, isDirectory: true)
            if await Task.detached(operation: { Self.coordinated(writing: dst) { Self.writeCloud(info, from: src, to: $0) } ?? false }).value { known[p.id] = fp }
        }
        for id in cloudIds where known[id] != nil && !installed.contains(where: { $0.id == id }) {
            let dir = root.appendingPathComponent(id, isDirectory: true)
            await Task.detached { _ = Self.coordinated(writing: dir) { try? FileManager.default.removeItem(at: $0) } }.value
            known[id] = nil
        }
        synced = known
        save()
    }

    /// Starts watching iCloud Drive's packs folder (once): whatever other
    /// devices put there is asked to download, and a sync follows when it
    /// arrives or changes. Without it, a new device often saw nothing: iCloud
    /// hadn't even listed the packs when the app first looked.
    func watchCloud() {
        guard cloudQuery == nil, ICloudSync.isOn else { return }
        let q = NSMetadataQuery()
        q.searchScopes = [NSMetadataQueryUbiquitousDocumentsScope]
        q.predicate = NSPredicate(format: "%K CONTAINS %@", NSMetadataItemPathKey, "/Sound packs/")
        let center = NotificationCenter.default
        cloudObservers = [Notification.Name.NSMetadataQueryDidFinishGathering, .NSMetadataQueryDidUpdate].map { name in
            center.addObserver(forName: name, object: q, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.cloudItemsChanged() }
            }
        }
        cloudQuery = q
        q.start()
    }

    /// iCloud Drive's packs changed: what isn't here yet is asked for, and a
    /// sync follows.
    private func cloudItemsChanged() {
        guard let q = cloudQuery else { return }
        q.disableUpdates()
        for i in 0..<q.resultCount {
            guard let item = q.result(at: i) as? NSMetadataItem, let url = item.value(forAttribute: NSMetadataItemURLKey) as? URL else { continue }
            let status = item.value(forAttribute: NSMetadataUbiquitousItemDownloadingStatusKey) as? String
            if status != NSMetadataUbiquitousItemDownloadingStatusCurrent {
                try? FileManager.default.startDownloadingUbiquitousItem(at: url)
            }
        }
        q.enableUpdates()
        packsMayHaveChanged()
    }

    /// Stops watching (iCloud sync turned off, or everything erased).
    func stopWatchingCloud() {
        guard let q = cloudQuery else { return }
        q.stop()
        cloudObservers.forEach(NotificationCenter.default.removeObserver)
        cloudObservers = []
        cloudQuery = nil
    }

    /// File coordination around iCloud Drive (Apple's rule: iCloud may be
    /// reading or writing the same files).
    nonisolated private static func coordinated<T>(reading url: URL, _ f: (URL) -> T) -> T? {
        var out: T?
        var err: NSError?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &err) { out = f($0) }
        return out
    }

    nonisolated private static func coordinated<T>(writing url: URL, _ f: (URL) -> T) -> T? {
        var out: T?
        var err: NSError?
        NSFileCoordinator().coordinate(writingItemAt: url, options: [], error: &err) { out = f($0) }
        return out
    }

    nonisolated private static func readCloud(_ root: URL) -> [CloudPackInfo] {
        let fm = FileManager.default
        var out: [CloudPackInfo] = []
        for dir in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
            let info = dir.appendingPathComponent("pack.json")
            if !fm.fileExists(atPath: info.path) {
                try? fm.startDownloadingUbiquitousItem(at: info)
                continue
            }
            if let d = try? Data(contentsOf: info), let c = try? JSONDecoder().decode(CloudPackInfo.self, from: d), c.id == dir.lastPathComponent {
                out.append(c)
            }
        }
        return out
    }

    /// The pack's sounds from iCloud Drive into this device; false while
    /// some are still downloading (asked for; taken next time).
    nonisolated private static func copySounds(from src: URL, to dst: URL) -> Bool {
        let fm = FileManager.default
        let items = (try? fm.contentsOfDirectory(at: src, includingPropertiesForKeys: nil, options: [])) ?? []
        // Not downloaded yet: ".name.wav.icloud".
        let waiting = items.filter { $0.lastPathComponent.hasPrefix(".") && $0.pathExtension == "icloud" }
        if !waiting.isEmpty {
            for w in waiting {
                let real = w.deletingLastPathComponent().appendingPathComponent(String(w.deletingPathExtension().lastPathComponent.dropFirst()))
                try? fm.startDownloadingUbiquitousItem(at: real)
            }
            return false
        }
        let staging = dst.deletingLastPathComponent().appendingPathComponent(".\(dst.lastPathComponent)-cloud")
        try? fm.removeItem(at: staging)
        guard (try? fm.createDirectory(at: staging, withIntermediateDirectories: true)) != nil else { return false }
        for f in items where SoundEvent.extensions.contains(f.pathExtension.lowercased()) {
            guard (try? fm.copyItem(at: f, to: staging.appendingPathComponent(f.lastPathComponent))) != nil else { return false }
        }
        try? fm.removeItem(at: dst)
        return (try? fm.moveItem(at: staging, to: dst)) != nil
    }

    nonisolated private static func writeCloud(_ info: CloudPackInfo, from src: URL, to dst: URL) -> Bool {
        let fm = FileManager.default
        guard (try? fm.createDirectory(at: dst, withIntermediateDirectories: true)) != nil else { return false }
        let mine = ((try? fm.contentsOfDirectory(at: src, includingPropertiesForKeys: nil)) ?? []).filter { SoundEvent.extensions.contains($0.pathExtension.lowercased()) }
        let names = Set(mine.map(\.lastPathComponent))
        for old in (try? fm.contentsOfDirectory(at: dst, includingPropertiesForKeys: nil)) ?? [] where !names.contains(old.lastPathComponent) && old.lastPathComponent != "pack.json" {
            try? fm.removeItem(at: old)
        }
        for f in mine {
            let to = dst.appendingPathComponent(f.lastPathComponent)
            try? fm.removeItem(at: to)
            guard (try? fm.copyItem(at: f, to: to)) != nil else { return false }
        }
        guard let d = try? JSONEncoder().encode(info) else { return false }
        return (try? d.write(to: dst.appendingPathComponent("pack.json"), options: .atomic)) != nil
    }
}
