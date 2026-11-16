import SwiftUI

extension UserRight {
    var label: String {
        switch self {
        case .multiLogin: "Log in more than once at a time"
        case .viewAllUsers: "See everyone on the server"
        case .viewHiddenChannels: "See hidden channels"
        case .createTemporaryChannels: "Make temporary channels"
        case .modifyChannels: "Make and change channels"
        case .broadcast: "Send broadcast messages"
        case .kickUsers: "Kick people"
        case .banUsers: "Ban people"
        case .moveUsers: "Move people"
        case .operatorEnable: "Make people channel operators"
        case .uploadFiles: "Upload files"
        case .downloadFiles: "Download files"
        case .updateServer: "Change the server's settings"
        case .transmitVoice: "Talk"
        case .transmitVideo: "Send video"
        case .transmitDesktop: "Share a desktop"
        case .transmitDesktopInput: "Control shared desktops"
        case .transmitMediaFileAudio: "Stream media file audio"
        case .transmitMediaFileVideo: "Stream media file video"
        case .recordVoice: "Record voices"
        case .textMessageUser: "Send private messages"
        case .textMessageChannel: "Write in channels"
        case .lockedNickname: "Nickname can't be changed"
        case .lockedStatus: "Status can't be changed"
        }
    }
}

/// Runs a blocking call off the main thread; failures announced.
@MainActor
func adminCall<T: Sendable>(_ connection: ServerConnection, _ what: String,
                             monitor m: @escaping @Sendable (MonitorClient, Int64) throws -> T,
                             _ f: @escaping @Sendable (TtClient) throws -> T) async -> T? {
    let r: Result<T, Error>
    if let id = connection.monitorId {
        // Through the Monitor's own login, as if connected.
        guard let got = await connection.monitorCall({ try m($0, id) }) else { announce("\(what): the Monitor can't be reached."); return nil }
        r = got
    } else {
        let c = connection.coreClient
        r = await Task.detached { Result { try f(c) } }.value
    }
    switch r {
    case .success(let v): return v
    case .failure(let e):
        announce("\(what): \(connection.monitorId == nil ? words(e) : NGAccountStore.words(e))")
        return nil
    }
}

/// A time as the server gives it; the Monitor sends Unix seconds.
func serverTime(_ s: String) -> String {
    guard !s.isEmpty, s.allSatisfy(\.isNumber), let t = TimeInterval(s) else { return s }
    return Date(timeIntervalSince1970: t).formatted(date: .abbreviated, time: .shortened)
}

/// The server's accounts.
struct AccountsView: View {
    @Environment(\.dismiss) private var dismiss
    let connection: ServerConnection
    @State private var accounts: [UserAccount]?
    @State private var editing: EditAccount?
    @State private var deleting: UserAccount?

    struct EditAccount: Identifiable {
        let account: UserAccount
        let new: Bool
        var id: String { new ? "+new" : account.username }
    }

    var body: some View {
        NavigationStack {
            List {
                if let accounts {
                    ForEach(accounts, id: \.username) { a in
                        Button { editing = EditAccount(account: a, new: false) } label: {
                            VStack(alignment: .leading) {
                                Text(a.username.isEmpty ? "Anonymous (no username)" : a.username)
                                Text(summary(a)).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .foregroundStyle(.primary)
                        .accessibilityElement(children: .combine)
                        .accessibilityHint("Double-tap to change.")
                        .swipeActions { Button("Delete", role: .destructive) { deleting = a } }
                        .accessibilityActions { Button("Delete") { deleting = a } }
                    }
                } else {
                    ProgressView("Loading the accounts")
                }
            }
            .navigationTitle("User accounts")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button("Add account", systemImage: "plus") {
                        editing = EditAccount(account: UserAccount(
                            username: "", password: "", admin: false, rights: defaultUserRights(), note: "",
                            initialChannel: "", autoOperatorChannels: [], bitrateLimit: 0, commandsLimit: 0,
                            commandsIntervalMs: 0, lastModified: "", lastLogin: ""), new: true)
                    }
                }
            }
            .task { await load() }
            .sheet(item: $editing, onDismiss: { Task { await load() } }) { e in
                AccountEditView(connection: connection, account: e.account, new: e.new)
            }
            .confirmationDialog("Delete the account \(deleting?.username ?? "")?",
                                isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                                titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    if let a = deleting {
                        Task {
                            let name = a.username
                            if await adminCall(connection, "Couldn't delete it", monitor: { try $0.adminDeleteAccount(serverId: $1, username: name) }, { try $0.deleteAccount(username: name) }) != nil {
                                announce("Deleted \(name)")
                            }
                            await load()
                        }
                    }
                }
            } message: {
                Text("They can no longer log in with it.")
            }
        }
    }

    private func summary(_ a: UserAccount) -> String {
        var p = [a.admin ? "Administrator" : "Default user"]
        if !a.note.isEmpty { p.append(a.note) }
        if !a.lastLogin.isEmpty { p.append("last login \(serverTime(a.lastLogin))") }
        return p.joined(separator: ", ")
    }

    private func load() async {
        accounts = await adminCall(connection, "Couldn't list the accounts", monitor: { try $0.adminAccounts(serverId: $1) }) { try $0.listAccounts() }?
            .sorted { $0.username.localizedStandardCompare($1.username) == .orderedAscending } ?? accounts ?? []
    }
}

