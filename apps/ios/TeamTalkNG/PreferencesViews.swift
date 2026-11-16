import UserNotifications
import SwiftUI

/// Settings → Display, as the desktop's Display tab.
struct DisplaySettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section("Channels") {
                Toggle("Show usernames instead of nicknames", isOn: $model.showUsernames)
                Toggle("Show channel topics", isOn: $model.showTopics)
                Toggle("Show number of users in channel", isOn: $model.showUserCount)
                Toggle("Highlight who talked last", isOn: $model.showLastTalk)
                Toggle("Show user and channel icons", isOn: $model.showIcons)
                NumberField("Maximum text length in channel list", value: $model.maxTextLength, in: 1...1000)
                Picker("Show states as", selection: $model.infoStyle) {
                    ForEach(AppModel.InfoStyle.allCases) { Text($0.label).tag($0) }
                }
                Picker("Sort channels by", selection: $model.sortChannelsByName) {
                    Text("Ascending").tag(true)
                    Text("Popularity").tag(false)
                }
                Picker("When I double-tap a channel", selection: $model.channelTap) {
                    ForEach(AppModel.ChannelTap.allCases) { Text($0.label).tag($0) }
                }
                Toggle("Expand channels automatically", isOn: $model.autoExpandChannels)
            }
            Section("Chat") {
                Toggle("Show the time of messages", isOn: $model.showTimestamps)
                Toggle("Return sends message", isOn: $model.sendOnReturn)
                TextField("Timestamp format (empty: the system's)", text: $model.timestampFormat).accessibilityLabel("Timestamp format (empty: the system's)")
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityHint("Such as HH:mm:ss. Now: \(model.timestamp(.now))")
                Toggle("Show the message of the day", isOn: $model.showMOTD)
                Toggle("Show status-bar events in the chat", isOn: $model.eventsInChat)
                NavigationLink("Status-bar events") { StatusEventsView() }
                NavigationLink("Message templates") { ChatTemplatesView() }
            }
            Section("Dialogs") {
                Toggle("Open private messages as they arrive", isOn: $model.messagePopup)
                Toggle("Tell me in a dialog when I'm kicked", isOn: $model.excludedDialog)
                Toggle("Show the server list when the app starts", isOn: $model.serverListOnStart)
            }
            Section {
                Toggle("Notify me of private messages", isOn: $model.notifyInBackground)
            } footer: {
                Text("While TeamTalk NG is in the background.")
            }
        }
        .navigationTitle("Display")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: model.notifyInBackground) { if model.notifyInBackground { requestNotifications() } }
    }
}

func requestNotifications() {
    UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
}

/// Settings → Connection, as the desktop's Connection tab.
struct ConnectionSettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                Toggle("Reconnect when the connection drops", isOn: $model.reconnect)
                Toggle("Join the root channel when connected", isOn: $model.joinRoot)
            } footer: {
                Text("The root channel is joined when neither the server nor your account says which channel. To connect when the app starts, edit the server.")
            }
            Section {
                ForEach(PersonView.normal, id: \.self) { sub in
                    Toggle(PersonView.label(sub), isOn: Binding(
                        get: { !model.defaultSubscriptionsOff.contains(sub) },
                        set: { on in if on { model.defaultSubscriptionsOff.remove(sub) } else { model.defaultSubscriptionsOff.insert(sub) } }))
                }
            } header: {
                Text("Receive from everyone")
            } footer: {
                Text("What you receive from people when they log in. Change it for one person from their details.")
            }
        }
        .navigationTitle("Connection")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Settings → General, as the desktop's General tab: who I am (nickname,
/// gender, status message, the BearWare.dk web login), inactivity, and
/// talking.
struct GeneralSettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                TextField("Nickname", text: $model.nickname).accessibilityLabel("Nickname")
                Picker("Gender", selection: $model.gender) {
                    Text("Male").tag(Gender.male)
                    Text("Female").tag(Gender.female)
                    Text("Neutral").tag(Gender.neutral)
                }
                TextField("Status message", text: $model.statusMessage).accessibilityLabel("Status message")
            } footer: {
                Text("Used on servers that don't have their own.")
            }
            Section {
                NavigationLink("BearWare.dk account") { BearWareView() }
            }
            Section {
                // The desktop's: seconds of inactivity, 0 means disabled.
                NumberField("Set away status after (seconds)", value: $model.awayAfterSeconds, in: 0...86400)
                if model.awayAfterSeconds > 0 {
                    TextField("Status message during inactivity", text: $model.awayMessage).accessibilityLabel("Status message during inactivity")
                    Toggle("Turn off voice activation while I'm away", isOn: $model.awayStopsVoiceActivation)
                }
            } header: {
                Text("Away")
            } footer: {
                Text("Inactivity here: TeamTalk NG in the background or the iPhone locked that long; your status becomes Away and comes back when you return. 0 means disabled.")
            }
            Section("Talking") {
                Picker("Talk mode", selection: $model.talkMode) {
                    ForEach(TalkMode.allCases) { Text($0.label).tag($0) }
                }
                if model.talkMode == .voiceActivation {
                    NamedSlider("Voice activation level", value: $model.voiceLevel, in: 0...20, step: 1,
                                spoken: "\(Int(model.voiceLevel))")
                }
            }
        }
        .navigationTitle("General")
        .navigationBarTitleDisplayMode(.inline)
    }
}
