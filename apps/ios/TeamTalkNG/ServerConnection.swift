import Foundation
import Observation

/// A line in a server's conversation.
struct ChatLine: Identifiable, Hashable {
    let id = UUID()
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
    private(set) var lines: [ChatLine] = []
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
        run("Couldn't talk") { try $0.setTransmitting(on: on) }
    }

    func setMicMuted(_ on: Bool) {
        muted = on
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
                if !dropped { announce("\(server.title): connection lost, reconnecting") }
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
                announce("Private message from \(from): \(m.text)")
            case .channel:
                let mine = m.fromUserId == snapshot?.myUserId
                lines.append(ChatLine(from: mine ? "Me" : from, text: m.text, privateWith: nil, time: .now))
                if !mine { announce("\(from): \(m.text)") }
            case .broadcast:
                lines.append(ChatLine(from: "Broadcast from \(from)", text: m.text, privateWith: nil, time: .now))
                announce("Broadcast from \(from): \(m.text)")
            }
        case .userJoined(let u, let ch):
            if ch == myChannel, u.id != snapshot?.myUserId { announce("\(u.displayName) joined") }
        case .userLeft(let u, let ch):
            if ch == myChannel, u.id != snapshot?.myUserId { announce("\(u.displayName) left") }
        case .voiceActivated(let on):
            voiceActive = on
        case .kicked(_, let ch):
            announce(ch > 0 ? "You were kicked from the channel" : "You were kicked from the server")
        default: break
        }
        refresh()
    }
}
