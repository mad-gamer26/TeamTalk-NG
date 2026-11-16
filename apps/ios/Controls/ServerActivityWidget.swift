import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

/// A connected server's Live Activity: the Lock Screen and the Dynamic
/// Island, showing what the owner chose (Settings → Live Activities), with
/// their buttons in their order. Everything reads well with VoiceOver: each
/// line is one element, icons are only decoration.
struct ServerActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: ServerActivityAttributes.self) { context in
            LockScreenActivity(id: context.attributes.serverId, s: context.state)
                .padding()
                .activityBackgroundTint(Color.black.opacity(0.85))
                .activitySystemActionForegroundColor(.white)
                .widgetURL(URL(string: "teamtalkng://server/\(context.attributes.serverId)"))
        } dynamicIsland: { context in
            let s = context.state, id = context.attributes.serverId
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) { Glance(item: s.layout.compactLeading, s: s, wide: true) }
                DynamicIslandExpandedRegion(.trailing) { Glance(item: s.layout.compactTrailing, s: s, wide: true) }
                DynamicIslandExpandedRegion(.center) {
                    Text(Describe.title(s)).font(.headline).lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    // The island has a fixed height: small text and buttons.
                    VStack(alignment: .leading, spacing: 2) {
                        Details(s: s, skipTitle: true, compact: true)
                        ActivityButtons(id: id, s: s).controlSize(.small)
                    }
                }
            } compactLeading: {
                Glance(item: s.layout.compactLeading, s: s, wide: false)
            } compactTrailing: {
                Glance(item: s.layout.compactTrailing, s: s, wide: false)
            } minimal: {
                Glance(item: s.layout.minimal, s: s, wide: false)
            }
            .widgetURL(URL(string: "teamtalkng://server/\(id)"))
        }
    }
}

/// Words for each part (what's shown and what VoiceOver says).
enum Describe {
    static func title(_ s: ServerActivityAttributes.ContentState) -> String {
        s.layout.shows(.server) ? s.serverName : (s.layout.shows(.channel) && !s.channel.isEmpty ? s.channel : "TeamTalk NG")
    }
    static func microphone(_ s: ServerActivityAttributes.ContentState) -> String {
        if s.voiceActivation { return s.microphoneOn ? "Microphone on" : "Microphone muted" }
        return s.microphoneOn ? "Talking" : "Not talking"
    }
    static func talking(_ s: ServerActivityAttributes.ContentState) -> String {
        if s.talking.isEmpty { return "Nobody talking" }
        if s.layout.talkingStyle == .count { return s.talking.count == 1 ? "1 person talking" : "\(s.talking.count) people talking" }
        return "Talking: " + s.talking.joined(separator: ", ")
    }
    static func people(_ n: Int) -> String { n == 1 ? "1 person" : "\(n) people" }
    static func message(_ m: LiveMessage, _ s: ServerActivityAttributes.ContentState, privately: Bool) -> String {
        let who = privately ? "Private message from \(m.from)" : "\(m.from)"
        return s.layout.messageText == .full ? "\(who): \(m.text)" : (privately ? who : "Message from \(m.from)")
    }
    static func unread(_ n: Int) -> String { n == 1 ? "1 unread private message" : "\(n) unread private messages" }
}

private struct LockScreenActivity: View {
    let id: String
    let s: ServerActivityAttributes.ContentState
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Details(s: s, skipTitle: false, compact: false)
            ActivityButtons(id: id, s: s)
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The chosen lines, in a fixed order.
private struct Details: View {
    let s: ServerActivityAttributes.ContentState
    let skipTitle: Bool
    let compact: Bool
    var body: some View {
        let l = s.layout
        VStack(alignment: .leading, spacing: compact ? 0 : 3) {
            if l.shows(.server) && !skipTitle { Text(s.serverName).font(.headline).lineLimit(1) }
            if l.shows(.connection) && s.connection != "Connected" { line(s.connection, "exclamationmark.triangle") }
            if l.shows(.channel) {
                let where_ = s.channel.isEmpty ? "Not in a channel" : "Channel: \(s.channel)"
                line(l.shows(.people) && !s.channel.isEmpty ? "\(where_), \(Describe.people(s.peopleInChannel))" : where_, "number")
            } else if l.shows(.people) {
                line(Describe.people(s.peopleInChannel), "person.2")
            }
            if l.shows(.talking) { line(Describe.talking(s), "waveform") }
            let states = [
                l.shows(.microphone) ? Describe.microphone(s) : nil,
                l.shows(.talkMode) ? (s.voiceActivation ? "Voice activation" : "Push to talk") : nil,
                l.shows(.muteEveryone) && s.mutedEveryone ? "Everyone muted for me" : nil,
                l.shows(.status) ? "Status: \(s.status)" : nil,
            ].compactMap { $0 }
            if !states.isEmpty { line(states.joined(separator: ", "), s.microphoneOn ? "mic.fill" : "mic.slash") }
            if l.shows(.lastMessage), let m = s.lastMessage { line(Describe.message(m, s, privately: false), "text.bubble") }
            if l.shows(.lastPrivate), let m = s.lastPrivate { line(Describe.message(m, s, privately: true), "envelope") }
            if l.shows(.unread) && s.unreadPrivate > 0 { line(Describe.unread(s.unreadPrivate), "envelope.badge") }
        }
        .font(compact ? .caption : .subheadline)
    }

