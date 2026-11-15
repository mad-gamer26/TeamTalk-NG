import Foundation
import Observation
import SwiftUI

/// The desktop's status-bar events (qtTeamTalk's STATUSBAR_*), each on or
/// off, in its order, with its names and messages. The desktop shows them
/// in its status bar and, by default, in the chat; here the server screen
/// has a status line and they go in the chat (Settings → Display).
enum StatusEvent: String, CaseIterable, Identifiable {
    case loggedIn, loggedOut
    case joined, left, joinedMine, leftMine
    case subUserMessages, subChannelMessages, subBroadcastMessages, subVoice, subVideo
    case subDesktop, subDesktopInput, subMediaFile
    case subInterceptUserMessages, subInterceptChannelMessages, subInterceptVoice
    case subInterceptVideo, subInterceptDesktop, subInterceptMediaFile
    case classroomChat, classroomVoice, classroomVideo, classroomDesktop, classroomMediaFile
    case fileAdded, fileRemoved
    case serverConfigSaved, recordingStarted, transmissionBlocked, soundDevice

    var id: Self { self }

    /// The desktop's names.
    var label: String {
        switch self {
        case .loggedIn: "User logged in"
        case .loggedOut: "User logged out"
        case .joined: "User joined channel"
        case .left: "User left channel"
        case .joinedMine: "User joined current channel"
        case .leftMine: "User left current channel"
        case .subUserMessages: "Subscription private text message changed"
        case .subChannelMessages: "Subscription channel text message changed"
        case .subBroadcastMessages: "Subscription broadcast text message changed"
        case .subVoice: "Subscription voice stream changed"
        case .subVideo: "Subscription webcam stream changed"
        case .subDesktop: "Subscription shared desktop stream changed"
        case .subDesktopInput: "Subscription desktop access changed"
        case .subMediaFile: "Subscription media file stream changed"
        case .subInterceptUserMessages: "Subscription intercept private text message changed"
        case .subInterceptChannelMessages: "Subscription intercept channel text message changed"
        case .subInterceptVoice: "Subscription intercept voice stream changed"
        case .subInterceptVideo: "Subscription intercept webcam stream changed"
        case .subInterceptDesktop: "Subscription intercept desktop stream changed"
        case .subInterceptMediaFile: "Subscription intercept media file stream changed"
        case .classroomChat: "Classroom allow channel messages transmission changed"
        case .classroomVoice: "Classroom allow voice transmission changed"
        case .classroomVideo: "Classroom allow webcam transmission changed"
        case .classroomDesktop: "Classroom allow desktop transmission changed"
        case .classroomMediaFile: "Classroom allow media file transmission changed"
        case .fileAdded: "File added"
        case .fileRemoved: "File removed"
        case .serverConfigSaved: "Server configuration saved"
        case .recordingStarted: "Recording started"
        case .transmissionBlocked: "Transmission blocked by channel operator"
        case .soundDevice: "Sound device detected"
        }
    }

    /// Its message, shared within a group as the desktop's; nil: fixed
    /// words.
    var templateKey: String? {
        switch self {
        case .loggedIn, .loggedOut, .joined, .left, .joinedMine, .leftMine, .fileAdded, .fileRemoved: rawValue
        case .classroomChat, .classroomVoice, .classroomVideo, .classroomDesktop, .classroomMediaFile: "classroom"
        case .serverConfigSaved, .recordingStarted, .transmissionBlocked, .soundDevice: nil
        default: "subscription"
        }
    }

    /// The desktop's (settings.h STATUSBARMSG_*).
    var defaultTemplate: String {
        switch self {
        case .loggedIn: "{user} has logged in"
        case .loggedOut: "{user} has logged out"
        case .joined: "{user} joined channel {channel}"
        case .left: "{user} left channel {channel}"
        case .joinedMine: "{user} joined channel"
        case .leftMine: "{user} left channel"
        case .fileAdded: "File {filename} added by {user}"
        case .fileRemoved: "File {file} removed by {user}"
        default:
            switch templateKey {
            case "subscription": "Subscription \"{type}\" {state} for {user}"
            case "classroom": "Transmission \"{type}\" {state} for {user}"
            default: "{message}"
            }
        }
    }

