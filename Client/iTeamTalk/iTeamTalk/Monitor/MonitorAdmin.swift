/*
 * Managing a monitored server (accounts, bans, server properties) and a
 * person's details, with the connected-server screens
 * (AdminToolsViewController, ServerPropertiesViewController,
 * UserDetailViewController) working through the monitor service.
 */

import UIKit

/// A TeamTalk time the server sends as seconds since 1970, as the SDK shows
/// it; servers use small numbers for "never".
private func teamTalkTime(_ value: MonitorJSON?) -> String {
    guard let seconds = value?.int, seconds > 86_400 else { return "" }
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy/MM/dd HH:mm"
    return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(seconds)))
}

private func string(_ value: MonitorJSON?) -> String {
    switch value {
    case .string(let s): return s
    case .number(let n): return String(Int(n))
    default: return ""
    }
}

// MARK: - Accounts and bans

final class MonitorAdminToolsModel: AdminToolsModel {
    private weak var session: MonitorSessionViewController?

    init(session: MonitorSessionViewController, server: Server) {
        self.session = session
        super.init(server: server, loadLists: false)
        refreshAll()
    }

    private func admin(_ command: String, _ params: [String: Any] = [:]) async throws -> [[String: MonitorJSON]] {
        guard let session else { return [] }
        return try await session.connection.api.admin(server: session.serverID, command: command, params: params)
    }

    /// Run a change, then show the lists as they are now.
    private func change(_ work: @escaping () async throws -> Void) {
        Task { @MainActor in
            do {
                try await work()
            } catch {
                statusMessage = error.localizedDescription
            }
            refreshAll()
        }
    }

    override func refreshAccounts() {
        isLoadingAccounts = true
        Task { @MainActor in
            do {
                let lines = try await admin("listaccounts", ["index": 0, "count": 100_000])
                accounts = lines.filter { $0["type"]?.string == "useraccount" }.map { AdminUserAccount(Self.account(from: $0)) }
                    .sorted { $0.username.localizedCaseInsensitiveCompare($1.username) == .orderedAscending }
            } catch {
                statusMessage = error.localizedDescription
            }
            isLoadingAccounts = false
        }
    }

    override func refreshBans() {
        isLoadingBans = true
        Task { @MainActor in
            do {
                let lines = try await admin("listbans", ["index": 0, "count": 100_000])
                bans = lines.filter { $0["type"]?.string == "userbanned" }.map { AdminBannedUser(Self.ban(from: $0)) }
                    .sorted { $0.ipAddress.localizedCaseInsensitiveCompare($1.ipAddress) == .orderedAscending }
            } catch {
                statusMessage = error.localizedDescription
            }
            isLoadingBans = false
        }
    }

