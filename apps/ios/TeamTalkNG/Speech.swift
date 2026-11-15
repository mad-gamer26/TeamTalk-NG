import AVFoundation
import Observation
import SwiftUI

/// What the desktop speaks (its Text to Speech events), each with a
/// message to say, made of {variables}.
enum SpeechEvent: String, CaseIterable, Identifiable, Codable {
    case loggedIn, loggedOut
    case joined, left, joinedMine, leftMine
    case privateMessage, privateMessageSent, typing
    case questionMode
    case channelMessage, channelMessageSent
    case broadcastMessage, broadcastMessageSent
    case subscriptionChange, classroomChange
    case fileAdded, fileRemoved
    case connection
    case talking

    var id: Self { self }

    var label: String {
        switch self {
        case .loggedIn: "Someone logs in"
        case .loggedOut: "Someone logs out"
        case .joined: "Someone joins another channel"
        case .left: "Someone leaves another channel"
        case .joinedMine: "Someone joins your channel"
        case .leftMine: "Someone leaves your channel"
        case .privateMessage: "Private message"
        case .privateMessageSent: "Private message sent"
        case .typing: "Someone is typing to you"
        case .questionMode: "Someone has a question"
        case .channelMessage: "Channel message"
        case .channelMessageSent: "Channel message sent"
        case .broadcastMessage: "Broadcast message"
        case .broadcastMessageSent: "Broadcast message sent"
        case .subscriptionChange: "A subscription changes"
        case .classroomChange: "Classroom permission changes"
        case .fileAdded: "File added"
        case .fileRemoved: "File removed"
        case .connection: "Connection lost, back, kicked"
        case .talking: "Talking starts and stops"
        }
    }

    /// The desktop's message.
    var defaultTemplate: String {
        switch self {
        case .loggedIn: "{user} has logged in on {server}"
        case .loggedOut: "{user} has logged out from {server}"
        case .joined: "{user} joined channel {channel}"
        case .left: "{user} left channel {channel}"
        case .joinedMine: "{user} joined channel"
        case .leftMine: "{user} left channel"
        case .privateMessage: "Private message from {user}: {message}"
        case .privateMessageSent: "Private message sent: {message}"
        case .typing: "{user} is typing..."
        case .questionMode: "{user} set question mode"
        case .channelMessage: "Channel message from {user}: {message}"
        case .channelMessageSent: "Channel message sent: {message}"
        case .broadcastMessage: "Broadcast message from {user}: {message}"
        case .broadcastMessageSent: "Broadcast message sent: {message}"
        case .subscriptionChange: "Subscription \"{type}\" {state} for {user}"
        case .classroomChange: "Transmission \"{type}\" {state} for {user}"
        case .fileAdded: "File {filename} added by {user}"
        case .fileRemoved: "File {file} removed by {user}"
        case .connection: "{server}: {state}"
        case .talking: "{state}"
        }
    }

    /// The {variables} it may use, and what each is.
    var variables: [(String, String)] {
        let user = [("{user}", "Their nickname"), ("{username}", "Their username")]
        let server = ("{server}", "The server's name")
        switch self {
        case .loggedIn, .loggedOut, .questionMode: return user + [server]
        case .joined, .left: return user + [("{channel}", "The channel")]
        case .joinedMine, .leftMine, .typing: return user
        case .privateMessage, .channelMessage, .broadcastMessage: return user + [("{message}", "The message"), server]
        case .privateMessageSent, .channelMessageSent, .broadcastMessageSent: return [("{message}", "The message")]
        case .subscriptionChange, .classroomChange: return user + [("{type}", "Which"), ("{state}", "On or off")]
        case .fileAdded: return user + [("{filename}", "The file"), ("{filesize}", "Its size")]
        case .fileRemoved: return user + [("{file}", "The file")]
        case .connection: return [server, ("{state}", "What happened")]
        case .talking: return [("{state}", "Talking, or stopped talking")]
        }
    }

