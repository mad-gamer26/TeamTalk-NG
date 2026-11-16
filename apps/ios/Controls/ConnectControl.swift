import AppIntents
import SwiftUI
import WidgetKit

/// The extension: Live Activities (iOS 17) and Control Center's controls
/// (iOS 18): Connect to a server (chosen when it's added), Disconnect, and
/// switches for the microphone, Mute Everyone for Me and voice activation.
/// The switches act on the open server, or the only one connected.
@main
struct TeamTalkControls: WidgetBundle {
    var body: some Widget {
        ServerActivityWidget()
        if #available(iOSApplicationExtension 18.0, *) {
            ConnectServerControl()
            DisconnectControl()
            MicrophoneControl()
            MuteEveryoneControl()
            VoiceActivationControl()
        }
    }
}

@available(iOSApplicationExtension 18.0, *)
struct ConnectServerControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        AppIntentControlConfiguration(kind: "TeamTalkNG.connect-server", provider: Provider()) { server in
            ControlWidgetButton(action: ConnectServerIntent(server: server)) {
                Label("Connect to \(server.name)", systemImage: "server.rack")
            }
        }
        .displayName("Connect to Server")
        .description("Connects to a server in your server list.")
        .promptsForUserConfiguration()
    }

    struct Provider: AppIntentControlValueProvider {
        func previewValue(configuration: ChooseServer) -> ServerEntity {
            configuration.server ?? ServerEntity.all().first ?? ServerEntity(id: "", name: "a server")
        }
        func currentValue(configuration: ChooseServer) async throws -> ServerEntity {
            previewValue(configuration: configuration)
        }
    }
}

@available(iOSApplicationExtension 18.0, *)
struct ChooseServer: ControlConfigurationIntent {
    static let title: LocalizedStringResource = "Choose a Server"
    @Parameter(title: "Server") var server: ServerEntity?
}

@available(iOSApplicationExtension 18.0, *)
struct DisconnectControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "TeamTalkNG.disconnect") {
            ControlWidgetButton(action: DisconnectIntent()) {
                Label("Disconnect", systemImage: "xmark.circle")
            }
        }
        .displayName("Disconnect")
        .description("Disconnects from the open server, or the only one connected.")
    }
}

/// The switches' value: what the app last wrote to the App Group.
@available(iOSApplicationExtension 18.0, *)
struct StateValue: ControlValueProvider {
    let pick: @Sendable (ControlState.Values) -> Bool
    var previewValue: Bool { false }
    func currentValue() async throws -> Bool { pick(ControlState.read()) }
}

@available(iOSApplicationExtension 18.0, *)
struct MicrophoneControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "TeamTalkNG.microphone", provider: StateValue { $0.connected && $0.microphoneOn }) { on in
            ControlWidgetToggle("Microphone", isOn: on, action: MicrophoneSwitchIntent()) { isOn in
                Label(isOn ? "Microphone on" : "Microphone off", systemImage: isOn ? "mic.fill" : "mic.slash")
            }
        }
        .displayName("Microphone")
        .description("Push to talk: talks or stops. Voice activation: unmutes or mutes the microphone.")
    }
}

@available(iOSApplicationExtension 18.0, *)
struct MuteEveryoneControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "TeamTalkNG.mute-everyone", provider: StateValue { $0.connected && $0.mutedEveryone }) { on in
            ControlWidgetToggle("Mute Everyone for Me", isOn: on, action: MuteEveryoneSwitchIntent()) { isOn in
                Label(isOn ? "Everyone muted for me" : "Everyone heard", systemImage: isOn ? "speaker.slash" : "speaker.wave.2")
            }
        }
        .displayName("Mute Everyone for Me")
        .description("Mutes or unmutes everything you hear from the server. Nobody else is muted.")
    }
}

@available(iOSApplicationExtension 18.0, *)
struct VoiceActivationControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "TeamTalkNG.voice-activation", provider: StateValue { $0.voiceActivation }) { on in
            ControlWidgetToggle("Voice Activation", isOn: on, action: VoiceActivationSwitchIntent()) { isOn in
                Label(isOn ? "Voice activation" : "Push to talk", systemImage: "waveform")
            }
        }
        .displayName("Voice Activation")
        .description("Voice activation on, or push to talk.")
    }
}