    private func accountParams(username: String, password: String, note: String, initChannel: String, userType: AccountUserType, userRights: UserRights) -> [String: Any]? {
        let name = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            statusMessage = NSLocalizedString("Username is required", comment: "admin tools")
            return nil
        }
        return [
            "username": name,
            "password": password,
            "note": note,
            "initchan": initChannel,
            "usertype": Int(userType.sdkUserType),
            "userrights": Int(userType == .defaultUser ? userRights : 0),
        ]
    }

    override func createAccount(username: String, password: String, note: String, initChannel: String, userType: AccountUserType, userRights: UserRights) {
        guard let params = accountParams(username: username, password: password, note: note, initChannel: initChannel, userType: userType, userRights: userRights) else { return }
        change { _ = try await self.admin("newaccount", params) }
    }

    override func editAccount(_ original: AdminUserAccount, username: String, password: String, note: String, initChannel: String, userType: AccountUserType, userRights: UserRights) {
        guard let params = accountParams(username: username, password: password, note: note, initChannel: initChannel, userType: userType, userRights: userRights) else { return }
        // As on a connected server: the old account goes, the changed one
        // is created.
        change {
            _ = try await self.admin("delaccount", ["username": original.username])
            _ = try await self.admin("newaccount", params)
        }
    }

    override func deleteAccount(_ account: AdminUserAccount) {
        change {
            _ = try await self.admin("delaccount", ["username": account.username])
            await MainActor.run { self.statusMessage = String(format: NSLocalizedString("Deleted %@", comment: "admin tools"), account.username) }
        }
    }

    override func unban(_ bannedUser: AdminBannedUser) {
        var params: [String: Any] = ["bantype": Int(bannedUser.banTypes)]
        if !bannedUser.ipAddress.isEmpty { params["ipaddr"] = bannedUser.ipAddress }
        if !bannedUser.username.isEmpty { params["username"] = bannedUser.username }
        change { _ = try await self.admin("unban", params) }
    }

    override func defaultServerEntryName() -> String {
        session?.model?.summary.displayName ?? server.name
    }

    static func account(from line: [String: MonitorJSON]) -> UserAccount {
        var account = UserAccount()
        func set(_ value: String, _ property: UAExt) {
            var wrapped = StringWrap()
            toTTString(value, dst: &wrapped.buf)
            setUserAccountString(property, &account, fromStringWrap(&wrapped))
        }
        set(string(line["username"]), ACCOUNT_USERNAME)
        set(string(line["password"]), ACCOUNT_PASSWORD)
        set(string(line["note"]), ACCOUNT_NOTE)
        set(string(line["initchan"]), INITCHANNEL)
        toTTString(teamTalkTime(line["modifiedtime"]), dst: &account.szLastModified)
        toTTString(teamTalkTime(line["lastlogin"]), dst: &account.szLastLoginTime)
        account.uUserType = UINT32(truncatingIfNeeded: line["usertype"]?.int ?? 0)
        account.uUserRights = UINT32(truncatingIfNeeded: line["userrights"]?.int ?? 0)
        return account
    }

    static func ban(from line: [String: MonitorJSON]) -> BannedUser {
        var ban = BannedUser()
        toTTString(string(line["ipaddr"]), dst: &ban.szIPAddress)
        toTTString(string(line["username"]), dst: &ban.szUsername)
        toTTString(string(line["nickname"]), dst: &ban.szNickname)
        toTTString(string(line["channel"]), dst: &ban.szChannelPath)
        toTTString(teamTalkTime(line["bantime"]), dst: &ban.szBanTime)
        toTTString(string(line["owner"]), dst: &ban.szOwner)
        ban.uBanTypes = UINT32(truncatingIfNeeded: line["type"]?.int ?? 0)
        return ban
    }
}

// MARK: - Server properties

final class MonitorServerPropertiesModel: ServerPropertiesModel {
    private weak var session: MonitorSessionViewController?

    init(session: MonitorSessionViewController) {
        self.session = session
        super.init(connected: false)
        loadProperties()
    }

    override func loadProperties() {
        guard let p = session?.model?.snapshot.info.properties ?? nil, !p.isEmpty else {
            statusMessage = NSLocalizedString("Could not load server properties", comment: "admin tools")
            return
        }
        apply(p)
    }

    private func apply(_ p: [String: MonitorJSON]) {
        func number(_ key: String) -> String { p[key]?.int.map(String.init) ?? "0" }
        serverName = string(p["servername"])
        motd = string(p["motdraw"])
        maxUsers = number("maxusers")
        maxLoginAttempts = number("maxloginattempts")
        maxLoginsPerIPAddress = number("maxiplogins")
        maxVoiceTxPerSecond = number("voicetxlimit")
        maxVideoCaptureTxPerSecond = number("videotxlimit")
        maxMediaFileTxPerSecond = number("mediafiletxlimit")
        maxDesktopTxPerSecond = number("desktoptxlimit")
        maxTotalTxPerSecond = number("totaltxlimit")
        autoSave = (p["autosave"]?.int ?? 0) != 0
        tcpPort = number("tcpport")
        udpPort = number("udpport")
        userTimeout = number("usertimeout")
        loginDelayMSec = number("logindelay")
        serverLogEvents = UINT32(truncatingIfNeeded: p["logevents"]?.int ?? 0)
    }

