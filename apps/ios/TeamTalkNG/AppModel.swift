import Foundation
import Observation

/// Saved servers, the open connections (several at once), and settings.
@MainActor @Observable
final class AppModel {
    private(set) var servers: [SavedServer] = []
    private(set) var connections: [UUID: ServerConnection] = [:]

    var talkMode: TalkMode = .pushToTalk {
        didSet {
            save()
            connections.values.forEach { $0.applyTalkMode() }
            if talkMode != oldValue && (talkMode == .voiceActivation || oldValue == .voiceActivation) {
                sounds.play(talkMode == .voiceActivation ? .voiceActivationOn : .voiceActivationOff)
            }
        }
    }
    /// Voice activation: the level that starts it (0–100).
    var voiceLevel: Double = 20 {
        didSet { save(); connections.values.forEach { $0.applyTalkMode() } }
    }
    var nickname = "" { didSet { save() } }
    /// Set on every server after logging in (the desktop's gender setting).
    var gender = Gender.neutral { didSet { save() } }

    /// The desktop's Sound System settings, for every server.
    var audio = defaultAudioSettings() {
        didSet {
            saveAudio()
            // Echo cancellation changes the audio session's mode first.
            if audio.echoCancellation != oldValue.echoCancellation { AudioSession.activate() }
            for c in connections.values { c.applyAudioSettings() }
        }
    }

    /// Stream the video of video files too (VP8).
    var streamVideo = true {
        didSet {
            save()
            for c in connections.values { c.applyHearOwnStream() }
        }
    }

    /// Hear the files I stream (the SDK doesn't play my own stream back).
    var hearOwnStream = true {
        didSet {
            save()
            for c in connections.values { c.applyHearOwnStream() }
        }
    }

    /// Recording as the desktop sets it up.
    var recordMP3 = true { didSet { save() } }
    var recordOneFile = true { didSet { save() } }
    var recordEachPerson = false { didSet { save() } }
    var recordMediaFiles = false { didSet { save() } }
    /// Each server's chat written to text files too.
    var saveChatLogs = false { didSet { save() } }

    /// The desktop's General settings for me: a status message to log in
    /// with, and going away when TeamTalk NG is in the background (or the
    /// iPhone is locked) this long, with its own message, maybe without
    /// voice activation.
    var statusMessage = "" { didSet { save() } }
    var awayAfterMinutes = 0 { didSet { save() } }
    var awayMessage = "" { didSet { save() } }
    var awayStopsVoiceActivation = false { didSet { save() } }
    @ObservationIgnored private var awayTimer: Task<Void, Never>?
    let sounds = SoundStore()
    let speech = SpeechStore()
    let chatTemplates = ChatTemplateStore()

    // MARK: Display (the desktop's Display tab)

    enum ChannelTap: String, CaseIterable, Identifiable {
        case join, joinOrLeave, nothing
        var id: Self { self }
        var label: String {
            switch self {
            case .join: "Joins it"
            case .joinOrLeave: "Joins it, or leaves it if you're there"
            case .nothing: "Nothing (use its actions)"
            }
        }
    }

    var showUsernames = false { didSet { save() } }
    var showTopics = true { didSet { save() } }
    var sortChannelsByName = true { didSet { save() } }
    var channelTap = ChannelTap.join { didSet { save() } }
    var showTimestamps = true { didSet { save() } }
    var showMOTD = true { didSet { save() } }
    var eventsInChat = false { didSet { save() } }
    var notifyInBackground = true { didSet { save() } }

    // MARK: Connection (the desktop's Connection tab)

    var reconnect = true { didSet { save() } }
    var joinRoot = true { didSet { save() } }
    /// What's received from people by default (the rest is turned off for
    /// each one as they log in).
    var defaultSubscriptionsOff: Set<Subscription> = [] { didSet { save() } }
    @ObservationIgnored private(set) lazy var account = NGAccountStore(app: self)
    @ObservationIgnored private(set) lazy var monitor = MonitorStore(app: self)

    private let defaults = UserDefaults.standard

