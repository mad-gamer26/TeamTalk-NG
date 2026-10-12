/*
 * Talking to the TeamTalk NG monitor service at mad-gamer.com: its HTTP
 * API, a WebSocket that keeps this install's monitored servers up to date
 * while the app is open, and monitoring servers from the saved list.
 */

import Foundation
import UIKit

extension Notification.Name {
    /// The monitored servers, the connection to the service, or a
    /// server's state changed.
    static let monitorChanged = Notification.Name("MonitorChanged")
    /// One event from the monitor service: `userInfo["event"]` (a
    /// `MonitorStoredEvent`).
    /// `userInfo["catchUp"]` is true for events that happened while the app
    /// was away: push notifications already told of them, so they update
    /// screens but play no sound and are not spoken.
    static let monitorEvent = Notification.Name("MonitorEvent")
    /// A server's whole state was loaded again: `userInfo["server"]`.
    static let monitorServerReloaded = Notification.Name("MonitorServerReloaded")
}

enum MonitorError: LocalizedError {
    case refused(String)
    case notPaired
    case unreachable(String)
    /// Monitors belong to an NG Account; this iPhone isn't signed in.
    case needsAccount

    var errorDescription: String? {
        switch self {
        case .refused(let m): return m
        case .notPaired: return NSLocalizedString("The monitor service no longer knows this phone. Monitor a server again to sign up again.", comment: "monitor")
        case .unreachable(let m): return String(format: NSLocalizedString("Could not reach the monitor service: %@", comment: "monitor"), m)
        case .needsAccount: return NSLocalizedString("Sign in to your NG Account to monitor servers.", comment: "monitor")
        }
    }
}

/// Where the monitor service runs.
enum MonitorService {
    static let baseURL = URL(string: "https://ttmonitor.mad-gamer.com")!
}

struct MonitorRegistration: Decodable {
    var deviceId: Int
    var token: String
    var pushKey: String
    var name: String
}

