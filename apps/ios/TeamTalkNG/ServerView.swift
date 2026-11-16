import SwiftUI

/// One server: its channels with the people in them, the conversation, and
/// talking. Magic Tap (two-finger double-tap) talks or mutes from anywhere.
struct ServerView: View {
    @Environment(AppModel.self) private var model
    let connection: ServerConnection
    @State private var tab = Tab.channels
    @State private var passwordFor: Channel?
    @State private var channelPassword = ""
    @State private var privateWith: User?
    @State private var personFor: User?
    @State private var showStatus = false
    @State private var showAudioNet = false
    @State private var channelSheet: ChannelSheet?
    @State private var movingUser: User?
    /// The desktop's Users submenus and Volume dialog.
    @State private var userDialog: UserDialog?
    @State private var pickingUpload = false
    @State private var banning: BanTarget?
    @State private var deletingChannel: Channel?
    @State private var bansOf: Channel?
    @State private var infoOf: Channel?
    @State private var joiningByPath = false
    @State private var joinPath = ""
    @State private var joinPassword = ""
    @State private var pickingStream = false
    @State private var classroomOf: Channel?
    @State private var showServerSettings = false
    @State private var showBans = false
    @State private var showAccounts = false
    @State private var showStats = false
    @State private var showOnline = false
    @State private var showServerVolume = false
    @State private var showMoveUsers = false
    @State private var showClientStats = false
    @State private var broadcasting = false
    @State private var broadcastText = ""
    @State private var renaming = false
    @State private var newNickname = ""
    /// The row VoiceOver is on (the desktop's selected item, for its shortcuts).
    @AccessibilityFocusState private var voFocus: String?

    enum Tab: String, CaseIterable, Identifiable {
        case channels = "Channels", chat = "Chat", files = "Files"
        var id: Self { self }
    }

