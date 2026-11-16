import AudioNetKit
import Foundation
import Observation
import Security

// AudioNet in TeamTalk NG (the owner's design, 2026-11-16):
// * signed in to any number of AudioNet accounts, each as a visitor (no
//   device is added to the account; the visitor's token is kept in the
//   keychain, on this iPhone only);
// * a device's sound into a TeamTalk channel: each such stream has a
//   TeamTalk login of its own (named from Settings, "Matthew - Microphone"),
//   which follows me from channel to channel and sends the sound as its
//   voice, so my own talking and file streaming are untouched and the
//   others can set each stream's volume;
// * the channel's sound (everyone I hear) or my microphone sent to one of
//   my AudioNet devices' outputs.
// Each stream has its own volume and mute, shown while it streams.

/// One signed-in AudioNet account.
@MainActor @Observable
final class AudioNetAccount: Identifiable {
    enum State: Equatable {
        case idle, connecting, connected
        case problem(String)
    }

    let login: VisitorLogin
    nonisolated let id: String
    var state: State = .idle
    var devices: [Device] = []
    @ObservationIgnored var client: Client?
    @ObservationIgnored var generation = 0

    init(login: VisitorLogin) {
        self.login = login
        id = "\(login.serverUrl)|\(login.username)"
    }

    /// "matthew on audionet.example.com".
    var name: String {
        let host = URL(string: login.serverUrl)?.host ?? login.serverUrl
        return "\(login.username) on \(host)"
    }

    var stateText: String {
        switch state {
        case .idle: "Not connected"
        case .connecting: "Connecting"
        case .connected: "Connected"
        case .problem(let p): p
        }
    }
}

/// A stream TeamTalk NG runs: a device's sound into a channel, or the
/// channel's sound or my microphone to a device.
@MainActor @Observable
final class AudioNetStream: Identifiable {
    enum Kind: Equatable {
        case intoChannel
        case toDevice(Capture)
    }

    let id = UUID()
    let kind: Kind
    let accountId: String
    /// What it is, in words ("Microphone from Mac into Lobby on My server").
    let title: String
    var sessionId: String?
    var state = "Starting"
    /// 0 to 1 (AudioNet's slider: heard on a square curve), and mute.
    var volume: Double = 1
    var muted = false
    weak var connection: ServerConnection?
    @ObservationIgnored var feed: ChannelFeed?

    init(kind: Kind, accountId: String, title: String, connection: ServerConnection) {
        self.kind = kind
        self.accountId = accountId
        self.title = title
        self.connection = connection
    }
}

@MainActor @Observable
final class AudioNetStore {
    private(set) var accounts: [AudioNetAccount] = []
    private(set) var streams: [AudioNetStream] = []
    /// The AudioNet screen is open: accounts stay connected (their devices
    /// listed) while it is, or while they have streams.
    var screenOpen = false { didSet { updateConnections() } }
    /// The name an AudioNet stream's TeamTalk login has (%nickname%,
    /// %source%, %device%).
    var loginName: String {
        didSet { UserDefaults.standard.set(loginName, forKey: "audioNetLoginName") }
    }
    static let defaultLoginName = "%nickname% - %source%"

    /// Captures shared by the streams that send them (one reader each).
    @ObservationIgnored private var hubs: [String: CaptureHub] = [:]

    init() {
        loginName = UserDefaults.standard.string(forKey: "audioNetLoginName") ?? Self.defaultLoginName
        accounts = Self.loadLogins().map(AudioNetAccount.init)
    }

    // MARK: Accounts

    func signIn(server: String, username: String, password: String) async -> String? {
        let server = server.trimmingCharacters(in: .whitespacesAndNewlines)
        let username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        UserDefaults.standard.set(server, forKey: "audioNetServer")
        let r = await Task.detached { Result { try visitorSignIn(serverUrl: server, username: username, password: password) } }.value
        switch r {
        case .success(let l):
            let a = AudioNetAccount(login: l)
            if let old = accounts.first(where: { $0.id == a.id }) { signOut(old) }
            accounts.append(a)
            saveLogins()
            updateConnections()
            return nil
        case .failure(let e):
            return Self.words(e)
        }
    }

