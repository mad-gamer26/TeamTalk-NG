import Foundation
import Observation
import UIKit

/// The Monitor: it stays logged in to servers while this app isn't, keeps
/// private conversations, and says what happened. Your own (`ng-monitor`
/// on your computer, reached through TeamTalk NG's relay, end to end
/// encrypted: nobody else holds your server passwords) is recommended;
/// for those without a computer, TeamTalk NG's hosted one (it keeps the
/// servers' passwords on TeamTalk NG's server, encrypted). One or the
/// other; the pairing or registration is in iCloud Keychain, so your
/// other devices use it too.
@MainActor @Observable
final class MonitorStore {
    private unowned let app: AppModel
    private(set) var servers: [MonitorServer] = []
    private(set) var problem: String?
    private(set) var loading = false
    /// Events seen so far (newest last), and the last one's number.
    private(set) var events: [MonitorEvent] = []
    private var lastSeq: Int64?

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

    /// A client for the Monitor in use; nil while there's none (the hosted
    /// one registers this install first when `registering`).
    private func client(registering: Bool = false) async -> MonitorClient? {
        if own == nil { own = Self.loadOwn() }
        if let o = own {
            do {
                let c = try MonitorClient.own(relay: Service.base, monitor: o, phoneKey: Self.phoneKey)
                await ensurePushKey(c)
                return c
            } catch {
                problem = NGAccountStore.words(error)
                return nil
            }
        }
        guard hosted else { return nil }
        return await hostedClient(registering: registering)
    }

    /// A client for the hosted Monitor (registering this install first when
    /// `registering` and it has no registration yet), whether or not it's
    /// the one in use: moving servers to it needs it before switching.
    /// `inUse`: it's the Monitor this iPhone uses (its notification key goes
    /// to the notification extension, and the Apple token to it). Not while
    /// moving to it: until the move works, the other Monitor's key stays.
    private func hostedClient(registering: Bool, inUse: Bool = true) async -> MonitorClient? {
        let token = Passwords.secret(Self.hostedService, "token")
        if !token.isEmpty {
            // A registration made on another device: its notification key too.
            let key = Passwords.secret(Self.hostedService, "push key")
            if inUse, !key.isEmpty, !Service.hasPushKey(for: "hosted") { Service.savePushKey(key, for: "hosted") }
            return MonitorClient(baseUrl: Service.base, token: token)
        }
        guard registering else { return nil }
        let c = MonitorClient(baseUrl: Service.base, token: nil)
        let name = UIDevice.current.name
        switch await Task.detached(operation: { Result { try c.registerWithKey(deviceName: name) } }).value {
        case .success(let r):
            Passwords.setSecret(r.token, Self.hostedService, "token")
            Passwords.setSecret(r.pushKey, Self.hostedService, "push key")
            if inUse {
                Service.savePushKey(r.pushKey, for: "hosted")
                if let t = pushToken { await sendPushToken(t, via: c) }
            }
            return c
        case .failure(let e):
            problem = NGAccountStore.words(e)
            return nil
        }
    }

    // MARK: TeamTalk NG's hosted Monitor

    private static let hostedService = "TeamTalk NG monitor"

    /// Using TeamTalk NG's hosted Monitor (chosen; your own is recommended).
    private(set) var hosted: Bool = UserDefaults.standard.bool(forKey: "monitorHosted")
        || !Passwords.secret(MonitorStore.hostedService, "token").isEmpty

    /// Uses the hosted Monitor (it registers this install when a server is
    /// first monitored).
    func useHosted() {
        guard own == nil else { return }
        hosted = true
        UserDefaults.standard.set(true, forKey: "monitorHosted")
        problem = nil
        monitorChanged()
    }

