/*
 * A monitored server, shown the way a connected server is: the same channel
 * tree, user rows, actions, message screens and bottom toolbar, built from
 * the app's own screens (ChannelListViewController and
 * TextMessageViewController) with the monitor's view of the server in place
 * of a live TeamTalk connection. Acting here acts as the monitor.
 */

import UIKit

// MARK: - Turning the monitor's view into TeamTalk's own types

extension MonitorChannel {
    var teamTalkChannel: Channel {
        var c = Channel()
        c.nChannelID = INT32(id)
        c.nParentID = INT32(parentId)
        toTTString(name, dst: &c.szName)
        toTTString(topic, dst: &c.szTopic)
        c.bPassword = passwordProtected ? TRUE : FALSE
        c.nMaxUsers = INT32(maxUsers)
        c.uChannelType = UINT32(truncatingIfNeeded: channelType)
        return c
    }
}

extension MonitorUser {
    var teamTalkUser: User {
        var u = User()
        u.nUserID = INT32(id)
        toTTString(ipAddress ?? "", dst: &u.szIPAddress)
        // "5.22.0.5198" as the SDK keeps it: major, minor and build in bytes.
        let parts = version.split(separator: ".").compactMap { UINT32($0) }
        if parts.count >= 3 {
            u.uVersion = (parts[0] & 0xFF) << 16 | (parts[1] & 0xFF) << 8 | (parts[2] & 0xFF)
        }
        toTTString(nickname, dst: &u.szNickname)
        toTTString(username, dst: &u.szUsername)
        toTTString(statusMsg, dst: &u.szStatusMsg)
        toTTString(clientName, dst: &u.szClientName)
        u.nStatusMode = INT32(truncatingIfNeeded: statusMode)
        u.uUserType = UINT32(truncatingIfNeeded: userType)
        u.nChannelID = INT32(channelId ?? 0)
        return u
    }
}

private let mainStoryboard = UIStoryboard(name: "Main", bundle: nil)

// MARK: - Channels

/// The connected-server channel list, showing what the monitor sees.
final class MonitorChannelListViewController: ChannelListViewController {
    weak var session: MonitorSessionViewController?
    private(set) var model: MonitorServerModel?
    private var expandedOnce = false

    private var api: MonitorAPI? { session?.connection.api }
    private var serverID: Int { session?.serverID ?? 0 }

    /// Show the server as the monitor now sees it.
    func show(_ model: MonitorServerModel) {
        self.model = model
        var channels = [INT32: Channel]()
        for c in model.snapshot.channels {
            channels[INT32(c.id)] = c.teamTalkChannel
        }
        var users = [INT32: User]()
        for u in model.snapshot.users where u.id != model.me.userId {
            users[INT32(u.id)] = u.teamTalkUser
        }
        self.channels = channels
        self.users = users
        var properties = ServerProperties()
        let name = model.snapshot.info.name.isEmpty ? model.summary.displayName : model.snapshot.info.name
        toTTString(name, dst: &properties.szServerName)
        toTTString(model.snapshot.info.motd, dst: &properties.szMOTD)
        srvprop = properties
        mychannel = model.me.channelId.flatMap { channels[INT32($0)] } ?? Channel()
        var account = UserAccount()
        account.uUserRights = UINT32(truncatingIfNeeded: model.me.userRights)
        account.uUserType = UINT32(truncatingIfNeeded: model.me.userType)
        myuseraccount = account
        if let current = channels[curchannel.nChannelID] {
            curchannel = current
        }
        // Open the tree the first time, as a connected server is opened
        // where people are.
        if !expandedOnce, !channels.isEmpty {
            expandedOnce = true
            for c in channels.values where c.nParentID == 0 {
                expandedChannelIDs.insert(c.nChannelID)
            }
            for u in users.values where u.nChannelID != 0 {
                expandChannelAndParents(u.nChannelID)
            }
        }
        if isViewLoaded {
            tableView.reloadData()
        }
    }

    // The monitor, not this phone, is the one on the server.

    override func localUserID() -> INT32 {
        INT32(model?.me.userId ?? 0)
    }

    override func isChannelOperator(_ userID: INT32, channelID: INT32) -> Bool {
        model?.channel(Int(channelID))?.operators.contains(Int(userID)) ?? false
    }

    override func isLocallyTransmittingVoice() -> Bool { false }
    override var allowsLocalMute: Bool { false }
    /// The monitor has a gender of its own, which the server reports.
    override var showsLocalGenderPreference: Bool { false }
    override var allowsChannelEditing: Bool { false }
    override func canUseVoiceTx() -> Bool { false }

    override func updateTX() {
        super.updateTX()
        session?.updateBottomToolbar()
    }

    // Actions go to the monitor.

    override func joinNewChannel(_ channel: Channel) {
        let channelID = Int(channel.nChannelID)
        guard channel.bPassword == TRUE else {
            expandChannelAndParents(channel.nChannelID)
            session?.run { api, server in try await api.act(server: server, "join", ["channel_id": channelID]) }
            return
        }
        let alert = UIAlertController(title: NSLocalizedString("Enter Password", comment: "Dialog message"),
                                      message: NSLocalizedString("Password", comment: "Dialog message"),
                                      preferredStyle: .alert)
        alert.addTextField { field in
            field.autocorrectionType = .no
            field.spellCheckingType = .no
            field.autocapitalizationType = .none
        }
        alert.addAction(UIAlertAction(title: NSLocalizedString("Cancel", comment: "Dialog message"), style: .cancel))
        alert.addAction(UIAlertAction(title: NSLocalizedString("Join", comment: "Dialog message"), style: .default) { [weak self] _ in
            let password = alert.textFields?.first?.text ?? ""
            self?.expandChannelAndParents(channel.nChannelID)
            self?.session?.run { api, server in try await api.act(server: server, "join", ["channel_id": channelID, "password": password]) }
        })
        present(alert, animated: true)
    }

