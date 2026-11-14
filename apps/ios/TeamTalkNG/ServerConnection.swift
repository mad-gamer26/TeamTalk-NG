import Foundation
import Observation

/// A line in a server's conversation.
struct ChatLine: Identifiable, Hashable, Codable {
    var id = UUID()
    let from: String
    let text: String
    /// "private" lines are between me and one person.
    let privateWith: String?
    let time: Date
}

/// Hands the core's events (on its event thread) to the main thread.
final class EventBridge: TtListener, @unchecked Sendable {
    weak var connection: ServerConnection?

    func onEvent(event: Event) {
        Task { @MainActor [weak self] in self?.connection?.handle(event) }
    }
}

/// One server: its core client, what it shows, and talking. Stays connected
/// while the app is open, whichever screen is showing.
@MainActor @Observable
final class ServerConnection {
    var server: SavedServer
    private weak var app: AppModel?
    private let bridge = EventBridge()
    private let client: TtClient

    private(set) var state: ConnectionState = .disconnected
    private(set) var snapshot: Snapshot?
    private(set) var lines: [ChatLine] = [] {
        didSet { History.save(lines, for: server.id) }
    }
    /// Uploads and downloads under way, by transfer ID.
    private(set) var transfers: [Int32: Transfer] = [:]
    /// The last thing that went wrong, in words.
    private(set) var problem: String?
    /// Busy connecting (the button waits).
    private(set) var busy = false

    /// Push to talk: talking now.
    private(set) var transmitting = false
    /// Voice activation and always on: microphone muted.
    private(set) var muted = false
    /// Voice activation is sending my voice now.
    private(set) var voiceActive = false

    init(server: SavedServer, app: AppModel) {
        self.server = server
        self.app = app
        client = TtClient(listener: bridge)
        lines = History.load(for: server.id)
        bridge.connection = self
    }

    var isConnected: Bool { state == .loggedIn }

    var stateText: String {
        switch state {
        case .disconnected: problem.map { "Not connected: \($0)" } ?? "Not connected"
        case .connecting: "Connecting"
        case .loggingIn: "Logging in"
        case .loggedIn: "Connected"
        case .reconnecting(let n): "Connection lost, reconnecting (attempt \(n))"
        }
    }

    // MARK: Connecting

    func connect() {
        guard !busy, state == .disconnected else { return }
        busy = true
        problem = nil
        let s = server
        let nickname = s.nickname.isEmpty ? (app?.nickname ?? "") : s.nickname
        let options = ConnectOptions(
            host: s.host, tcpPort: s.tcpPort, udpPort: s.udpPort, encrypted: s.encrypted,
            nickname: nickname.isEmpty ? s.username : nickname, username: s.username,
            password: Passwords.get(s.id), clientName: "TeamTalk NG",
            joinChannelPath: s.joinChannel, joinChannelPassword: "", reconnect: true)
        let client = self.client
        Task {
            let allowed = await AudioSession.requestMicrophone()
            AudioSession.activate()
            let result: String? = await Task.detached {
                do {
                    try client.connect(options: options)
                    // Every connection shares the microphone and speaker.
                    try? client.initAudio(devices: allowed ? .shared : .virtual)
                    return nil
                } catch {
                    return words(error)
                }
            }.value
            busy = false
            problem = result
            refresh()
            if let result {
                announce("Couldn't connect: \(result)")
            } else {
                applyTalkMode()
            }
        }
    }

    func disconnect() {
        let client = self.client
        transmitting = false
        Task.detached { try? client.disconnect() }
    }

    // MARK: Channels and messages

    func join(_ channel: Channel, password: String = "") {
        run("Couldn't join") { try $0.joinChannel(channelId: channel.id, password: password) }
    }

    func leaveChannel() {
        run("Couldn't leave") { try $0.leaveChannel() }
    }

