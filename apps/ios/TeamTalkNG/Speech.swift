import AVFoundation
import Observation
import SwiftUI

/// What the desktop speaks: its Text to Speech events (qtTeamTalk's
/// utiltts.h), each on or off by itself, in its order, with its names.
/// Events of a group share one message, as on the desktop.
enum SpeechEvent: String, CaseIterable, Identifiable, Codable {
    case loggedIn, loggedOut
    case joined, left, joinedMine, leftMine
    case privateMessage, privateMessageSent, typing, typingAnywhere
    case channelMessage, channelMessageSent
    case broadcastMessage, broadcastMessageSent
    case questionMode
    case subUserMessages, subChannelMessages, subBroadcastMessages, subVoice, subVideo
    case subDesktop, subDesktopInput, subMediaFile
    case subInterceptUserMessages, subInterceptChannelMessages, subInterceptVoice
    case subInterceptVideo, subInterceptDesktop, subInterceptMediaFile
    case classroomChat, classroomVoice, classroomVideo, classroomDesktop, classroomMediaFile
    case fileAdded, fileRemoved
    case menuActions
    case voiceTransmission, videoTransmission, desktopSharing
    case connectivity

    var id: Self { self }

    /// The desktop's names (Preferences → Text to Speech).
    var label: String {
        switch self {
        case .loggedIn: "User logged in"
        case .loggedOut: "User logged out"
        case .joined: "User joined channel"
        case .left: "User left channel"
        case .joinedMine: "User joined current channel"
        case .leftMine: "User left current channel"
        case .privateMessage: "Private message received"
        case .privateMessageSent: "Private message sent"
        case .typing: "User is typing a private message in focused window"
        case .typingAnywhere: "User is typing a private message"
        case .channelMessage: "Channel message received"
        case .channelMessageSent: "Channel message sent"
        case .broadcastMessage: "Broadcast message received"
        case .broadcastMessageSent: "Broadcast message sent"
        case .questionMode: "User enabled question mode"
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
        case .menuActions: "Menu actions"
        case .voiceTransmission: "Voice transmission mode toggled"
        case .videoTransmission: "Video transmission toggled"
        case .desktopSharing: "Desktop sharing toggled"
        case .connectivity: "Server connectivity"
        }
    }

    /// The message it's stored under: shared within a group, as the
    /// desktop's (the keys are the ones this app used before, so changed
    /// messages carry over). Nil: it says fixed words (the desktop's).
    var templateKey: String? {
        switch self {
        case .subUserMessages, .subChannelMessages, .subBroadcastMessages, .subVoice, .subVideo,
             .subDesktop, .subDesktopInput, .subMediaFile, .subInterceptUserMessages,
             .subInterceptChannelMessages, .subInterceptVoice, .subInterceptVideo,
             .subInterceptDesktop, .subInterceptMediaFile: "subscriptionChange"
        case .classroomChat, .classroomVoice, .classroomVideo, .classroomDesktop, .classroomMediaFile: "classroomChange"
        case .typingAnywhere: "typing"
        case .menuActions, .voiceTransmission, .videoTransmission, .desktopSharing, .connectivity: nil
        default: rawValue
        }
    }

