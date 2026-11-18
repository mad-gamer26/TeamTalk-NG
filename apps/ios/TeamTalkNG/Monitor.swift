import Foundation
import Observation
import UIKit

/// Your own Monitor (`ng-monitor` on your computer): it stays logged in to
/// servers while this app isn't, keeps private conversations, and says
/// what happened. Reached through TeamTalk NG's relay, end to end
/// encrypted; nobody else holds your server passwords. Paired once (the
/// pairing is in iCloud Keychain, so your other devices use it too).
@MainActor @Observable
final class MonitorStore {
    private unowned let app: AppModel
    private(set) var servers: [MonitorServer] = []
    private(set) var problem: String?
    private(set) var loading = false
    /// Events seen so far (newest last), and the last one's number.
    private(set) var events: [MonitorEvent] = []
    private var lastSeq: Int64?
    private var polling: Task<Void, Never>?

    init(app: AppModel) {
        self.app = app
    }

    var unread: Int64 { servers.reduce(0) { $0 + $1.unreadPrivateMessages } }

    /// Paired or unpaired: a different Monitor, or none.
    func monitorChanged() {
        servers = []
        events = []
        lastSeq = nil
        Task { await refresh() }
    }

    /// A client for your own Monitor; nil while none is paired.
    private func client(registering: Bool = false) async -> MonitorClient? {
        if own == nil { own = Self.loadOwn() }
        guard let o = own else { return nil }
        do {
            let c = try MonitorClient.own(relay: Service.base, monitor: o, phoneKey: Self.phoneKey)
            await ensurePushKey(c)
            return c
        } catch {
            problem = NGAccountStore.words(error)
            return nil
        }
    }

    /// Runs a call; failures in words (nil: it worked).
    @discardableResult
    func call<T: Sendable>(registering: Bool = false, _ f: @escaping @Sendable (MonitorClient) throws -> T) async -> Result<T, Error>? {
        guard let c = await client(registering: registering) else { return nil }
        let r = await Task.detached { Result { try f(c) } }.value
        if case .failure(let e) = r { problem = NGAccountStore.words(e) }
        return r
    }

    // MARK: Your own Monitor

    private static let ownService = "TeamTalk NG own monitor"
    private struct StoredOwn: Codable { var id: String; var name: String; var key: String }

    /// Your own Monitor (`ng-monitor` on your computer), when this iPhone
    /// is paired with one: then it's the only Monitor this app uses.
    private(set) var own: OwnMonitor? = MonitorStore.loadOwn()

    private static func loadOwn() -> OwnMonitor? {
        let s = Passwords.secret(ownService, "monitor")
        guard let o = try? JSONDecoder().decode(StoredOwn.self, from: Data(s.utf8)), let k = Data(base64Encoded: o.key) else { return nil }
        return OwnMonitor(monitorId: o.id, name: o.name, monitorKey: k)
    }

    /// This iPhone's key for its own Monitors (made once, kept in the Keychain).
    private static var phoneKey: Data {
        if let k = Data(base64Encoded: Passwords.secret(ownService, "phone key")), k.count == 32 { return k }
        let k = ownMonitorNewPhoneKey()
        Passwords.setSecret(k.base64EncodedString(), ownService, "phone key")
        return k
    }

    /// Pairs with the Monitor showing `code`. Returns why not, or nil.
    func pairOwn(code: String) async -> String? {
        let relay = Service.base, name = UIDevice.current.name, key = Self.phoneKey
        switch await Task.detached(operation: { Result { try ownMonitorPair(relay: relay, code: code, phoneName: name, phoneKey: key) } }).value {
        case .failure(let e):
            return NGAccountStore.words(e)
        case .success(let m):
            let stored = StoredOwn(id: m.monitorId, name: m.name, key: m.monitorKey.base64EncodedString())
            if let d = try? JSONEncoder().encode(stored) { Passwords.setSecret(String(decoding: d, as: UTF8.self), Self.ownService, "monitor") }
            own = m
            problem = nil
            pushKeySaved = false
            monitorChanged()
            return nil
        }
    }

    /// Forgets the paired Monitor here (and on your other devices: the
    /// pairing is in iCloud Keychain). It keeps watching at home; unpair
    /// there with `ng-monitor unpair`.
    func forgetOwn() {
        Passwords.setSecret("", Self.ownService, "monitor")
        own = nil
        pushKeySaved = false
        Service.forgetOwnPushKey()
        monitorChanged()
    }

