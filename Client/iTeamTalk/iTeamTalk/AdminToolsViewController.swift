import SwiftUI
import UIKit

struct AdminUserAccount: Identifiable, Equatable {
    let rawAccount: UserAccount
    let id: String
    let username: String
    let accountType: AccountUserType
    let userType: String
    let note: String
    let initChannel: String
    let lastModified: String
    let lastLogin: String

    init(_ account: UserAccount) {
        rawAccount = account
        var accountCopy = account
        username = String(cString: getUserAccountString(ACCOUNT_USERNAME, &accountCopy))
        accountType = AccountUserType(accountCopy.uUserType)
        userType = accountType.title
        note = String(cString: getUserAccountString(ACCOUNT_NOTE, &accountCopy))
        initChannel = String(cString: getUserAccountString(INITCHANNEL, &accountCopy))
        lastModified = String(cString: getUserAccountString(ACCOUNT_LASTMODIFIED, &accountCopy))
        lastLogin = String(cString: getUserAccountString(ACCOUNT_LASTLOGIN, &accountCopy))
        id = username
    }

    static func == (lhs: AdminUserAccount, rhs: AdminUserAccount) -> Bool {
        lhs.id == rhs.id
    }

    var password: String {
        var accountCopy = rawAccount
        return String(cString: getUserAccountString(ACCOUNT_PASSWORD, &accountCopy))
    }

    /// The same account with `password` (the server does not give a user
    /// their own account's password; it is the one they logged in with).
    func withPassword(_ password: String) -> AdminUserAccount {
        var account = rawAccount
        var wrapped = StringWrap()
        toTTString(password, dst: &wrapped.buf)
        setUserAccountString(ACCOUNT_PASSWORD, &account, fromStringWrap(&wrapped))
        return AdminUserAccount(account)
    }
}

struct AdminBannedUser: Identifiable, Equatable {
    let id: String
    let ipAddress: String
    let username: String
    let nickname: String
    let channelPath: String
    let banTime: String
    let owner: String
    let banTypes: BanTypes

    init(_ bannedUser: BannedUser) {
        var bannedUser = bannedUser
        ipAddress = String(cString: getBannedUserString(BAN_IPADDRESS, &bannedUser))
        username = String(cString: getBannedUserString(BAN_USERNAME, &bannedUser))
        nickname = String(cString: getBannedUserString(BAN_NICKNAME, &bannedUser))
        channelPath = String(cString: getBannedUserString(BAN_CHANNELPATH, &bannedUser))
        banTime = String(cString: getBannedUserString(BAN_TIME, &bannedUser))
        owner = String(cString: getBannedUserString(BAN_OWNER, &bannedUser))
        banTypes = bannedUser.uBanTypes
        id = [ipAddress, username, channelPath, banTime].joined(separator: "|")
    }
}

enum AccountUserType: String, CaseIterable, Identifiable {
    case defaultUser
    case administrator
    case disabled

    var id: String { rawValue }

    init(_ userTypes: UserTypes) {
        if (userTypes & USERTYPE_ADMIN.rawValue) != 0 {
            self = .administrator
        } else if (userTypes & USERTYPE_DEFAULT.rawValue) != 0 {
            self = .defaultUser
        } else {
            self = .disabled
        }
    }

    var title: String {
        switch self {
        case .defaultUser:
            return NSLocalizedString("Default User", comment: "admin tools")
        case .administrator:
            return NSLocalizedString("Administrator", comment: "admin tools")
        case .disabled:
            return NSLocalizedString("Disabled", comment: "admin tools")
        }
    }

    var sdkUserType: UserTypes {
        switch self {
        case .defaultUser:
            return USERTYPE_DEFAULT.rawValue
        case .administrator:
            return USERTYPE_ADMIN.rawValue
        case .disabled:
            return USERTYPE_NONE.rawValue
        }
    }
}

private struct AccountRightOption: Identifiable {
    let id: String
    let title: String
    let rawValue: UserRights
    let isInverted: Bool

    init(_ title: String, rawValue: UserRights, isInverted: Bool = false) {
        self.id = title
        self.title = title
        self.rawValue = rawValue
        self.isInverted = isInverted
    }
}

private struct ServerLogEventOption: Identifiable {
    let id: String
    let title: String
    let rawValue: ServerLogEvents

    init(_ title: String, rawValue: ServerLogEvents) {
        self.id = title
        self.title = title
        self.rawValue = rawValue
    }
}

private let defaultRegularUserRights: UserRights =
    USERRIGHT_MULTI_LOGIN.rawValue |
    USERRIGHT_VIEW_ALL_USERS.rawValue |
    USERRIGHT_CREATE_TEMPORARY_CHANNEL.rawValue |
    USERRIGHT_UPLOAD_FILES.rawValue |
    USERRIGHT_DOWNLOAD_FILES.rawValue |
    USERRIGHT_TRANSMIT_VOICE.rawValue |
    USERRIGHT_TRANSMIT_VIDEOCAPTURE.rawValue |
    USERRIGHT_TRANSMIT_DESKTOP.rawValue |
    USERRIGHT_TRANSMIT_DESKTOPINPUT.rawValue |
    USERRIGHT_TRANSMIT_MEDIAFILE_AUDIO.rawValue |
    USERRIGHT_TRANSMIT_MEDIAFILE_VIDEO.rawValue |
    USERRIGHT_TEXTMESSAGE_USER.rawValue |
    USERRIGHT_TEXTMESSAGE_CHANNEL.rawValue

