import SwiftUI
import UIKit

/// The share sheet, from anywhere (a menu item or a VoiceOver action).
@MainActor func presentShareSheet(_ items: [Any]) {
    guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first(where: { $0.activationState == .foregroundActive }),
          var top = scene.keyWindow?.rootViewController else { return }
    while let p = top.presentedViewController { top = p }
    let sheet = UIActivityViewController(activityItems: items, applicationActivities: nil)
    sheet.popoverPresentationController?.sourceView = top.view
    top.present(sheet, animated: true)
}

/// The first screen: saved servers, with each one's connection state.
struct ServerListView: View {
    @Environment(AppModel.self) private var model
    @State private var editing: SavedServer?
    @State private var showSettings = false
    @State private var showMonitor = false
    @State private var shownServerList = false
    @State private var showPublic = false
    @State private var firstRun = false
    @State private var importing = false
    @State private var linking = false
    @State private var link = ""
    @State private var search = ""

    /// Reordering in edit mode (not while searching: only some show).
    private var moving: ((IndexSet, Int) -> Void)? {
        guard search.isEmpty else { return nil }
        let m = model
        return { m.move(from: $0, to: $1) }
    }

    /// The servers whose name, address, username or nickname has what's
    /// searched for (all of them when nothing is).
    private var shownServers: [SavedServer] {
        let q = search.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return model.servers }
        return model.servers.filter { s in
            [s.title, s.host, s.username, s.nickname].contains { $0.localizedCaseInsensitiveContains(q) }
        }
    }

    var body: some View {
        @Bindable var model = model
        NavigationStack(path: $model.navigation) {
            List {
                if model.servers.isEmpty {
                    Text("No servers yet. Add one from Server List Actions.")
                        .foregroundStyle(.secondary)
                } else if shownServers.isEmpty {
                    Text("No servers match \"\(search)\".")
                        .foregroundStyle(.secondary)
                }
                // Dragged to reorder (touch and hold, then move), or Move
                // up and Move down; not while searching (only some show).
                ForEach(shownServers) { server in
                    ServerRow(server: server, connection: model.connections[server.id], edit: { editing = server },
                              canMove: search.isEmpty, index: model.servers.firstIndex(of: server) ?? 0,
                              count: model.servers.count)
                }
                .onMove(perform: moving)
            }
            .searchable(text: $search, prompt: "Search servers")
            .navigationTitle("Servers")
            .navigationDestination(for: SavedServer.self) { server in
                ServerView(connection: model.connection(for: server))
            }
            // A tapped Monitor notification: its server, as if connected.
            .navigationDestination(isPresented: Binding(get: { model.openMonitor != nil }, set: { if !$0 { model.openMonitor = nil } })) {
                if let m = model.openMonitor { ServerView(connection: model.monitorConnection(for: m)) }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Settings", systemImage: "gearshape") { showSettings = true }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu("Server List Actions", systemImage: "plus") {
                        Button("Type its details") { editing = SavedServer() }
                        Button("Public servers and join codes") { showPublic = true }
                        Button("Import a .tt file") { importing = true }
                        // The desktop's "Export Server list to .tt File".
                        if !model.servers.isEmpty {
                            Button("Save the Server List as a File") { presentShareSheet([ttFileURL(for: model.servers)]) }
                        }
                        Button("Open a tt:// link") { linking = true }
                        // Everything about the Monitor, in one place.
                        Button("Monitor") { showMonitor = true }
                    }
                    .accessibilityLabel("Server List Actions")
                    // Its items as VoiceOver actions too, reversed.
                    .accessibilityActions {
                        Button("Monitor") { showMonitor = true }
                        Button("Open a tt:// link") { linking = true }
                        if !model.servers.isEmpty {
                            Button("Save the Server List as a File") { presentShareSheet([ttFileURL(for: model.servers)]) }
                        }
                        Button("Import a .tt file") { importing = true }
                        Button("Public servers and join codes") { showPublic = true }
                        Button("Type its details") { editing = SavedServer() }
                    }
                }
            }
            .navigationDestination(isPresented: $showMonitor) { MonitorListView() }
            .sheet(item: $editing) { server in
                ServerEditView(server: server)
            }
            .sheet(isPresented: $showSettings) {
                SettingsView()
            }
            .sheet(isPresented: $showPublic) { PublicServersView() }
            .sheet(isPresented: $firstRun) { FirstRunView() }
            .sheet(item: Binding(get: { model.backupToRestore }, set: { model.backupToRestore = $0 })) { c in
                RestoreBackupView(contents: c)
            }
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
        #if DEBUG
        // UI tests: what the last test action said.
        .overlay(alignment: .bottom) {
            if !model.uiTestActionResult.isEmpty {
                Text(model.uiTestActionResult).font(.caption).accessibilityIdentifier("uitest-action-result")
            }
        }
        #endif
    }
}

