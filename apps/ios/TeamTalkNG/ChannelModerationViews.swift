import SwiftUI

/// A channel's bans, each removable.
struct ChannelBansView: View {
    @Environment(\.dismiss) private var dismiss
    let connection: ServerConnection
    let channel: Channel
    @State private var bans: [Ban]?

    var body: some View {
        NavigationStack {
            List {
                if let bans {
                    if bans.isEmpty { Text("Nobody is banned from this channel.").foregroundStyle(.secondary) }
                    ForEach(bans, id: \.self) { b in
                        let who = [b.nickname, b.username].first { !$0.isEmpty } ?? b.ipAddress
                        Text(b.byUsername ? "\(who), by account" : "\(who), by IP address \(b.ipAddress)")
                            .swipeActions { Button("Remove ban", role: .destructive) { remove(b) } }
                            .accessibilityActions { Button("Remove ban") { remove(b) } }
                    }
                } else {
                    ProgressView("Loading the bans")
                }
            }
            .navigationTitle("Bans: \(channel.parentId == 0 ? "root channel" : channel.name)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task { bans = await connection.channelBans(channel.id) ?? [] }
        }
    }

    private func remove(_ b: Ban) {
        Task {
            if await connection.unban(b) {
                bans?.removeAll { $0 == b }
                announce("Ban removed")
            }
        }
    }
}

/// A classroom channel: what everyone may send, and who else may.
struct ClassroomView: View {
    @Environment(\.dismiss) private var dismiss
    let connection: ServerConnection
    let channelId: Int32

    var body: some View {
        let channel = connection.snapshot?.channels.first { $0.id == channelId }
        NavigationStack {
            Form {
                if let channel {
                    Section {
                        ForEach(PersonView.streams, id: \.self) { st in
                            Toggle(PersonView.streamLabel(st), isOn: Binding(
                                get: { channel.transmit.contains { $0.userId == 0 && $0.allowed.contains(st) } },
                                set: { connection.setTransmit(channel: channel.id, user: 0, st, $0) }))
                        }
                    } header: {
                        Text("Everyone may")
                    } footer: {
                        Text("Set it for one person from their details.")
                    }
                    let people = channel.transmit.filter { $0.userId != 0 }
                    if !people.isEmpty {
                        Section("Also allowed") {
                            ForEach(people, id: \.userId) { t in
                                let name = connection.snapshot?.users.first { $0.id == t.userId }?.displayName ?? "User \(t.userId)"
                                Text("\(name): \(t.allowed.map(PersonView.streamLabel).joined(separator: ", "))")
                            }
                        }
                    }
                }
            }
            .navigationTitle("Classroom")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}
