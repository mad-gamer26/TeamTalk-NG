/*
 * What a TeamTalk NG Monitor reports, as its API sends it, and a live copy
 * of one monitored server kept up to date from the monitor's events.
 */

import Foundation

struct MonitorUser: Codable, Equatable {
    var id: Int
    var nickname: String
    var username: String
    var statusMode: Int
    var statusMsg: String
    var clientName: String
    var version: String
    var userType: Int
    var channelId: Int?
    var packetProtocol: Int
    var ipAddress: String?

    var displayName: String {
        if !nickname.trimmingCharacters(in: .whitespaces).isEmpty { return nickname }
        if !username.isEmpty { return username }
        return String(format: NSLocalizedString("User %d", comment: "monitor"), id)
    }

    var isAdministrator: Bool { userType == 2 }
}

struct MonitorChannel: Codable, Equatable {
    var id: Int
    var parentId: Int
    var name: String
    var path: String
    var topic: String
    var passwordProtected: Bool
    var maxUsers: Int
    var channelType: Int
    var operators: [Int]
}

struct MonitorServerInfo: Codable, Equatable {
    /// Every server setting, by the server's own names (`motdraw`,
    /// `maxusers`, ...).
    var properties: [String: MonitorJSON]?
    var name: String
    var motd: String
    var version: String
    var `protocol`: String
    var maxUsers: Int
    var userTimeout: Int
}

struct MonitorMe: Codable, Equatable {
    var userId: Int
    var userType: Int
    var userRights: Int
    var channelId: Int?
}

struct MonitorSnapshot: Codable {
    var info: MonitorServerInfo
    var me: MonitorMe
    var channels: [MonitorChannel]
    var users: [MonitorUser]
}

enum MonitorConnectionStatus: String, Codable {
    case connecting
    case connected
    case loggedIn = "logged_in"
    case disconnected
    case loginFailed = "login_failed"
    case steppedAside = "stepped_aside"
    case paused

    var text: String {
        switch self {
        case .connecting: return NSLocalizedString("Connecting", comment: "monitor")
        case .connected: return NSLocalizedString("Logging in", comment: "monitor")
        case .loggedIn: return NSLocalizedString("Watching", comment: "monitor")
        case .disconnected: return NSLocalizedString("Disconnected", comment: "monitor")
        case .loginFailed: return NSLocalizedString("Login refused", comment: "monitor")
        case .steppedAside: return NSLocalizedString("Stepped aside", comment: "monitor")
        case .paused: return NSLocalizedString("Paused while you are connected", comment: "monitor")
        }
    }
}

struct MonitorServerSummary: Codable {
    var id: Int
    var name: String
    var host: String
    var tcpPort: Int
    var encrypted: Bool
    var enabled: Bool
    var nickname: String
    var username: String
    var status: MonitorConnectionStatus
    var reason: String?
    var statusSince: Int64
    var serverName: String
    var userCount: Int
    var unreadPrivateMessages: Int

    var displayName: String {
        if !name.isEmpty { return name }
        if !serverName.isEmpty { return serverName }
        return host
    }
}

struct MonitorServerView: Codable {
    var server: MonitorServerSummary
    var state: MonitorSnapshot
    var seq: Int64
}

struct MonitorUserRef: Codable, Equatable {
    var id: Int
    var nickname: String
    var username: String
}

enum MonitorMessageKind: String, Codable {
    case user
    case channel
    case broadcast
}

struct MonitorTextMessage: Codable {
    var kind: MonitorMessageKind
    var from: MonitorUserRef
    var to: MonitorUserRef?
    var channelId: Int?
    var channelPath: String?
    var text: String
    var outgoing: Bool
    var intercepted: Bool
}