    /// To my channel, or privately to someone.
    func send(_ text: String, to user: User? = nil) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let snap = snapshot else { return }
        let target: MessageTarget
        if let user {
            target = .user(userId: user.id)
            // The server doesn't echo private messages back.
            lines.append(ChatLine(from: "Me", text: text, privateWith: user.displayName, time: .now))
        } else {
            guard snap.myChannelId > 0 else { return }
            target = .channel(channelId: snap.myChannelId)
        }
        run("Couldn't send") { try $0.sendMessage(target: target, text: text) }
    }

    func setStatus(_ mode: StatusMode, _ message: String) {
        run("Couldn't change the status") { try $0.setStatus(mode: mode, message: message) }
    }

    func setVolume(_ user: User, percent: Int) {
        run("Couldn't change the volume") { try $0.setUserVolume(userId: user.id, percent: Int32(percent)) }
    }

    func setMuted(_ user: User, _ muted: Bool) {
        run("Couldn't mute") { try $0.setUserMuted(userId: user.id, muted: muted) }
    }

    // MARK: Files

    /// Uploads a file picked by the person (copied first: the picker's URL
    /// is only readable for a moment).
    func upload(_ url: URL) {
        guard let channel = snapshot?.myChannelId, channel > 0 else { return }
        let reading = url.startAccessingSecurityScopedResource()
        defer { if reading { url.stopAccessingSecurityScopedResource() } }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("uploads/\(UUID().uuidString)")
        let copy = dir.appendingPathComponent(url.lastPathComponent)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: url, to: copy)
        } catch {
            announce("Couldn't read that file: \(error.localizedDescription)")
            return
        }
        let path = copy.path
        run("Couldn't upload") { try $0.uploadFile(channelId: channel, localPath: path) }
    }

    /// Downloads into the app's documents (visible in the Files app).
    func download(_ file: RemoteFile) {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        var target = docs.appendingPathComponent(file.name)
        var n = 2
        let base = (file.name as NSString).deletingPathExtension, ext = (file.name as NSString).pathExtension
        while FileManager.default.fileExists(atPath: target.path) {
            target = docs.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
            n += 1
        }
        let path = target.path
        run("Couldn't download") { try $0.downloadFile(channelId: file.channelId, fileId: file.id, localPath: path) }
    }

    func delete(_ file: RemoteFile) {
        run("Couldn't delete") { try $0.deleteFile(channelId: file.channelId, fileId: file.id) }
    }

    func cancel(_ transfer: Transfer) {
        run("Couldn't cancel") { try $0.cancelTransfer(transferId: transfer.id) }
    }

    /// May I delete it: mine, or I'm an admin.
    func canDelete(_ file: RemoteFile) -> Bool {
        guard let s = snapshot, let me = s.users.first(where: { $0.id == s.myUserId }) else { return false }
        return me.admin || me.username == file.uploader
    }

    func clearHistory() { lines = [] }

    // MARK: Administration

    var rights: MyRights { snapshot?.myRights ?? MyRights(admin: false, createTemporaryChannels: false, modifyChannels: false, broadcast: false, kick: false, ban: false, moveUsers: false, uploadFiles: false, downloadFiles: false, updateServer: false) }

    func kick(_ user: User, fromChannel: Bool) {
        run("Couldn't kick") { try $0.kickUser(userId: user.id, fromChannel: fromChannel) }
    }

    /// Bans, then kicks them off the server.
    func ban(_ user: User, by kind: BanKind) {
        run("Couldn't ban") { c in
            try c.banUser(userId: user.id, kind: kind)
            try c.kickUser(userId: user.id, fromChannel: false)
        }
    }

    func move(_ user: User, to channel: Channel) {
        run("Couldn't move") { try $0.moveUser(userId: user.id, channelId: channel.id) }
    }

    /// Makes a channel, or (`temporary`) makes one and joins it.
    func makeChannel(_ spec: ChannelSpec, temporary: Bool) {
        run("Couldn't make the channel") { c in
            if temporary { try c.joinNewChannel(spec: spec) } else { try c.makeChannel(spec: spec) }
        }
    }

    func updateChannel(_ channel: Channel, _ spec: ChannelSpec) {
        run("Couldn't change the channel") { try $0.updateChannel(channelId: channel.id, spec: spec) }
    }

    func removeChannel(_ channel: Channel) {
        run("Couldn't delete the channel") { try $0.removeChannel(channelId: channel.id) }
    }

    func updateServer(name: String, motd: String) {
        run("Couldn't change the server") { try $0.updateServer(name: name, motd: motd) }
    }

    func broadcast(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        run("Couldn't broadcast") { try $0.sendMessage(target: .broadcast, text: text) }
    }

    /// The server's bans (nil and announced when they can't be listed).
    func bans() async -> [Ban]? {
        let client = self.client
        let result: Result<[Ban], Error> = await Task.detached {
            do { return .success(try client.listBans()) } catch { return .failure(error) }
        }.value
        switch result {
        case .success(let b): return b
        case .failure(let e):
            announce("Couldn't list the bans: \(words(e))")
            return nil
        }
    }

    func unban(_ ban: Ban) async -> Bool {
        let client = self.client
        let failed: String? = await Task.detached {
            do { try client.unban(ban: ban); return nil } catch { return words(error) }
        }.value
        if let failed { announce("Couldn't remove the ban: \(failed)") }
        return failed == nil
    }

    /// Runs a core call off the main thread; failures are announced.
    private func run(_ what: String, _ call: @escaping @Sendable (TtClient) throws -> Void) {
        let client = self.client
        Task {
            let failed: String? = await Task.detached {
                do { try call(client); return nil } catch { return words(error) }
            }.value
            if let failed {
                problem = failed
                announce("\(what): \(failed)")
            }
        }
    }

    // MARK: Talking

    /// Push to talk on or off (the talk button and Magic Tap).
    func setTransmitting(_ on: Bool) {
        guard isConnected, app?.talkMode == .pushToTalk, on != transmitting else { return }
        transmitting = on
        sound(on ? .on : .off)
        run("Couldn't talk") { try $0.setTransmitting(on: on) }
    }

    func setMicMuted(_ on: Bool) {
        muted = on
        sound(on ? .off : .on)
        applyTalkMode()
    }

    /// Magic Tap: talk or stop (push to talk), or mute and unmute.
    func toggleTalking() {
        guard isConnected, let mode = app?.talkMode else { return }
        if mode == .pushToTalk {
            setTransmitting(!transmitting)
            announce(transmitting ? "Talking" : "Stopped talking")
        } else {
            setMicMuted(!muted)
            announce(muted ? "Microphone muted" : "Microphone on")
        }
    }

    /// Sets the core to the app's talk mode.
    func applyTalkMode() {
        guard isConnected, let app else { return }
        let mode = app.talkMode, level = Int32(app.voiceLevel), muted = self.muted
        if mode != .pushToTalk { transmitting = false }
        let ptt = transmitting
        run("Couldn't set up talking") { c in
            switch mode {
            case .pushToTalk:
                try c.setVoiceActivation(on: false, level: level, stopDelayMs: 500)
                try c.setTransmitting(on: ptt)
            case .voiceActivation:
                try c.setTransmitting(on: false)
                try c.setVoiceActivation(on: !muted, level: level, stopDelayMs: 500)
            case .alwaysOn:
                try c.setVoiceActivation(on: false, level: level, stopDelayMs: 500)
                try c.setTransmitting(on: !muted)
            }
        }
    }

    func inputLevel() -> Int { Int(client.inputLevel()) }

    // MARK: Events

    private var refreshPending = false
    /// The connection dropped since the last login.
    private var dropped = false

    /// A fresh snapshot, at most once per main-thread turn.
    private func refresh() {
        guard !refreshPending else { return }
        refreshPending = true
        Task { @MainActor in
            refreshPending = false
            snapshot = client.snapshot()
            state = snapshot?.state ?? .disconnected
        }
    }

    private var myChannel: Int32 { snapshot?.myChannelId ?? 0 }
    private func sound(_ e: SoundEvent) { app?.sounds.play(e) }
    private var me: User? { snapshot.flatMap { s in s.users.first { $0.id == s.myUserId } } }

    fileprivate func handle(_ event: Event) {
        switch event {
        case .connectionChanged(let s):
            state = s
            switch s {
            case .loggedIn where dropped:
                dropped = false
                announce("\(server.title): reconnected")
                applyTalkMode()
            case .reconnecting(let n):
                transmitting = false
                if !dropped {
                    sound(.serverLost)
                    announce("\(server.title): connection lost, reconnecting")
                }
                dropped = n > 0
            case .disconnected:
                transmitting = false
                voiceActive = false
            default: break
            }
        case .connectionFailed(let m):
            problem = m
            announce("\(server.title): \(m)")
        case .messageReceived(let m):
            let from = snapshot?.users.first { $0.id == m.fromUserId }?.displayName ?? m.fromUsername
            switch m.target {
            case .user:
                lines.append(ChatLine(from: from, text: m.text, privateWith: from, time: .now))
                sound(.privateMessage)
                announce("Private message from \(from): \(m.text)")
            case .channel:
                let mine = m.fromUserId == snapshot?.myUserId
                lines.append(ChatLine(from: mine ? "Me" : from, text: m.text, privateWith: nil, time: .now))
                if !mine {
                    sound(.channelMessage)
                    announce("\(from): \(m.text)")
                }
            case .broadcast:
                lines.append(ChatLine(from: "Broadcast from \(from)", text: m.text, privateWith: nil, time: .now))
                sound(.broadcastMessage)
                announce("Broadcast from \(from): \(m.text)")
            }
        case .userJoined(let u, let ch):
            if ch == myChannel, u.id != snapshot?.myUserId {
                sound(.userJoined)
                announce("\(u.displayName) joined")
            }
        case .userLeft(let u, let ch):
            if ch == myChannel, u.id != snapshot?.myUserId {
                sound(.userLeft)
                announce("\(u.displayName) left")
            }
        case .userLoggedIn(let u):
            // Not for those already there when I log in (the server lists them).
            if state == .loggedIn, u.id != snapshot?.myUserId { sound(.loggedIn) }
        case .userLoggedOut(let u):
            if state == .loggedIn, u.id != snapshot?.myUserId { sound(.loggedOut) }
        case .fileRemoved(let f):
            if f.channelId == myChannel { sound(.fileUpdate) }
        case .transferChanged(let t):
            switch t.status {
            case .active:
                if transfers[t.id] == nil {
                    announce("\(t.inbound ? "Downloading" : "Uploading") \(t.remoteName)")
                }
                transfers[t.id] = t
            case .finished:
                transfers[t.id] = nil
                sound(.transferComplete)
                announce("\(t.inbound ? "Downloaded" : "Uploaded") \(t.remoteName)")
                if !t.inbound { try? FileManager.default.removeItem(atPath: (t.localPath as NSString).deletingLastPathComponent) }
            case .failed:
                transfers[t.id] = nil
                announce("\(t.inbound ? "Download" : "Upload") of \(t.remoteName) failed")
            case .cancelled:
                transfers[t.id] = nil
                announce("Cancelled \(t.remoteName)")
            }
        case .fileAdded(let f):
            if f.channelId == myChannel, f.uploader != me?.username {
                sound(.fileUpdate)
                announce("New file: \(f.name)")
            }
        case .voiceActivated(let on):
            voiceActive = on
        case .kicked(_, let ch):
            announce(ch > 0 ? "You were kicked from the channel" : "You were kicked from the server")
        default: break
        }
        refresh()
    }
}

/// Each server's conversation, kept between launches (the last 500 lines).
enum History {
    private static func url(_ id: UUID) -> URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("History", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("\(id.uuidString).json")
    }

    static func load(for id: UUID) -> [ChatLine] {
        guard let d = try? Data(contentsOf: url(id)) else { return [] }
        return (try? JSONDecoder().decode([ChatLine].self, from: d)) ?? []
    }

    static func save(_ lines: [ChatLine], for id: UUID) {
        let keep = Array(lines.suffix(500))
        guard let d = try? JSONEncoder().encode(keep) else { return }
        try? d.write(to: url(id), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    static func delete(for id: UUID) {
        try? FileManager.default.removeItem(at: url(id))
    }
}
