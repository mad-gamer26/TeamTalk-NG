import SwiftUI

/// Everything about one person, and everything the desktop's Users menu
/// does with them: information, how I hear them, what I receive from them,
/// relaying, operator, classroom permissions, moving, kicking, banning.
struct PersonView: View {
    @Environment(\.dismiss) private var dismiss
    let connection: ServerConnection
    let userId: Int32
    let message: (User) -> Void
    let move: (User) -> Void

    @State private var stats: UserStatistics?
    @State private var watching: VideoKind?
    @State private var confirm: Moderation?
    @State private var opPassword = ""

    enum Moderation: Identifiable {
        case kickChannel, kickServer, banChannel(BanKind), banServer(BanKind)
        var id: String { "\(self)" }
        var title: String {
            switch self {
            case .kickChannel: "Kick from the channel"
            case .kickServer: "Kick from the server"
            case .banChannel(let k): k == .username ? "Ban from the channel by account" : "Ban from the channel by IP address"
            case .banServer(let k): k == .username ? "Ban from the server by account" : "Ban from the server by IP address"
            }
        }
    }

    private var user: User? { connection.snapshot?.users.first { $0.id == userId } }

    /// The desktop's "Copy User Information to Clipboard" (userinfodlg.cpp),
    /// line by line in its words.
    private func copyInfo(_ u: User) async {
        let st = await connection.statistics(u)
        var lines = ["User ID: \(u.id)", "Nickname: \(u.nickname)", "Username: \(u.username)",
                     "Client: \(u.clientName) \(u.version)"]
        lines.append("Status mode: " + (u.status == .away ? "Away" : u.status == .question ? "Question" : "Available"))
        if !u.statusMessage.isEmpty { lines.append("Status message: \(u.statusMessage)") }
        lines.append("User type: " + (u.admin ? "Administrator" : "Default"))
        if !u.ipAddress.isEmpty { lines.append("IP address: \(u.ipAddress)") }
        if let st {
            lines.append("Voice packet loss: \(st.voicePacketsLost)/\(st.voicePacketsReceived + st.voicePacketsLost)")
            lines.append("Video frame loss: \(st.videoFramesLost)/\(st.videoFramesReceived + st.videoFramesLost)")
            lines.append("Audio file packets loss: \(st.mediaAudioPacketsLost)/\(st.mediaAudioPacketsReceived + st.mediaAudioPacketsLost)")
        }
        UIPasteboard.general.string = lines.joined(separator: "\n")
        announce("Copied")
    }
    private var isMe: Bool { userId == connection.snapshot?.myUserId }

