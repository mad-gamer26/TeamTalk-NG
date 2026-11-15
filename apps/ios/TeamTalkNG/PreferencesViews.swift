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
                Picker("Sort channels", selection: $model.sortChannelsByName) {
                    Text("By name").tag(true)
                    Text("As the server has them").tag(false)
                }
                Picker("Double-tapping a channel", selection: $model.channelTap) {
                    ForEach(AppModel.ChannelTap.allCases) { Text($0.label).tag($0) }
                }
            }
            Section("Chat") {
                Toggle("Show the time of messages", isOn: $model.showTimestamps)
                Toggle("Show the message of the day", isOn: $model.showMOTD)
                Toggle("Show joins, leaves and logins in the chat", isOn: $model.eventsInChat)
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