    /// As the desktop has it (and announcements this app always made).
    var onByDefault: Bool {
        switch self {
        case .joined, .left, .privateMessageSent, .channelMessageSent, .broadcastMessageSent, .typing: false
        default: true
        }
    }
}

/// How events are spoken, and which.
@MainActor @Observable
final class SpeechStore {
    enum Output: String, CaseIterable, Identifiable {
        /// VoiceOver says them (when it's running; else the system voice).
        case voiceOver
        /// The system voice, always.
        case systemVoice
        case off
        var id: Self { self }
        var label: String {
            switch self {
            case .voiceOver: "VoiceOver (the system voice when it's off)"
            case .systemVoice: "The system voice"
            case .off: "Nothing"
            }
        }
    }

    var output: Output = .voiceOver { didSet { save() } }
    /// Cut short what's being said for something new (the desktop's
    /// "interrupt current screen reader speech").
    var interrupt = false { didSet { save() } }
    var voice = "" { didSet { save() } }
    /// 0–1, as the system voice takes them.
    var rate = Double(AVSpeechUtteranceDefaultSpeechRate) { didSet { save() } }
    var volume = 1.0 { didSet { save() } }
    private(set) var disabled: Set<SpeechEvent> = []
    private(set) var templates: [SpeechEvent: String] = [:]

    private let defaults = UserDefaults.standard
    private let synth = AVSpeechSynthesizer()

    init() {
        output = Output(rawValue: defaults.string(forKey: "speechOutput") ?? "") ?? .voiceOver
        interrupt = defaults.bool(forKey: "speechInterrupt")
        voice = defaults.string(forKey: "speechVoice") ?? ""
        rate = defaults.object(forKey: "speechRate") as? Double ?? Double(AVSpeechUtteranceDefaultSpeechRate)
        volume = defaults.object(forKey: "speechVolume") as? Double ?? 1
        if let off = defaults.stringArray(forKey: "speechOff") {
            disabled = Set(off.compactMap(SpeechEvent.init(rawValue:)))
        } else {
            disabled = Set(SpeechEvent.allCases.filter { !$0.onByDefault })
        }
        if let t = defaults.dictionary(forKey: "speechTemplates") as? [String: String] {
            for (k, v) in t { if let e = SpeechEvent(rawValue: k) { templates[e] = v } }
        }
    }

    private func save() {
        defaults.set(output.rawValue, forKey: "speechOutput")
        defaults.set(interrupt, forKey: "speechInterrupt")
        defaults.set(voice, forKey: "speechVoice")
        defaults.set(rate, forKey: "speechRate")
        defaults.set(volume, forKey: "speechVolume")
        defaults.set(disabled.map(\.rawValue), forKey: "speechOff")
        defaults.set(Dictionary(uniqueKeysWithValues: templates.map { ($0.key.rawValue, $0.value) }), forKey: "speechTemplates")
    }

    func isOn(_ e: SpeechEvent) -> Bool { !disabled.contains(e) }
    func setOn(_ e: SpeechEvent, _ on: Bool) {
        if on { disabled.remove(e) } else { disabled.insert(e) }
        save()
    }
    func setAll(_ on: Bool) {
        disabled = on ? [] : Set(SpeechEvent.allCases)
        save()
    }

    func template(_ e: SpeechEvent) -> String { templates[e] ?? e.defaultTemplate }
    func setTemplate(_ e: SpeechEvent, _ t: String) {
        templates[e] = t == e.defaultTemplate || t.isEmpty ? nil : t
        save()
    }
    func resetTemplates() {
        templates = [:]
        save()
    }

    /// As the desktop has them: on and off, messages, voice.
    func revert() {
        templates = [:]
        disabled = Set(SpeechEvent.allCases.filter { !$0.onByDefault })
        output = .voiceOver
        interrupt = false
        rate = Double(AVSpeechUtteranceDefaultSpeechRate)
        volume = 1
        voice = ""
    }