    override func leaveCurrentChannel() {
        guard mychannel.nChannelID > 0 else { return }
        session?.run { api, server in try await api.act(server: server, "leave") }
    }

    override func messageUser(_ action: UIAccessibilityCustomAction) -> Bool {
        if let ac = action as? MyCustomAction {
            openPrivateMessages(userID: INT32(ac.tag))
        }
        return true
    }

    override func kickUser(_ action: UIAccessibilityCustomAction) -> Bool {
        if let ac = action as? MyCustomAction, let user = users[INT32(ac.tag)] {
            kick(user, fromServer: false)
        }
        return true
    }

    override func banUser(_ action: UIAccessibilityCustomAction) -> Bool {
        if let ac = action as? MyCustomAction, let user = users[INT32(ac.tag)] {
            ban(user)
        }
        return true
    }

    override func moveIntoChannel(_ action: UIAccessibilityCustomAction) -> Bool {
        if let ac = action as? MyCustomAction {
            let channelID = ac.tag
            let ids = moveusers.map { Int($0) }
            moveusers.removeAll()
            session?.run { api, server in
                for id in ids {
                    try await api.act(server: server, "move", ["user_id": id, "channel_id": channelID])
                }
            }
            tableView.reloadData()
        }
        return true
    }

    private func kick(_ user: User, fromServer: Bool) {
        var fields: [String: Any] = ["user_id": Int(user.nUserID)]
        if !fromServer, user.nChannelID != 0 {
            fields["channel_id"] = Int(user.nChannelID)
        }
        session?.run { api, server in try await api.act(server: server, "kick", fields) }
    }

    private func ban(_ user: User) {
        let id = Int(user.nUserID)
        session?.run { api, server in
            try await api.act(server: server, "ban", ["user_id": id])
            try await api.act(server: server, "kick", ["user_id": id])
        }
    }

    private func openPrivateMessages(userID: INT32) {
        guard let user = model?.user(Int(userID)) else { return }
        session?.showPrivateMessages(MonitorPrivateChat(userID: user.id, conversationID: nil, nickname: user.displayName))
    }

    /// What tapping a person does on a connected server (their details,
    /// with the actions on them) and the message button.
    override func shouldPerformSegue(withIdentifier identifier: String, sender: Any?) -> Bool {
        switch identifier {
        case "Show User":
            if let cell = sender as? UITableViewCell {
                showUserDetails(userID: INT32(cell.tag), from: cell)
            }
        case "New TextMessage":
            if let button = sender as? UIButton {
                openPrivateMessages(userID: INT32(button.tag))
            }
        default:
            break
        }
        return false
    }

    private func showUserDetails(userID: INT32, from cell: UITableViewCell) {
        guard let session, let user = model?.user(Int(userID)) else { return }
        session.navigationController?.pushViewController(MonitorUserDetailViewController.make(session: session, user: user), animated: true)
    }

}

// MARK: - Messages

/// The connected-server message screen: the channel's messages and server
/// events, or a private conversation, through the monitor.
final class MonitorTextMessageViewController: TextMessageViewController {
    weak var session: MonitorSessionViewController?
    /// The private conversation shown; nil for the channel's messages.
    var chat: MonitorPrivateChat?
    /// The person logged out: the conversation is over, as in TeamTalk.
    private var ended = false
    /// The newest event already on screen; anything at or before it (a
    /// replay after the app was away, or already in the loaded history)
    /// is skipped.
    private var shownThrough: Int64 = 0
    /// Events that came while the history was loading, added after it.
    private var loading = false
    private var arrivedWhileLoading: [Notification] = []

    static func make(session: MonitorSessionViewController, chat: MonitorPrivateChat?) -> MonitorTextMessageViewController {
        let vc = mainStoryboard.instantiateViewController(identifier: "Text Message") { coder in
            MonitorTextMessageViewController(coder: coder)
        }
        vc.session = session
        vc.chat = chat
        // As on a connected server, a private window is the user's ID.
        vc.userid = INT32(chat?.userID ?? 0)
        vc.conversationTitle = chat?.nickname ?? ""
        return vc
    }

