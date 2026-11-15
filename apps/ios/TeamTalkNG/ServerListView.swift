import SwiftUI

/// The first screen: saved servers, with each one's connection state.
struct ServerListView: View {
    @Environment(AppModel.self) private var model
    @State private var editing: SavedServer?
    @State private var showSettings = false
    @State private var shownServerList = false
    @State private var showPublic = false
    @State private var firstRun = false
    @State private var importing = false
    @State private var linking = false
    @State private var link = ""

    var body: some View {
        @Bindable var model = model
        NavigationStack(path: $model.navigation) {
            List {
                Section {
                    NavigationLink {
                        MonitorListView()
                    } label: {
                        // A label with an empty value read as nothing to
                        // VoiceOver: the name always, the count when any.
                        let unread = model.monitor.unread
                        HStack {
                            Label("Monitor", systemImage: "eye")
                            Spacer()
                            if unread > 0 {
                                Text("\(unread) unread").foregroundStyle(.secondary)
                            }
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Monitor")
                        .accessibilityValue(unread > 0 ? "\(unread) unread private messages" : "")
                    }
                }
                if model.servers.isEmpty {
                    Text("No servers yet. Add one with the Add server button.")
                        .foregroundStyle(.secondary)
                }
                ForEach(model.servers) { server in
                    ServerRow(server: server, connection: model.connections[server.id], edit: { editing = server })
                }
                .onMove(perform: model.move)
            }
            .navigationTitle("Servers")
            .navigationDestination(for: SavedServer.self) { server in
                ServerView(connection: model.connection(for: server))
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Settings", systemImage: "gearshape") { showSettings = true }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu("Add server", systemImage: "plus") {
                        Button("Type its details") { editing = SavedServer() }
                        Button("Public servers and join codes") { showPublic = true }
                        Button("Import a .tt file") { importing = true }
                        // The desktop's "Export Server list to .tt File".
                        if !model.servers.isEmpty {
                            ShareLink(item: ttFileURL(for: model.servers)) { Text("Export Server list to .tt File") }
                        }
                        Button("Open a tt:// link") { linking = true }
                    }
                }
            }
            .sheet(item: $editing) { server in
                ServerEditView(server: server)
            }
            .sheet(isPresented: $showSettings) {
                SettingsView()
            }
            .sheet(isPresented: $showPublic) { PublicServersView() }
            .sheet(isPresented: $firstRun) { FirstRunView() }
            .onAppear {
                if !UserDefaults.standard.bool(forKey: "setUp") && model.servers.isEmpty { firstRun = true }
                // The desktop's "Show dialog box with server list on startup".
                else if model.serverListOnStart && !shownServerList { shownServerList = true; showPublic = true }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.teamTalkFile, .xml, .data]) { r in
                if case .success(let url) = r { model.open(url) }
            }
            .alert("Open a tt:// link", isPresented: $linking) {
                TextField("tt://", text: $link).accessibilityLabel("tt:// link").textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("Open") {
                    if let u = URL(string: link.trimmingCharacters(in: .whitespaces)), u.scheme?.lowercased() == "tt" { model.open(u) } else { announce("That isn't a tt:// link") }
                    link = ""
                }
                Button("Cancel", role: .cancel) { link = "" }
            }
        }
    }
}

private struct ServerRow: View {
    @Environment(AppModel.self) private var model
    let server: SavedServer
    let connection: ServerConnection?
    let edit: () -> Void

    var body: some View {
        NavigationLink(value: server) {
            VStack(alignment: .leading) {
                Text(server.title).font(.headline)
                Text(connection?.stateText ?? "Not connected")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
        }
        .swipeActions {
            Button("Delete", role: .destructive) { model.delete(server) }
            Button("Edit", action: edit).tint(.blue)
        }
        .contextMenu {
            Button("Edit", action: edit)
            ShareLink(item: ttFileURL(for: server, withPassword: false)) { Text("Share as a .tt file") }
            Button("Copy its tt:// link") {
                UIPasteboard.general.string = ttLink(entry: server.entry(password: ""))
                announce("Link copied")
            }
            if connection?.state != nil && connection?.state != .disconnected {
                Button("Disconnect") { connection?.disconnect() }
            }
            Button("Delete", role: .destructive) { model.delete(server) }
        }
        // Reversed for VoiceOver (the touch-and-hold menu's order, backwards).
        .accessibilityActions {
            Button("Delete") { model.delete(server) }
            if connection?.state != nil && connection?.state != .disconnected {
                Button("Disconnect") { connection?.disconnect() }
            }
            Button("Copy its tt:// link") {
                UIPasteboard.general.string = ttLink(entry: server.entry(password: ""))
                announce("Link copied")
            }
            Button("Edit", action: edit)
        }
    }
}

/// Adding or changing a saved server.
struct ServerEditView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State var server: SavedServer
    @State private var importingCert: CertKind?
    @State private var showPassword = false
    @State private var showChannelPassword = false

