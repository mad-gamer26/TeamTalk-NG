import AppIntents

/// Siri's phrases and the Shortcuts app's actions (Shared/ConnectIntent.swift
/// and Shared/AppActions.swift). Every phrase names the app, as Siri needs.
struct TeamTalkShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: ConnectServerIntent(), phrases: [
            "Connect to \(\.$target) in \(.applicationName)",
            "Connect to a server in \(.applicationName)",
        ], shortTitle: "Connect to Server", systemImageName: "server.rack")
        AppShortcut(intent: DisconnectIntent(), phrases: [
            "Disconnect from \(\.$server) in \(.applicationName)",
            "Disconnect in \(.applicationName)",
        ], shortTitle: "Disconnect", systemImageName: "xmark.circle")
        AppShortcut(intent: DisconnectAllIntent(), phrases: [
            "Disconnect from every server in \(.applicationName)",
            "Disconnect from all servers in \(.applicationName)",
        ], shortTitle: "Disconnect From Every Server", systemImageName: "xmark.octagon")
        AppShortcut(intent: MuteEveryoneIntent(), phrases: [
            "Mute everyone in \(.applicationName)",
            "Mute everyone on \(\.$server) in \(.applicationName)",
            "Mute everyone \(\.$action) in \(.applicationName)",
        ], shortTitle: "Mute Everyone for Me", systemImageName: "speaker.slash")
        AppShortcut(intent: TalkModeIntent(), phrases: [
            "Switch talk mode in \(.applicationName)",
            "Use \(\.$mode) in \(.applicationName)",
        ], shortTitle: "Set Talk Mode", systemImageName: "waveform")
        AppShortcut(intent: MicrophoneIntent(), phrases: [
            "Turn the microphone \(\.$action) in \(.applicationName)",
            "Microphone \(\.$action) in \(.applicationName)",
            "Talk in \(.applicationName)",
        ], shortTitle: "Microphone On or Off", systemImageName: "mic")
        AppShortcut(intent: SetStatusIntent(), phrases: [
            "Set my status to \(\.$status) in \(.applicationName)",
            "Set my \(.applicationName) status to \(\.$status)",
        ], shortTitle: "Set Status", systemImageName: "person.crop.circle")
        AppShortcut(intent: SendMessageIntent(), phrases: [
            "Send a message in \(.applicationName)",
            "Send a message to the channel in \(.applicationName)",
        ], shortTitle: "Send a Message", systemImageName: "text.bubble")
    }
}