    /// The key that opens this Monitor's notifications (asked once per
    /// device: a pairing from another device arrives without it), and this
    /// device's Apple token given to it.
    private var pushKeySaved = Service.hasPushKey
    private func ensurePushKey(_ c: MonitorClient) async {
        guard !pushKeySaved else { return }
        guard case .success(let hello) = await Task.detached(operation: { Result { try c.ownHello() } }).value else { return }
        Service.saveOwnPushKey(hello.pushKey)
        pushKeySaved = true
        if let t = pushToken { await sendPushToken(t, via: c) }
    }

    // MARK: Notifications

    /// The device's APNs token, once Apple gives it.
    private var pushToken: String?

    /// Apple gave a device token: the Monitor sends notifications to it (to
    /// Apple's sandbox from a development build).
    func setPushToken(_ token: String) async {
        pushToken = token
        guard let c = await client(registering: true) else { return }
        await sendPushToken(token, via: c)
    }

    private func sendPushToken(_ token: String, via c: MonitorClient) async {
        let id = NGAccountStore.installId
        let sandbox = Service.sandbox
        let topic = Bundle.main.bundleIdentifier ?? ""
        let r = await Task.detached { Result { try c.setPush(apnsToken: token, sandbox: sandbox, appRef: id, installId: id, topic: topic) } }.value
        if case .failure(let e) = r { problem = NGAccountStore.words(e) }
    }

    func refresh() async {
        loading = true
        defer { loading = false }
        guard let r = await call({ try $0.servers() }) else { servers = []; return }
        if case .success(let s) = r { servers = s; problem = nil }
        if !connectedHere.isEmpty || !quietIds.isEmpty { await syncQuiet() }
        await syncNames()
    }

    /// The Monitor titles its notifications with its own name for a server:
    /// kept the same as the name in the server list (renamed there, renamed
    /// here). Without logging in again.
    private func syncNames() async {
        var renamed = false
        for saved in app.servers {
            guard let m = monitor(of: saved), m.name != saved.title, var c = await config(m) else { continue }
            c.name = saved.title
            let input = MonitorServerInput(
                name: c.name, host: c.host, tcpPort: c.tcpPort, encrypted: c.encrypted, nickname: c.nickname,
                username: c.username, password: "", statusMsg: c.statusMsg, statusMode: c.statusMode,
                channel: c.channel, channelPassword: "", enabled: c.enabled)
            let id = c.id
            if case .success? = await call({ try $0.updateServer(serverId: id, server: input) }) { renamed = true }
        }
        if renamed, case .success(let s)? = await call({ try $0.servers() }) { servers = s }
    }

    /// Follows events while a Monitor screen is open (every few seconds),
    /// saying the new ones.
    func startFollowing() {
        guard polling == nil else { return }
        polling = Task { [weak self] in
            while !Task.isCancelled {
                await self?.poll()
                try? await Task.sleep(for: .seconds(4))
            }
        }
    }

    func stopFollowing() {
        polling?.cancel()
        polling = nil
    }

    private func poll() async {
        let since = lastSeq
        guard let r = await call({ try $0.events(since: since, serverId: nil) }), case .success(let e) = r else { return }
        let first = since == nil
        lastSeq = e.lastSeq
        guard !e.events.isEmpty else { return }
        events.append(contentsOf: e.events)
        if events.count > 500 { events.removeFirst(events.count - 500) }
        if !first {
            for ev in e.events.suffix(5) {
                let server = servers.first { $0.id == ev.serverId }?.name ?? ""
                announce(server.isEmpty ? ev.text : "\(server): \(ev.text)")
                if ev.kind == "message" { app.sounds.play(ev.messageKind == "user" ? .privateMessage : .channelMessage) }
            }
        }
        await refresh()
    }

    // MARK: Servers

    /// Monitors one of the saved servers. Returns why not, or nil.
    func add(_ s: SavedServer) async -> String? {
        let input = MonitorServerInput(
            name: s.title, host: s.host, tcpPort: s.tcpPort, encrypted: s.encrypted,
            nickname: s.nickname.isEmpty ? app.nickname : s.nickname, username: s.username,
            password: Passwords.get(s.id), statusMsg: "", statusMode: Gender.monitorBits(app.gender), channel: "",
            channelPassword: "", enabled: true)
        guard own != nil || Self.loadOwn() != nil else { return "Set up your Monitor first: Settings → Monitor." }
        guard let r = await call(registering: true, { try $0.addServer(server: input) }) else { return problem ?? "Your Monitor can't be reached." }
        switch r {
        case .success: await refresh(); return nil
        case .failure(let e): return NGAccountStore.words(e)
        }
    }

