import AudioNetKit
import SwiftUI

/// More → AudioNet: what's streaming (each with its volume, while it
/// streams), the accounts and their devices, and adding an account.
struct AudioNetView: View {
    let connection: ServerConnection
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var addingAccount = false
    @State private var signingOut: AudioNetAccount?
    @State private var problem: String?

    var body: some View {
        let net = model.audioNet
        NavigationStack {
            Form {
                if !net.streams.isEmpty {
                    Section("Streaming") {
                        ForEach(net.streams) { s in StreamRow(stream: s) }
                    }
                }
                if net.accounts.isEmpty {
                    Section {
                        Text("Sign in to an AudioNet account to send a device's sound into this channel (as a TeamTalk login of its own), or the channel's sound or your microphone to a device. TeamTalk NG signs in as a visitor: no device is added to your account.")
                            .foregroundStyle(.secondary)
                    }
                }
                ForEach(net.accounts) { a in
                    Section {
                        if a.devices.isEmpty {
                            Text(a.state == .connected ? "No devices are visible in this account." : a.stateText)
                                .foregroundStyle(.secondary)
                        }
                        ForEach(a.devices, id: \.nodeId) { d in
                            NavigationLink {
                                AudioNetDeviceView(device: d, account: a, connection: connection)
                            } label: {
                                Text(d.name)
                            }
                        }
                        Button("Sign out of \(a.name)", role: .destructive) { signingOut = a }
                    } header: {
                        Text(a.name)
                    } footer: {
                        Text(a.stateText)
                    }
                }
                Section {
                    Button("Add an AudioNet account") { addingAccount = true }
                }
                Section {
                    TextField("Name of a stream's login", text: Binding(get: { net.loginName }, set: { net.loginName = $0 }))
                        .accessibilityLabel("Name of a stream's login")
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                } header: {
                    Text("Into channels")
                } footer: {
                    Text("Each device's sound you send into a channel logs in to the server separately, under this name, and follows you from channel to channel. %nickname% is your name, %source% the sound's, %device% the device's. Your account on the server must allow more than one login.")
                }
            }
            .navigationTitle("AudioNet")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .sheet(isPresented: $addingAccount) { AudioNetSignIn() }
            .confirmationDialog("Sign out of \(signingOut?.name ?? "")?", isPresented: Binding(get: { signingOut != nil }, set: { if !$0 { signingOut = nil } }), titleVisibility: .visible) {
                Button("Sign out", role: .destructive) { if let a = signingOut { net.signOut(a) } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Its streams stop.")
            }
        }
        // The whole sheet, devices' screens included (they'd count as
        // leaving if this were on its first page).
        .onAppear { net.screenOpen = true }
        .onDisappear { net.screenOpen = false }
    }
}

/// A stream: what it is, its volume and mute (only while it streams), Stop.
private struct StreamRow: View {
    let stream: AudioNetStream
    @Environment(AppModel.self) private var model

    var body: some View {
        let net = model.audioNet
        VStack(alignment: .leading, spacing: 6) {
            Text(stream.title).accessibilityValue(stream.state)
            NamedSlider("Volume of \(stream.title)", value: Binding(
                get: { stream.volume },
                set: { net.setVolume(stream, $0, muted: stream.muted) }), in: 0...1, step: 0.05,
                spoken: { "\(Int(($0 * 100).rounded())) percent" })
            HStack {
                Button(stream.muted ? "Unmute" : "Mute") { net.setVolume(stream, stream.volume, muted: !stream.muted) }
                    .accessibilityLabel(stream.muted ? "Unmute \(stream.title)" : "Mute \(stream.title)")
                Spacer()
                Button("Stop", role: .destructive) { net.stop(stream, said: "\(stream.title) stopped.") }
                    .accessibilityLabel("Stop \(stream.title)")
            }
            .buttonStyle(.borderless)
        }
    }
}

/// One device: its sounds to send into the channel, and its outputs to
/// send the channel's sound or my microphone to.
struct AudioNetDeviceView: View {
    let device: Device
    let account: AudioNetAccount
    let connection: ServerConnection
    @Environment(AppModel.self) private var model
    @State private var busy = false
    @State private var problem: String?

    var body: some View {
        let net = model.audioNet
        // The device as it is now (its sources and outputs change).
        let d = account.devices.first { $0.nodeId == device.nodeId } ?? device
        Form {
            Section {
                if d.sources.isEmpty { Text("This device shares no sound.").foregroundStyle(.secondary) }
                ForEach(d.sources, id: \.id) { s in
                    Button("Send \(s.name) into this channel") {
                        run { await net.sendIntoChannel(d, s, account: account, on: connection) }
                    }
                }
            } header: {
                Text("Into this channel")
            } footer: {
                Text("Each as a TeamTalk login of its own, so your talking and file streaming stay as they are.")
            }
            Section("To this device") {
                if d.outputs.isEmpty { Text("This device has no outputs.").foregroundStyle(.secondary) }
                ForEach(d.outputs, id: \.id) { o in
                    Button("Send the channel's sound to \(o.name)") {
                        run { await net.sendToDevice(.channel, d, o, account: account, from: connection) }
                    }
                    Button("Send my microphone to \(o.name)") {
                        run { await net.sendToDevice(.microphone, d, o, account: account, from: connection) }
                    }
                }
            }
            Section {
                NavigationLink("Sound settings") {
                    AudioNetSoundSettingsView(nodeId: d.nodeId, account: account)
                }
                .accessibilityLabel("Sound settings of \(d.name)")
            }
        }
        .disabled(busy)
        .navigationTitle(d.name)
        .alert("AudioNet", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
            Button("OK") {}
        } message: { Text(problem ?? "") }
    }

