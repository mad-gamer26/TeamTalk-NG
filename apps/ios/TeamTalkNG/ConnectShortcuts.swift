import AppIntents

/// Siri: "Connect to <server> in TTNG Dev" (the old app's voice shortcut).
struct TeamTalkShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: ConnectServerIntent(), phrases: [
            "Connect to \(\.$target) in \(.applicationName)",
            "Connect to a server in \(.applicationName)",
        ], shortTitle: "Connect to Server", systemImageName: "server.rack")
    }
}