    var body: some View {
        VStack(spacing: 0) {
            if !connection.isConnected {
                notConnected
            } else {
                Picker("Show", selection: $tab) {
                    ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                switch tab {
                case .channels: channels
                case .chat: ChatView(connection: connection, privateWith: nil)
                case .files: FilesView(connection: connection)
                }
                if connection.hasAudio {
                    if let st = connection.snapshot?.streaming {
                        StreamBar(connection: connection, stream: st)
                    }
                    TalkBar(connection: connection)
                }
                // The desktop's status bar: its latest message.
                if !connection.statusLine.isEmpty {
                    Text(connection.statusLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal)
                        .padding(.bottom, 4)
                        .accessibilityLabel("Status: \(connection.statusLine)")
                }
            }
        }
        .navigationTitle(connection.snapshot?.server.name.nonEmpty ?? connection.server.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // Monitor mode: the Monitor's own settings and conversations.
            if let id = connection.monitorId {
                ToolbarItem(placement: .topBarLeading) {
                    NavigationLink("Monitor") { MonitorServerView(serverId: id) }
                }
            }
            if connection.isConnected {
                ToolbarItem(placement: .topBarTrailing) {
                    // One list for the menu and its VoiceOver actions (reversed,
                    // the owner's choice); what's on says its opposite, so
                    // nothing needs a check mark.
                    // Redrawn only when its items change (not with every
                    // second of a streamed file).
                    MoreMenu(items: moreItems).equatable()
                }
            }
        }
        .accessibilityAction(.magicTap) { if connection.hasAudio { connection.toggleTalking() } }
        // A hardware keyboard: the desktop's shortcuts (Help lists them).
        .background { DesktopShortcuts(run: perform) }
        .onAppear { connection.screenOpen = true; connection.connect() }
        .onDisappear { connection.screenOpen = false }
        // The Monitor's view is followed while it's on screen.
        .onDisappear { connection.leaveMonitorView() }
        .alert("Channel password", isPresented: Binding(get: { passwordFor != nil }, set: { if !$0 { passwordFor = nil } })) {
            SecureField("Password", text: $channelPassword).accessibilityLabel("Password")
            Button("Join") {
                if let c = passwordFor { connection.join(c, password: channelPassword) }
                channelPassword = ""
            }
            Button("Cancel", role: .cancel) { channelPassword = "" }
        } message: {
            Text("\(passwordFor?.name ?? "This channel") needs a password.")
        }
        .modifier(DesktopDialogs(connection: connection, privateWith: $privateWith, busy: personFor != nil))
        .sheet(item: $privateWith) { user in
            NavigationStack {
                ChatView(connection: connection, privateWith: user)
                    .navigationTitle(user.displayName)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) { Button("Done") { privateWith = nil } }
                    }
            }
        }
        .sheet(item: $personFor) { user in
            PersonView(connection: connection, userId: user.id) { privateWith = $0 } move: { movingUser = $0 }
        }
        .sheet(isPresented: $showStatus) {
            StatusView(connection: connection)
        }
        .sheet(item: $channelSheet) { sheet in
            ChannelEditView(connection: connection, sheet: sheet)
        }
        .sheet(item: $infoOf) { c in
            ChannelInfoView(connection: connection, channelId: c.id)
        }
        .alert("Join a channel by its path", isPresented: $joiningByPath) {
            TextField("Path, like /Lobby/Secret/", text: $joinPath).accessibilityLabel("Channel path")
                .textInputAutocapitalization(.never)
            SecureField("Password (if any)", text: $joinPassword).accessibilityLabel("Password (if any)")
            Button("Join") { connection.joinByPath(joinPath, password: joinPassword); joinPassword = "" }
            Button("Cancel", role: .cancel) { joinPassword = "" }
        } message: {
            Text("For hidden channels, which aren't listed.")
        }
        .fileImporter(isPresented: $pickingUpload, allowedContentTypes: [.item]) { result in
            if case .success(let url) = result { connection.upload(url) }
        }
        .fileImporter(isPresented: $pickingStream, allowedContentTypes: [.audio, .movie]) { result in
            if case .success(let url) = result { connection.streamFile(url) }
        }
        .sheet(item: $bansOf) { c in
            ChannelBansView(connection: connection, channel: c)
        }
        .sheet(item: $classroomOf) { c in
            ClassroomView(connection: connection, channelId: c.id)
        }
        .sheet(item: $userDialog) { d in
            switch d.kind {
            case .subscriptions: SubscriptionsDialog(connection: connection, user: d.user)
            case .transmit: TransmitDialog(connection: connection, user: d.user)
            default: UserVolumeDialog(connection: connection, user: d.user)
            }
        }
        .confirmationDialog(banning.map { $0.fromChannel ? "Kick and ban \($0.user.displayName) from the channel" : "Kick and ban \($0.user.displayName) from the server" } ?? "",
                            isPresented: Binding(get: { banning != nil }, set: { if !$0 { banning = nil } }), titleVisibility: .visible) {
            if let b = banning {
                Button("Ban by username") {
                    if b.fromChannel { connection.banFromChannel(b.user, by: .username) } else { connection.ban(b.user, by: .username) }
                }
                Button("Ban by IP address") {
                    if b.fromChannel { connection.banFromChannel(b.user, by: .ipAddress) } else { connection.ban(b.user, by: .ipAddress) }
                }
            }
        }
        .sheet(item: $movingUser) { user in
            MoveView(connection: connection, user: user)
        }
        .sheet(isPresented: $showServerSettings) {
            ServerSettingsView(connection: connection)
        }
        .sheet(isPresented: $showBans) {
            BansView(connection: connection)
        }
        .sheet(isPresented: $showAccounts) { AccountsView(connection: connection) }
        .sheet(isPresented: $showServerVolume) { ServerVolumeView(connection: connection) }
        .sheet(isPresented: $showAudioNet) { AudioNetView(connection: connection) }
        .sheet(isPresented: $showMoveUsers) { MoveUsersView(connection: connection) }
        .sheet(isPresented: $showStats) { ServerStatisticsView(connection: connection) }
        .sheet(isPresented: $showClientStats) { ClientStatisticsView(connection: connection) }
        .sheet(isPresented: $showOnline) { OnlineUsersView(connection: connection) { personFor = $0 } }
        .alert("Change nickname", isPresented: $renaming) {
            TextField("Nickname", text: $newNickname).accessibilityLabel("Nickname")
            Button("Change") { connection.setNickname(newNickname) }
            Button("Cancel", role: .cancel) {}
        }
        .onChange(of: renaming) { if renaming { newNickname = connection.me?.nickname ?? "" } }
        .alert("Broadcast message", isPresented: $broadcasting) {
            TextField("Message to everyone", text: $broadcastText).accessibilityLabel("Message to everyone")
            Button("Send") { connection.broadcast(broadcastText); broadcastText = "" }
            Button("Cancel", role: .cancel) { broadcastText = "" }
        } message: {
            Text("Everyone on the server gets it.")
        }
        .confirmationDialog(
            "Delete \(deletingChannel?.name ?? "this channel")?",
            isPresented: Binding(get: { deletingChannel != nil }, set: { if !$0 { deletingChannel = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) { if let c = deletingChannel { connection.removeChannel(c) } }
        } message: {
            Text("Its subchannels and files go too.")
        }
    }

    private var notConnected: some View {
        VStack(spacing: 16) {
            Spacer()
            Text(connection.stateText)
                .multilineTextAlignment(.center)
            if connection.state == .disconnected {
                Button(connection.busy ? "Connecting…" : "Connect") { connection.connect() }
                    .buttonStyle(.borderedProminent)
                    .disabled(connection.busy)
            } else if case .reconnecting = connection.state {
                Button("Stop trying", role: .destructive) { connection.disconnect() }
                    .buttonStyle(.bordered)
            }
            Spacer()
        }
        .padding()
    }

    private var rootId: Int32 { connection.snapshot?.channels.first { $0.parentId == 0 }?.id ?? 0 }

    private var channels: some View {
        let snap = connection.snapshot
        let rows = snap.map { ChannelTree.rows($0, byName: model.sortChannelsByName, expanded: connection.expanded) } ?? []
        return List(rows) { row in
            Group {
            switch row {
            case .channel(let c, let depth):
                ChannelRow(channel: c, depth: depth, snapshot: snap!, rights: connection.rights,
                           newSub: { channelSheet = .new(parent: c.id, temporary: !connection.rights.modifyChannels) },
                           edit: { channelSheet = .edit(c) },
                           delete: { deletingChannel = c },
                           moderate: connection.canModerate(channel: c.id),
                           bans: { bansOf = c }, classroom: { classroomOf = c }, info: { infoOf = c },
                           picked: connection.pickedToMove, movePicked: { connection.movePicked(to: c) },
                           copyLink: {
                               UIPasteboard.general.string = connection.link(to: c, withAccount: false, channelPassword: "")
                               announce("Link to \(c.parentId == 0 ? "the root channel" : c.name) copied")
                           },
                           showTopic: model.showTopics, tap: model.channelTap,
                           expandable: ChannelTree.hasRows(c, snap!),
                           expanded: connection.isExpanded(c),
                           setExpanded: { connection.setExpanded(c, $0) },
                           connection: connection,
                           style: model.infoStyle, showCount: model.showUserCount,
                           showIcons: model.showIcons, maxLength: model.maxTextLength,
                           stream: { pickingStream = true },
                           upload: { pickingUpload = true }) {
                    let here = c.id == snap?.myChannelId
                    switch model.channelTap {
                    case .nothing: break
                    case .joinOrLeave where here: connection.leaveChannel()
                    default:
                        if here { break }
                        if c.hasPassword { passwordFor = c } else { connection.join(c) }
                    }
                }
            case .user(let u, let depth):
                UserRow(user: u, depth: depth, isMe: u.id == snap?.myUserId, showUsername: model.showUsernames,
                        connection: connection, style: model.infoStyle, showIcons: model.showIcons,
                        maxLength: model.maxTextLength,
                        lastToTalk: model.showLastTalk && connection.lastTalker == u.id) { kind in
                    switch kind {
                    case .info: personFor = u
                    case .messages: privateWith = u
                    case .move: movingUser = u
                    case .banServer: banning = BanTarget(user: u, fromChannel: false)
                    case .banChannel: banning = BanTarget(user: u, fromChannel: true)
                    default: userDialog = UserDialog(user: u, kind: kind)
                    }
                }
            }
            }
            .accessibilityFocused($voFocus, equals: row.id)
        }
        .listStyle(.plain)
    }
}

extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}

