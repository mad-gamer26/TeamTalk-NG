import SwiftUI

/// The Monitor: servers it watches, their conversations and events.
struct MonitorListView: View {
    @Environment(AppModel.self) private var model
    @State private var adding = false

    var body: some View {
        let monitor = model.monitor
        List {
            Section {
                if monitor.servers.isEmpty && !monitor.loading {
                    Text("The Monitor stays logged in to your servers while TeamTalk NG isn't, keeps your private messages, and tells you what happened. Add a server to start.")
                        .foregroundStyle(.secondary)
                }
                ForEach(monitor.servers, id: \.id) { s in
                    NavigationLink {
                        MonitorServerView(serverId: s.id)
                    } label: {
                        VStack(alignment: .leading) {
                            Text(s.name).font(.headline)
                            Text(details(s)).font(.subheadline).foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                    }
                    .swipeActions { Button("Stop monitoring", role: .destructive) { Task { await monitor.remove(s) } } }
                    .accessibilityActions { Button("Stop monitoring") { Task { await monitor.remove(s) } } }
                }
            } footer: {
                if let p = monitor.problem { Text(p) }
            }
            if !monitor.events.isEmpty {
                Section("Recent") {
                    ForEach(monitor.events.suffix(30).reversed(), id: \.seq) { e in
                        EventRow(event: e, server: monitor.servers.first { $0.id == e.serverId }?.name)
                    }
                }
            }
        }
        .navigationTitle("Monitor")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Add a server", systemImage: "plus") { adding = true }
            }
        }
        .refreshable { await monitor.refresh() }
        .task { await monitor.refresh() }
        .onAppear { monitor.startFollowing() }
        .onDisappear { monitor.stopFollowing() }
        .sheet(isPresented: $adding) { AddMonitorView() }
    }

    private func details(_ s: MonitorServer) -> String {
        var parts = [s.statusText]
        if s.status == "logged_in" { parts.append(s.userCount == 1 ? "1 person" : "\(s.userCount) people") }
        if s.unreadPrivateMessages > 0 { parts.append("\(s.unreadPrivateMessages) unread") }
        return parts.joined(separator: ", ")
    }
}

private struct EventRow: View {
    let event: MonitorEvent
    let server: String?