    override func saveProperties(completion: @escaping () -> Void) {
        guard let session else { return }
        func number(_ text: String) -> Int { Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0 }
        let params: [String: Any] = [
            "servername": serverName,
            "motdraw": motd,
            "maxusers": number(maxUsers),
            "maxloginattempts": number(maxLoginAttempts),
            "maxiplogins": number(maxLoginsPerIPAddress),
            "voicetxlimit": number(maxVoiceTxPerSecond),
            "videotxlimit": number(maxVideoCaptureTxPerSecond),
            "mediafiletxlimit": number(maxMediaFileTxPerSecond),
            "desktoptxlimit": number(maxDesktopTxPerSecond),
            "totaltxlimit": number(maxTotalTxPerSecond),
            "autosave": autoSave ? 1 : 0,
            "tcpport": number(tcpPort),
            "udpport": number(udpPort),
            "usertimeout": number(userTimeout),
            "logindelay": number(loginDelayMSec),
            "logevents": Int(serverLogEvents),
        ]
        statusMessage = NSLocalizedString("Updating server properties", comment: "admin tools")
        let api = session.connection.api
        let server = session.serverID
        Task { @MainActor in
            do {
                let lines = try await api.admin(server: server, command: "updateserver", params: params)
                if let updated = lines.first(where: { $0["type"]?.string == "serverupdate" }) {
                    apply(updated)
                }
                statusMessage = NSLocalizedString("Server properties updated", comment: "admin tools")
                completion()
            } catch {
                statusMessage = error.localizedDescription
            }
        }
    }
}

// MARK: - A person's details

/// The connected-server user details: the same copyable General rows and
/// kick actions, for someone on a monitored server.
final class MonitorUserDetailViewController: UserDetailViewController {
    weak var session: MonitorSessionViewController?
    var monitorUser: MonitorUser?

    static func make(session: MonitorSessionViewController, user: MonitorUser) -> MonitorUserDetailViewController {
        let vc = UIStoryboard(name: "Main", bundle: nil).instantiateViewController(identifier: "UserDetail") { coder in
            MonitorUserDetailViewController(coder: coder)
        }
        vc.session = session
        vc.monitorUser = user
        vc.userid = INT32(user.id)
        // As on a connected server, the details open ready to read.
        vc.expandedSections = [vc.SECTION_GENERAL, vc.SECTION_ACTIONS]
        return vc
    }

    override func userForDisplay() -> User {
        monitorUser?.teamTalkUser ?? User()
    }

    override var showsConnectionSections: Bool { false }

    override func currentUserIsAdmin() -> Bool {
        guard let me = session?.model?.me else { return false }
        return (UINT32(truncatingIfNeeded: me.userType) & USERTYPE_ADMIN.rawValue) != 0
    }

    override func channelName(for channelID: INT32) -> String {
        guard channelID > 0 else { return NSLocalizedString("No channel", comment: "user detail") }
        guard let channel = session?.model?.channel(Int(channelID)) else { return "\(channelID)" }
        return channel.parentId == 0 ? NSLocalizedString("root", comment: "user detail") : channel.name
    }

    override func handleTTMessage(_ m: TTMessage) {
        // Not on a live connection.
    }

    override func kickUser(_ sender: UIButton) {
        guard let user = monitorUser else { return }
        var fields: [String: Any] = ["user_id": user.id]
        if let channel = user.channelId { fields["channel_id"] = channel }
        session?.run(presentingFrom: self) { api, server in try await api.act(server: server, "kick", fields) }
    }

    override func kickandbanUser(_ sender: UIButton) {
        guard let user = monitorUser else { return }
        session?.run(presentingFrom: self) { api, server in
            try await api.act(server: server, "ban", ["user_id": user.id])
            try await api.act(server: server, "kick", ["user_id": user.id])
        }
    }
}
