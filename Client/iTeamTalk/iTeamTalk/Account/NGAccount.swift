/*
 * NG Account on this iPhone: signing in and out, and which of servers,
 * settings and sound packs sync. The account owns the monitors, so
 * signing in on a new iPhone (or after reinstalling) brings everything
 * back without iCloud.
 */

import Foundation
import UIKit

extension Notification.Name {
    /// Signed in or out, or the account's details changed.
    static let ngAccountChanged = Notification.Name("NGAccountChanged")
    /// Another device changed the account's synced data or sound packs.
    static let ngAccountRemoteChange = Notification.Name("NGAccountRemoteChange")
}

final class NGAccountCenter {
    static let shared = NGAccountCenter()

    /// What syncs; each on unless turned off on this iPhone.
    enum Category: String, CaseIterable {
        case servers, settings, soundPacks

        var title: String {
            switch self {
            case .servers: return NSLocalizedString("Servers", comment: "ng account")
            case .settings: return NSLocalizedString("Settings", comment: "ng account")
            case .soundPacks: return NSLocalizedString("Sound Packs", comment: "ng account")
            }
        }
    }

    private init() {}

    /// This iPhone's sign-in, if signed in.
    var signIn: MonitorAccount? {
        MonitorAccountStore.ngAccount.flatMap { $0.baseURL == MonitorService.baseURL ? $0 : nil }
    }

    var isSignedIn: Bool { signIn != nil }
    var email: String? { signIn?.email }

    /// The API, signed in when this iPhone is.
    var api: NGAccountAPI { NGAccountAPI(baseURL: MonitorService.baseURL, token: signIn?.token) }

    func isSyncing(_ c: Category) -> Bool {
        MonitorInstall.groupDefaults.object(forKey: "NGSync." + c.rawValue) as? Bool ?? true
    }

    @MainActor
    func setSyncing(_ c: Category, _ on: Bool) {
        MonitorInstall.groupDefaults.set(on, forKey: "NGSync." + c.rawValue)
        if on {
            switch c {
            case .servers, .settings: NGSync.shared.turnedOn(c)
            // Sound pack sync compares with the whole account each time.
            case .soundPacks: NGPackSync.shared.syncSoon(); NGSync.shared.syncSoon()
            }
        }
        NotificationCenter.default.post(name: .ngAccountChanged, object: nil)
    }

    /// Monitors from before NG Account that this iPhone still knows of;
    /// signing in moves them into the account.
    var hasMonitorsWithoutAccount: Bool {
        !unclaimed.isEmpty
    }

    /// Sign-ups from before NG Account still in iCloud Keychain: signing in
    /// moves their monitors into the account and deletes them.
    private var unclaimed: [MonitorAccount] {
        MonitorAccountStore.legacy.filter { $0.baseURL == MonitorService.baseURL }
    }

    /// Move the monitors of sign-ups from before NG Account into the
    /// account, then delete those sign-ups from iCloud Keychain (on every
    /// iPhone it syncs to). One the service can't be reached for stays,
    /// and is tried again later; one the service no longer knows is
    /// already gone, so it's deleted too.
    @MainActor
    func absorbOldSignUps() async {
        let old = unclaimed
        guard let signIn, !old.isEmpty else { return }
        for old in old {
            do {
                // The sign-up the account was made from merges into itself.
                try await MonitorAPI(account: signIn).merge(otherToken: old.token)
            } catch MonitorError.refused {
                // Merged already, or forgotten by the service.
            } catch MonitorError.notPaired {
                sessionEnded()
                return
            } catch {
                continue
            }
            MonitorAccountStore.remove(ref: old.ref)
        }
        // This iPhone's pushes carry the NG Account sign-in's name again.
        MonitorNotifications.shared.registerIfAllowed()
        await MonitorCenter.shared.connection?.refreshServers()
    }

    private func install() -> NGInstall {
        let legacy = unclaimed
        return NGInstall(installID: MonitorInstall.id, deviceName: UIDevice.current.name,
                         claimToken: legacy.min { $0.deviceID < $1.deviceID }?.token)
    }