    private func run(_ start: @escaping () async -> String?) {
        busy = true
        Task {
            let p = await start()
            busy = false
            if let p { problem = p } else { announce("Streaming") }
        }
    }
}

/// Another device's sound settings: its outputs and microphones (volume,
/// mute, default, default for communications, disable), a phone's own
/// volumes, and disabled devices to enable. Drawn from the account's live
/// device list, so changes made anywhere show at once.
struct AudioNetSoundSettingsView: View {
    let nodeId: String
    let account: AudioNetAccount
    @Environment(AppModel.self) private var model

    var body: some View {
        let d = account.devices.first { $0.nodeId == nodeId }
        Form {
            if let d {
                if !d.allowsControl {
                    Text("\(d.name) doesn't let other devices change its sound settings.")
                } else {
                    content(d)
                }
            } else {
                Text("This device is no longer visible.")
            }
        }
        .navigationTitle("Sound settings of \(d?.name ?? "the device")")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder private func content(_ d: Device) -> some View {
        let outputs = d.outputs.filter { $0.control != nil }
        let microphones = d.sources.filter { $0.isInput && $0.control != nil }
        if outputs.isEmpty && microphones.isEmpty && d.volumes.isEmpty && d.disabled.isEmpty {
            Text(d.platform == "ios"
                 ? "An iPhone's sound settings can't be changed from other devices."
                 : "\(d.name) doesn't report its sound settings. It may need a newer AudioNet.")
        }
        if !outputs.isEmpty {
            Section("Outputs") {
                ForEach(outputs, id: \.id) { o in
                    endpoint(d, name: o.name, target: o.id, isDefault: o.isDefault, control: o.control!)
                }
            }
        }
        if !microphones.isEmpty {
            Section("Microphones") {
                ForEach(microphones, id: \.id) { m in
                    endpoint(d, name: m.name, target: m.id, isDefault: m.isDefault, control: m.control!)
                }
            }
        }
        if !d.volumes.isEmpty {
            Section("Volumes") {
                ForEach(d.volumes, id: \.id) { v in
                    volume(d, name: v.name, target: v.id, value: v.volume)
                    if v.canMute, let muted = v.muted {
                        LiveToggle("Mute \(v.name.lowercased())", isOn: Binding(
                            get: { muted }, set: { change(d, .mute(target: v.id, muted: $0)) }))
                    }
                }
            }
        }
        if !d.disabled.isEmpty {
            Section("Disabled") {
                ForEach(d.disabled, id: \.id) { x in
                    Button("Enable \(x.name) (\(x.isInput ? "microphone" : "output"))") {
                        change(d, .enabled(target: x.id, enabled: true))
                    }
                }
            }
        }
    }

    @ViewBuilder private func endpoint(_ d: Device, name: String, target: String, isDefault: Bool,
                                       control c: SoundControl) -> some View {
        let roles = [isDefault ? "default" : nil, c.isDefaultCommunications ? "default for communications" : nil]
            .compactMap { $0 }
        Text(roles.isEmpty ? name : "\(name) (\(roles.joined(separator: ", ")))").font(.headline)
        if c.canSetVolume, let v = c.volume {
            volume(d, name: name, target: target, value: v)
        } else if let v = c.volume {
            LabeledContent("Volume of \(name)", value: "\(Int((v * 100).rounded())) percent")
        }
        if c.canMute, let muted = c.muted {
            LiveToggle("Mute \(name)", isOn: Binding(get: { muted }, set: { change(d, .mute(target: target, muted: $0)) }))
        }
        if c.canSetDefault && !isDefault {
            Button("Make \(name) the default") { change(d, .default(target: target, communications: false)) }
        }
        if c.canSetDefaultCommunications && !c.isDefaultCommunications {
            Button("Make \(name) the default for communications") {
                change(d, .default(target: target, communications: true))
            }
        }
        if c.canEnable {
            Button("Disable \(name)") { change(d, .enabled(target: target, enabled: false)) }
        }
    }

    private func volume(_ d: Device, name: String, target: String, value: Float) -> some View {
        NamedSlider("Volume of \(name)", value: Binding(
            get: { Double(value) },
            set: { change(d, .volume(target: target, volume: Float($0))) }), in: 0...1, step: 0.05,
            spoken: { "\(Int(($0 * 100).rounded())) percent" })
    }

    private func change(_ d: Device, _ c: SoundChange) {
        model.audioNet.changeSound(account, d, c)
    }
}

/// Adding an account: its server, name and password (the password isn't
/// kept: a visitor token is).
private struct AudioNetSignIn: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var server = UserDefaults.standard.string(forKey: "audioNetServer") ?? ""
    @State private var username = ""
    @State private var password = ""
    @State private var busy = false
    @State private var problem: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Server address", text: $server).accessibilityLabel("Server address")
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("Account name", text: $username).accessibilityLabel("Account name")
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("Password", text: $password).accessibilityLabel("Password")
                } footer: {
                    Text("Your AudioNet server's address, account name and password.")
                }
                if let problem { Section { Text(problem) } }
            }
            .navigationTitle("Add an AudioNet account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Sign in") {
                        busy = true
                        Task {
                            problem = await model.audioNet.signIn(server: server, username: username, password: password)
                            busy = false
                            if problem == nil { dismiss() } else { announce(problem!) }
                        }
                    }
                    .disabled(busy || server.isEmpty || username.isEmpty || password.isEmpty)
                }
            }
        }
    }
}