    func signOut(_ a: AudioNetAccount) {
        for s in streams where s.accountId == a.id { stop(s, said: nil) }
        disconnect(a)
        accounts.removeAll { $0.id == a.id }
        saveLogins()
        let l = a.login
        // Ends the visitor's session; nothing else is left (no device added).
        Task.detached { _ = try? visitorSignOut(login: l) }
    }

    func account(_ id: String) -> AudioNetAccount? { accounts.first { $0.id == id } }

    private func updateConnections() {
        for a in accounts {
            let needed = screenOpen || streams.contains { $0.accountId == a.id }
            if needed && a.client == nil { connect(a) } else if !needed && a.client != nil { disconnect(a) }
        }
    }

    private func connect(_ a: AudioNetAccount) {
        a.generation += 1
        let c = Client.visitor(login: a.login, appName: "TeamTalk NG", listener: Events(owner: self, account: a.id, generation: a.generation))
        a.client = c
        a.state = .connecting
        c.start()
    }

    private func disconnect(_ a: AudioNetAccount) {
        a.generation += 1
        let c = a.client
        a.client = nil
        a.state = .idle
        a.devices = []
        Task.detached { c?.stop() }
    }

    fileprivate func handle(_ event: AudioNetKit.Event, account id: String, generation g: Int) {
        guard let a = account(id), a.generation == g else { return }
        switch event {
        case .connected:
            a.state = .connected
            a.client?.refreshDevices()
        case .disconnected(let reason):
            a.state = reason.isEmpty ? .connecting : .problem("Reconnecting: \(reason)")
        case .devices(let list):
            a.devices = list
        case .deviceChanged(let d):
            if let i = a.devices.firstIndex(where: { $0.nodeId == d.nodeId }) { a.devices[i] = d } else { a.devices.append(d) }
        case .deviceGone(let node):
            a.devices.removeAll { $0.nodeId == node }
        case .stream(let session, let state, let detail):
            guard let s = streams.first(where: { $0.sessionId == session }) else { return }
            switch state {
            case .starting: s.state = "Starting"
            case .active: s.state = "Streaming"
            case .ended: stop(s, said: "\(s.title) stopped.")
            case .failed: stop(s, said: detail.isEmpty ? "\(s.title) failed." : "\(s.title) failed: \(detail)")
            }
        case .streamEnded(let session, let reason):
            if let s = streams.first(where: { $0.sessionId == session }) {
                stop(s, said: reason.isEmpty ? "\(s.title) stopped." : "\(s.title) stopped: \(reason)")
            }
        case .serverProblem(let message):
            a.state = .problem(message)
        case .stopped(let error):
            if let error { a.state = .problem(error) }
        default:
            break
        }
    }

    // MARK: Streams

    /// A device's sound into my channel on `c`, through a TeamTalk login of
    /// its own. A message when it can't.
    func sendIntoChannel(_ device: Device, _ source: Source, account a: AudioNetAccount, on c: ServerConnection) async -> String? {
        guard let client = a.client else { return "\(a.name) isn't connected yet." }
        guard c.isConnected, c.hasAudio, let snap = c.snapshot, snap.myChannelId > 0,
              let channel = snap.channels.first(where: { $0.id == snap.myChannelId }) else {
            return "Join a channel first."
        }
        // Without multiple logins, the stream's login would log me out.
        guard c.rights.multiLogin else {
            return "Your account on this server can't be logged in twice, so an AudioNet stream would log you out. The server's owner can allow multiple logins for your account."
        }
        let rate = channel.codec.sampleRate > 0 ? UInt32(channel.codec.sampleRate) : 48_000
        let channels = UInt32(min(2, max(1, channel.codec.channels)))
        let channelName = channel.parentId == 0 ? "the root channel" : channel.name
        let s = AudioNetStream(kind: .intoChannel, accountId: a.id,
                               title: "\(source.name) from \(device.name) into \(channelName)", connection: c)
        let tap = AudioTap(name: "TeamTalk NG", sampleRate: rate, channels: channels)
        let session: String
        do { session = try client.listen(nodeId: device.nodeId, sourceId: source.id, outputId: tap.destinationId()) } catch { return Self.words(error) }
        s.sessionId = session
        streams.append(s)
        let nickname = loginName
            .replacingOccurrences(of: "%nickname%", with: c.nameForOthers)
            .replacingOccurrences(of: "%source%", with: source.name)
            .replacingOccurrences(of: "%device%", with: device.name)
        let path = c.myChannelPath
        let options = c.companionOptions(nickname: nickname, channelPath: path, channelPassword: c.knownPassword(snap.myChannelId))
        let feed = ChannelFeed(tap: tap, sampleRate: rate, channels: channels)
        feed.path = path
        s.feed = feed
        if let problem = await feed.start(options) {
            stop(s, said: nil)
            return "The stream's TeamTalk login couldn't connect: \(problem)"
        }
        return nil
    }