    override func viewTitle() -> String {
        guard let chat else { return NSLocalizedString("Messages", comment: "text message") }
        return chat.nickname
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        NotificationCenter.default.addObserver(self, selector: #selector(monitorEvent(_:)), name: .monitorEvent, object: session?.connection)
        loadHistory()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        markRead()
    }

    private func markRead() {
        guard let conversation = chat?.conversationID, let session else { return }
        let api = session.connection.api
        let server = session.serverID
        Task { try? await api.markRead(server: server, conversation: conversation) }
    }

    private func privateMessage(_ m: MonitorPrivateMessage, nickname: String) -> MyTextMessage {
        var msg = MyTextMessage(fromuserid: INT32(m.outgoing ? 0 : chat?.userID ?? 0), nickname: nickname, msgtype: m.outgoing ? .PRIV_IM_MYSELF : .PRIV_IM, content: m.text)
        msg.date = m.date
        return msg
    }

    private func loadHistory() {
        guard let session else { return }
        let api = session.connection.api
        let server = session.serverID
        loading = true
        Task { @MainActor in
            defer {
                loading = false
                let held = arrivedWhileLoading
                arrivedWhileLoading = []
                held.forEach(monitorEvent)
            }
            do {
                if var chat {
                    // From a person in the channel list: their conversation
                    // during this login, if there is one yet.
                    if chat.conversationID == nil {
                        let all = try await api.conversations(server: server)
                        chat.conversationID = all.first { $0.userId == chat.userID && $0.active }?.id
                        self.chat = chat
                    }
                    if let id = chat.conversationID {
                        let (conversation, history, seq) = try await api.messages(server: server, conversation: id)
                        messages = history.map { privateMessage($0, nickname: conversation.nickname) }
                        shownThrough = max(shownThrough, seq)
                        updateClearButtonVisibility()
                        if !conversation.active {
                            ended = true
                            appendEventMessage(MyTextMessage(logmsg: conversation.nickname + " " + NSLocalizedString("has logged out", comment: "log entry")))
                        }
                        markRead()
                    }
                } else {
                    let events = try await api.recentEvents(server: server, limit: 300)
                    shownThrough = max(shownThrough, events.map(\.seq).max() ?? 0)
                    messages = events.compactMap { e in
                        guard var msg = Self.channelScreenMessage(e.event, session: session) else { return nil }
                        msg.date = e.date
                        return msg
                    }
                }
                updateTableView(animated: false)
            } catch {
                appendLogMessage(error.localizedDescription)
            }
        }
    }

    /// An event as the connected-server message screen would show it: a
    /// channel or broadcast message, or a server event.
    static func channelScreenMessage(_ e: MonitorEvent, session: MonitorSessionViewController) -> MyTextMessage? {
        switch e {
        case .message(let m):
            switch m.kind {
            case .channel:
                return MyTextMessage(fromuserid: INT32(m.from.id), nickname: m.from.nickname, msgtype: m.outgoing ? .CHAN_IM_MYSELF : .CHAN_IM, content: m.text)
            case .broadcast:
                return MyTextMessage(fromuserid: INT32(m.from.id), nickname: m.from.nickname, msgtype: .BCAST, content: m.text)
            case .user:
                return nil
            }
        case .loggedIn(let u):
            return MyTextMessage(logmsg: u.displayName + " " + NSLocalizedString("has logged in", comment: "log entry"))
        case .loggedOut(let u):
            return MyTextMessage(logmsg: u.displayName + " " + NSLocalizedString("has logged out", comment: "log entry"))
        case .joined(let u, _, let path):
            if u.id == session.model?.me.userId {
                return MyTextMessage(logmsg: String(format: NSLocalizedString("Joined channel %@", comment: "log entry"), path))
            }
            return MyTextMessage(logmsg: String(format: NSLocalizedString("%@ joined channel %@", comment: "log entry"), u.displayName, path))
        case .left(let u, _, let path):
            if u.id == session.model?.me.userId {
                return MyTextMessage(logmsg: String(format: NSLocalizedString("Left channel %@", comment: "log entry"), path))
            }
            return MyTextMessage(logmsg: String(format: NSLocalizedString("%@ left channel %@", comment: "log entry"), u.displayName, path))
        case .connection(let status, _) where status == .loggedIn:
            return MyTextMessage(logmsg: NSLocalizedString("Logged in to server", comment: "log entry"))
        case .connection, .kicked:
            return MonitorEventText.describe(e, model: session.model).map { MyTextMessage(logmsg: $0) }
        default:
            return nil
        }
    }

    @objc private func monitorEvent(_ n: Notification) {
        guard let session, let e = n.userInfo?["event"] as? MonitorStoredEvent, e.serverId == session.serverID else { return }
        if loading {
            arrivedWhileLoading.append(n)
            return
        }
        // Already on screen (in the loaded history, or shown before).
        guard e.seq > shownThrough else { return }
        shownThrough = e.seq
        if let chat {
            switch e.event {
            case .message(let m) where m.kind == .user && !m.intercepted && !ended:
                // Messages with this user ID, as in a TeamTalk private window.
                let other = m.outgoing ? m.to : m.from
                guard other?.id == chat.userID else { return }
                var msg = MyTextMessage(fromuserid: INT32(m.from.id), nickname: m.from.nickname, msgtype: m.outgoing ? .PRIV_IM_MYSELF : .PRIV_IM, content: m.text)
                msg.date = e.date
                appendEventMessage(msg)
                if chat.conversationID == nil {
                    // The first message started the conversation: learn it.
                    loadConversationID()
                } else if !m.outgoing {
                    markRead()
                }
            case .loggedOut(let u) where u.id == chat.userID && !ended:
                ended = true
                appendEventMessage(MyTextMessage(logmsg: u.displayName + " " + NSLocalizedString("has logged out", comment: "log entry")))
            default:
                return
            }
        } else {
            guard var msg = Self.channelScreenMessage(e.event, session: session) else { return }
            msg.date = e.date
            appendEventMessage(msg)
        }
        if isViewLoaded {
            updateTableView()
        }
    }

    /// A private conversation's button deletes it on the monitor (Clear
    /// would only empty the screen until it was opened again).
    override func updateClearButtonVisibility() {
        guard chat != nil else {
            super.updateClearButtonVisibility()
            return
        }
        navigationItem.rightBarButtonItem = chat?.conversationID == nil ? nil :
            UIBarButtonItem(title: NSLocalizedString("Delete", comment: "monitor conversation"), style: .plain, target: self, action: #selector(confirmClearMessages))
    }

    override func confirmClearMessages() {
        guard let chat, let conversation = chat.conversationID, let session else {
            super.confirmClearMessages()
            return
        }
        MonitorConversationDeletion.confirm(from: self, nickname: chat.nickname) { [weak self] in
            let api = session.connection.api
            let server = session.serverID
            Task { @MainActor in
                do {
                    try await api.deleteConversation(server: server, conversation: conversation)
                    self?.navigationController?.popViewController(animated: true)
                } catch {
                    MonitorConversationDeletion.failed(error, from: self)
                }
            }
        }
    }

    private func loadConversationID() {
        guard let session, let userID = chat?.userID else { return }
        let api = session.connection.api
        let server = session.serverID
        Task { @MainActor in
            let all = (try? await api.conversations(server: server)) ?? []
            if let id = all.first(where: { $0.userId == userID && $0.active })?.id {
                chat?.conversationID = id
                updateClearButtonVisibility()
                markRead()
            }
        }
    }

    override func sendTextMessage(_ sender: UIButton) {
        let content = msgTextView.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty, let session else {
            msgTextView.text = ""
            msgTextView.resignFirstResponder()
            return
        }
        let api = session.connection.api
        let server = session.serverID
        let chat = chat
        msgTextView.text = ""
        Task { @MainActor in
            do {
                // The monitor's own message comes back as an event and is
                // shown then.
                if let chat {
                    try await api.sendPrivateMessage(server: server, userID: chat.userID, conversationID: chat.conversationID, text: content)
                } else {
                    try await api.sendChannelMessage(server: server, channelID: nil, text: content)
                }
            } catch {
                msgTextView.text = content
                let alert = UIAlertController(title: NSLocalizedString("Message Not Sent", comment: "monitor"), message: error.localizedDescription, preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: NSLocalizedString("OK", comment: "monitor"), style: .default))
                present(alert, animated: true)
            }
        }
    }
}

/// The monitor's private conversations on one server, including with
/// people who have logged out.
final class MonitorConversationsViewController: UITableViewController {
    weak var session: MonitorSessionViewController?
    private var conversations: [MonitorConversation] = []

