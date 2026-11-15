import Foundation
import Security

/// A saved server. The password lives in the keychain, not here.
struct SavedServer: Codable, Identifiable, Hashable {
    var id = UUID()
    var name = ""
    var host = ""
    var tcpPort: UInt16 = 10333
    var udpPort: UInt16 = 10333
    var encrypted = false
    var username = ""
    var nickname = ""
    /// A channel to join after logging in ("/Lobby/"); empty for none.
    var joinChannel = ""
    /// Its key in NG Account (servers from the old app keep theirs).
    var syncKey: String?
    /// Whether NG Account gets its password (nil: yes).
    var syncPassword: Bool?
    /// What NG Account had that this app doesn't use (certificates…).
    var syncOther: String?
    /// Connect when the app starts (the desktop's "connect on startup").
    var connectOnStart: Bool?

    var key: String { syncKey ?? id.uuidString }

    var title: String { name.isEmpty ? host : name }
}

/// How talking works, for every server.
enum TalkMode: String, Codable, CaseIterable, Identifiable {
    case pushToTalk, voiceActivation, alwaysOn
    var id: Self { self }
    var label: String {
        switch self {
        case .pushToTalk: "Push to talk"
        case .voiceActivation: "Voice activation"
        case .alwaysOn: "Always on"
        }
    }
}

/// Passwords, one keychain item per saved server.
enum Passwords {
    private static func query(_ id: UUID) -> [String: Any] { query(service: "TeamTalk NG server", account: id.uuidString) }

    static func query(service: String, account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    /// A secret in the keychain by service and name ("" when none).
    static func secret(_ service: String, _ account: String) -> String {
        var q = query(service: service, account: account)
        q[kSecReturnData as String] = true
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return "" }
        return String(decoding: d, as: UTF8.self)
    }

    static func setSecret(_ value: String, _ service: String, _ account: String) {
        SecItemDelete(query(service: service, account: account) as CFDictionary)
        guard !value.isEmpty else { return }
        var q = query(service: service, account: account)
        q[kSecValueData as String] = Data(value.utf8)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(q as CFDictionary, nil)
    }

    static func get(_ id: UUID) -> String {
        var q = query(id)
        q[kSecReturnData as String] = true
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return "" }
        return String(decoding: d, as: UTF8.self)
    }

    static func set(_ password: String, for id: UUID) {
        SecItemDelete(query(id) as CFDictionary)
        guard !password.isEmpty else { return }
        var q = query(id)
        q[kSecValueData as String] = Data(password.utf8)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(q as CFDictionary, nil)
    }
}
