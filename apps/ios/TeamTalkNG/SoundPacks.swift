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
        // (vox_me_*): here whenever I turn my microphone on or off
        // (push to talk, mute, the talk mode).
        case .voiceActivationMeOn: "Microphone turned on"
        case .voiceActivationMeOff: "Microphone turned off"
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
    static var catalogBase: URL { Service.baseURL }

    private(set) var installed: [InstalledPack] = []
    var selectedId: String = InstalledPack.builtIn.id { didSet { save(); if !loading, oldValue != selectedId { packsChanged?() } } }
    /// Installed or chosen packs changed here (NG Account sends them).
    @ObservationIgnored var packsChanged: (() -> Void)?
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
        for f in pack.files where SoundEvent.extensions.contains((f.name as NSString).pathExtension.lowercased()) {
            // Names come from the catalog: keep them to plain file names.
            guard !f.name.contains("/"), !f.name.hasPrefix(".") else { continue }
            // The desktop's hotkey sound isn't used here.
            if SoundEvent.unused.contains(((f.name as NSString).deletingPathExtension).lowercased()) { continue }
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
        packsChanged?()
        // Counted in the catalog (best effort).
        var req = URLRequest(url: Self.catalogBase.appendingPathComponent("v1/catalog/\(pack.id)/installed"))
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
    func createPack(name: String, author: String) -> InstalledPack {
        let p = InstalledPack(id: "own-" + UUID().uuidString.prefix(8).lowercased(),
                              name: name.trimmingCharacters(in: .whitespaces).nonEmpty ?? "My sound pack",
                              author: author.trimmingCharacters(in: .whitespaces), version: "", description: "")
        try? FileManager.default.createDirectory(at: Self.directory(p.id), withIntermediateDirectories: true)
        add(p)
        return p
    }

    /// A copy of any pack, mine to edit (the built-in one's copy starts
    /// empty: its sounds are the built-in ones anyway).
    @discardableResult
    func duplicate(_ source: InstalledPack, name: String) -> InstalledPack {
        let p = createPack(name: name, author: source.author)
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
    private(set) var packEdited = UUID()

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