    /// The channel's sound or my microphone (from `c`) to a device's output.
    func sendToDevice(_ what: Capture, _ device: Device, _ output: Output, account a: AudioNetAccount, from c: ServerConnection) async -> String? {
        guard let client = a.client else { return "\(a.name) isn't connected yet." }
        guard c.isConnected, c.hasAudio, (c.snapshot?.myChannelId ?? 0) > 0 else { return "Join a channel first." }
        let key = "\(c.server.id)|\(what == .channel ? "channel" : "microphone")"
        let hub = hubs[key] ?? CaptureHub(client: c.coreClient, what: what)
        hubs[key] = hub
        guard let format = await hub.start() else {
            if hub.isEmpty { hub.stop(); hubs[key] = nil }
            return what == .channel ? "The channel's sound couldn't be captured." : "The microphone couldn't be captured."
        }
        let name = what == .channel ? "TeamTalk channel" : "TeamTalk microphone"
        let source = AppSource(name: name, sampleRate: format.rate, channels: format.channels)
        let session: String
        do { session = try client.send(nodeId: device.nodeId, sourceId: source.sourceId(), outputId: output.id) } catch {
            if hub.isEmpty { hub.stop(); hubs[key] = nil }
            return Self.words(error)
        }
        hub.add(session, source)
        let what_ = what == .channel ? "The channel's sound" : "My microphone"
        let s = AudioNetStream(kind: .toDevice(what), accountId: a.id, title: "\(what_) to \(output.name) on \(device.name)", connection: c)
        s.sessionId = session
        streams.append(s)
        return nil
    }

    func setVolume(_ s: AudioNetStream, _ volume: Double, muted: Bool) {
        s.volume = volume
        s.muted = muted
        guard let id = s.sessionId else { return }
        account(s.accountId)?.client?.setStreamVolume(sessionId: id, volume: Float(volume), muted: muted)
    }

    /// Stops a stream (and says `said`, when given).
    func stop(_ s: AudioNetStream, said: String?) {
        guard streams.contains(where: { $0 === s }) else { return }
        streams.removeAll { $0 === s }
        if let id = s.sessionId { account(s.accountId)?.client?.stopStream(sessionId: id) }
        s.feed?.stop()
        s.feed = nil
        if case .toDevice(let what) = s.kind, let c = s.connection, let id = s.sessionId {
            let key = "\(c.server.id)|\(what == .channel ? "channel" : "microphone")"
            if let hub = hubs[key] {
                hub.remove(id)
                if hub.isEmpty { hub.stop(); hubs[key] = nil }
            }
        }
        if let said { announce(said) }
        updateConnections()
    }

    func stopAll(for c: ServerConnection, said: String?) {
        let mine = streams.filter { $0.connection === c }
        for s in mine { stop(s, said: nil) }
        if !mine.isEmpty, let said { announce(said) }
    }