    /// From your own Monitor to the hosted one. Every server your Monitor
    /// watches moves (its settings, passwords and private conversations,
    /// and your notification settings); all are added to the hosted Monitor
    /// before any leaves yours, and if one can't be added nothing changes.
    /// Then this phone forgets the pairing (your Monitor keeps running on
    /// your computer, watching nothing for it). Why not, or nil.
    func moveToHosted() async -> String? {
        if own == nil { own = Self.loadOwn() }
        guard let o = own else { useHosted(); return nil }
        let from: MonitorClient
        do { from = try MonitorClient.own(relay: Service.base, monitor: o, phoneKey: Self.phoneKey) } catch { return NGAccountStore.words(error) }
        // Registered (if not already), but not in use yet: your own Monitor's
        // notification key stays until the move has worked.
        let hadRegistration = !Passwords.secret(Self.hostedService, "token").isEmpty
        guard let to = await hostedClient(registering: true, inUse: false) else { return problem ?? "TeamTalk NG's Monitor can't be reached." }
        if let why = await moveServers(from: from, to: to, toName: "TeamTalk NG's Monitor") {
            // Nothing changed: a registration made just now goes again.
            if !hadRegistration {
                _ = await Task.detached(operation: { Result { try to.forgetRegistration() } }).value
                Passwords.setSecret("", Self.hostedService, "token")
                Passwords.setSecret("", Self.hostedService, "push key")
            }
            await refresh()
            return why
        }
        Passwords.setSecret("", Self.ownService, "monitor")
        own = nil
        pushKeySaved = false
        // The hosted Monitor's key in place of your own's at once (no moment
        // without one), and the Apple token to it.
        Service.savePushKey(Passwords.secret(Self.hostedService, "push key"), for: "hosted")
        if let t = pushToken { await sendPushToken(t, via: to) }
        hosted = true
        UserDefaults.standard.set(true, forKey: "monitorHosted")
        problem = nil
        monitorChanged()
        return nil
    }

    #if DEBUG
    /// UI tests: a move whose servers can't be added (nothing changes).
    var failMovesForTests = false

    /// UI test: a move to the hosted Monitor that fails leaves your own
    /// Monitor's notification key in place and no hosted registration.
    func failedMoveTest() async -> String {
        guard own != nil || Self.loadOwn() != nil else { return "Failed move: not paired" }
        _ = await client()  // your own Monitor's key in place
        let before = Service.currentPushKeyForTests
        failMovesForTests = true
        defer { failMovesForTests = false }
        let why = await moveToHosted()
        let after = Service.currentPushKeyForTests
        let registered = !Passwords.secret(Self.hostedService, "token").isEmpty
        return "Failed move: refused \(why != nil), key kept \(before.key == after.key && after.kind == "own"), hosted registration left \(registered)"
    }
    #endif

    /// Moves every server `from` watches to `to`: added there first (with
    /// its passwords and conversations, from `export`; an older Monitor
    /// without it gives its settings, and the password saved on this
    /// iPhone), then removed from `from` once all are in. If any can't be
    /// added, those added are taken out again and nothing changes. The
    /// phone's notification settings are copied too. Why not, or nil.
    private func moveServers(from: MonitorClient, to: MonitorClient, toName: String) async -> String? {
        #if DEBUG
        if failMovesForTests { return "Nothing moved to \(toName), because these couldn't: a test server: refused for the test" }
        #endif
        // For an older Monitor without export: the passwords saved here,
        // by host, port and username.
        var kept: [String: (password: String, channelPassword: String)] = [:]
        for sv in app.servers { kept[Self.key(sv.host, sv.tcpPort, sv.username)] = (Passwords.get(sv.id), sv.channelPassword) }
        let saved = kept
        let r: Result<[String], Error> = await Task.detached {
            Result {
                let list = try from.servers()
                if let prefs = try? from.notificationPrefs() { try? to.setNotificationPrefs(prefs: prefs) }
                var added: [(old: Int64, new: Int64)] = []
                var failed: [String] = []
                for s in list {
                    do {
                        let id: Int64
                        do {
                            id = try to.importServer(moved: try from.exportServer(serverId: s.id))
                        } catch NgError.Refused(404, _) {
                            // An older Monitor: no export. Its settings, and
                            // the password saved here.
                            let c = try from.serverConfig(serverId: s.id)
                            guard let mine = saved[MonitorStore.key(s.host, s.tcpPort, s.username)] else {
                                throw NgError.Unexpected(message: "this iPhone has no password for it (update your Monitor to move it with its own)")
                            }
                            id = try to.addServer(server: MonitorServerInput(
                                name: s.name, host: s.host, tcpPort: s.tcpPort, encrypted: s.encrypted,
                                nickname: c.nickname, username: s.username, password: mine.password,
                                statusMsg: c.statusMsg, statusMode: c.statusMode, channel: c.channel,
                                channelPassword: mine.channelPassword, enabled: c.enabled))
                        }
                        added.append((s.id, id))
                    } catch {
                        failed.append("\(s.name): \(NGAccountStore.words(error))")
                    }
                }
                if !failed.isEmpty {
                    for a in added { try? to.removeServer(serverId: a.new) }
                    return failed
                }
                for a in added { try? from.removeServer(serverId: a.old) }
                return []
            }
        }.value
        switch r {
        case .failure(let e): return NGAccountStore.words(e)
        case .success(let failed) where !failed.isEmpty:
            return "Nothing moved to \(toName), because these couldn't: " + failed.joined(separator: "; ")
        case .success: return nil
        }
    }