enum MonitorEvent: Decodable {
    case connection(status: MonitorConnectionStatus, reason: String?)
    case loggedIn(MonitorUser)
    case loggedOut(MonitorUser)
    case joined(MonitorUser, channelId: Int, channelPath: String)
    case left(MonitorUser, channelId: Int, channelPath: String)
    case userUpdated(MonitorUser)
    case channelAdded(MonitorChannel)
    case channelUpdated(MonitorChannel)
    case channelRemoved(channelId: Int, channelPath: String)
    case serverUpdated(MonitorServerInfo)
    case message(MonitorTextMessage)
    case kicked(by: MonitorUserRef?, channelId: Int?)
    case myChannel(channelId: Int?)
    case unknown

    private enum Keys: String, CodingKey {
        case type, status, reason, user, channelId, channelPath, channel, info, message, by
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "connection":
            self = .connection(status: try c.decode(MonitorConnectionStatus.self, forKey: .status), reason: try c.decodeIfPresent(String.self, forKey: .reason))
        case "logged_in": self = .loggedIn(try c.decode(MonitorUser.self, forKey: .user))
        case "logged_out": self = .loggedOut(try c.decode(MonitorUser.self, forKey: .user))
        case "joined":
            self = .joined(try c.decode(MonitorUser.self, forKey: .user), channelId: try c.decode(Int.self, forKey: .channelId), channelPath: try c.decode(String.self, forKey: .channelPath))
        case "left":
            self = .left(try c.decode(MonitorUser.self, forKey: .user), channelId: try c.decode(Int.self, forKey: .channelId), channelPath: try c.decode(String.self, forKey: .channelPath))
        case "user_updated": self = .userUpdated(try c.decode(MonitorUser.self, forKey: .user))
        case "channel_added": self = .channelAdded(try c.decode(MonitorChannel.self, forKey: .channel))
        case "channel_updated": self = .channelUpdated(try c.decode(MonitorChannel.self, forKey: .channel))
        case "channel_removed":
            self = .channelRemoved(channelId: try c.decode(Int.self, forKey: .channelId), channelPath: try c.decode(String.self, forKey: .channelPath))
        case "server_updated": self = .serverUpdated(try c.decode(MonitorServerInfo.self, forKey: .info))
        case "message": self = .message(try c.decode(MonitorTextMessage.self, forKey: .message))
        case "kicked":
            self = .kicked(by: try c.decodeIfPresent(MonitorUserRef.self, forKey: .by), channelId: try c.decodeIfPresent(Int.self, forKey: .channelId))
        case "my_channel": self = .myChannel(channelId: try c.decodeIfPresent(Int.self, forKey: .channelId))
        default: self = .unknown
        }
    }
}

struct MonitorStoredEvent: Decodable {
    var seq: Int64
    var serverId: Int
    /// Unix milliseconds.
    var time: Int64
    var event: MonitorEvent

    var date: Date { Date(timeIntervalSince1970: TimeInterval(time) / 1000) }
}

/// A private conversation, as in TeamTalk: with one user ID for as long as
/// that person stays logged in.
struct MonitorConversation: Codable {
    var id: Int
    var serverId: Int
    var userId: Int
    var nickname: String
    var username: String
    /// Still logged in with this user ID, so replies reach them.
    var active: Bool
    var lastText: String
    var lastTime: Int64
    var lastOutgoing: Bool
    var unread: Int
}

struct MonitorPrivateMessage: Codable {
    var id: Int
    var conversationId: Int
    var serverId: Int
    var outgoing: Bool
    var text: String
    var time: Int64
    var read: Bool

    var date: Date { Date(timeIntervalSince1970: TimeInterval(time) / 1000) }
}

/// Who a private message window is with: a user ID, as in TeamTalk, and
/// (once known) the conversation with them during this login.
struct MonitorPrivateChat {
    var userID: Int
    var conversationID: Int?
    var nickname: String
}