    init(session: MonitorSessionViewController) {
        self.session = session
        super.init(style: .plain)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        CompactUI.apply(to: self, title: NSLocalizedString("Private Messages", comment: "monitor"))
        CompactUI.apply(to: tableView)
        NotificationCenter.default.addObserver(self, selector: #selector(load), name: .monitorEvent, object: session?.connection)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        load()
    }

    @objc private func load() {
        guard let session else { return }
        let api = session.connection.api
        let server = session.serverID
        Task { @MainActor in
            conversations = (try? await api.conversations(server: server)) ?? conversations
            if conversations.isEmpty {
                CompactUI.setEmptyState(on: tableView, title: NSLocalizedString("No messages", comment: "text message"),
                                        message: NSLocalizedString("Private messages to the monitor will appear here.", comment: "monitor"))
            } else {
                CompactUI.clearEmptyState(on: tableView)
            }
            tableView.reloadData()
        }
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        conversations.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let c = conversations[indexPath.row]
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        cell.backgroundColor = CompactUI.secondaryBackgroundColor
        var title = c.nickname
        if !c.active { title += " " + NSLocalizedString("(logged out)", comment: "monitor") }
        if c.unread > 0 { title += ", " + String(format: NSLocalizedString("%d unread", comment: "monitor"), c.unread) }
        cell.textLabel?.text = title
        cell.detailTextLabel?.text = (c.lastOutgoing ? NSLocalizedString("Your Message", comment: "text message accessibility") + ": " : "") + c.lastText
        cell.detailTextLabel?.textColor = CompactUI.secondaryTextColor
        cell.detailTextLabel?.numberOfLines = 2
        cell.imageView?.image = UIImage(named: "message_blue")
        cell.accessoryType = .disclosureIndicator
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let c = conversations[indexPath.row]
        session?.showPrivateMessages(MonitorPrivateChat(userID: c.userId, conversationID: c.id, nickname: c.nickname))
    }

    override func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        let c = conversations[indexPath.row]
        let delete = UIContextualAction(style: .destructive, title: NSLocalizedString("Delete", comment: "monitor conversation")) { [weak self] _, _, done in
            self?.delete(c)
            done(false)
        }
        return UISwipeActionsConfiguration(actions: [delete])
    }

    override func tableView(_ tableView: UITableView, contextMenuConfigurationForRowAt indexPath: IndexPath, point: CGPoint) -> UIContextMenuConfiguration? {
        let c = conversations[indexPath.row]
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            UIMenu(children: [UIAction(title: NSLocalizedString("Delete Conversation", comment: "monitor conversation"), image: UIImage(systemName: "trash"), attributes: .destructive) { _ in
                self?.delete(c)
            }])
        }
    }

    private func delete(_ c: MonitorConversation) {
        guard let session else { return }
        MonitorConversationDeletion.confirm(from: self, nickname: c.nickname) { [weak self] in
            let api = session.connection.api
            Task { @MainActor in
                do {
                    try await api.deleteConversation(server: session.serverID, conversation: c.id)
                    UIAccessibility.post(notification: .announcement, argument: NSLocalizedString("Conversation deleted", comment: "monitor conversation"))
                    self?.load()
                } catch {
                    MonitorConversationDeletion.failed(error, from: self)
                }
            }
        }
    }
}

/// Asking before deleting a conversation, the same from the list and from
/// the conversation.
enum MonitorConversationDeletion {
    static func confirm(from vc: UIViewController, nickname: String, delete: @escaping () -> Void) {
        let alert = UIAlertController(
            title: NSLocalizedString("Delete Conversation?", comment: "monitor conversation"),
            message: String(format: NSLocalizedString("This deletes your conversation with %@ and its messages from the monitor.", comment: "monitor conversation"), nickname),
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: NSLocalizedString("Cancel", comment: "message dialog"), style: .cancel))
        alert.addAction(UIAlertAction(title: NSLocalizedString("Delete", comment: "monitor conversation"), style: .destructive) { _ in delete() })
        vc.present(alert, animated: true)
    }

    static func failed(_ error: Error, from vc: UIViewController?) {
        let alert = UIAlertController(title: NSLocalizedString("Conversation Not Deleted", comment: "monitor conversation"), message: error.localizedDescription, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: NSLocalizedString("OK", comment: "monitor"), style: .default))
        vc?.present(alert, animated: true)
    }
}