    init() {
        if let d = defaults.data(forKey: "servers"), let s = try? JSONDecoder().decode([SavedServer].self, from: d) {
            servers = s
        }
        talkMode = TalkMode(rawValue: defaults.string(forKey: "talkMode") ?? "") ?? .pushToTalk
        voiceLevel = defaults.object(forKey: "voiceLevel") as? Double ?? 20
        nickname = defaults.string(forKey: "nickname") ?? ""
        gender = ["male": Gender.male, "female": .female][defaults.string(forKey: "gender") ?? ""] ?? .neutral
        if let a = defaults.dictionary(forKey: "audio") as? [String: Int] {
            audio = AudioSettings(
                echoCancellation: a["echo"] == 1, gainControl: a["agc", default: 1] == 1, noiseSuppression: a["denoise", default: 1] == 1,
                micGain: Int32(a["mic", default: 100]), outputVolume: Int32(a["out", default: 100]), mediaVolume: Int32(a["media", default: 100]))
        }
        recordMP3 = defaults.object(forKey: "recordMP3") as? Bool ?? true
        recordOneFile = defaults.object(forKey: "recordOneFile") as? Bool ?? true
        recordEachPerson = defaults.bool(forKey: "recordEachPerson")
        recordMediaFiles = defaults.bool(forKey: "recordMediaFiles")
        saveChatLogs = defaults.bool(forKey: "saveChatLogs")
        hearOwnStream = defaults.object(forKey: "hearOwnStream") as? Bool ?? true
        streamVideo = defaults.object(forKey: "streamVideo") as? Bool ?? true
        showUsernames = defaults.bool(forKey: "showUsernames")
        showTopics = defaults.object(forKey: "showTopics") as? Bool ?? true
        sortChannelsByName = defaults.object(forKey: "sortChannelsByName") as? Bool ?? true
        channelTap = ChannelTap(rawValue: defaults.string(forKey: "channelTap") ?? "") ?? .join
        showTimestamps = defaults.object(forKey: "showTimestamps") as? Bool ?? true
        showMOTD = defaults.object(forKey: "showMOTD") as? Bool ?? true
        eventsInChat = defaults.bool(forKey: "eventsInChat")
        notifyInBackground = defaults.object(forKey: "notifyInBackground") as? Bool ?? true
        reconnect = defaults.object(forKey: "reconnect") as? Bool ?? true
        joinRoot = defaults.object(forKey: "joinRoot") as? Bool ?? true
        defaultSubscriptionsOff = Set((defaults.stringArray(forKey: "subscriptionsOff") ?? []).compactMap { name in
            PersonView.normal.first { "\($0)" == name }
        })
        statusMessage = defaults.string(forKey: "statusMessage") ?? ""
        awayAfterMinutes = defaults.integer(forKey: "awayAfterMinutes")
        awayMessage = defaults.string(forKey: "awayMessage") ?? ""
        awayStopsVoiceActivation = defaults.bool(forKey: "awayStopsVoiceActivation")
    }

    /// The desktop's "Reset preferences to default": every setting as it
    /// was at first (servers, accounts and sound packs stay).
    func resetPreferences() {
        let keep: Set<String> = ["servers", "installId", "ngEmail", "ngSyncState", "soundPacks"]
        for k in defaults.dictionaryRepresentation().keys where !keep.contains(k) && !k.hasPrefix("Apple") && !k.hasPrefix("NS") {
            defaults.removeObject(forKey: k)
        }
        talkMode = .pushToTalk
        voiceLevel = 20
        nickname = ""
        audio = defaultAudioSettings()
        recordMP3 = true; recordOneFile = true; recordEachPerson = false; recordMediaFiles = false; saveChatLogs = false
        statusMessage = ""; awayAfterMinutes = 0; awayMessage = ""; awayStopsVoiceActivation = false
        hearOwnStream = true
        showUsernames = false; showTopics = true; sortChannelsByName = true; channelTap = .join
        showTimestamps = true; showMOTD = true; eventsInChat = false; notifyInBackground = true
        reconnect = true; joinRoot = true; defaultSubscriptionsOff = []
        sounds.revert()
        sounds.volume = 0.8
        sounds.selectedId = InstalledPack.builtIn.id
        speech.revert()
        chatTemplates.revert()
        AudioSession.activate()
    }

    /// A server from a .tt file, tt:// link, join code or the public list
    /// (the same server already saved is updated instead).
    @discardableResult
    func addFromEntry(_ e: HostEntry, connect: Bool = false) -> SavedServer {
        var s = SavedServer(e)
        if let same = servers.first(where: { $0.host.caseInsensitiveCompare(e.host) == .orderedSame && $0.tcpPort == e.tcpPort && $0.username == e.username }) {
            let id = same.id
            s.id = id
            s.syncKey = same.syncKey
        }
        upsert(s, password: e.password.isEmpty ? Passwords.get(s.id) : e.password)
        if connect { connection(for: s).connect() }
        return s
    }