    /// The desktop's message (settings.h TTSMSG_*).
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
        case .typing, .typingAnywhere: "{user} is typing..."
        case .questionMode: "{user} set question mode"
        case .channelMessage: "Channel message from {user}: {message}"
        case .channelMessageSent: "Channel message sent: {message}"
        case .broadcastMessage: "Broadcast message from {user}: {message}"
        case .broadcastMessageSent: "Broadcast message sent: {message}"
        case .fileAdded: "File {filename} added by {user}"
        case .fileRemoved: "File {file} removed by {user}"
        default:
            switch templateKey {
            case "subscriptionChange": "Subscription \"{type}\" {state} for {user}"
            case "classroomChange": "Transmission \"{type}\" {state} for {user}"
            default: "{message}"
            }
        }
    }

    /// The {variables} it may use, and what each is (the desktop's).
    var variables: [(String, String)] {
        let user = [("{user}", "User's nickname"), ("{username}", "User's username")]
        let server = ("{server}", "Server's name")
        switch self {
        case .loggedIn, .loggedOut, .questionMode: return user + [server]
        case .joined, .left: return user + [("{channel}", "Channel's name")]
        case .joinedMine, .leftMine, .typing, .typingAnywhere: return user
        case .privateMessage, .channelMessage, .broadcastMessage: return user + [("{message}", "Message content"), server]
        case .privateMessageSent, .channelMessageSent, .broadcastMessageSent: return [("{message}", "Message content")]
        case .fileAdded: return [("{filename}", "File name")] + user + [("{filesize}", "File size")]
        case .fileRemoved: return [("{file}", "File name")] + user
        default:
            switch templateKey {
            case "subscriptionChange": return user + [("{type}", "Subscription type"), ("{state}", "Subscription state")]
            case "classroomChange": return [("{type}", "Transmission type"), ("{state}", "Transmission state"), ("{user}", "User concerns by change")]
            default: return []
            }
        }
    }

    /// On by default as on the desktop (TTS_ACTIVEEVENTS).
    var onByDefault: Bool {
        switch self {
        case .loggedIn, .loggedOut, .joinedMine, .leftMine, .privateMessage, .channelMessage,
             .broadcastMessage, .fileAdded, .fileRemoved, .menuActions: true
        default: false
        }
    }

    /// The events an earlier version's event became (to keep its choice).
    static func from(old: String) -> [SpeechEvent] {
        if let e = SpeechEvent(rawValue: old) { return [e] }
        switch old {
        case "subscriptionChange": return allCases.filter { $0.templateKey == "subscriptionChange" }
        case "classroomChange": return allCases.filter { $0.templateKey == "classroomChange" }
        case "connection": return [.connectivity]
        case "talking": return [.voiceTransmission]
        default: return []
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
    /// Changed messages, by SpeechEvent.templateKey.
    private(set) var templates: [String: String] = [:]

    private let defaults = UserDefaults.standard
    private let synth = AVSpeechSynthesizer()

    init() {
        output = Output(rawValue: defaults.string(forKey: "speechOutput") ?? "") ?? .voiceOver
        interrupt = defaults.bool(forKey: "speechInterrupt")
        voice = defaults.string(forKey: "speechVoice") ?? ""
        rate = defaults.object(forKey: "speechRate") as? Double ?? Double(AVSpeechUtteranceDefaultSpeechRate)
        volume = defaults.object(forKey: "speechVolume") as? Double ?? 1
        if let off = defaults.stringArray(forKey: "speechOff") {
            // The earlier version's events: its defaults become the
            // desktop's; choices made by hand carry over to the events
            // they became.
            let oldDefault: Set<String> = ["joined", "left", "privateMessageSent", "channelMessageSent", "broadcastMessageSent", "typing"]
            if !defaults.bool(forKey: "speechEventsDesktop") {
                if Set(off) == oldDefault {
                    disabled = Set(SpeechEvent.allCases.filter { !$0.onByDefault })
                } else {
                    let known = Set(off.flatMap(SpeechEvent.from(old:)))
                    disabled = known.union(SpeechEvent.allCases.filter { !$0.onByDefault && ["typingAnywhere", "menuActions", "videoTransmission", "desktopSharing"].contains($0.rawValue) })
                }
                defaults.set(true, forKey: "speechEventsDesktop")
            } else {
                disabled = Set(off.compactMap(SpeechEvent.init(rawValue:)))
            }
        } else {
            disabled = Set(SpeechEvent.allCases.filter { !$0.onByDefault })
            defaults.set(true, forKey: "speechEventsDesktop")
        }
        if let t = defaults.dictionary(forKey: "speechTemplates") as? [String: String] {
            templates = t
        }
    }

    private func save() {
        defaults.set(output.rawValue, forKey: "speechOutput")
        defaults.set(interrupt, forKey: "speechInterrupt")
        defaults.set(voice, forKey: "speechVoice")
        defaults.set(rate, forKey: "speechRate")
        defaults.set(volume, forKey: "speechVolume")
        defaults.set(disabled.map(\.rawValue), forKey: "speechOff")
        defaults.set(templates, forKey: "speechTemplates")
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

    func template(_ e: SpeechEvent) -> String { e.templateKey.flatMap { templates[$0] } ?? e.defaultTemplate }
    func setTemplate(_ e: SpeechEvent, _ t: String) {
        guard let key = e.templateKey else { return }
        templates[key] = t == e.defaultTemplate || t.isEmpty ? nil : t
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

    /// The message with its variables filled in (fixed-words events say
    /// their {message}).
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
                            if e.templateKey != nil {
                                Text(speech.template(e)).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .accessibilityActions { if e.templateKey != nil { Button("Change what's said") { editing = e } } }
                    .contextMenu { if e.templateKey != nil { Button("Change what's said") { editing = e } } }
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