/// The monitor's API, for one pairing.
struct MonitorAPI {
    let account: MonitorAccount

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        return e
    }()

    private static let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 20
        c.waitsForConnectivity = false
        return URLSession(configuration: c)
    }()

    /// Sign this install up with the service.
    static func register(baseURL: URL, deviceName: String) async throws -> MonitorRegistration {
        var req = URLRequest(url: baseURL.appendingPathComponent("v1/register"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["device_name": deviceName])
        return try decoder.decode(MonitorRegistration.self, from: try await perform(req))
    }

    private static func perform(_ req: URLRequest) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            throw MonitorError.unreachable(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw MonitorError.unreachable("no response") }
        if http.statusCode == 401 { throw MonitorError.notPaired }
        guard (200..<300).contains(http.statusCode) else {
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            throw MonitorError.refused(message ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode))
        }
        return data
    }

    private func request(_ method: String, _ path: String, query: [URLQueryItem] = [], body: Data? = nil) async throws -> Data {
        var comps = URLComponents(url: account.baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { comps.queryItems = query }
        var req = URLRequest(url: comps.url!)
        req.httpMethod = method
        req.setValue("Bearer \(account.token)", forHTTPHeaderField: "Authorization")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = body
        }
        return try await Self.perform(req)
    }

    private func json(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object)
    }

    func servers() async throws -> [MonitorServerSummary] {
        struct R: Decodable { var servers: [MonitorServerSummary] }
        return try Self.decoder.decode(R.self, from: try await request("GET", "v1/servers")).servers
    }

    func server(_ id: Int) async throws -> MonitorServerView {
        try Self.decoder.decode(MonitorServerView.self, from: try await request("GET", "v1/servers/\(id)"))
    }

    /// A server's settings, apart from its passwords.
    struct ServerConfig: Decodable {
        var username: String
        var statusMsg: String
        var statusMode: Int?
        var channel: String
    }

    func serverConfig(_ id: Int) async throws -> ServerConfig {
        try Self.decoder.decode(ServerConfig.self, from: try await request("GET", "v1/servers/\(id)/config"))
    }

    func addServer(_ s: MonitorServerInput) async throws {
        _ = try await request("POST", "v1/servers", body: try Self.encoder.encode(s))
    }

    func updateServer(_ id: Int, _ s: MonitorServerInput) async throws {
        _ = try await request("PUT", "v1/servers/\(id)", body: try Self.encoder.encode(s))
    }

    func removeServer(_ id: Int) async throws {
        _ = try await request("DELETE", "v1/servers/\(id)")
    }

    /// Manage the server (accounts, bans, settings, statistics): what the
    /// server answered, one object per line, its name under `type`.
    func admin(server: Int, command: String, params: [String: Any] = [:]) async throws -> [[String: MonitorJSON]] {
        struct R: Decodable { var lines: [[String: MonitorJSON]] }
        let data = try await request("POST", "v1/servers/\(server)/admin", body: try json(["command": command, "params": params]))
        // Plain keys: these are the server's own field names.
        return try JSONDecoder().decode(R.self, from: data).lines
    }

    /// Stop monitoring a server for up to `minutes`.
    func pause(server: Int, minutes: Int) async throws {
        _ = try await request("POST", "v1/servers/\(server)/pause", body: try json(["minutes": minutes]))
    }

    func resume(server: Int) async throws {
        _ = try await request("DELETE", "v1/servers/\(server)/pause")
    }

    /// To someone by user ID. With `conversationID`, only while that
    /// conversation lasts (the person has not logged out since).
    func sendPrivateMessage(server: Int, userID: Int, conversationID: Int? = nil, text: String) async throws {
        var body: [String: Any] = ["to": "user", "user_id": userID, "text": text]
        if let conversationID { body["conversation_id"] = conversationID }
        _ = try await request("POST", "v1/servers/\(server)/messages", body: try json(body))
    }



    /// To a channel, or the monitor's own channel when `channelID` is nil.
    func sendChannelMessage(server: Int, channelID: Int?, text: String) async throws {
        var body: [String: Any] = ["to": "channel", "text": text]
        if let channelID { body["channel_id"] = channelID }
        _ = try await request("POST", "v1/servers/\(server)/messages", body: try json(body))
    }

    func sendBroadcast(server: Int, text: String) async throws {
        _ = try await request("POST", "v1/servers/\(server)/messages", body: try json(["to": "broadcast", "text": text]))
    }

    /// `action` is one of the monitor's actions: join, leave, move, kick,
    /// ban, nickname, status.
    func act(server: Int, _ action: String, _ fields: [String: Any] = [:]) async throws {
        var body = fields
        body["action"] = action
        _ = try await request("POST", "v1/servers/\(server)/actions", body: try json(body))
    }

    func conversations(server: Int? = nil) async throws -> [MonitorConversation] {
        struct R: Decodable { var conversations: [MonitorConversation] }
        let q = server.map { [URLQueryItem(name: "server_id", value: String($0))] } ?? []
        return try Self.decoder.decode(R.self, from: try await request("GET", "v1/conversations", query: q)).conversations
    }

    /// A conversation, its messages, and the newest event the messages
    /// already include (later events are new).
    func messages(server: Int, conversation: Int) async throws -> (MonitorConversation, [MonitorPrivateMessage], Int64) {
        struct R: Decodable { var conversation: MonitorConversation; var messages: [MonitorPrivateMessage]; var seq: Int64 }
        let path = "v1/servers/\(server)/conversations/\(conversation)/messages"
        let r = try Self.decoder.decode(R.self, from: try await request("GET", path, query: [URLQueryItem(name: "limit", value: "300")]))
        return (r.conversation, r.messages, r.seq)
    }

    /// Delete a conversation and its messages from the monitor.
    func deleteConversation(server: Int, conversation: Int) async throws {
        _ = try await request("DELETE", "v1/servers/\(server)/conversations/\(conversation)")
    }

    func markRead(server: Int, conversation: Int) async throws {
        _ = try await request("POST", "v1/servers/\(server)/conversations/\(conversation)/read")
    }

    func recentEvents(server: Int, limit: Int = 200) async throws -> [MonitorStoredEvent] {
        struct R: Decodable { var events: [MonitorStoredEvent] }
        let q = [URLQueryItem(name: "server_id", value: String(server)), URLQueryItem(name: "limit", value: String(limit))]
        return try Self.decoder.decode(R.self, from: try await request("GET", "v1/events", query: q)).events
    }

    func prefs() async throws -> MonitorPrefs {
        try Self.decoder.decode(MonitorPrefs.self, from: try await request("GET", "v1/me/prefs"))
    }

    func setPrefs(_ p: MonitorPrefs) async throws {
        _ = try await request("PUT", "v1/me/prefs", body: try Self.encoder.encode(p))
    }

    func registerPush(deviceToken: String?, sandbox: Bool) async throws {
        var body: [String: Any] = ["sandbox": sandbox, "app_ref": account.ref, "install_id": MonitorInstall.id]
        body["apns_token"] = deviceToken ?? NSNull()
        _ = try await request("PUT", "v1/me/push", body: try json(body))
    }

    /// Fold another sign-up of this person (by its secret token) into this
    /// one: its servers, conversations and phones.
    func merge(otherToken: String) async throws {
        _ = try await request("POST", "v1/me/merge", body: try json(["token": otherToken]))
    }

    func unpair() async throws {
        _ = try await request("DELETE", "v1/me")
    }

    func webSocketRequest(since: Int64?) -> URLRequest {
        var comps = URLComponents(url: account.baseURL.appendingPathComponent("v1/ws"), resolvingAgainstBaseURL: false)!
        comps.scheme = comps.scheme == "https" ? "wss" : "ws"
        if let since { comps.queryItems = [URLQueryItem(name: "since", value: String(since))] }
        var req = URLRequest(url: comps.url!)
        req.setValue("Bearer \(account.token)", forHTTPHeaderField: "Authorization")
        return req
    }
}