/// The channel tree, flattened: each channel, then its people, then its
/// subchannels, alphabetically.
enum ChannelTree {
    enum Row: Identifiable {
        case channel(Channel, depth: Int)
        case user(User, depth: Int)
        var id: String {
            switch self {
            case .channel(let c, _): "c\(c.id)"
            case .user(let u, _): "u\(u.id)"
            }
        }
    }

    /// `byName`: channels alphabetically, else in the server's order.
    /// `expanded`: the channels whose people and subchannels show (all
    /// when nil).
    static func rows(_ s: Snapshot, byName: Bool = true, expanded: Set<Int32>? = nil) -> [Row] {
        var out: [Row] = []
        func population(_ id: Int32) -> Int {
            let inside = descendants(id, s)
            return s.users.filter { $0.channelId == id || inside.contains($0.channelId) }.count
        }
        func add(_ c: Channel, _ depth: Int) {
            out.append(.channel(c, depth: depth))
            if let expanded, !expanded.contains(c.id) { return }
            for u in s.users.filter({ $0.channelId == c.id }).sorted(by: { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }) {
                out.append(.user(u, depth: depth + 1))
            }
            let subs = s.channels.filter { $0.parentId == c.id }
            let byNameOrder = { (a: Channel, b: Channel) in a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending }
            // The desktop's sort: ascending, or popularity (most people,
            // subchannels included, first; then by name).
            let sorted = byName ? subs.sorted(by: byNameOrder) : subs.sorted {
                let (x, y) = (population($0.id), population($1.id))
                return x != y ? x > y : byNameOrder($0, $1)
            }
            for sub in sorted { add(sub, depth + 1) }
        }
        for root in s.channels where root.parentId == 0 { add(root, 0) }
        return out
    }

    /// Every channel inside one, at any depth.
    static func descendants(_ id: Int32, _ s: Snapshot) -> Set<Int32> {
        var out = Set<Int32>(), todo = [id]
        while let c = todo.popLast() {
            for sub in s.channels where sub.parentId == c && out.insert(sub.id).inserted { todo.append(sub.id) }
        }
        return out
    }

    /// Whether a channel has anything to expand (people or subchannels).
    static func hasRows(_ c: Channel, _ s: Snapshot) -> Bool {
        s.users.contains { $0.channelId == c.id } || s.channels.contains { $0.parentId == c.id }
    }
}

private struct ChannelRow: View {
    let channel: Channel
    let depth: Int
    let snapshot: Snapshot
    let rights: MyRights
    let newSub: () -> Void
    let edit: () -> Void
    let delete: () -> Void
    let moderate: Bool
    let bans: () -> Void
    let classroom: () -> Void
    let info: () -> Void
    let picked: Set<Int32>
    let movePicked: () -> Void
    let copyLink: () -> Void
    let showTopic: Bool
    let tap: AppModel.ChannelTap
    let expandable: Bool
    let expanded: Bool
    let setExpanded: (Bool) -> Void
    var connection: ServerConnection? = nil
    var style: AppModel.InfoStyle = .text
    var showCount = true
    var showIcons = true
    var maxLength = 50
    var stream: () -> Void = {}
    var upload: () -> Void = {}
    let join: () -> Void

    private var name: String { channel.parentId == 0 ? (snapshot.server.name.nonEmpty ?? "Root channel") : channel.name }
    private var here: Bool { snapshot.myChannelId == channel.id }
    private var hint: String {
        switch tap {
        case .nothing: ""
        case .joinOrLeave: here ? "Double-tap to leave." : "Double-tap to join."
        case .join: here ? "" : "Double-tap to join."
        }
    }

    /// The desktop's channel item text (channelstree.cpp updateChannelItem):
    /// name (the server's for root), (people) or (here/with subchannels),
    /// hidden and password marks, and ": topic" when topics are shown.
    private var desktopText: (display: String, spoken: String) {
        var display = name, spoken = name
        if display.count > maxLength { display = String(display.prefix(maxLength)) + "..." }
        if showCount {
            let count = snapshot.users.filter { $0.channelId == channel.id }.count
            let subs = ChannelTree.descendants(channel.id, snapshot)
            let suffix = subs.isEmpty ? " (\(count))"
                : " (\(count)/\(snapshot.users.filter { $0.channelId == channel.id || subs.contains($0.channelId) }.count))"
            display += suffix; spoken += suffix
        }
        for (on, emoji, text) in [(channel.hidden, "👻", "Hidden"), (channel.hasPassword, "🔒", "Password protected")] where on {
            switch style {
            case .emoji: display += " - \(emoji)"; spoken += " - \(emoji)"
            case .text: display += " - \(text)"; spoken += " - \(text)"
            case .none: break
            }
        }
        if showTopic && !channel.topic.isEmpty { spoken += ": \(channel.topic)" }
        return (display, spoken)
    }

    /// As the desktop says it after the channel: expanded or collapsed.
    private var state: String {
        expandable ? (expanded ? "Expanded" : "Collapsed") : ""
    }

