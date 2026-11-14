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
    @State private var channelSheet: ChannelSheet?
    @State private var movingUser: User?
    @State private var deletingChannel: Channel?
    @State private var bansOf: Channel?
    @State private var classroomOf: Channel?
    @State private var showServerSettings = false
    @State private var showBans = false
    @State private var broadcasting = false
    @State private var broadcastText = ""
    @State private var renaming = false
    @State private var newNickname = ""

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
                TalkBar(connection: connection)
            }
        }
        .navigationTitle(connection.snapshot?.server.name.nonEmpty ?? connection.server.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if connection.isConnected {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu("More", systemImage: "ellipsis.circle") {
                        if (connection.snapshot?.myChannelId ?? 0) > 0 {
                            Button("Leave channel") { connection.leaveChannel() }
                        }
                        Button("Status") { showStatus = true }
                        Button("Change nickname") { renaming = true }
                        Toggle("Question mode", isOn: Binding(
                            get: { connection.me?.status == .question },
                            set: { on in connection.setStatus(on ? .question : .available, connection.me?.statusMessage ?? "") }))
                        Toggle("Hear myself", isOn: Binding(get: { connection.hearingMyself }, set: { connection.setHearMyself($0) }))
                        Toggle("Mute everyone", isOn: Binding(get: { connection.snapshot?.mutedAll ?? false }, set: { connection.setMuteAll($0) }))
                        if connection.snapshot?.relaying != nil {
                            Button("Stop relaying") { connection.setRelay(nil) }
                        }
                        if (connection.snapshot?.myChannelId ?? 0) > 0 {
                            if connection.recording {
                                Button("Stop recording") { connection.stopRecording() }
                            } else {
                                Button("Record the channel (MP3)") { connection.startRecording(mp3: true) }
                                Button("Record the channel (WAV)") { connection.startRecording(mp3: false) }
                            }
                        }
                        if connection.rights.createTemporaryChannels || connection.rights.modifyChannels {
                            Button("New channel") { channelSheet = .new(parent: rootId, temporary: !connection.rights.modifyChannels) }
                        }
                        if connection.rights.broadcast {
                            Button("Broadcast message") { broadcasting = true }
                        }
                        if connection.rights.updateServer {
                            Button("Server settings") { showServerSettings = true }
                        }
                        if connection.rights.ban {
                            Button("Bans") { showBans = true }
                        }
                        Button("Clear chat history") { connection.clearHistory() }
                        Button("Disconnect", role: .destructive) { connection.disconnect() }
                    }
                }
            }
        }
        .accessibilityAction(.magicTap) { connection.toggleTalking() }
        .onAppear { connection.connect() }
        .alert("Channel password", isPresented: Binding(get: { passwordFor != nil }, set: { if !$0 { passwordFor = nil } })) {
            SecureField("Password", text: $channelPassword)
            Button("Join") {
                if let c = passwordFor { connection.join(c, password: channelPassword) }
                channelPassword = ""
            }
            Button("Cancel", role: .cancel) { channelPassword = "" }
        } message: {
            Text("\(passwordFor?.name ?? "This channel") needs a password.")
        }
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
        .sheet(item: $bansOf) { c in
            ChannelBansView(connection: connection, channel: c)
        }
        .sheet(item: $classroomOf) { c in
            ClassroomView(connection: connection, channelId: c.id)
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
        .alert("Change nickname", isPresented: $renaming) {
            TextField("Nickname", text: $newNickname)
            Button("Change") { connection.setNickname(newNickname) }
            Button("Cancel", role: .cancel) {}
        }
        .onChange(of: renaming) { if renaming { newNickname = connection.me?.nickname ?? "" } }
        .alert("Broadcast message", isPresented: $broadcasting) {
            TextField("Message to everyone", text: $broadcastText)
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
            }
            Spacer()
        }
        .padding()
    }

    private var rootId: Int32 { connection.snapshot?.channels.first { $0.parentId == 0 }?.id ?? 0 }

    private var channels: some View {
        let snap = connection.snapshot
        let rows = snap.map(ChannelTree.rows) ?? []
        return List(rows) { row in
            switch row {
            case .channel(let c, let depth):
                ChannelRow(channel: c, depth: depth, snapshot: snap!, rights: connection.rights,
                           newSub: { channelSheet = .new(parent: c.id, temporary: !connection.rights.modifyChannels) },
                           edit: { channelSheet = .edit(c) },
                           delete: { deletingChannel = c },
                           moderate: connection.canModerate(channel: c.id),
                           bans: { bansOf = c }, classroom: { classroomOf = c }) {
                    if c.hasPassword && c.id != snap?.myChannelId {
                        passwordFor = c
                    } else if c.id != snap?.myChannelId {
                        connection.join(c)
                    }
                }
            case .user(let u, let depth):
                UserRow(user: u, depth: depth, isMe: u.id == snap?.myUserId, rights: connection.rights,
                        message: { privateWith = u }, details: { personFor = u },
                        move: { movingUser = u },
                        kick: { connection.kick(u, fromChannel: $0) },
                        ban: { connection.ban(u, by: $0) })
            }
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

    static func rows(_ s: Snapshot) -> [Row] {
        var out: [Row] = []
        func add(_ c: Channel, _ depth: Int) {
            out.append(.channel(c, depth: depth))
            for u in s.users.filter({ $0.channelId == c.id }).sorted(by: { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }) {
                out.append(.user(u, depth: depth + 1))
            }
            for sub in s.channels.filter({ $0.parentId == c.id }).sorted(by: { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) {
                add(sub, depth + 1)
            }
        }
        for root in s.channels where root.parentId == 0 { add(root, 0) }
        return out
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
    let join: () -> Void

    private var name: String { channel.parentId == 0 ? (snapshot.server.name.nonEmpty ?? "Root channel") : channel.name }
    private var here: Bool { snapshot.myChannelId == channel.id }

    private var details: String {
        let n = snapshot.users.filter { $0.channelId == channel.id }.count
        var parts = [n == 1 ? "1 person" : "\(n) people"]
        if here { parts.insert("you're here", at: 0) }
        if channel.hasPassword { parts.append("password") }
        if !channel.topic.isEmpty { parts.append(channel.topic) }
        return parts.joined(separator: ", ")
    }

    var body: some View {
        Button(action: join) {
            HStack {
                Image(systemName: here ? "folder.fill" : "folder")
                    .accessibilityHidden(true)
                VStack(alignment: .leading) {
                    Text(name).font(.body.weight(here ? .semibold : .regular))
                    Text(details).font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.leading, CGFloat(depth) * 16)
        }
        .foregroundStyle(.primary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(name), channel")
        .accessibilityValue(details)
        .accessibilityHint(here ? "" : "Double-tap to join.")
        .accessibilityAddTraits(.isButton)
        .contextMenu { actions }
        .accessibilityActions { actions }
    }

    @ViewBuilder private var actions: some View {
        if rights.modifyChannels || rights.createTemporaryChannels {
            Button("New channel inside", action: newSub)
        }
        if rights.modifyChannels {
            Button("Edit channel", action: edit)
            if channel.parentId != 0 { Button("Delete channel", role: .destructive, action: delete) }
        }
        if moderate {
            Button("Channel bans", action: bans)
            if channel.classroom { Button("Classroom: who may send", action: classroom) }
        }
    }
}

private struct UserRow: View {
    let user: User
    let depth: Int
    let isMe: Bool
    let rights: MyRights
    let message: () -> Void
    let details: () -> Void
    let move: () -> Void
    let kick: (_ fromChannel: Bool) -> Void
    let ban: (BanKind) -> Void

    /// Their state, said with their name.
    private var label: String {
        var parts = [isMe ? "\(user.displayName) (you)" : user.displayName]
        if user.talking { parts.append("talking") }
        if user.voiceMuted { parts.append("muted") }
        if user.operator { parts.append("operator") }
        if user.streamingMedia { parts.append("streaming a file") }
        if user.sendingVideo { parts.append("sending video") }
        if user.sharingDesktop { parts.append("sharing a desktop") }
        switch user.status {
        case .away: parts.append("away")
        case .question: parts.append("has a question")
        case .available: break
        }
        if !user.statusMessage.isEmpty { parts.append(user.statusMessage) }
        if user.admin { parts.append("admin") }
        return parts.joined(separator: ", ")
    }

    var body: some View {
        Button(action: details) {
            HStack {
                Image(systemName: user.talking ? "waveform.circle.fill" : "person.circle")
                    .foregroundStyle(user.talking ? .green : .secondary)
                    .accessibilityHidden(true)
                Text(label)
            }
            .padding(.leading, CGFloat(depth) * 16)
        }
        .foregroundStyle(.primary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityHint("Double-tap for everything about \(isMe ? "you" : user.displayName).")
        .accessibilityAddTraits(.isButton)
        .contextMenu { if isMe { Button("Details and controls", action: details) } else { actions } }
        .accessibilityActions { if !isMe { actions } }
    }

    @ViewBuilder private var actions: some View {
        Button("Message privately", action: message)
        Button("Details and controls", action: details)
        if rights.moveUsers { Button("Move to a channel", action: move) }
        if rights.kick {
            if user.channelId > 0 { Button("Kick from the channel") { kick(true) } }
            Button("Kick from the server") { kick(false) }
        }
        if rights.ban {
            Button("Ban by account and kick") { ban(.username) }
            Button("Ban by IP address and kick") { ban(.ipAddress) }
        }
    }
}

/// Push to talk, or the microphone's state in the other modes.
private struct TalkBar: View {
    @Environment(AppModel.self) private var model
    let connection: ServerConnection
    @GestureState private var holding = false

    var body: some View {
        Group {
            switch model.talkMode {
            case .pushToTalk:
                Text(connection.transmitting ? "Talking" : "Hold to talk")
                    .font(.title3.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 64)
                    .background(connection.transmitting ? Color.green : Color.accentColor, in: .rect(cornerRadius: 14))
                    .foregroundStyle(.white)
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .updating($holding) { _, s, _ in s = true }
                    )
                    .onChange(of: holding) { _, on in connection.setTransmitting(on) }
                    .accessibilityElement()
                    .accessibilityLabel("Talk")
                    .accessibilityValue(connection.transmitting ? "Talking" : "Not talking")
                    .accessibilityHint("Double-tap to start or stop talking. Magic Tap does the same anywhere.")
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction { connection.setTransmitting(!connection.transmitting) }
            case .voiceActivation, .alwaysOn:
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
        if model.talkMode == .alwaysOn { return "Microphone on" }
        return connection.voiceActive ? "Voice activation: sending" : "Voice activation: waiting for sound"
    }
}

/// The channel conversation, or one person's private messages.
struct ChatView: View {
    let connection: ServerConnection
    let privateWith: User?
    @State private var draft = ""
    @FocusState private var typing: Bool

    private var lines: [ChatLine] {
        connection.lines.filter { privateWith == nil ? true : $0.privateWith == privateWith!.displayName }
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                List(lines) { line in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(line.privateWith != nil && privateWith == nil ? "\(line.from) (private)" : line.from)
                                .font(.caption.weight(.semibold))
                            Spacer()
                            Text(line.time, format: Calendar.current.isDateInToday(line.time)
                                 ? .dateTime.hour().minute() : .dateTime.day().month().hour().minute())
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Text(line.text)
                    }
                    .accessibilityElement(children: .combine)
                    .id(line.id)
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
            HStack {
                TextField(privateWith == nil ? "Message the channel" : "Message \(privateWith!.displayName)", text: $draft, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .focused($typing)
                    .onSubmit(send)
                Button("Send", action: send)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
    }

    private func send() {
        connection.send(draft, to: privateWith)
        draft = ""
    }
}

/// My status on this server.
private struct StatusView: View {
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
                TextField("Status message", text: $message)
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

    private var files: [RemoteFile] {
        (connection.snapshot?.files ?? [])
            .filter { $0.channelId == channelId }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private var transfers: [Transfer] {
        connection.transfers.values.sorted { $0.id < $1.id }
    }

    var body: some View {
        List {
            if !transfers.isEmpty {
                Section("Under way") {
                    ForEach(transfers, id: \.id) { t in TransferRow(transfer: t) { connection.cancel(t) } }
                }
            }
            Section {
                if channelId == 0 {
                    Text("Join a channel to see its files.").foregroundStyle(.secondary)
                } else if files.isEmpty {
                    Text("This channel has no files.").foregroundStyle(.secondary)
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
