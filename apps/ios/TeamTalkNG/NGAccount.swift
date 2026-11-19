import CryptoKit
import Foundation
import Observation
import UIKit

/// NG Account: only for publishing sound packs to the catalog (and keeping
/// them yours after reinstalling the app or on a new device). Servers sync
/// through iCloud; the Monitor runs on your own computer.
@MainActor @Observable
final class NGAccountStore {
    private unowned let app: AppModel
    private var client: NgAccountClient

    private(set) var email: String?

    var signedIn: Bool { email != nil }

    private let defaults = UserDefaults.standard
    private static let keychainService = "TeamTalk NG account"

    init(app: AppModel) {
        self.app = app
        let token = Passwords.secret(Self.keychainService, "token")
        client = Self.makeClient(token: token.isEmpty ? nil : token)
        email = defaults.string(forKey: "ngEmail")
        if email != nil, token.isEmpty { email = nil }
        // What sync kept, from before NG Account stopped syncing servers.
        defaults.removeObject(forKey: "ngSyncState")
        defaults.removeObject(forKey: "ngSyncPacks")
    }

    static var installId: String {
        if let id = UserDefaults.standard.string(forKey: "installId") { return id }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: "installId")
        return id
    }

    private static func makeClient(token: String?) -> NgAccountClient {
        NgAccountClient(baseUrl: Service.base, installId: installId, deviceName: UIDevice.current.name, token: token)
    }

    // MARK: Signing in

    /// Runs a blocking call off the main thread; failures in words.
    private func call<T: Sendable>(_ f: @escaping @Sendable (NgAccountClient) throws -> T) async -> Result<T, Error> {
        let c = client
        return await Task.detached { Result { try f(c) } }.value
    }

    static func words(_ e: Error) -> String {
        switch e as? NgError {
        case .Network(let m), .SignedOut(let m), .Unexpected(let m): m
        case .Refused(_, let m): m
        case nil: e.localizedDescription
        }
    }

    /// Returns why not, or nil when it worked.
    func signIn(email: String, password: String) async -> String? {
        let e = email.trimmingCharacters(in: .whitespaces)
        switch await call({ try $0.signIn(email: e, password: password) }) {
        case .success(let s): await signedIn(s); return nil
        case .failure(let err): return Self.words(err)
        }
    }

    /// Emails a code; then `verify`.
    func signUp(email: String, password: String) async -> String? {
        let e = email.trimmingCharacters(in: .whitespaces)
        switch await call({ try $0.signUp(email: e, password: password) }) {
        case .success: return nil
        case .failure(let err): return Self.words(err)
        }
    }

    func verify(email: String, code: String) async -> String? {
        let e = email.trimmingCharacters(in: .whitespaces), c = code.trimmingCharacters(in: .whitespaces)
        switch await call({ try $0.verify(email: e, code: c) }) {
        case .success(let s): await signedIn(s); return nil
        case .failure(let err): return Self.words(err)
        }
    }

    func forgotPassword(email: String) async -> String? {
        let e = email.trimmingCharacters(in: .whitespaces)
        switch await call({ try $0.forgotPassword(email: e) }) {
        case .success: return nil
        case .failure(let err): return Self.words(err)
        }
    }

    func resetPassword(email: String, code: String, password: String) async -> String? {
        let e = email.trimmingCharacters(in: .whitespaces), c = code.trimmingCharacters(in: .whitespaces)
        switch await call({ try $0.resetPassword(email: e, code: c, password: password) }) {
        case .success(let s): await signedIn(s); return nil
        case .failure(let err): return Self.words(err)
        }
    }

    func changePassword(current: String, new: String) async -> String? {
        switch await call({ try $0.changePassword(current: current, new: new) }) {
        case .success: return nil
        case .failure(let err): return Self.words(err)
        }
    }

    private func signedIn(_ s: NgSession) async {
        Passwords.setSecret(s.token, Self.keychainService, "token")
        email = s.email
        defaults.set(s.email, forKey: "ngEmail")
        client = Self.makeClient(token: s.token)
    }

    /// Signs out (published packs stay in the catalog, still yours).
    func signOut() async {
        _ = await call { try $0.signOut() }
        forget()
    }

    private func forget() {
        Passwords.setSecret("", Self.keychainService, "token")
        email = nil
        defaults.removeObject(forKey: "ngEmail")
        client = Self.makeClient(token: nil)
    }

    private func failed(_ e: Error) -> String {
        if case .SignedOut = e as? NgError {
            forget()
            return "You were signed out of NG Account. Sign in again (Settings → NG Account)."
        }
        return Self.words(e)
    }

    // MARK: Publishing my packs to the catalog

    /// The catalog's copy of one of my packs (the service keeps only
    /// published ones); nil when there's none or I'm not signed in.
    func publishedCopy(of localId: String) async -> OwnPack? {
        guard email != nil else { return nil }
        return try? await call { try $0.myPacks() }.get().first { $0.localId == localId }
    }

    /// Puts my pack in the catalog (or updates it there): its sounds sent
    /// (only those changed), its name, author and description set, made
    /// public. A problem in words, or nil.
    func publish(localId: String, files: [(name: String, url: URL)], name: String, author: String, description: String) async -> String? {
        guard email != nil else { return "Sign in to NG Account first (Settings → NG Account)." }
        let r: Result<OwnPack, Error> = await call { c in
            var p = try c.backupPack(localId: localId, name: name)
            let had = Dictionary(uniqueKeysWithValues: p.files.map { ($0.name, $0.hash) })
            for f in files {
                guard let data = try? Data(contentsOf: f.url) else { continue }
                let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                if had[f.name] != hash { p = try c.uploadPackFile(id: p.id, name: f.name, data: data) }
            }
            let keep = Set(files.map(\.name))
            for f in p.files where !keep.contains(f.name) { p = try c.removePackFile(id: p.id, name: f.name) }
            return try c.changePack(id: p.id, name: name, author: author, description: description, public: true)
        }
        switch r {
        case .success: return nil
        case .failure(let e): return failed(e)
        }
    }

    /// Takes my pack out of the catalog: the service deletes its copy (the
    /// pack stays on my devices).
    func withdraw(localId: String) async -> String? {
        guard let p = await publishedCopy(of: localId) else { return "It isn't in the catalog." }
        let r = await call { try $0.changePack(id: p.id, name: nil, author: nil, description: nil, public: false) }
        if case .failure(let e) = r { return failed(e) }
        return nil
    }

    /// Deleting my pack here also takes it out of the catalog.
    func forgetPack(localId: String) async {
        guard let p = await publishedCopy(of: localId) else { return }
        _ = await call { try $0.deletePack(id: p.id) }
    }
}
