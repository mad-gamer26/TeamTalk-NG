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

    /// The key that opens this install's notifications.
    static func savePushKey(_ key: String) {
        group?.set(key, forKey: "pushKey")
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
final class PushDelegate: NSObject, UIApplicationDelegate {
    /// Gets the device token (and one that came before it was set).
    @MainActor static var tokenArrived: ((String) -> Void)? {
        didSet { if let t = pendingToken, let f = tokenArrived { pendingToken = nil; f(t) } }
    }
    @MainActor private static var pendingToken: String?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
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