/// One account's settings.
struct AccountEditView: View {
    @Environment(\.dismiss) private var dismiss
    let connection: ServerConnection
    @State var account: UserAccount
    let new: Bool
    @State private var bitrateKbps = ""
    @State private var commands = ""
    @State private var seconds = ""

    var body: some View {
        let permanent: [Channel] = (connection.snapshot?.channels ?? []).filter { $0.permanent || $0.parentId == 0 }
        NavigationStack {
            Form {
                Section {
                    if new {
                        TextField("Username", text: $account.username).accessibilityLabel("Username")
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                    } else {
                        LabeledContent("Username", value: account.username)
                    }
                    SecureField("Password", text: $account.password).accessibilityLabel("Password")
                    Picker("Type", selection: $account.admin) {
                        Text("Default user").tag(false)
                        Text("Administrator").tag(true)
                    }
                    TextField("Note", text: $account.note, axis: .vertical).accessibilityLabel("Note")
                }
                Section {
                    Picker("Initial channel", selection: $account.initialChannel) {
                        Text("None").tag("")
                        ForEach(permanent, id: \.id) { c in
                            let path = connection.coreClient.channelPath(channelId: c.id)
                            Text(path).tag(path)
                        }
                    }
                } footer: {
                    Text("Joined after logging in, without the channel's password.")
                }
                if !account.admin {
                    Section("What they may do") {
                        ForEach(allUserRights(), id: \.self) { r in
                            Toggle(r.label, isOn: Binding(
                                get: { account.rights.contains(r) },
                                set: { on in
                                    if on { account.rights.append(r) } else { account.rights.removeAll { $0 == r } }
                                }))
                        }
                    }
                }
                Section {
                    ForEach(permanent, id: \.id) { c in
                        Toggle(connection.coreClient.channelPath(channelId: c.id), isOn: Binding(
                            get: { account.autoOperatorChannels.contains(c.id) },
                            set: { on in
                                if on { account.autoOperatorChannels.append(c.id) } else { account.autoOperatorChannels.removeAll { $0 == c.id } }
                            }))
                    }
                } header: {
                    Text("Operator of these channels")
                } footer: {
                    Text("They become an operator whenever they join one (up to 16, permanent channels only).")
                }
                Section {
                    TextField("Highest audio bitrate, kbit/s (0: no limit)", text: $bitrateKbps).accessibilityLabel("Highest audio bitrate, kbit/s (0: no limit)").keyboardType(.numberPad)
                    TextField("Flood protection: at most this many commands (0: off)", text: $commands).accessibilityLabel("Flood protection: at most this many commands (0: off)").keyboardType(.numberPad)
                    TextField("… in this many seconds", text: $seconds).accessibilityLabel("Flood protection: in this many seconds").keyboardType(.numberPad)
                } header: {
                    Text("Limits")
                }
                if !new && !account.lastModified.isEmpty {
                    Section {
                        LabeledContent("Changed", value: serverTime(account.lastModified))
                        if !account.lastLogin.isEmpty { LabeledContent("Last login", value: serverTime(account.lastLogin)) }
                    }
                }
            }
            .navigationTitle(new ? "New account" : account.username)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        var a = account
                        a.bitrateLimit = (Int32(bitrateKbps) ?? 0) * 1000
                        a.commandsLimit = Int32(commands) ?? 0
                        a.commandsIntervalMs = (Int32(seconds) ?? 0) * 1000
                        a.username = a.username.trimmingCharacters(in: .whitespaces)
                        let saving = a
                        Task {
                            if await adminCall(connection, "Couldn't save it", monitor: { try $0.adminSaveAccount(serverId: $1, account: saving) }, { try $0.saveAccount(account: saving) }) != nil {
                                announce("Saved \(saving.username)")
                                dismiss()
                            }
                        }
                    }
                }
            }
            .onAppear {
                bitrateKbps = String(account.bitrateLimit / 1000)
                commands = String(account.commandsLimit)
                seconds = String(account.commandsIntervalMs / 1000)
            }
        }
    }
}

