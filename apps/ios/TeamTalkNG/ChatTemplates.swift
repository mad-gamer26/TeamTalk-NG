import Foundation
import Observation
import SwiftUI

/// The desktop's chat message templates (Preferences → Display → Message
/// templates), with its defaults and variables.
enum ChatTemplate: String, CaseIterable, Identifiable, Codable {
    case channelMessage, broadcastMessage, privateMessage, logMessage
    case serverName, motd, joinedChannel, channelTopic, diskQuota

    var id: String { rawValue }

    var label: String {
        switch self {
        case .channelMessage: "Channel message"
        case .broadcastMessage: "Broadcast message"
        case .privateMessage: "Private message"
        case .logMessage: "Event"
        case .serverName: "Server name"
        case .motd: "Message of the day"
        case .joinedChannel: "Joined a channel"
        case .channelTopic: "Channel topic"
        case .diskQuota: "Disk quota"
        }
    }

    /// The desktop's own (qtTeamTalk 5.23).
    var defaultTemplate: String {
        switch self {
        case .channelMessage, .privateMessage: "{date} <{user}>\n{content}"
        case .broadcastMessage: "{date} <{user}->BROADCAST>\n{content}"
        case .logMessage: "{date} * {content}"
        case .serverName: "{date} Server Name: {server}"
        case .motd: "{date} Message of the day: {MOTD}"
        case .joinedChannel: "{date} Joined channel: {channelpath}"
        case .channelTopic: "Topic: {channeltopic}"
        case .diskQuota: "Disk quota: {quota}"
        }
    }

    var variables: [(String, String)] {
        let channel = [("{date}", "Date"), ("{channelpath}", "Channel path"), ("{channelname}", "Channel name"),
                       ("{channeltopic}", "Channel topic"), ("{quota}", "Disk quota")]
        switch self {
        case .channelMessage, .broadcastMessage, .privateMessage:
            return [("{date}", "Message date"), ("{user}", "Sender's nickname"), ("{content}", "Message content")]
        case .logMessage: return [("{date}", "Message date"), ("{content}", "Message content")]
        case .serverName: return [("{date}", "Date"), ("{server}", "Server name")]
        case .motd: return [("{date}", "Date"), ("{MOTD}", "Server's message of the day")]
        case .joinedChannel, .channelTopic, .diskQuota: return channel
        }
    }

    /// An example, to show what a template makes.
    var example: [String: String] {
        ["user": "Alex", "content": "Hello", "server": "My server", "MOTD": "Welcome", "channelpath": "/Lobby/",
         "channelname": "Lobby", "channeltopic": "Chatting", "quota": "10 MB"]
    }
}

/// Whether the chat uses the templates, and the changed ones.
@MainActor @Observable
final class ChatTemplateStore {
    /// Off: the chat as NG shows it (sender, time and message apart).
    var enabled = false { didSet { save() } }
    private(set) var templates: [ChatTemplate: String] = [:]
    private let defaults = UserDefaults.standard

    @ObservationIgnored private var loading = true

    init() {
        enabled = defaults.bool(forKey: "chatTemplatesOn")
        if let t = defaults.dictionary(forKey: "chatTemplates") as? [String: String] {
            for (k, v) in t { if let e = ChatTemplate(rawValue: k) { templates[e] = v } }
        }
        loading = false
    }

    private func save() {
        // Not while loading (see AppModel.save).
        guard !loading else { return }
        defaults.set(enabled, forKey: "chatTemplatesOn")
        defaults.set(Dictionary(uniqueKeysWithValues: templates.map { ($0.key.rawValue, $0.value) }), forKey: "chatTemplates")
    }

    func template(_ t: ChatTemplate) -> String { templates[t] ?? t.defaultTemplate }
    func setTemplate(_ t: ChatTemplate, _ text: String) {
        templates[t] = text == t.defaultTemplate || text.isEmpty ? nil : text
        save()
    }
    func revert() {
        templates = [:]
        enabled = false
    }

    /// The line, as the desktop makes it: variables filled in, {date} the
    /// time (left out with times turned off).
    func format(_ t: ChatTemplate, _ vars: [String: String], date: String) -> String {
        Self.fill(template(t), vars, date: date)
    }

    nonisolated static func fill(_ template: String, _ vars: [String: String], date: String) -> String {
        var s = template.replacingOccurrences(of: "{date}", with: date)
        for (k, v) in vars { s = s.replacingOccurrences(of: "{\(k)}", with: v) }
        return s.trimmingCharacters(in: .whitespaces)
    }
}

/// Settings → Display → Message templates.
struct ChatTemplatesView: View {
    @Environment(AppModel.self) private var model
    @State private var editing: ChatTemplate?

    var body: some View {
        let store = model.chatTemplates
        @Bindable var b = store
        Form {
            Section {
                Toggle("Format the chat as the desktop does", isOn: $b.enabled)
            } footer: {
                Text("Each line made from its template, as in BearWare's TeamTalk; with the server's name and the channel's topic and disk quota when you connect and join.")
            }
            Section {
                ForEach(ChatTemplate.allCases) { t in
                    Button { editing = t } label: {
                        VStack(alignment: .leading) {
                            Text(t.label).foregroundStyle(.primary)
                            Text(store.template(t)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityHint("Changes it")
                }
            } header: {
                Text("Templates")
            }
            Section {
                Button("Every template as it was at first") {
                    for t in ChatTemplate.allCases { store.setTemplate(t, "") }
                }
            }
        }
        .navigationTitle("Message templates")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $editing) { t in ChatTemplateEditor(template: t) }
    }
}

private struct ChatTemplateEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let template: ChatTemplate
    @State private var text = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Template", text: $text, axis: .vertical).accessibilityLabel("Template")
                } footer: {
                    Text("Empty goes back to the first template.")
                }
                Section("Looks like") {
                    Text(ChatTemplateStore.fill(text.isEmpty ? template.defaultTemplate : text, template.example,
                                                date: Date.now.formatted(.dateTime.hour().minute())))
                }
                Section("Variables (double-tap to add)") {
                    ForEach(template.variables, id: \.0) { v in
                        Button { text += v.0 } label: { LabeledContent(v.0, value: v.1) }
                            .foregroundStyle(.primary)
                    }
                }
                Section {
                    Button("Back to the first template") { text = template.defaultTemplate }
                }
            }
            .navigationTitle(template.label)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { model.chatTemplates.setTemplate(template, text); dismiss() }
                }
            }
            .onAppear { text = model.chatTemplates.template(template) }
        }
    }
}