/// One paired monitor while the app is open: its servers, the live state of
/// the servers being looked at, and the WebSocket keeping them current.
final class MonitorConnection {
    private(set) var account: MonitorAccount
    private(set) var servers: [MonitorServerSummary] = []
    private(set) var models: [Int: MonitorServerModel] = [:]
    private(set) var lastError: String?
    private(set) var online = false

    private var task: URLSessionWebSocketTask?
    private var lastSeq: Int64?
    /// Between reconnecting and the service's "ready": the events coming
    /// are the ones missed while away.
    private var catchingUp = false
    private var retryDelay: TimeInterval = 1
    private var running = false
    private var generation = 0

    var api: MonitorAPI { MonitorAPI(account: account) }

    init(account: MonitorAccount) {
        self.account = account
    }

    func update(account: MonitorAccount) {
        self.account = account
    }

    func start() {
        guard !running else { return }
        running = true
        Task { await refreshServers() }
        connect()
    }

    func stop() {
        running = false
        generation += 1
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        online = false
    }

    @MainActor
    func refreshServers() async {
        do {
            servers = try await api.servers()
            prefs = try? await api.prefs()
            lastError = nil
        } catch MonitorError.notPaired where account.isNGAccount {
            // Signed out elsewhere, password reset, or the account deleted.
            NGAccountCenter.shared.sessionEnded()
            return
        } catch {
            lastError = error.localizedDescription
        }
        changed()
    }

    /// The notification settings, as of the last refresh.
    var prefs: MonitorPrefs?

    /// Muted by hand (not just for being connected to it live).
    func isMutedByHand(_ serverID: Int) -> Bool {
        (prefs?.mutedServers.contains(serverID) ?? false) && !MonitorCenter.shared.isLiveMuted(serverID)
    }

    /// The live state of a server, loading it the first time.
    @MainActor
    func model(for serverID: Int) async throws -> MonitorServerModel {
        if let m = models[serverID] { return m }
        let view = try await api.server(serverID)
        let m = MonitorServerModel(view: view)
        models[serverID] = m
        // Before the WebSocket is up, follow events from this snapshot on.
        if lastSeq == nil { lastSeq = view.seq }
        return m
    }

    @MainActor
    private func reloadModels() async {
        for id in Array(models.keys) {
            if let view = try? await api.server(id) {
                models[id] = MonitorServerModel(view: view)
                NotificationCenter.default.post(name: .monitorServerReloaded, object: self, userInfo: ["server": id])
            }
        }
        await refreshServers()
    }

    private func connect() {
        guard running else { return }
        generation += 1
        let gen = generation
        catchingUp = lastSeq != nil
        let t = URLSession.shared.webSocketTask(with: api.webSocketRequest(since: lastSeq))
        task = t
        t.resume()
        receive(t, gen)
    }

    private func receive(_ t: URLSessionWebSocketTask, _ gen: Int) {
        t.receive { [weak self] result in
            DispatchQueue.main.async {
                guard let self, gen == self.generation else { return }
                switch result {
                case .success(let message):
                    self.retryDelay = 1
                    if case .string(let text) = message {
                        self.handle(text)
                    }
                    self.receive(t, gen)
                case .failure(let error):
                    self.online = false
                    self.lastError = error.localizedDescription
                    self.changed()
                    self.scheduleReconnect()
                }
            }
        }
    }