    /// Opens what iOS hands the app: tt:// links (connect) and .tt files.
    func open(_ url: URL) {
        if url.scheme?.lowercased() == "tt", let e = parseTtLink(link: url.absoluteString) {
            addFromEntry(e, connect: true)
            announce("Connecting to \(e.host)")
            return
        }
        let reading = url.startAccessingSecurityScopedResource()
        defer { if reading { url.stopAccessingSecurityScopedResource() } }
        guard let xml = try? String(contentsOf: url, encoding: .utf8) else {
            announce("That file couldn't be read")
            return
        }
        do {
            let list = try parseTtFile(xml: xml)
            for e in list { addFromEntry(e) }
            announce(list.count == 1 ? "Added \(list[0].name)" : "Added \(list.count) servers")
        } catch {
            announce(words(error))
        }
    }

    /// Servers marked to connect when the app starts.
    func connectOnStart() {
        for s in servers where s.connectOnStart == true { connection(for: s).connect() }
    }

    /// The app went to the background (or was locked), or came back.
    func activeChanged(_ active: Bool) {
        awayTimer?.cancel()
        awayTimer = nil
        if active {
            for c in connections.values { c.setAutoAway(false) }
            return
        }
        guard awayAfterMinutes > 0 else { return }
        let minutes = awayAfterMinutes
        awayTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(minutes * 60))
            guard !Task.isCancelled, let self else { return }
            for c in self.connections.values { c.setAutoAway(true) }
        }
    }

    private func saveAudio() {
        defaults.set(["echo": audio.echoCancellation ? 1 : 0, "agc": audio.gainControl ? 1 : 0,
                      "denoise": audio.noiseSuppression ? 1 : 0, "mic": Int(audio.micGain),
                      "out": Int(audio.outputVolume), "media": Int(audio.mediaVolume)], forKey: "audio")
    }

    private func save() {
        defaults.set(try? JSONEncoder().encode(servers), forKey: "servers")
        defaults.set(talkMode.rawValue, forKey: "talkMode")
        defaults.set(voiceLevel, forKey: "voiceLevel")
        defaults.set(nickname, forKey: "nickname")
        defaults.set(gender == .male ? "male" : gender == .female ? "female" : "neutral", forKey: "gender")
        defaults.set(recordMP3, forKey: "recordMP3")
        defaults.set(recordOneFile, forKey: "recordOneFile")
        defaults.set(recordEachPerson, forKey: "recordEachPerson")
        defaults.set(recordMediaFiles, forKey: "recordMediaFiles")
        defaults.set(saveChatLogs, forKey: "saveChatLogs")
        defaults.set(hearOwnStream, forKey: "hearOwnStream")
        defaults.set(streamVideo, forKey: "streamVideo")
        defaults.set(showUsernames, forKey: "showUsernames")
        defaults.set(showTopics, forKey: "showTopics")
        defaults.set(sortChannelsByName, forKey: "sortChannelsByName")
        defaults.set(channelTap.rawValue, forKey: "channelTap")
        defaults.set(showTimestamps, forKey: "showTimestamps")
        defaults.set(showMOTD, forKey: "showMOTD")
        defaults.set(eventsInChat, forKey: "eventsInChat")
        defaults.set(notifyInBackground, forKey: "notifyInBackground")
        defaults.set(reconnect, forKey: "reconnect")
        defaults.set(joinRoot, forKey: "joinRoot")
        defaults.set(defaultSubscriptionsOff.map { "\($0)" }, forKey: "subscriptionsOff")
        defaults.set(statusMessage, forKey: "statusMessage")
        defaults.set(awayAfterMinutes, forKey: "awayAfterMinutes")
        defaults.set(awayMessage, forKey: "awayMessage")
        defaults.set(awayStopsVoiceActivation, forKey: "awayStopsVoiceActivation")
    }

    func upsert(_ server: SavedServer, password: String) {
        if let i = servers.firstIndex(where: { $0.id == server.id }) {
            servers[i] = server
        } else {
            servers.append(server)
        }
        Passwords.set(password, for: server.id)
        save()
        account.changed()
    }

    /// From NG Account: the servers as the account has them now (no sync
    /// back of this change).
    func applySynced(_ list: [SavedServer], passwords: [UUID: String]) {
        servers = list
        for (id, p) in passwords { Passwords.set(p, for: id) }
        save()
    }

    func delete(_ server: SavedServer) {
        connections[server.id]?.disconnect()
        connections[server.id] = nil
        servers.removeAll { $0.id == server.id }
        Passwords.set("", for: server.id)
        History.delete(for: server.id)
        save()
        account.deleted(server.key)
    }

    func move(from: IndexSet, to: Int) {
        servers.move(fromOffsets: from, toOffset: to)
        save()
        account.changed()
    }

    /// The server's connection, made (not connected) on first use.
    func connection(for server: SavedServer) -> ServerConnection {
        if let c = connections[server.id] {
            c.server = server
            return c
        }
        let c = ServerConnection(server: server, app: self)
        connections[server.id] = c
        return c
    }
}