    var body: some View {
        NavigationStack {
            Group {
                if let user {
                    form(user)
                } else {
                    Text("They're no longer on the server.").foregroundStyle(.secondary)
                }
            }
            .navigationTitle(user.map { isMe ? "\($0.displayName) (you)" : $0.displayName } ?? "Gone")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                if let user {
                    ToolbarItem(placement: .bottomBar) {
                        Button("Copy User Information to Clipboard") { Task { await copyInfo(user) } }
                    }
                }
            }
            .sheet(item: $watching) { k in
                if let u = user { VideoView(connection: connection, user: u, kind: k) }
            }
            .confirmationDialog(confirm?.title ?? "", isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }),
                                titleVisibility: .visible) {
                Button(confirm?.title ?? "", role: .destructive) { if let c = confirm, let u = user { moderate(c, u) } }
            }
        }
    }

    @ViewBuilder
    private func form(_ u: User) -> some View {
        let s = connection.snapshot
        let channel = s?.channels.first { $0.id == u.channelId }
        let rights = connection.rights
        Form {
            Section("Information") {
                row("Nickname", u.nickname.isEmpty ? "None" : u.nickname)
                row("Username", u.username.isEmpty ? "None" : u.username)
                row("Status", statusText(u))
                row("Gender", "\(u.gender)".capitalized)
                row("Channel", channel.map { connection.channelPathText($0) } ?? "Not in a channel")
                row("Account", u.admin ? "Administrator" : "Default user")
                if u.operator { row("Operator", "Of their channel") }
                row("Client", u.clientName.isEmpty ? "Unknown, version \(u.version)" : "\(u.clientName), version \(u.version)")
                if !u.ipAddress.isEmpty { row("IP address", u.ipAddress) }
                row("Doing", doing(u))
                if let stats {
                    row("Voice packets", "\(stats.voicePacketsReceived) received, \(stats.voicePacketsLost) lost")
                    row("Media file packets", "\(stats.mediaAudioPacketsReceived) received, \(stats.mediaAudioPacketsLost) lost")
                }
                Button(stats == nil ? "Show connection statistics" : "Update connection statistics") {
                    Task { stats = await connection.statistics(u) }
                }
            }
            if !isMe {
                Section {
                    Button("Message privately") { dismiss(); message(u) }
                    if u.sendingVideo { Button("Watch their camera") { watching = .camera } }
                    if u.streamingMedia { Button("Watch the video they're streaming") { watching = .mediaFile } }
                    if u.sharingDesktop { Button("See their shared desktop") { watching = .desktop } }
                }
            }
            if connection.hasAudio {
            Section("Their voice, for me") {
                LiveToggle("Mute Voice", isOn: Binding(get: { u.voiceMuted }, set: { connection.setMuted(u, $0) }))
                volume("Voice volume", u.voiceVolume) { connection.setVolume(u, percent: $0) }
                LiveToggle("Left speaker", isOn: Binding(get: { u.voiceLeft }, set: { connection.setStereo(u, .voice, left: $0, right: u.voiceRight) }))
                LiveToggle("Right speaker", isOn: Binding(get: { u.voiceRight }, set: { connection.setStereo(u, .voice, left: u.voiceLeft, right: $0) }))
            }
            Section("Their media files, for me") {
                LiveToggle("Mute Media File", isOn: Binding(get: { u.mediaMuted }, set: { connection.setMediaMuted(u, $0) }))
                volume("Media file volume", u.mediaVolume) { connection.setMediaVolume(u, percent: $0) }
                LiveToggle("Left speaker", isOn: Binding(get: { u.mediaLeft }, set: { connection.setStereo(u, .mediaFile, left: $0, right: u.mediaRight) }))
                LiveToggle("Right speaker", isOn: Binding(get: { u.mediaRight }, set: { connection.setStereo(u, .mediaFile, left: u.mediaLeft, right: $0) }))
            }
            }
            Section {
                ForEach(Self.normal.filter(connection.shows), id: \.self) { sub in subscription(u, sub) }
            } header: {
                Text("What I receive from them")
            } footer: {
                Text(isMe && connection.hasAudio ? "Your own voice: on means you hear yourself." : "")
            }
            // The desktop offers the intercepts to everyone (only admins'
            // are honoured by the server).
            if !isMe {
                Section {
                    ForEach(Self.intercepts.filter(connection.shows), id: \.self) { sub in subscription(u, sub) }
                } header: {
                    Text("Intercept (administrators)")
                } footer: {
                    Text(connection.hasAudio ? "Their messages and audio, even in other channels or to other people." : "Their messages, even in other channels or to other people.")
                }
            }
            // The desktop: not while voice activation is on or I'm talking.
            if !isMe && connection.hasAudio && connection.appModel?.talkMode != .voiceActivation && !connection.transmitting {
                Section {
                    let relaying = s?.relaying
                    LiveToggle("Relay their voice into my channel", isOn: Binding(
                        get: { relaying?.userId == u.id && relaying?.stream == .voice },
                        set: { connection.setRelay($0 ? u : nil, .voice) }))
                    LiveToggle("Relay their media files into my channel", isOn: Binding(
                        get: { relaying?.userId == u.id && relaying?.stream == .mediaFile },
                        set: { connection.setRelay($0 ? u : nil, .mediaFile) }))
                } header: {
                    Text("Relay to my channel")
                } footer: {
                    Text("What you hear from them goes on to your channel, as if you were saying it. From another channel, intercept their voice first.")
                }
            }
            if u.channelId > 0 {
                Section {
                    // The desktop: directly with the right to make operators;
                    // otherwise with the channel's operator password.
                    if rights.operatorEnable {
                        LiveToggle("Operator of their channel", isOn: Binding(get: { u.operator }, set: { connection.setOperator(u, $0) }))
                    } else {
                        PasswordField("Channel's operator password", text: $opPassword)
                        Button(u.operator ? "Remove Channel Operator" : (isMe ? "Become operator" : "Make operator")) {
                            connection.setOperator(u, !u.operator, password: opPassword)
                        }
                        .disabled(opPassword.isEmpty)
                    }
                } header: {
                    Text("Channel operator")
                }
            }
            if let channel, connection.canControlTransmit(channel: channel.id) {
                Section {
                    ForEach(Self.streams.filter(connection.shows), id: \.self) { st in
                        let allowed = connection.transmitAllowed(channel, user: u.id, st)
                        LiveToggle(Self.streamLabel(st), isOn: Binding(
                            get: { allowed },
                            set: { connection.setTransmit(channel: channel.id, user: u.id, st, $0) }))
                    }
                } header: {
                    Text("They may send (Transmit Control)")
                }
            }
            // The desktop: kicking and banning from a channel offered for
            // anyone (the server refuses non-operators); from the server and
            // moving need their rights.
            if isMe && rights.moveUsers {
                Section("Moderation") {
                    Button(connection.pickedToMove.contains(u.id) ? "Unmark User for Moving" : "Mark User for Moving") { connection.togglePicked(u) }
                }
            }
            if !isMe {
                Section("Moderation") {
                    if rights.moveUsers {
                        Button("Move to a channel") { dismiss(); move(u) }
                        Button(connection.pickedToMove.contains(u.id) ? "Unmark User for Moving" : "Mark User for Moving") { connection.togglePicked(u) }
                    }
                    if u.channelId > 0 { Button("Kick from the channel", role: .destructive) { confirm = .kickChannel } }
                    if rights.kick { Button("Kick from the server", role: .destructive) { confirm = .kickServer } }
                    if u.channelId > 0 {
                        Button("Ban from the channel by account", role: .destructive) { confirm = .banChannel(.username) }
                        Button("Ban from the channel by IP address", role: .destructive) { confirm = .banChannel(.ipAddress) }
                    }
                    if rights.ban {
                        Button("Ban from the server by account", role: .destructive) { confirm = .banServer(.username) }
                        Button("Ban from the server by IP address", role: .destructive) { confirm = .banServer(.ipAddress) }
                    }
                }
            }
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        LabeledContent(label, value: value)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(label)
            .accessibilityValue(value)
    }

    private func volume(_ label: String, _ percent: Int32, set: @escaping (Int) -> Void) -> some View {
        // The desktop's scale: 0–100, 50 as sent, in steps of 1.
        NamedSlider(label, int: Binding(get: { Int(percent) }, set: { set($0) }), in: 0...100, spoken: { "\($0) percent" })
    }

    private func subscription(_ u: User, _ sub: Subscription) -> some View {
        LiveToggle(Self.label(sub), isOn: Binding(
            get: { u.mySubscriptions.on.contains(sub) },
            set: { connection.setSubscription(u, sub, $0) }))
    }

    private func statusText(_ u: User) -> String {
        let mode = switch u.status {
        case .available: "Available"
        case .away: "Away"
        case .question: "Question"
        }
        return u.statusMessage.isEmpty ? mode : "\(mode): \(u.statusMessage)"
    }

    private func doing(_ u: User) -> String {
        var d: [String] = []
        if u.talking { d.append("talking") }
        if u.streamingMedia { d.append("streaming a media file") }
        if u.sendingVideo { d.append("sending video") }
        if u.sharingDesktop { d.append("sharing a desktop") }
        return d.isEmpty ? "Nothing right now" : d.joined(separator: ", ").capitalizedFirst
    }

    private func moderate(_ m: Moderation, _ u: User) {
        switch m {
        case .kickChannel: connection.kick(u, fromChannel: true)
        case .kickServer: connection.kick(u, fromChannel: false)
        case .banChannel(let k): connection.banFromChannel(u, by: k)
        case .banServer(let k): connection.ban(u, by: k)
        }
        confirm = nil
        dismiss()
    }

    static let normal: [Subscription] = [.userMessages, .channelMessages, .broadcastMessages, .voice, .video, .desktop, .desktopAccess, .mediaFile]
    static let intercepts: [Subscription] = [.interceptUserMessages, .interceptChannelMessages, .interceptVoice, .interceptVideo, .interceptDesktop, .interceptMediaFile]
    static let streams: [TransmitStream] = [.voice, .channelMessages, .mediaFile, .video, .desktop]

    static func label(_ s: Subscription) -> String {
        switch s {
        case .userMessages: "Private messages"
        case .channelMessages: "Channel messages"
        case .broadcastMessages: "Broadcast messages"
        case .voice: "Voice"
        case .video: "Video"
        case .desktop: "Shared desktop"
        case .desktopAccess: "Desktop access"
        case .mediaFile: "Media files"
        case .interceptUserMessages: "Their private messages"
        case .interceptChannelMessages: "Their channel messages"
        case .interceptVoice: "Their voice"
        case .interceptVideo: "Their video"
        case .interceptDesktop: "Their shared desktop"
        case .interceptMediaFile: "Their media files"
        }
    }

    static func streamLabel(_ s: TransmitStream) -> String {
        switch s {
        case .voice: "Talk"
        case .channelMessages: "Write in the channel"
        case .mediaFile: "Stream media files"
        case .video: "Send video"
        case .desktop: "Share a desktop"
        }
    }
}

extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

extension VideoKind: Identifiable {
    public var id: Self { self }
}
