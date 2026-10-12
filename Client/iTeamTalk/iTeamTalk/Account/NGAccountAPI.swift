/*
 * NG Account's part of the TeamTalk NG service: making and signing in to
 * accounts, the account's devices, syncing servers and settings, and
 * sound packs. Runs on the same service as the monitors.
 */

import Foundation

enum NGAccountError: LocalizedError {
    /// The service said no, in its own words.
    case refused(String)
    /// The session ended (signed out elsewhere, password changed, account
    /// deleted).
    case signedOut
    case unreachable(String)

    var errorDescription: String? {
        switch self {
        case .refused(let m): return m
        case .signedOut: return NSLocalizedString("You're signed out of your NG Account. Sign in again.", comment: "ng account")
        case .unreachable(let m): return String(format: NSLocalizedString("Could not reach TeamTalk NG's service: %@", comment: "ng account"), m)
        }
    }
}

struct NGAccountInfo: Codable, Equatable {
    var id: Int
    var email: String
    var created: Int64
}

struct NGSignedIn: Decodable {
    var token: String
    var sessionId: Int
    var account: NGAccountInfo
    var deviceId: Int
    var pushKey: String
}

/// An app install signed in to the account.
struct NGSession: Decodable, Equatable {
    var id: Int
    var installId: String
    var name: String
    var created: Int64
    var lastSeen: Int64
    var current: Bool
}

struct NGPackFile: Codable, Equatable {
    var name: String
    var hash: String
    var size: Int64
}

/// A sound pack in the account (backed up, maybe published).
struct NGPack: Decodable, Equatable {
    var id: String
    var localId: String
    var name: String
    var author: String
    var description: String
    var `public`: Bool
    var official: Bool
    var hidden: Bool
    var version: String
    var size: Int64
    var files: [NGPackFile]
}

struct NGPackList: Decodable {
    var packs: [NGPack]
    var usedBytes: Int64
    var limitBytes: Int64
}

/// A published pack, as the catalog lists it.
struct NGCatalogPack: Decodable {
    var id: String
    var name: String
    var author: String
    var description: String
    var version: String
    var official: Bool
    var installs: Int
    var size: Int64
    var downloadPath: String
}

/// What the app may change about a pack in the account.
struct NGPackChange: Encodable {
    var name: String?
    var author: String?
    var description: String?
    var `public`: Bool?
}

/// One synced record: a server or a setting.
struct NGSyncRecord {
    var kind: String
    var key: String
    var rev: Int64
    var deleted: Bool
    /// JSON (a dictionary for a server, any value for a setting).
    var data: Any?

    init?(_ json: [String: Any]) {
        guard let kind = json["kind"] as? String, let key = json["key"] as? String, let rev = (json["rev"] as? NSNumber)?.int64Value else { return nil }
        self.kind = kind
        self.key = key
        self.rev = rev
        deleted = json["deleted"] as? Bool ?? false
        data = json["data"]
    }
}

struct NGSyncChange {
    var kind: String
    var key: String
    var baseRev: Int64
    var deleted: Bool
    var data: Any?

    var json: [String: Any] {
        var j: [String: Any] = ["kind": kind, "key": key, "base_rev": baseRev, "deleted": deleted]
        if let data, !deleted { j["data"] = data }
        return j
    }
}

struct NGSyncResult {
    var rev: Int64
    var applied: [NGSyncRecord]
    var conflicts: [NGSyncRecord]
}

/// Which app install is signing in; `claimToken` is the sign-up it used
/// for monitors before NG Account, whose monitors become the account's.
struct NGInstall {
    var installID: String
    var deviceName: String
    var claimToken: String?

    var fields: [String: Any] {
        var f: [String: Any] = ["install_id": installID, "device_name": deviceName]
        if let claimToken { f["claim_token"] = claimToken }
        return f
    }
}

struct NGAccountAPI {
    let baseURL: URL
    /// The session's secret; nil before signing in.
    let token: String?

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()