/// What this device is notified about by one monitor.
struct MonitorPrefs: Codable, Equatable {
    /// "all", "watched" or "none".
    var logins = "all"
    var logouts = "all"
    var watched: [String] = []
    var privateMessages = true
    /// "all", "mentions" or "none".
    var channelMessages = "mentions"
    var mentionWords: [String] = []
    var broadcasts = true
    var connection = true
    var mutedServers: [Int] = []
    var mutedUntil: Int64?
    var ignored: [String] = []
}

/// Settings of a server the monitor watches, as sent to it.
struct MonitorServerInput: Encodable {
    var name: String
    var host: String
    var tcpPort: Int
    var encrypted: Bool
    var nickname: String
    var username: String
    var password: String
    var statusMsg: String
    /// The monitor's gender, as status mode bits (see MonitorGender).
    var statusMode: Int
    var channel: String
    var channelPassword: String
    var enabled: Bool
}

/// A monitor's gender, which TeamTalk carries in the status mode, in the
/// order Settings shows them (male, female, neutral).
enum MonitorGender {
    static let female = 0x100
    static let neutral = 0x1000

    static func statusMode(index: Int) -> Int {
        switch index {
        case 1: return female
        case 2: return neutral
        default: return 0
        }
    }

    static func index(statusMode: Int) -> Int {
        if statusMode & female != 0 { return 1 }
        if statusMode & neutral != 0 { return 2 }
        return 0
    }
}

/// A live copy of one monitored server.
final class MonitorServerModel {
    let serverID: Int
    private(set) var summary: MonitorServerSummary
    private(set) var snapshot: MonitorSnapshot
    private(set) var seq: Int64

    init(view: MonitorServerView) {
        serverID = view.server.id
        summary = view.server
        snapshot = view.state
        seq = view.seq
    }

    var me: MonitorMe { snapshot.me }

    var users: [MonitorUser] {
        snapshot.users.filter { $0.id != snapshot.me.userId }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    var channels: [MonitorChannel] {
        snapshot.channels.sorted { $0.path.localizedCaseInsensitiveCompare($1.path) == .orderedAscending }
    }

    func channel(_ id: Int?) -> MonitorChannel? {
        guard let id else { return nil }
        return snapshot.channels.first { $0.id == id }
    }

    func user(_ id: Int) -> MonitorUser? {
        snapshot.users.first { $0.id == id }
    }

    func users(in channelID: Int) -> [MonitorUser] {
        users.filter { $0.channelId == channelID }
    }

    /// Bring the copy up to date; events it already reflects are skipped.
    func apply(_ e: MonitorStoredEvent) {
        guard e.serverId == serverID, e.seq > seq else { return }
        seq = e.seq
        switch e.event {
        case .connection(let status, let reason):
            summary.status = status
            summary.reason = reason
            if status != .loggedIn {
                snapshot.users = []
                snapshot.channels = []
                snapshot.me.channelId = nil
            }
        case .loggedIn(let u), .userUpdated(let u):
            upsert(u)
        case .loggedOut(let u):
            snapshot.users.removeAll { $0.id == u.id }
        case .joined(var u, let channelID, _):
            u.channelId = channelID
            upsert(u)
        case .left(var u, _, _):
            u.channelId = nil
            upsert(u)
        case .channelAdded(let c), .channelUpdated(let c):
            snapshot.channels.removeAll { $0.id == c.id }
            snapshot.channels.append(c)
        case .channelRemoved(let id, _):
            snapshot.channels.removeAll { $0.id == id }
        case .serverUpdated(let info):
            snapshot.info = info
            summary.serverName = info.name
        case .myChannel(let id):
            snapshot.me.channelId = id
        case .kicked(_, let channelID):
            if channelID != nil { snapshot.me.channelId = nil }
        case .message, .unknown:
            break
        }
        summary.userCount = snapshot.users.count
    }

    private func upsert(_ u: MonitorUser) {
        if let i = snapshot.users.firstIndex(where: { $0.id == u.id }) {
            snapshot.users[i] = u
        } else {
            snapshot.users.append(u)
        }
    }
}