    var body: some View {
        HStack {
            Button(action: join) {
                HStack {
                    if showIcons { Image(systemName: here ? "folder.fill" : "folder") }
                    VStack(alignment: .leading) {
                        Text(desktopText.display).font(.body.weight(here ? .semibold : .regular))
                        if showTopic && !channel.topic.isEmpty {
                            Text(channel.topic).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.leading, CGFloat(depth) * 16)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // The disclosure arrow, on the right.
            if expandable {
                Button { withAnimation { setExpanded(!expanded) } } label: {
                    Image(systemName: "chevron.right")
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .foregroundStyle(.secondary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .foregroundStyle(.primary)
        // One element for VoiceOver: a heading, double-tap as set, and
        // Expand or Collapse first among its actions.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(desktopText.spoken)
        .accessibilityValue(state)
        .accessibilityHint(hint)
        .accessibilityAddTraits([.isButton, .isHeader])
        .accessibilityAction { join() }
        .contextMenu { ForEach(menu) { Button($0.title, action: $0.action) } }
        .accessibilityActions { ForEach(menu.reversed()) { Button($0.title, action: $0.action) } }
    }

    /// The desktop's Channels menu, in its order (after Expand/Collapse;
    /// this app's "move the picked here" and classroom list at the end).
    private var menu: [MenuItem] {
        var m: [MenuItem] = []
        if expandable { m.append(.init(expanded ? "Collapse" : "Expand") { setExpanded(!expanded) }) }
        if !here { m.append(.init("Join Channel", join)) }
        if here, let connection { m.append(.init("Leave Channel") { connection.leaveChannel() }) }
        m.append(.init("View Channel Info", info))
        if let connection {
            m.append(.init("Speak Channel Info") { connection.speakChannelInfo(channel) })
            if here { m.append(.init("Read What's Happening Here") { connection.speakChannelState() }) }
        }
        m.append(.init("Copy a Link to This Channel", copyLink))
        if rights.modifyChannels || rights.createTemporaryChannels { m.append(.init("New Channel Inside This One", newSub)) }
        if rights.modifyChannels || moderate { m.append(.init("Edit Channel", edit)) }
        if rights.modifyChannels && channel.parentId != 0 { m.append(.init("Delete Channel", delete)) }
        if moderate { m.append(.init("Channel Bans", bans)) }
        if here {
            if connection?.hasAudio != false { m.append(.init("Stream a File to the Channel", stream)) }
            if let connection, connection.hasAudio, let st = snapshot.streaming {
                m.append(.init("Pause or Resume the File") { connection.pauseStream(st.status != .paused) })
            }
            if rights.uploadFiles || rights.admin { m.append(.init("Upload File", upload)) }
        }
        if !picked.isEmpty { m.append(.init("Move the \(picked.count) picked here", movePicked)) }
        if moderate && channel.classroom { m.append(.init("Classroom: who may send", classroom)) }
        return m
    }
}

struct UserDialog: Identifiable {
    let user: User
    let kind: UserMenu.UserSheet
    var id: String { "\(user.id)-\(kind)" }
}

struct BanTarget: Identifiable {
    let user: User
    let fromChannel: Bool
    var id: Int32 { user.id }
}

private struct UserRow: View {
    let user: User
    let depth: Int
    let isMe: Bool
    let showUsername: Bool
    let connection: ServerConnection
    var style: AppModel.InfoStyle = .text
    var showIcons = true
    var maxLength = 50
    var lastToTalk = false
    let open: (UserMenu.UserSheet) -> Void

    /// The desktop's user item text (channelstree.cpp updateUserItem), in
    /// its order, with emoji or words or neither ("Style of user and
    /// channel info").
    private var label: String {
        var t = showUsername && !user.username.isEmpty ? user.username : user.displayName
        let talking = user.talking || (isMe && connection.transmitting)
        let female = user.gender == .female
        switch style {
        case .emoji:
            if connection.unread.contains(user.id) { t += ", ✉" }
            if user.status == .away { t += ", 😴" }
            if user.status == .question { t += ", ❓" }
            if talking { t += ", 🎤" }
            if user.streamingMedia { t += ", 💿" }
            if user.streamPaused { t += ", 💿⏸️" }
            if user.sendingVideo { t += ", 🎥" }
            if user.sharingDesktop { t += ", 💻" }
        case .text:
            if connection.unread.contains(user.id) { t += ", Unread message" }
            if user.status == .away { t += ", Away" }
            if user.status == .question { t += ", Question" }
            if talking { t += ", Speaking" }
            if user.streamingMedia { t += ", Streaming mediafile" }
            if user.streamPaused { t += ", Streaming mediafile (Paused)" }
            if user.sendingVideo { t += ", Video" }
            if user.sharingDesktop { t += ", Desktop sharing" }
        case .none: break
        }
        if !user.statusMessage.isEmpty { t += " - \(user.statusMessage)" }
        switch style {
        case .emoji:
            t += user.gender == .female ? ", 👩" : user.gender == .male ? ", 👨" : ", 🧑"
            if user.admin { t += user.gender == .female ? " (🦸‍♀️)" : user.gender == .male ? " (🦸‍♂️)" : " (🦸)" }
            if user.operator { t += user.gender == .female ? " (👮‍♀️)" : user.gender == .male ? " (👮‍♂️)" : " (👮)" }
        case .text:
            t += user.gender == .female ? ", Female" : user.gender == .male ? ", Male" : ", Neutral"
            if user.admin { t += " (Administrator)" }
            if user.operator { t += " (Channel operator)" }
            _ = female
        case .none: break
        }
        return t
    }

    /// What's shown: cut at the "Maximum text length" (VoiceOver gets it all).
    private var shown: String {
        label.count > maxLength ? String(label.prefix(maxLength)) + "..." : label
    }

    var body: some View {
        Button { open(.info) } label: {
            HStack {
                if showIcons {
                    Image(systemName: user.talking ? "waveform.circle.fill" : "person.circle")
                        .foregroundStyle(user.talking ? .green : .secondary)
                        .accessibilityHidden(true)
                }
                Text(shown)
            }
            .padding(.leading, CGFloat(depth) * 16)
        }
        .foregroundStyle(.primary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityHint("Double-tap for everything about \(isMe ? "you" : user.displayName).")
        .accessibilityAddTraits(.isButton)
        // The desktop's Users menu: in order when touched and held, and
        // reversed for VoiceOver.
        .contextMenu { UserMenu(connection: connection, user: user, open: open) }
        .accessibilityActions { UserMenu(connection: connection, user: user, open: open, flatReversed: true) }
        // The desktop's "Show last to talk in yellow".
        .listRowBackground(lastToTalk && !user.talking ? Color.yellow.opacity(0.35) : nil)
    }
}

/// Push to talk, or the microphone's state in the other modes.
private struct TalkBar: View {
    @Environment(AppModel.self) private var model
    let connection: ServerConnection
    @GestureState private var holding = false
    /// When the press began, and whether I was talking then.
    @State private var pressStart: Date?
    @State private var wasTalking = false

    var body: some View {
        Group {
            switch model.talkMode {
            case .pushToTalk:
                Text(connection.transmitting ? "Talking" : "Tap or hold to talk")
                    .font(.title3.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 64)
                    .background(connection.transmitting ? Color.green : Color.accentColor, in: .rect(cornerRadius: 14))
                    .foregroundStyle(.white)
                    // A tap turns talking on or off; pressing and holding
                    // talks while held (the owner's choice, instead of the
                    // desktop's Push To Talk Lock setting).
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .updating($holding) { _, s, _ in s = true }
                    )
                    .onChange(of: holding) { _, on in
                        if on {
                            pressStart = .now
                            wasTalking = connection.transmitting
                            // Talking at once, for a hold.
                            if !wasTalking { connection.setTransmitting(true) }
                        } else {
                            let held = Date.now.timeIntervalSince(pressStart ?? .now)
                            pressStart = nil
                            // A tap: on stays on, or off if it was on. A hold: off.
                            if held >= 0.4 || wasTalking { connection.setTransmitting(false) }
                        }
                    }
                    .accessibilityElement()
                    .accessibilityLabel("Talk")
                    .accessibilityValue(connection.transmitting ? "Talking" : "Not talking")
                    .accessibilityHint("Double-tap to start or stop talking, or double-tap and hold to talk while held. Magic Tap starts or stops anywhere.")
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction { connection.setTransmitting(!connection.transmitting) }
            case .voiceActivation:
                HStack {
                    Text(micText).frame(maxWidth: .infinity, alignment: .leading)
                    Button(connection.muted ? "Unmute" : "Mute") { connection.setMicMuted(!connection.muted) }
                        .buttonStyle(.borderedProminent)
                        .tint(connection.muted ? .red : .accentColor)
                        .accessibilityHint("Magic Tap does the same anywhere.")
                }
                .frame(minHeight: 64)
            }
        }
        .padding()
    }

    private var micText: String {
        if connection.muted { return "Microphone muted" }
        return connection.voiceActive ? "Voice activation: sending" : "Voice activation: waiting for sound"
    }
}

/// The channel conversation, or one person's private messages.
struct ChatView: View {
    @Environment(AppModel.self) private var model
    let connection: ServerConnection
    let privateWith: User?
    @State private var draft = ""
    @FocusState private var typing: Bool

    private var showTimes: Bool { model.showTimestamps }

    private var lines: [ChatLine] {
        connection.lines.filter { privateWith == nil ? true : $0.privateWith == privateWith!.displayName }
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                List(lines) { line in
                    if model.chatTemplates.enabled, let kind = line.kind {
                        // The desktop's look: one line from its template.
                        Text(model.chatTemplates.format(kind, line.vars ?? [:], date: showTimes ? stamp(line.time) : ""))
                            .id(line.id)
                    } else {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(line.privateWith != nil && privateWith == nil ? "\(line.from) (private)" : line.from)
                                .font(.caption.weight(.semibold))
                            Spacer()
                            if showTimes {
                                Text(stamp(line.time))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Text(line.text)
                    }
                    .accessibilityElement(children: .combine)
                    .id(line.id)
                    }
                }
                .listStyle(.plain)
                .overlay {
                    if lines.isEmpty {
                        Text(privateWith == nil ? "No messages yet." : "No private messages yet.")
                            .foregroundStyle(.secondary)
                    }
                }
                .onChange(of: lines.count) {
                    if let last = lines.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            if let p = privateWith, connection.isTyping(p) {
                Text("\(p.displayName) is typing…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
            }
            HStack {
                // "Return sends message" (the old app's; on by default): one
                // line, Return sends; off, Return starts a new line.
                TextField(privateWith == nil ? "Message the channel" : "Message \(privateWith!.displayName)", text: $draft,
                          axis: model.sendOnReturn ? .horizontal : .vertical)
                    .accessibilityLabel(privateWith == nil ? "Message the channel" : "Message \(privateWith!.displayName)")
                    .textFieldStyle(.roundedBorder)
                    .focused($typing)
                    // Escape leaves the box (a keyboard's; the desktop's
                    // shortcuts work again outside it).
                    .onKeyPress(.escape) {
                        typing = false
                        return .handled
                    }
                    .submitLabel(model.sendOnReturn ? .send : .return)
                    .onSubmit { if model.sendOnReturn { send(); typing = true } }
                    .onChange(of: draft) {
                        if let p = privateWith { connection.setTyping(to: p, !draft.isEmpty) }
                    }
                Button("Send", action: send)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
        // The conversation on screen (the desktop's "focused window").
        .onAppear { if let p = privateWith { connection.focusedConversation = p.id; connection.unread.remove(p.id) } }
        .onDisappear { if connection.focusedConversation == privateWith?.id { connection.focusedConversation = nil } }
    }

    /// The desktop's timestamp (Settings → Display → Timestamp format).
    private func stamp(_ t: Date) -> String { model.timestamp(t) }

    private func send() {
        connection.send(draft, to: privateWith)
        draft = ""
    }
}

/// My status on this server.
private struct StatusView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let connection: ServerConnection
    @State private var mode = StatusMode.available
    @State private var message = ""
    @State private var gender = Gender.neutral
    @State private var startGender = Gender.neutral

    var body: some View {
        NavigationStack {
            Form {
                Picker("Status", selection: $mode) {
                    Text("Available").tag(StatusMode.available)
                    Text("Away").tag(StatusMode.away)
                    Text("Question").tag(StatusMode.question)
                }
                TextField("Status message", text: $message).accessibilityLabel("Status message")
                // The desktop's Change Status dialog checkbox.
                if connection.hasAudio {
                    Toggle("Show the file's name in my status while streaming", isOn: Binding(
                        get: { model.streamingStatus }, set: { model.streamingStatus = $0 }))
                }
                Picker("Gender", selection: $gender) {
                    Text("Male").tag(Gender.male)
                    Text("Female").tag(Gender.female)
                    Text("Neutral").tag(Gender.neutral)
                }
            }
            .navigationTitle("Status")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Set") {
                        connection.setStatus(mode, message)
                        if gender != startGender { connection.setGender(gender) }
                        dismiss()
                    }
                }
            }
            .onAppear {
                if let s = connection.snapshot, let me = s.users.first(where: { $0.id == s.myUserId }) {
                    mode = me.status
                    message = me.statusMessage
                    gender = me.gender
                    startGender = me.gender
                }
            }
        }
        .presentationDetents([.medium])
    }
}

extension User: Identifiable {}

/// My channel's files, transfers under way, and uploading.
struct FilesView: View {
    let connection: ServerConnection
    @State private var picking = false
    @State private var confirmDelete: RemoteFile?

    private var channelId: Int32 { connection.snapshot?.myChannelId ?? 0 }

    // The old app's file sorting: by name, size, owner or date, either way.
    @AppStorage("filesSortField") private var sortField = "name"
    @AppStorage("filesSortAscending") private var ascending = true

    private var files: [RemoteFile] {
        let mine = (connection.snapshot?.files ?? []).filter { $0.channelId == channelId }
        let up = mine.sorted { a, b in
            switch sortField {
            case "size": a.size != b.size ? a.size < b.size : a.name.localizedStandardCompare(b.name) == .orderedAscending
            case "owner": a.uploader.localizedStandardCompare(b.uploader) == .orderedAscending
            case "date": a.uploaded < b.uploaded
            default: a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
        }
        return ascending ? up : up.reversed()
    }

    private var transfers: [Transfer] {
        connection.transfers.values.sorted { $0.id < $1.id }
    }

    var body: some View {
        List {
            if !transfers.isEmpty {
                Section("In progress") {
                    ForEach(transfers, id: \.id) { t in TransferRow(transfer: t) { connection.cancel(t) } }
                }
            }
            Section {
                if channelId == 0 {
                    Text("Join a channel to see its files.").foregroundStyle(.secondary)
                } else if files.isEmpty {
                    Text("This channel has no files.").foregroundStyle(.secondary)
                }
                if !files.isEmpty {
                    Picker("Sort by", selection: $sortField) {
                        Text("Name").tag("name")
                        Text("Size").tag("size")
                        Text("Owner").tag("owner")
                        Text("Date").tag("date")
                    }
                    Toggle("Ascending", isOn: $ascending)
                }
                ForEach(files, id: \.id) { f in
                    let deletable = connection.canDelete(f)
                    Button { connection.download(f) } label: {
                        VStack(alignment: .leading) {
                            Text(f.name)
                            Text(details(f)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .foregroundStyle(.primary)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(f.name)
                    .accessibilityValue(details(f))
                    .accessibilityHint("Double-tap to download.")
                    .accessibilityAddTraits(.isButton)
                    .swipeActions { if deletable { Button("Delete", role: .destructive) { confirmDelete = f } } }
                    .contextMenu {
                        Button("Download") { connection.download(f) }
                        if deletable { Button("Delete", role: .destructive) { confirmDelete = f } }
                    }
                    .accessibilityActions {
                        if deletable { Button("Delete") { confirmDelete = f } }
                    }
                }
            } header: {
                if channelId > 0 { Text("Files in this channel") }
            } footer: {
                if channelId > 0 { Text("Downloads go to TeamTalk NG's folder in the Files app.") }
            }
        }
        .safeAreaInset(edge: .top) {
            if channelId > 0 {
                Button("Upload a file", systemImage: "square.and.arrow.up") { picking = true }
                    .buttonStyle(.bordered)
                    .padding(.top, 8)
            }
        }
        .fileImporter(isPresented: $picking, allowedContentTypes: [.item]) { result in
            if case .success(let url) = result { connection.upload(url) }
        }
        .confirmationDialog(
            "Delete \(confirmDelete?.name ?? "this file")?",
            isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let f = confirmDelete { connection.delete(f) }
            }
        } message: {
            Text("It's removed from the channel for everyone.")
        }
    }

    private func details(_ f: RemoteFile) -> String {
        let size = ByteCountFormatter.string(fromByteCount: f.size, countStyle: .file)
        return f.uploader.isEmpty ? size : "\(size), from \(f.uploader)"
    }
}

private struct TransferRow: View {
    let transfer: Transfer
    let cancel: () -> Void

    private var fraction: Double {
        transfer.size > 0 ? Double(transfer.transferred) / Double(transfer.size) : 0
    }

    private var label: String { "\(transfer.inbound ? "Downloading" : "Uploading") \(transfer.remoteName)" }

    var body: some View {
        HStack {
            VStack(alignment: .leading) {
                Text(label)
                ProgressView(value: fraction)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(label)
            .accessibilityValue("\(Int(fraction * 100)) percent")
            Button("Cancel", action: cancel)
                .buttonStyle(.borderless)
                .accessibilityLabel("Cancel \(transfer.remoteName)")
        }
    }
}

/// The file I'm streaming to the channel, and its controls.
private struct StreamBar: View {
    let connection: ServerConnection
    let stream: MediaStream

    private func time(_ ms: UInt32) -> String {
        let s = Int(ms / 1000)
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }

    var body: some View {
        let name = ((stream.path as NSString).lastPathComponent as NSString).deletingPathExtension
        let paused = stream.status == .paused
        VStack(alignment: .leading, spacing: 6) {
            Text("\(paused ? "Paused" : "Streaming") \(name), \(time(stream.elapsedMs)) of \(time(stream.durationMs))")
                .font(.subheadline)
            HStack {
                Button("Back 10 seconds", systemImage: "gobackward.10") { connection.seekStream(by: -10_000) }
                Button(paused ? "Resume" : "Pause", systemImage: paused ? "play.fill" : "pause.fill") { connection.pauseStream(!paused) }
                Button("Forward 10 seconds", systemImage: "goforward.10") { connection.seekStream(by: 10_000) }
                Spacer()
                Button("Stop streaming", systemImage: "stop.fill", role: .destructive) { connection.stopStream() }
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.bordered)
        }
        .padding(.horizontal)
        .padding(.top, 8)
    }
}

/// The desktop's dialogs: the text message popup (a private message opens
/// its conversation, when nothing else is open on top) and the dialog box
/// when excluded from a channel or the server.
private struct DesktopDialogs: ViewModifier {
    let connection: ServerConnection
    /// Closes the server screen (back to the server list, or the Monitor's).
    @Environment(\.dismiss) private var dismiss
    @Binding var privateWith: User?
    let busy: Bool
    @State private var askPassword: Channel?
    @State private var password = ""
    @State private var username = ""

    func body(content: Content) -> some View {
        content
            .onChange(of: connection.popupConversation?.id) {
                if let u = connection.popupConversation, privateWith == nil, !busy { privateWith = u }
                connection.popupConversation = nil
            }
            .sheet(item: Binding(get: { connection.streamPlan }, set: { connection.streamPlan = $0 })) { plan in
                StreamMediaFileDialog(connection: connection, plan: plan)
            }
            .onChange(of: connection.retryChannelPassword?.id) {
                if let c = connection.retryChannelPassword { askPassword = c }
                connection.retryChannelPassword = nil
            }
            .alert("Join channel error", isPresented: Binding(get: { askPassword != nil }, set: { if !$0 { askPassword = nil } })) {
                SecureField("Password", text: $password).accessibilityLabel("Password")
                Button("Join") {
                    if let c = askPassword { connection.join(c, password: password) }
                    password = ""
                }
                Button("Cancel", role: .cancel) { password = "" }
            } message: { Text("Incorrect channel password. Try again.") }
            .alert("Login error", isPresented: Binding(get: { connection.loginRetry }, set: { if !$0 { connection.loginRetry = false } })) {
                TextField("Username", text: $username).accessibilityLabel("Username")
                SecureField("Password", text: $password).accessibilityLabel("Password")
                Button("Login") { connection.retryLogin(username: username, password: password); password = "" }
                Button("Cancel", role: .cancel) { password = "" }
            } message: { Text("Incorrect username or password. Try again.") }
            .onChange(of: connection.loginRetry) { if connection.loginRetry { username = connection.server.username } }
            // Already refused before this screen opened (a tt:// link
            // connects at once): the username still filled in.
            .onAppear { if connection.loginRetry { username = connection.server.username } }
            .alert(connection.excluded?.title ?? "", isPresented: Binding(get: { connection.excluded != nil },
                                                    set: { if !$0 { connection.excluded = nil } })) {
                Button("OK") { if connection.excluded?.leaves == true { connection.leaveScreen() } }
            } message: { Text(connection.excluded?.text ?? "") }
            // Disconnected or kicked from the server: back to the list, as the desktop.
            .onChange(of: connection.leaveRequests) { dismiss() }
    }
}

// MARK: The desktop's keyboard shortcuts

extension ServerView {
    /// The person VoiceOver is on (the desktop's selected user).
    private var focusedUser: User? {
        guard let f = voFocus, f.hasPrefix("u"), let id = Int32(f.dropFirst()) else { return nil }
        return connection.snapshot?.users.first { $0.id == id }
    }

    /// The channel VoiceOver is on, or the focused person's, or mine.
    private var focusedChannel: Channel? {
        let snap = connection.snapshot
        if let f = voFocus, f.hasPrefix("c"), let id = Int32(f.dropFirst()) { return snap?.channels.first { $0.id == id } }
        let id = focusedUser?.channelId ?? snap?.myChannelId ?? 0
        return snap?.channels.first { $0.id == id }
    }

    /// The server screen's More menu, in its order.
    private var moreItems: [MenuItem] {
        let snap = connection.snapshot
        let inChannel = (snap?.myChannelId ?? 0) > 0
        let audio = connection.hasAudio
        var m: [MenuItem] = []
        if inChannel { m.append(.init("Leave channel") { connection.leaveChannel() }) }
        m.append(.init("Status") { showStatus = true })
        m.append(.init("Change nickname") { renaming = true })
        m.append(.init("Join a channel by its path") { joiningByPath = true })
        if audio && inChannel && snap?.streaming == nil {
            m.append(.init("Stream a File to the Channel") { pickingStream = true })
        }
        let question = connection.me?.status == .question
        m.append(.init(question ? "Leave question mode" : "Question mode") {
            connection.setStatus(question ? .available : .question, connection.me?.statusMessage ?? "")
        })
        if audio {
            let hearing = connection.hearingMyself
            m.append(.init(hearing ? "Stop hearing myself" : "Hear myself") { connection.setHearMyself(!hearing) })
            let muted = snap?.mutedAll ?? false
            m.append(.init(muted ? "Unmute Everyone for Me" : "Mute Everyone for Me") { connection.setMuteAll(!muted) })
            m.append(.init("Volume for this server") { showServerVolume = true })
            let streaming = model.audioNet.streams.filter { $0.connection === connection }.count
            m.append(.init(streaming == 0 ? "AudioNet" : "AudioNet (\(streaming) streaming)") { showAudioNet = true })
            if snap?.relaying != nil { m.append(.init("Stop relaying") { connection.setRelay(nil) }) }
            if inChannel {
                m.append(connection.recording ? .init("Stop recording") { connection.stopRecording() }
                                              : .init("Record conversations") { connection.startRecording() })
            }
        }
        if connection.rights.createTemporaryChannels || connection.rights.modifyChannels {
            m.append(.init("New channel") { channelSheet = .new(parent: rootId, temporary: !connection.rights.modifyChannels) })
        }
        if connection.rights.broadcast { m.append(.init("Broadcast message") { broadcasting = true }) }
        if connection.rights.moveUsers { m.append(.init("Move users") { showMoveUsers = true }) }
        m.append(.init("Online users") { showOnline = true })
        m.append(.init("Connection statistics") { showClientStats = true })
        if connection.rights.updateServer { m.append(.init("Server settings") { showServerSettings = true }) }
        if connection.rights.ban { m.append(.init("Bans") { showBans = true }) }
        if connection.rights.admin {
            m.append(.init("User accounts") { showAccounts = true })
            m.append(.init("Server statistics") { showStats = true })
            m.append(.init("Save server configuration") { connection.saveServerConfig() })
        }
        m.append(.init("Clear chat history") { connection.clearHistory() })
        var d = MenuItem("Disconnect") { connection.disconnect(); connection.leaveScreen() }
        d.destructive = true
        m.append(d)
        return m
    }

    func perform(_ cmd: DesktopCommand) {
        let u = focusedUser, c = focusedChannel
        // Through the Monitor (text only): nothing about audio.
        if !connection.hasAudio {
            switch cmd {
            case .record, .hearMyself, .pushToTalk, .voiceActivation, .soundEvents, .volume, .muteVoice, .muteMedia,
                 .voiceUp, .voiceDown, .mediaUp, .mediaDown, .muteAll, .stream, .pauseStream, .talk: return
            case .subscription(let sub) where !connection.shows(sub): return
            case .transmit(let st, _) where !connection.shows(st): return
            default: break
            }
        }
        switch cmd {
        case .record: if connection.recording { connection.stopRecording() } else { connection.startRecording() }
        case .speakClientStats: Task { await connection.speakClientStatistics() }
        case .questionMode:
            let q = connection.me?.status == .question
            connection.setStatus(q ? .available : .question, connection.me?.statusMessage ?? "")
        case .hearMyself: connection.setHearMyself(!connection.hearingMyself)
        case .pushToTalk: model.talkMode = model.talkMode == .pushToTalk ? .voiceActivation : .pushToTalk
            connection.noteMenu(model.talkMode == .pushToTalk ? "Push to talk on" : "Push to talk off")
        case .voiceActivation: model.talkMode = model.talkMode == .voiceActivation ? .pushToTalk : .voiceActivation
            connection.noteMenu(model.talkMode == .voiceActivation ? "Voice activation enabled" : "Voice activation disabled")
        case .speechEvents: model.speech.toggleEnabled()
        case .soundEvents:
            model.sounds.enabled.toggle()
            connection.noteMenu(model.sounds.enabled ? "Sound events enabled" : "Sound events disabled")
        case .userInfo: if let u { personFor = u }
        case .speakUserInfo: if let u { connection.speakUserInfo(u) } else if let c { connection.speakChannelInfo(c) }
        case .messages: if let u { privateWith = u }
        case .op: if let u { connection.setOperator(u, !u.operator) }
        case .volume: if let u { userDialog = UserDialog(user: u, kind: .volume) }
        case .muteVoice: if let u { connection.toggleMuteVoice(u) }
        case .muteMedia: if let u { connection.toggleMuteMedia(u) }
        case .kickChannel: if let u { connection.kick(u, fromChannel: true) }
        case .kickBanChannel: if let u { banning = BanTarget(user: u, fromChannel: true) }
        case .kickServer: if let u { connection.kick(u, fromChannel: false) }
        case .kickBanServer: if let u { banning = BanTarget(user: u, fromChannel: false) }
        case .subscription(let s): if let u { connection.toggleSubscription(u, s) }
        case .transmit(let s, let all):
            guard let c, let who = all ? Int32(0) : u?.id, connection.canControlTransmit(channel: c.id),
                  !all || c.classroom else { return }
            connection.setTransmit(channel: c.id, user: who, s, !connection.transmitAllowed(c, user: who, s))
        case .voiceUp: if let u { connection.stepVolume(u, media: false, by: 1) }
        case .voiceDown: if let u { connection.stepVolume(u, media: false, by: -1) }
        case .mediaUp: if let u { connection.stepVolume(u, media: true, by: 1) }
        case .mediaDown: if let u { connection.stepVolume(u, media: true, by: -1) }
        case .storeForMove: if let u { connection.togglePicked(u) }
        case .moveUsers: if let c { connection.movePicked(to: c) }
        case .moveDialog: if connection.rights.moveUsers { showMoveUsers = true }
        case .muteAll: connection.setMuteAll(!(connection.snapshot?.mutedAll ?? false))
        case .join: if let c, c.id != connection.snapshot?.myChannelId { if c.hasPassword { passwordFor = c } else { connection.join(c) } }
        case .leave: connection.leaveChannel()
        case .speakChannelInfo: if let c { connection.speakChannelInfo(c) }
        case .speakChannelState: connection.speakChannelState()
        case .ttURL:
            UIPasteboard.general.string = connection.link(to: c, withAccount: false, channelPassword: "")
            connection.noteMenu("Link copied to clipboard")
        case .channelBans: if let c { bansOf = c }
        case .stream: pickingStream = true
        case .pauseStream: if let st = connection.snapshot?.streaming { connection.pauseStream(st.status != .paused) }
        case .accounts: showAccounts = true
        case .serverBans: showBans = true
        case .onlineUsers: showOnline = true
        case .broadcast: broadcasting = true
        case .saveConfig: connection.saveServerConfig()
        case .talk: connection.toggleTalking()
        case .tab(let t): tab = t
        }
    }
}

/// The server screen's More button: its items, and the same as VoiceOver
/// actions, reversed (the owner's choice).
private struct MoreMenu: View, Equatable {
    let items: [MenuItem]
    /// What it shows (compared; the actions can't be).
    private let shown: [String]

    init(items: [MenuItem]) {
        self.items = items
        shown = items.map { $0.destructive ? "!" + $0.title : $0.title }
    }

    nonisolated static func == (a: MoreMenu, b: MoreMenu) -> Bool { a.shown == b.shown }

    var body: some View {
        Menu("More", systemImage: "ellipsis.circle") {
            ForEach(items) { i in Button(i.title, role: i.destructive ? .destructive : nil, action: i.action) }
        }
        .accessibilityActions {
            ForEach(items.reversed()) { i in Button(i.title, action: i.action) }
        }
    }
}
