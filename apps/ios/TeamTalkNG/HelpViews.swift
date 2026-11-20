import SwiftUI

/// About TeamTalk NG (the desktop's Help → About).
struct AboutView: View {
    var body: some View {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? ""
        let build = info?["CFBundleVersion"] as? String ?? ""
        Form {
            Section {
                LabeledContent("Version", value: version)
                LabeledContent("Build", value: build)
                LabeledContent("TeamTalk SDK", value: sdkVersion())
            }
            Section("Made with") {
                Text("BearWare.dk's TeamTalk 5 SDK, and its classic sounds.")
                Text("Sound packs from the TeamTalk NG catalog, by their authors.")
            }
            Section {
                Link("BearWare.dk", destination: URL(string: "https://bearware.dk")!)
            }
        }
        .navigationTitle("About")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// The manual (the desktop's Help → Manual), short and spoken-friendly.
struct HelpView: View {
    private let topics: [(String, String)] = [
        ("Servers", "Add a server with the Add server button: type its details, pick one from the public list, use a join code, or open a .tt file or tt:// link. Open a server to connect; it stays connected while you use others."),
        ("Channels and people", "A server shows its channels with the people in each. Double-tap a channel to join it. Double-tap a person for everything about them and what you can do with them. Each channel and person also has actions: swipe up or down with VoiceOver to hear them."),
        ("Talking", "Push to talk: tap the Talk button to start or stop talking, or press and hold it to talk while held (with VoiceOver: double-tap, or double-tap and hold). Magic Tap, a two-finger double-tap, starts and stops talking anywhere on a server, or mutes and unmutes with voice activation. Choose push to talk or voice activation in Settings."),
        ("Messages", "The Chat tab has the channel's conversation. Write privately to someone from their details. Your chat history stays until you clear it, and can be saved to text files."),
        ("Files and media", "The Files tab has the channel's files: download, upload, delete. Stream a file to the channel from the More menu (Stream a File to the Channel). To hear it yourself, turn on your own media file subscription: your entry in the channel list, Subscriptions."),
        ("Sounds and speech", "Every event has a sound and a spoken message, as on the desktop. Choose which, change the messages and the voice in Settings → Sounds and Settings → Spoken events."),
        ("Administration", "With the rights, the More menu has user accounts, server settings, bans, statistics and broadcast messages, and people and channels have their moderation actions."),
        ("Keyboard", "With a keyboard, the desktop client's shortcuts, Command for its Control and Option for its Alt. They act on the person or channel VoiceOver is on. Command-I user information, Command-G speak it, Command-E messages, Command-O op, Command-U volume, Command-Shift-M mute voice, Command-K and Command-Option-K kick from the channel and the server, Command-B and Command-Option-B kick and ban, Command-1 to 8 subscriptions, Command-Shift-1 to 8 intercepts, Command-Y and Command-H voice volume up and down, Command-M mute all, Command-J join, Command-L leave, Command-Option-G speak channel information, Command-Shift-G speak channel state, Command-Shift-R copy a tt:// link, Command-S stream a file, Command-P pause or resume it, Command-T speak client statistics, Command-Option-A record, Command-Shift-T and Command-Shift-A push to talk and voice activation, Command-Option-S and Command-Option-Z spoken and sound events on or off, Command-Shift-L user accounts, Command-Shift-B banned users, Command-Shift-U online users, Command-Shift-E broadcast, Command-Shift-S save the server's configuration. This app's own: Command-Shift-P talks or stops talking, Control-1, 2 and 3 choose Channels, Chat and Files, and Command-Return sends a message."),
    ]

    var body: some View {
        List(topics, id: \.0) { t in
            VStack(alignment: .leading, spacing: 6) {
                Text(t.0).font(.headline)
                Text(t.1)
            }
            .accessibilityElement(children: .combine)
        }
        .navigationTitle("Help")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// The first-run setup (TeamTalk Classic's wizard): who you are, how you
/// talk, and a first server.
struct FirstRunView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var nickname = ""
    @State private var gender = Gender.neutral
    @State private var mode = TalkMode.pushToTalk
    @State private var showPublic = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("A few things to set up. You can change all of them later in Settings.")
                }
                Section("You") {
                    TextField("Nickname", text: $nickname).accessibilityLabel("Nickname")
                    Picker("Gender", selection: $gender) {
                        Text("Male").tag(Gender.male)
                        Text("Female").tag(Gender.female)
                        Text("Neutral").tag(Gender.neutral)
                    }
                }
                Section {
                    Picker("Talking", selection: $mode) {
                        ForEach(TalkMode.allCases) { Text($0.label).tag($0) }
                    }
                } footer: {
                    Text("Push to talk: a tap on the Talk button starts or stops talking; pressing and holding it talks while held. Magic Tap starts or stops too. Voice activation sends when you speak, with a mute button.")
                }
                Section {
                    Button("Find a server to start with") { showPublic = true }
                }
            }
            .navigationTitle("Welcome to TeamTalk NG")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        if !nickname.isEmpty { model.nickname = nickname }
                        model.gender = gender
                        model.talkMode = mode
                        UserDefaults.standard.set(true, forKey: "setUp")
                        dismiss()
                    }
                }
            }
            .sheet(isPresented: $showPublic) { PublicServersView() }
        }
        .interactiveDismissDisabled()
    }
}
