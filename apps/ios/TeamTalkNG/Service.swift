import Foundation
import UIKit
import UserNotifications

/// Where the Monitor and NG Account service is: the build's
/// TTNG_SERVICE_URL (the dev app: the development ngmon on the owner's Mac),
/// empty meaning the live service.
enum Service {
    static var base: String {
        (Bundle.main.object(forInfoDictionaryKey: "TTNGServiceURL") as? String)?
            .trimmingCharacters(in: .whitespaces) ?? ""
    }

    /// The live service, for what has no address of its own.
    static var baseURL: URL { URL(string: base.isEmpty ? "https://ttmonitor.mad-gamer.com" : base)! }

    /// Shared with the notification extension (it opens sealed pushes).
    static var group: UserDefaults? {
        (Bundle.main.object(forInfoDictionaryKey: "TTNGAppGroup") as? String).flatMap { UserDefaults(suiteName: $0) }
    }

    /// The key that opens this install's notifications from the hosted
    /// Monitor (kept aside while your own Monitor's is in use).
    static func savePushKey(_ key: String) {
        group?.set(key, forKey: "hostedPushKey")
        if group?.bool(forKey: "ownMonitor") != true { group?.set(key, forKey: "pushKey") }
    }

    /// Your own Monitor's notifications key: in use instead of the hosted one.
    static func saveOwnPushKey(_ key: String) {
        if group?.bool(forKey: "ownMonitor") != true, let hosted = group?.string(forKey: "pushKey") {
            group?.set(hosted, forKey: "hostedPushKey")
        }
        group?.set(true, forKey: "ownMonitor")
        group?.set(key, forKey: "pushKey")
    }

    /// Back to the hosted Monitor's key.
    static func forgetOwnPushKey() {
        group?.set(false, forKey: "ownMonitor")
        group?.set(group?.string(forKey: "hostedPushKey") ?? "", forKey: "pushKey")
    }

    /// A development build gets its pushes from Apple's sandbox.
    static var sandbox: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }
}

/// Registers with Apple for the Monitor's notifications and hands the
/// device token to the Monitor.
final class PushDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    /// Gets the device token (and one that came before it was set).
    @MainActor static var tokenArrived: ((String) -> Void)? {
        didSet { if let t = pendingToken, let f = tokenArrived { pendingToken = nil; f(t) } }
    }
    @MainActor private static var pendingToken: String?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { ok, _ in
            guard ok else { return }
            Task { @MainActor in application.registerForRemoteNotifications() }
        }
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
        Task { @MainActor in
            if let f = Self.tokenArrived { f(hex) } else { Self.pendingToken = hex }
        }
    }

    /// A notification while the app is open: shown and heard as usual,
    /// except the Monitor's about a server whose Monitor screen is open
    /// (its events are already there).
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping @Sendable (UNNotificationPresentationOptions) -> Void) {
        let info = notification.request.content.userInfo
        let data = (info["data"] as? [String: Any])
            ?? (((info["ttng"] as? [String: Any])?["content"] as? [String: Any])?["data"] as? [String: Any])
        let id = (data?["server_id"] as? NSNumber)?.int64Value
        Task { @MainActor in
            if let id, AppModel.shared?.isShowingMonitor(id) == true {
                completionHandler([])
            } else {
                completionHandler([.banner, .list, .sound, .badge])
            }
        }
    }

    /// A notification was tapped: the screen it's about.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping @Sendable () -> Void) {
        let info = response.notification.request.content.userInfo
        let open = info["ttngOpen"] as? [String: Any]
        let data = (info["data"] as? [String: Any])
            ?? (((info["ttng"] as? [String: Any])?["content"] as? [String: Any])?["data"] as? [String: Any])
        // Only what's needed, as plain values, onto the main actor.
        var plain: [AnyHashable: Any] = [:]
        if let open { plain["ttngOpen"] = open }
        if let data { plain["data"] = data }
        let box = UncheckedBox(plain)
        Task { @MainActor in
            BackgroundNotifications.open(box.value)
            completionHandler()
        }
    }

    /// NG Account's silent notice that the account changed on another
    /// device ({"ttng": {"sync": rev}}): synced now, in the background too.
    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any],
                     fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        guard (userInfo["ttng"] as? [String: Any])?["sync"] != nil else { completionHandler(.noData); return }
        Task { @MainActor in
            await AppModel.shared?.account.sync()
            completionHandler(.newData)
        }
    }
}

/// Hands a notification's plain values to the main actor.
private struct UncheckedBox<T>: @unchecked Sendable { let value: T; init(_ v: T) { value = v } }
