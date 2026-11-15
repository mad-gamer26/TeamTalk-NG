import AudioNetKit
import Foundation
import Observation
import Security
import SwiftUI

/// AudioNet in TeamTalk NG (the old app's): send the sound of one of your
/// AudioNet devices (its microphone, or what's playing on it) into the
/// channel, mixed with an audio file if you stream one, while your
/// microphone stays on. NG signs in to the AudioNet account as a visitor,
/// like AudioNet's web client: no device is added to the account. The
/// device's sound comes into an AudioTap (AudioNet's engine hands it to the
/// app instead of a speaker); the live mix reads it.
@MainActor @Observable
final class AudioNetStore {
    enum Connection: Equatable {
        case signedOut, connecting, connected
        case disconnected(String)
        /// Signed in, not connected (nothing being sent, the screen closed).
        case idle
    }

    struct Sending {
        let sessionId: String
        let deviceName: String
        let sourceName: String
        let tap: AudioTap
        var active: Bool
    }

    private(set) var login: VisitorLogin?
    private(set) var connection = Connection.signedOut
    private(set) var devices: [Device] = []
    private(set) var sending: Sending?
    /// The engine's latest status line.
    private(set) var status = ""
    private(set) var busy = false
    /// The sending connection's mix ends AudioNet's part (set by it).
    @ObservationIgnored var onEnded: ((String) -> Void)?

    @ObservationIgnored private var client: Client?
    /// Which client's events count (a stopped one's late events don't).
    @ObservationIgnored private var generation = 0

    init() { login = Self.loadLogin() }

    var lastServer: String { login?.serverUrl ?? UserDefaults.standard.string(forKey: "audioNetServer") ?? "" }
    var lastUsername: String { login?.username ?? UserDefaults.standard.string(forKey: "audioNetUsername") ?? "" }

