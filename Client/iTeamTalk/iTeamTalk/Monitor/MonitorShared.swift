/*
 * TeamTalk NG Monitor support shared by the app and its notification
 * service extension: the sign-up with the monitor service (kept in iCloud
 * Keychain, so a reinstalled app or a new iPhone finds its monitors again),
 * this copy of the app, and opening the sealed text of pushes.
 */

import CryptoKit
import Foundation
import Security
import UIKit
import UserNotifications

/// This install's sign-up with the TeamTalk NG monitor service.
struct MonitorAccount: Codable, Equatable {
    /// This app's own name for the sign-up; the monitor sends it back in
    /// every push so the right key opens it.
    let ref: String
    var name: String
    var baseURL: URL
    /// The device's secret for the monitor's API.
    var token: String
    /// Key that opens sealed notification text (base64).
    var pushKey: String
    var deviceID: Int
}

/// This installed copy of the app, which gets its own notifications. Kept
/// in the app group's settings: the app's own settings are copied to the
/// person's other devices by iCloud sync, and two iPhones must not share it.
enum MonitorInstall {
    static let groupDefaults = UserDefaults(suiteName: MonitorAccountStore.accessGroup) ?? .standard

    /// A restored backup or a Quick Start transfer copies this to a new
    /// iPhone, so it is tied to Apple's per-iPhone app identifier, which
    /// does change on a new iPhone: there it starts over.
    static var id: String {
        let vendor = UIDevice.current.identifierForVendor?.uuidString
        if let id = groupDefaults.string(forKey: "MonitorInstallID"),
           vendor == nil || groupDefaults.string(forKey: "MonitorInstallVendor") == vendor {
            return id
        }
        let id = UUID().uuidString
        groupDefaults.set(id, forKey: "MonitorInstallID")
        groupDefaults.set(vendor, forKey: "MonitorInstallVendor")
        return id
    }
}

enum MonitorAccountStore {
    /// The app group, which the keychain also accepts as an access group
    /// shared by the app and its extensions.
    static let accessGroup = "group.com.matthewdovi.TeamTalk-NG"
    private static let service = "TeamTalk NG Monitor"

    /// Queries match the sign-up whether it syncs through iCloud Keychain
    /// or (from before it did) stays on this iPhone.
    private static func baseQuery(useGroup: Bool) -> [String: Any] {
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
        ]
        if useGroup {
            q[kSecAttrAccessGroup as String] = accessGroup
        }
        return q
    }

    /// Builds without entitlements (the simulator) cannot use the shared
    /// group; they keep the pairing to the app alone.
    private static var groupAvailable: Bool = {
        var q = baseQuery(useGroup: true)
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        let status = SecItemCopyMatching(q as CFDictionary, nil)
        return status != errSecMissingEntitlement
    }()

    static func all() -> [MonitorAccount] {
        var q = baseQuery(useGroup: groupAvailable)
        q[kSecMatchLimit as String] = kSecMatchLimitAll
        q[kSecReturnData as String] = true
        var result: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess,
              let items = result as? [Data] else { return [] }
        return items.compactMap { try? JSONDecoder().decode(MonitorAccount.self, from: $0) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func account(ref: String) -> MonitorAccount? {
        all().first { $0.ref == ref }
    }

    /// Save the sign-up to iCloud Keychain: deleting the app, restoring
    /// the phone or moving to a new iPhone keeps the monitors.
    static func save(_ account: MonitorAccount) {
        guard let data = try? JSONEncoder().encode(account) else { return }
        var match = baseQuery(useGroup: groupAvailable)
        match[kSecAttrAccount as String] = account.ref
        // Replace whatever is there (it may be an older, this-iPhone-only item).
        SecItemDelete(match as CFDictionary)
        var add = match
        add[kSecAttrSynchronizable as String] = kCFBooleanTrue
        add[kSecValueData as String] = data
        // The notification extension runs while the phone is locked.
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }

    /// Move a sign-up saved before it synced into iCloud Keychain.
    static func migrateToICloudKeychain() {
        var q = baseQuery(useGroup: groupAvailable)
        q[kSecAttrSynchronizable as String] = kCFBooleanFalse
        q[kSecMatchLimit as String] = kSecMatchLimitAll
        q[kSecReturnData as String] = true
        var result: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess, let items = result as? [Data] else { return }
        for account in items.compactMap({ try? JSONDecoder().decode(MonitorAccount.self, from: $0) }) {
            save(account)
        }
    }

    static func remove(ref: String) {
        var q = baseQuery(useGroup: groupAvailable)
        q[kSecAttrAccount as String] = ref
        SecItemDelete(q as CFDictionary)
    }
}

/// The sound of monitor notifications on this iPhone, chosen in
/// Notification Settings and applied by the notification service extension.
enum MonitorNotificationSound {
    enum Choice: String, CaseIterable {
        /// The selected sound pack's sounds (the default).
        case soundPack
        /// The iPhone's own notification sound.
        case system
        case none
    }

    private static let choiceKey = "MonitorNotificationSound"
    private static let filesKey = "MonitorNotificationSoundFiles"

    static var choice: Choice {
        get { MonitorInstall.groupDefaults.string(forKey: choiceKey).flatMap(Choice.init(rawValue:)) ?? .soundPack }
        set { MonitorInstall.groupDefaults.set(newValue.rawValue, forKey: choiceKey) }
    }

    /// The sound pack's sounds prepared for notifications, by the service's
    /// sound name (`logged_on`): a file in `soundsDirectory`, or "" when
    /// that sound event is turned off.
    static var files: [String: String] {
        get { MonitorInstall.groupDefaults.dictionary(forKey: filesKey) as? [String: String] ?? [:] }
        set { MonitorInstall.groupDefaults.set(newValue, forKey: filesKey) }
    }

    /// The app group's Library/Sounds, where iOS looks for notification
    /// sounds besides the app itself.
    static var soundsDirectory: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: MonitorAccountStore.accessGroup)?
            .appendingPathComponent("Library/Sounds", isDirectory: true)
    }

    /// The sound for a notification whose push names `serviceSound` (such
    /// as `logged_on.wav`). `fallback` is what the push would play anyway.
    static func sound(serviceSound: String?, fallback: UNNotificationSound?) -> UNNotificationSound? {
        switch choice {
        case .none:
            return nil
        case .system:
            return .default
        case .soundPack:
            guard let serviceSound else { return fallback }
            let name = (serviceSound as NSString).deletingPathExtension
            guard let file = files[name] else { return fallback }
            if file.isEmpty {
                // That sound event is turned off in the app.
                return nil
            }
            guard let dir = soundsDirectory, FileManager.default.fileExists(atPath: dir.appendingPathComponent(file).path) else { return fallback }
            return UNNotificationSound(named: UNNotificationSoundName(file))
        }
    }
}

