import SwiftUI

extension Channel: Identifiable {}

/// Making a channel, or editing one.
enum ChannelSheet: Identifiable {
    case new(parent: Int32, temporary: Bool)
    case edit(Channel)
    var id: String {
        switch self {
        case .new(let p, let t): "new-\(p)-\(t)"
        case .edit(let c): "edit-\(c.id)"
        }
    }
}

/// Moving someone into a channel.
struct MoveView: View {
    @Environment(\.dismiss) private var dismiss
    let connection: ServerConnection
    let user: User

    var body: some View {
        NavigationStack {
            List {
                ForEach(ChannelTree.rows(connection.snapshot!).compactMap { row -> (Channel, Int)? in
                    if case .channel(let c, let d) = row { (c, d) } else { nil }
                }, id: \.0.id) { c, depth in
                    let name = c.parentId == 0 ? "Root channel" : c.name
                    Button {
                        connection.move(user, to: c)
                        dismiss()
                    } label: {
                        Text(name).padding(.leading, CGFloat(depth) * 16)
                    }
                    .disabled(c.id == user.channelId)
                    .accessibilityLabel(c.id == user.channelId ? "\(name), they're here" : name)
                }
            }
            .navigationTitle("Move \(user.displayName)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }
}

/// The server's bans, each removable.
struct BansView: View {
    @Environment(\.dismiss) private var dismiss
    let connection: ServerConnection
    @State private var bans: [Ban]?
    @State private var byUsername = false
    @State private var address = ""
    @State private var search = ""

    private func matches(_ b: Ban) -> Bool {
        search.isEmpty || [b.username, b.nickname, b.ipAddress].contains { $0.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        NavigationStack {
            List {
                if let bans {
                    if bans.isEmpty { Text("Nobody is banned.").foregroundStyle(.secondary) }
                    ForEach(bans.filter(matches), id: \.self) { b in
                        VStack(alignment: .leading) {
                            Text(title(b))
                            Text(details(b)).font(.caption).foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                        .swipeActions { Button("Remove ban", role: .destructive) { remove(b) } }
                        .accessibilityActions { Button("Remove ban") { remove(b) } }
                    }
                } else {
                    ProgressView("Loading the bans")
                }
            }
            .safeAreaInset(edge: .bottom) {
                VStack(alignment: .leading) {
                    // The desktop's ban type: "Ban IP-address" or "Ban Username".
                    Picker("Ban type", selection: $byUsername) {
                        Text("Ban IP-address").tag(false)
                        Text("Ban Username").tag(true)
                    }
                    .pickerStyle(.menu)
                    TextField(byUsername ? "Username" : "IP-address, like 10.0.0.*", text: $address).accessibilityLabel(byUsername ? "Username" : "IP-address")
                        .textFieldStyle(.roundedBorder)
                        .keyboardType(byUsername ? .default : .numbersAndPunctuation)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("Add") {
                        if byUsername { connection.banUsername(address) } else { connection.banAddress(address) }
                        address = ""
                        Task { try? await Task.sleep(for: .milliseconds(500)); bans = await connection.bans() ?? bans }
                    }
                    .disabled(address.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding()
            }
            .searchable(text: $search, prompt: "Username or address")
            .navigationTitle("Bans")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task { bans = await connection.bans() ?? [] }
        }
    }

    private func title(_ b: Ban) -> String {
        let who = [b.nickname, b.username].first { !$0.isEmpty } ?? b.ipAddress
        return b.byUsername ? "\(who), by account" : "\(who), by IP address \(b.ipAddress)"
    }

    private func details(_ b: Ban) -> String {
        var parts: [String] = []
        if !b.channelPath.isEmpty { parts.append("channel \(b.channelPath)") }
        if !b.time.isEmpty { parts.append(b.time) }
        if !b.owner.isEmpty { parts.append("by \(b.owner)") }
        return parts.joined(separator: ", ")
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
