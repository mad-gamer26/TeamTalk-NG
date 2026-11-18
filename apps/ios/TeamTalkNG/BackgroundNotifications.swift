import SwiftUI
import UIKit
import UserNotifications

/// Notifications while TeamTalk NG is in the background (the desktop's
/// popups): a server's events, each on or off by itself (Settings →
/// Display → Notifications). Titled with the server's name; the text is the
/// event's name, then what happened ("Private message from Matthew: Hi").
/// Tapping one opens the server: a channel message on its Chat tab, a
/// private message in its conversation.
enum BackgroundNotifications {
    /// The events that can notify: what others do and what happens to the
    /// connection, not what I do myself.
    static let events: [SpeechEvent] = SpeechEvent.allCases.filter {
        ![.privateMessageSent, .typing, .typingAnywhere, .channelMessageSent, .broadcastMessageSent,
          .menuActions, .voiceTransmission, .videoTransmission, .desktopSharing].contains($0)
    }

    /// The notification's text for an event: its name, then what happened.
    @MainActor static func body(_ e: SpeechEvent, _ v: [String: String]) -> String? {
        let user = v["user"] ?? v["username"] ?? ""
        let message = v["message"] ?? ""
        switch e {
        case .privateMessage: return "Private message from \(user): \(message)"
        case .channelMessage: return "Channel message from \(user): \(message)"
        case .broadcastMessage: return "Broadcast message from \(user): \(message)"
        case .loggedIn: return "\(user) logged in"
        case .loggedOut: return "\(user) logged out"
        case .joinedMine, .leftMine, .questionMode: return "\(e.label): \(user)"
        case .joined, .left: return "\(e.label): \(user), \(v["channel"] ?? "")"
        case .fileAdded: return "\(e.label): \(v["filename"] ?? ""), by \(user)"
        case .fileRemoved: return "\(e.label): \(v["file"] ?? ""), by \(user)"
        default:
            // Fixed words (connectivity, others' subscriptions, classroom).
            let text = message.isEmpty ? (AppModel.shared?.speech.text(e, v) ?? "") : message
            return text.isEmpty ? nil : "\(e.label): \(text)"
        }
    }

    /// What tapping it opens.
    enum Opens: String { case server, chat, conversation }

    @MainActor static func post(server: SavedServer, title: String, body: String, opens: Opens, userId: Int32? = nil) {
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        c.sound = nil
        c.threadIdentifier = "server-\(server.id.uuidString)"
        var open: [String: Any] = ["server": server.id.uuidString, "opens": opens.rawValue]
        if let userId { open["user_id"] = Int(userId) }
        c.userInfo = ["ttngOpen": open]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
    }

    /// A notification was tapped: the screen it opens.
    @MainActor static func open(_ info: [AnyHashable: Any]) {
        guard let model = AppModel.shared else { return }
        if let o = info["ttngOpen"] as? [String: Any], let id = o["server"] as? String {
            let opens = Opens(rawValue: o["opens"] as? String ?? "") ?? .server
            let user = (o["user_id"] as? NSNumber).map { Int32(truncating: $0) }
            model.openFromNotification(serverId: id, opens: opens, userId: user)
            return
        }
        // The Monitor's: its server, as if connected.
        let data = (info["data"] as? [String: Any])
            ?? (((info["ttng"] as? [String: Any])?["content"] as? [String: Any])?["data"] as? [String: Any])
        guard let d = data, let monitorId = (d["server_id"] as? NSNumber)?.int64Value else { return }
        let opens: Opens = switch d["event"] as? String {
        case "private_message": .conversation
        case "channel_message": .chat
        default: .server
        }
        let user = (d["user_id"] as? NSNumber).map { Int32(truncating: $0) }
        model.openMonitorFromNotification(monitorId: monitorId, opens: opens, userId: user)
    }
}

/// Settings → Display → Notifications: which events notify in the background.
struct BackgroundNotificationsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            Section {
                ForEach(BackgroundNotifications.events) { e in
                    Toggle(e.label, isOn: Binding(get: { model.notifies(e) }, set: { model.setNotifies(e, $0) }))
                }
            } footer: {
                Text("While TeamTalk NG is in the background. A notification has the server's name and the event, such as \"Private message from Matthew: Hi\". Tapping a channel message opens the server's chat, a private message its conversation, and any other the server.")
            }
            Section {
                Button("Enable all") { model.setAllNotifies(true) }
                Button("Clear all") { model.setAllNotifies(false) }
            }
        }
        .navigationTitle("Notifications")
        .navigationBarTitleDisplayMode(.inline)
    }
}