    func remove(_ s: MonitorServer) async {
        await call { try $0.removeServer(serverId: s.id) }
        await refresh()
    }

    /// Turns monitoring of a server on or off, keeping its other settings.
    func setEnabled(_ s: MonitorServer, _ on: Bool) async {
        guard var c = await config(s) else { return }
        c.enabled = on
        _ = await save(c)
    }

    /// A monitored server's settings as the Monitor keeps them: nickname,
    /// status message, gender, channel, on or off. Nil when it can't say.
    func config(_ s: MonitorServer) async -> MonitorServerConfig? {
        guard case .success(let c)? = await call({ try $0.serverConfig(serverId: s.id) }) else { return nil }
        return c
    }

    /// Saves a server's Monitor settings (`channelPassword` empty: kept,
    /// as its login password always is). Returns why not, or nil.
    func save(_ c: MonitorServerConfig, channelPassword: String = "") async -> String? {
        let input = MonitorServerInput(
            name: c.name, host: c.host, tcpPort: c.tcpPort, encrypted: c.encrypted, nickname: c.nickname,
            username: c.username, password: "", statusMsg: c.statusMsg, statusMode: c.statusMode,
            channel: c.channel, channelPassword: channelPassword, enabled: c.enabled)
        guard let r = await call({ try $0.updateServer(serverId: c.id, server: input) }) else { return problem }
        await refresh()
        if case .failure(let e) = r { return NGAccountStore.words(e) }
        return nil
    }

    static func same(_ s: SavedServer, _ m: MonitorServer) -> Bool {
        s.host.caseInsensitiveCompare(m.host) == .orderedSame && s.tcpPort == m.tcpPort && s.username == m.username
    }

    /// The monitor of a saved server, if any.
    func monitor(of s: SavedServer) -> MonitorServer? { servers.first { Self.same(s, $0) } }

    // MARK: Logged in here too

    /// Saved servers this app is logged in to itself.
    private var connectedHere: [UUID: SavedServer] = [:]
    /// The monitors that send this iPhone nothing now (it's there itself).
    private var quietIds: Set<Int64> = []
    private var quietRenewal: Task<Void, Never>?
    /// How long the Monitor keeps this iPhone quiet without hearing from
    /// it: renewed well before, so closing the app or restarting the phone
    /// brings the notifications back within this time.
    private static let quietSeconds: Int64 = 120

    /// This app logged in to a server (or left it, in any way). The monitor
    /// stays logged in there, but sends this iPhone no notifications about
    /// it meanwhile; the account's other phones get them as usual.
    func appConnected(_ s: SavedServer, _ connected: Bool) {
        guard (connectedHere[s.id] != nil) != connected else { return }
        connectedHere[s.id] = connected ? s : nil
        if connectedHere.isEmpty {
            quietRenewal?.cancel()
            quietRenewal = nil
        } else if quietRenewal == nil {
            quietRenewal = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(45))
                    guard !Task.isCancelled else { return }
                    await self?.syncQuiet(renew: true)
                }
            }
        }
        Task { servers.isEmpty ? await refresh() : await syncQuiet() }
    }

    /// Tells the Monitor which of its servers this iPhone is on itself.
    private func syncQuiet(renew: Bool = false) async {
        let want = Set(connectedHere.values.compactMap { monitor(of: $0)?.id })
        let start = renew ? want : want.subtracting(quietIds)
        let end = quietIds.subtracting(want)
        quietIds = want
        guard !start.isEmpty || !end.isEmpty else { return }
        let install = NGAccountStore.installId, seconds = Self.quietSeconds
        for id in start { await call { try $0.quiet(serverId: id, installId: install, seconds: seconds) } }
        for id in end { await call { try $0.unquiet(serverId: id, installId: install) } }
    }
}

extension Gender {
    /// The Monitor's gender as TeamTalk status mode bits.
    static func monitorBits(_ g: Gender) -> Int64 {
        switch g {
        case .female: 256
        case .neutral: 4096
        default: 0
        }
    }

    /// From the Monitor's status mode bits.
    static func fromMonitorBits(_ bits: Int64) -> Gender {
        if bits & 256 != 0 { return .female }
        if bits & 4096 != 0 { return .neutral }
        return .male
    }
}
