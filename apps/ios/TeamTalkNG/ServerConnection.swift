import Foundation
import UIKit
import UserNotifications
import Observation

/// A line in a server's conversation.
struct ChatLine: Identifiable, Hashable, Codable {
    var id = UUID()
    let from: String
    let text: String
    /// "private" lines are between me and one person.
    let privateWith: String?
    let time: Date
    /// Its desktop template and variables (Settings → Display → Message
    /// templates); lines saved before templates have none.
    var kind: ChatTemplate? = nil
    var vars: [String: String]? = nil
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
    /// For screens that call the core themselves (off the main thread).
    var coreClient: TtClient { client }
    /// People picked to move together (the desktop's "store for move").
    private(set) var pickedToMove: Set<Int32> = []

    func togglePicked(_ u: User) {
        if pickedToMove.contains(u.id) { pickedToMove.remove(u.id) } else { pickedToMove.insert(u.id) }
        announce(pickedToMove.contains(u.id) ? "\(u.displayName) picked to move, \(pickedToMove.count) in all" : "\(u.displayName) no longer picked")
    }

    /// Moves everyone picked into a channel.
    func movePicked(to c: Channel) {
        let ids = pickedToMove
        pickedToMove = []
        run("Couldn't move everyone") { cl in
            for id in ids { try cl.moveUser(userId: id, channelId: c.id) }
        }
        announce(ids.count == 1 ? "Moved 1 person" : "Moved \(ids.count) people")
    }

    /// Who is writing to me privately right now (until when).
    private(set) var typing: [Int32: Date] = [:]
    private var lastTypingSent: [Int32: (Bool, Date)] = [:]

    /// Tells someone I'm writing (at most every few seconds), or stopped.
    func setTyping(to user: User, _ on: Bool) {
        let last = lastTypingSent[user.id]
        if let last, last.0 == on, !on || Date.now.timeIntervalSince(last.1) < 3 { return }
        lastTypingSent[user.id] = (on, .now)
        run("Couldn't say you're typing") { try $0.setTyping(userId: user.id, typing: on) }
    }

    func isTyping(_ user: User) -> Bool { isTypingId(user.id) }
    private func isTypingId(_ id: Int32) -> Bool { (typing[id] ?? .distantPast) > .now }

    /// People who logged out while I was connected (Online users).
    private(set) var departed: [(user: User, at: Date)] = []

    private(set) var state: ConnectionState = .disconnected
    private(set) var snapshot: Snapshot?
    private(set) var lines: [ChatLine] = [] {
        didSet {
            History.save(lines, for: server.id)
            if lines.count == oldValue.count + 1, let last = lines.last { log(last) }
        }
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
            joinChannelPath: s.joinLastChannel == true ? (UserDefaults.standard.string(forKey: "lastChannel-\(s.id)") ?? s.joinChannel) : s.joinChannel,
            joinChannelPassword: s.channelPassword, reconnect: app?.reconnect ?? true,
            caPem: s.encrypted ? s.caPem : "", certPem: s.encrypted ? s.certPem : "", keyPem: s.encrypted ? s.keyPem : "",
            verifyPeer: s.encrypted && s.verifyPeer,
            webLoginUsername: s.bearwareLogin ? BearWare.username : "", webLoginToken: s.bearwareLogin ? BearWare.token : "")
        let client = self.client
        let audio = app?.audio ?? defaultAudioSettings()
        let hearOwn = app?.hearOwnStream ?? true
        let streamVideo = app?.streamVideo ?? true
        Task {
            let allowed = await AudioSession.requestMicrophone()
            AudioSession.activate()
            let result: String? = await Task.detached {
                do {
                    try client.connect(options: options)
                    // Every connection shares the microphone and speaker.
                    try? client.setAudioSettings(settings: audio)
                    try? client.setHearOwnStream(on: hearOwn)
                    try? client.setStreamVideo(on: streamVideo)
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
                app?.monitor.appConnected(server, true)
                // Settings → Connection: the root channel, when the server
                // entry and the account didn't say where.
                if app?.joinRoot == true, (snapshot?.myChannelId ?? 0) == 0 {
                    run("Couldn't join the root channel") { try $0.joinChannelPath(path: "/", password: "") }
                }
                // The server's own status message, else the one in Settings.
                let own = server.statusMessage
                let msg = own.isEmpty ? (app?.statusMessage ?? "") : own
                if !msg.isEmpty { setStatus(.available, msg) }
                if let g = app?.gender, g != .male { setGender(g) }
            }
        }
    }