    /// Stops using the hosted Monitor: its registration ends, so it logs out
    /// of these servers and deletes them, their passwords and conversations
    /// there. Only once it says so does this iPhone forget the registration;
    /// otherwise it keeps it (so it can try again), and says why.
    func stopHosted() async -> String? {
        if !Passwords.secret(Self.hostedService, "token").isEmpty, let c = await hostedClient(registering: false, inUse: false) {
            if case .failure(let e) = await Task.detached(operation: { Result { try c.forgetRegistration() } }).value {
                if case .SignedOut = e as? NgError {
                    // Already gone there.
                } else {
                    return "TeamTalk NG's Monitor couldn't delete what it keeps: \(NGAccountStore.words(e)). Nothing changed; try again."
                }
            }
        }
        Passwords.setSecret("", Self.hostedService, "token")
        Passwords.setSecret("", Self.hostedService, "push key")
        hosted = false
        UserDefaults.standard.set(false, forKey: "monitorHosted")
        if own == nil { Service.forgetPushKey() }
        monitorChanged()
        return nil
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

    /// Pairs with the Monitor showing `code`. From the hosted Monitor, every
    /// server it watches moves to your own first (settings, passwords,
    /// conversations, notification settings; all or nothing), then the
    /// hosted registration ends. Returns why not, or nil.
    func pairOwn(code: String) async -> String? {
        let relay = Service.base, name = UIDevice.current.name, key = Self.phoneKey
        let m: OwnMonitor
        switch await Task.detached(operation: { Result { try ownMonitorPair(relay: relay, code: code, phoneName: name, phoneKey: key) } }).value {
        case .failure(let e): return NGAccountStore.words(e)
        case .success(let paired): m = paired
        }
        if hosted, let from = await hostedClient(registering: false) {
            let to: MonitorClient
            do { to = try MonitorClient.own(relay: relay, monitor: m, phoneKey: key) } catch { return NGAccountStore.words(error) }
            if let why = await moveServers(from: from, to: to, toName: "your Monitor") {
                return why + " You're still using TeamTalk NG's Monitor; pair again with a new code to try again."
            }
            // Your Monitor in use from here: its key in place of the hosted
            // one's at once (no moment without one), then the hosted
            // registration ends.
            own = m
            pushKeySaved = false
            await ensurePushKey(to)
            if let why = await stopHosted() {
                // Moved, but the hosted copy isn't deleted yet: say so; the
                // registration stays here to delete it later.
                problem = why
            }
        }
        let stored = StoredOwn(id: m.monitorId, name: m.name, key: m.monitorKey.base64EncodedString())
        if let d = try? JSONEncoder().encode(stored) { Passwords.setSecret(String(decoding: d, as: UTF8.self), Self.ownService, "monitor") }
        own = m
        hosted = false
        UserDefaults.standard.set(false, forKey: "monitorHosted")
        pushKeySaved = false
        monitorChanged()
        return nil
    }

    /// Forgets the paired Monitor here (and on your other devices: the
    /// pairing is in iCloud Keychain). It keeps watching at home; unpair
    /// there with `ng-monitor unpair`.
    func forgetOwn() {
        Passwords.setSecret("", Self.ownService, "monitor")
        own = nil
        pushKeySaved = false
        Service.forgetPushKey()
        monitorChanged()
    }

    /// The key that opens this Monitor's notifications (asked once per
    /// device: a pairing from another device arrives without it), and this
    /// device's Apple token given to it.
    private var pushKeySaved = Service.hasPushKey(for: "own")
    private func ensurePushKey(_ c: MonitorClient) async {
        guard !pushKeySaved else { return }
        guard case .success(let hello) = await Task.detached(operation: { Result { try c.ownHello() } }).value else { return }
        Service.savePushKey(hello.pushKey, for: "own")
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

    /// A live connection to the Monitor's events (nil: no Monitor, or it
    /// can't be reached now).
    func openEvents(since: Int64?) async -> MonitorEventStream? {
        guard let c = await client() else { return nil }
        switch await Task.detached(operation: { Result { try c.openEvents(since: since) } }).value {
        case .success(let s): return s
        case .failure(let e): problem = NGAccountStore.words(e); return nil
        }
    }

    /// Follows the Monitor's events live while a Monitor screen is open (one
    /// connection, as the old app; no polling), saying the new ones. What
    /// happened while the screen was away is caught up quietly (it was said
    /// in a server's screen, or by a notification).
    func startFollowing() {
        guard following == nil else { return }
        following = Task { [weak self] in
            var wait: Double = 1
            while !Task.isCancelled {
                guard let self else { return }
                guard let stream = await self.openEvents(since: self.lastSeq) else {
                    try? await Task.sleep(for: .seconds(wait)); wait = min(wait * 2, 30); continue
                }
                self.stream = stream
                wait = 1
                var ready = false
                while !Task.isCancelled {
                    guard case .success(let item) = await Task.detached(operation: { Result { try stream.next() } }).value else { break }
                    switch item {
                    case .event(let e):
                        self.lastSeq = e.seq
                        self.take(e, say: ready)
                    case .ready(let seq):
                        self.lastSeq = max(self.lastSeq ?? seq, seq)
                        ready = true
                        await self.refresh()
                    case .reset(let seq):
                        self.lastSeq = seq
                    case .nothing:
                        break
                    }
                }
                stream.close()
                self.stream = nil
            }
        }
    }

    func stopFollowing() {
        following?.cancel()
        following = nil
        stream?.close()
        stream = nil
    }

    private var following: Task<Void, Never>?
    private var stream: MonitorEventStream?
    private var refreshSoon: Task<Void, Never>?

    /// One event, kept (said when it's live).
    private func take(_ ev: MonitorEvent, say: Bool) {
        events.append(ev)
        if events.count > 500 { events.removeFirst(events.count - 500) }
        if say {
            let server = servers.first { $0.id == ev.serverId }?.name ?? ""
            announce(server.isEmpty ? ev.text : "\(server): \(ev.text)")
            if ev.kind == "message" { app.sounds.play(ev.messageKind == "user" ? .privateMessage : .channelMessage) }
        }
        // The servers' summaries (status, unread) a moment after events.
        refreshSoon?.cancel()
        refreshSoon = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            await self?.refresh()
        }
    }

    // MARK: Servers

    /// Monitors one of the saved servers. Returns why not, or nil.
    /// How a new monitored server starts: the fields the add screen fills in.
    struct NewServerSettings {
        var nickname: String
        var statusMessage: String
        var gender: Gender
        var channel: String
        var channelPassword: String
    }

    /// What adding `s` starts with (the owner's order): the nickname saved
    /// with the server, else the Monitor default, else General's; status
    /// message and gender the Monitor default, else General's (a default
    /// gender of None is General's); the server's own channel.
    func newServerSettings(for s: SavedServer) -> NewServerSettings {
        let d = Self.defaults
        let nickname = [s.nickname, d.nickname, app.nickname].first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""
        return NewServerSettings(nickname: nickname,
                                 statusMessage: d.statusMessage.isEmpty ? app.statusMessage : d.statusMessage,
                                 gender: d.gender ?? app.gender,
                                 channel: s.joinChannel, channelPassword: s.channelPassword)
    }

    /// Starts monitoring a saved server with these settings. Why not, or nil.
    func add(_ s: SavedServer, _ n: NewServerSettings) async -> String? {
        let input = MonitorServerInput(
            name: s.title, host: s.host, tcpPort: s.tcpPort, encrypted: s.encrypted,
            nickname: n.nickname, username: s.username,
            password: Passwords.get(s.id), statusMsg: n.statusMessage, statusMode: Gender.monitorBits(n.gender), channel: n.channel,
            channelPassword: n.channelPassword, enabled: true)
        guard own != nil || Self.loadOwn() != nil || hosted else { return "Choose a Monitor first, under Which Monitor." }
        guard let r = await call(registering: true, { try $0.addServer(server: input) }) else { return problem ?? "Your Monitor can't be reached." }
        switch r {
        case .success: await refresh(); return nil
        case .failure(let e): return NGAccountStore.words(e)
        }
    }

    // MARK: Default settings for new servers

    /// The Monitor's defaults (on this iPhone, synced with your settings):
    /// empty fields, and gender nil (None), use General's.
    struct Defaults {
        var nickname = ""
        var statusMessage = ""
        var gender: Gender?
    }

    static var defaults: Defaults {
        get {
            let u = UserDefaults.standard
            let g: Gender? = switch u.string(forKey: "monitorDefaultGender") {
            case "male": .male
            case "female": .female
            case "neutral": .neutral
            default: nil
            }
            return Defaults(nickname: u.string(forKey: "monitorDefaultNickname") ?? "",
                            statusMessage: u.string(forKey: "monitorDefaultStatus") ?? "", gender: g)
        }
        set {
            let u = UserDefaults.standard
            u.set(newValue.nickname, forKey: "monitorDefaultNickname")
            u.set(newValue.statusMessage, forKey: "monitorDefaultStatus")
            let g: String = switch newValue.gender {
            case .male?: "male"
            case .female?: "female"
            case .neutral?: "neutral"
            default: ""
            }
            u.set(g, forKey: "monitorDefaultGender")
        }
    }

    // MARK: Notification settings (kept by the Monitor)

    /// The Monitor's notification settings for this iPhone (TeamTalk NG's
    /// Monitor: this iPhone's own; your own Monitor: shared by the phones
    /// paired with it).
    struct NotificationPrefs: Codable, Equatable {
        var logins = "all"
        var logouts = "all"
        var watched: [String] = []
        var privateMessages = true
        var channelMessages = "mentions"
        var mentionWords: [String] = []
        var broadcasts = true
        var connection = true
        var mutedServers: [Int64] = []
        var mutedUntil: Int64?
        var ignored: [String] = []

        enum CodingKeys: String, CodingKey {
            case logins, logouts, watched, broadcasts, connection, ignored
            case privateMessages = "private_messages", channelMessages = "channel_messages", mentionWords = "mention_words"
            case mutedServers = "muted_servers", mutedUntil = "muted_until"
        }

        init() {}
        init(from d: Decoder) throws {
            let c = try d.container(keyedBy: CodingKeys.self)
            logins = (try? c.decode(String.self, forKey: .logins)) ?? "all"
            logouts = (try? c.decode(String.self, forKey: .logouts)) ?? "all"
            watched = (try? c.decode([String].self, forKey: .watched)) ?? []
            privateMessages = (try? c.decode(Bool.self, forKey: .privateMessages)) ?? true
            channelMessages = (try? c.decode(String.self, forKey: .channelMessages)) ?? "mentions"
            mentionWords = (try? c.decode([String].self, forKey: .mentionWords)) ?? []
            broadcasts = (try? c.decode(Bool.self, forKey: .broadcasts)) ?? true
            connection = (try? c.decode(Bool.self, forKey: .connection)) ?? true
            mutedServers = (try? c.decode([Int64].self, forKey: .mutedServers)) ?? []
            mutedUntil = try? c.decode(Int64.self, forKey: .mutedUntil)
            ignored = (try? c.decode([String].self, forKey: .ignored)) ?? []
        }
    }

    /// Reads them from the Monitor; nil when it can't be reached.
    func notificationPrefs() async -> NotificationPrefs? {
        guard case .success(let json)? = await call({ try $0.notificationPrefs() }) else { return nil }
        return try? JSONDecoder().decode(NotificationPrefs.self, from: Data(json.utf8))
    }

    /// Saves them on the Monitor. Why not, or nil.
    func setNotificationPrefs(_ p: NotificationPrefs) async -> String? {
        guard let d = try? JSONEncoder().encode(p) else { return "They couldn't be saved." }
        let json = String(decoding: d, as: UTF8.self)
        guard let r = await call(registering: true, { try $0.setNotificationPrefs(prefs: json) }) else { return problem ?? "Your Monitor can't be reached." }
        if case .failure(let e) = r { return NGAccountStore.words(e) }
        return nil
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

    /// A server's identity across Monitors: host (any case), port, username.
    nonisolated static func key(_ host: String, _ port: UInt16, _ username: String) -> String {
        "\(host.lowercased()):\(port):\(username)"
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