/// Monitored servers this iPhone is connected to live right now: their
/// notifications are not shown (you are already there). Shared with the
/// notification extension; each entry is refreshed while connected and
/// counts for 15 minutes, so a closed or crashed app silences nothing for
/// long.
enum MonitorLiveServers {
    private static let key = "MonitorLiveServers"
    static let lifetime: TimeInterval = 15 * 60

    private static func name(_ ref: String, _ serverID: Int) -> String { "\(ref)|\(serverID)" }

    private static var entries: [String: Double] {
        get { MonitorInstall.groupDefaults.dictionary(forKey: key) as? [String: Double] ?? [:] }
        set { MonitorInstall.groupDefaults.set(newValue, forKey: key) }
    }

    /// Connected (or still connected) to this monitored server.
    static func mark(ref: String, serverID: Int) {
        let now = Date().timeIntervalSince1970
        entries = entries.filter { now - $0.value < lifetime }.merging([name(ref, serverID): now]) { _, new in new }
    }

    static func unmark(ref: String, serverID: Int) {
        entries.removeValue(forKey: name(ref, serverID))
    }

    static func clear() {
        entries = [:]
    }

    static func isLive(ref: String, serverID: Int) -> Bool {
        guard let at = entries[name(ref, serverID)] else { return false }
        return Date().timeIntervalSince1970 - at < lifetime
    }
}

/// Tells the service, at most once a day, that this iPhone still has the
/// app, even if it is only ever used through notifications. Sign-ups the
/// service stops hearing from are put to sleep and in the end deleted.
enum MonitorKeepAlive {
    private static let lastKey = "MonitorLastKeepAlive"

    static func pingIfDue(ref: String, completion: @escaping () -> Void) {
        let last = MonitorInstall.groupDefaults.double(forKey: lastKey)
        guard Date().timeIntervalSince1970 - last > 24 * 3600,
              let account = MonitorAccountStore.account(ref: ref) else {
            completion()
            return
        }
        var req = URLRequest(url: account.baseURL.appendingPathComponent("v1/me"), timeoutInterval: 5)
        req.setValue("Bearer \(account.token)", forHTTPHeaderField: "Authorization")
        URLSession.shared.dataTask(with: req) { _, response, _ in
            if (response as? HTTPURLResponse)?.statusCode == 200 {
                MonitorInstall.groupDefaults.set(Date().timeIntervalSince1970, forKey: lastKey)
            }
            completion()
        }.resume()
    }
}

/// What a monitor's push says, once opened.
struct MonitorPushContent: Decodable {
    let title: String
    let subtitle: String
    let body: String
    let data: [String: MonitorJSON]
}

/// The `ttng` part of a monitor's push payload.
enum MonitorPush {
    static let accountRefKey = "ttng_ref"
    static let dataKey = "ttng_data"

    /// Open the monitor's content in a push: sealed with the pairing's
    /// key, or plain when the monitor does not seal.
    static func content(from userInfo: [AnyHashable: Any]) -> (ref: String, content: MonitorPushContent)? {
        guard let ttng = userInfo["ttng"] as? [String: Any] else { return nil }
        let ref = ttng["ref"] as? String ?? ""
        if let plain = ttng["content"],
           let data = try? JSONSerialization.data(withJSONObject: plain),
           let content = try? JSONDecoder().decode(MonitorPushContent.self, from: data) {
            return (ref, content)
        }
        guard let sealed = ttng["sealed"] as? String,
              let account = MonitorAccountStore.account(ref: ref),
              let opened = open(sealed: sealed, keyBase64: account.pushKey),
              let content = try? JSONDecoder().decode(MonitorPushContent.self, from: opened) else { return nil }
        return (ref, content)
    }

    /// ChaCha20-Poly1305, nonce + ciphertext + tag, as the monitor seals it.
    static func open(sealed: String, keyBase64: String) -> Data? {
        guard let combined = Data(base64Encoded: sealed),
              let keyData = Data(base64Encoded: keyBase64),
              let box = try? ChaChaPoly.SealedBox(combined: combined) else { return nil }
        return try? ChaChaPoly.open(box, using: SymmetricKey(data: keyData))
    }
}

/// Any JSON value, for the loosely shaped `data` of a push.
enum MonitorJSON: Codable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else { self = .null }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .number(let n): try c.encode(n)
        case .bool(let b): try c.encode(b)
        case .null: try c.encodeNil()
        }
    }

    var string: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    var int: Int? {
        if case .number(let n) = self { return Int(n) }
        return nil
    }

    var plain: Any {
        switch self {
        case .string(let s): return s
        case .number(let n): return n
        case .bool(let b): return b
        case .null: return NSNull()
        }
    }
}