    private func scheduleReconnect() {
        guard running else { return }
        let delay = retryDelay
        retryDelay = min(retryDelay * 2, 30)
        let gen = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, gen == self.generation, self.running else { return }
            Task { @MainActor in
                // Reconnecting also catches up on servers added meanwhile.
                await self.refreshServers()
                self.connect()
            }
        }
    }

    private struct Envelope: Decodable {
        var type: String
        var seq: Int64?
        var event: MonitorStoredEvent?
    }

    private func handle(_ text: String) {
        guard let data = text.data(using: .utf8),
              let env = try? MonitorAPI.decoder.decode(Envelope.self, from: data) else { return }
        switch env.type {
        case "ready":
            catchingUp = false
            online = true
            lastError = nil
            if lastSeq == nil { lastSeq = env.seq }
            changed()
        case "reset":
            lastSeq = env.seq
            Task { @MainActor in await self.reloadModels() }
        case "sync":
            // The NG Account's servers, settings or sound packs changed on
            // another device.
            MainActor.assumeIsolated { NGAccountCenter.shared.remoteChange() }
        case "event":
            guard let e = env.event else { return }
            lastSeq = max(lastSeq ?? 0, e.seq)
            models[e.serverId]?.apply(e)
            // After logging in again the server sends its whole state at
            // once, which the monitor does not repeat as events: reload it.
            if case .connection(let status, _) = e.event, status == .loggedIn, models[e.serverId] != nil {
                let id = e.serverId
                Task { @MainActor in
                    if let view = try? await self.api.server(id) {
                        self.models[id] = MonitorServerModel(view: view)
                        self.changed()
                        NotificationCenter.default.post(name: .monitorServerReloaded, object: self, userInfo: ["server": id])
                    }
                }
            }
            if case .connection(let status, let reason) = e.event, let i = servers.firstIndex(where: { $0.id == e.serverId }) {
                servers[i].status = status
                servers[i].reason = reason
            }
            if case .message(let m) = e.event, m.kind == .user, !m.outgoing, !m.intercepted,
               let i = servers.firstIndex(where: { $0.id == e.serverId }) {
                servers[i].unreadPrivateMessages += 1
            }
            if let m = models[e.serverId], let i = servers.firstIndex(where: { $0.id == e.serverId }) {
                servers[i].userCount = m.summary.userCount
            }
            // Missed while away (or simply old): already notified.
            let catchUp = catchingUp || Date().timeIntervalSince(e.date) > 30
            NotificationCenter.default.post(name: .monitorEvent, object: self, userInfo: ["ref": account.ref, "event": e, "catchUp": catchUp])
            changed()
        default:
            break
        }
    }

    private func changed() {
        NotificationCenter.default.post(name: .monitorChanged, object: self, userInfo: ["ref": account.ref])
    }
}

/// This install's monitored servers, connected to the service while the
/// app is in the foreground.
final class MonitorCenter {
    static let shared = MonitorCenter()

    /// The connection to the service, once this install has signed up.
    private(set) var connection: MonitorConnection?
    private var active = false
    /// Live servers whose monitors' notifications are held back, renewed
    /// until disconnecting.
    private var liveTimers: [String: Timer] = [:]


