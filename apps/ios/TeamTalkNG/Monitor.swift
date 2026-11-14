import Foundation
import Observation
import UIKit

/// The Monitor (ttmonitor.mad-gamer.com): it stays logged in to servers
/// while this app isn't, keeps private conversations, and says what
/// happened. With NG Account, the account's monitors; without, this
/// iPhone's own registration. (Notifications come once the new app has
/// the real app ID.)
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
    private static let keychainService = "TeamTalk NG monitor"

    init(app: AppModel) {
        self.app = app
    }

    var unread: Int64 { servers.reduce(0) { $0 + $1.unreadPrivateMessages } }

    /// Signed in or out of NG Account: a different set of monitors.
    func accountChanged() {
        servers = []
        events = []
        lastSeq = nil
        Task { await refresh() }
    }

    private var ownToken: String { Passwords.secret(Self.keychainService, "token") }

    /// A client with the right token, registering this iPhone if needed.
    private func client(registering: Bool) async -> MonitorClient? {
        if let t = app.account.sessionToken { return MonitorClient(baseUrl: "", token: t) }
        if !ownToken.isEmpty { return MonitorClient(baseUrl: "", token: ownToken) }
        guard registering else { return nil }
        let c = MonitorClient(baseUrl: "", token: nil)
        let name = UIDevice.current.name
        switch await Task.detached(operation: { Result { try c.register(deviceName: name) } }).value {
        case .success(let token):
            Passwords.setSecret(token, Self.keychainService, "token")
            return c
        case .failure(let e):
            problem = NGAccountStore.words(e)
            return nil
        }
    }

    /// Runs a call; failures in words (nil: it worked).
    @discardableResult
    func call<T: Sendable>(registering: Bool = false, _ f: @escaping @Sendable (MonitorClient) throws -> T) async -> Result<T, Error>? {
        guard let c = await client(registering: registering) else { return nil }
        let r = await Task.detached { Result { try f(c) } }.value
        if case .failure(let e) = r {
            if case .SignedOut = e as? NgError, app.account.sessionToken == nil {
                // This iPhone's registration is gone: start again next time.
                Passwords.setSecret("", Self.keychainService, "token")
            }
            problem = NGAccountStore.words(e)
        }
        return r
    }

    func refresh() async {
        loading = true
        defer { loading = false }
        guard let r = await call({ try $0.servers() }) else { servers = []; return }
        if case .success(let s) = r { servers = s; problem = nil }
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
            password: Passwords.get(s.id), statusMsg: "", channel: "", channelPassword: "", enabled: true)
        guard let r = await call(registering: true, { try $0.addServer(server: input) }) else { return problem }
        switch r {
        case .success: await refresh(); return nil
        case .failure(let e): return NGAccountStore.words(e)
        }
    }

    func remove(_ s: MonitorServer) async {
        await call { try $0.removeServer(serverId: s.id) }
        await refresh()
    }

    func setEnabled(_ s: MonitorServer, _ on: Bool) async {
        // The monitor keeps the password; an empty one leaves it as it is.
        let input = MonitorServerInput(
            name: s.name, host: s.host, tcpPort: s.tcpPort, encrypted: s.encrypted, nickname: s.nickname,
            username: s.username, password: savedPassword(for: s), statusMsg: "", channel: "", channelPassword: "", enabled: on)
        await call { try $0.updateServer(serverId: s.id, server: input) }
        await refresh()
    }

    private func savedPassword(for m: MonitorServer) -> String {
        app.servers.first { Self.same($0, m) }.map { Passwords.get($0.id) } ?? ""
    }

    static func same(_ s: SavedServer, _ m: MonitorServer) -> Bool {
        s.host.caseInsensitiveCompare(m.host) == .orderedSame && s.tcpPort == m.tcpPort && s.username == m.username
    }

    /// The monitor of a saved server, if any.
    func monitor(of s: SavedServer) -> MonitorServer? { servers.first { Self.same(s, $0) } }

    /// This app connected to (or left) a monitored server with the same
    /// account: the monitor steps back meanwhile, so the two don't clash.
    func appConnected(_ s: SavedServer, _ connected: Bool) {
        guard let m = monitor(of: s) else { return }
        Task {
            if connected {
                await call { try $0.pause(serverId: m.id, minutes: 12 * 60) }
            } else {
                await call { try $0.resume(serverId: m.id) }
            }
            await refresh()
        }
    }
}