    /// The message with its variables filled in.
    func text(_ e: SpeechEvent, _ vars: [String: String]) -> String {
        var t = template(e)
        for (k, v) in vars { t = t.replacingOccurrences(of: "{\(k)}", with: v) }
        return t
    }

    /// Says an event (if it's on).
    func say(_ e: SpeechEvent, _ vars: [String: String]) {
        guard isOn(e) else { return }
        speak(text(e, vars))
    }

    /// Says anything, the chosen way.
    func speak(_ text: String) {
        switch output {
        case .off: return
        case .voiceOver where UIAccessibility.isVoiceOverRunning:
            var s = AttributedString(text)
            s.accessibilitySpeechAnnouncementPriority = interrupt ? .high : .default
            AccessibilityNotification.Announcement(s).post()
        default:
            if interrupt { synth.stopSpeaking(at: .immediate) }
            let u = AVSpeechUtterance(string: text)
            u.rate = Float(rate)
            u.volume = Float(volume)
            if !voice.isEmpty { u.voice = AVSpeechSynthesisVoice(identifier: voice) }
            synth.speak(u)
        }
    }
}

/// Settings → Spoken events.
struct SpeechView: View {
    @Environment(AppModel.self) private var model
    @State private var editing: SpeechEvent?

    var body: some View {
        let speech = model.speech
        @Bindable var b = speech
        Form {
            Section {
                Picker("Say events with", selection: $b.output) {
                    ForEach(SpeechStore.Output.allCases) { Text($0.label).tag($0) }
                }
                Toggle("Interrupt what's being said", isOn: $b.interrupt)
            }
            if speech.output != .off {
                Section("The system voice") {
                    Picker("Voice", selection: $b.voice) {
                        Text("The system's").tag("")
                        ForEach(AVSpeechSynthesisVoice.speechVoices().sorted { $0.name < $1.name }, id: \.identifier) { v in
                            Text("\(v.name), \(Locale.current.localizedString(forIdentifier: v.language) ?? v.language)").tag(v.identifier)
                        }
                    }
                    Slider(value: $b.rate, in: Double(AVSpeechUtteranceMinimumSpeechRate)...Double(AVSpeechUtteranceMaximumSpeechRate)) {
                        Text("Speed")
                    }
                    .accessibilityValue("\(Int(speech.rate * 100)) percent")
                    Slider(value: $b.volume, in: 0...1) { Text("Volume") }
                        .accessibilityValue("\(Int(speech.volume * 100)) percent")
                    Button("Try it") { speech.speak("This is how events sound.") }
                }
            }
            Section {
                ForEach(SpeechEvent.allCases) { e in
                    Toggle(isOn: Binding(get: { speech.isOn(e) }, set: { speech.setOn(e, $0) })) {
                        VStack(alignment: .leading) {
                            Text(e.label)
                            Text(speech.template(e)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityActions { Button("Change what's said") { editing = e } }
                    .contextMenu { Button("Change what's said") { editing = e } }
                }
            } header: {
                Text("Events")
            } footer: {
                Text("Each event's action (swipe up or down with VoiceOver, or touch and hold) changes what's said.")
            }
            Section {
                Button("Turn all on") { speech.setAll(true) }
                Button("Turn all off") { speech.setAll(false) }
                Button("Every message as it was at first") { speech.resetTemplates() }
                Button("Everything as it was at first", role: .destructive) { speech.revert() }
            }
        }
        .navigationTitle("Spoken events")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $editing) { e in TemplateEditor(event: e) }
    }
}

/// Changing what an event says, with its variables.
private struct TemplateEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let event: SpeechEvent
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
                        Button { text += v.0 } label: {
                            LabeledContent(v.0, value: v.1)
                        }
                        .foregroundStyle(.primary)
                    }
                }
                Section {
                    Button("Back to the first message") { text = event.defaultTemplate }
                    Button("Try it") { model.speech.speak(text) }
                }
            }
            .navigationTitle(event.label)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { model.speech.setTemplate(event, text); dismiss() }
                }
            }
            .onAppear { text = model.speech.template(event) }
        }
    }
}
