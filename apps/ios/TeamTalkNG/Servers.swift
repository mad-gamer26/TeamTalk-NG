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
    /// Join the channel I was last in (the desktop's "last joined channel").
    var joinLastChannel: Bool?

    var key: String { syncKey ?? id.uuidString }

    /// The extra fields the old app and NG Account keep (in `syncOther`,
    /// in their field names, so they sync): status message, channel
    /// password, certificates.
    private var extras: [String: Any] {
        get {
            guard let d = syncOther?.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return [:] }
            return o
        }
        set {
            let clean = newValue.filter { !(($0.value as? String)?.isEmpty ?? false) }
            syncOther = clean.isEmpty ? nil : (try? JSONSerialization.data(withJSONObject: clean, options: [.sortedKeys])).map { String(decoding: $0, as: UTF8.self) }
        }
    }

    private func extra(_ k: String) -> String { extras[k] as? String ?? "" }
    private mutating func setExtra(_ k: String, _ v: String) { var e = extras; e[k] = v; extras = e }

    var statusMessage: String { get { extra("statusmsg") } set { setExtra("statusmsg", newValue) } }
    var channelPassword: String { get { extra("chanpasswd") } set { setExtra("chanpasswd", newValue) } }
    var caPem: String { get { extra("cacertdata") } set { setExtra("cacertdata", newValue) } }
    var certPem: String { get { extra("certdata") } set { setExtra("certdata", newValue) } }
    var keyPem: String { get { extra("certprivkeydata") } set { setExtra("certprivkeydata", newValue) } }
    var verifyPeer: Bool {
        get { extras["certverifypeer"] as? Bool ?? false }
        set { var e = extras; e["certverifypeer"] = newValue ? true : nil; extras = e }
    }

    /// Logs in with the BearWare.dk account (the desktop's web login).
    var bearwareLogin: Bool {
        username.caseInsensitiveCompare("bearware") == .orderedSame || username.lowercased().hasSuffix("@bearware.dk")
    }

    /// As a .tt file or tt:// link has it (`password`: its password, or none).
    func entry(password: String) -> HostEntry {
        HostEntry(name: title, host: host, tcpPort: tcpPort, udpPort: udpPort, encrypted: encrypted,
                  username: username, password: password, nickname: nickname, statusMessage: statusMessage,
                  channel: joinChannel, channelPassword: channelPassword, caPem: caPem, certPem: certPem,
                  keyPem: keyPem, verifyPeer: verifyPeer, joinCode: "", listing: "", userCount: 0,
                  country: "", serverName: "", motd: "")
    }

    var title: String { name.isEmpty ? host : name }
}

extension SavedServer {
    /// From a .tt file, a tt:// link or the public list.
    init(_ e: HostEntry) {
        self.init()
        name = e.name
        host = e.host
        tcpPort = e.tcpPort
        udpPort = e.udpPort
        encrypted = e.encrypted
        username = e.username
        nickname = e.nickname
        joinChannel = e.channel
        statusMessage = e.statusMessage
        channelPassword = e.channelPassword
        caPem = e.caPem
        certPem = e.certPem
        keyPem = e.keyPem
        verifyPeer = e.verifyPeer
    }

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