@available(iOS 13.0, *)
private let accountRightOptions = [
    AccountRightOption(NSLocalizedString("Log in multiple times", comment: "admin tools"), rawValue: USERRIGHT_MULTI_LOGIN.rawValue),
    AccountRightOption(NSLocalizedString("Change nickname", comment: "admin tools"), rawValue: USERRIGHT_LOCKED_NICKNAME.rawValue, isInverted: true),
    AccountRightOption(NSLocalizedString("See users in all channels", comment: "admin tools"), rawValue: USERRIGHT_VIEW_ALL_USERS.rawValue),
    AccountRightOption(NSLocalizedString("See hidden channels", comment: "admin tools"), rawValue: USERRIGHT_VIEW_HIDDEN_CHANNELS.rawValue),
    AccountRightOption(NSLocalizedString("Create/modify all channels", comment: "admin tools"), rawValue: USERRIGHT_MODIFY_CHANNELS.rawValue),
    AccountRightOption(NSLocalizedString("Create temporary channels", comment: "admin tools"), rawValue: USERRIGHT_CREATE_TEMPORARY_CHANNEL.rawValue),
    AccountRightOption(NSLocalizedString("Edit server properties", comment: "admin tools"), rawValue: USERRIGHT_UPDATE_SERVERPROPERTIES.rawValue),
    AccountRightOption(NSLocalizedString("Kick users off the server", comment: "admin tools"), rawValue: USERRIGHT_KICK_USERS.rawValue),
    AccountRightOption(NSLocalizedString("Ban users from server", comment: "admin tools"), rawValue: USERRIGHT_BAN_USERS.rawValue),
    AccountRightOption(NSLocalizedString("Move users between channels", comment: "admin tools"), rawValue: USERRIGHT_MOVE_USERS.rawValue),
    AccountRightOption(NSLocalizedString("Make other users channel operator", comment: "admin tools"), rawValue: USERRIGHT_OPERATOR_ENABLE.rawValue),
    AccountRightOption(NSLocalizedString("Upload files", comment: "admin tools"), rawValue: USERRIGHT_UPLOAD_FILES.rawValue),
    AccountRightOption(NSLocalizedString("Download files", comment: "admin tools"), rawValue: USERRIGHT_DOWNLOAD_FILES.rawValue),
    AccountRightOption(NSLocalizedString("Record voice in all channels", comment: "admin tools"), rawValue: USERRIGHT_RECORD_VOICE.rawValue),
    AccountRightOption(NSLocalizedString("Transmit voice data (microphone)", comment: "admin tools"), rawValue: USERRIGHT_TRANSMIT_VOICE.rawValue),
    AccountRightOption(NSLocalizedString("Transmit video data (webcam)", comment: "admin tools"), rawValue: USERRIGHT_TRANSMIT_VIDEOCAPTURE.rawValue),
    AccountRightOption(NSLocalizedString("Transmit desktop sessions (shared desktop)", comment: "admin tools"), rawValue: USERRIGHT_TRANSMIT_DESKTOP.rawValue),
    AccountRightOption(NSLocalizedString("Get remote access to desktop sessions", comment: "admin tools"), rawValue: USERRIGHT_TRANSMIT_DESKTOPINPUT.rawValue),
    AccountRightOption(NSLocalizedString("Stream audio files (wav, mp3 files)", comment: "admin tools"), rawValue: USERRIGHT_TRANSMIT_MEDIAFILE_AUDIO.rawValue),
    AccountRightOption(NSLocalizedString("Stream video files (avi, mp4 files)", comment: "admin tools"), rawValue: USERRIGHT_TRANSMIT_MEDIAFILE_VIDEO.rawValue),
    AccountRightOption(NSLocalizedString("Send private text messages", comment: "admin tools"), rawValue: USERRIGHT_TEXTMESSAGE_USER.rawValue),
    AccountRightOption(NSLocalizedString("Send channel text messages", comment: "admin tools"), rawValue: USERRIGHT_TEXTMESSAGE_CHANNEL.rawValue),
    AccountRightOption(NSLocalizedString("Send broadcast text messages", comment: "admin tools"), rawValue: USERRIGHT_TEXTMESSAGE_BROADCAST.rawValue)
]

@available(iOS 13.0, *)
private let serverLogEventOptions = [
    ServerLogEventOption(NSLocalizedString("User connected", comment: "admin tools"), rawValue: SERVERLOGEVENT_USER_CONNECTED.rawValue),
    ServerLogEventOption(NSLocalizedString("User disconnected", comment: "admin tools"), rawValue: SERVERLOGEVENT_USER_DISCONNECTED.rawValue),
    ServerLogEventOption(NSLocalizedString("User logged in", comment: "admin tools"), rawValue: SERVERLOGEVENT_USER_LOGGEDIN.rawValue),
    ServerLogEventOption(NSLocalizedString("User logged out", comment: "admin tools"), rawValue: SERVERLOGEVENT_USER_LOGGEDOUT.rawValue),
    ServerLogEventOption(NSLocalizedString("User login failed", comment: "admin tools"), rawValue: SERVERLOGEVENT_USER_LOGINFAILED.rawValue),
    ServerLogEventOption(NSLocalizedString("User timed out", comment: "admin tools"), rawValue: SERVERLOGEVENT_USER_TIMEDOUT.rawValue),
    ServerLogEventOption(NSLocalizedString("User kicked", comment: "admin tools"), rawValue: SERVERLOGEVENT_USER_KICKED.rawValue),
    ServerLogEventOption(NSLocalizedString("User banned", comment: "admin tools"), rawValue: SERVERLOGEVENT_USER_BANNED.rawValue),
    ServerLogEventOption(NSLocalizedString("User unbanned", comment: "admin tools"), rawValue: SERVERLOGEVENT_USER_UNBANNED.rawValue),
    ServerLogEventOption(NSLocalizedString("User updated", comment: "admin tools"), rawValue: SERVERLOGEVENT_USER_UPDATED.rawValue),
    ServerLogEventOption(NSLocalizedString("User joined channel", comment: "admin tools"), rawValue: SERVERLOGEVENT_USER_JOINEDCHANNEL.rawValue),
    ServerLogEventOption(NSLocalizedString("User left channel", comment: "admin tools"), rawValue: SERVERLOGEVENT_USER_LEFTCHANNEL.rawValue),
    ServerLogEventOption(NSLocalizedString("User moved", comment: "admin tools"), rawValue: SERVERLOGEVENT_USER_MOVED.rawValue),
    ServerLogEventOption(NSLocalizedString("Private text message", comment: "admin tools"), rawValue: SERVERLOGEVENT_USER_TEXTMESSAGE_PRIVATE.rawValue),
    ServerLogEventOption(NSLocalizedString("Custom text message", comment: "admin tools"), rawValue: SERVERLOGEVENT_USER_TEXTMESSAGE_CUSTOM.rawValue),
    ServerLogEventOption(NSLocalizedString("Channel text message", comment: "admin tools"), rawValue: SERVERLOGEVENT_USER_TEXTMESSAGE_CHANNEL.rawValue),
    ServerLogEventOption(NSLocalizedString("Broadcast text message", comment: "admin tools"), rawValue: SERVERLOGEVENT_USER_TEXTMESSAGE_BROADCAST.rawValue),
    ServerLogEventOption(NSLocalizedString("Channel created", comment: "admin tools"), rawValue: SERVERLOGEVENT_CHANNEL_CREATED.rawValue),
    ServerLogEventOption(NSLocalizedString("Channel updated", comment: "admin tools"), rawValue: SERVERLOGEVENT_CHANNEL_UPDATED.rawValue),
    ServerLogEventOption(NSLocalizedString("Channel removed", comment: "admin tools"), rawValue: SERVERLOGEVENT_CHANNEL_REMOVED.rawValue),
    ServerLogEventOption(NSLocalizedString("File uploaded", comment: "admin tools"), rawValue: SERVERLOGEVENT_FILE_UPLOADED.rawValue),
    ServerLogEventOption(NSLocalizedString("File downloaded", comment: "admin tools"), rawValue: SERVERLOGEVENT_FILE_DOWNLOADED.rawValue),
    ServerLogEventOption(NSLocalizedString("File deleted", comment: "admin tools"), rawValue: SERVERLOGEVENT_FILE_DELETED.rawValue),
    ServerLogEventOption(NSLocalizedString("Server updated", comment: "admin tools"), rawValue: SERVERLOGEVENT_SERVER_UPDATED.rawValue),
    ServerLogEventOption(NSLocalizedString("Server configuration saved", comment: "admin tools"), rawValue: SERVERLOGEVENT_SERVER_SAVECONFIG.rawValue),
    ServerLogEventOption(NSLocalizedString("User encryption error", comment: "admin tools"), rawValue: SERVERLOGEVENT_USER_CRYPTERROR.rawValue),
    ServerLogEventOption(NSLocalizedString("User new stream", comment: "admin tools"), rawValue: SERVERLOGEVENT_USER_NEW_STREAM.rawValue)
]

