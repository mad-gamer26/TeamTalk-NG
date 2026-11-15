import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    /// TeamTalk's server files.
    static let teamTalkFile = UTType(exportedAs: "dk.bearware.teamtalk.tt", conformingTo: .xml)
}

/// The BearWare.dk account (the desktop's web login), in the keychain.
enum BearWare {
    private static let service = "TeamTalk NG BearWare.dk"
    static var username: String { Passwords.secret(service, "username") }
    static var token: String { Passwords.secret(service, "token") }
    static var signedIn: Bool { !username.isEmpty && !token.isEmpty }

    static func save(_ a: BearWareAccount) {
        Passwords.setSecret(a.username, service, "username")
        Passwords.setSecret(a.token, service, "token")
    }

    static func signOut() {
        Passwords.setSecret("", service, "username")
        Passwords.setSecret("", service, "token")
    }
}

/// Settings → BearWare.dk account.
struct BearWareView: View {
    @Environment(AppModel.self) private var model
    @State private var username = ""
    @State private var password = ""
    @State private var busy = false
    @State private var problem: String?
    @State private var who = BearWare.username

    var body: some View {
        Form {
            if who.isEmpty {
                Section {
                    TextField("BearWare.dk username", text: $username)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("Password", text: $password)
                    Button(busy ? "Signing in…" : "Sign in") { signIn() }
                        .disabled(busy || username.isEmpty || password.isEmpty)
                    if let problem { Text(problem) }
                } footer: {
                    Text("Some servers take BearWare.dk accounts: give such a server the username \"bearware\" and it logs you in with this account.")
                }
            } else {
                Section {
                    LabeledContent("Signed in as", value: who)
                    Button("Sign out", role: .destructive) { BearWare.signOut(); who = ""; announce("Signed out") }
                }
            }
            Section {
                @Bindable var model = model
                Toggle("Restore volume settings and subscriptions on login for Web Login users", isOn: $model.restoreUserSettings)
            } footer: {
                Text("People logged in with a BearWare.dk account (…@bearware.dk) get back the volume, mute, stereo and subscriptions you gave them, when they log in again while you're connected.")
            }
        }
        .navigationTitle("BearWare.dk account")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func signIn() {
        busy = true
        let (u, p) = (username, password)
        Task {
            let r = await Task.detached { Result { try bearwareSignIn(username: u, password: p) } }.value
            busy = false
            switch r {
            case .success(let a):
                BearWare.save(a)
                who = a.username
                password = ""
                announce("Signed in as \(a.username)")
            case .failure(let e):
                problem = words(e)
                announce(words(e))
            }
        }
    }
}

/// BearWare's public server list, and join codes.
struct PublicServersView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var servers: [HostEntry]?
    @State private var problem: String?
    @State private var unofficial = false
    @State private var code = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        TextField("Join code", text: $code)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                        Button("Add") { Task { await joinCode() } }.disabled(code.isEmpty)
                    }
                } footer: {
                    Text("A server's owner can give you a join code instead of its address.")
                }
                Section {
                    Toggle("Include unofficial servers", isOn: $unofficial)
                    if let problem { Text("Couldn't load the list: \(problem)") }
                    if let servers {
                        ForEach(servers, id: \.self) { s in
                            Button { add(s) } label: {
                                VStack(alignment: .leading) {
                                    Text(s.name)
                                    Text(details(s)).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .foregroundStyle(.primary)
                            .accessibilityElement(children: .combine)
                            .accessibilityHint("Double-tap to add it to your servers.")
                        }
                    } else if problem == nil {
                        ProgressView("Loading the list")
                    }
                } header: {
                    Text("Public servers")
                }
            }
            .navigationTitle("Public servers")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
            .task(id: unofficial) { await load() }
        }
    }

    private func details(_ s: HostEntry) -> String {
        var p = [s.listing.capitalized, s.userCount == 1 ? "1 person" : "\(s.userCount) people"]
        if !s.country.isEmpty { p.append(s.country) }
        if s.encrypted { p.append("encrypted") }
        if !s.motd.isEmpty { p.append(s.motd) }
        return p.filter { !$0.isEmpty }.joined(separator: ", ")
    }

    private func load() async {
        servers = nil
        problem = nil
        let u = unofficial
        switch await Task.detached(operation: { Result { try publicServers(official: true, unofficial: u) } }).value {
        case .success(let l): servers = l
        case .failure(let e): problem = words(e)
        }
    }

    private func joinCode() async {
        let c = code
        switch await Task.detached(operation: { Result { try serverForJoinCode(code: c) } }).value {
        case .success(let e): add(e)
        case .failure(let e): announce(words(e))
        }
    }

    private func add(_ e: HostEntry) {
        model.addFromEntry(e)
        announce("Added \(e.name)")
        dismiss()
    }
}

/// A .tt file to share (written for the share sheet).
func ttFileURL(for s: SavedServer, withPassword: Bool) -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("share", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent("\(s.title.replacingOccurrences(of: "/", with: "-")).tt")
    try? ttFile(entry: s.entry(password: withPassword ? Passwords.get(s.id) : "")).write(to: url, atomically: true, encoding: .utf8)
    return url
}