/// Every server setting.
struct ServerSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    let connection: ServerConnection
    @State private var s: ServerSettings?
    /// The desktop's Server Properties: everyone sees them; only those who
    /// may update the server change them (read-only otherwise, the message
    /// of the day as shown, a Close button only).
    private var editable: Bool { connection.rights.updateServer }

    var body: some View {
        NavigationStack {
            Form {
                if let s {
                    let b = Binding(get: { self.s ?? s }, set: { self.s = $0 })
                    if editable {
                        Section {
                            TextField("Server name", text: b.name).accessibilityLabel("Server name")
                            TextField("Message of the day", text: b.motd, axis: .vertical).accessibilityLabel("Message of the day").lineLimit(3...8)
                        } footer: {
                            Text("The message can use %users% (people online), %admins%, %uptime% and %voicetx%, %voicerx%, %lastuser%.")
                        }
                    } else {
                        Section {
                            LabeledContent("Server name", value: s.name)
                            LabeledContent("Message of the day", value: connection.snapshot?.server.motd ?? s.motd)
                        }
                    }
                    Section("Connections") {
                        number("Most people", b.maxUsers)
                        number("User timeout, seconds", b.userTimeout)
                        number("TCP port", b.tcpPort)
                        number("UDP port", b.udpPort)
                        if editable {
                            Toggle("Save changes straight away", isOn: b.autoSave)
                        } else {
                            LabeledContent("Save changes straight away", value: s.autoSave ? "On" : "Off")
                        }
                    }
                    Section {
                        number("Wrong logins before a ban (0: never)", b.maxLoginAttempts)
                        number("Logins per address (0: no limit)", b.maxLoginsPerAddress)
                        number("Time between logins, ms (0: none)", b.loginDelayMs)
                    } header: {
                        Text("Protection against abuse")
                    }
                    Section {
                        number("Voice, KB/s", kb(b.voiceLimit))
                        number("Video, KB/s", kb(b.videoLimit))
                        number("Media files, KB/s", kb(b.mediaFileLimit))
                        number("Desktops, KB/s", kb(b.desktopLimit))
                        number("Everything together, KB/s", kb(b.totalLimit))
                    } header: {
                        Text("Speed limits, KB/s (0: none)")
                    }
                    Section {
                        LabeledContent("Server version", value: s.version)
                        LabeledContent("Protocol version", value: s.protocolVersion)
                    }
                } else {
                    ProgressView("Loading the settings")
                }
            }
            .navigationTitle("Server settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if !editable {
                    ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                } else {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        guard let saving = s else { return }
                        Task {
                            if await adminCall(connection, "Couldn't change the server", monitor: { try $0.adminUpdateServer(serverId: $1, settings: saving) }, { try $0.updateServerSettings(settings: saving) }) != nil {
                                announce("Server settings saved")
                                dismiss()
                            }
                        }
                    }
                    .disabled(s == nil)
                }
                }
            }
            .task { s = await adminCall(connection, "Couldn't read the settings", monitor: { try $0.adminServerSettings(serverId: $1) }) { try $0.serverSettings() } }
        }
    }

    private func kb(_ b: Binding<Int32>) -> Binding<Int32> {
        Binding(get: { b.wrappedValue / 1000 }, set: { b.wrappedValue = $0 * 1000 })
    }

    @ViewBuilder private func number(_ label: String, _ v: Binding<Int32>) -> some View {
        if editable {
            LabeledContent(label) {
                TextField(label, value: v, format: .number)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
                    .accessibilityLabel(label)
            }
        } else {
            LabeledContent(label, value: "\(v.wrappedValue)")
        }
    }
}

/// What the server has done since it started.
struct ServerStatisticsView: View {
    @Environment(\.dismiss) private var dismiss
    let connection: ServerConnection
    @State private var st: ServerStatistics?

    var body: some View {
        NavigationStack {
            Form {
                if let st {
                    Section {
                        row("Running for", Duration.milliseconds(st.uptimeMs).formatted(.units(allowed: [.days, .hours, .minutes], width: .wide)))
                        row("People served", "\(st.usersServed)")
                        row("Most at once", "\(st.usersPeak)")
                        row("Files", "\(st.filesReceived) uploaded, \(st.filesSent) downloaded")
                    }
                    Section("Data sent and received") {
                        row("Everything", bytes(st.totalBytesSent, st.totalBytesReceived))
                        row("Voice", bytes(st.voiceBytesSent, st.voiceBytesReceived))
                        row("Video", bytes(st.videoBytesSent, st.videoBytesReceived))
                        row("Media files", bytes(st.mediaFileBytesSent, st.mediaFileBytesReceived))
                        row("Desktops", bytes(st.desktopBytesSent, st.desktopBytesReceived))
                    }
                } else {
                    ProgressView("Asking the server")
                }
            }
            .navigationTitle("Server statistics")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .primaryAction) { Button("Update") { Task { await load() } } }
            }
            .task { await load() }
        }
    }

    private func load() async {
        st = await adminCall(connection, "Couldn't get the statistics", monitor: { try $0.adminStatistics(serverId: $1) }) { try $0.serverStatistics() } ?? st
    }

    private func bytes(_ sent: Int64, _ received: Int64) -> String {
        "\(ByteCountFormatter.string(fromByteCount: sent, countStyle: .binary)) sent, \(ByteCountFormatter.string(fromByteCount: received, countStyle: .binary)) received"
    }

    private func row(_ l: String, _ v: String) -> some View {
        LabeledContent(l, value: v).accessibilityElement(children: .ignore).accessibilityLabel(l).accessibilityValue(v)
    }
}