    var body: some View {
        let time = Date(timeIntervalSince1970: TimeInterval(event.time) / 1000)
        VStack(alignment: .leading, spacing: 2) {
            Text(event.text)
            Text([server, time.formatted(date: .abbreviated, time: .shortened)].compactMap { $0 }.joined(separator: ", "))
                .font(.caption).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Choosing a saved server to monitor.
private struct AddMonitorView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var busy: UUID?
    @State private var problem: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    let candidates = model.servers.filter { model.monitor.monitor(of: $0) == nil }
                    if candidates.isEmpty {
                        Text("Every saved server is already monitored, or there are none. Add servers on the Servers screen.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(candidates) { s in
                        Button {
                            busy = s.id
                            Task {
                                problem = await model.monitor.add(s)
                                busy = nil
                                if problem == nil { announce("Monitoring \(s.title)"); dismiss() } else { announce(problem!) }
                            }
                        } label: {
                            VStack(alignment: .leading) {
                                Text(s.title)
                                Text(s.username.isEmpty ? s.host : "\(s.username) on \(s.host)").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .disabled(busy != nil)
                    }
                } footer: {
                    Text("The Monitor logs in with the server's saved account. Use one it may stay logged in with.")
                }
                if let problem { Section { Text(problem) } }
            }
            .navigationTitle("Monitor a server")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }
}

/// One monitored server: conversations, who's there, what happened.
struct MonitorServerView: View {
    @Environment(AppModel.self) private var model
    let serverId: Int64
    @State private var view: MonitorView?
    @State private var conversations: [MonitorConversation] = []

    var body: some View {
        let monitor = model.monitor
        let server = monitor.servers.first { $0.id == serverId }
        List {
            if let server {
                Section {
                    Text(server.statusText)
                    Toggle("Monitoring", isOn: Binding(get: { server.enabled }, set: { on in Task { await monitor.setEnabled(server, on) } }))
                }
            }
            Section("Private conversations") {
                if conversations.isEmpty { Text("None yet.").foregroundStyle(.secondary) }
                ForEach(conversations, id: \.id) { c in
                    NavigationLink {
                        MonitorConversationView(serverId: serverId, conversation: c)
                    } label: {
                        VStack(alignment: .leading) {
                            Text(c.nickname.isEmpty ? c.username : c.nickname).font(.headline)
                            Text(summary(c)).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
            if let view {
                Section(view.users.count == 1 ? "1 person on the server" : "\(view.users.count) people on the server") {
                    ForEach(view.users.filter { $0.id != view.myUserId }, id: \.id) { u in
                        let channel = view.channels.first { $0.id == u.channelId }?.path
                        Text([u.displayName, channel.map { "in \($0)" }, u.statusMsg.isEmpty ? nil : u.statusMsg].compactMap { $0 }.joined(separator: ", "))
                    }
                }
            }
            let mine = monitor.events.filter { $0.serverId == serverId }
            if !mine.isEmpty {
                Section("Recent") {
                    ForEach(mine.suffix(50).reversed(), id: \.seq) { e in EventRow(event: e, server: nil) }
                }
            }
        }
        .navigationTitle(server?.name ?? "Monitor")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task { await load() }
        .onChange(of: monitor.events.count) { Task { await load() } }
    }

    private func summary(_ c: MonitorConversation) -> String {
        var parts: [String] = []
        if c.unread > 0 { parts.append("\(c.unread) unread") }
        if !c.lastText.isEmpty { parts.append(c.lastOutgoing ? "You: \(c.lastText)" : c.lastText) }
        if !c.active { parts.append("ended") }
        return parts.joined(separator: ", ")
    }

    private func load() async {
        let id = serverId
        if case .success(let v)? = await model.monitor.call({ try $0.view(serverId: id) }) { view = v }
        if case .success(let c)? = await model.monitor.call({ try $0.conversations(serverId: id) }) {
            conversations = c.sorted { $0.lastTime > $1.lastTime }
        }
    }
}

/// A private conversation through the Monitor.
struct MonitorConversationView: View {
    @Environment(AppModel.self) private var model
    let serverId: Int64
    let conversation: MonitorConversation
    @State private var messages: [MonitorMessage] = []
    @State private var draft = ""

    var body: some View {
        let name = conversation.nickname.isEmpty ? conversation.username : conversation.nickname
        VStack(spacing: 0) {
            List(messages, id: \.id) { m in
                let time = Date(timeIntervalSince1970: TimeInterval(m.time) / 1000)
                VStack(alignment: .leading, spacing: 2) {
                    Text(m.outgoing ? "You" : name).font(.caption.weight(.semibold))
                    Text(m.text)
                    Text(time.formatted(date: .abbreviated, time: .shortened)).font(.caption2).foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }
            .listStyle(.plain)
            if conversation.active {
                HStack {
                    TextField("Message \(name)", text: $draft, axis: .vertical).accessibilityLabel("Message \(name)")
                        .textFieldStyle(.roundedBorder)
                    Button("Send") { send() }
                        .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .padding()
            } else {
                Text("\(name) logged out, so this conversation has ended.")
                    .foregroundStyle(.secondary)
                    .padding()
            }
        }
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .onChange(of: model.monitor.events.count) { Task { await load() } }
    }

    private func load() async {
        let (s, c) = (serverId, conversation.id)
        if case .success(let m)? = await model.monitor.call({ try $0.messages(serverId: s, conversationId: c, before: nil) }) {
            messages = m
            await model.monitor.call { try $0.markRead(serverId: s, conversationId: c) }
        }
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        draft = ""
        let (s, c, u) = (serverId, conversation.id, conversation.userId)
        Task {
            let r = await model.monitor.call {
                try $0.sendMessage(serverId: s, to: .user(userId: u, conversationId: c), text: text)
            }
            if case .failure(let e)? = r { announce("Couldn't send: \(NGAccountStore.words(e))") } else { await load() }
        }
    }
}
