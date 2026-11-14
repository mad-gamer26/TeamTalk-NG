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
    private static func query(_ id: UUID) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "TeamTalk NG server",
         kSecAttrAccount as String: id.uuidString]
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