    var variables: [(String, String)] {
        let user = [("{user}", "User's nickname"), ("{username}", "User's username")]
        switch self {
        case .loggedIn, .loggedOut: return user + [("{server}", "Server's name")]
        case .joined, .left: return user + [("{channel}", "Channel's name")]
        case .joinedMine, .leftMine: return user
        case .fileAdded: return [("{filename}", "File name")] + user + [("{filesize}", "File size")]
        case .fileRemoved: return [("{file}", "File name")] + user
        default:
            switch templateKey {
            case "subscription": return user + [("{type}", "Subscription type"), ("{state}", "Subscription state")]
            case "classroom": return [("{type}", "Transmission type"), ("{state}", "Transmission state"), ("{user}", "User concerns by change")]
            default: return []
            }
        }
    }

    init(_ s: SpeechEvent) {
        self = StatusEvent(rawValue: s.rawValue) ?? .loggedIn
    }
}

/// Which status-bar events show, and changed messages (all on by default,
/// as the desktop's STATUSBAR_ACTIVEEVENTS).
@MainActor @Observable
final class StatusEventStore {
    private(set) var disabled: Set<StatusEvent> = []
    private(set) var templates: [String: String] = [:]
    private let defaults = UserDefaults.standard

    init() {
        disabled = Set((defaults.stringArray(forKey: "statusEventsOff") ?? []).compactMap(StatusEvent.init(rawValue:)))
        templates = defaults.dictionary(forKey: "statusTemplates") as? [String: String] ?? [:]
    }

    private func save() {
        defaults.set(disabled.map(\.rawValue), forKey: "statusEventsOff")
        defaults.set(templates, forKey: "statusTemplates")
    }

    func isOn(_ e: StatusEvent) -> Bool { !disabled.contains(e) }
    func setOn(_ e: StatusEvent, _ on: Bool) {
        if on { disabled.remove(e) } else { disabled.insert(e) }
        save()
    }
    func setAll(_ on: Bool) {
        disabled = on ? [] : Set(StatusEvent.allCases)
        save()
    }
    func template(_ e: StatusEvent) -> String { e.templateKey.flatMap { templates[$0] } ?? e.defaultTemplate }
    func setTemplate(_ e: StatusEvent, _ t: String) {
        guard let key = e.templateKey else { return }
        templates[key] = t == e.defaultTemplate || t.isEmpty ? nil : t
        save()
    }
    func revert() {
        disabled = []
        templates = [:]
        save()
    }

    /// The message with its variables filled in.
    func text(_ e: StatusEvent, _ vars: [String: String]) -> String {
        var t = template(e)
        for (k, v) in vars { t = t.replacingOccurrences(of: "{\(k)}", with: v) }
        return t
    }
}

/// Settings → Display → Status-bar events: the desktop's Status Bar
/// Events dialog.
struct StatusEventsView: View {
    @Environment(AppModel.self) private var model
    @State private var editing: StatusEvent?

    var body: some View {
        let store = model.statusEvents
        Form {
            Section {
                ForEach(StatusEvent.allCases) { e in
                    Toggle(isOn: Binding(get: { store.isOn(e) }, set: { store.setOn(e, $0) })) {
                        VStack(alignment: .leading) {
                            Text(e.label)
                            if e.templateKey != nil {
                                Text(store.template(e)).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .accessibilityActions { if e.templateKey != nil { Button("Change the message") { editing = e } } }
                    .contextMenu { if e.templateKey != nil { Button("Change the message") { editing = e } } }
                }
            } footer: {
                Text("Shown in the server screen's status line and, with \"Show status-bar events in the chat\", in the chat. An event's actions change its message.")
            }
            Section {
                Button("Enable all") { store.setAll(true) }
                Button("Clear all") { store.setAll(false) }
                Button("Revert", role: .destructive) { store.revert() }
            }
        }
        .navigationTitle("Status-bar events")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $editing) { e in StatusTemplateEditor(event: e) }
    }
}

private struct StatusTemplateEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let event: StatusEvent
    @State private var text = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Message", text: $text, axis: .vertical)
                } footer: {
                    Text("Empty goes back to the first message.")
                }
                Section("Variables (double-tap to add)") {
                    ForEach(event.variables, id: \.0) { v in
                        Button { text += v.0 } label: { LabeledContent(v.0, value: v.1) }
                            .foregroundStyle(.primary)
                    }
                }
                Section {
                    Button("Reset to default value") { text = event.defaultTemplate }
                }
            }
            .navigationTitle(event.label)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { model.statusEvents.setTemplate(event, text); dismiss() }
                }
            }
            .onAppear { text = model.statusEvents.template(event) }
        }
    }
}