    private func line(_ text: String, _ icon: String) -> some View {
        Label { Text(text).lineLimit(2) } icon: { Image(systemName: icon).accessibilityHidden(true) }
            .accessibilityElement(children: .combine)
    }
}

/// The owner's buttons, in their order (at most four).
private struct ActivityButtons: View {
    let id: String
    let s: ServerActivityAttributes.ContentState
    var body: some View {
        let buttons = Array(s.layout.buttons.prefix(LiveLayout.maxButtons))
        if !buttons.isEmpty {
            HStack(spacing: 8) {
                ForEach(buttons) { b in
                    if s.layout.buttonStyle == .icons {
                        button(b).labelStyle(.iconOnly).frame(maxWidth: .infinity)
                    } else {
                        button(b).labelStyle(.titleAndIcon).lineLimit(2).font(.caption).frame(maxWidth: .infinity)
                    }
                }
            }
            .buttonStyle(.bordered)
            .tint(.white)
        }
    }

    @ViewBuilder private func button(_ b: LiveButton) -> some View {
        switch b {
        case .microphone:
            let label = s.voiceActivation ? (s.microphoneOn ? "Mute microphone" : "Unmute microphone")
                : (s.microphoneOn ? "Stop talking" : "Start talking")
            Button(intent: MicrophoneIntent(action: .toggle, serverId: id)) {
                Label(label, systemImage: s.microphoneOn ? "mic.slash" : "mic.fill")
            }
            .accessibilityLabel(label)
        case .muteEveryone:
            let label = s.mutedEveryone ? "Unmute Everyone for Me" : "Mute Everyone for Me"
            Button(intent: MuteEveryoneIntent(action: .toggle, serverId: id)) {
                Label(label, systemImage: s.mutedEveryone ? "speaker.wave.2" : "speaker.slash")
            }
            .accessibilityLabel(label)
        case .talkMode:
            let label = s.voiceActivation ? "Use push to talk" : "Use voice activation"
            Button(intent: TalkModeIntent(mode: .switchMode)) {
                Label(label, systemImage: "waveform")
            }
            .accessibilityLabel(label)
        case .disconnect:
            Button(intent: DisconnectIntent(serverId: id)) {
                Label("Disconnect", systemImage: "xmark")
            }
            .accessibilityLabel("Disconnect")
        }
    }
}

/// One thing in a small space; `wide`: the expanded island's corners.
private struct Glance: View {
    let item: LiveGlance
    let s: ServerActivityAttributes.ContentState
    let wide: Bool
    var body: some View {
        switch item {
        case .microphone:
            Image(systemName: s.microphoneOn ? "mic.fill" : "mic.slash")
                .foregroundStyle(s.microphoneOn ? .green : .secondary)
                .accessibilityLabel(Describe.microphone(s))
        case .talking:
            let short = s.talking.isEmpty ? "" : (s.layout.talkingStyle == .count || s.talking.count > 1 ? "\(s.talking.count)" : s.talking[0])
            Label { Text(short).lineLimit(1) } icon: { Image(systemName: "waveform").accessibilityHidden(true) }
                .labelStyle(.titleAndIcon)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Describe.talking(s))
        case .people:
            Label { Text("\(s.peopleInChannel)") } icon: { Image(systemName: "person.2") }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Describe.people(s.peopleInChannel))
        case .channel:
            Text(s.channel.isEmpty ? "-" : s.channel).lineLimit(1).frame(maxWidth: wide ? 120 : 60)
                .accessibilityLabel(s.channel.isEmpty ? "Not in a channel" : "Channel: \(s.channel)")
        case .server:
            Text(s.serverName).lineLimit(1).frame(maxWidth: wide ? 120 : 60)
                .accessibilityLabel(s.serverName)
        case .unread:
            Label { Text("\(s.unreadPrivate)") } icon: { Image(systemName: "envelope") }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Describe.unread(s.unreadPrivate))
        case .nothing:
            EmptyView()
        }
    }
}