/// Accounts and bans of the connected server. The monitor's subclass
/// (MonitorAdminToolsModel) does the same through the monitor service.
class AdminToolsModel: ObservableObject, TeamTalkEvent {
    @Published var accounts: [AdminUserAccount] = []
    @Published var bans: [AdminBannedUser] = []
    @Published var statusMessage = ""
    @Published var isLoadingAccounts = false
    @Published var isLoadingBans = false

    let server: Server
    private var accountCommandID: INT32 = 0
    private var banCommandID: INT32 = 0
    private var mutationCommandIDs = Set<INT32>()
    private var pendingAccountEdits = [INT32: UserAccount]()

    private var listening = false

    init(server: Server, loadLists: Bool = true) {
        self.server = server
        guard loadLists else { return }
        listening = true
        addToTTMessages(self)
        refreshAll()
    }

    deinit {
        if listening {
            removeTTMessageHandler(self)
        }
    }

    func refreshAll() {
        refreshAccounts()
        refreshBans()
    }

    func refreshAccounts() {
        guard isConnectedToServer() else {
            statusMessage = NSLocalizedString("Not connected", comment: "admin tools")
            return
        }

        accounts.removeAll()
        isLoadingAccounts = true
        accountCommandID = TT_DoListUserAccounts(ttInst, 0, 100_000)
        if accountCommandID < 0 {
            isLoadingAccounts = false
            statusMessage = NSLocalizedString("Could not request accounts", comment: "admin tools")
        }
    }

    func refreshBans() {
        guard isConnectedToServer() else {
            statusMessage = NSLocalizedString("Not connected", comment: "admin tools")
            return
        }

        bans.removeAll()
        isLoadingBans = true
        banCommandID = TT_DoListBans(ttInst, 0, 0, 100_000)
        if banCommandID < 0 {
            isLoadingBans = false
            statusMessage = NSLocalizedString("Could not request bans", comment: "admin tools")
        }
    }

    func createAccount(username: String, password: String, note: String, initChannel: String, userType: AccountUserType, userRights: UserRights) {
        guard let accountTemplate = makeAccount(username: username, password: password, note: note, initChannel: initChannel, userType: userType, userRights: userRights) else {
            return
        }

        var account = accountTemplate
        let commandID = TT_DoNewUserAccount(ttInst, &account)
        trackMutation(commandID, fallbackMessage: NSLocalizedString("Could not create account", comment: "admin tools"))
    }

    func editAccount(_ original: AdminUserAccount, username: String, password: String, note: String, initChannel: String, userType: AccountUserType, userRights: UserRights) {
        guard let account = makeAccount(username: username,
                                        password: password,
                                        note: note,
                                        initChannel: initChannel,
                                        userType: userType,
                                        userRights: userRights,
                                        basedOn: original.rawAccount) else {
            return
        }

        var oldUsername = StringWrap()
        toTTString(original.username, dst: &oldUsername.buf)
        let deleteCommandID = TT_DoDeleteUserAccount(ttInst, fromStringWrap(&oldUsername))
        guard deleteCommandID >= 0 else {
            statusMessage = NSLocalizedString("Could not edit account", comment: "admin tools")
            return
        }
        pendingAccountEdits[deleteCommandID] = account
    }

    private func makeAccount(username: String,
                             password: String,
                             note: String,
                             initChannel: String,
                             userType: AccountUserType,
                             userRights: UserRights,
                             basedOn original: UserAccount? = nil) -> UserAccount? {
        let trimmedUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedUsername.isEmpty == false else {
            statusMessage = NSLocalizedString("Username is required", comment: "admin tools")
            return nil
        }

        var account = original ?? UserAccount()
        setAccountString(trimmedUsername, property: ACCOUNT_USERNAME, account: &account)
        setAccountString(password, property: ACCOUNT_PASSWORD, account: &account)
        setAccountString(note, property: ACCOUNT_NOTE, account: &account)
        setAccountString(initChannel, property: INITCHANNEL, account: &account)
        account.uUserType = userType.sdkUserType
        account.uUserRights = userType == .defaultUser ? userRights : 0
        return account
    }

    func deleteAccount(_ account: AdminUserAccount) {
        var username = StringWrap()
        toTTString(account.username, dst: &username.buf)
        let commandID = TT_DoDeleteUserAccount(ttInst, fromStringWrap(&username))
        trackMutation(commandID, fallbackMessage: NSLocalizedString("Could not delete account", comment: "admin tools"))
    }

    func unban(_ bannedUser: AdminBannedUser) {
        var banned = BannedUser()
        setBannedUserString(bannedUser.ipAddress, property: BAN_IPADDRESS, bannedUser: &banned)
        setBannedUserString(bannedUser.username, property: BAN_USERNAME, bannedUser: &banned)
        banned.uBanTypes = bannedUser.banTypes

        let commandID = TT_DoUnBanUserEx(ttInst, &banned)
        trackMutation(commandID, fallbackMessage: NSLocalizedString("Could not remove ban", comment: "admin tools"))
    }

    func handleTTMessage(_ message: TTMessage) {
        var message = message

        switch message.nClientEvent {
        case CLIENTEVENT_CMD_USERACCOUNT:
            let account = AdminUserAccount(getUserAccount(&message).pointee)
            upsertAccount(account)

        case CLIENTEVENT_CMD_BANNEDUSER:
            let bannedUser = AdminBannedUser(getBannedUser(&message).pointee)
            upsertBan(bannedUser)

        case CLIENTEVENT_CMD_USERACCOUNT_NEW:
            let account = AdminUserAccount(getUserAccount(&message).pointee)
            upsertAccount(account)

        case CLIENTEVENT_CMD_USERACCOUNT_REMOVE:
            let account = AdminUserAccount(getUserAccount(&message).pointee)
            accounts.removeAll { $0.username == account.username }
            statusMessage = String(format: NSLocalizedString("Deleted %@", comment: "admin tools"), account.username)

        case CLIENTEVENT_CMD_PROCESSING:
            if getTTBOOL(&message) == 0 {
                completeCommand(message.nSource)
            }

        case CLIENTEVENT_CMD_ERROR:
            pendingAccountEdits.removeValue(forKey: message.nSource)
            completeCommand(message.nSource)
            statusMessage = getClientErrorMsg(message.clienterrormsg, strprop: ERRMESSAGE)

        default:
            break
        }
    }