/// Everyone on the server, and who left while I was here.
struct OnlineUsersView: View {
    @AppStorage("keepDisconnectedUsers") private var keepDisconnected = false
    @Environment(\.dismiss) private var dismiss
    let connection: ServerConnection
    let open: (User) -> Void

    var body: some View {
        let s = connection.snapshot
        let users = (s?.users ?? []).sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        NavigationStack {
            List {
                Section(users.count == 1 ? "1 person online" : "\(users.count) people online") {
                    ForEach(users, id: \.id) { u in
                        Button { dismiss(); open(u) } label: {
                            VStack(alignment: .leading) {
                                Text(u.displayName)
                                Text(where_(u)).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .foregroundStyle(.primary)
                        .accessibilityElement(children: .combine)
                    }
                }
                // The desktop's "Keep disconnected users" (off by default).
                Toggle("Keep people in Online users after they log out", isOn: $keepDisconnected)
                if keepDisconnected && !connection.departed.isEmpty {
                    Section("Left while you were here") {
                        ForEach(connection.departed.reversed(), id: \.at) { d in
                            Text("\(d.user.displayName) (\(d.user.username)), at \(d.at.formatted(date: .omitted, time: .shortened))")
                        }
                    }
                }
            }
            .navigationTitle("Online users")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }

    private func where_(_ u: User) -> String {
        let ch = connection.snapshot?.channels.first { $0.id == u.channelId }
        var p = [ch.map { connection.channelPathText($0) } ?? "Not in a channel"]
        if !u.username.isEmpty { p.append(u.username) }
        if !u.ipAddress.isEmpty { p.append(u.ipAddress) }
        p.append("\(u.clientName) \(u.version)")
        return p.joined(separator: ", ")
    }
}

/// The desktop's User Accounts for someone who isn't an admin: their own
/// account, read-only (its "View User Information", UserAccountDlg's
/// USER_READONLY), as the server gave it at login.
struct MyAccountView: View {
    @Environment(\.dismiss) private var dismiss
    let connection: ServerConnection

    var body: some View {
        NavigationStack {
            Form {
                if let a = connection.coreClient.myAccount() {
                    Section {
                        LabeledContent("Username", value: a.username)
                        LabeledContent("Type", value: a.admin ? "Administrator" : "Default user")
                        if !a.note.isEmpty { LabeledContent("Note", value: a.note) }
                        LabeledContent("Initial channel", value: a.initialChannel.isEmpty ? "None" : a.initialChannel)
                    }
                    if !a.admin {
                        Section("What you may do") {
                            ForEach(allUserRights(), id: \.self) { r in
                                LabeledContent(r.label, value: a.rights.contains(r) ? "Yes" : "No")
                            }
                        }
                    }
                    if !a.autoOperatorChannels.isEmpty {
                        Section("Operator of these channels") {
                            ForEach(a.autoOperatorChannels, id: \.self) { id in
                                Text(connection.coreClient.channelPath(channelId: id).nonEmpty ?? "Channel \(id)")
                            }
                        }
                    }
                    Section("Limits") {
                        LabeledContent("Highest audio bitrate, kbit/s (0: no limit)", value: "\(a.bitrateLimit / 1000)")
                        LabeledContent("Flood protection: at most this many commands (0: off)", value: "\(a.commandsLimit)")
                        LabeledContent("Flood protection: in this many seconds", value: "\(a.commandsIntervalMs / 1000)")
                    }
                    if !a.lastModified.isEmpty || !a.lastLogin.isEmpty {
                        Section {
                            if !a.lastModified.isEmpty { LabeledContent("Changed", value: serverTime(a.lastModified)) }
                            if !a.lastLogin.isEmpty { LabeledContent("Last login", value: serverTime(a.lastLogin)) }
                        }
                    }
                } else {
                    Text("This server didn't say what your account may do.").foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Your account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}
