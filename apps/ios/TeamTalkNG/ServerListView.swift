import SwiftUI

/// The first screen: saved servers, with each one's connection state.
struct ServerListView: View {
    @Environment(AppModel.self) private var model
    @State private var editing: SavedServer?
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
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
                    Button("Add server", systemImage: "plus") { editing = SavedServer() }
                }
            }
            .sheet(item: $editing) { server in
                ServerEditView(server: server)
            }
            .sheet(isPresented: $showSettings) {
                SettingsView()
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
            if connection?.state != nil && connection?.state != .disconnected {
                Button("Disconnect") { connection?.disconnect() }
            }
            Button("Delete", role: .destructive) { model.delete(server) }
        }
        .accessibilityActions {
            Button("Edit", action: edit)
            if connection?.state != nil && connection?.state != .disconnected {
                Button("Disconnect") { connection?.disconnect() }
            }
            Button("Delete") { model.delete(server) }
        }
    }
}

/// Adding or changing a saved server.
struct ServerEditView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State var server: SavedServer
    @State private var password = ""
    @State private var tcp = ""
    @State private var udp = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $server.name)
                    TextField("Address", text: $server.host)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    TextField("TCP port", text: $tcp).keyboardType(.numberPad)
                    TextField("UDP port", text: $udp).keyboardType(.numberPad)
                    Toggle("Encrypted", isOn: $server.encrypted)
                }
                Section("Account") {
                    TextField("Username", text: $server.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Password", text: $password)
                    TextField("Nickname (optional)", text: $server.nickname)
                }
                Section {
                    TextField("Channel to join (optional), like /Lobby/", text: $server.joinChannel)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
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

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            Form {
                Section {
                    TextField("Nickname", text: $model.nickname)
                } footer: {
                    Text("Used on servers that don't have their own.")
                }
                Section("Talking") {
                    Picker("Talk mode", selection: $model.talkMode) {
                        ForEach(TalkMode.allCases) { Text($0.label).tag($0) }
                    }
                    if model.talkMode == .voiceActivation {
                        Slider(value: $model.voiceLevel, in: 0...100, step: 1) {
                            Text("Voice activation level")
                        }
                        .accessibilityValue("\(Int(model.voiceLevel))")
                    }
                }
                Section {
                    NavigationLink("Sounds") { SoundsView() }
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
                    LabeledContent("TeamTalk SDK", value: sdkVersion())
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}