    private init() {
        // Nothing is connected live when the app starts.
        MonitorLiveServers.clear()
        reload()
        NotificationCenter.default.addObserver(self, selector: #selector(didBecomeActive), name: UIApplication.didBecomeActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(didEnterBackground), name: UIApplication.didEnterBackgroundNotification, object: nil)
    }

    func connection(ref: String) -> MonitorConnection? {
        connection?.account.ref == ref ? connection : nil
    }

    /// Follow the NG Account this iPhone is signed in to: monitors belong
    /// to the account. (Sign-ups from before NG Account only move their
    /// monitors into an account when signing in.)
    func reload() {
        let account = NGAccountCenter.shared.signIn
        if let account {
            if let connection, connection.account.ref == account.ref {
                connection.update(account: account)
            } else {
                connection?.stop()
                connection = MonitorConnection(account: account)
            }
        } else {
            connection?.stop()
            connection = nil
        }
        if active || UIApplication.shared.applicationState == .active {
            active = true
            connection?.start()
        }
        NotificationCenter.default.post(name: .monitorChanged, object: nil)
    }

    @objc private func didBecomeActive() {
        active = true
        // iCloud Keychain may have brought a sign-up from before NG Account.
        Task { @MainActor in await NGAccountCenter.shared.absorbOldSignUps() }
        // iCloud Keychain may have brought a sign-up meanwhile.
        reload()
        connection?.start()
        // Sound events may have been changed meanwhile.
        MonitorNotificationSounds.refresh()
    }

    @objc private func didEnterBackground() {
        // Push notifications take over in the background.
        active = false
        connection?.stop()
    }

    /// The connection to the NG Account's monitors.
    @MainActor
    func ensureSignedUp() async throws -> MonitorConnection {
        reload()
        guard let connection else { throw MonitorError.needsAccount }
        return connection
    }

    /// The monitor's settings for a saved server: its login, under a
    /// nickname that shows it is the monitor.
    static func input(for server: Server) -> MonitorServerInput {
        // The nickname a live connection would use: the saved server's, or
        // else the one in Settings.
        var nickname = server.nickname.trimmingCharacters(in: .whitespaces)
        if nickname.isEmpty {
            nickname = (UserDefaults.standard.string(forKey: PREF_GENERAL_NICKNAME) ?? "").trimmingCharacters(in: .whitespaces)
        }
        return MonitorServerInput(
            name: server.name.isEmpty ? server.ipaddr : server.name,
            host: server.ipaddr,
            tcpPort: server.tcpport,
            encrypted: server.encrypted,
            nickname: nickname.isEmpty ? NSLocalizedString("Monitor", comment: "monitor server default nickname")
                : String(format: NSLocalizedString("%@ (Monitor)", comment: "monitor nickname: the person's nickname"), nickname),
            username: server.username,
            password: server.password,
            statusMsg: "",
            statusMode: MonitorGender.statusMode(index: preferredGenderIndex()),
            channel: "",
            channelPassword: "",
            enabled: true)
    }

    /// The monitored server a saved server matches, if any.
    func monitored(_ server: Server) -> MonitorServerSummary? {
        connection?.servers.first {
            $0.host.caseInsensitiveCompare(server.ipaddr) == .orderedSame && $0.tcpPort == server.tcpport && $0.username == server.username
        }
    }

    /// Start monitoring a server with these settings.
    @MainActor
    func monitor(_ input: MonitorServerInput) async throws {
        let connection = try await ensureSignedUp()
        try await connection.api.addServer(input)
        await connection.refreshServers()
    }

    /// The monitored servers at a live server's address (whatever account
    /// the monitor uses there).
    private func monitoredAtAddress(of server: Server) -> [MonitorServerSummary] {
        let host = server.ipaddr.trimmingCharacters(in: .whitespacesAndNewlines)
        return connection?.servers.filter {
            $0.host.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(host) == .orderedSame && $0.tcpPort == server.tcpport
        } ?? []
    }

    /// While connected to a server live, the monitor keeps watching it, but
    /// sends no notifications for it: the app mutes it in the notification
    /// settings on the monitor, and unmutes it on disconnecting. Only
    /// servers muted this way are unmuted, so mutes chosen by hand stay.
    @MainActor
    func connectedLive(to server: Server) {
        let key = "\(server.ipaddr.lowercased()):\(server.tcpport)"
        Task { @MainActor in
            await connection?.refreshServers()
            guard let ref = connection?.account.ref else { return }
            let monitored = monitoredAtAddress(of: server)
            guard !monitored.isEmpty else { return }
            monitored.forEach { MonitorLiveServers.mark(ref: ref, serverID: $0.id) }
            liveTimers[key]?.invalidate()
            liveTimers[key] = Timer.scheduledTimer(withTimeInterval: 5 * 60, repeats: true) { _ in
                monitored.forEach { MonitorLiveServers.mark(ref: ref, serverID: $0.id) }
            }
            await setLiveMuted(monitored.map(\.id), muted: true)
        }
    }

    @MainActor
    func disconnectedLive(from server: Server) {
        let key = "\(server.ipaddr.lowercased()):\(server.tcpport)"
        liveTimers.removeValue(forKey: key)?.invalidate()
        guard let ref = connection?.account.ref else { return }
        let ids = monitoredAtAddress(of: server).map(\.id)
        ids.forEach { MonitorLiveServers.unmark(ref: ref, serverID: $0) }
        guard !ids.isEmpty else { return }
        // Unmute even if the app goes to the background right away.
        let background = UIApplication.shared.beginBackgroundTask(withName: "MonitorUnmute")
        Task { @MainActor in
            await setLiveMuted(ids, muted: false)
            UIApplication.shared.endBackgroundTask(background)
        }
    }

    /// Servers this app muted for being connected live (not by hand).
    private static let liveMutedKey = "MonitorLiveMutedServers"

    private var liveMuted: Set<Int> {
        get { Set(MonitorInstall.groupDefaults.array(forKey: Self.liveMutedKey) as? [Int] ?? []) }
        set { MonitorInstall.groupDefaults.set(Array(newValue), forKey: Self.liveMutedKey) }
    }

    func isLiveMuted(_ serverID: Int) -> Bool {
        liveMuted.contains(serverID)
    }

    /// Mute or unmute one server's notifications by hand. The monitor keeps
    /// watching it. A choice made by hand is never undone by connecting or
    /// disconnecting live.
    @MainActor
    func setMuted(_ serverID: Int, _ muted: Bool) async throws {
        guard let connection else { return }
        var prefs = try await connection.api.prefs()
        prefs.mutedServers.removeAll { $0 == serverID }
        if muted {
            prefs.mutedServers.append(serverID)
        }
        try await connection.api.setPrefs(prefs)
        var mine = liveMuted
        mine.remove(serverID)
        liveMuted = mine
        connection.prefs = prefs
        NotificationCenter.default.post(name: .monitorChanged, object: connection)
    }

    /// Mute or unmute servers on the monitor for being connected live.
    @MainActor
    private func setLiveMuted(_ ids: [Int], muted: Bool) async {
        guard let api = connection?.api, var prefs = try? await api.prefs() else { return }
        var mine = liveMuted
        for id in ids {
            if muted {
                // Muted by hand already: leave it to the person.
                guard !prefs.mutedServers.contains(id) else { continue }
                prefs.mutedServers.append(id)
                mine.insert(id)
            } else if mine.contains(id), let ref = connection?.account.ref, !MonitorLiveServers.isLive(ref: ref, serverID: id) {
                // (Still connected live, say a connection made right at
                // launch: stays muted.)
                prefs.mutedServers.removeAll { $0 == id }
                mine.remove(id)
            }
        }
        do {
            try await api.setPrefs(prefs)
            liveMuted = mine
        } catch {
            print("Could not \(muted ? "mute" : "unmute") servers connected live: \(error.localizedDescription)")
        }
    }

    /// Nothing is connected live when the app starts: unmute what was
    /// muted for being connected (the app may have been closed then).
    @MainActor
    func unmuteLeftoverLiveServers() {
        let ids = Array(liveMuted)
        guard !ids.isEmpty, connection != nil else { return }
        Task { @MainActor in await setLiveMuted(ids, muted: false) }
    }

    private static let genderGivenKey = "MonitorGenderGiven"

    /// Monitors set up before they had a gender log in as male: give them
    /// the gender in Settings, once. The service sets it without logging
    /// in again.
    @MainActor
    func giveMonitorsGender() {
        let defaults = MonitorInstall.groupDefaults
        guard !defaults.bool(forKey: Self.genderGivenKey), let connection else { return }
        let mode = MonitorGender.statusMode(index: preferredGenderIndex())
        Task { @MainActor in
            do {
                if mode != 0 {
                    for s in try await connection.api.servers() {
                        let c = try await connection.api.serverConfig(s.id)
                        guard (c.statusMode ?? 0) == 0 else { continue }
                        try await connection.api.updateServer(s.id, MonitorServerInput(
                            name: s.name, host: s.host, tcpPort: s.tcpPort, encrypted: s.encrypted,
                            nickname: s.nickname, username: c.username,
                            password: "", // unchanged
                            statusMsg: c.statusMsg, statusMode: mode,
                            channel: c.channel,
                            channelPassword: "", // unchanged
                            enabled: s.enabled))
                    }
                }
                defaults.set(true, forKey: Self.genderGivenKey)
            } catch {
                print("Could not give monitors a gender: \(error.localizedDescription)")
            }
        }
    }

    /// Stop monitoring every server. The NG Account stays signed in.
    @MainActor
    func stopEverything() async throws {
        guard let connection else { return }
        try await connection.api.unpair()
        await connection.refreshServers()
    }
}
