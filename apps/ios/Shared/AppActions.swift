import AppIntents
import Foundation

// Siri, the Shortcuts app, Control Center and Live Activities' buttons:
// disconnect, mute everyone for me, talk mode, the microphone, status and
// messages. Built into the app and the controls extension; as Live Activity
// intents they always run in the app (started in the background if need
// be), where the connections are. A server left out means the open one, or
// the only one connected.

struct ShortcutProblem: Error, CustomLocalizedStringResourceConvertible {
    let text: String
    init(_ text: String) { self.text = text }
    var localizedStringResource: LocalizedStringResource { "\(text)" }
}

enum SwitchAction: String, AppEnum {
    case on, off, toggle
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "On or off"
    static let caseDisplayRepresentations: [SwitchAction: DisplayRepresentation] = [
        .on: "On", .off: "Off", .toggle: "Switch",
    ]
    func resolve(_ now: Bool) -> Bool {
        switch self {
        case .on: true
        case .off: false
        case .toggle: !now
        }
    }
}

enum TalkModeChoice: String, AppEnum {
    case pushToTalk, voiceActivation, switchMode
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Talk mode"
    static let caseDisplayRepresentations: [TalkModeChoice: DisplayRepresentation] = [
        .pushToTalk: "Push to talk", .voiceActivation: "Voice activation", .switchMode: "Switch",
    ]
}

enum StatusChoice: String, AppEnum {
    case available, away, question
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Status"
    static let caseDisplayRepresentations: [StatusChoice: DisplayRepresentation] = [
        .available: "Available", .away: "Away", .question: "Question",
    ]
    var label: String {
        switch self {
        case .available: "Available"
        case .away: "Away"
        case .question: "Question"
        }
    }
}

struct DisconnectIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Disconnect"
    static let description = IntentDescription("Disconnects from a server (the open one, or the only one connected, when none is chosen).")
    @Parameter(title: "Server") var server: ServerEntity?
    static var parameterSummary: some ParameterSummary { Summary("Disconnect from \(\.$server)") }

    init() {}
    init(serverId: String?) { server = serverId.map { ServerEntity(id: $0, name: "") } }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let id = server?.id
        #if TTNG_APP
        let said = try ShortcutActions.disconnect(id)
        #else
        let said = "Open TeamTalk NG and try again."
        #endif
        return .result(dialog: "\(said)")
    }
}

struct DisconnectAllIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Disconnect From Every Server"
    static let description = IntentDescription("Disconnects from every server you're connected to.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        #if TTNG_APP
        let said = try ShortcutActions.disconnectAll()
        #else
        let said = "Open TeamTalk NG and try again."
        #endif
        return .result(dialog: "\(said)")
    }
}

struct MuteEveryoneIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Mute Everyone for Me"
    static let description = IntentDescription("Mutes or unmutes everything you hear from a server. Nobody else is muted.")
    @Parameter(title: "Mute", default: .toggle) var action: SwitchAction
    @Parameter(title: "Server") var server: ServerEntity?
    static var parameterSummary: some ParameterSummary { Summary("Mute everyone for me: \(\.$action), on \(\.$server)") }

    init() {}
    init(action: SwitchAction, serverId: String?) {
        self.action = action
        server = serverId.map { ServerEntity(id: $0, name: "") }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let id = server?.id, action = action
        #if TTNG_APP
        let said = try ShortcutActions.muteEveryone(id, action)
        #else
        let said = "Open TeamTalk NG and try again."
        #endif
        return .result(dialog: "\(said)")
    }
}

struct TalkModeIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Set Talk Mode"
    static let description = IntentDescription("Push to talk or voice activation, on every server.")
    @Parameter(title: "Talk mode", default: .switchMode) var mode: TalkModeChoice
    static var parameterSummary: some ParameterSummary { Summary("Set talk mode to \(\.$mode)") }

    init() {}
    init(mode: TalkModeChoice) { self.mode = mode }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let mode = mode
        #if TTNG_APP
        let said = try ShortcutActions.talkMode(mode)
        #else
        let said = "Open TeamTalk NG and try again."
        #endif
        return .result(dialog: "\(said)")
    }
}

