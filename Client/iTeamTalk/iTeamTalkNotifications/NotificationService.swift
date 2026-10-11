/*
 * Opens TeamTalk NG Monitor pushes before they are shown. A monitor seals
 * the text of its notifications with a key only this phone has, so Apple
 * carries just a placeholder; this replaces it with the
 * real title and message, and keeps the monitor's details for replying.
 */

import UserNotifications

final class NotificationService: UNNotificationServiceExtension {
    private var contentHandler: ((UNNotificationContent) -> Void)?
    private var bestAttempt: UNMutableNotificationContent?

    override func didReceive(_ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        self.contentHandler = contentHandler
        let content = (request.content.mutableCopy() as? UNMutableNotificationContent) ?? UNMutableNotificationContent()
        bestAttempt = content
        if let opened = MonitorPush.content(from: content.userInfo) {
            // The sound this iPhone wants: its sound pack's, the default, or
            // none. Connected to that server live (the app mutes it on the
            // monitor, so this is one that slipped through): no sound, and
            // straight to Notification Center without lighting the screen.
            let serviceSound = (content.userInfo["aps"] as? [String: Any])?["sound"] as? String
            if let serverID = opened.content.data["server_id"]?.int,
               MonitorLiveServers.isLive(ref: opened.ref, serverID: serverID) {
                content.sound = nil
                content.interruptionLevel = .passive
            } else {
                content.sound = MonitorNotificationSound.sound(serviceSound: serviceSound, fallback: content.sound)
            }
            content.title = opened.content.title
            content.subtitle = opened.content.subtitle
            content.body = opened.content.body
            var info = content.userInfo
            info[MonitorPush.accountRefKey] = opened.ref
            info[MonitorPush.dataKey] = opened.content.data.mapValues { $0.plain }
            // The sealed text has done its job.
            if var ttng = info["ttng"] as? [String: Any] {
                ttng["sealed"] = nil
                info["ttng"] = ttng
            }
            content.userInfo = info
            // Let the service know this iPhone still has the app.
            MonitorKeepAlive.pingIfDue(ref: opened.ref) {
                contentHandler(content)
            }
            return
        }
        contentHandler(content)
    }

    override func serviceExtensionTimeWillExpire() {
        if let contentHandler, let bestAttempt {
            contentHandler(bestAttempt)
        }
    }
}