    // MARK: Signing up and in

    /// Start making an account; a code is emailed to finish with.
    func signUp(email: String, password: String) async throws {
        try await NGAccountAPI(baseURL: MonitorService.baseURL, token: nil).signUp(email: email, password: password)
    }

    @MainActor
    func verify(email: String, code: String) async throws {
        let r = try await NGAccountAPI(baseURL: MonitorService.baseURL, token: nil).verify(email: email, code: code, install: install())
        await signedIn(r, firstTime: true)
    }

    @MainActor
    func signIn(email: String, password: String) async throws {
        let r = try await NGAccountAPI(baseURL: MonitorService.baseURL, token: nil).signIn(email: email, password: password, install: install())
        await signedIn(r, firstTime: false)
    }

    func forgotPassword(email: String) async throws {
        try await NGAccountAPI(baseURL: MonitorService.baseURL, token: nil).forgotPassword(email: email)
    }

    @MainActor
    func resetPassword(email: String, code: String, password: String) async throws {
        let r = try await NGAccountAPI(baseURL: MonitorService.baseURL, token: nil).resetPassword(email: email, code: code, password: password, install: install())
        await signedIn(r, firstTime: false)
    }

    @MainActor
    private func signedIn(_ r: NGSignedIn, firstTime: Bool) async {
        let account = MonitorAccount(ref: UUID().uuidString, name: "TeamTalk NG", baseURL: MonitorService.baseURL,
                                     token: r.token, pushKey: r.pushKey, deviceID: r.deviceId, email: r.account.email)
        MonitorAccountStore.saveSignIn(account)
        MonitorCenter.shared.reload()
        // Monitors from other sign-ups this iPhone knows of join too (the
        // service took the first with the sign-in), and the old sign-ups
        // leave iCloud Keychain.
        await absorbOldSignUps()
        MonitorNotifications.shared.registerIfAllowed()
        NGSync.shared.signedIn(newAccount: firstTime)
        NGPackSync.shared.syncSoon()
        NotificationCenter.default.post(name: .ngAccountChanged, object: nil)
        UIAccessibility.post(notification: .announcement, argument: String(format: NSLocalizedString("Signed in as %@", comment: "ng account"), r.account.email))
    }

    // MARK: Signing out and deleting

    /// Sign this iPhone out. `removeLocalCopy` also removes the servers and
    /// sound packs that came from the account; settings stay as they are.
    @MainActor
    func signOut(removeLocalCopy: Bool) async {
        let api = self.api
        try? await api.signOut()
        forget(removeLocalCopy: removeLocalCopy)
    }

    @MainActor
    func deleteAccount(password: String) async throws {
        try await api.deleteAccount(password: password)
        forget(removeLocalCopy: false)
    }

    /// The service no longer knows this sign-in (signed out from another
    /// device, password reset, or the account deleted).
    @MainActor
    func sessionEnded() {
        guard isSignedIn else { return }
        forget(removeLocalCopy: false)
    }

    @MainActor
    private func forget(removeLocalCopy: Bool) {
        if let signIn {
            MonitorAccountStore.remove(ref: signIn.ref)
        }
        if removeLocalCopy {
            NGSync.shared.removeLocalCopy()
            NGPackSync.shared.removeLocalCopy()
        }
        NGSync.shared.signedOut()
        NGPackSync.shared.signedOut()
        MonitorCenter.shared.reload()
        NotificationCenter.default.post(name: .ngAccountChanged, object: nil)
    }

    /// Run a signed-in request; a sign-in that ended signs this iPhone out.
    func signed<T>(_ work: (NGAccountAPI) async throws -> T) async throws -> T {
        do {
            return try await work(api)
        } catch NGAccountError.signedOut {
            await sessionEnded()
            throw NGAccountError.signedOut
        }
    }

    /// Another device changed something: pull it now.
    @MainActor
    func remoteChange() {
        NGSync.shared.syncSoon()
        NGPackSync.shared.syncSoon()
        NotificationCenter.default.post(name: .ngAccountRemoteChange, object: nil)
    }
}