struct MicrophoneIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Turn Microphone On or Off"
    static let description = IntentDescription("Push to talk: starts or stops talking. Voice activation: unmutes or mutes the microphone.")
    @Parameter(title: "Microphone", default: .toggle) var action: SwitchAction
    @Parameter(title: "Server") var server: ServerEntity?
    static var parameterSummary: some ParameterSummary { Summary("Microphone \(\.$action) on \(\.$server)") }

    init() {}
    init(action: SwitchAction, serverId: String?) {
        self.action = action
        server = serverId.map { ServerEntity(id: $0, name: "") }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let id = server?.id, action = action
        #if TTNG_APP
        let said = try ShortcutActions.microphone(id, action)
        #else
        let said = "Open TeamTalk NG and try again."
        #endif
        return .result(dialog: "\(said)")
    }
}

struct SetStatusIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Set Status"
    static let description = IntentDescription("Available, Away or Question, with a status message if you give one, on every server you're connected to (or the one chosen).")
    @Parameter(title: "Status", default: .available) var status: StatusChoice
    @Parameter(title: "Status message") var message: String?
    @Parameter(title: "Server") var server: ServerEntity?
    static var parameterSummary: some ParameterSummary { Summary("Set status to \(\.$status) with \(\.$message) on \(\.$server)") }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let id = server?.id, status = status, message = message
        #if TTNG_APP
        let said = try ShortcutActions.setStatus(id, status, message)
        #else
        let said = "Open TeamTalk NG and try again."
        #endif
        return .result(dialog: "\(said)")
    }
}

struct SendMessageIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Send a Message"
    static let description = IntentDescription("To the channel you're in, or privately to someone on that server.")
    @Parameter(title: "Message", requestValueDialog: "What do you want to say?") var message: String
    @Parameter(title: "To", description: "A person's nickname or username. Leave it empty to write to the channel.") var person: String?
    @Parameter(title: "Server") var server: ServerEntity?
    static var parameterSummary: some ParameterSummary { Summary("Send \(\.$message) to \(\.$person) on \(\.$server)") }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let id = server?.id, message = message, person = person
        #if TTNG_APP
        let said = try ShortcutActions.sendMessage(id, message, to: person)
        #else
        let said = "Open TeamTalk NG and try again."
        #endif
        return .result(dialog: "\(said)")
    }
}

// Control Center's switches: each sets a value (on or off), in the app.

struct MicrophoneSwitchIntent: SetValueIntent, LiveActivityIntent {
    static let title: LocalizedStringResource = "Microphone"
    @Parameter(title: "On") var value: Bool

    @MainActor
    func perform() async throws -> some IntentResult {
        #if TTNG_APP
        _ = try ShortcutActions.microphone(nil, value ? .on : .off)
        #endif
        return .result()
    }
}

struct MuteEveryoneSwitchIntent: SetValueIntent, LiveActivityIntent {
    static let title: LocalizedStringResource = "Mute Everyone for Me"
    @Parameter(title: "Muted") var value: Bool

    @MainActor
    func perform() async throws -> some IntentResult {
        #if TTNG_APP
        _ = try ShortcutActions.muteEveryone(nil, value ? .on : .off)
        #endif
        return .result()
    }
}

struct VoiceActivationSwitchIntent: SetValueIntent, LiveActivityIntent {
    static let title: LocalizedStringResource = "Voice Activation"
    @Parameter(title: "On") var value: Bool

    @MainActor
    func perform() async throws -> some IntentResult {
        #if TTNG_APP
        _ = try ShortcutActions.talkMode(value ? .voiceActivation : .pushToTalk)
        #endif
        return .result()
    }
}