    enum CertKind { case ca, cert, key }

    @ViewBuilder
    private func cert(_ label: String, _ path: WritableKeyPath<SavedServer, String>, _ kind: CertKind) -> some View {
        let has = !server[keyPath: path].isEmpty
        HStack {
            Text(label)
            Spacer()
            Text(has ? "Imported" : "None").foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityActions {
            if has { Button("Remove") { server[keyPath: path] = "" } }
            Button("Import from Files") { importingCert = kind }
        }
        .contextMenu {
            Button("Import from Files") { importingCert = kind }
            if has { Button("Remove", role: .destructive) { server[keyPath: path] = "" } }
        }
        .onTapGesture { importingCert = kind }
    }
    @State private var password = ""
    @State private var tcp = ""
    @State private var udp = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $server.name).accessibilityLabel("Name")
                    TextField("Address", text: $server.host).accessibilityLabel("Address")
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    TextField("TCP port", text: $tcp).accessibilityLabel("TCP port").keyboardType(.numberPad)
                    TextField("UDP port", text: $udp).accessibilityLabel("UDP port").keyboardType(.numberPad)
                    Toggle("Encrypted", isOn: $server.encrypted)
                }
                if server.encrypted {
                    Section {
                        cert("Certificate authority", \.caPem, .ca)
                        cert("Client certificate", \.certPem, .cert)
                        cert("Client private key", \.keyPem, .key)
                        Toggle("Check the server's certificate", isOn: $server.verifyPeer)
                    } header: {
                        Text("Certificates (optional)")
                    } footer: {
                        Text("As the desktop's Encryption Setup: the authority whose certificate the server must have (with checking on), and a certificate of yours for servers that ask for one. Import each from Files (a .pem file).")
                    }
                }
                Section("Account") {
                    Toggle("Log in with my BearWare.dk account", isOn: Binding(
                        get: { server.bearwareLogin },
                        set: { server.username = $0 ? "bearware" : "" }))
                    TextField("Username", text: $server.username).accessibilityLabel("Username")
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    if showPassword {
                        TextField("Password", text: $password).accessibilityLabel("Password")
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                    } else {
                        SecureField("Password", text: $password).accessibilityLabel("Password")
                    }
                    // The desktop's "Show password".
                    Toggle("Show password", isOn: $showPassword)
                    TextField("Nickname (optional)", text: $server.nickname).accessibilityLabel("Nickname (optional)")
                    TextField("Status message (optional)", text: $server.statusMessage).accessibilityLabel("Status message (optional)")
                }
                Section {
                    Toggle("Connect when the app starts", isOn: Binding(get: { server.connectOnStart ?? false }, set: { server.connectOnStart = $0 }))
                    Toggle("Join the channel I was last in", isOn: Binding(get: { server.joinLastChannel ?? false }, set: { server.joinLastChannel = $0 }))
                    TextField("Channel to join (optional), like /Lobby/", text: $server.joinChannel).accessibilityLabel("Channel to join (optional), like /Lobby/")
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    if !server.joinChannel.isEmpty {
                        if showChannelPassword {
                            TextField("Its password (optional)", text: $server.channelPassword).accessibilityLabel("Its password (optional)")
                                .textInputAutocapitalization(.never).autocorrectionDisabled()
                        } else {
                            SecureField("Its password (optional)", text: $server.channelPassword).accessibilityLabel("Its password (optional)")
                        }
                        Toggle("Show channel password", isOn: $showChannelPassword)
                    }
                }
            }
            .navigationTitle(model.servers.contains { $0.id == server.id } ? "Edit server" : "Add server")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        server.host = server.host.trimmingCharacters(in: .whitespaces)
                        server.tcpPort = UInt16(tcp) ?? 10333
                        server.udpPort = UInt16(udp) ?? server.tcpPort
                        model.upsert(server, password: password)
                        dismiss()
                    }
                    .disabled(server.host.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .fileImporter(isPresented: Binding(get: { importingCert != nil }, set: { if !$0 { importingCert = nil } }),
                          allowedContentTypes: [.data, .text]) { r in
                guard case .success(let url) = r, let kind = importingCert else { return }
                let reading = url.startAccessingSecurityScopedResource()
                defer { if reading { url.stopAccessingSecurityScopedResource() } }
                guard let pem = try? String(contentsOf: url, encoding: .utf8), pem.contains("-----BEGIN") else {
                    announce("That isn't a PEM certificate or key")
                    return
                }
                switch kind {
                case .ca: server.caPem = pem
                case .cert: server.certPem = pem
                case .key: server.keyPem = pem
                }
                announce("Imported \(url.lastPathComponent)")
                importingCert = nil
            }
            .onAppear {
                password = Passwords.get(server.id)
                tcp = String(server.tcpPort)
                udp = String(server.udpPort)
            }
        }
    }
}

