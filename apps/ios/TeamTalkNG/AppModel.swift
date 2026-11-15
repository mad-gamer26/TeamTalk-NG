import Foundation
import Observation

/// Saved servers, the open connections (several at once), and settings.
@MainActor @Observable
final class AppModel {
    private(set) var servers: [SavedServer] = []
    private(set) var connections: [UUID: ServerConnection] = [:]

    var talkMode: TalkMode = .pushToTalk {
        didSet { save(); connections.values.forEach { $0.applyTalkMode() } }
    }
    /// Voice activation: the level that starts it (0–100).
    var voiceLevel: Double = 20 {
        didSet { save(); connections.values.forEach { $0.applyTalkMode() } }
    }
    var nickname = "" { didSet { save() } }

    /// The desktop's Sound System settings, for every server.
    var audio = defaultAudioSettings() {
        didSet {
            saveAudio()
            // Echo cancellation changes the audio session's mode first.
            if audio.echoCancellation != oldValue.echoCancellation { AudioSession.activate() }
            for c in connections.values { c.applyAudioSettings() }
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
        statusMessage = defaults.string(forKey: "statusMessage") ?? ""
        awayAfterMinutes = defaults.integer(forKey: "awayAfterMinutes")
        awayMessage = defaults.string(forKey: "awayMessage") ?? ""
        awayStopsVoiceActivation = defaults.bool(forKey: "awayStopsVoiceActivation")
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
        defaults.set(recordMP3, forKey: "recordMP3")
        defaults.set(recordOneFile, forKey: "recordOneFile")
        defaults.set(recordEachPerson, forKey: "recordEachPerson")
        defaults.set(recordMediaFiles, forKey: "recordMediaFiles")
        defaults.set(saveChatLogs, forKey: "saveChatLogs")
        defaults.set(hearOwnStream, forKey: "hearOwnStream")
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
