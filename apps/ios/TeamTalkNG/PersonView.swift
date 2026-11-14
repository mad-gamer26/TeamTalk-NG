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
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
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
        let mod = connection.canModerate(channel: u.channelId)
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
                }
            }
            Section("Their voice, for me") {
                Toggle("Mute their voice", isOn: Binding(get: { u.voiceMuted }, set: { connection.setMuted(u, $0) }))
                volume("Voice volume", u.voiceVolume) { connection.setVolume(u, percent: $0) }
                Toggle("Left speaker", isOn: Binding(get: { u.voiceLeft }, set: { connection.setStereo(u, .voice, left: $0, right: u.voiceRight) }))
                Toggle("Right speaker", isOn: Binding(get: { u.voiceRight }, set: { connection.setStereo(u, .voice, left: u.voiceLeft, right: $0) }))
            }
            Section("Their media files, for me") {
                Toggle("Mute their media files", isOn: Binding(get: { u.mediaMuted }, set: { connection.setMediaMuted(u, $0) }))
                volume("Media file volume", u.mediaVolume) { connection.setMediaVolume(u, percent: $0) }
                Toggle("Left speaker", isOn: Binding(get: { u.mediaLeft }, set: { connection.setStereo(u, .mediaFile, left: $0, right: u.mediaRight) }))
                Toggle("Right speaker", isOn: Binding(get: { u.mediaRight }, set: { connection.setStereo(u, .mediaFile, left: u.mediaLeft, right: $0) }))
            }
            Section {
                ForEach(Self.normal, id: \.self) { sub in subscription(u, sub) }
            } header: {
                Text("What I receive from them")
            } footer: {
                Text(isMe ? "Your own voice: on means you hear yourself." : "")
            }
            if rights.admin && !isMe {
                Section {
                    ForEach(Self.intercepts, id: \.self) { sub in subscription(u, sub) }
                } header: {
                    Text("Intercept (administrators)")
                } footer: {
                    Text("Their messages and audio, even in other channels or to other people.")
                }
            }
            if !isMe {
                Section {
                    let relaying = s?.relaying
                    Toggle("Relay their voice into my channel", isOn: Binding(
                        get: { relaying?.userId == u.id && relaying?.stream == .voice },
                        set: { connection.setRelay($0 ? u : nil, .voice) }))
                    Toggle("Relay their media files into my channel", isOn: Binding(
                        get: { relaying?.userId == u.id && relaying?.stream == .mediaFile },
                        set: { connection.setRelay($0 ? u : nil, .mediaFile) }))
                } header: {
                    Text("Relay")
                } footer: {
                    Text("What you hear from them goes on to your channel, as if you were saying it. From another channel, intercept their voice first.")
                }
            }
            if u.channelId > 0 {
                Section {
                    if mod {
                        Toggle("Operator of their channel", isOn: Binding(get: { u.operator }, set: { connection.setOperator(u, $0) }))
                    } else if isMe || !u.operator {
                        SecureField("Channel's operator password", text: $opPassword)
                        Button(isMe ? "Become operator" : "Make operator") { connection.setOperator(u, true, password: opPassword) }
                            .disabled(opPassword.isEmpty)
                    }
                } header: {
                    Text("Channel operator")
                }
            }
            if let channel, channel.classroom, mod {
                Section {
                    ForEach(Self.streams, id: \.self) { st in
                        let allowed = channel.transmit.contains { $0.userId == u.id && $0.allowed.contains(st) }
                        Toggle(Self.streamLabel(st), isOn: Binding(
                            get: { allowed },
                            set: { connection.setTransmit(channel: channel.id, user: u.id, st, $0) }))
                    }
                } header: {
                    Text("Classroom: they may send")
                }
            }
            if !isMe && (rights.moveUsers || rights.kick || rights.ban || mod) {
                Section("Moderation") {
                    if rights.moveUsers { Button("Move to a channel") { dismiss(); move(u) } }
                    if (rights.kick || mod) && u.channelId > 0 { Button("Kick from the channel", role: .destructive) { confirm = .kickChannel } }
                    if rights.kick { Button("Kick from the server", role: .destructive) { confirm = .kickServer } }
                    if (rights.ban || mod) && u.channelId > 0 {
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
        Slider(value: Binding(get: { Double(percent) }, set: { set(Int($0)) }), in: 0...400, step: 10) { Text(label) }
            .accessibilityLabel(label)
            .accessibilityValue("\(percent) percent")
    }

    private func subscription(_ u: User, _ sub: Subscription) -> some View {
        Toggle(Self.label(sub), isOn: Binding(
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