    private func upsertAccount(_ account: AdminUserAccount) {
        if let index = accounts.firstIndex(where: { $0.username == account.username }) {
            accounts[index] = account
        } else {
            accounts.append(account)
        }
        accounts.sort { $0.username.localizedCaseInsensitiveCompare($1.username) == .orderedAscending }
    }

    private func upsertBan(_ bannedUser: AdminBannedUser) {
        if let index = bans.firstIndex(where: { $0.id == bannedUser.id }) {
            bans[index] = bannedUser
        } else {
            bans.append(bannedUser)
        }
        bans.sort { $0.ipAddress.localizedCaseInsensitiveCompare($1.ipAddress) == .orderedAscending }
    }

    private func completeCommand(_ commandID: INT32) {
        if commandID == accountCommandID {
            isLoadingAccounts = false
            accountCommandID = 0
        }
        if commandID == banCommandID {
            isLoadingBans = false
            banCommandID = 0
        }
        if mutationCommandIDs.remove(commandID) != nil {
            refreshAll()
        }
        if var account = pendingAccountEdits.removeValue(forKey: commandID) {
            let createCommandID = TT_DoNewUserAccount(ttInst, &account)
            trackMutation(createCommandID, fallbackMessage: NSLocalizedString("Could not edit account", comment: "admin tools"))
        }
    }

    private func trackMutation(_ commandID: INT32, fallbackMessage: String) {
        if commandID < 0 {
            statusMessage = fallbackMessage
        } else {
            mutationCommandIDs.insert(commandID)
        }
    }

    private func setAccountString(_ value: String, property: UAExt, account: inout UserAccount) {
        var wrapped = StringWrap()
        toTTString(value, dst: &wrapped.buf)
        setUserAccountString(property, &account, fromStringWrap(&wrapped))
    }

    private func setBannedUserString(_ value: String, property: BUExt, bannedUser: inout BannedUser) {
        var wrapped = StringWrap()
        toTTString(value, dst: &wrapped.buf)
        switch property {
        case BAN_IPADDRESS:
            bannedUser.szIPAddress = wrapped.buf
        case BAN_USERNAME:
            bannedUser.szUsername = wrapped.buf
        default:
            break
        }
    }

    func ttLink(for account: AdminUserAccount) -> String {
        var components = [String]()
        if server.tcpport != AppInfo.DEFAULT_TCPPORT {
            components.append("tcpport=\(server.tcpport)")
        }
        if server.udpport != AppInfo.DEFAULT_UDPPORT {
            components.append("udpport=\(server.udpport)")
        }
        if server.encrypted {
            components.append("encrypted=true")
        }
        components.append("username=\(urlEscaped(account.username))")
        components.append("password=\(urlEscaped(password(for: account)))")
        if account.initChannel.isEmpty == false {
            components.append("channel=\(urlEscaped(account.initChannel))")
        }
        return "\(AppInfo.TTLINK_PREFIX)\(server.ipaddr)?\(components.joined(separator: "&"))"
    }

    func defaultExportFileName(for account: AdminUserAccount) -> String {
        sanitizedFileName(account.username.isEmpty ? NSLocalizedString("TeamTalk Server", comment: "admin tools") : account.username)
    }

    func defaultServerEntryName() -> String {
        var properties = ServerProperties()
        if TT_GetServerProperties(ttInst, &properties) == TRUE {
            let publicName = String(cString: getServerPropertiesString(SERVERNAME, &properties)).trimmingCharacters(in: .whitespacesAndNewlines)
            if publicName.isEmpty == false {
                return publicName
            }
        }
        let storedName = server.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return storedName.isEmpty ? server.ipaddr : storedName
    }

    func writeTTFile(for account: AdminUserAccount, fileName: String, serverEntryName: String) throws -> URL {
        let cleanFileName = sanitizedFileName(fileName.trimmingCharacters(in: .whitespacesAndNewlines))
        let resolvedFileName = cleanFileName.isEmpty ? defaultExportFileName(for: account) : cleanFileName
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(resolvedFileName).appendingPathExtension("tt")
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        try ttFileXML(for: account, serverEntryName: serverEntryName).data(using: .utf8)?.write(to: url, options: .atomic)
        return url
    }

    private func ttFileXML(for account: AdminUserAccount, serverEntryName: String) -> String {
        let displayName = serverEntryName.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedDisplayName = displayName.isEmpty ? defaultServerEntryName() : displayName
        var xml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<teamtalk>\n"
        xml += "  <host>\n"
        xml += "    <name>\(xmlEscaped(resolvedDisplayName))</name>\n"
        xml += "    <address>\(xmlEscaped(server.ipaddr))</address>\n"
        xml += "    <tcpport>\(server.tcpport)</tcpport>\n"
        xml += "    <udpport>\(server.udpport)</udpport>\n"
        xml += "    <encrypted>\(server.encrypted ? "true" : "false")</encrypted>\n"
        xml += "    <auth>\n"
        xml += "      <username>\(xmlEscaped(account.username))</username>\n"
        xml += "      <password>\(xmlEscaped(password(for: account)))</password>\n"
        xml += "      <nickname></nickname>\n"
        xml += "      <statusmsg></statusmsg>\n"
        xml += "    </auth>\n"
        xml += "    <join>\n"
        xml += "      <channel>\(xmlEscaped(account.initChannel))</channel>\n"
        xml += "      <password></password>\n"
        xml += "    </join>\n"
        xml += "  </host>\n"
        xml += "</teamtalk>\n"
        return xml
    }

    private func password(for account: AdminUserAccount) -> String {
        var accountCopy = account.rawAccount
        return String(cString: getUserAccountString(ACCOUNT_PASSWORD, &accountCopy))
    }

    private func urlEscaped(_ value: String) -> String {
        var allowedCharacters = CharacterSet.urlQueryAllowed
        allowedCharacters.remove(charactersIn: "&=?+")
        return value.addingPercentEncoding(withAllowedCharacters: allowedCharacters) ?? value
    }

    private func xmlEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private func sanitizedFileName(_ value: String) -> String {
        let invalidCharacters = CharacterSet(charactersIn: "/\\?%*|\"<>:")
        return value.components(separatedBy: invalidCharacters).joined(separator: "-")
    }
}

@available(iOS 13.0, *)
final class AdminToolsViewController: UIHostingController<AdminToolsView> {
    private let model: AdminToolsModel

    convenience init(server: Server, initialSection: Int = 0) {
        self.init(model: AdminToolsModel(server: server), initialSection: initialSection)
    }

