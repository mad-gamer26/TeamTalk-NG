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
    /// For the desktop's menus (DesktopMenus.swift).
    var appModel: AppModel? { app }
    private let bridge = EventBridge()
    private let client: TtClient
    /// For screens that call the core themselves (off the main thread).
    var coreClient: TtClient { client }
    /// People picked to move together (the desktop's "store for move").
    private(set) var pickedToMove: Set<Int32> = []

    func togglePicked(_ u: User) {
        if pickedToMove.contains(u.id) { pickedToMove.remove(u.id) } else { pickedToMove.insert(u.id) }
        // The desktop's "Store User(s) for Move", in plainer words.
        note(pickedToMove.contains(u.id) ? "\(u.displayName) picked for moving" : "\(u.displayName) no longer picked for moving")
    }

    /// Moves everyone picked into a channel.
    func movePicked(to c: Channel) {
        let ids = pickedToMove
        pickedToMove = []
        run("Couldn't move everyone") { cl in
            for id in ids { try cl.moveUser(userId: id, channelId: c.id) }
        }
        note("Moved to \(c.parentId == 0 ? "the root channel" : c.name)")
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
            LiveActivities.shared.changed(self)
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
    private(set) var transmitting = false { didSet { LiveActivities.shared.changed(self) } }
    /// Voice activation: microphone muted.
    private(set) var muted = false { didSet { LiveActivities.shared.changed(self) } }
    /// Voice activation is sending my voice now.
    private(set) var voiceActive = false

    init(server: SavedServer, app: AppModel) {
        self.server = server
        self.app = app
        client = TtClient(listener: bridge)
        lines = History.load(for: server.id)
        bridge.connection = self
    }

    // MARK: Monitor mode
    //
    // A server the Monitor is logged in to, shown and behaving as if this
    // app were: the same screen, channel tree, chat, sounds and spoken and
    // status-bar events, from the Monitor's view and events; what the
    // Monitor can do (messages, join, leave, move, kick, ban, nickname,
    // status) goes through it.

    /// The Monitor's server ID, in monitor mode.
    private(set) var monitorId: Int64?
    var isMonitor: Bool { monitorId != nil }
    /// Audio can be controlled here: not through the Monitor, a text-only
    /// client (the owner's rule: no audio controls at all when exploring a
    /// server through it).
    var hasAudio: Bool { monitorId == nil }
    /// What's about audio among subscriptions and what may be sent.
    static let audioSubscriptions: Set<Subscription> = [.voice, .mediaFile, .interceptVoice, .interceptMediaFile]
    static let audioStreams: Set<TransmitStream> = [.voice, .mediaFile]
    func shows(_ s: Subscription) -> Bool { hasAudio || !Self.audioSubscriptions.contains(s) }
    func shows(_ s: TransmitStream) -> Bool { hasAudio || !Self.audioStreams.contains(s) }
    fileprivate var monitorSnapshot: Snapshot?
    fileprivate var monitorTask: Task<Void, Never>?

    /// The Monitor's connection to `id`, as a server screen.
    convenience init(monitorServer m: MonitorServer, app: AppModel) {
        var saved = SavedServer()
        saved.name = m.name
        saved.host = m.host
        saved.tcpPort = m.tcpPort
        saved.udpPort = m.tcpPort
        saved.username = m.username
        saved.nickname = m.nickname
        self.init(server: saved, app: app)
        monitorId = m.id
    }

    var isConnected: Bool { state == .loggedIn }

    var stateText: String {
        switch state {
        case .disconnected: problem.map { "Not connected: \($0)" } ?? "Not connected"
        case .connecting: "Connecting"
        case .loggingIn: "Logging in"
        case .loggedIn: "Connected"
        case .reconnecting(let n):
            loggedInOnce ? "Connection lost, reconnecting (attempt \(n))" : "\(problem ?? "Couldn't connect"). Trying again (attempt \(n))"
        }
    }

    // MARK: Connecting

    func connect() {
        if monitorId != nil { startMonitor(); return }
        guard !busy, state == .disconnected else { return }
        busy = true
        problem = nil
        let s = server
        // The desktop's: the server's nickname, else mine, else "NoName".
        let nickname = s.nickname.isEmpty ? (app?.nickname.nonEmpty ?? "NoName") : s.nickname
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
        let audio = effectiveAudio
        let streamVideo = app?.streamVideo ?? true
        Task {
            let allowed = await AudioSession.requestMicrophone()
            AudioSession.activate()
            audioDevices = allowed ? .shared : .virtual
            let result: String? = await Task.detached {
                do {
                    try client.connect(options: options)
                    // Every connection shares the microphone and speaker.
                    try? client.setAudioSettings(settings: audio)
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
                // With Reconnect on, the core tries again (as the desktop):
                // the setup below happens when a retry logs in.
                firstLoginPending = true
            } else {
                afterFirstLogin()
            }
        }
    }

    /// A first connection that failed, being tried again (its setup waits).
    @ObservationIgnored private var firstLoginPending = false

    /// What follows logging in: talking as set, the root channel, my
    /// status and gender.
    private func afterFirstLogin() {
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

    func disconnect() {
        if monitorId != nil { stopMonitor(); return }
        let client = self.client
        transmitting = false
        app?.monitor.appConnected(server, false)
        Task.detached { try? client.disconnect() }
    }

    // MARK: Channels and messages

    func join(_ channel: Channel, password: String = "") {
        if monitorId != nil {
            let path = monitorChannelPath(channel.id)
            monitorAct(.join(channelPath: path, password: password)); return
        }
        let path = channel.parentId == 0 ? "/" : client.channelPath(channelId: channel.id)
        // Remembered for AudioNet streams' logins, which follow me there.
        if !password.isEmpty { channelPasswords[channel.id] = password }
        run("Couldn't join", onFail: { [weak self] why in
            self?.status(nil, "Cannot join channel \(path)")
            // The desktop asks again: "Incorrect channel password. Try again."
            if why == "Incorrect channel password. Try again." { self?.retryChannelPassword = channel }
        }) {
            try $0.joinChannel(channelId: channel.id, password: password)
        }
    }

    // MARK: For AudioNet streams' own logins

    /// Channel passwords that were given (the server's own one too).
    @ObservationIgnored private var channelPasswords: [Int32: String] = [:]

    func knownPassword(_ channelId: Int32) -> String {
        if let p = channelPasswords[channelId] { return p }
        let path = channelId > 0 ? client.channelPath(channelId: channelId) : ""
        return !path.isEmpty && path == server.joinChannel ? server.channelPassword : ""
    }

    /// My channel's path ("/" for the root), or empty.
    var myChannelPath: String {
        guard let s = snapshot, s.myChannelId > 0 else { return "" }
        return s.channels.first { $0.id == s.myChannelId }?.parentId == 0 ? "/" : client.channelPath(channelId: s.myChannelId)
    }

    /// My name as others see it.
    var nameForOthers: String { me?.displayName ?? app?.nickname.nonEmpty ?? server.username }

    /// A second login to this server, as me (an AudioNet stream's).
    func companionOptions(nickname: String, channelPath: String, channelPassword: String) -> ConnectOptions {
        let s = server
        return ConnectOptions(
            host: s.host, tcpPort: s.tcpPort, udpPort: s.udpPort, encrypted: s.encrypted,
            nickname: nickname, username: s.username,
            password: Passwords.get(s.id), clientName: "TeamTalk NG AudioNet",
            joinChannelPath: channelPath, joinChannelPassword: channelPassword, reconnect: true,
            caPem: s.encrypted ? s.caPem : "", certPem: s.encrypted ? s.certPem : "", keyPem: s.encrypted ? s.keyPem : "",
            verifyPeer: s.encrypted && s.verifyPeer,
            webLoginUsername: s.bearwareLogin ? BearWare.username : "", webLoginToken: s.bearwareLogin ? BearWare.token : "")
    }

    func leaveChannel() {
        if monitorId != nil { monitorAct(.leave); return }
        run("Couldn't leave") { try $0.leaveChannel() }
    }

    /// To my channel, or privately to someone.
    func send(_ text: String, to user: User? = nil) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let snap = snapshot else { return }
        if monitorId != nil { monitorSend(text, to: user); return }
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
            checkBlocked(.channelMessages)
        }
        run("Couldn't send") { try $0.sendMessage(target: target, text: text) }
    }

    func setStatus(_ mode: StatusMode, _ message: String) {
        autoAway = nil
        if monitorId != nil {
            let bits: Int64 = mode == .away ? 1 : mode == .question ? 2 : 0
            monitorAct(.status(mode: bits, message: message)); return
        }
        run("Couldn't change the status") { try $0.setStatus(mode: mode, message: message) }
    }

    /// My status message before it showed a streamed file's name.
    private var statusBeforeStream: String?

    private func restoreStatusAfterStream() {
        guard let msg = statusBeforeStream, let me else { return }
        statusBeforeStream = nil
        run("Couldn't change the status") { try $0.setStatus(mode: me.status, message: msg) }
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

    /// The desktop's Transmit Control: channel operators and those who may
    /// modify channels, in any channel.
    func canControlTransmit(channel id: Int32) -> Bool {
        // Not through the Monitor (it can't change channels).
        monitorId == nil && (canModerate(channel: id) || rights.modifyChannels)
    }

    /// Whether someone (0: everyone, classroom only) may send a kind of
    /// stream: a classroom channel lists who may, any other who may not.
    func transmitAllowed(_ c: Channel, user: Int32, _ s: TransmitStream) -> Bool {
        let listed = c.transmit.contains { $0.userId == user && $0.allowed.contains(s) }
        return c.classroom ? listed : !listed
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
        mute(user) { try $0.setUserMediaMuted(userId: user.id, muted: muted) }
    }

    /// Muting someone for me, shown at once (so the menu says Unmute next).
    private func mute(_ user: User, _ call: @escaping @Sendable (TtClient) throws -> Void) {
        let client = self.client
        Task {
            let failed: String? = await Task.detached {
                do { try call(client); return nil } catch { return words(error) }
            }.value
            if let failed { announce("Couldn't mute: \(failed)") }
            refresh()
        }
    }

    func setStereo(_ user: User, _ stream: AudioStream, left: Bool, right: Bool) {
        run("Couldn't change that") { try $0.setUserStereo(userId: user.id, stream: stream, left: left, right: right) }
    }

    func setMuteAll(_ on: Bool) {
        sound(on ? .muteAllOn : .muteAllOff)
        let client = self.client
        Task {
            // The core sends no event for it: the view refreshes here, so
            // the next press does the opposite straight away.
            let failed: String? = await Task.detached {
                do { try client.setMuteAll(on: on); return nil } catch { return words(error) }
            }.value
            if let failed { announce("Couldn't mute everyone: \(failed)") }
            refresh()
        }
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
        let client = self.client
        Task {
            let failed: String? = await Task.detached {
                do { try client.setRelay(relay: relay); return nil } catch { return words(error) }
            }.value
            if let failed { announce("Couldn't relay: \(failed)") }
            // The core sends no event for it: shown at once (the menus and
            // the person's details say the opposite next).
            refresh()
        }
    }

    func statistics(_ user: User) async -> UserStatistics? {
        let client = self.client, id = user.id
        return await Task.detached { try? client.userStatistics(userId: id) }.value
    }

    func channelBans(_ channel: Int32) async -> [Ban]? {
        if let id = monitorId {
            return await monitorAdmin("Couldn't list the bans") { try $0.adminChannelBans(serverId: id, channelId: channel) }
        }
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
        guard let info = mediaFileInfo(path: path) else {
            announce("That file can't be played.")
            return
        }
        // The desktop's Stream Media File dialog comes first.
        streamPlan = StreamPlan(path: path, info: info)
    }

    /// A file picked to stream, waiting for the Stream Media File dialog.
    struct StreamPlan: Identifiable {
        let path: String
        let info: MediaFileInfo
        var id: String { path }
    }

    /// The desktop's canTx (utiltt.cpp): in a classroom channel only those
    /// listed (or everyone, when listed) may send; in other channels the
    /// list blocks.
    func canTransmit(_ s: TransmitStream) -> Bool {
        guard let snap = snapshot, let c = snap.channels.first(where: { $0.id == snap.myChannelId }) else { return true }
        let listed = { (id: Int32) in c.transmit.contains { $0.userId == id && $0.allowed.contains(s) } }
        return c.classroom ? (listed(snap.myUserId) || listed(0)) : !listed(snap.myUserId)
    }

    /// The desktop's "… blocked by channel operator" status message.
    private func checkBlocked(_ s: TransmitStream) {
        guard !canTransmit(s) else { return }
        let what: String = switch s {
        case .channelMessages: "Text messages"
        case .voice: "Voice transmission"
        case .mediaFile: "Media file transmission"
        case .video: "Video transmission"
        case .desktop: "Desktop transmission"
        }
        status(.transmissionBlocked, "\(what) blocked by channel operator")
    }

    func startStream(_ plan: StreamPlan, offsetMs: UInt32, looping: Bool, preprocessor: StreamPreprocessor = .none) {
        checkBlocked(.mediaFile)
        run("Couldn't stream") {
            try $0.streamMediaFileWith(path: plan.path, offsetMs: offsetMs, paused: false, looping: looping, preprocessor: preprocessor)
        }
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
        mute(user) { try $0.setUserMuted(userId: user.id, muted: muted) }
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

    func applyStreamVideo() {
        guard let video = app?.streamVideo else { return }
        run("Couldn't change that") { try $0.setStreamVideo(on: video) }
    }

    /// The Settings volumes, with this server's own where it has them
    /// (the desktop's separate instances, each with its own volumes).
    var effectiveAudio: AudioSettings {
        var a = app?.audio ?? defaultAudioSettings()
        if let v = server.outputVolume { a.outputVolume = Int32(v) }
        if let v = server.micGain { a.micGain = Int32(v) }
        if let v = server.mediaVolume { a.mediaVolume = Int32(v) }
        return a
    }

    /// The sound devices this connection opened (nil: none yet).
    @ObservationIgnored private(set) var audioDevices: AudioDevices?

    /// Closes the sound devices (echo cancellation turned on or off: every
    /// connection closes before any opens again, see AppModel).
    func closeAudio() async {
        guard monitorId == nil, audioDevices != nil else { return }
        let c = client
        _ = await Task.detached { try? c.closeAudio() }.value
    }

    /// Opens them again with the settings as they are now.
    func reopenAudio() async {
        guard monitorId == nil, let d = audioDevices else { return }
        let c = client, a = effectiveAudio
        let failed: String? = await Task.detached {
            do { try c.setAudioSettings(settings: a); try c.initAudio(devices: d); return nil } catch { return words(error) }
        }.value
        if let failed { announce("Couldn't open the sound devices: \(failed)") }
        applyTalkMode()
    }

    func applyAudioSettings() {
        guard monitorId == nil else { return }
        let a = effectiveAudio
        run("Couldn't change the sound") { try $0.setAudioSettings(settings: a) }
    }

    func clientStatistics() async -> ClientStatistics? {
        let c = client
        return await Task.detached { try? c.clientStatistics() }.value
    }

    /// Writes a chat line to its log, as the desktop's (Record
    /// Conversations: "Folder for channel log files" with "<channel>.clog",
    /// the server's name for the root channel; "Folder for user-to-user log
    /// files" with "<name>.ulog"), in the Files app under Chat logs.
    private func log(_ line: ChatLine) {
        guard app?.saveChatLogs == true else { return }
        let safe = { (s: String) in s.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-") }
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Chat logs", isDirectory: true)
            .appendingPathComponent(safe(server.title), isDirectory: true)
        let file: URL
        if let with = line.privateWith {
            file = base.appendingPathComponent("User logs", isDirectory: true).appendingPathComponent("\(safe(with)).ulog")
        } else {
            let snap = snapshot
            let ch = snap?.channels.first { $0.id == snap?.myChannelId }
            let name = ch.map { $0.parentId == 0 ? (snap?.server.name.nonEmpty ?? server.title) : $0.name } ?? server.title
            file = base.appendingPathComponent("Channel logs", isDirectory: true).appendingPathComponent("\(safe(name)).clog")
        }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        // The line as the chat shows it with the desktop's templates.
        let stamp = app?.timestamp(line.time) ?? ""
        let text: String
        if let kind = line.kind, let t = app?.chatTemplates {
            text = t.format(kind, line.vars ?? [:], date: stamp) + "\n"
        } else {
            text = "\(stamp) <\(line.from)>\n\(line.text)\n"
        }
        if let h = try? FileHandle(forWritingTo: file) {
            h.seekToEndOfFile()
            h.write(Data(text.utf8))
            try? h.close()
        } else {
            try? Data(text.utf8).write(to: file)
        }
    }

    // MARK: Administration

    var rights: MyRights { snapshot?.myRights ?? MyRights(admin: false, createTemporaryChannels: false, modifyChannels: false, broadcast: false, kick: false, ban: false, moveUsers: false, uploadFiles: false, downloadFiles: false, updateServer: false, multiLogin: false) }

    func kick(_ user: User, fromChannel: Bool) {
        if monitorId != nil { monitorAct(.kick(userId: Int64(user.id), channelId: fromChannel ? Int64(user.channelId) : nil)); return }
        run("Couldn't kick") { try $0.kickUser(userId: user.id, fromChannel: fromChannel) }
    }

    /// Bans, then kicks them off the server.
    func ban(_ user: User, by kind: BanKind) {
        if monitorId != nil { monitorAct(.ban(userId: Int64(user.id))); return }
        run("Couldn't ban") { c in
            try c.banUser(userId: user.id, kind: kind)
            try c.kickUser(userId: user.id, fromChannel: false)
        }
    }

    func move(_ user: User, to channel: Channel) {
        if monitorId != nil { monitorAct(.move(userId: Int64(user.id), channelId: Int64(channel.id))); return }
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
        if let id = monitorId {
            Task {
                if await monitorAdmin("Couldn't save the configuration", { try $0.adminSaveConfig(serverId: id) }) != nil {
                    note("Server configuration saved")
                    status(.serverConfigSaved, "Server configuration saved")
                }
            }
            return
        }
        run("Couldn't save the configuration") { try $0.saveServerConfig() }
        note("Server configuration saved")
        status(.serverConfigSaved, "Server configuration saved")
    }

    /// The desktop's "Ban Username" (by hand, in Banned Users).
    func banUsername(_ username: String, channelPath: String = "") {
        let u = username.trimmingCharacters(in: .whitespaces)
        guard !u.isEmpty else { return }
        if let id = monitorId {
            Task { _ = await monitorAdmin("Couldn't ban it") { try $0.adminBan(serverId: id, address: "", username: u, channelPath: channelPath) } }
            return
        }
        run("Couldn't ban it") { try $0.banUsername(username: u, channelPath: channelPath) }
    }

    func banAddress(_ address: String, channelPath: String = "") {
        let a = address.trimmingCharacters(in: .whitespaces)
        guard !a.isEmpty else { return }
        if let id = monitorId {
            Task { _ = await monitorAdmin("Couldn't ban it") { try $0.adminBan(serverId: id, address: a, username: "", channelPath: channelPath) } }
            return
        }
        run("Couldn't ban it") { try $0.banAddress(address: a, channelPath: channelPath) }
    }

    func broadcast(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if let id = monitorId {
            Task { _ = await monitorAdmin("Couldn't broadcast") { try $0.sendMessage(serverId: id, to: .broadcast, text: text) } }
            return
        }
        run("Couldn't broadcast") { try $0.sendMessage(target: .broadcast, text: text) }
    }

    /// The server's bans (nil and announced when they can't be listed).
    func bans() async -> [Ban]? {
        if let id = monitorId {
            return await monitorAdmin("Couldn't list the bans") { try $0.adminBans(serverId: id) }
        }
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
        if let id = monitorId {
            return await monitorAdmin("Couldn't remove the ban") { try $0.adminUnban(serverId: id, ban: ban) } != nil
        }
        let client = self.client
        let failed: String? = await Task.detached {
            do { try client.unban(ban: ban); return nil } catch { return words(error) }
        }.value
        if let failed { announce("Couldn't remove the ban: \(failed)") }
        return failed == nil
    }

    /// Runs a core call off the main thread; failures are announced.
    private func run(_ what: String, onFail: ((String) -> Void)? = nil, _ call: @escaping @Sendable (TtClient) throws -> Void) {
        // The Monitor can't do this (only what it routes above).
        if monitorId != nil { announce("\(what): the Monitor can't do that."); return }
        let client = self.client
        Task {
            let failed: String? = await Task.detached {
                do { try call(client); return nil } catch { return words(error) }
            }.value
            if let failed {
                problem = failed
                onFail?(failed)
                announce("\(what): \(failed)")
            }
        }
    }

    // MARK: Talking

    /// Push to talk on or off (the talk button and Magic Tap).
    func setTransmitting(_ on: Bool) {
        guard isConnected, app?.talkMode == .pushToTalk, on != transmitting else { return }
        transmitting = on
        // Microphone on and off (the owner's choice: vox_me_*).
        sound(on ? .voiceActivationMeOn : .voiceActivationMeOff)
        if on { checkBlocked(.voice) }
        run("Couldn't talk") { try $0.setTransmitting(on: on) }
    }

    func setMicMuted(_ on: Bool) {
        muted = on
        sound(on ? .voiceActivationMeOff : .voiceActivationMeOn)
        applyTalkMode()
    }

    /// Magic Tap: talk or stop (push to talk), or mute and unmute.
    func toggleTalking() {
        guard isConnected, let mode = app?.talkMode else { return }
        if mode == .pushToTalk {
            setTransmitting(!transmitting)
            sayText(.voiceTransmission, transmitting ? "Talking" : "Stopped talking")
        } else {
            setMicMuted(!muted)
            sayText(.voiceTransmission, muted ? "Microphone muted" : "Microphone on")
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
            snapshot = monitorId == nil ? client.snapshot() : monitorSnapshot
            state = snapshot?.state ?? .disconnected
            // Live Activities and Control Center follow, and AudioNet
            // streams' logins follow me to my channel.
            LiveActivities.shared.changed(self)
            app?.audioNet.follow(self)
            // My channel changed: in view, its parents open (as the
            // desktop's join does; the channel I left was just collapsed,
            // and it may be one of them).
            if let mine = snapshot?.myChannelId, mine != shownMyChannel {
                shownMyChannel = mine
                if mine > 0 { expandWithParents(mine) }
            }
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

    /// Says the result of something I did (the desktop's "Menu actions").
    private func note(_ text: String) { app?.speech.say(.menuActions, ["message": text]) }
    func noteMenu(_ text: String) { note(text) }

    /// Says fixed words under a spoken event (the desktop's connectivity,
    /// transmission toggles, menu actions).
    private func sayText(_ e: SpeechEvent, _ text: String) { app?.speech.say(e, ["message": text]) }

    /// The desktop's names for subscriptions when I change mine (its
    /// SUBCHANGE "{type}"), and the spoken event of each.
    static func subscriptionType(_ s: Subscription) -> (name: String, event: SpeechEvent) {
        switch s {
        case .userMessages: ("Private messages", .subUserMessages)
        case .channelMessages: ("Channel messages", .subChannelMessages)
        case .broadcastMessages: ("Broadcast messages", .subBroadcastMessages)
        case .voice: ("Voice", .subVoice)
        case .video: ("Video", .subVideo)
        case .desktop: ("Shared screen", .subDesktop)
        case .desktopAccess: ("Control of my shared screen", .subDesktopInput)
        case .mediaFile: ("Media files", .subMediaFile)
        case .interceptUserMessages: ("Listen in on private messages", .subInterceptUserMessages)
        case .interceptChannelMessages: ("Listen in on channel messages", .subInterceptChannelMessages)
        case .interceptVoice: ("Listen in on voice", .subInterceptVoice)
        case .interceptVideo: ("Listen in on video", .subInterceptVideo)
        case .interceptDesktop: ("Listen in on shared screens", .subInterceptDesktop)
        case .interceptMediaFile: ("Listen in on media files", .subInterceptMediaFile)
        }
    }

    /// The desktop's menu names for subscriptions (said when someone else
    /// changes theirs to me).
    static func subscriptionMenuName(_ s: Subscription) -> String {
        switch s {
        case .userMessages: "Private Messages"
        case .channelMessages: "Channel Messages"
        case .broadcastMessages: "Broadcast Messages"
        case .voice: "Voice"
        case .video: "Video"
        case .desktop: "Shared Screen"
        case .desktopAccess: "Control of My Shared Screen"
        case .mediaFile: "Media Files"
        case .interceptUserMessages: "Listen In on Private Messages"
        case .interceptChannelMessages: "Listen In on Channel Messages"
        case .interceptVoice: "Listen In on Voice"
        case .interceptVideo: "Listen In on Video"
        case .interceptDesktop: "Listen In on Shared Screens"
        case .interceptMediaFile: "Listen In on Media Files"
        }
    }

    static func classroomEvent(_ s: TransmitStream) -> SpeechEvent {
        switch s {
        case .channelMessages: .classroomChat
        case .voice: .classroomVoice
        case .video: .classroomVideo
        case .desktop: .classroomDesktop
        case .mediaFile: .classroomMediaFile
        }
    }

    /// A channel whose password was wrong, to ask again (the desktop's
    /// "Join channel error").
    var retryChannelPassword: Channel?
    /// The login was refused for a wrong username or password (the
    /// desktop's "Login error" dialog).
    var loginRetry = false

    /// Tries again with a corrected username and password (saved, as the
    /// desktop's dialog does).
    func retryLogin(username: String, password: String) {
        loginRetry = false
        server.username = username
        appModel?.upsert(server, password: password)
        connect()
    }

    /// A file waiting for the Stream Media File dialog.
    var streamPlan: StreamPlan?

    /// A private conversation to open (the desktop's message popup).
    var popupConversation: User?
    /// Why I was excluded, for the desktop's dialog box.
    /// The desktop's dialog when I'm kicked (with "Tell me in a dialog
    /// when I'm kicked" on); from the server, the screen closes after it.
    var excluded: Excluded?
    struct Excluded { let title: String; let text: String; let leaves: Bool }
    /// Counts requests to close the server screen and go back to the list
    /// (after Disconnect, or after being kicked from the server).
    private(set) var leaveRequests = 0
    func leaveScreen() { leaveRequests += 1 }
    /// The server screen is showing (a kick's dialog only shows there; on
    /// the list, the kick is said and there's nothing to leave).
    var screenOpen = false

    /// Logins, joins and leaves are announced (the login has finished,
    /// set in event order: the refreshed snapshot runs ahead of the events).
    private var live = false

    /// Who talked last (the desktop's "Show last to talk").
    private(set) var lastTalker: Int32 = 0
    /// People whose private messages aren't read yet (the desktop's ✉).
    var unread: Set<Int32> = [] { didSet { LiveActivities.shared.changed(self) } }

    /// Web-login users' settings between their logins (the desktop's
    /// "Restore volume settings and subscriptions on login").
    var userCache: [String: CachedUser] = [:]

    /// The private conversation on screen (for "typing in focused window").
    var focusedConversation: Int32?

    private func vars(_ u: User) -> [String: String] {
        ["user": u.displayName, "username": u.username]
    }

    private func serverVars(_ u: User) -> [String: String] {
        var v = vars(u)
        v["server"] = snapshot?.server.name.nonEmpty ?? server.title
        return v
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

    /// The latest status-bar message (the desktop's status bar).
    private(set) var statusLine = ""

    /// A status-bar message: always (`event` nil, the desktop's BYPASS) or
    /// when its event is on; in the chat too with "Show status-bar events
    /// in the chat" (on by default, as the desktop).
    func status(_ event: StatusEvent?, _ text: String) {
        if let event, app?.statusEvents.isOn(event) == false { return }
        statusLine = text
        guard app?.eventsInChat == true else { return }
        lines.append(ChatLine(from: "Event", text: text, privateWith: nil, time: .now, kind: .logMessage, vars: ["content": text]))
    }

    /// A status-bar event with its message's variables.
    private func status(_ event: StatusEvent, vars: [String: String]) {
        guard let store = app?.statusEvents else { return }
        status(event, store.text(event, vars))
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
    /// My channel as the tree last showed it (to open the way to a new one).
    private var shownMyChannel: Int32 = 0

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
            // As the desktop: people already there when I log in aren't
            // announced, only those who come or go after (this event comes
            // after the server has listed everyone).
            live = s == .loggedIn
            switch s {
            case .loggedIn:
                if firstLoginPending {
                    firstLoginPending = false
                    afterFirstLogin()
                }
                if dropped {
                    dropped = false
                    applyTalkMode()
                }
                sayText(.connectivity, "Connected to \(snapshot?.server.name.nonEmpty ?? server.title)")
                status(nil, "Connected to \(snapshot?.server.name.nonEmpty ?? server.title)")
                if app?.chatTemplates.enabled == true, let name = snapshot?.server.name.nonEmpty ?? server.title.nonEmpty {
                    lines.append(ChatLine(from: "Server", text: "Server name: \(name)", privateWith: nil, time: .now,
                                          kind: .serverName, vars: ["server": name]))
                }
                if !loggedInOnce || app?.showMOTD == true {
                    loggedInOnce = true
                    Task { @MainActor in self.showMOTD() }
                }
            case .reconnecting(let n):
                for u in known.values { cacheUser(u) }
                transmitting = false
                // As the desktop: the tree starts over (my channel opens
                // again when I'm back in it).
                expanded = []
                seenChannels = []
                if !dropped {
                    sound(.serverLost)
                    sayText(.connectivity, "Connection lost to \(server.host) TCP port \(server.tcpPort) UDP port \(server.udpPort)")
                    status(nil, "Connection lost to \(server.host) TCP port \(server.tcpPort) UDP port \(server.udpPort)")
                }
                sayText(.connectivity, "Trying to reconnect to \(server.host) port \(server.tcpPort)")
                dropped = n > 0
            case .disconnected:
                for u in known.values { cacheUser(u) }
                if loggedInOnce {
                    sayText(.connectivity, "Disconnected from \(snapshot?.server.name.nonEmpty ?? server.title)")
                    status(nil, "Disconnected from \(snapshot?.server.name.nonEmpty ?? server.title)")
                }
                transmitting = false
                voiceActive = false
                expanded = []
                seenChannels = []
            default: break
            }
        case .connectionFailed(let m):
            problem = m
            // The desktop's "Login error" dialog, to correct and try again.
            if m == "Incorrect username or password. Try again." { loginRetry = true }
            sound(.serverLost)
            sayText(.connectivity, m)
            status(nil, m)
        case .messageReceived(let m):
            let sender = snapshot?.users.first { $0.id == m.fromUserId }
            let from = sender?.displayName ?? m.fromUsername
            var v = ["user": from, "username": m.fromUsername, "message": m.text]
            let mine = m.fromUserId == snapshot?.myUserId
            switch m.target {
            case .user:
                lines.append(ChatLine(from: from, text: m.text, privateWith: from, time: .now, kind: .privateMessage, vars: ["user": from, "content": m.text]))
                // The desktop marks who has written until their messages are read.
                if focusedConversation != m.fromUserId {
                    unread.insert(m.fromUserId)
                    // The desktop's "Popup dialog when receiving text message".
                    if app?.messagePopup == true, let sender { popupConversation = sender }
                }
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
            if ch == myChannel && live {
                sound(.userJoined)
                say(.joinedMine, vars(u))
                status(.joinedMine, vars: vars(u))
            } else if live {
                var v = vars(u)
                v["channel"] = channelName(ch)
                say(.joined, v)
                status(.joined, vars: v)
            }
        case .userLeft(let u, let ch):
            if u.id == snapshot?.myUserId {
                // The desktop: the one I left collapses, and the one I'm in
                // stays in view (its join shows it, opening its parents) —
                // leaving the root for a channel under it mustn't hide it.
                expanded.remove(ch)
            }
            guard u.id != snapshot?.myUserId else { break }
            if ch == myChannel && live {
                sound(.userLeft)
                say(.leftMine, vars(u))
                status(.leftMine, vars: vars(u))
            } else if live {
                var v = vars(u)
                v["channel"] = channelName(ch)
                say(.left, v)
                status(.left, vars: v)
            }
        case .userLoggedIn(let u):
            applyDefaultSubscriptions(u)
            restoreUser(u)
            // Not for those already there when I log in (the server lists them).
            if live, u.id != snapshot?.myUserId {
                sound(.loggedIn)
                say(.loggedIn, vars(u))
                status(.loggedIn, vars: serverVars(u))
            }
        case .userLoggedOut(let u):
            cacheUser(known[u.id] ?? u)
            if live, u.id != snapshot?.myUserId {
                sound(.loggedOut)
                say(.loggedOut, vars(u))
                status(.loggedOut, vars: serverVars(u))
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
                status(.fileRemoved, vars: ["file": f.name, "user": f.uploader, "username": f.uploader])
            }
        case .fileAdded(let f):
            if f.channelId == myChannel, f.uploader != me?.username {
                sound(.fileUpdate)
                let who = snapshot?.users.first { $0.username == f.uploader }?.displayName ?? f.uploader
                let fv = ["filename": f.name, "user": who, "username": f.uploader,
                          "filesize": ByteCountFormatter.string(fromByteCount: f.size, countStyle: .file)]
                say(.fileAdded, fv)
                status(.fileAdded, vars: fv)
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
                // The desktop's words.
                announce("Failed to \(t.inbound ? "download" : "upload") file \(t.remoteName)")
            case .cancelled:
                transfers[t.id] = nil
                note("Cancelled \(t.remoteName)")
            }
        case .streamChanged(let st):
            let name = ((st.path as NSString).lastPathComponent as NSString).deletingPathExtension
            switch st.status {
            case .started:
                note("Streaming \(name)"); status(nil, "Started streaming media file to channel")
                // The desktop's "Display file name in status message when streaming".
                if app?.streamingStatus == true, let me {
                    statusBeforeStream = me.statusMessage
                    run("Couldn't change the status") { try $0.setStatus(mode: me.status, message: (st.path as NSString).lastPathComponent) }
                }
            case .finished:
                if !st.looping {
                    note("\(name) finished"); status(nil, "Finished streaming media file to channel")
                    restoreStatusAfterStream()
                }
            case .failed:
                announce("Streaming \(name) failed"); status(nil, "Error streaming media file to channel")
                restoreStatusAfterStream()
            case .stopped:
                note("Stopped streaming"); status(nil, "Aborted streaming media file to channel")
                restoreStatusAfterStream()
            default: break
            }
        case .recordingChanged(let path, let active, let error):
            let name = (path as NSString).lastPathComponent
            if active {
                note("Recording")
                status(.recordingStarted, "Recording to file: \(name)")
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
                    say(focusedConversation == userId ? .typing : .typingAnywhere, vars(u))
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
        case .talkingChanged(let userId, let talking):
            // The desktop's last to talk: someone else who started talking.
            if talking && userId != snapshot?.myUserId { lastTalker = userId }
        case .kicked(let by, let ch):
            // The desktop's words.
            let who = (known[by] ?? snapshot?.users.first { $0.id == by }).map { "by \($0.displayName)" } ?? "by unknown user"
            let place = ch > 0 ? "channel" : "server"
            let text = "Kicked from \(place) \(who)"
            // From the server (a ban kicks too): the desktop's server lost sound.
            if ch == 0 { sound(.serverLost) }
            sayText(.connectivity, text)
            status(nil, text)
            if app?.excludedDialog == true && screenOpen {
                // The desktop's dialog; the server list once it's dismissed.
                excluded = Excluded(title: "Kicked from \(place)", text: "You have been kicked from \(place) \(who)", leaves: ch == 0)
            } else if ch == 0 {
                leaveScreen()
            }
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
        // Theirs to me, as the desktop: intercepts from anyone (with their
        // sound), the rest from people in my channel.
        let intercepts: [Subscription] = [.interceptUserMessages, .interceptChannelMessages, .interceptVoice, .interceptVideo, .interceptDesktop, .interceptMediaFile]
        let theirsBefore = Set(before.theirSubscriptions.on), theirsNow = Set(u.theirSubscriptions.on)
        if u.id != snapshot?.myUserId {
            for sub in theirsNow.symmetricDifference(theirsBefore) {
                let intercept = intercepts.contains(sub)
                guard intercept || (u.channelId == myChannel && myChannel > 0) else { continue }
                if intercept { sound(theirsNow.contains(sub) ? .intercepted : .interceptEnded) }
                let text = "\(u.displayName) changed subscription \"\(Self.subscriptionMenuName(sub))\" to: \(theirsNow.contains(sub) ? "On" : "Off")"
                sayText(Self.subscriptionType(sub).event, text)
                status(StatusEvent(Self.subscriptionType(sub).event), text)
            }
        }
        // Mine to them (I changed it): the desktop's message.
        let mineBefore = Set(before.mySubscriptions.on), mineNow = Set(u.mySubscriptions.on)
        for sub in mineNow.symmetricDifference(mineBefore) {
            var v = vars(u)
            let t = Self.subscriptionType(sub)
            v["type"] = t.name
            v["state"] = mineNow.contains(sub) ? "Enabled" : "Disabled"
            say(t.event, v)
            status(StatusEvent(t.event), vars: v)
        }
        if u.sendingVideo && !before.sendingVideo { sound(.newVideo); status(nil, "New video session from \(u.displayName)") }
        if u.sharingDesktop && !before.sharingDesktop { sound(.newDesktop); status(nil, "New desktop session from \(u.displayName)") }
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
                    let cv = ["type": PersonView.streamLabel(st), "state": allowed(c, user, st) ? "allowed" : "not allowed", "user": name, "username": name]
                    say(Self.classroomEvent(st), cv)
                    status(StatusEvent(Self.classroomEvent(st)), vars: cv)
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


// MARK: Monitor mode: the Monitor's view and events as a live connection

extension ServerConnection {
    private var monitorStore: MonitorStore? { app?.monitor }

    fileprivate func startMonitor() {
        guard monitorTask == nil, let id = monitorId else { return }
        state = .connecting
        monitorTask = Task { [weak self] in
            var seq: Int64?
            var first = true
            while !Task.isCancelled {
                guard let self, let store = self.monitorStore else { return }
                if first || seq == nil {
                    guard case .success(let v)? = await store.call({ try $0.view(serverId: id) }) else {
                        try? await Task.sleep(for: .seconds(3)); continue
                    }
                    seq = v.seq
                    self.applyMonitorView(v, announce: false)
                    if first {
                        first = false
                        // Already there: listed, not announced (as on login).
                        self.handle(.connectionChanged(state: .loggedIn))
                        // The root channel open, as a live connection's (it
                        // joins the root; the Monitor's login sits in none).
                        if let root = v.channels.first(where: { $0.parentId == 0 }) { self.expanded.insert(Int32(root.id)) }
                    }
                }
                let since = seq
                if case .success(let batch)? = await store.call({ try $0.events(since: since, serverId: id) }) {
                    if batch.gap { seq = nil; continue }
                    if !batch.events.isEmpty {
                        let before = self.monitorSnapshot
                        if case .success(let v)? = await store.call({ try $0.view(serverId: id) }) {
                            self.applyMonitorView(v, announce: true)
                        }
                        for e in batch.events where self.monitorTask != nil { self.monitorEvent(e, before: before) }
                    }
                    seq = batch.lastSeq
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    /// Leaves the server as a live connection disconnects: no longer
    /// followed, the server screen shows "Disconnected" with Connect (the
    /// Monitor itself keeps watching). `quietly`: the screen was closed.
    fileprivate func stopMonitor(quietly: Bool = false) {
        monitorTask?.cancel()
        monitorTask = nil
        if quietly {
            state = .disconnected
            live = false
        } else if state != .disconnected {
            handle(.connectionChanged(state: .disconnected))
        }
        monitorSnapshot = nil
        refresh()
    }

    /// The screen closed: stop following without announcing anything.
    func leaveMonitorView() {
        if monitorId != nil { stopMonitor(quietly: true) }
    }

    /// The Monitor's account's rights (TeamTalk's UserRight bits; an admin
    /// has them all). Only what the Monitor can do: no channels or files.
    static func rights(type: Int64, bits: Int64) -> MyRights {
        let admin = type & 2 != 0
        func has(_ b: Int64) -> Bool { admin || bits & b != 0 }
        return MyRights(admin: admin, createTemporaryChannels: false, modifyChannels: false, broadcast: has(0x10),
                        kick: has(0x20), ban: has(0x40), moveUsers: has(0x80), uploadFiles: false, downloadFiles: false,
                        updateServer: has(0x800), multiLogin: false)
    }

    /// The Monitor's view as the core's snapshot.
    private func applyMonitorView(_ v: MonitorView, announce: Bool) {
        // Disconnected meanwhile: a late answer doesn't bring it back.
        guard monitorTask != nil else { return }
        let users = v.users.map(Self.user(from:))
        let channels = v.channels.map(Self.channel(from:))
        let me = users.first { Int64($0.id) == v.myUserId }
        monitorSnapshot = Snapshot(
            state: .loggedIn,
            server: ServerInfo(name: v.serverName, motd: v.motd, version: "", maxUsers: 0),
            myUserId: Int32(v.myUserId), myChannelId: me?.channelId ?? 0,
            myRights: Self.rights(type: v.myUserType, bits: v.myUserRights),
            channels: channels, users: users, files: [], transfers: [], recordingPath: "",
            mutedAll: false, relaying: nil, streaming: nil)
        // As a live connection: events are handled against what was known,
        // then the snapshot refreshes (handle() refreshes after each).
        if !announce { refresh() }
    }

    /// One Monitor event, as the live connection's event.
    private func monitorEvent(_ e: MonitorEvent, before: Snapshot?) {
        let now = monitorSnapshot
        let find = { (s: Snapshot?) in s?.users.first { Int64($0.id) == e.userId } }
        guard let u = find(now) ?? find(before) else {
            switch e.kind {
            case "kicked": handle(.kicked(byUserId: Int32(e.userId), channelId: Int32(e.channelId)))
            case "connection": status(nil, e.text); sayText(.connectivity, e.text)
            default: break
            }
            return
        }
        switch e.kind {
        case "logged_in": handle(.userLoggedIn(user: u))
        case "logged_out": handle(.userLoggedOut(user: u))
        case "joined": handle(.userJoined(user: u, channelId: Int32(e.channelId)))
        case "left": handle(.userLeft(user: u, channelId: Int32(e.channelId)))
        case "user_updated": handle(.userUpdated(user: u))
        case "message":
            // The Monitor's own private messages are shown when sent.
            if e.outgoing && e.messageKind == "user" { return }
            let target: MessageTarget = switch e.messageKind {
            case "user": .user(userId: Int32(e.outgoing ? e.toUserId : Int64(snapshot?.myUserId ?? 0)))
            case "broadcast": .broadcast
            default: .channel(channelId: Int32(e.channelId))
            }
            let from = e.outgoing ? (snapshot?.myUserId ?? u.id) : u.id
            handle(.messageReceived(message: TextMessage(target: target, fromUserId: from, fromUsername: u.username,
                                                         text: e.body, receivedAt: UInt64(max(0, e.time)))))
        default: break
        }
    }


    /// A channel's path ("/" for the root), from the Monitor's view.
    func monitorChannelPath(_ id: Int32) -> String {
        guard let c = snapshot?.channels.first(where: { $0.id == id }) else { return "/" }
        if c.parentId == 0 { return "/" }
        var parts: [String] = []
        var at: Channel? = c
        while let x = at, x.parentId != 0 {
            parts.insert(x.name, at: 0)
            at = snapshot?.channels.first { $0.id == x.parentId }
        }
        return "/" + parts.joined(separator: "/") + "/"
    }

    /// A call on the Monitor for this server (nil: the Monitor couldn't be reached).
    func monitorCall<T: Sendable>(_ f: @escaping @Sendable (MonitorClient) throws -> T) async -> Result<T, Error>? {
        await monitorStore?.call(f)
    }

    /// Server administration through the Monitor; failures announced.
    private func monitorAdmin<T: Sendable>(_ what: String, _ f: @escaping @Sendable (MonitorClient) throws -> T) async -> T? {
        switch await monitorCall(f) {
        case .success(let v)?: return v
        case .failure(let e)?: announce("\(what): \(NGAccountStore.words(e))"); return nil
        case nil: announce("\(what): the Monitor can't be reached."); return nil
        }
    }

    private func monitorAct(_ a: MonitorAction) {
        guard let id = monitorId, let store = monitorStore else { return }
        Task {
            if case .failure(let e)? = await store.call({ try $0.act(serverId: id, action: a) }) {
                announce(NGAccountStore.words(e))
            }
        }
    }

    private func monitorSend(_ text: String, to user: User?) {
        guard let id = monitorId, let store = monitorStore else { return }
        if let user {
            lines.append(ChatLine(from: "Me", text: text, privateWith: user.displayName, time: .now, kind: .privateMessage, vars: ["user": myName, "content": text]))
            sound(.privateMessageSent)
            say(.privateMessageSent, ["message": text])
        }
        let to: MonitorTarget = user.map { .user(userId: Int64($0.id), conversationId: nil) } ?? .channel(channelId: nil)
        Task {
            if case .failure(let e)? = await store.call({ try $0.sendMessage(serverId: id, to: to, text: text) }) {
                announce("Couldn't send: \(NGAccountStore.words(e))")
            }
        }
    }

    // MARK: The Monitor's records as the core's

    static func user(from m: MonitorUser) -> User {
        let bits = m.statusMode
        let mode: StatusMode = switch bits & 0xff { case 1: .away; case 2: .question; default: .available }
        let gender: Gender = bits & 0x1000 != 0 ? .neutral : bits & 0x100 != 0 ? .female : .male
        return User(id: Int32(m.id), displayName: m.displayName, nickname: m.nickname, username: m.username,
                    channelId: Int32(m.channelId), status: mode, statusMessage: m.statusMsg, admin: m.admin,
                    clientName: m.clientName, ipAddress: "", talking: false, version: "", gender: gender,
                    sendingVideo: bits & 0x200 != 0, sharingDesktop: bits & 0x400 != 0,
                    streamingMedia: bits & 0x800 != 0, streamPaused: bits & 0x2000 != 0, playingMedia: false,
                    mySubscriptions: Subscriptions(on: []), theirSubscriptions: Subscriptions(on: []),
                    voiceMuted: false, mediaMuted: false, voiceVolume: 50, mediaVolume: 50,
                    voiceLeft: true, voiceRight: true, mediaLeft: true, mediaRight: true, operator: false)
    }

    static func channel(from m: MonitorChannel) -> Channel {
        Channel(id: Int32(m.id), parentId: Int32(m.parentId), name: m.name, topic: m.topic, hasPassword: m.passwordProtected,
                maxUsers: 0, permanent: true, soloTransmit: false, classroom: false, operatorReceiveOnly: false,
                noVoiceActivation: false, noRecording: false, hidden: false, transmit: [], transmitQueue: [],
                operatorPassword: "", diskQuota: 0,
                codec: AudioCodec(kind: .noAudio, sampleRate: 0, channels: 0, bitrate: 0, vbr: false, dtx: false, music: false,
                                  frameSizeMs: 0, transmitIntervalMs: 0, quality: 0),
                fixedVolume: false, fixedVolumeLevel: 0, voiceTimeoutMs: 0, mediaTimeoutMs: 0)
    }
}