    /// Devices that can be listened to (AudioNet lists only visible ones:
    /// running with visibility on), with sounds.
    var listenable: [Device] {
        devices.filter { !$0.sources.isEmpty }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    var connectionText: String {
        switch connection {
        case .signedOut: "signed out"
        case .connecting: "connecting"
        case .connected: "connected"
        case .disconnected: "reconnecting"
        case .idle: "not connected"
        }
    }

    func connectIfSignedIn() {
        guard let login, client == nil else { return }
        generation += 1
        let c = Client.visitor(login: login, appName: "TeamTalk NG", listener: Events(owner: self, generation: generation))
        client = c
        connection = .connecting
        c.start()
    }

    func signIn(server: String, username: String, password: String) async -> String? {
        let server = server.trimmingCharacters(in: .whitespacesAndNewlines)
        let username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        UserDefaults.standard.set(server, forKey: "audioNetServer")
        UserDefaults.standard.set(username, forKey: "audioNetUsername")
        busy = true
        defer { busy = false }
        let r = await Task.detached { Result { try visitorSignIn(serverUrl: server, username: username, password: password) } }.value
        switch r {
        case .success(let l):
            Self.saveLogin(l)
            login = l
            connectIfSignedIn()
            return nil
        case .failure(let e):
            return Self.words(e)
        }
    }

    func signOut() {
        stopSending()
        generation += 1
        let old = client, l = login
        client = nil
        Task.detached {
            old?.stop()
            // Ends the visitor's session; nothing else is left (no device added).
            if let l { _ = try? visitorSignOut(login: l) }
        }
        Self.deleteLogin()
        login = nil
        devices = []
        connection = .signedOut
        status = ""
    }

    /// Listens to `source` of `device` into a new tap in the mix's format.
    func startListening(device: Device, source: Source) throws -> AudioTap {
        guard let client, connection == .connected else {
            throw AudioNetError.Failed(message: "AudioNet isn't connected yet. Try again in a moment.")
        }
        // Another sound chosen while sending: only that stream ends (not
        // the connection, which this listen needs).
        if let s = sending {
            client.stopStream(sessionId: s.sessionId)
            sending = nil
        }
        let tap = AudioTap(name: "TeamTalk channel", sampleRate: UInt32(ChannelMix.sampleRate), channels: UInt32(ChannelMix.channels))
        let session = try client.listen(nodeId: device.nodeId, sourceId: source.id, outputId: tap.destinationId())
        sending = Sending(sessionId: session, deviceName: device.name, sourceName: source.name, tap: tap, active: false)
        return tap
    }

    /// The AudioNet screen is open (it needs the device list).
    var screenOpen = false {
        didSet {
            if screenOpen { connectIfSignedIn() } else if sending == nil { closeSession() }
        }
    }

    /// Stops sending, and closes the session completely: the stream, the
    /// tap, the connection to AudioNet (the sign-in stays; it connects
    /// again when the AudioNet screen is open).
    func stopSending() {
        closeSession()
        if screenOpen { connectIfSignedIn() }
    }

    private func closeSession() {
        let c = client, session = sending?.sessionId
        sending = nil
        guard c != nil || session != nil else { return }
        // Late events of this session don't count.
        generation += 1
        client = nil
        devices = []
        if login != nil { connection = .idle }
        Task.detached {
            if let session { c?.stopStream(sessionId: session) }
            c?.stop()
        }
    }

    static func words(_ e: Error) -> String {
        if case AudioNetError.Failed(let m) = e { return m }
        return e.localizedDescription
    }

    private func ended(_ session: String, reason: String) {
        guard sending?.sessionId == session else { return }
        onEnded?(reason)
        // Ended by AudioNet: closed completely too.
        stopSending()
    }

    fileprivate func handle(_ event: AudioNetKit.Event, generation g: Int) {
        guard g == generation else { return }
        switch event {
        case .connected:
            connection = .connected
            client?.refreshDevices()
        case .disconnected(let reason):
            connection = .disconnected(reason)
        case .status(let text):
            status = text
        case .devices(let list):
            devices = list
        case .deviceChanged(let d):
            if let i = devices.firstIndex(where: { $0.nodeId == d.nodeId }) { devices[i] = d } else { devices.append(d) }
        case .deviceGone(let nodeId):
            // No longer visible (visibility off, or AudioNet stopped there).
            devices.removeAll { $0.nodeId == nodeId }
        case .stream(let session, let state, let detail):
            switch state {
            case .active:
                if sending?.sessionId == session, sending?.active == false {
                    sending?.active = true
                    announce("AudioNet sound is being sent to the channel.")
                }
            case .failed, .ended: ended(session, reason: detail)
            case .starting: break
            }
        case .streamEnded(let session, let reason):
            ended(session, reason: reason)
        case .serverProblem(let message):
            status = message
        case .stopped(let error):
            // The sign-in ended for good (expired, or ended elsewhere).
            client = nil
            if let s = sending { sending = nil; onEnded?(error ?? "AudioNet stopped"); _ = s }
            devices = []
            if let error {
                Self.deleteLogin()
                login = nil
                connection = .signedOut
                status = error
            } else {
                connection = .disconnected("")
            }
        case .diagnostics:
            break
        }
    }

    /// The engine's events (on its threads), moved to the main thread.
    private final class Events: AudioNetKit.EventListener, @unchecked Sendable {
        weak var owner: AudioNetStore?
        let generation: Int
        init(owner: AudioNetStore, generation: Int) { self.owner = owner; self.generation = generation }
        func onEvent(event: AudioNetKit.Event) {
            let g = generation
            Task { @MainActor [weak owner] in owner?.handle(event, generation: g) }
        }
    }

    // MARK: The visitor sign-in (its token stands in for the password), on this iPhone only

    private static let keychain: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "AudioNet sign-in",
        kSecAttrAccount as String: "visitor",
    ]

    private static func loadLogin() -> VisitorLogin? {
        var q = keychain
        q[kSecReturnData as String] = true
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data,
              let f = try? JSONSerialization.jsonObject(with: d) as? [String: String],
              let s = f["server_url"], let u = f["username"], let t = f["token"]
        else { return nil }
        return VisitorLogin(serverUrl: s, username: u, token: t)
    }

    private static func saveLogin(_ l: VisitorLogin) {
        guard let d = try? JSONSerialization.data(withJSONObject: ["server_url": l.serverUrl, "username": l.username, "token": l.token]) else { return }
        deleteLogin()
        var q = keychain
        q[kSecValueData as String] = d
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(q as CFDictionary, nil)
    }

    private static func deleteLogin() { SecItemDelete(keychain as CFDictionary) }
}

// MARK: The AudioNet screen