// MARK: - The screen

/// A monitored server's screen, laid out like a connected server's
/// (MainTabBarController): the channel list, with the bottom toolbar.
final class MonitorSessionViewController: UITabBarController {
    let connection: MonitorConnection
    let serverID: Int
    private(set) var model: MonitorServerModel?
    private let channelsTab: MonitorChannelListViewController
    private var channelMessages: MonitorTextMessageViewController?

    init(connection: MonitorConnection, serverID: Int) {
        self.connection = connection
        self.serverID = serverID
        channelsTab = mainStoryboard.instantiateViewController(identifier: "ChannelList") { coder in
            MonitorChannelListViewController(coder: coder)
        }
        super.init(nibName: nil, bundle: nil)
        channelsTab.session = self
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    private var summary: MonitorServerSummary? {
        connection.servers.first { $0.id == serverID } ?? model?.summary
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        viewControllers = [channelsTab]
        tabBar.isHidden = true
        channelsTab.tabBarItem.title = NSLocalizedString("Channels", comment: "main-tab")
        navigationItem.title = summary?.displayName ?? NSLocalizedString("Server", comment: "unnamed connected server")
        NotificationCenter.default.addObserver(self, selector: #selector(monitorEvent(_:)), name: .monitorEvent, object: connection)
        NotificationCenter.default.addObserver(self, selector: #selector(serverReloaded(_:)), name: .monitorServerReloaded, object: connection)
        // The server list arriving (or changing) can change the toolbar.
        NotificationCenter.default.addObserver(self, selector: #selector(serversChanged), name: .monitorChanged, object: connection)
        load()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        MonitorNotifications.shared.visibleServer = (connection.account.ref, serverID)
        updateBottomToolbar()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        // Its conversations, messages and other screens opened on top are
        // still this server, which keeps playing and speaking its events:
        // banners stay held back until the server itself is left.
        if isMovingFromParent || navigationController == nil {
            clearVisibleServer()
        }
        navigationController?.setToolbarHidden(true, animated: animated)
    }

    private func clearVisibleServer() {
        if MonitorNotifications.shared.visibleServer?.serverID == serverID {
            MonitorNotifications.shared.visibleServer = nil
        }
    }

    deinit {
        let id = serverID
        DispatchQueue.main.async {
            if MonitorNotifications.shared.visibleServer?.serverID == id {
                MonitorNotifications.shared.visibleServer = nil
            }
        }
    }

    private func load() {
        Task { @MainActor in
            do {
                let model = try await connection.model(for: serverID)
                show(model)
            } catch {
                let alert = UIAlertController(title: NSLocalizedString("Could Not Load the Server", comment: "monitor"), message: error.localizedDescription, preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: NSLocalizedString("OK", comment: "monitor"), style: .default))
                present(alert, animated: true)
            }
        }
    }

    private func show(_ model: MonitorServerModel) {
        self.model = model
        channelsTab.show(model)
        updateTitleAndStatus()
        updateBottomToolbar()
    }

    /// The server name, and when the monitor is not on the server, why.
    private func updateTitleAndStatus() {
        guard let model else { return }
        navigationItem.title = model.summary.displayName
        if model.summary.status == .loggedIn {
            CompactUI.clearEmptyState(on: channelsTab.tableView)
        } else {
            let reason = [model.summary.status.text, model.summary.reason].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ": ")
            CompactUI.setEmptyState(on: channelsTab.tableView, title: NSLocalizedString("The monitor is not on this server right now", comment: "monitor"), message: reason)
        }
    }

    @objc private func serversChanged() {
        updateBottomToolbar()
    }

    @objc private func serverReloaded(_ n: Notification) {
        guard n.userInfo?["server"] as? Int == serverID, let model = connection.models[serverID] else { return }
        show(model)
    }

    @objc private func monitorEvent(_ n: Notification) {
        guard let e = n.userInfo?["event"] as? MonitorStoredEvent, e.serverId == serverID else { return }
        if let model = connection.models[serverID] {
            show(model)
        }
        // Events missed while the app was away were already notified.
        if n.userInfo?["catchUp"] as? Bool == true {
            return
        }
        if let sound = MonitorSpeech.sound(e.event, model: connection.models[serverID]) {
            playSound(sound)
        }
        if let text = MonitorSpeech.utterance(e.event, model: connection.models[serverID]) {
            newUtterance(text)
        }
    }

    // MARK: Acting

    /// Run a monitor request, showing what went wrong if it fails.
    func run(presentingFrom presenter: UIViewController? = nil, _ work: @escaping (MonitorAPI, Int) async throws -> Void) {
        let api = connection.api
        let id = serverID
        Task { @MainActor in
            do {
                try await work(api, id)
            } catch {
                let alert = UIAlertController(title: NSLocalizedString("The Monitor Could Not Do That", comment: "monitor"), message: error.localizedDescription, preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: NSLocalizedString("OK", comment: "monitor"), style: .default))
                (presenter ?? self).present(alert, animated: true)
            }
        }
    }

    func showPrivateMessages(_ chat: MonitorPrivateChat) {
        navigationController?.pushViewController(MonitorTextMessageViewController.make(session: self, chat: chat), animated: true)
    }

    // MARK: Bottom toolbar, as on a connected server

    func updateBottomToolbar() {
        guard isViewLoaded, navigationController?.topViewController === self else { return }
        var buttons: [UIButton] = []
        let settings = toolbarButton(imageName: "gearshape", label: NSLocalizedString("Monitor Settings", comment: "monitor"), action: #selector(showSettings))
        buttons.append(settings)
        // Always there, and early, so narrow screens show it without scrolling.
        if connectTarget != nil {
            buttons.append(toolbarButton(imageName: "phone.connection", label: NSLocalizedString("Connect", comment: "connect to server"), action: #selector(connectLive)))
        }
        if model?.me.channelId != nil {
            buttons.append(toolbarButton(imageName: "message", label: NSLocalizedString("Messages", comment: "main-tab"), action: #selector(showChannelMessages)))
        }
        let privateMessages = toolbarButton(imageName: "envelope", label: NSLocalizedString("Private Messages", comment: "monitor"), action: #selector(showConversations))
        if let unread = summary?.unreadPrivateMessages, unread > 0 {
            privateMessages.accessibilityValue = String(format: NSLocalizedString("%d unread", comment: "monitor"), unread)
        }
        buttons.append(privateMessages)
        if isAdmin {
            let manage = toolbarButton(imageName: "person.2.badge.gearshape", label: NSLocalizedString("Manage Server", comment: "main-tab"), action: #selector(showManageServerActions))
            manage.menu = manageServerMenu()
            manage.showsMenuAsPrimaryAction = true
            buttons.append(manage)
        }
        if canBroadcast {
            buttons.append(toolbarButton(imageName: "star.bubble", label: NSLocalizedString("Broadcast Message", comment: "main-tab"), action: #selector(showBroadcast)))
        }
        toolbarItems = [UIBarButtonItem(customView: toolbarScrollView(buttons: buttons))]
        navigationController?.setToolbarHidden(false, animated: false)
    }

    private var isAdmin: Bool {
        guard let me = model?.me else { return false }
        return (UINT32(truncatingIfNeeded: me.userType) & USERTYPE_ADMIN.rawValue) != 0
    }

    /// The same Manage Server menu as on a connected server.
    private func manageServerMenu() -> UIMenu {
        UIMenu(title: NSLocalizedString("Manage Server", comment: "main-tab"), children: [
            UIAction(title: NSLocalizedString("Accounts", comment: "main-tab"), image: UIImage(systemName: "person.2")) { [weak self] _ in
                self?.showAdminTools(initialSection: 0)
            },
            UIAction(title: NSLocalizedString("Bans", comment: "main-tab"), image: UIImage(systemName: "hand.raised")) { [weak self] _ in
                self?.showAdminTools(initialSection: 1)
            },
            UIAction(title: NSLocalizedString("Edit Server Properties", comment: "main-tab"), image: UIImage(systemName: "slider.horizontal.3")) { [weak self] _ in
                self?.showServerProperties()
            },
        ])
    }

    @objc private func showManageServerActions() {
        let sheet = UIAlertController(title: NSLocalizedString("Manage Server", comment: "main-tab"), message: nil, preferredStyle: .actionSheet)
        sheet.addAction(UIAlertAction(title: NSLocalizedString("Accounts", comment: "main-tab"), style: .default) { [weak self] _ in self?.showAdminTools(initialSection: 0) })
        sheet.addAction(UIAlertAction(title: NSLocalizedString("Bans", comment: "main-tab"), style: .default) { [weak self] _ in self?.showAdminTools(initialSection: 1) })
        sheet.addAction(UIAlertAction(title: NSLocalizedString("Edit Server Properties", comment: "main-tab"), style: .default) { [weak self] _ in self?.showServerProperties() })
        sheet.addAction(UIAlertAction(title: NSLocalizedString("Cancel", comment: "Dialog message"), style: .cancel))
        sheet.popoverPresentationController?.sourceView = view
        present(sheet, animated: true)
    }

    /// The monitored server as a saved-server entry, for exporting accounts.
    private var serverEntry: Server {
        if let saved = savedServer { return saved }
        let s = Server()
        s.name = summary?.displayName ?? ""
        s.ipaddr = summary?.host ?? ""
        s.tcpport = summary?.tcpPort ?? AppInfo.DEFAULT_TCPPORT
        s.encrypted = summary?.encrypted ?? false
        return s
    }

    private func showAdminTools(initialSection: Int) {
        let model = MonitorAdminToolsModel(session: self, server: serverEntry)
        navigationController?.pushViewController(AdminToolsViewController(model: model, initialSection: initialSection), animated: true)
    }

    private func showServerProperties() {
        navigationController?.pushViewController(ServerPropertiesViewController(model: MonitorServerPropertiesModel(session: self)), animated: true)
    }

    private var canBroadcast: Bool {
        guard let me = model?.me else { return false }
        return (UINT32(truncatingIfNeeded: me.userType) & USERTYPE_ADMIN.rawValue) != 0
            || (UINT32(truncatingIfNeeded: me.userRights) & USERRIGHT_TEXTMESSAGE_BROADCAST.rawValue) != 0
    }

    /// The saved server this monitored server came from.
    /// The saved server for this monitored server: same address and port,
    /// preferring the same account (the monitor may use an account of its
    /// own).
    private var savedServer: Server? {
        guard let s = summary else { return nil }
        let host = s.host.trimmingCharacters(in: .whitespacesAndNewlines)
        let sameAddress = loadLocalServers().filter {
            $0.ipaddr.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(host) == .orderedSame && $0.tcpport == s.tcpPort
        }
        return sameAddress.first { $0.username == s.username } ?? sameAddress.first
    }

    /// What Connect connects to: the saved server, or (when there is none,
    /// say it was deleted or changed) the monitored address, which the
    /// connected screen then offers to save.
    private var connectTarget: Server? {
        if let saved = savedServer { return saved }
        guard let s = summary else { return nil }
        let server = Server()
        server.name = s.displayName
        server.ipaddr = s.host.trimmingCharacters(in: .whitespacesAndNewlines)
        server.tcpport = s.tcpPort
        server.udpport = s.tcpPort
        server.encrypted = s.encrypted
        return server
    }

    private func toolbarButton(imageName: String, label: String, action: Selector) -> UIButton {
        let button = UIButton(type: .system)
        button.setImage(UIImage(systemName: imageName), for: .normal)
        button.accessibilityLabel = label
        button.addTarget(self, action: action, for: .touchUpInside)
        button.widthAnchor.constraint(equalToConstant: 48).isActive = true
        button.heightAnchor.constraint(equalToConstant: 44).isActive = true
        return button
    }

    private func toolbarScrollView(buttons: [UIButton]) -> UIScrollView {
        let scrollView = UIScrollView(frame: CGRect(x: 0, y: 0, width: view.bounds.width, height: 44))
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.alwaysBounceHorizontal = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.heightAnchor.constraint(equalToConstant: 44).isActive = true
        scrollView.widthAnchor.constraint(equalToConstant: view.bounds.width).isActive = true
        let stackView = UIStackView(arrangedSubviews: buttons)
        stackView.axis = .horizontal
        stackView.alignment = .center
        stackView.distribution = .equalSpacing
        stackView.spacing = 16
        stackView.layoutMargins = UIEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)
        stackView.isLayoutMarginsRelativeArrangement = true
        stackView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(stackView)
        NSLayoutConstraint.activate([
            stackView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            stackView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            stackView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            stackView.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor),
        ])
        return scrollView
    }

    @objc private func showSettings() {
        let sheet = UIAlertController(title: NSLocalizedString("Monitor Settings", comment: "monitor"), message: nil, preferredStyle: .actionSheet)
        sheet.addAction(UIAlertAction(title: NSLocalizedString("Server Settings", comment: "monitor"), style: .default) { [weak self] _ in
            guard let self else { return }
            navigationController?.pushViewController(MonitorServerEditViewController(connection: connection, serverID: serverID), animated: true)
        })
        let muted = connection.isMutedByHand(serverID)
        sheet.addAction(UIAlertAction(title: muted ? NSLocalizedString("Unmute Notifications", comment: "monitor") : NSLocalizedString("Mute Notifications", comment: "monitor"), style: .default) { [weak self] _ in
            guard let self else { return }
            let id = serverID
            Task { @MainActor in
                do {
                    try await MonitorCenter.shared.setMuted(id, !muted)
                    UIAccessibility.post(notification: .announcement, argument: muted
                        ? NSLocalizedString("Notifications unmuted", comment: "monitor")
                        : NSLocalizedString("Notifications muted", comment: "monitor"))
                } catch {
                    self.run { _, _ in throw error }
                }
            }
        })
        sheet.addAction(UIAlertAction(title: NSLocalizedString("Change Nickname", comment: "monitor"), style: .default) { [weak self] _ in
            self?.compose(title: NSLocalizedString("Nickname", comment: "monitor"), allowEmpty: false) { text in
                // The service also saves it in the monitor's settings.
                self?.run { [weak self] api, server in
                    try await api.act(server: server, "nickname", ["nickname": text])
                    await self?.connection.refreshServers()
                }
            }
        })
        sheet.addAction(UIAlertAction(title: NSLocalizedString("Change Status Message", comment: "monitor"), style: .default) { [weak self] _ in
            self?.compose(title: NSLocalizedString("Status Message", comment: "monitor"), allowEmpty: true) { text in
                // Keep the monitor's gender, which shares the status mode.
                let mode = self.flatMap { s in s.model?.users.first { $0.id == s.model?.me.userId } }?.statusMode ?? 0
                self?.run { api, server in try await api.act(server: server, "status", ["status_mode": mode & (MonitorGender.female | MonitorGender.neutral), "status_msg": text]) }
            }
        })
        sheet.addAction(UIAlertAction(title: NSLocalizedString("Cancel", comment: "Dialog message"), style: .cancel))
        sheet.popoverPresentationController?.sourceView = view
        present(sheet, animated: true)
    }

    @objc private func showChannelMessages() {
        let vc = channelMessages ?? MonitorTextMessageViewController.make(session: self, chat: nil)
        channelMessages = vc
        navigationController?.pushViewController(vc, animated: true)
    }

    @objc private func showConversations() {
        navigationController?.pushViewController(MonitorConversationsViewController(session: self), animated: true)
    }

    @objc private func showBroadcast() {
        compose(title: NSLocalizedString("Broadcast Message", comment: "main-tab"), allowEmpty: false) { [weak self] text in
            self?.run { api, server in try await api.sendBroadcast(server: server, text: text) }
        }
    }

    /// Connect to the server for real, as from the server list.
    @objc private func connectLive() {
        guard let target = connectTarget, let nav = navigationController,
              let serverList = nav.viewControllers.first as? ServerListViewController else { return }
        nav.popToRootViewController(animated: false)
        serverList.connect(to: target)
    }

    private func compose(title: String, allowEmpty: Bool, send: @escaping (String) -> Void) {
        let alert = UIAlertController(title: title, message: nil, preferredStyle: .alert)
        alert.addTextField { $0.autocapitalizationType = .sentences }
        alert.addAction(UIAlertAction(title: NSLocalizedString("Cancel", comment: "Dialog message"), style: .cancel))
        alert.addAction(UIAlertAction(title: NSLocalizedString("OK", comment: "monitor"), style: .default) { _ in
            let text = alert.textFields?.first?.text ?? ""
            guard allowEmpty || !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
            send(text)
        })
        present(alert, animated: true)
    }
}

/// Sounds and speech for a monitored server's events, with the same words,
/// sound events and text-to-speech event settings as a connected server.
enum MonitorSpeech {
    private static func enabled(_ key: String) -> Bool {
        let defaults = UserDefaults.standard
        return defaults.object(forKey: key) == nil || defaults.bool(forKey: key)
    }

    /// A user's name as a connected server shows it.
    static func name(_ nickname: String, username: String, id: Int) -> String {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: PREF_DISPLAY_SHOWUSERNAME) != nil && defaults.bool(forKey: PREF_DISPLAY_SHOWUSERNAME) {
            return limitText(username)
        }
        if nickname.isEmpty {
            return DEFAULT_NICKNAME + " - #\(id)"
        }
        return limitText(nickname)
    }

    private static func name(_ u: MonitorUser) -> String { name(u.nickname, username: u.username, id: u.id) }
    private static func name(_ u: MonitorUserRef) -> String { name(u.nickname, username: u.username, id: u.id) }

    private static func channelName(_ id: Int, path: String, model: MonitorServerModel?) -> String {
        let parent = model?.channel(id)?.parentId
        if parent == 0 || (parent == nil && (path.isEmpty || path == "/")) {
            return NSLocalizedString("root", comment: "TTS EVENT")
        }
        let name = model?.channel(id)?.name ?? path.split(separator: "/").last.map(String.init) ?? ""
        return name.isEmpty ? NSLocalizedString("channel", comment: "TTS EVENT") : name
    }

    private static func isMyChannel(_ id: Int, model: MonitorServerModel?) -> Bool {
        guard let mine = model?.me.channelId, mine > 0 else { return false }
        return mine == id
    }

    static func sound(_ e: MonitorEvent, model: MonitorServerModel?) -> Sounds? {
        switch e {
        case .joined(_, let channelID, _) where isMyChannel(channelID, model: model):
            return .joined_CHAN
        case .left(_, let channelID, _) where isMyChannel(channelID, model: model):
            return .left_CHAN
        default:
            return MonitorEventText.sound(e)
        }
    }

    static func utterance(_ e: MonitorEvent, model: MonitorServerModel?) -> String? {
        switch e {
        case .connection(let status, _):
            switch status {
            case .loggedIn:
                guard enabled(PREF_TTSEVENT_USERLOGIN) else { return nil }
                let server = model?.summary.displayName ?? NSLocalizedString("server", comment: "TTS EVENT")
                return String(format: NSLocalizedString("Logged in to %@", comment: "TTS EVENT"), server)
            case .disconnected:
                return enabled(PREF_TTSEVENT_CONLOST) ? NSLocalizedString("Connection lost", comment: "tts event") : nil
            case .loginFailed, .steppedAside:
                return enabled(PREF_TTSEVENT_CONLOST) ? MonitorEventText.describe(e, model: model) : nil
            default:
                return nil
            }
        case .loggedIn(let u):
            guard enabled(PREF_TTSEVENT_USERLOGIN) else { return nil }
            return name(u) + " " + NSLocalizedString("has logged in", comment: "TTS EVENT")
        case .loggedOut(let u):
            guard enabled(PREF_TTSEVENT_USERLOGOUT) else { return nil }
            return name(u) + " " + NSLocalizedString("has logged out", comment: "TTS EVENT")
        case .joined(let u, let channelID, let path):
            guard enabled(PREF_TTSEVENT_JOINEDCHAN), u.id != model?.me.userId else { return nil }
            if isMyChannel(channelID, model: model) {
                return String(format: NSLocalizedString("%@ joined channel", comment: "TTS EVENT"), name(u))
            }
            return String(format: NSLocalizedString("%@ joined channel %@", comment: "TTS EVENT"), name(u), channelName(channelID, path: path, model: model))
        case .left(let u, let channelID, let path):
            guard enabled(PREF_TTSEVENT_LEFTCHAN), u.id != model?.me.userId else { return nil }
            if isMyChannel(channelID, model: model) {
                return String(format: NSLocalizedString("%@ left channel", comment: "TTS EVENT"), name(u))
            }
            return String(format: NSLocalizedString("%@ left channel %@", comment: "TTS EVENT"), name(u), channelName(channelID, path: path, model: model))
        case .myChannel(let id):
            if let id, let c = model?.channel(id) {
                guard enabled(PREF_TTSEVENT_JOINEDCHAN) else { return nil }
                return String(format: NSLocalizedString("Joined channel %@", comment: "TTS EVENT"), channelName(id, path: c.path, model: model))
            }
            return nil
        case .kicked:
            return enabled(PREF_TTSEVENT_CONLOST) ? MonitorEventText.describe(e, model: model) : nil
        case .message(let m) where !m.outgoing:
            let from = limitText(name(m.from))
            switch m.kind {
            case .user:
                guard enabled(PREF_TTSEVENT_TEXTMSG) else { return nil }
                return String(format: NSLocalizedString("Private text message from %@. %@", comment: "TTS EVENT"), from, m.text)
            case .channel:
                guard enabled(PREF_TTSEVENT_CHANTEXTMSG) else { return nil }
                return String(format: NSLocalizedString("Channel message from %@. %@", comment: "TTS EVENT"), from, m.text)
            case .broadcast:
                guard enabled(PREF_TTSEVENT_BROADCASTMSG) else { return nil }
                return String(format: NSLocalizedString("Broadcast message from %@: %@", comment: "TTS EVENT"), from, m.text)
            }
        default:
            return nil
        }
    }
}
