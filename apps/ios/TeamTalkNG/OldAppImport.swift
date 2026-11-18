import Foundation
import Security

/// Moving over from the old TeamTalk NG app: this app replaces it (the same
/// app on the App Store), so on the first start its servers (with their
/// passwords and NG Account keys), its NG Account sign-in and its main
/// settings are still in this app's own storage, in the old app's format.
/// Read once, before anything loads; the old app's data is left as it was.
enum OldAppImport {
    private static let doneKey = "importedOldApp"
    private static let serverListKey = "ServerList"

    static func runIfNeeded() {
        let d = UserDefaults.standard
        guard !d.bool(forKey: doneKey) else { return }
        defer { d.set(true, forKey: doneKey) }
        // A fresh install of this app: nothing of the old app's.
        guard d.object(forKey: serverListKey) != nil || d.object(forKey: "nickname_preference") != nil else { return }
        importServers(d)
        importSettings(d)
        importSignIn(d)
    }

    // MARK: Servers

    /// The old app's Server (archived with NSKeyedArchiver, by its fields).
    @objc(TTNGOldServer) private final class OldServer: NSObject, NSCoding {
        var fields: [String: Any] = [:]
        func encode(with coder: NSCoder) {}
        init?(coder c: NSCoder) {
            for k in ["name", "ipaddr", "username", "password", "nickname", "statusmsg", "channel", "chanpasswd",
                      "cacertdata", "certdata", "certprivkeydata", "syncid"] {
                if let v = c.decodeObject(forKey: k) as? String { fields[k] = v }
            }
            fields["tcpport"] = c.decodeInteger(forKey: "tcpport")
            fields["udpport"] = c.decodeInteger(forKey: "udpport")
            fields["encrypted"] = c.decodeBool(forKey: "encrypted")
            fields["certverifypeer"] = c.decodeBool(forKey: "certverifypeer")
            fields["syncpassword"] = c.containsValue(forKey: "syncpassword") ? c.decodeBool(forKey: "syncpassword") : true
        }
    }

    /// The servers the old app saved, as this app's (with their passwords).
    static func oldServers(_ d: UserDefaults) -> [(SavedServer, String)] {
        guard let list = d.array(forKey: serverListKey) as? [Data] else { return [] }
        return list.compactMap { data in
            guard let u = try? NSKeyedUnarchiver(forReadingFrom: data) else { return nil }
            u.requiresSecureCoding = false
            // The old app's module names over the years.
            for module in ["TeamTalk_NG", "TeamTalk", "iTeamTalk", "TeamTalkNG"] {
                u.setClass(OldServer.self, forClassName: "\(module).Server")
            }
            defer { u.finishDecoding() }
            guard let o = u.decodeObject(forKey: NSKeyedArchiveRootObjectKey) as? OldServer else { return nil }
            let f = o.fields
            func s(_ k: String) -> String { f[k] as? String ?? "" }
            var srv = SavedServer()
            srv.name = s("name")
            srv.host = s("ipaddr")
            srv.tcpPort = UInt16(clamping: f["tcpport"] as? Int ?? 10333)
            srv.udpPort = UInt16(clamping: f["udpport"] as? Int ?? 10333)
            srv.encrypted = f["encrypted"] as? Bool ?? false
            srv.username = s("username")
            srv.nickname = s("nickname")
            srv.joinChannel = s("channel")
            // The same record in NG Account (the old app's sync key).
            if !s("syncid").isEmpty { srv.syncKey = s("syncid") }
            srv.syncPassword = (f["syncpassword"] as? Bool ?? true) ? nil : false
            srv.statusMessage = s("statusmsg")
            srv.channelPassword = s("chanpasswd")
            srv.caPem = s("cacertdata")
            srv.certPem = s("certdata")
            srv.keyPem = s("certprivkeydata")
            srv.verifyPeer = f["certverifypeer"] as? Bool ?? false
            guard !srv.host.isEmpty else { return nil }
            if srv.name.isEmpty { srv.name = srv.host }
            return (srv, s("password"))
        }
    }

    private static func importServers(_ d: UserDefaults) {
        let old = oldServers(d)
        guard !old.isEmpty else { return }
        var servers = (d.data(forKey: "servers")).flatMap { try? JSONDecoder().decode([SavedServer].self, from: $0) } ?? []
        for (s, password) in old where !servers.contains(where: { $0.key == s.key || ($0.host.caseInsensitiveCompare(s.host) == .orderedSame && $0.tcpPort == s.tcpPort && $0.username == s.username) }) {
            servers.append(s)
            Passwords.set(password, for: s.id)
        }
        d.set(try? JSONEncoder().encode(servers), forKey: "servers")
    }

    // MARK: Settings (the ones both apps have)

    private static func importSettings(_ d: UserDefaults) {
        func copy(_ from: String, _ to: String) {
            if let v = d.object(forKey: from), d.object(forKey: to) == nil { d.set(v, forKey: to) }
        }
        copy("nickname_preference", "nickname")
        copy("statusmsg_preference", "statusMessage")
        copy("general_sendonreturn_preference", "sendOnReturn")
        copy("joinroot_preference", "joinRoot")
        copy("display_showusername_preference", "showUsernames")
        copy("display_popuptxtmsg_preference", "messagePopup")
        copy("display_limittext_preference", "maxTextLength")
        copy("RecordMediaFiles", "recordMediaFiles")
        if d.object(forKey: "gender_preference") != nil, d.object(forKey: "gender") == nil {
            // The old app's order once moved: 0 male, 1 female, 2 neutral now.
            var i = d.integer(forKey: "gender_preference")
            if d.object(forKey: "gender_order_migrated_preference") == nil {
                if d.object(forKey: "gender_neutral_migrated_preference") == nil { i = i == 1 ? 1 : 0 }
                else { i = [0: 2, 1: 0, 2: 1][i] ?? 2 }
            }
            d.set(["male", "female", "neutral"][min(max(i, 0), 2)], forKey: "gender")
        }
    }

    // MARK: NG Account

    /// The old app's NG Account sign-in (its keychain item in the shared
    /// App Group): the session, used here as this app's (for publishing
    /// sound packs; the hosted Monitor it also served has ended).
    private static func importSignIn(_ d: UserDefaults) {
        guard d.string(forKey: "ngEmail") == nil,
              let group = Bundle.main.object(forInfoDictionaryKey: "TTNGAppGroup") as? String else { return }
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "TeamTalk NG Monitor",
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
            kSecAttrAccessGroup as String: group,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnData as String: true,
        ]
        var out: CFTypeRef?
        if SecItemCopyMatching(q as CFDictionary, &out) != errSecSuccess {
            q.removeValue(forKey: kSecAttrAccessGroup as String)
            guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess else { return }
        }
        struct OldSignIn: Decodable { let token: String; let pushKey: String; let email: String?; let baseURL: URL }
        guard let items = out as? [Data],
              let s = items.compactMap({ try? JSONDecoder().decode(OldSignIn.self, from: $0) }).first(where: { $0.email != nil }),
              let email = s.email, !s.token.isEmpty,
              // Only the same service (not a development one).
              s.baseURL.host == Service.baseURL.host
        else { return }
        Passwords.setSecret(s.token, "TeamTalk NG account", "token")
        d.set(email, forKey: "ngEmail")
    }
}