    init(model: AdminToolsModel, initialSection: Int = 0) {
        self.model = model
        super.init(rootView: AdminToolsView(model: model, initialSection: initialSection))
        title = NSLocalizedString("Manage Server", comment: "admin tools")
    }

    @MainActor required dynamic init?(coder aDecoder: NSCoder) {
        model = AdminToolsModel(server: Server())
        super.init(coder: aDecoder, rootView: AdminToolsView(model: model, initialSection: 0))
        title = NSLocalizedString("Manage Server", comment: "admin tools")
    }
}

@available(iOS 13.0, *)
/// The connected server's properties. The monitor's subclass
/// (MonitorServerPropertiesModel) does the same through the monitor service.
class ServerPropertiesModel: ObservableObject, TeamTalkEvent {
    @Published var serverName = ""
    @Published var motd = ""
    @Published var maxUsers = ""
    @Published var maxLoginAttempts = ""
    @Published var maxLoginsPerIPAddress = ""
    @Published var maxVoiceTxPerSecond = ""
    @Published var maxVideoCaptureTxPerSecond = ""
    @Published var maxMediaFileTxPerSecond = ""
    @Published var maxDesktopTxPerSecond = ""
    @Published var maxTotalTxPerSecond = ""
    @Published var autoSave = false
    @Published var tcpPort = ""
    @Published var udpPort = ""
    @Published var userTimeout = ""
    @Published var loginDelayMSec = ""
    @Published var serverLogEvents: ServerLogEvents = 0
    @Published var statusMessage = ""

    private var properties = ServerProperties()
    private var updateCommandID: INT32 = 0
    private var saveCompletion: (() -> Void)?

    private var listening = false

    convenience init() {
        self.init(connected: true)
    }

    /// `connected: false` leaves loading and saving to a subclass.
    init(connected: Bool) {
        guard connected else { return }
        listening = true
        addToTTMessages(self)
        loadProperties()
    }

    deinit {
        if listening {
            removeTTMessageHandler(self)
        }
    }

    func loadProperties() {
        guard TT_GetServerProperties(ttInst, &properties) == TRUE else {
            statusMessage = NSLocalizedString("Could not load server properties", comment: "admin tools")
            return
        }
        serverName = fromTTString(properties.szServerName)
        motd = fromTTString(properties.szMOTDRaw)
        maxUsers = "\(properties.nMaxUsers)"
        maxLoginAttempts = "\(properties.nMaxLoginAttempts)"
        maxLoginsPerIPAddress = "\(properties.nMaxLoginsPerIPAddress)"
        maxVoiceTxPerSecond = "\(properties.nMaxVoiceTxPerSecond)"
        maxVideoCaptureTxPerSecond = "\(properties.nMaxVideoCaptureTxPerSecond)"
        maxMediaFileTxPerSecond = "\(properties.nMaxMediaFileTxPerSecond)"
        maxDesktopTxPerSecond = "\(properties.nMaxDesktopTxPerSecond)"
        maxTotalTxPerSecond = "\(properties.nMaxTotalTxPerSecond)"
        autoSave = properties.bAutoSave == TRUE
        tcpPort = "\(properties.nTcpPort)"
        udpPort = "\(properties.nUdpPort)"
        userTimeout = "\(properties.nUserTimeout)"
        loginDelayMSec = "\(properties.nLoginDelayMSec)"
        serverLogEvents = properties.uServerLogEvents
    }

    func saveProperties(completion: @escaping () -> Void) {
        var updatedProperties = properties
        toTTString(serverName, dst: &updatedProperties.szServerName)
        toTTString(motd, dst: &updatedProperties.szMOTDRaw)
        updatedProperties.nMaxUsers = intValue(maxUsers)
        updatedProperties.nMaxLoginAttempts = intValue(maxLoginAttempts)
        updatedProperties.nMaxLoginsPerIPAddress = intValue(maxLoginsPerIPAddress)
        updatedProperties.nMaxVoiceTxPerSecond = intValue(maxVoiceTxPerSecond)
        updatedProperties.nMaxVideoCaptureTxPerSecond = intValue(maxVideoCaptureTxPerSecond)
        updatedProperties.nMaxMediaFileTxPerSecond = intValue(maxMediaFileTxPerSecond)
        updatedProperties.nMaxDesktopTxPerSecond = intValue(maxDesktopTxPerSecond)
        updatedProperties.nMaxTotalTxPerSecond = intValue(maxTotalTxPerSecond)
        updatedProperties.bAutoSave = autoSave ? TRUE : FALSE
        updatedProperties.nTcpPort = intValue(tcpPort)
        updatedProperties.nUdpPort = intValue(udpPort)
        updatedProperties.nUserTimeout = intValue(userTimeout)
        updatedProperties.nLoginDelayMSec = intValue(loginDelayMSec)
        updatedProperties.uServerLogEvents = serverLogEvents

        updateCommandID = TT_DoUpdateServer(ttInst, &updatedProperties)
        if updateCommandID < 0 {
            saveCompletion = nil
            statusMessage = NSLocalizedString("Could not update server properties", comment: "admin tools")
        } else {
            saveCompletion = completion
            properties = updatedProperties
            statusMessage = NSLocalizedString("Updating server properties", comment: "admin tools")
        }
    }

    fileprivate func binding(for option: ServerLogEventOption) -> Binding<Bool> {
        Binding(
            get: { (self.serverLogEvents & option.rawValue) != 0 },
            set: { isEnabled in
                if isEnabled {
                    self.serverLogEvents |= option.rawValue
                } else {
                    self.serverLogEvents &= ~option.rawValue
                }
            }
        )
    }

    func handleTTMessage(_ message: TTMessage) {
        var message = message

        switch message.nClientEvent {
        case CLIENTEVENT_CMD_SERVER_UPDATE:
            properties = getServerProperties(&message).pointee
            loadProperties()
            statusMessage = NSLocalizedString("Server properties updated", comment: "admin tools")
            let completion = saveCompletion
            saveCompletion = nil
            updateCommandID = 0
            completion?()

        case CLIENTEVENT_CMD_PROCESSING:
            if message.nSource == updateCommandID && getTTBOOL(&message) == 0 {
                updateCommandID = 0
            }

        case CLIENTEVENT_CMD_ERROR:
            if message.nSource == updateCommandID {
                updateCommandID = 0
                saveCompletion = nil
                statusMessage = getClientErrorMsg(message.clienterrormsg, strprop: ERRMESSAGE)
            }

        default:
            break
        }
    }

    private func intValue(_ value: String) -> INT32 {
        INT32(value.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }
}

@available(iOS 13.0, *)
final class ServerPropertiesViewController: UIHostingController<ServerPropertiesView> {
    private let model: ServerPropertiesModel

    init(model: ServerPropertiesModel = ServerPropertiesModel()) {
        self.model = model
        super.init(rootView: ServerPropertiesView(model: model))
        title = NSLocalizedString("Edit Server Properties", comment: "admin tools")
    }

