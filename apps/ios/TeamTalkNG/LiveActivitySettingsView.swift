import SwiftUI

/// Settings → Live Activities: whether they show, for which servers, every
/// part they show, their buttons and order, the Dynamic Island, and what
/// happens after disconnecting.
struct LiveActivitySettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var live = LiveActivities.shared

    var body: some View {
        @Bindable var live = live
        Form {
            Section {
                Toggle("Show Live Activities", isOn: $live.enabled)
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("While you're connected, a server's Live Activity shows on the Lock Screen and in the Dynamic Island, with your buttons. Tap it to open the server.")
                    if !live.allowedBySystem {
                        Text("Live Activities are turned off for TeamTalk NG in the iPhone's Settings app.")
                    }
                    Text(live.showing.isEmpty ? "None showing now." : "Showing now: \(live.showing.joined(separator: ", ")).")
                }
            }
            if live.enabled {
                Section("Servers") {
                    Picker("Show for", selection: $live.allServers) {
                        Text("Every server").tag(true)
                        Text("Only the servers I choose").tag(false)
                    }
                    if !live.allServers {
                        if model.servers.isEmpty { Text("No servers yet.").foregroundStyle(.secondary) }
                        ForEach(model.servers) { s in
                            Toggle(s.title, isOn: Binding(
                                get: { live.chosen.contains(s.id.uuidString) },
                                set: { if $0 { live.chosen.insert(s.id.uuidString) } else { live.chosen.remove(s.id.uuidString) } }))
                        }
                    }
                }
                Section {
                    ForEach(LiveItem.allCases) { item in
                        Toggle(item.label, isOn: Binding(
                            get: { live.layout.shown.contains(item) },
                            set: { on in
                                if on { live.layout.shown.append(item) } else { live.layout.shown.removeAll { $0 == item } }
                            }))
                    }
                } header: {
                    Text("What it shows")
                } footer: {
                    Text("The Lock Screen and the expanded Dynamic Island show these, in this order.")
                }
                Section("How it shows them") {
                    Picker("Who's talking", selection: $live.layout.talkingStyle) {
                        ForEach(LiveTalkingStyle.allCases) { Text($0.label).tag($0) }
                    }
                    Picker("Messages", selection: $live.layout.messageText) {
                        ForEach(LiveMessageText.allCases) { Text($0.label).tag($0) }
                    }
                }
                buttonsSection
                Section {
                    Picker("Left of the camera", selection: $live.layout.compactLeading) {
                        ForEach(LiveGlance.allCases) { Text($0.label).tag($0) }
                    }
                    Picker("Right of the camera", selection: $live.layout.compactTrailing) {
                        ForEach(LiveGlance.allCases) { Text($0.label).tag($0) }
                    }
                    Picker("When another app's activity shares the island", selection: $live.layout.minimal) {
                        ForEach(LiveGlance.allCases) { Text($0.label).tag($0) }
                    }
                } header: {
                    Text("Dynamic Island")
                } footer: {
                    Text("What the small Dynamic Island shows on each side of the camera. Touching and holding it shows everything, with your buttons.")
                }
                Section("After disconnecting") {
                    Picker("The Live Activity", selection: $live.afterDisconnect) {
                        ForEach(LiveAfterDisconnect.allCases) { Text($0.label).tag($0) }
                    }
                }
                Section {
                    Button("Reset Live Activity settings", role: .destructive) { live.reset() }
                }
            }
        }
        .navigationTitle("Live Activities")
    }

    @ViewBuilder private var buttonsSection: some View {
        let buttons = live.layout.buttons
        Section {
            if buttons.isEmpty { Text("No buttons.").foregroundStyle(.secondary) }
            ForEach(Array(buttons.enumerated()), id: \.element) { i, b in
                let first = i == 0, last = i == buttons.count - 1
                Menu {
                    if !first { Button("Move Up") { move(b, by: -1) } }
                    if !last { Button("Move Down") { move(b, by: 1) } }
                    Button("Remove", role: .destructive) { live.layout.buttons.removeAll { $0 == b } }
                } label: {
                    Text(b.label).frame(maxWidth: .infinity, alignment: .leading)
                }
                .accessibilityLabel(b.label)
                .accessibilityValue("\(i + 1) of \(buttons.count)")
                // The menu's items as VoiceOver actions, reversed (the owner's rule).
                .accessibilityActions {
                    Button("Remove") { live.layout.buttons.removeAll { $0 == b } }
                    if !last { Button("Move Down") { move(b, by: 1) } }
                    if !first { Button("Move Up") { move(b, by: -1) } }
                }
            }
            let left = LiveButton.allCases.filter { !buttons.contains($0) }
            if buttons.count < LiveLayout.maxButtons {
                ForEach(left) { b in
                    Button("Add \(b.label)") { live.layout.buttons.append(b) }
                }
            }
            Picker("Button labels", selection: $live.layout.buttonStyle) {
                ForEach(LiveButtonStyle.allCases) { Text($0.label).tag($0) }
            }
        } header: {
            Text("Buttons")
        } footer: {
            Text("Up to \(LiveLayout.maxButtons), in this order. Each acts on that Live Activity's server.")
        }
    }

    private func move(_ b: LiveButton, by step: Int) {
        guard let i = live.layout.buttons.firstIndex(of: b) else { return }
        let j = i + step
        guard live.layout.buttons.indices.contains(j) else { return }
        live.layout.buttons.swapAt(i, j)
    }
}
