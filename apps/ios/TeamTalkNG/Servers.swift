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
    /// This server's own volumes (nil: the Settings ones), on this iPhone.
    var outputVolume: Int?
    var micGain: Int?
    var mediaVolume: Int?

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
    // The desktop's two (no "always on"; a saved one reads as push to talk).
    case pushToTalk, voiceActivation
    var id: Self { self }
    var label: String {
        switch self {
        case .pushToTalk: "Push to talk"
        case .voiceActivation: "Voice activation"
        }
    }
}

/// Passwords, one keychain item per saved server.
enum Passwords {
    private static func query(_ id: UUID) -> [String: Any] { query(service: serverService, account: id.uuidString) }
    static let serverService = "TeamTalk NG server"
    /// Kept in iCloud Keychain while iCloud sync is on (end to end
    /// encrypted by Apple): server passwords, the paired Monitor and the
    /// hosted Monitor's registration.
    static let syncedServices: Set<String> = [serverService, "TeamTalk NG own monitor", "TeamTalk NG monitor"]

    static func query(service: String, account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account,
         // Whether in iCloud Keychain or only on this device.
         kSecAttrSynchronizable as String: kSecAttrSynchronizableAny]
    }

    /// Whether a service's items go to iCloud Keychain now.
    private static func synced(_ service: String) -> Bool {
        syncedServices.contains(service) && ICloudSync.isOn
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
        q[kSecAttrSynchronizable as String] = synced(service) ? kCFBooleanTrue : kCFBooleanFalse
        q[kSecValueData as String] = Data(value.utf8)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(q as CFDictionary, nil)
    }

    static func get(_ id: UUID) -> String { secret(serverService, id.uuidString) }

    static func set(_ password: String, for id: UUID) { setSecret(password, serverService, id.uuidString) }

    /// iCloud sync turned on or off: the synced services' items move into
    /// or out of iCloud Keychain.
    static func resync() {
        for service in syncedServices {
            let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
                                    kSecMatchLimit as String: kSecMatchLimitAll,
                                    kSecReturnAttributes as String: true,
                                    kSecReturnData as String: true]
            var out: CFTypeRef?
            guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let items = out as? [[String: Any]] else { continue }
            for item in items {
                guard let account = item[kSecAttrAccount as String] as? String, let data = item[kSecValueData as String] as? Data else { continue }
                setSecret(String(decoding: data, as: UTF8.self), service, account)
            }
        }
    }
}