    /// A connection changed: its streams' logins follow me to my channel;
    /// when it's gone, they stop.
    func follow(_ c: ServerConnection) {
        let mine = streams.filter { $0.connection === c }
        guard !mine.isEmpty else { return }
        guard c.isConnected || isReconnecting(c) else {
            stopAll(for: c, said: "AudioNet streams on \(c.server.title) stopped: disconnected.")
            return
        }
        let id = c.snapshot?.myChannelId ?? 0
        let path = id > 0 ? c.myChannelPath : ""
        for s in mine {
            guard let feed = s.feed, feed.path != path else { continue }
            feed.path = path
            feed.follow(path: path, password: c.knownPassword(id))
        }
    }

    private func isReconnecting(_ c: ServerConnection) -> Bool {
        if case .reconnecting = c.state { return true }
        return false
    }

    // MARK: Words and the keychain

    static func words(_ e: Error) -> String {
        if let e = e as? AudioNetError { return "\(e)".replacingOccurrences(of: "message: ", with: "") }
        return e.localizedDescription
    }

    private static let keychain: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "AudioNet sign-in",
    ]

    private static func item(_ account: String) -> [String: Any] {
        var q = keychain
        q[kSecAttrAccount as String] = account
        return q
    }

    /// Every visitor sign-in (the one from before several accounts too).
    private static func loadLogins() -> [VisitorLogin] {
        func read(_ account: String) -> Data? {
            var q = item(account)
            q[kSecReturnData as String] = true
            var out: CFTypeRef?
            return SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess ? out as? Data : nil
        }
        func login(_ f: [String: String]) -> VisitorLogin? {
            guard let s = f["server_url"], let u = f["username"], let t = f["token"] else { return nil }
            return VisitorLogin(serverUrl: s, username: u, token: t)
        }
        if let d = read("visitors"), let list = try? JSONSerialization.jsonObject(with: d) as? [[String: String]] {
            return list.compactMap(login)
        }
        if let d = read("visitor"), let f = try? JSONSerialization.jsonObject(with: d) as? [String: String], let l = login(f) {
            return [l]
        }
        return []
    }

    private func saveLogins() {
        let list = accounts.map { ["server_url": $0.login.serverUrl, "username": $0.login.username, "token": $0.login.token] }
        guard let d = try? JSONSerialization.data(withJSONObject: list) else { return }
        SecItemDelete(Self.item("visitors") as CFDictionary)
        SecItemDelete(Self.item("visitor") as CFDictionary)
        var q = Self.item("visitors")
        q[kSecValueData as String] = d
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(q as CFDictionary, nil)
    }

    private final class Events: AudioNetKit.EventListener, @unchecked Sendable {
        weak var owner: AudioNetStore?
        let account: String
        let generation: Int
        init(owner: AudioNetStore, account: String, generation: Int) {
            self.owner = owner
            self.account = account
            self.generation = generation
        }
        func onEvent(event: AudioNetKit.Event) {
            let account = account, generation = generation
            Task { @MainActor [weak owner] in owner?.handle(event, account: account, generation: generation) }
        }
    }
}

// MARK: Into a channel: a TeamTalk login of its own

/// An AudioNet stream's TeamTalk login: no sound devices; it sends what
/// the tap plays as its voice, read by the clock (the reads set the
/// stream's pace).
final class ChannelFeed: @unchecked Sendable {
    private let tap: AudioTap
    private let rate: UInt32
    private let channels: UInt32
    private let client: TtClient
    private let queue = DispatchQueue(label: "ttng.audionet.feed")
    private var timer: DispatchSourceTimer?
    private var started = Date()
    private var sentFrames: Int = 0
    /// The channel it's in (set on the main thread).
    @MainActor var path = ""

    init(tap: AudioTap, sampleRate: UInt32, channels: UInt32) {
        self.tap = tap
        rate = sampleRate
        self.channels = channels
        client = TtClient(listener: QuietListener())
    }

