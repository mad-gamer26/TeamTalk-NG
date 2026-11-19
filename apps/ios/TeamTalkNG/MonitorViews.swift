import SwiftUI

/// The Monitor, all in one place (Server List Actions → Monitor): the
/// servers it watches (each to explore, with its settings and Stop
/// monitoring), adding one, recent events, its notifications, the default
/// settings for new servers, and which Monitor this is.
struct MonitorListView: View {
    @Environment(AppModel.self) private var model
    @State private var adding = false
    @State private var stopping: MonitorServer?
    @State private var settingsFor: Int64?
    @State private var forgetting = false
    @State private var choosingHosted = false
    @State private var leavingHosted = false
    @State private var movingToHosted = false

    var body: some View {
        let monitor = model.monitor
        let inUse = monitor.own != nil || monitor.hosted
        List {
            Section {
                if !inUse {
                    Text("Choose a Monitor first, under Which Monitor at the bottom of this screen.")
                        .foregroundStyle(.secondary)
                } else if monitor.servers.isEmpty && !monitor.loading {
                    Text("Your Monitor isn't watching any servers yet.")
                        .foregroundStyle(.secondary)
                }
                ForEach(monitor.servers, id: \.id) { s in
                    NavigationLink {
                        // As if connected: the server screen, from the Monitor.
                        ServerView(connection: model.monitorConnection(for: s))
                    } label: {
                        VStack(alignment: .leading) {
                            Text(verbatim: s.name).font(.headline)
                            Text(details(s)).font(.subheadline).foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                    }
                    .contextMenu {
                        Button("Monitor settings") { settingsFor = s.id }
                        Button("Stop monitoring", role: .destructive) { stopping = s }
                    }
                    // VoiceOver's actions: written in reverse of the menu (the owner's order).
                    .accessibilityActions {
                        Button("Stop monitoring") { stopping = s }
                        Button("Monitor settings") { settingsFor = s.id }
                    }
                }
                if inUse {
                    Button("Monitor a server") { adding = true }
                }
            } header: {
                Text("Servers")
            } footer: {
                if let p = monitor.problem {
                    Text(p)
                } else if inUse {
                    Text("Tap a server to explore it. Its actions: its Monitor settings, or Stop monitoring.")
                }
            }
            if !monitor.events.isEmpty {
                Section("Recent") {
                    ForEach(monitor.events.suffix(30).reversed(), id: \.seq) { e in
                        EventRow(event: e, server: monitor.servers.first { $0.id == e.serverId }?.name)
                    }
                }
            }
            Section {
                if inUse {
                    NavigationLink("Notifications") { MonitorNotificationsView() }
                }
                NavigationLink("Default settings") { MonitorDefaultsView() }
            } footer: {
                Text("Default settings: the nickname, status message and gender new servers start with.")
            }
            Section {
                if let own = monitor.own {
                    LabeledContent("Your Monitor", value: own.name)
                    Button("Use TeamTalk NG's Monitor instead") { movingToHosted = true }
                        .accessibilityIdentifier("monitor-move-to-hosted")
                    Button("Forget this Monitor", role: .destructive) { forgetting = true }
                } else if monitor.hosted {
                    LabeledContent("Using", value: "TeamTalk NG's Monitor")
                    NavigationLink("Set up your own Monitor (recommended)") { OwnMonitorPairView() }
                        .accessibilityIdentifier("monitor-use-own")
                    Button("Stop using TeamTalk NG's Monitor", role: .destructive) { leavingHosted = true }
                } else {
                    NavigationLink("Set up your own Monitor (recommended)") { OwnMonitorPairView() }
                        .accessibilityIdentifier("monitor-use-own")
                    Button("Use TeamTalk NG's Monitor") { choosingHosted = true }
                        .accessibilityIdentifier("monitor-use-hosted")
                }
            } header: {
                Text("Which Monitor")
            } footer: {
                if monitor.own != nil {
                    Text("Your Monitor runs on your computer: your server passwords and messages stay there. TeamTalk NG reaches it through its relay, end-to-end encrypted.")
                } else if monitor.hosted {
                    Text("TeamTalk NG's Monitor keeps the passwords of the servers it watches on TeamTalk NG's server, encrypted. Your own Monitor, on your computer, keeps them there instead; setting it up moves these servers to it.")
                } else {
                    Text("A Monitor stays logged in to your servers while TeamTalk NG isn't, keeps your private messages, and tells you what happened. Your own Monitor runs on your computer (Windows, Mac or Linux), so your server passwords never leave it. Without a computer, TeamTalk NG's Monitor can watch your servers instead; it keeps their passwords on its server, encrypted.")
                }
            }
        }
        .navigationTitle("Monitor")
        .refreshable { await monitor.refresh() }
        .task { await monitor.refresh() }
        .onAppear { monitor.startFollowing() }
        .onDisappear { monitor.stopFollowing() }
        .navigationDestination(isPresented: Binding(get: { settingsFor != nil }, set: { if !$0 { settingsFor = nil } })) {
            if let id = settingsFor { MonitorServerSettingsView(serverId: id) }
        }
        .sheet(isPresented: $adding) { AddMonitorView() }
        .confirmationDialog("Use TeamTalk NG's Monitor?", isPresented: $choosingHosted, titleVisibility: .visible) {
            Button("Use TeamTalk NG's Monitor") {
                monitor.useHosted()
                announce("Using TeamTalk NG's Monitor")
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("It watches the servers you choose from TeamTalk NG's server, so it keeps their accounts' passwords there, encrypted. Your own Monitor, on your computer, keeps them to yourself; you can move to it any time.")
        }
        .confirmationDialog("Use TeamTalk NG's Monitor instead?", isPresented: $movingToHosted, titleVisibility: .visible) {
            Button("Move to TeamTalk NG's Monitor") {
                Task {
                    let problem = await monitor.moveToHosted()
                    announce(problem ?? "Using TeamTalk NG's Monitor; your servers moved to it")
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your servers move to TeamTalk NG's Monitor, which keeps their passwords on its server, encrypted. Your own Monitor stops watching them but keeps running on your computer; to remove it there, run the install command with --uninstall.")
        }
        .confirmationDialog("Stop using TeamTalk NG's Monitor?", isPresented: $leavingHosted, titleVisibility: .visible) {
            Button("Stop using it", role: .destructive) {
                Task {
                    let problem = await monitor.stopHosted()
                    announce(problem ?? "No longer using TeamTalk NG's Monitor")
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("It logs out of your servers and deletes them and their passwords from TeamTalk NG's server, on all your devices.")
        }
        .confirmationDialog("Forget your Monitor?", isPresented: $forgetting, titleVisibility: .visible) {
            Button("Forget it", role: .destructive) {
                monitor.forgetOwn()
                announce("Monitor forgotten")
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("TeamTalk NG stops using it on this iPhone and your other devices. It keeps running on your computer; to unpair there, run ng-monitor phones, then ng-monitor unpair with the number.")
        }
        .confirmationDialog("Stop monitoring \(stopping?.name ?? "")?", isPresented: Binding(get: { stopping != nil }, set: { if !$0 { stopping = nil } }),
                            titleVisibility: .visible, presenting: stopping) { s in
            Button("Stop monitoring", role: .destructive) {
                Task { await monitor.remove(s); announce("No longer monitoring \(s.name)") }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("The Monitor logs out of it, and its conversations there go.")
        }
    }

    private func details(_ s: MonitorServer) -> String {
        guard s.enabled else { return "Off" }
        var parts = [s.statusText]
        if s.status == "logged_in" { parts.append(s.userCount == 1 ? "1 person" : "\(s.userCount) people") }
        if s.unreadPrivateMessages > 0 { parts.append("\(s.unreadPrivateMessages) unread") }
        return parts.joined(separator: ", ")
    }
}

private struct EventRow: View {
    let event: MonitorEvent
    let server: String?

    var body: some View {
        let time = Date(timeIntervalSince1970: TimeInterval(event.time) / 1000)
        VStack(alignment: .leading, spacing: 2) {
            Text(event.text)
            Text([server, time.formatted(date: .abbreviated, time: .shortened)].compactMap { $0 }.joined(separator: ", "))
                .font(.caption).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Choosing a saved server to monitor, then its settings before it starts.
struct AddMonitorView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    let candidates = model.servers.filter { model.monitor.monitor(of: $0) == nil }
                    if candidates.isEmpty {
                        Text("Every saved server is already monitored, or there are none. Add servers on the Servers screen.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(candidates) { s in
                        NavigationLink {
                            AddMonitorSettingsView(server: s) { dismiss() }
                        } label: {
                            VStack(alignment: .leading) {
                                Text(s.title)
                                Text(s.username.isEmpty ? s.host : "\(s.username) on \(s.host)").font(.caption).foregroundStyle(.secondary)
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                } footer: {
                    Text("The Monitor logs in with the server's saved account. Use one it may stay logged in with. You choose its nickname, status and channel next.")
                }
            }
            .navigationTitle("Monitor a server")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }
}

/// A new monitored server's settings, before the Monitor logs in: filled
/// in from the server's own nickname, the Monitor's defaults, then General.
struct AddMonitorSettingsView: View {
    @Environment(AppModel.self) private var model
    let server: SavedServer
    let done: () -> Void
    @State private var settings: MonitorStore.NewServerSettings?
    @State private var busy = false
    @State private var problem: String?

    var body: some View {
        Form {
            if settings != nil {
                Section {
                    TextField("Nickname", text: binding(\.nickname)).accessibilityLabel("Nickname")
                    TextField("Status message", text: binding(\.statusMessage)).accessibilityLabel("Status message")
                    Picker("Gender", selection: binding(\.gender)) {
                        Text("Male").tag(Gender.male)
                        Text("Female").tag(Gender.female)
                        Text("Neutral").tag(Gender.neutral)
                    }
                } header: {
                    Text("How others see it")
                }
                Section {
                    TextField("Channel to join", text: binding(\.channel))
                        .accessibilityLabel("Channel to join")
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    PasswordField("Channel password", text: binding(\.channelPassword))
                } header: {
                    Text("Channel")
                } footer: {
                    Text("The channel's path, such as /Lobby/; empty for the server's first channel.")
                }
                Section {
                    Button(busy ? "Starting…" : "Monitor") { start() }.disabled(busy)
                } footer: {
                    if let problem { Text(problem) }
                }
            }
        }
        // Scrolling puts the keyboard away (it hid the Monitor button).
        .scrollDismissesKeyboard(.immediately)
        .navigationTitle(server.title)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { if settings == nil { settings = model.monitor.newServerSettings(for: server) } }
    }

    private func binding<T>(_ path: WritableKeyPath<MonitorStore.NewServerSettings, T>) -> Binding<T> {
        Binding(get: { settings![keyPath: path] }, set: { settings![keyPath: path] = $0 })
    }

    private func start() {
        guard let s = settings else { return }
        busy = true
        Task {
            problem = await model.monitor.add(server, s)
            busy = false
            if let problem { announce(problem) } else { announce("Monitoring \(server.title)"); done() }
        }
    }
}

/// One monitored server: conversations, who's there, what happened.
struct MonitorServerView: View {
    @Environment(AppModel.self) private var model
    let serverId: Int64
    @State private var view: MonitorView?
    @State private var conversations: [MonitorConversation] = []

    var body: some View {
        let monitor = model.monitor
        let server = monitor.servers.first { $0.id == serverId }
        List {
            if let server {
                Section {
                    Text(server.statusText)
                } footer: {
                    Text("Its settings are on the Monitor screen, in its actions.")
                }
            }
            Section("Private conversations") {
                if conversations.isEmpty { Text("None yet.").foregroundStyle(.secondary) }
                ForEach(conversations, id: \.id) { c in
                    NavigationLink {
                        MonitorConversationView(serverId: serverId, conversation: c)
                    } label: {
                        VStack(alignment: .leading) {
                            Text(c.nickname.isEmpty ? c.username : c.nickname).font(.headline)
                            Text(summary(c)).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
            if let view {
                Section(view.users.count == 1 ? "1 person on the server" : "\(view.users.count) people on the server") {
                    ForEach(view.users.filter { $0.id != view.myUserId }, id: \.id) { u in
                        let channel = view.channels.first { $0.id == u.channelId }?.path
                        Text([u.displayName, channel.map { "in \($0)" }, u.statusMsg.isEmpty ? nil : u.statusMsg].compactMap { $0 }.joined(separator: ", "))
                    }
                }
            }
            let mine = monitor.events.filter { $0.serverId == serverId }
            if !mine.isEmpty {
                Section("Recent") {
                    ForEach(mine.suffix(50).reversed(), id: \.seq) { e in EventRow(event: e, server: nil) }
                }
            }
        }
        .navigationTitle(server?.name ?? "Monitor")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task { await load() }
        .onChange(of: monitor.events.count) { Task { await load() } }
    }

    private func summary(_ c: MonitorConversation) -> String {
        var parts: [String] = []
        if c.unread > 0 { parts.append("\(c.unread) unread") }
        if !c.lastText.isEmpty { parts.append(c.lastOutgoing ? "You: \(c.lastText)" : c.lastText) }
        if !c.active { parts.append("ended") }
        return parts.joined(separator: ", ")
    }

    private func load() async {
        let id = serverId
        if case .success(let v)? = await model.monitor.call({ try $0.view(serverId: id) }) { view = v }
        if case .success(let c)? = await model.monitor.call({ try $0.conversations(serverId: id) }) {
            conversations = c.sorted { $0.lastTime > $1.lastTime }
        }
    }
}

/// A private conversation through the Monitor.
struct MonitorConversationView: View {
    @Environment(AppModel.self) private var model
    let serverId: Int64
    let conversation: MonitorConversation
    @State private var messages: [MonitorMessage] = []
    @State private var draft = ""

    var body: some View {
        let name = conversation.nickname.isEmpty ? conversation.username : conversation.nickname
        VStack(spacing: 0) {
            List(messages, id: \.id) { m in
                let time = Date(timeIntervalSince1970: TimeInterval(m.time) / 1000)
                VStack(alignment: .leading, spacing: 2) {
                    Text(m.outgoing ? "You" : name).font(.caption.weight(.semibold))
                    Text(m.text)
                    Text(time.formatted(date: .abbreviated, time: .shortened)).font(.caption2).foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }
            .listStyle(.plain)
            if conversation.active {
                HStack {
                    TextField("Message \(name)", text: $draft, axis: .vertical).accessibilityLabel("Message \(name)")
                        .textFieldStyle(.roundedBorder)
                    Button("Send") { send() }
                        .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .padding()
            } else {
                Text("\(name) logged out, so this conversation has ended.")
                    .foregroundStyle(.secondary)
                    .padding()
            }
        }
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .onChange(of: model.monitor.events.count) { Task { await load() } }
    }

    private func load() async {
        let (s, c) = (serverId, conversation.id)
        if case .success(let m)? = await model.monitor.call({ try $0.messages(serverId: s, conversationId: c, before: nil) }) {
            messages = m
            await model.monitor.call { try $0.markRead(serverId: s, conversationId: c) }
        }
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        draft = ""
        let (s, c, u) = (serverId, conversation.id, conversation.userId)
        Task {
            let r = await model.monitor.call {
                try $0.sendMessage(serverId: s, to: .user(userId: u, conversationId: c), text: text)
            }
            if case .failure(let e)? = r { announce("Couldn't send: \(NGAccountStore.words(e))") } else { await load() }
        }
    }
}

/// Pairing with your own Monitor: how to install it on a computer, and
/// the code it shows.
struct OwnMonitorPairView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var code = ""
    @State private var pairing = false
    @State private var problem: String?

    private static let windows = "irm https://ttmonitor.mad-gamer.com/install.ps1 | iex"
    private static let macLinux = "curl -fsSL https://ttmonitor.mad-gamer.com/install.sh | sh"

    var body: some View {
        Form {
            Section {
                Text("Your own Monitor runs on your computer (Windows, Mac or Linux), or anything that stays on, like a Raspberry Pi. It stays logged in to your servers, keeps your private messages and sends your notifications, and your server passwords never leave it. Install it with one command, then type the code it shows.")
            }
            Section {
                Text(verbatim: Self.windows).font(.body.monospaced()).textSelection(.enabled)
                Button("Copy the Windows command") { copy(Self.windows) }
            } header: {
                Text("On Windows")
            } footer: {
                Text("In PowerShell. Windows asks once for administrator permission: the Monitor runs as a service, even before anyone signs in.")
            }
            Section {
                Text(verbatim: Self.macLinux).font(.body.monospaced()).textSelection(.enabled)
                Button("Copy the Mac and Linux command") { copy(Self.macLinux) }
            } header: {
                Text("On a Mac or Linux")
            } footer: {
                Text("In Terminal. It installs for you alone and starts with the computer.")
            }
            Section {
                TextField("Pairing code", text: $code)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("own-monitor-code")
                Button(pairing ? "Pairing…" : "Pair") { Task { await pair() } }
                    .disabled(pairing || code.trimmingCharacters(in: .whitespaces).isEmpty)
                    .accessibilityIdentifier("own-monitor-pair")
            } header: {
                Text("Pairing code")
            } footer: {
                if let problem {
                    Text(problem)
                } else {
                    Text("When it's installed, the Monitor shows a code like ABCD-1234-5678. It works for 10 minutes. Your other devices with TeamTalk NG use the same Monitor through iCloud. For another code, run ng-monitor pair on the computer."
                         + (model.monitor.hosted ? " Pairing moves the servers TeamTalk NG's Monitor watches to your own, and deletes them and their passwords from TeamTalk NG's server." : ""))
                }
            }
        }
        .navigationTitle("Set up your Monitor")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func copy(_ s: String) {
        UIPasteboard.general.string = s
        announce("Copied")
    }

    private func pair() async {
        pairing = true
        defer { pairing = false }
        problem = await model.monitor.pairOwn(code: code)
        if let problem {
            announce(problem)
        } else {
            announce("Paired with \(model.monitor.own?.name ?? "your Monitor")")
            dismiss()
        }
    }
}

/// One monitored server's settings: on or off, how the Monitor appears
/// there (nickname, status message, gender), and the channel it joins.
struct MonitorServerSettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let serverId: Int64
    @State private var config: MonitorServerConfig?
    @State private var loadProblem: String?
    @State private var nickname = ""
    @State private var statusMessage = ""
    @State private var gender: Gender = .male
    @State private var channel = ""
    @State private var channelPassword = ""
    @State private var busy = false

    var body: some View {
        let monitor = model.monitor
        let server = monitor.servers.first { $0.id == serverId }
        Form {
            if let server {
                Section {
                    LiveToggle("Monitoring", isOn: Binding(get: { server.enabled }, set: { on in
                        Task {
                            await monitor.setEnabled(server, on)
                            config = await monitor.config(server)
                        }
                    }))
                    Text(server.enabled ? server.statusText : "Off")
                }
            }
            if config != nil {
                Section {
                    TextField("Nickname", text: $nickname).accessibilityLabel("Nickname")
                    TextField("Status message", text: $statusMessage).accessibilityLabel("Status message")
                    Picker("Gender", selection: $gender) {
                        Text("Male").tag(Gender.male)
                        Text("Female").tag(Gender.female)
                        Text("Neutral").tag(Gender.neutral)
                    }
                } header: {
                    Text("How others see it")
                }
                Section {
                    TextField("Channel to join", text: $channel)
                        .accessibilityLabel("Channel to join")
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    PasswordField("Channel password", text: $channelPassword)
                } header: {
                    Text("Channel")
                } footer: {
                    Text("The channel's path, such as /Lobby/; empty for the server's first channel. Leave the password empty to keep the one saved.")
                }
                Section {
                    Button("Save") { save() }.disabled(busy)
                }
            } else if let loadProblem {
                Section { Text(loadProblem) }
            } else {
                Section { ProgressView("Loading its settings") }
            }
        }
        .navigationTitle(server?.name ?? "Monitor")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func load() async {
        guard let s = model.monitor.servers.first(where: { $0.id == serverId }) else {
            loadProblem = "This server isn't monitored any more."
            return
        }
        guard let c = await model.monitor.config(s) else {
            loadProblem = model.monitor.problem ?? "The Monitor didn't answer. Try again in a moment."
            return
        }
        config = c
        nickname = c.nickname
        statusMessage = c.statusMsg
        gender = Gender.fromMonitorBits(c.statusMode)
        channel = c.channel
    }

    private func save() {
        guard var c = config else { return }
        c.nickname = nickname
        c.statusMsg = statusMessage
        c.statusMode = Gender.monitorBits(gender)
        c.channel = channel
        busy = true
        Task {
            let problem = await model.monitor.save(c, channelPassword: channelPassword)
            busy = false
            if let problem {
                announce(problem)
            } else {
                channelPassword = ""
                config = c
                announce("Saved")
            }
        }
    }
}

/// Monitor → Notifications: what the Monitor notifies this iPhone about
/// (its own settings, kept by the Monitor), and the notification sound.
struct MonitorNotificationsView: View {
    @Environment(AppModel.self) private var model
    @State private var prefs: MonitorStore.NotificationPrefs?
    @State private var loadProblem: String?
    @State private var soundChoice = MonitorSound.choice

    private static let presence: [(String, String)] = [("all", "Everyone"), ("watched", "Only people I watch"), ("none", "Nobody")]
    private static let channel: [(String, String)] = [("all", "All"), ("mentions", "Only when I'm mentioned"), ("none", "None")]

    var body: some View {
        let monitor = model.monitor
        Form {
            if prefs != nil {
                Section {
                    Picker("Logins", selection: field(\.logins)) {
                        ForEach(Self.presence, id: \.0) { Text($0.1).tag($0.0) }
                    }
                    Picker("Logouts", selection: field(\.logouts)) {
                        ForEach(Self.presence, id: \.0) { Text($0.1).tag($0.0) }
                    }
                    NavigationLink("People I watch") {
                        NameListView(title: "People I watch", what: "a nickname or username", items: field(\.watched),
                                     footer: "Logins and logouts set to Only people I watch notify about these people.")
                    }
                } header: {
                    Text("Logins and logouts")
                }
                Section {
                    LiveToggle("Private messages", isOn: field(\.privateMessages))
                    Picker("Channel messages", selection: field(\.channelMessages)) {
                        ForEach(Self.channel, id: \.0) { Text($0.1).tag($0.0) }
                    }
                    NavigationLink("Words that mention me") {
                        NameListView(title: "Words that mention me", what: "a word", items: field(\.mentionWords),
                                     footer: "A channel message with your Monitor's nickname, or one of these words, mentions you.")
                    }
                    LiveToggle("Broadcast messages", isOn: field(\.broadcasts))
                } header: {
                    Text("Messages")
                }
                Section {
                    LiveToggle("Connection problems", isOn: field(\.connection))
                } footer: {
                    Text("Your Monitor lost a server for more than a minute, or was kicked.")
                }
                Section {
                    ForEach(monitor.servers, id: \.id) { s in
                        LiveToggle(s.name, isOn: Binding(
                            get: { !(prefs?.mutedServers.contains(s.id) ?? false) },
                            set: { on in
                                var p = prefs!
                                p.mutedServers.removeAll { $0 == s.id }
                                if !on { p.mutedServers.append(s.id) }
                                save(p)
                            }))
                    }
                    if let until = prefs?.mutedUntil, until > Int64(Date().timeIntervalSince1970 * 1000) {
                        let date = Date(timeIntervalSince1970: TimeInterval(until) / 1000)
                        Text("All notifications paused until \(date.formatted(date: .abbreviated, time: .shortened))")
                        Button("Resume notifications") { var p = prefs!; p.mutedUntil = nil; save(p) }
                    } else {
                        Button("Pause all for an hour") { pause(hours: 1) }
                        Button("Pause all for 8 hours") { pause(hours: 8) }
                        Button("Pause all for a day") { pause(hours: 24) }
                    }
                } header: {
                    Text("Servers")
                } footer: {
                    Text("A server turned off here doesn't notify you; the Monitor still watches it.")
                }
                Section {
                    NavigationLink("People never to notify about") {
                        NameListView(title: "People never to notify about", what: "a nickname or username", items: field(\.ignored),
                                     footer: "Nothing these people do notifies you: logins, logouts or messages.")
                    }
                }
            } else if let loadProblem {
                Section { Text(loadProblem) }
            } else {
                Section { ProgressView("Loading the notification settings") }
            }
            Section {
                Picker("Notification sound", selection: Binding(get: { MonitorSound.choice }, set: { MonitorSound.choice = $0; soundChoice = $0 })) {
                    ForEach(MonitorSound.Choice.allCases) { Text($0.label).tag($0) }
                }
                .id(soundChoice)
            } footer: {
                Text(monitor.own != nil
                     ? "These settings are your Monitor's, for every phone paired with it. The sound pack's sounds follow Settings → Sounds: a sound turned off there is silent here too."
                     : "These settings are for this iPhone. The sound pack's sounds follow Settings → Sounds: a sound turned off there is silent here too.")
            }
        }
        .navigationTitle("Notifications")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if let p = await monitor.notificationPrefs() { prefs = p } else { loadProblem = monitor.problem ?? "The Monitor didn't answer. Try again in a moment." }
        }
    }

    /// A setting: changed here at once, then saved on the Monitor.
    private func field<T>(_ path: WritableKeyPath<MonitorStore.NotificationPrefs, T>) -> Binding<T> {
        Binding(get: { prefs![keyPath: path] }, set: { var p = prefs!; p[keyPath: path] = $0; save(p) })
    }

    private func pause(hours: Int) {
        var p = prefs!
        p.mutedUntil = Int64(Date().addingTimeInterval(TimeInterval(hours * 3600)).timeIntervalSince1970 * 1000)
        save(p)
    }

    private func save(_ p: MonitorStore.NotificationPrefs) {
        let before = prefs
        prefs = p
        Task {
            if let problem = await model.monitor.setNotificationPrefs(p) {
                prefs = before
                announce("Couldn't save: \(problem)")
            }
        }
    }
}

/// A list of names or words to add to and remove from.
private struct NameListView: View {
    let title: String
    let what: String
    @Binding var items: [String]
    let footer: String
    @State private var adding = ""

    var body: some View {
        Form {
            Section {
                if items.isEmpty { Text("None yet.").foregroundStyle(.secondary) }
                ForEach(items, id: \.self) { item in
                    Text(verbatim: item)
                        .swipeActions { Button("Remove", role: .destructive) { remove(item) } }
                        .accessibilityActions { Button("Remove") { remove(item) } }
                }
            } footer: {
                Text(footer)
            }
            Section {
                TextField("Add \(what)", text: $adding)
                    .accessibilityLabel("Add \(what)")
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onSubmit(add)
                Button("Add") { add() }
                    .disabled(adding.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func add() {
        let new = adding.trimmingCharacters(in: .whitespaces)
        guard !new.isEmpty, !items.contains(where: { $0.caseInsensitiveCompare(new) == .orderedSame }) else { return }
        items = items + [new]
        adding = ""
        announce("\(new) added")
    }

    private func remove(_ item: String) {
        items = items.filter { $0 != item }
        announce("\(item) removed")
    }
}

/// Monitor → Default settings: what new monitored servers start with.
/// Empty, or a gender of None: General's (Settings → General).
struct MonitorDefaultsView: View {
    @State private var d = MonitorStore.defaults

    var body: some View {
        Form {
            Section {
                TextField("Nickname", text: $d.nickname).accessibilityLabel("Nickname")
                TextField("Status message", text: $d.statusMessage).accessibilityLabel("Status message")
                Picker("Gender", selection: $d.gender) {
                    Text("None").tag(Gender?.none)
                    Text("Male").tag(Gender?.some(.male))
                    Text("Female").tag(Gender?.some(.female))
                    Text("Neutral").tag(Gender?.some(.neutral))
                }
            } footer: {
                Text("A server you add to the Monitor starts with these; you can change them before it starts. Its own saved nickname comes first. Empty, or a gender of None, uses Settings → General.")
            }
        }
        .navigationTitle("Default settings")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: d.nickname) { MonitorStore.defaults = d }
        .onChange(of: d.statusMessage) { MonitorStore.defaults = d }
        .onChange(of: d.gender) { MonitorStore.defaults = d }
    }
}