    private static let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 30
        c.waitsForConnectivity = false
        return URLSession(configuration: c)
    }()

    private func url(_ path: String, query: [URLQueryItem] = []) -> URL {
        var comps = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { comps.queryItems = query }
        return comps.url!
    }

    /// Send a request. `signed` requests that come back 401 mean the
    /// session ended; others mean the email, password or code was wrong.
    private func send(_ method: String, _ path: String, query: [URLQueryItem] = [], json: Any? = nil, body: Data? = nil, contentType: String? = nil) async throws -> Data {
        var req = URLRequest(url: url(path, query: query))
        req.httpMethod = method
        if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let json {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: json)
        } else if let body {
            req.setValue(contentType ?? "application/octet-stream", forHTTPHeaderField: "Content-Type")
            req.httpBody = body
        }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await Self.session.data(for: req)
        } catch {
            throw NGAccountError.unreachable(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw NGAccountError.unreachable("no response") }
        guard (200..<300).contains(http.statusCode) else {
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            if http.statusCode == 401 && token != nil {
                throw NGAccountError.signedOut
            }
            throw NGAccountError.refused(message ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode))
        }
        return data
    }

    // MARK: Signing up and in

    /// Start making an account: the service emails a code.
    func signUp(email: String, password: String) async throws {
        _ = try await send("POST", "v1/account/signup", json: ["email": email, "password": password])
    }

    /// Finish making the account with the emailed code.
    func verify(email: String, code: String, install: NGInstall) async throws -> NGSignedIn {
        var body = install.fields
        body["email"] = email
        body["code"] = code
        return try Self.decoder.decode(NGSignedIn.self, from: try await send("POST", "v1/account/verify", json: body))
    }

    func signIn(email: String, password: String, install: NGInstall) async throws -> NGSignedIn {
        var body = install.fields
        body["email"] = email
        body["password"] = password
        return try Self.decoder.decode(NGSignedIn.self, from: try await send("POST", "v1/account/signin", json: body))
    }

    /// Email a code to choose a new password with.
    func forgotPassword(email: String) async throws {
        _ = try await send("POST", "v1/account/forgot", json: ["email": email])
    }

    func resetPassword(email: String, code: String, password: String, install: NGInstall) async throws -> NGSignedIn {
        var body = install.fields
        body["email"] = email
        body["code"] = code
        body["password"] = password
        return try Self.decoder.decode(NGSignedIn.self, from: try await send("POST", "v1/account/reset", json: body))
    }

    // MARK: The account

    struct AccountState: Decodable {
        struct Packs: Decodable {
            var usedBytes: Int64
            var limitBytes: Int64
        }
        var account: NGAccountInfo
        var sessionId: Int
        var deviceId: Int
        var syncRev: Int64
        var packs: Packs
    }

    func account() async throws -> AccountState {
        try Self.decoder.decode(AccountState.self, from: try await send("GET", "v1/account"))
    }

    func changePassword(current: String, new: String) async throws {
        _ = try await send("POST", "v1/account/password", json: ["current": current, "new": new])
    }

    func signOut() async throws {
        _ = try await send("POST", "v1/account/signout")
    }

    func deleteAccount(password: String) async throws {
        _ = try await send("POST", "v1/account/delete", json: ["password": password])
    }

    func sessions() async throws -> [NGSession] {
        struct R: Decodable { var sessions: [NGSession] }
        return try Self.decoder.decode(R.self, from: try await send("GET", "v1/account/sessions")).sessions
    }

    func endSession(_ id: Int) async throws {
        _ = try await send("DELETE", "v1/account/sessions/\(id)")
    }

    /// Everything the account holds, as a JSON file (without passwords).
    func export() async throws -> Data {
        try await send("GET", "v1/account/export")
    }

    // MARK: Sync

    func pull(since: Int64) async throws -> (rev: Int64, reset: Bool, records: [NGSyncRecord]) {
        let data = try await send("GET", "v1/sync", query: [URLQueryItem(name: "since", value: String(since))])
        let j = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        let records = (j["records"] as? [[String: Any]] ?? []).compactMap(NGSyncRecord.init)
        return ((j["rev"] as? NSNumber)?.int64Value ?? 0, j["reset"] as? Bool ?? false, records)
    }

    func push(_ changes: [NGSyncChange]) async throws -> NGSyncResult {
        let data = try await send("POST", "v1/sync", json: ["changes": changes.map(\.json)])
        let j = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        return NGSyncResult(rev: (j["rev"] as? NSNumber)?.int64Value ?? 0,
                            applied: (j["applied"] as? [[String: Any]] ?? []).compactMap(NGSyncRecord.init),
                            conflicts: (j["conflicts"] as? [[String: Any]] ?? []).compactMap(NGSyncRecord.init))
    }

    // MARK: Sound packs

    func packs() async throws -> NGPackList {
        try Self.decoder.decode(NGPackList.self, from: try await send("GET", "v1/packs"))
    }

    /// The account's copy of one of this app's packs (made if new).
    func backupPack(localID: String, name: String) async throws -> NGPack {
        try Self.decoder.decode(NGPack.self, from: try await send("POST", "v1/packs", json: ["local_id": localID, "name": name]))
    }

    func changePack(_ id: String, _ change: NGPackChange) async throws -> NGPack {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        let body = try JSONSerialization.jsonObject(with: try e.encode(change))
        return try Self.decoder.decode(NGPack.self, from: try await send("PATCH", "v1/packs/\(id)", json: body))
    }

    func deletePack(_ id: String) async throws {
        _ = try await send("DELETE", "v1/packs/\(id)")
    }

    func uploadSound(pack: String, name: String, data: Data) async throws -> NGPack {
        try Self.decoder.decode(NGPack.self, from: try await send("PUT", "v1/packs/\(pack)/files/\(name)", body: data))
    }

    func downloadSound(pack: String, name: String) async throws -> Data {
        try await send("GET", "v1/packs/\(pack)/files/\(name)")
    }

    func removeSound(pack: String, name: String) async throws -> NGPack {
        try Self.decoder.decode(NGPack.self, from: try await send("DELETE", "v1/packs/\(pack)/files/\(name)"))
    }

    /// A pack as a zip of its sounds (the account's own, or a published one).
    func packZip(_ id: String) async throws -> Data {
        try await send("GET", "v1/packs/\(id)/pack.zip")
    }

    func catalog(query: String = "", popular: Bool = false) async throws -> [NGCatalogPack] {
        struct R: Decodable { var packs: [NGCatalogPack] }
        var items = [URLQueryItem]()
        if !query.isEmpty { items.append(URLQueryItem(name: "q", value: query)) }
        if popular { items.append(URLQueryItem(name: "sort", value: "popular")) }
        return try Self.decoder.decode(R.self, from: try await send("GET", "v1/catalog", query: items)).packs
    }

    func countInstall(_ id: String) async {
        _ = try? await send("POST", "v1/catalog/\(id)/installed")
    }

    func report(_ id: String, reason: String) async throws {
        _ = try await send("POST", "v1/catalog/\(id)/report", json: ["reason": reason])
    }
}