    /// Logs in (and joins the channel); a problem when it can't.
    func start(_ options: ConnectOptions) async -> String? {
        let client = self.client
        let failed: String? = await Task.detached {
            do { try client.connect(options: options); return nil } catch { return words(error) }
        }.value
        if failed != nil { return failed }
        queue.async { [self] in
            started = Date()
            sentFrames = 0
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now(), repeating: .milliseconds(20), leeway: .milliseconds(2))
            t.setEventHandler { [weak self] in self?.pump() }
            timer = t
            t.resume()
        }
        return nil
    }

    private func pump() {
        // The frames due by now; at most 200 ms at once (after a stall).
        let due = Int(Date().timeIntervalSince(started) * Double(rate))
        var frames = due - sentFrames
        if frames <= 0 { return }
        if frames > Int(rate) / 5 {
            sentFrames = due - Int(rate) / 5
            frames = Int(rate) / 5
        }
        let samples = tap.read(frames: UInt32(frames))
        sentFrames += frames
        // A full queue drops the block (the stream catches up).
        try? client.insertAudio(samples: samples, sampleRate: rate, channels: channels)
    }

    func follow(path: String, password: String) {
        let client = self.client
        Task.detached {
            if path.isEmpty { try? client.leaveChannel() } else { try? client.joinChannelPath(path: path, password: password) }
        }
    }

    func stop() {
        let client = self.client
        queue.async { [self] in
            timer?.cancel()
            timer = nil
        }
        Task.detached {
            try? client.endInsertedAudio()
            try? client.disconnect()
        }
    }
}

/// The stream logins' events aren't shown.
private final class QuietListener: TtListener, @unchecked Sendable {
    func onEvent(event: Event) {}
}

// MARK: To a device: the channel's sound or my microphone

/// One capture from a connection, written to every AppSource sending it.
final class CaptureHub: @unchecked Sendable {
    struct Format { let rate: UInt32; let channels: UInt32 }

    private let client: TtClient
    private let what: Capture
    private let queue = DispatchQueue(label: "ttng.audionet.capture")
    private var timer: DispatchSourceTimer?
    private var format: Format?
    private var sources: [String: AppSource] = [:]
    private let lock = NSLock()

    init(client: TtClient, what: Capture) {
        self.client = client
        self.what = what
    }

    var isEmpty: Bool { lock.withLock { sources.isEmpty } }

    /// Capturing (once), its format known; nil when it can't capture.
    func start() async -> Format? {
        if let f = lock.withLock({ format }) { return f }
        let client = self.client, what = self.what
        let f: Format? = await Task.detached {
            guard (try? client.setCapture(what: what, on: true)) != nil else { return nil }
            // The format comes with the first audio.
            for _ in 0..<50 {
                let a = client.readCaptured(what: what)
                if a.sampleRate > 0 && a.channels > 0 { return Format(rate: a.sampleRate, channels: a.channels) }
                try? await Task.sleep(for: .milliseconds(40))
            }
            try? client.setCapture(what: what, on: false)
            return nil
        }.value
        guard let f else { return nil }
        lock.withLock { format = f }
        queue.async { [self] in
            guard timer == nil else { return }
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now(), repeating: .milliseconds(20), leeway: .milliseconds(2))
            t.setEventHandler { [weak self] in self?.pump() }
            timer = t
            t.resume()
        }
        return f
    }

    func add(_ session: String, _ s: AppSource) { lock.withLock { sources[session] = s } }
    func remove(_ session: String) { lock.withLock { _ = sources.removeValue(forKey: session) } }

    private func pump() {
        let a = client.readCaptured(what: what)
        guard !a.samples.isEmpty, let f = lock.withLock({ format }), a.sampleRate == f.rate, a.channels == f.channels else { return }
        let floats = a.samples.map { Float($0) / 32768 }
        for s in lock.withLock({ Array(sources.values) }) { _ = s.write(samples: floats) }
    }

    func stop() {
        let client = self.client, what = self.what
        queue.async { [self] in
            timer?.cancel()
            timer = nil
        }
        Task.detached { try? client.setCapture(what: what, on: false) }
    }
}