    @MainActor required dynamic init?(coder aDecoder: NSCoder) {
        model = ServerPropertiesModel()
        super.init(coder: aDecoder, rootView: ServerPropertiesView(model: model))
        title = NSLocalizedString("Edit Server Properties", comment: "admin tools")
    }
}

@available(iOS 13.0, *)
struct AdminToolsView: View {
    @ObservedObject var model: AdminToolsModel
    private let showsAccounts: Bool
    @State private var accountSearch = ""
    @State private var banSearch = ""
    @State private var showingCreateAccount = false
    @State private var editingAccount: AdminUserAccount?

    init(model: AdminToolsModel, initialSection: Int = 0) {
        self.model = model
        showsAccounts = initialSection == 0
    }

    var body: some View {
        Group {
            if showsAccounts {
                accountList
            } else {
                banList
            }
        }
        .navigationTitle(showsAccounts ? NSLocalizedString("Accounts", comment: "admin tools") : NSLocalizedString("Bans", comment: "admin tools"))
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                Button {
                    if showsAccounts {
                        model.refreshAccounts()
                    } else {
                        model.refreshBans()
                    }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .accessibilityLabel(Text(NSLocalizedString("Refresh", comment: "admin tools")))

                if showsAccounts {
                    Button {
                        showingCreateAccount = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel(Text(NSLocalizedString("Add Account", comment: "admin tools")))
                }
            }
        }
        .sheet(isPresented: $showingCreateAccount) {
            AccountEditorView(model: model)
        }
        .sheet(item: $editingAccount) { account in
            AccountEditorView(model: model, account: account)
        }
    }

    private var accountList: some View {
        searchableList(searchText: $accountSearch, prompt: NSLocalizedString("Search Accounts", comment: "admin tools")) {
            List {
                if model.isLoadingAccounts {
                    ProgressView(NSLocalizedString("Loading Accounts", comment: "admin tools"))
                }
                if filteredAccounts.isEmpty && model.isLoadingAccounts == false {
                    Text(NSLocalizedString("No Accounts", comment: "admin tools"))
                        .foregroundColor(.secondary)
                }
                ForEach(filteredAccounts) { account in
                    AccountRow(account: account,
                              edit: { editingAccount = account },
                              delete: { model.deleteAccount(account) },
                              copyTTLink: { copyTTLink(for: account) },
                              exportTTFile: { promptExportTTFile(for: account) })
                }
                if model.statusMessage.isEmpty == false {
                    Text(model.statusMessage)
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            }
            .listStyle(InsetGroupedListStyle())
        }
    }

    private var banList: some View {
        searchableList(searchText: $banSearch, prompt: NSLocalizedString("Search Bans", comment: "admin tools")) {
            List {
                if model.isLoadingBans {
                    ProgressView(NSLocalizedString("Loading Bans", comment: "admin tools"))
                }
                if filteredBans.isEmpty && model.isLoadingBans == false {
                    Text(NSLocalizedString("No Bans", comment: "admin tools"))
                        .foregroundColor(.secondary)
                }
                ForEach(filteredBans) { bannedUser in
                    BanRow(bannedUser: bannedUser) {
                        model.unban(bannedUser)
                    }
                }
                if model.statusMessage.isEmpty == false {
                    Text(model.statusMessage)
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            }
            .listStyle(InsetGroupedListStyle())
        }
    }

    private var filteredAccounts: [AdminUserAccount] {
        let query = accountSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.isEmpty == false else { return model.accounts }
        return model.accounts.filter {
            $0.username.localizedCaseInsensitiveContains(query) ||
            $0.note.localizedCaseInsensitiveContains(query) ||
            $0.initChannel.localizedCaseInsensitiveContains(query)
        }
    }

    private var filteredBans: [AdminBannedUser] {
        let query = banSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.isEmpty == false else { return model.bans }
        return model.bans.filter {
            $0.ipAddress.localizedCaseInsensitiveContains(query) ||
            $0.username.localizedCaseInsensitiveContains(query) ||
            $0.nickname.localizedCaseInsensitiveContains(query) ||
            $0.channelPath.localizedCaseInsensitiveContains(query) ||
            $0.owner.localizedCaseInsensitiveContains(query)
        }
    }

    @ViewBuilder
    private func searchableList<Content: View>(searchText: Binding<String>, prompt: String, @ViewBuilder content: () -> Content) -> some View {
        if #available(iOS 15.0, *) {
            content()
                .searchable(text: searchText, placement: .automatic, prompt: Text(prompt))
        } else {
            content()
        }
    }

    private func copyTTLink(for account: AdminUserAccount) {
        UIPasteboard.general.string = model.ttLink(for: account)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            UIAccessibility.post(notification: .announcement,
                                 argument: NSLocalizedString("Link copied.", comment: "admin tools"))
        }
    }

    private func promptExportTTFile(for account: AdminUserAccount) {
        let alert = UIAlertController(title: NSLocalizedString("Export TT File", comment: "admin tools"),
                                      message: nil,
                                      preferredStyle: .alert)
        alert.addTextField { textField in
            textField.placeholder = NSLocalizedString("File Name", comment: "admin tools")
            textField.text = model.defaultExportFileName(for: account)
        }
        alert.addTextField { textField in
            textField.placeholder = NSLocalizedString("Server Entry Name", comment: "admin tools")
            textField.text = model.defaultServerEntryName()
        }
        alert.addAction(UIAlertAction(title: NSLocalizedString("Cancel", comment: "Dialog message"), style: .cancel))
        alert.addAction(UIAlertAction(title: NSLocalizedString("Export", comment: "admin tools"), style: .default) { _ in
            let fileName = alert.textFields?.first?.text ?? ""
            let serverEntryName = alert.textFields?.dropFirst().first?.text ?? ""
            do {
                let url = try model.writeTTFile(for: account, fileName: fileName, serverEntryName: serverEntryName)
                presentActivity(for: url)
            } catch {
                showExportError(error)
            }
        })
        presenter()?.present(alert, animated: true)
    }

    private func presentActivity(for url: URL) {
        let activity = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        if let presenter = presenter() {
            if let popover = activity.popoverPresentationController {
                popover.sourceView = presenter.view
                popover.sourceRect = CGRect(x: presenter.view.bounds.midX, y: presenter.view.bounds.midY, width: 1, height: 1)
            }
            presenter.present(activity, animated: true)
        }
    }

    private func showExportError(_ error: Error) {
        let alert = UIAlertController(title: NSLocalizedString("Export TT File", comment: "admin tools"),
                                      message: error.localizedDescription,
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: NSLocalizedString("OK", comment: "message dialog"), style: .default))
        presenter()?.present(alert, animated: true)
    }

    private func presenter() -> UIViewController? {
        let windowScene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        var controller = windowScene?.windows.first { $0.isKeyWindow }?.rootViewController
        while let presented = controller?.presentedViewController {
            controller = presented
        }
        return controller
    }
}

