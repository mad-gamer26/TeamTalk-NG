/*
 * Push notifications from TeamTalk NG Monitors: asking permission,
 * registering with Apple and with each paired monitor, the reply and mute
 * actions, and opening the right screen when one is tapped.
 */

import UIKit
import UserNotifications

final class MonitorNotifications: NSObject, UNUserNotificationCenterDelegate {
    static let shared = MonitorNotifications()

    static let replyAction = "TTNG_REPLY"
    static let muteAction = "TTNG_MUTE_HOUR"

    private static let deviceTokenKey = "MonitorAPNsDeviceToken"

    /// Shows whatever was tapped; set by the app once its window exists.
    var openHandler: ((_ ref: String, _ serverID: Int, _ chat: MonitorPrivateChat?) -> Void)?
    /// The monitored server on screen, whose banners are not needed.
    var visibleServer: (ref: String, serverID: Int)?

    /// Builds signed for development get their pushes from Apple's
    /// sandbox; the provisioning profile says which (App Store builds have
    /// none and use production).
    static let sandbox: Bool = {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .isoLatin1) else { return false }
        return text.range(of: "<key>aps-environment</key>\\s*<string>development</string>", options: .regularExpression) != nil
    }()

    func configure() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let reply = UNTextInputNotificationAction(
            identifier: Self.replyAction,
            title: NSLocalizedString("Reply", comment: "monitor notification"),
            options: [],
            textInputButtonTitle: NSLocalizedString("Send", comment: "monitor notification"),
            textInputPlaceholder: NSLocalizedString("Message", comment: "monitor notification"))
        let mute = UNNotificationAction(identifier: Self.muteAction, title: NSLocalizedString("Mute for 1 Hour", comment: "monitor notification"), options: [])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: "TTNG_PRIVATE_MESSAGE", actions: [reply, mute], intentIdentifiers: [], options: []),
            UNNotificationCategory(identifier: "TTNG_CHANNEL_MESSAGE", actions: [reply, mute], intentIdentifiers: [], options: []),
            UNNotificationCategory(identifier: "TTNG_PRESENCE", actions: [mute], intentIdentifiers: [], options: []),
            UNNotificationCategory(identifier: "TTNG_BROADCAST", actions: [mute], intentIdentifiers: [], options: []),
            UNNotificationCategory(identifier: "TTNG_CONNECTION", actions: [mute], intentIdentifiers: [], options: []),
        ])
        if !MonitorAccountStore.all().isEmpty {
            registerIfAllowed()
        }
    }

    /// Ask for permission (the first time) and register with Apple.
    func registerIfAllowed() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            guard granted else { return }
            DispatchQueue.main.async {
                UIApplication.shared.registerForRemoteNotifications()
            }
        }
    }

    func didRegister(deviceToken: Data) {
        let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
        MonitorInstall.groupDefaults.set(hex, forKey: Self.deviceTokenKey)
        // Signed in to NG Account: only its sign-in gets this iPhone's
        // pushes (an older sign-up merged into the account shares the same
        // push entry, so registering both would leave whichever came last).
        // Otherwise every sign-up from before NG Account.
        let accounts = NGAccountCenter.shared.signIn.map { [$0] } ?? MonitorAccountStore.all()
        for account in accounts {
            Task { @MainActor in
                do {
                    try await MonitorAPI(account: account).registerPush(deviceToken: hex, sandbox: Self.sandbox)
                } catch {
                    print("Monitor push registration failed for \(account.name): \(error.localizedDescription)")
                }
            }
        }
    }

    // MARK: UNUserNotificationCenterDelegate

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        let info = notification.request.content.userInfo
        guard let details = Self.details(info) else {
            completionHandler([.banner, .list, .sound])
            return
        }
        let (ref, content) = details
        // The open monitor screen already plays and speaks this event.
        if let visible = visibleServer, visible.ref == ref, visible.serverID == content["server_id"]?.int {
            completionHandler([])
            return
        }
        // Connected to that server live: you are already there.
        if let serverID = content["server_id"]?.int, MonitorLiveServers.isLive(ref: ref, serverID: serverID) {
            completionHandler([])
            return
        }
        completionHandler([.banner, .list, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        guard let details = Self.details(info), let account = MonitorAccountStore.account(ref: details.0) else {
            completionHandler()
            return
        }
        let (ref, data) = details
        let api = MonitorAPI(account: account)
        let serverID = data["server_id"]?.int ?? 0
        switch response.actionIdentifier {
        case Self.replyAction:
            let text = (response as? UNTextInputNotificationResponse)?.userText.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !text.isEmpty else {
                completionHandler()
                return
            }
            // Sending must finish before the system suspends the app.
            let background = UIApplication.shared.beginBackgroundTask(withName: "MonitorReply")
            Task { @MainActor in
                do {
                    if data["event"]?.string == "channel_message" {
                        try await api.sendChannelMessage(server: serverID, channelID: data["channel_id"]?.int, text: text)
                    } else if let userID = data["user_id"]?.int {
                        // Only to the same person: the conversation ends if
                        // they have logged out since.
                        let conversation = data["conversation_id"]?.int
                        try await api.sendPrivateMessage(server: serverID, userID: userID, conversationID: conversation, text: text)
                        if let conversation {
                            try? await api.markRead(server: serverID, conversation: conversation)
                        }
                    }
                } catch {
                    Self.reportFailure(String(format: NSLocalizedString("Your reply was not sent: %@", comment: "monitor notification"), error.localizedDescription))
                }
                completionHandler()
                UIApplication.shared.endBackgroundTask(background)
            }
        case Self.muteAction:
            let background = UIApplication.shared.beginBackgroundTask(withName: "MonitorMute")
            Task { @MainActor in
                if var prefs = try? await api.prefs() {
                    prefs.mutedUntil = Int64((Date().timeIntervalSince1970 + 3600) * 1000)
                    try? await api.setPrefs(prefs)
                }
                completionHandler()
                UIApplication.shared.endBackgroundTask(background)
            }
        default:
            var chat: MonitorPrivateChat?
            if data["event"]?.string == "private_message", let userID = data["user_id"]?.int {
                chat = MonitorPrivateChat(userID: userID, conversationID: data["conversation_id"]?.int, nickname: data["nickname"]?.string ?? "")
            }
            DispatchQueue.main.async {
                self.openHandler?(ref, serverID, chat)
                completionHandler()
            }
        }
    }

    /// The pairing and the monitor's details for a notification: put there
    /// by the notification service extension, or read straight from the
    /// payload when it did not run.
    private static func details(_ info: [AnyHashable: Any]) -> (String, [String: MonitorJSON])? {
        if let ref = info[MonitorPush.accountRefKey] as? String,
           let raw = info[MonitorPush.dataKey] as? [String: Any],
           let json = try? JSONSerialization.data(withJSONObject: raw),
           let data = try? JSONDecoder().decode([String: MonitorJSON].self, from: json) {
            return (ref, data)
        }
        if let opened = MonitorPush.content(from: info) {
            return (opened.ref, opened.content.data)
        }
        return nil
    }

    private static func reportFailure(_ text: String) {
        let content = UNMutableNotificationContent()
        content.title = NSLocalizedString("TeamTalk NG", comment: "monitor notification")
        content.body = text
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}
