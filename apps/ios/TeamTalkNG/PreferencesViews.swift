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
                Toggle("Show last to talk in yellow", isOn: $model.showLastTalk)
                Toggle("Show user and channel icons", isOn: $model.showIcons)
                NumberField("Maximum text length in channel list", value: $model.maxTextLength, in: 1...1000)
                Picker("Style of user and channel info", selection: $model.infoStyle) {
                    ForEach(AppModel.InfoStyle.allCases) { Text($0.label).tag($0) }
                }
                Picker("Sort channels by", selection: $model.sortChannelsByName) {
                    Text("Ascending").tag(true)
                    Text("Popularity").tag(false)
                }
                Picker("Double-tapping a channel", selection: $model.channelTap) {
                    ForEach(AppModel.ChannelTap.allCases) { Text($0.label).tag($0) }
                }
                Toggle("Expand channels automatically", isOn: $model.autoExpandChannels)
            }
            Section("Chat") {
                Toggle("Show the time of messages", isOn: $model.showTimestamps)
                TextField("Timestamp format (empty: the system's)", text: $model.timestampFormat).accessibilityLabel("Timestamp format (empty: the system's)")
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityHint("Such as HH:mm:ss. Now: \(model.timestamp(.now))")
                Toggle("Show the message of the day", isOn: $model.showMOTD)
                Toggle("Show status-bar events in the chat", isOn: $model.eventsInChat)
                NavigationLink("Status-bar events") { StatusEventsView() }
                NavigationLink("Message templates") { ChatTemplatesView() }
            }
            Section("Dialogs") {
                Toggle("Popup dialog when receiving text message", isOn: $model.messagePopup)
                Toggle("Show dialog box when excluded from channel or server", isOn: $model.excludedDialog)
                Toggle("Show dialog box with server list on startup", isOn: $model.serverListOnStart)
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