@available(iOS 13.0, *)
struct ServerPropertiesView: View {
    @ObservedObject var model: ServerPropertiesModel
    @Environment(\.presentationMode) private var presentationMode

    var body: some View {
        Form {
            Section(header: Text(NSLocalizedString("General", comment: "admin tools"))) {
                labeledTextField(NSLocalizedString("Server Name", comment: "admin tools"), text: $model.serverName)
                labeledTextField(NSLocalizedString("Message of the Day", comment: "admin tools"), text: $model.motd)
                Toggle(NSLocalizedString("Auto Save", comment: "admin tools"), isOn: $model.autoSave)
            }

            Section(header: Text(NSLocalizedString("User Limits", comment: "admin tools"))) {
                numberField(NSLocalizedString("Maximum Users", comment: "admin tools"), text: $model.maxUsers)
                numberField(NSLocalizedString("Maximum Login Attempts", comment: "admin tools"), text: $model.maxLoginAttempts)
                numberField(NSLocalizedString("Maximum Logins Per IP Address", comment: "admin tools"), text: $model.maxLoginsPerIPAddress)
                numberField(NSLocalizedString("User Timeout", comment: "admin tools"), text: $model.userTimeout)
                numberField(NSLocalizedString("Login Delay", comment: "admin tools"), text: $model.loginDelayMSec)
            }

            Section(header: Text(NSLocalizedString("Ports", comment: "admin tools"))) {
                numberField(NSLocalizedString("TCP Port", comment: "admin tools"), text: $model.tcpPort)
                numberField(NSLocalizedString("UDP Port", comment: "admin tools"), text: $model.udpPort)
            }

            Section(header: Text(NSLocalizedString("Bandwidth Limits", comment: "admin tools"))) {
                numberField(NSLocalizedString("Voice Bytes Per Second", comment: "admin tools"), text: $model.maxVoiceTxPerSecond)
                numberField(NSLocalizedString("Video Bytes Per Second", comment: "admin tools"), text: $model.maxVideoCaptureTxPerSecond)
                numberField(NSLocalizedString("Audio File Bytes Per Second", comment: "admin tools"), text: $model.maxMediaFileTxPerSecond)
                numberField(NSLocalizedString("Desktop Bytes Per Second", comment: "admin tools"), text: $model.maxDesktopTxPerSecond)
                numberField(NSLocalizedString("Total Bytes Per Second", comment: "admin tools"), text: $model.maxTotalTxPerSecond)
            }

            Section(header: Text(NSLocalizedString("Server Log Events", comment: "admin tools"))) {
                ForEach(serverLogEventOptions) { option in
                    Toggle(option.title, isOn: model.binding(for: option))
                }
            }

            if model.statusMessage.isEmpty == false {
                Section {
                    Text(model.statusMessage)
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            }
        }
        .navigationTitle(NSLocalizedString("Edit Server Properties", comment: "admin tools"))
        .navigationBarItems(trailing: Button(NSLocalizedString("Save", comment: "admin tools")) {
            model.saveProperties {
                presentationMode.wrappedValue.dismiss()
            }
        })
    }

    private func labeledTextField(_ title: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
                .accessibilityHidden(true)
            TextField("", text: text)
                .accessibilityLabel(Text(title))
        }
    }

    private func numberField(_ title: String, text: Binding<String>) -> some View {
        labeledTextField(title, text: text)
            .keyboardType(.numberPad)
    }
}

@available(iOS 13.0, *)
struct AccountRow: View {
    let account: AdminUserAccount
    let edit: () -> Void
    let delete: () -> Void
    let copyTTLink: () -> Void
    let exportTTFile: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                Text(account.username)
                    .font(.body.weight(.semibold))
                Text(account.userType)
                    .font(.caption)
                    .foregroundColor(.secondary)
                if account.initChannel.isEmpty == false {
                    Text(account.initChannel)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(String(format: NSLocalizedString("%@, %@", comment: "admin tools"), account.username, account.userType)))
            .accessibilityAction(named: Text(NSLocalizedString("Delete Account", comment: "admin tools")), delete)
            .accessibilityAction(named: Text(NSLocalizedString("Export TT File", comment: "admin tools")), exportTTFile)
            .accessibilityAction(named: Text(NSLocalizedString("Copy TT Link", comment: "admin tools")), copyTTLink)
            .accessibilityAction(named: Text(NSLocalizedString("Edit Account", comment: "admin tools")), edit)
            Spacer()
            Menu {
                Button(NSLocalizedString("Edit Account", comment: "admin tools"), action: edit)
                Button(NSLocalizedString("Copy TT Link", comment: "admin tools"), action: copyTTLink)
                Button(NSLocalizedString("Export TT File", comment: "admin tools"), action: exportTTFile)
                Button(NSLocalizedString("Delete Account", comment: "admin tools"), action: delete)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .accessibilityHidden(true)
        }
    }
}

@available(iOS 13.0, *)
struct BanRow: View {
    let bannedUser: AdminBannedUser
    let unban: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                Text(bannedUser.ipAddress.isEmpty ? bannedUser.username : bannedUser.ipAddress)
                    .font(.body.weight(.semibold))
                if bannedUser.nickname.isEmpty == false {
                    Text(bannedUser.nickname)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                if bannedUser.channelPath.isEmpty == false {
                    Text(bannedUser.channelPath)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            Spacer()
            Menu {
                Button(NSLocalizedString("Remove Ban", comment: "admin tools"), action: unban)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .accessibilityLabel(Text(NSLocalizedString("Ban Actions", comment: "admin tools")))
        }
        .accessibilityElement(children: .combine)
    }
}

@available(iOS 13.0, *)
struct AccountEditorView: View {
    @ObservedObject var model: AdminToolsModel
    @Environment(\.presentationMode) private var presentationMode
    private let account: AdminUserAccount?
    @State private var username: String
    @State private var password = ""
    @State private var note: String
    @State private var initChannel: String
    @State private var userType: AccountUserType
    @State private var userRights: UserRights