/// Settings for every server.
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var resetting = false

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            Form {
                Section {
                    TextField("Nickname", text: $model.nickname).accessibilityLabel("Nickname")
                    Picker("Gender", selection: $model.gender) {
                        Text("Male").tag(Gender.male)
                        Text("Female").tag(Gender.female)
                        Text("Neutral").tag(Gender.neutral)
                    }
                    TextField("Status message", text: $model.statusMessage).accessibilityLabel("Status message")
                } footer: {
                    Text("Used on servers that don't have their own.")
                }
                Section {
                    // The desktop's: seconds of inactivity, 0 means disabled.
                    NumberField("Set away status after (seconds)", value: $model.awayAfterSeconds, in: 0...86400)
                    if model.awayAfterSeconds > 0 {
                        TextField("Status message during inactivity", text: $model.awayMessage).accessibilityLabel("Status message during inactivity")
                        Toggle("Disable voice activation during inactivity", isOn: $model.awayStopsVoiceActivation)
                    }
                } header: {
                    Text("Away")
                } footer: {
                    Text("Inactivity here: TeamTalk NG in the background or the iPhone locked that long; your status becomes Away and comes back when you return. 0 means disabled.")
                }
                Section("Talking") {
                    Picker("Talk mode", selection: $model.talkMode) {
                        ForEach(TalkMode.allCases) { Text($0.label).tag($0) }
                    }
                    if model.talkMode == .pushToTalk {
                        Toggle("Push To Talk Lock", isOn: $model.pttLock)
                    }
                    if model.talkMode == .voiceActivation {
                        NamedSlider("Voice activation level", value: $model.voiceLevel, in: 0...20, step: 1,
                                    spoken: "\(Int(model.voiceLevel))")
                    }
                }
                Section {
                    NavigationLink("BearWare.dk account") { BearWareView() }
                    NavigationLink("Sound system") { SoundSystemView() }
                    NavigationLink("Sounds") { SoundsView() }
                    NavigationLink("Spoken events") { SpeechView() }
                    NavigationLink("Display") { DisplaySettingsView() }
                    NavigationLink("Connection") { ConnectionSettingsView() }
                    NavigationLink("Recording") { RecordingSettingsView() }
                    NavigationLink("iCloud sync") { ICloudSyncView() }
                    NavigationLink {
                        NGAccountView()
                    } label: {
                        let who = model.account.email ?? "Not signed in"
                        HStack {
                            Text("NG Account")
                            Spacer()
                            Text(who).foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("NG Account")
                        .accessibilityValue(who)
                    }
                }
                Section {
                    Button("Reset all settings", role: .destructive) { resetting = true }
                } footer: {
                    Text("Servers, your NG Account and downloaded sound packs stay.")
                }
                Section {
                    NavigationLink("Help") { HelpView() }
                    NavigationLink("About") { AboutView() }
                }
            }
            .confirmationDialog("Reset all settings?", isPresented: $resetting, titleVisibility: .visible) {
                Button("Reset", role: .destructive) { model.resetPreferences(); announce("Settings reset") }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}
