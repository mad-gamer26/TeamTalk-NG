/*
 * Words and sounds for what a TeamTalk NG Monitor reports, for the server
 * events list and spoken announcements.
 */

import Foundation

/// Words for monitor events, for the activity list and speech.
enum MonitorEventText {
    static func describe(_ e: MonitorEvent, model: MonitorServerModel?) -> String? {
        switch e {
        case .connection(let status, let reason):
            if let reason, !reason.isEmpty, status != .loggedIn {
                return String(format: NSLocalizedString("Monitor %@: %@", comment: "monitor event"), status.text.lowercased(), reason)
            }
            return String(format: NSLocalizedString("Monitor %@", comment: "monitor event"), status.text.lowercased())
        case .loggedIn(let u):
            return String(format: NSLocalizedString("%@ logged in", comment: "monitor event"), u.displayName)
        case .loggedOut(let u):
            return String(format: NSLocalizedString("%@ logged out", comment: "monitor event"), u.displayName)
        case .joined(let u, _, let path):
            return String(format: NSLocalizedString("%@ joined %@", comment: "monitor event"), u.displayName, path)
        case .left(let u, _, let path):
            return String(format: NSLocalizedString("%@ left %@", comment: "monitor event"), u.displayName, path)
        case .userUpdated(let u):
            if !u.statusMsg.isEmpty {
                return String(format: NSLocalizedString("%@ is now: %@", comment: "monitor event"), u.displayName, u.statusMsg)
            }
            return nil
        case .channelAdded(let c):
            return String(format: NSLocalizedString("Channel %@ created", comment: "monitor event"), c.path)
        case .channelRemoved(_, let path):
            return String(format: NSLocalizedString("Channel %@ removed", comment: "monitor event"), path)
        case .message(let m):
            switch m.kind {
            case .user where m.outgoing:
                return String(format: NSLocalizedString("To %@: %@", comment: "monitor event"), m.to?.nickname ?? "", m.text)
            case .user:
                return String(format: NSLocalizedString("Private message from %@: %@", comment: "monitor event"), m.from.nickname, m.text)
            case .channel:
                return String(format: NSLocalizedString("%@ in %@: %@", comment: "monitor event"), m.from.nickname, m.channelPath ?? "", m.text)
            case .broadcast:
                return String(format: NSLocalizedString("Broadcast from %@: %@", comment: "monitor event"), m.from.nickname, m.text)
            }
        case .kicked(let by, let channelID):
            let who = by?.nickname ?? NSLocalizedString("Someone", comment: "monitor event")
            return channelID == nil
                ? String(format: NSLocalizedString("%@ kicked the monitor from the server", comment: "monitor event"), who)
                : String(format: NSLocalizedString("%@ kicked the monitor from its channel", comment: "monitor event"), who)
        case .myChannel(let id):
            if let c = model?.channel(id) {
                return String(format: NSLocalizedString("Monitor joined %@", comment: "monitor event"), c.path)
            }
            return NSLocalizedString("Monitor left its channel", comment: "monitor event")
        case .channelUpdated, .serverUpdated, .unknown:
            return nil
        }
    }

    /// The app's sound for an event, as for a live connection.
    static func sound(_ e: MonitorEvent) -> Sounds? {
        switch e {
        case .loggedIn: return .logged_IN
        case .loggedOut: return .logged_OUT
        case .message(let m) where !m.outgoing:
            switch m.kind {
            case .user: return .user_MSG
            case .channel: return .chan_MSG
            case .broadcast: return .broadcast_MSG
            }
        case .connection(let status, _) where status == .disconnected: return .srv_LOST
        default: return nil
        }
    }
}