    init(model: AdminToolsModel, account: AdminUserAccount? = nil) {
        self.model = model
        self.account = account
        _username = State(initialValue: account?.username ?? "")
        _password = State(initialValue: account?.password ?? "")
        _note = State(initialValue: account?.note ?? "")
        _initChannel = State(initialValue: account?.initChannel ?? "")
        _userType = State(initialValue: account?.accountType ?? .defaultUser)
        _userRights = State(initialValue: account?.accountType == .defaultUser ? account?.rawAccount.uUserRights ?? defaultRegularUserRights : defaultRegularUserRights)
    }

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text(NSLocalizedString("Account", comment: "admin tools"))) {
                    TextField(NSLocalizedString("Username", comment: "admin tools"), text: $username)
                        .autocapitalization(.none)
                    TextField(NSLocalizedString("Password", comment: "admin tools"), text: $password)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                    Picker(NSLocalizedString("User Type", comment: "admin tools"), selection: $userType) {
                        ForEach(AccountUserType.allCases) { type in
                            Text(type.title).tag(type)
                        }
                    }
                }
                if userType == .defaultUser {
                    Section(header: Text(NSLocalizedString("User Rights", comment: "admin tools"))) {
                        ForEach(accountRightOptions) { option in
                            Toggle(option.title, isOn: binding(for: option))
                        }
                    }
                }
                Section(header: Text(NSLocalizedString("Optional", comment: "admin tools"))) {
                    TextField(NSLocalizedString("Initial Channel", comment: "admin tools"), text: $initChannel)
                        .autocapitalization(.none)
                    TextField(NSLocalizedString("Note", comment: "admin tools"), text: $note)
                }
            }
            .navigationTitle(account == nil ? NSLocalizedString("Add Account", comment: "admin tools") : NSLocalizedString("Edit Account", comment: "admin tools"))
            .navigationBarItems(
                leading: Button(NSLocalizedString("Cancel", comment: "admin tools")) {
                    presentationMode.wrappedValue.dismiss()
                },
                trailing: Button(account == nil ? NSLocalizedString("Add", comment: "admin tools") : NSLocalizedString("Save", comment: "admin tools")) {
                    if let account {
                        model.editAccount(account, username: username, password: password, note: note, initChannel: initChannel, userType: userType, userRights: userRights)
                    } else {
                        model.createAccount(username: username, password: password, note: note, initChannel: initChannel, userType: userType, userRights: userRights)
                    }
                    presentationMode.wrappedValue.dismiss()
                }
            )
        }
    }

    private func binding(for option: AccountRightOption) -> Binding<Bool> {
        Binding(
            get: {
                let hasRight = (userRights & option.rawValue) != 0
                return option.isInverted ? hasRight == false : hasRight
            },
            set: { isEnabled in
                let shouldSetRawFlag = option.isInverted ? isEnabled == false : isEnabled
                if shouldSetRawFlag {
                    userRights |= option.rawValue
                } else {
                    userRights &= ~option.rawValue
                }
            }
        )
    }
}

/// Your own account on this server, as an administrator would see it, view
/// only; with Export TT File and Copy TT Link.
@available(iOS 13.0, *)
struct MyAccountView: View {
    @ObservedObject var model: AdminToolsModel
    let account: AdminUserAccount

    var body: some View {
        Form {
            Section(header: Text(NSLocalizedString("Account", comment: "admin tools"))) {
                row(NSLocalizedString("Username", comment: "admin tools"), account.username)
                row(NSLocalizedString("Password", comment: "admin tools"), account.password)
                row(NSLocalizedString("User Type", comment: "admin tools"), account.userType)
            }
            if account.accountType == .defaultUser {
                Section(header: Text(NSLocalizedString("User Rights", comment: "admin tools"))) {
                    ForEach(accountRightOptions) { option in
                        row(option.title, hasRight(option)
                            ? NSLocalizedString("Yes", comment: "yes")
                            : NSLocalizedString("No", comment: "no"))
                    }
                }
            }
            Section(header: Text(NSLocalizedString("Optional", comment: "admin tools"))) {
                row(NSLocalizedString("Initial Channel", comment: "admin tools"), account.initChannel)
                row(NSLocalizedString("Note", comment: "admin tools"), account.note)
            }
            Section {
                Button(NSLocalizedString("Export TT File", comment: "admin tools")) {
                    promptExportTTFile()
                }
                Button(NSLocalizedString("Copy TT Link", comment: "admin tools")) {
                    UIPasteboard.general.string = model.ttLink(for: account)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                        UIAccessibility.post(notification: .announcement,
                                             argument: NSLocalizedString("Link copied.", comment: "admin tools"))
                    }
                }
            }
        }
        .navigationTitle(NSLocalizedString("My Information", comment: "admin tools"))
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value.isEmpty ? NSLocalizedString("None", comment: "admin tools") : value)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.trailing)
        }
        .accessibilityElement(children: .combine)
    }

    private func hasRight(_ option: AccountRightOption) -> Bool {
        let has = (account.rawAccount.uUserRights & option.rawValue) != 0
        return option.isInverted ? has == false : has
    }

    private func promptExportTTFile() {
        let alert = UIAlertController(title: NSLocalizedString("Export TT File", comment: "admin tools"),
                                      message: nil,
                                      preferredStyle: .alert)
        alert.addTextField { textField in
            textField.placeholder = NSLocalizedString("File Name", comment: "admin tools")
            textField.text = model.defaultExportFileName(for: account)
        }
        alert.addTextField { textField in
            textField.placeholder = NSLocalizedString("Server Entry Name", comment: "admin tools")
            textField.text = model.defaultServerEntryName()
        }
        alert.addAction(UIAlertAction(title: NSLocalizedString("Cancel", comment: "Dialog message"), style: .cancel))
        alert.addAction(UIAlertAction(title: NSLocalizedString("Export", comment: "admin tools"), style: .default) { _ in
            let fileName = alert.textFields?.first?.text ?? ""
            let serverEntryName = alert.textFields?.dropFirst().first?.text ?? ""
            do {
                let url = try model.writeTTFile(for: account, fileName: fileName, serverEntryName: serverEntryName)
                let activity = UIActivityViewController(activityItems: [url], applicationActivities: nil)
                if let presenter = presenter(), let popover = activity.popoverPresentationController {
                    popover.sourceView = presenter.view
                    popover.sourceRect = CGRect(x: presenter.view.bounds.midX, y: presenter.view.bounds.midY, width: 1, height: 1)
                }
                presenter()?.present(activity, animated: true)
            } catch {
                let failed = UIAlertController(title: NSLocalizedString("Export TT File", comment: "admin tools"),
                                               message: error.localizedDescription,
                                               preferredStyle: .alert)
                failed.addAction(UIAlertAction(title: NSLocalizedString("OK", comment: "message dialog"), style: .default))
                presenter()?.present(failed, animated: true)
            }
        })
        presenter()?.present(alert, animated: true)
    }

    private func presenter() -> UIViewController? {
        let windowScene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        var controller = windowScene?.windows.first { $0.isKeyWindow }?.rootViewController
        while let presented = controller?.presentedViewController {
            controller = presented
        }
        return controller
    }
}

@available(iOS 13.0, *)
final class MyAccountViewController: UIHostingController<MyAccountView> {
    init(server: Server, account: UserAccount) {
        let model = AdminToolsModel(server: server, loadLists: false)
        let mine = AdminUserAccount(account).withPassword(server.password)
        super.init(rootView: MyAccountView(model: model, account: mine))
        title = NSLocalizedString("My Information", comment: "admin tools")
    }

    @MainActor required dynamic init?(coder aDecoder: NSCoder) { nil }
}