    func disconnect() {
        let client = self.client
        transmitting = false
        app?.monitor.appConnected(server, false)
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
            lastTypingSent[user.id] = (false, .now)
            run("Couldn't say you stopped typing") { try $0.setTyping(userId: user.id, typing: false) }
            // The server doesn't echo private messages back.
            lines.append(ChatLine(from: "Me", text: text, privateWith: user.displayName, time: .now, kind: .privateMessage, vars: ["user": myName, "content": text]))
            sound(.privateMessageSent)
            say(.privateMessageSent, ["message": text])
        } else {
            guard snap.myChannelId > 0 else { return }
            target = .channel(channelId: snap.myChannelId)
        }
        run("Couldn't send") { try $0.sendMessage(target: target, text: text) }
    }

    func setStatus(_ mode: StatusMode, _ message: String) {
        autoAway = nil
        run("Couldn't change the status") { try $0.setStatus(mode: mode, message: message) }
    }

    /// The status before going away by itself (to come back to), when away.
    private var autoAway: (mode: StatusMode, message: String)?
    /// Voice activation paused while away (Settings).
    private(set) var awayPausedVoice = false

    /// Goes away by itself (or comes back), as the desktop does after a
    /// while without input. A status the person chose meanwhile stays.
    func setAutoAway(_ on: Bool) {
        guard isConnected, let app, let me else { return }
        if on {
            guard autoAway == nil, me.status == .available else { return }
            autoAway = (me.status, me.statusMessage)
            let msg = app.awayMessage.isEmpty ? me.statusMessage : app.awayMessage
            run("Couldn't go away") { try $0.setStatus(mode: .away, message: msg) }
            if app.awayStopsVoiceActivation && app.talkMode == .voiceActivation {
                awayPausedVoice = true
                applyTalkMode()
            }
        } else if let back = autoAway {
            autoAway = nil
            if me.status == .away {
                run("Couldn't come back") { try $0.setStatus(mode: back.mode, message: back.message) }
            }
            if awayPausedVoice {
                awayPausedVoice = false
                applyTalkMode()
            }
        }
    }

    // MARK: People (the desktop's Users menu)

    var me: User? { snapshot.flatMap { s in s.users.first { $0.id == s.myUserId } } }

    /// May I moderate this channel: an admin, or its operator.
    /// A channel's path in words ("Lobby, Music"; the root by the server's name).
    func channelPathText(_ c: Channel) -> String {
        if c.parentId == 0 { return "Root channel" }
        return client.channelPath(channelId: c.id)
    }

    func canModerate(channel id: Int32) -> Bool {
        rights.admin || (me?.operator == true && me?.channelId == id)
    }

    func setSubscription(_ user: User, _ what: Subscription, _ on: Bool) {
        run("Couldn't change that") { try $0.setSubscription(userId: user.id, what: what, on: on) }
    }

    func setHearMyself(_ on: Bool) {
        run("Couldn't change that") { try $0.setHearMyself(on: on) }
    }

    var hearingMyself: Bool { me?.mySubscriptions.on.contains(.voice) ?? false }

    func setMediaVolume(_ user: User, percent: Int) {
        run("Couldn't change the volume") { try $0.setUserMediaVolume(userId: user.id, percent: Int32(percent)) }
    }

    func setMediaMuted(_ user: User, _ muted: Bool) {
        run("Couldn't mute") { try $0.setUserMediaMuted(userId: user.id, muted: muted) }
    }

    func setStereo(_ user: User, _ stream: AudioStream, left: Bool, right: Bool) {
        run("Couldn't change that") { try $0.setUserStereo(userId: user.id, stream: stream, left: left, right: right) }
    }

    func setMuteAll(_ on: Bool) {
        sound(on ? .muteAllOn : .muteAllOff)
        run("Couldn't mute everyone") { try $0.setMuteAll(on: on) }
    }

    func setOperator(_ user: User, _ on: Bool, password: String = "") {
        run("Couldn't change operators") { try $0.setOperator(userId: user.id, channelId: user.channelId, password: password, on: on) }
    }

    func setTransmit(channel: Int32, user: Int32, _ stream: TransmitStream, _ allowed: Bool) {
        run("Couldn't change who may send") {
            try $0.setTransmitAllowed(channelId: channel, userId: user, stream: stream, allowed: allowed)
        }
    }

    /// Bans from their channel, then kicks them from it.
    func banFromChannel(_ user: User, by kind: BanKind) {
        run("Couldn't ban") { c in
            try c.banFromChannel(userId: user.id, kind: kind)
            try c.kickUser(userId: user.id, fromChannel: true)
        }
    }

    func setGender(_ g: Gender) {
        run("Couldn't change the gender") { try $0.setGender(gender: g) }
    }

    func setNickname(_ n: String) {
        run("Couldn't change the nickname") { try $0.setNickname(nickname: n) }
    }

    func setRelay(_ user: User?, _ stream: AudioStream = .voice) {
        let relay = user.map { Relay(userId: $0.id, stream: stream) }
        run("Couldn't relay") { try $0.setRelay(relay: relay) }
    }

    func statistics(_ user: User) async -> UserStatistics? {
        let client = self.client, id = user.id
        return await Task.detached { try? client.userStatistics(userId: id) }.value
    }

    func channelBans(_ channel: Int32) async -> [Ban]? {
        let client = self.client
        let r: Result<[Ban], Error> = await Task.detached { Result { try client.listChannelBans(channelId: channel) } }.value
        switch r {
        case .success(let b): return b
        case .failure(let e): announce("Couldn't list the bans: \(words(e))"); return nil
        }
    }

    // MARK: Channels: by path, and streaming files

    /// A tt:// link to this server and a channel (the desktop's
    /// "Generate tt:// URL"); with the account only when asked.
    func link(to channel: Channel?, withAccount: Bool, channelPassword: String) -> String {
        var e = server.entry(password: withAccount ? Passwords.get(server.id) : "")
        if !withAccount { e.username = "" }
        e.channel = channel.map { $0.parentId == 0 ? "/" : client.channelPath(channelId: $0.id) } ?? ""
        e.channelPassword = channelPassword
        return ttLink(entry: e)
    }

    func joinByPath(_ path: String, password: String) {
        var p = path.trimmingCharacters(in: .whitespaces)
        if !p.hasPrefix("/") { p = "/" + p }
        if !p.hasSuffix("/") { p += "/" }
        let path = p
        run("Couldn't join") { try $0.joinHiddenChannel(path: path, password: password) }
    }

    /// Streams a picked file (copied first: the picker's URL is short-lived).
    func streamFile(_ url: URL) {
        let reading = url.startAccessingSecurityScopedResource()
        defer { if reading { url.stopAccessingSecurityScopedResource() } }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("streams", isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let copy = dir.appendingPathComponent(url.lastPathComponent)
        do { try FileManager.default.copyItem(at: url, to: copy) } catch {
            announce("Couldn't read that file: \(error.localizedDescription)")
            return
        }
        let path = copy.path
        guard mediaFileInfo(path: path) != nil else {
            announce("That file can't be played.")
            return
        }
        run("Couldn't stream") { try $0.streamMediaFile(path: path, offsetMs: 0, paused: false, looping: false) }
    }

    func pauseStream(_ paused: Bool) {
        run("Couldn't change the stream") { try $0.updateStream(offsetMs: nil, paused: paused) }
        announce(paused ? "Paused" : "Playing")
    }

    func seekStream(by ms: Int64) {
        guard let st = snapshot?.streaming else { return }
        let to = UInt32(max(0, min(Int64(st.durationMs), Int64(st.elapsedMs) + ms)))
        let paused = st.status == .paused
        run("Couldn't move the stream") { try $0.updateStream(offsetMs: to, paused: paused) }
    }

    func stopStream() {
        run("Couldn't stop the stream") { try $0.stopStream() }
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

    // MARK: Recording

    var recording: Bool { !(snapshot?.recordingPath.isEmpty ?? true) || coreClient.recordingEach() != nil }

    /// Records as Settings → Recording says: one file of the channel and/or
    /// a file for each person, in Recordings (the Files app).
    func startRecording() {
        guard let s = snapshot, s.myChannelId > 0, let app else { return }
        let mp3 = app.recordMP3
        let channel = s.channels.first { $0.id == s.myChannelId }
        let place = channel.map { $0.parentId == 0 ? "Root" : $0.name } ?? "Channel"
        let stamp = Date.now.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false).timeSeparator(.omitted))
        let base = "\(server.title) \(place) \(stamp)".replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Recordings")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("\(base).\(mp3 ? "mp3" : "wav")").path
        let each = dir.appendingPathComponent(base, isDirectory: true)
        let (one, eachOn, media) = (app.recordOneFile, app.recordEachPerson, app.recordMediaFiles)
        if eachOn { try? FileManager.default.createDirectory(at: each, withIntermediateDirectories: true) }
        let eachPath = each.path
        run("Couldn't record") { c in
            if one { try c.startRecordingWith(path: path, format: mp3 ? .mp3 : .wave, includeMedia: media) }
            if eachOn {
                try c.setRecordEach(folder: eachPath, format: mp3 ? .mp3 : .wave)
            }
        }
        if eachOn && !one { announce("Recording each person") }
    }

    func stopRecording() {
        let each = coreClient.recordingEach() != nil, one = !(snapshot?.recordingPath.isEmpty ?? true)
        run("Couldn't stop recording") { c in
            if one { try c.stopRecording() }
            if each { try c.setRecordEach(folder: nil, format: .wave) }
        }
        if each && !one { announce("Recordings saved, in the Files app") }
    }

    // MARK: Sound

    func applyHearOwnStream() {
        guard let on = app?.hearOwnStream, let video = app?.streamVideo else { return }
        run("Couldn't change that") { c in
            try c.setHearOwnStream(on: on)
            try c.setStreamVideo(on: video)
        }
    }

    func applyAudioSettings() {
        guard let a = app?.audio else { return }
        run("Couldn't change the sound") { try $0.setAudioSettings(settings: a) }
    }

    func clientStatistics() async -> ClientStatistics? {
        let c = client
        return await Task.detached { try? c.clientStatistics() }.value
    }

    /// Appends a chat line to today's log file (Settings → Recording).
    private func log(_ line: ChatLine) {
        guard app?.saveChatLogs == true else { return }
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Chat logs", isDirectory: true)
            .appendingPathComponent(server.title.replacingOccurrences(of: "/", with: "-"), isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("\(line.time.formatted(.iso8601.year().month().day())).txt")
        let who = line.privateWith.map { "\(line.from) (private, with \($0))" } ?? line.from
        let text = "[\(line.time.formatted(date: .omitted, time: .standard))] \(who): \(line.text)\n"
        if let h = try? FileHandle(forWritingTo: file) {
            h.seekToEndOfFile()
            h.write(Data(text.utf8))
            try? h.close()
        } else {
            try? Data(text.utf8).write(to: file)
        }
    }

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

    func saveServerConfig() {
        run("Couldn't save the configuration") { try $0.saveServerConfig() }
        announce("Server configuration saved")
    }

    func banAddress(_ address: String, channelPath: String = "") {
        let a = address.trimmingCharacters(in: .whitespaces)
        guard !a.isEmpty else { return }
        run("Couldn't ban it") { try $0.banAddress(address: a, channelPath: channelPath) }
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
            say(.talking, ["state": transmitting ? "Talking" : "Stopped talking"])
        } else {
            setMicMuted(!muted)
            say(.talking, ["state": muted ? "Microphone muted" : "Microphone on"])
        }
    }

    /// Sets the core to the app's talk mode.
    func applyTalkMode() {
        guard isConnected, let app else { return }
        let mode = app.talkMode, level = Int32(app.voiceLevel), muted = self.muted, pausedForAway = awayPausedVoice
        if mode != .pushToTalk { transmitting = false }
        let ptt = transmitting
        run("Couldn't set up talking") { c in
            switch mode {
            case .pushToTalk:
                try c.setVoiceActivation(on: false, level: level, stopDelayMs: 500)
                try c.setTransmitting(on: ptt)
            case .voiceActivation:
                try c.setTransmitting(on: false)
                try c.setVoiceActivation(on: !muted && !pausedForAway, level: level, stopDelayMs: 500)
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
            // Channels new to me: collapsed, or expanded with the setting.
            for c in snapshot?.channels ?? [] where seenChannels.insert(c.id).inserted {
                if app?.autoExpandChannels == true { expanded.insert(c.id) }
            }
            known = Dictionary(snapshot?.users.map { ($0.id, $0) } ?? [], uniquingKeysWith: { a, _ in a })
            knownChannels = Dictionary(snapshot?.channels.map { ($0.id, $0) } ?? [], uniquingKeysWith: { a, _ in a })
        }
    }

    private var myChannel: Int32 { snapshot?.myChannelId ?? 0 }
    private func sound(_ e: SoundEvent) { app?.sounds.play(e) }

    /// Says an event, the desktop's way (its message, if it's on).
    private func say(_ e: SpeechEvent, _ vars: [String: String] = [:]) {
        var v = vars
        v["server"] = v["server"] ?? (snapshot?.server.name.nonEmpty ?? server.title)
        app?.speech.say(e, v)
    }

    /// Says something about what I did (results, not events).
    private func note(_ text: String) { app?.speech.speak(text) }

    private func vars(_ u: User) -> [String: String] {
        ["user": u.displayName, "username": u.username]
    }

    /// The desktop's lines on joining a channel: where, its topic, its
    /// disk quota (with the templates on).
    private func joinedLines(_ c: Channel, path: String) {
        guard app?.chatTemplates.enabled == true else { return }
        let quota = c.diskQuota > 0 ? ByteCountFormatter.string(fromByteCount: c.diskQuota, countStyle: .file) : "0 bytes"
        let v = ["channelpath": path, "channelname": c.parentId == 0 ? "root" : c.name, "channeltopic": c.topic, "quota": quota]
        lines.append(ChatLine(from: "Channel", text: "Joined channel \(path)", privateWith: nil, time: .now, kind: .joinedChannel, vars: v))
        lines.append(ChatLine(from: "Channel", text: "Topic: \(c.topic)", privateWith: nil, time: .now, kind: .channelTopic, vars: v))
        lines.append(ChatLine(from: "Channel", text: "Disk quota: \(quota)", privateWith: nil, time: .now, kind: .diskQuota, vars: v))
    }

    /// My name on this server, as others see it.
    private var myName: String {
        snapshot.flatMap { s in s.users.first { $0.id == s.myUserId }?.displayName } ?? "Me"
    }

    /// An event line in the chat (Settings → Display).
    private func eventLine(_ text: String) {
        guard app?.eventsInChat == true else { return }
        lines.append(ChatLine(from: "Event", text: text, privateWith: nil, time: .now, kind: .logMessage, vars: ["content": text]))
    }

    private func channelName(_ id: Int32) -> String {
        guard let c = snapshot?.channels.first(where: { $0.id == id }) else { return "" }
        return c.parentId == 0 ? "root" : c.name
    }

    // MARK: Expanded channels (the desktop's rules)

    /// Channels showing their people and subchannels. As on the desktop:
    /// new ones collapsed (expanded with "Expand channels automatically"),
    /// the one I join expanded with every channel above it, the one I
    /// leave collapsed.
    private(set) var expanded: Set<Int32> = []
    /// The channels the tree has shown since it was last built (to know
    /// which are new). The desktop builds the tree again after a dropped
    /// connection, so this starts over then.
    private var seenChannels: Set<Int32> = []

    func isExpanded(_ c: Channel) -> Bool { expanded.contains(c.id) }

    func setExpanded(_ c: Channel, _ on: Bool) {
        if on { expanded.insert(c.id) } else { expanded.remove(c.id) }
    }

    private func expandWithParents(_ id: Int32) {
        var at: Int32? = id
        var seen = Set<Int32>()
        while let i = at, i != 0, seen.insert(i).inserted {
            expanded.insert(i)
            at = snapshot?.channels.first { $0.id == i }?.parentId
        }
    }

    /// Who I knew, and how, before this event (to say what changed).
    private var known: [Int32: User] = [:]
    private var knownChannels: [Int32: Channel] = [:]
    private var loggedInOnce = false

    fileprivate func handle(_ event: Event) {
        switch event {
        case .connectionChanged(let s):
            state = s
            switch s {
            case .loggedIn:
                if dropped {
                    dropped = false
                    say(.connection, ["state": "reconnected"])
                    applyTalkMode()
                }
                if app?.chatTemplates.enabled == true, let name = snapshot?.server.name.nonEmpty ?? server.title.nonEmpty {
                    lines.append(ChatLine(from: "Server", text: "Server name: \(name)", privateWith: nil, time: .now,
                                          kind: .serverName, vars: ["server": name]))
                }
                if !loggedInOnce || app?.showMOTD == true {
                    loggedInOnce = true
                    Task { @MainActor in self.showMOTD() }
                }
            case .reconnecting(let n):
                transmitting = false
                // As the desktop: the tree starts over (my channel opens
                // again when I'm back in it).
                expanded = []
                seenChannels = []
                if !dropped {
                    sound(.serverLost)
                    say(.connection, ["state": "connection lost, reconnecting"])
                }
                dropped = n > 0
            case .disconnected:
                transmitting = false
                voiceActive = false
                expanded = []
                seenChannels = []
            default: break
            }
        case .connectionFailed(let m):
            problem = m
            sound(.serverLost)
            say(.connection, ["state": m])
        case .messageReceived(let m):
            let sender = snapshot?.users.first { $0.id == m.fromUserId }
            let from = sender?.displayName ?? m.fromUsername
            var v = ["user": from, "username": m.fromUsername, "message": m.text]
            let mine = m.fromUserId == snapshot?.myUserId
            switch m.target {
            case .user:
                lines.append(ChatLine(from: from, text: m.text, privateWith: from, time: .now, kind: .privateMessage, vars: ["user": from, "content": m.text]))
                sound(.privateMessage)
                say(.privateMessage, v)
                notifyIfAway("Private message from \(from)", m.text)
            case .channel:
                lines.append(ChatLine(from: mine ? "Me" : from, text: m.text, privateWith: nil, time: .now, kind: .channelMessage, vars: ["user": from, "content": m.text]))
                if mine {
                    sound(.channelMessageSent)
                    say(.channelMessageSent, ["message": m.text])
                } else {
                    sound(.channelMessage)
                    say(.channelMessage, v)
                }
            case .broadcast:
                lines.append(ChatLine(from: "Broadcast from \(from)", text: m.text, privateWith: nil, time: .now, kind: .broadcastMessage, vars: ["user": from, "content": m.text]))
                if mine {
                    v = ["message": m.text]
                    say(.broadcastMessageSent, v)
                } else {
                    sound(.broadcastMessage)
                    say(.broadcastMessage, v)
                }
            }
        case .userJoined(let u, let ch):
            if u.id == snapshot?.myUserId, let c = snapshot?.channels.first(where: { $0.id == ch }) {
                // The desktop's "last joined channel", per server.
                let path = c.parentId == 0 ? "/" : client.channelPath(channelId: ch)
                UserDefaults.standard.set(path, forKey: "lastChannel-\(server.id)")
                joinedLines(c, path: path)
            }
            if u.id == snapshot?.myUserId { expandWithParents(ch) }
            guard u.id != snapshot?.myUserId else { break }
            if ch == myChannel {
                sound(.userJoined)
                say(.joinedMine, vars(u))
                eventLine("\(u.displayName) joined")
            } else if state == .loggedIn {
                var v = vars(u)
                v["channel"] = channelName(ch)
                say(.joined, v)
            }
        case .userLeft(let u, let ch):
            if u.id == snapshot?.myUserId { expanded.remove(ch) }
            guard u.id != snapshot?.myUserId else { break }
            if ch == myChannel {
                sound(.userLeft)
                say(.leftMine, vars(u))
                eventLine("\(u.displayName) left")
            } else if state == .loggedIn {
                var v = vars(u)
                v["channel"] = channelName(ch)
                say(.left, v)
            }
        case .userLoggedIn(let u):
            applyDefaultSubscriptions(u)
            // Not for those already there when I log in (the server lists them).
            if state == .loggedIn, u.id != snapshot?.myUserId {
                sound(.loggedIn)
                say(.loggedIn, vars(u))
                eventLine("\(u.displayName) logged in")
            }
        case .userLoggedOut(let u):
            if state == .loggedIn, u.id != snapshot?.myUserId {
                sound(.loggedOut)
                say(.loggedOut, vars(u))
                eventLine("\(u.displayName) logged out")
                departed.append((u, .now))
                if departed.count > 200 { departed.removeFirst() }
            }
        case .userUpdated(let u):
            if let before = known[u.id] { changed(before, u) }
        case .channelUpdated(let c):
            if let before = knownChannels[c.id] { channelChanged(before, c) }
        case .fileRemoved(let f):
            if f.channelId == myChannel {
                sound(.fileUpdate)
                say(.fileRemoved, ["file": f.name, "user": f.uploader, "username": f.uploader])
            }
        case .fileAdded(let f):
            if f.channelId == myChannel, f.uploader != me?.username {
                sound(.fileUpdate)
                let who = snapshot?.users.first { $0.username == f.uploader }?.displayName ?? f.uploader
                say(.fileAdded, ["filename": f.name, "user": who, "username": f.uploader,
                                 "filesize": ByteCountFormatter.string(fromByteCount: f.size, countStyle: .file)])
            }
        case .transferChanged(let t):
            switch t.status {
            case .active:
                if transfers[t.id] == nil {
                    note("\(t.inbound ? "Downloading" : "Uploading") \(t.remoteName)")
                }
                transfers[t.id] = t
            case .finished:
                transfers[t.id] = nil
                sound(.transferComplete)
                note("\(t.inbound ? "Downloaded" : "Uploaded") \(t.remoteName)")
                if !t.inbound { try? FileManager.default.removeItem(atPath: (t.localPath as NSString).deletingLastPathComponent) }
            case .failed:
                transfers[t.id] = nil
                announce("\(t.inbound ? "Download" : "Upload") of \(t.remoteName) failed")
            case .cancelled:
                transfers[t.id] = nil
                note("Cancelled \(t.remoteName)")
            }
        case .streamChanged(let st):
            let name = ((st.path as NSString).lastPathComponent as NSString).deletingPathExtension
            switch st.status {
            case .started: note("Streaming \(name)")
            case .finished: if !st.looping { note("\(name) finished") }
            case .failed: announce("Streaming \(name) failed")
            case .stopped: note("Stopped streaming")
            default: break
            }
        case .recordingChanged(let path, let active, let error):
            let name = (path as NSString).lastPathComponent
            if active {
                note("Recording")
            } else if let error {
                announce("The recording stopped: \(error). Saved as \(name)")
            } else {
                note("Recording saved as \(name), in the Files app")
            }
        case .typing(let userId, let on):
            if on {
                let first = !isTypingId(userId)
                typing[userId] = .now.addingTimeInterval(6)
                if first, let u = snapshot?.users.first(where: { $0.id == userId }) {
                    sound(.typing)
                    say(.typing, vars(u))
                }
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(6.5))
                    if (self.typing[userId] ?? .distantPast) <= .now { self.typing[userId] = nil }
                }
            } else {
                typing[userId] = nil
            }
        case .voiceActivated(let on):
            voiceActive = on
            sound(on ? .voiceActivationStarts : .voiceActivationStops)
        case .kicked(_, let ch):
            say(.connection, ["state": ch > 0 ? "you were kicked from the channel" : "you were kicked from the server"])
        default: break
        }
        refresh()
    }

    /// Someone changed: question mode, intercepting me, my subscriptions.
    private func changed(_ before: User, _ u: User) {
        if u.status == .question && before.status != .question && u.id != snapshot?.myUserId {
            sound(.questionMode)
            say(.questionMode, vars(u))
        }
        let intercepts: [Subscription] = [.interceptUserMessages, .interceptChannelMessages, .interceptVoice, .interceptVideo, .interceptDesktop, .interceptMediaFile]
        let was = Set(before.theirSubscriptions.on).intersection(intercepts), now = Set(u.theirSubscriptions.on).intersection(intercepts)
        if now.count > was.count { sound(.intercepted) } else if now.count < was.count { sound(.interceptEnded) }
        let mineBefore = Set(before.mySubscriptions.on), mineNow = Set(u.mySubscriptions.on)
        for sub in mineNow.symmetricDifference(mineBefore) {
            var v = vars(u)
            v["type"] = PersonView.label(sub)
            v["state"] = mineNow.contains(sub) ? "on" : "off"
            say(.subscriptionChange, v)
        }
        if u.sendingVideo && !before.sendingVideo { sound(.newVideo) }
        if u.sharingDesktop && !before.sharingDesktop { sound(.newDesktop) }
    }

    /// My channel changed: classroom permissions, my turn to talk.
    private func channelChanged(_ before: Channel, _ c: Channel) {
        guard c.id == myChannel, let me = snapshot?.myUserId else { return }
        if c.classroom {
            let allowed = { (ch: Channel, user: Int32, st: TransmitStream) in ch.transmit.contains { $0.userId == user && $0.allowed.contains(st) } }
            let people = Set(before.transmit.map(\.userId) + c.transmit.map(\.userId))
            for user in people {
                for st in PersonView.streams where allowed(before, user, st) != allowed(c, user, st) {
                    let name = user == 0 ? "everyone" : (snapshot?.users.first { $0.id == user }?.displayName ?? "someone")
                    say(.classroomChange, ["type": PersonView.streamLabel(st), "state": allowed(c, user, st) ? "allowed" : "not allowed", "user": name, "username": name])
                }
            }
        }
        let wasFirst = before.transmitQueue.first == me, isFirst = c.transmitQueue.first == me
        if isFirst && !wasFirst { sound(.yourTurn) }
        if wasFirst && !c.transmitQueue.contains(me) { sound(.turnOver) }
    }

    /// The server's message of the day, as a line in the chat (Settings → Display).
    private func showMOTD() {
        guard app?.showMOTD == true, let motd = snapshot?.server.motd.trimmingCharacters(in: .whitespacesAndNewlines), !motd.isEmpty else { return }
        if lines.last?.text == motd { return }
        lines.append(ChatLine(from: "Message of the day", text: motd, privateWith: nil, time: .now, kind: .motd, vars: ["MOTD": motd]))
    }

    /// The default subscriptions (Settings → Connection), for someone new.
    private func applyDefaultSubscriptions(_ u: User) {
        guard let off = app?.defaultSubscriptionsOff, !off.isEmpty, u.id != snapshot?.myUserId else { return }
        for sub in off where u.mySubscriptions.on.contains(sub) {
            run("Couldn't change that") { try $0.setSubscription(userId: u.id, what: sub, on: false) }
        }
    }

    /// A notification for a private message while the app isn't in front
    /// (the desktop's popup).
    private func notifyIfAway(_ title: String, _ body: String) {
        guard app?.notifyInBackground == true, UIApplication.shared.applicationState != .active else { return }
        let c = UNMutableNotificationContent()
        c.title = title
        c.subtitle = server.title
        c.body = body
        c.sound = nil
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
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