private struct ServerRow: View {
    @Environment(AppModel.self) private var model
    let server: SavedServer
    let connection: ServerConnection?
    let edit: () -> Void
    /// Reordering offered (not while searching), and where it is.
    let canMove: Bool
    let index: Int
    let count: Int
    @State private var deleting = false

    var body: some View {
        let up = canMove && index > 0
        let down = canMove && index < count - 1
        NavigationLink(value: server) {
            // Only what the server is, as the old app: its name (when it
            // has one) and host:port. Never its state or an error.
            // (A name that is only its host, as from a tt:// link, isn't
            // repeated; the port is plain digits, not "10,333".)
            let named = !server.name.isEmpty && server.name.caseInsensitiveCompare(server.host) != .orderedSame
            VStack(alignment: .leading) {
                if named { Text(verbatim: server.name).font(.headline) }
                Text(verbatim: "\(server.host):\(String(server.tcpPort))")
                    .font(named ? .subheadline : .headline)
                    .foregroundStyle(named ? .secondary : .primary)
            }
            .accessibilityElement(children: .combine)
        }
        .draggable(server.id.uuidString)
        .dropDestination(for: String.self) { ids, _ in
            guard canMove, let id = ids.first.flatMap(UUID.init(uuidString:)) else { return false }
            model.moveServer(id, onto: server.id)
            return true
        }
        .swipeActions {
            Button("Delete", role: .destructive) { deleting = true }
            Button("Edit", action: edit).tint(.blue)
        }
        .contextMenu {
            Button("Edit", action: edit)
            ShareLink(item: ttFileURL(for: server, withPassword: false)) { Text("Share as a .tt file") }
            Button("Copy its tt:// link") {
                UIPasteboard.general.string = ttLink(entry: server.entry(password: Passwords.get(server.id)))
                announce("Link copied")
            }
            if connection?.state != nil && connection?.state != .disconnected {
                Button("Disconnect") { connection?.disconnect() }
            }
            if up { Button("Move up") { model.moveServer(server, by: -1) } }
            if down { Button("Move down") { model.moveServer(server, by: 1) } }
            Button("Delete", role: .destructive) { deleting = true }
        }
        // Reversed for VoiceOver (the touch-and-hold menu's order, backwards).
        .accessibilityActions {
            Button("Delete") { deleting = true }
            if down { Button("Move down") { model.moveServer(server, by: 1) } }
            if up { Button("Move up") { model.moveServer(server, by: -1) } }
            if connection?.state != nil && connection?.state != .disconnected {
                Button("Disconnect") { connection?.disconnect() }
            }
            Button("Copy its tt:// link") {
                UIPasteboard.general.string = ttLink(entry: server.entry(password: Passwords.get(server.id)))
                announce("Link copied")
            }
            Button("Edit", action: edit)
        }
        .confirmationDialog("Delete \(server.title)?", isPresented: $deleting, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { model.delete(server) }
            Button("Cancel", role: .cancel) {}
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
                    // The BearWare.dk account logs in: no username or password here.
                    if !server.bearwareLogin {
                        TextField("Username", text: $server.username).accessibilityLabel("Username")
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        if showPassword {
                            TextField("Password", text: $password).accessibilityLabel("Password")
                                .textInputAutocapitalization(.never).autocorrectionDisabled()
                        } else {
                            PasswordField("Password", text: $password)
                        }
                        // The desktop's "Show password".
                        Toggle("Show password", isOn: $showPassword)
                    }
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
                            PasswordField("Its password (optional)", text: $server.channelPassword, showLabel: "Show channel password")
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

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            Form {
                Section {
                    NavigationLink("General") { GeneralSettingsView() }
                    NavigationLink("Sound system") { SoundSystemView() }
                    NavigationLink("Sounds") { SoundsView() }
                    NavigationLink("Spoken events") { SpeechView() }
                    NavigationLink("Display") { DisplaySettingsView() }
                    NavigationLink("Connection") { ConnectionSettingsView() }
                    NavigationLink("Recording") { RecordingSettingsView() }
                    NavigationLink("Live Activities") { LiveActivitySettingsView() }
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
                    NavigationLink("Transfer or Reset") { TransferOrResetView() }
                }
                Section {
                    NavigationLink("Help") { HelpView() }
                    NavigationLink("About") { AboutView() }
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
