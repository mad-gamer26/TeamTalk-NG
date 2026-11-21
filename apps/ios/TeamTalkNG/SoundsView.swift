import SwiftUI

/// Settings → Sounds: the pack, volume, and which events sound.
struct SoundsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let sounds = model.sounds
        @Bindable var b = sounds
        Form {
            Section {
                Toggle("Play sounds", isOn: Binding(get: { sounds.enabled }, set: { sounds.enabled = $0 }))
            }
            Section {
                Picker("Sound pack", selection: $b.selectedId) {
                    ForEach(sounds.packs) { Text($0.name).tag($0.id) }
                }
                NavigationLink("Sound packs") { SoundPacksView() }
                NavigationLink("Get sound packs") { CatalogView() }
                Picker("Playback mode", selection: $b.playbackMode) {
                    ForEach(SoundStore.PlaybackMode.allCases) { Text($0.label).tag($0) }
                }
                NamedSlider("Sound volume", value: $b.volume, in: 0...1, step: 0.05, spoken: { "\(Int(($0 * 100).rounded())) percent" })
            } footer: {
                Text("Sound packs: make your own, edit, share, publish, import a desktop client's pack, or delete one.")
            }
            Section {
                ForEach(SoundEvent.allCases) { e in
                    Toggle(e.label, isOn: Binding(get: { sounds.isOn(e) }, set: { sounds.setOn(e, $0) }))
                        .accessibilityActions { Button("Play") { sounds.preview(e) } }
                        .contextMenu { Button("Play") { sounds.preview(e) } }
                }
            } header: {
                Text("Sounds")
            } footer: {
                Text("Each sound's action (swipe up or down with VoiceOver, or touch and hold) plays it. A pack's sounds are chosen in Sound packs.")
            }
            Section {
                Button("Turn all on") { sounds.setAll(true) }
                Button("Turn all off") { sounds.setAll(false) }
                Button("Reset to Default", role: .destructive) { sounds.revert() }
            }
        }
        .navigationTitle("Sound Events")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// The catalog of sound packs, to download.
struct CatalogView: View {
    @Environment(AppModel.self) private var model
    @State private var packs: [CatalogPack]?
    @State private var problem: String?
    @State private var busy: String?
    @State private var reporting: CatalogPack?
    @State private var blocking: CatalogPack?

    static let contact = "mattdovi@icloud.com"
    static let reasons = ["It's offensive or abusive", "It isn't what it says it is", "It uses sounds it has no right to", "Something else"]

    var body: some View {
        List {
            if let problem {
                Text("Couldn't load the sound packs: \(problem)")
                Button("Try again") { Task { await load() } }
            } else if let packs {
                let shown = packs.filter { !model.sounds.isBlocked($0) }
                Section {
                    ForEach(shown) { p in row(p) }
                } footer: {
                    if shown.count < packs.count {
                        Text("Packs by publishers you blocked are hidden.")
                    }
                }
                Section {
                    if !model.sounds.blockedPublishers.isEmpty {
                        NavigationLink("Blocked publishers") { BlockedPublishersView() }
                    }
                    Link("Contact TeamTalk NG", destination: URL(string: "mailto:\(Self.contact)?subject=TeamTalk%20NG%20sound%20packs")!)
                } footer: {
                    Text("Anyone can publish a pack. To report one that's offensive or not what it says, use Report on it (in its actions); to stop seeing someone's packs, block them. Or email \(Self.contact).")
                }
            } else {
                ProgressView("Loading the sound packs")
            }
        }
        .confirmationDialog(reporting.map { "Report \($0.name)?" } ?? "", isPresented: Binding(get: { reporting != nil }, set: { if !$0 { reporting = nil } }), titleVisibility: .visible, presenting: reporting) { p in
            ForEach(Self.reasons, id: \.self) { reason in
                Button(reason) { Task { await report(p, reason) } }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("TeamTalk NG looks at every report within a day, and removes packs that break the rules.")
        }
        .confirmationDialog(blocking.map { "Block \($0.author)?" } ?? "", isPresented: Binding(get: { blocking != nil }, set: { if !$0 { blocking = nil } }), titleVisibility: .visible, presenting: blocking) { p in
            Button("Block", role: .destructive) {
                model.sounds.block(p)
                announce("\(p.author) blocked. Their packs are hidden.")
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Their packs are hidden from the catalog on this iPhone. You can unblock them under Blocked publishers.")
        }
        .navigationTitle("Get sound packs")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func row(_ p: CatalogPack) -> some View {
        let have = model.sounds.installedVersion(of: p)
        let action = have == nil ? "Download" : (have == p.version ? "Download again" : "Update")
        let size = p.size.map { ", " + ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) } ?? ""
        let state = have == nil ? "" : (have == p.version ? ", downloaded" : ", update available")
        return Button {
            Task { await install(p) }
        } label: {
            VStack(alignment: .leading) {
                Text(p.official == true ? "\(p.name) (official)" : p.name)
                Text("By \(p.author)\(size)\(state)").font(.caption).foregroundStyle(.secondary)
                if !p.description.isEmpty {
                    Text(p.description).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .foregroundStyle(.primary)
        .disabled(busy != nil)
        .accessibilityElement(children: .combine)
        .accessibilityHint(busy == p.id ? "Downloading." : "Double-tap to \(action.lowercased()) and use it.")
        .contextMenu {
            Button("Report this pack") { reporting = p }
            if p.official != true { Button("Block \(p.author)", role: .destructive) { blocking = p } }
        }
        // VoiceOver's actions: written in reverse of the menu (the user's order).
        .accessibilityActions {
            if p.official != true { Button("Block \(p.author)") { blocking = p } }
            Button("Report this pack") { reporting = p }
        }
    }

    private func report(_ p: CatalogPack, _ reason: String) async {
        if let problem = await model.sounds.report(p, reason: reason) {
            announce("Couldn't report \(p.name): \(problem)")
        } else {
            announce("\(p.name) reported. Thank you.")
        }
    }

    private func load() async {
        problem = nil
        do { packs = try await model.sounds.catalog() } catch { problem = error.localizedDescription }
    }

    private func install(_ p: CatalogPack) async {
        busy = p.id
        announce("Downloading \(p.name)")
        do {
            try await model.sounds.install(p)
            announce("\(p.name) is downloaded and in use")
            model.sounds.preview(.userJoined)
        } catch {
            announce("Couldn't download \(p.name): \(error.localizedDescription)")
        }
        busy = nil
    }
}

/// Publishers I blocked in the catalog, to unblock.
struct BlockedPublishersView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let blocked = model.sounds.blockedPublishers.sorted { $0.value.localizedStandardCompare($1.value) == .orderedAscending }
        List {
            Section {
                if blocked.isEmpty { Text("Nobody is blocked.") }
                ForEach(blocked, id: \.key) { key, author in
                    Button {
                        model.sounds.unblock(key)
                        announce("\(author) unblocked")
                    } label: {
                        Text(author)
                    }
                    .foregroundStyle(.primary)
                    .accessibilityHint("Double-tap to unblock.")
                }
            } footer: {
                Text("Their packs are hidden from the catalog. Tap one to unblock them.")
            }
        }
        .navigationTitle("Blocked publishers")
        .navigationBarTitleDisplayMode(.inline)
    }
}