/// The server screen's AudioNet: sign in, choose a device's sound to send
/// to the channel, its volume, and stop.
struct AudioNetView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let connection: ServerConnection
    @State private var signingIn = false
    @State private var choosing: Device?
    @State private var confirmSignOut = false
    @State private var problem: String?

    var body: some View {
        let net = model.audioNet
        NavigationStack {
            Form {
                if net.login == nil {
                    Section {
                        Button(net.busy ? "Signing in…" : "Sign in to AudioNet") { signingIn = true }
                            .disabled(net.busy)
                    } footer: {
                        Text("Sign in to your AudioNet account to send the sound of one of your devices into this channel, with your microphone still on. TeamTalk NG signs in as a visitor: no device is added to your account.")
                    }
                } else {
                    Section {
                        LabeledContent("Account", value: "\(net.lastUsername) on \(URL(string: net.lastServer)?.host ?? net.lastServer), \(net.connectionText)")
                        Button("Sign out of AudioNet", role: .destructive) { confirmSignOut = true }
                    } header: {
                        Text("Account")
                    } footer: {
                        if !net.status.isEmpty { Text(net.status) }
                    }
                    if let s = net.sending {
                        Section("Sending to this channel") {
                            Text("\(s.sourceName) from \(s.deviceName), \(s.active ? "sending" : "starting")")
                            Button("Stop sending", role: .destructive) { connection.stopAudioNet() }
                        }
                    }
                    Section {
                        @Bindable var model = model
                        NamedSlider("Sending volume", int: $model.audioNetVolume, in: 0...100, spoken: "\(model.audioNetVolume)")
                        NamedSlider("Audio file volume in the mix", int: $model.mixFileVolume, in: 0...100, spoken: "\(model.mixFileVolume)")
                    } footer: {
                        Text("How loud the AudioNet sound and an audio file streamed with it are for everyone in the channel. 50 leaves them as they are.")
                    }
                    Section {
                        let devices = net.listenable
                        if devices.isEmpty {
                            Text(net.connection == .connected
                                 ? "None of your devices is visible. A device appears here while AudioNet runs on it with visibility on."
                                 : "Connecting to AudioNet…")
                        }
                        ForEach(devices, id: \.nodeId) { d in
                            Button {
                                choosing = d
                            } label: {
                                Text("\(d.name), \(d.sources.count == 1 ? "1 sound" : "\(d.sources.count) sounds")")
                            }
                            .disabled(!connection.canStreamMix)
                        }
                    } header: {
                        Text("Devices")
                    } footer: {
                        Text(connection.canStreamMix
                             ? "Choose a device to send its sound into this channel. Stream an audio file while it's sending and the two are mixed."
                             : "You can't stream media files in this channel.")
                    }
                }
            }
            .navigationTitle("AudioNet")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .onAppear { net.screenOpen = true }
            .onDisappear { net.screenOpen = false }
            .sheet(isPresented: $signingIn) { AudioNetSignIn() }
            .confirmationDialog(choosing.map { "Send from \($0.name)" } ?? "", isPresented: Binding(get: { choosing != nil }, set: { if !$0 { choosing = nil } }), titleVisibility: .visible) {
                if let d = choosing {
                    ForEach(d.sources.sorted { $0.isDefault && !$1.isDefault }, id: \.id) { s in
                        Button(s.name) { problem = connection.startAudioNet(device: d, source: s) }
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Its sound goes into this channel as a media file stream, mixed with any audio file you stream. Your microphone stays on.")
            }
            .confirmationDialog("Sign out of AudioNet?", isPresented: $confirmSignOut, titleVisibility: .visible) {
                Button("Sign out", role: .destructive) { connection.stopAudioNet(); net.signOut() }
            } message: {
                if net.sending != nil { Text("Sending to the channel stops.") }
            }
            .alert("AudioNet", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
                Button("OK") {}
            } message: { Text(problem ?? "") }
        }
    }
}

private struct AudioNetSignIn: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var server = ""
    @State private var username = ""
    @State private var password = ""
    @State private var problem: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Server address", text: $server).accessibilityLabel("Server address")
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("Account name", text: $username).accessibilityLabel("Account name")
                        .textContentType(.username).textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("Password", text: $password).accessibilityLabel("Password").textContentType(.password)
                } footer: {
                    Text("Your AudioNet server's address, account name and password.")
                }
                if let problem { Section { Text(problem) } }
            }
            .navigationTitle("Sign in to AudioNet")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Sign in") {
                        Task {
                            if let p = await model.audioNet.signIn(server: server, username: username, password: password) {
                                problem = p
                                announce(p)
                            } else {
                                announce("Signed in to AudioNet.")
                                dismiss()
                            }
                        }
                    }
                    .disabled(model.audioNet.busy || server.isEmpty || username.isEmpty || password.isEmpty)
                }
            }
            .onAppear { server = model.audioNet.lastServer; username = model.audioNet.lastUsername }
        }
    }
}
