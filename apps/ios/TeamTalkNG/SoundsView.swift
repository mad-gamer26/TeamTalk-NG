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
                Button("As they were at first", role: .destructive) { sounds.revert() }
            }
        }
        .navigationTitle("Sounds")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// The catalog of sound packs, to download.
struct CatalogView: View {
    @Environment(AppModel.self) private var model
    @State private var packs: [CatalogPack]?
    @State private var problem: String?
    @State private var busy: String?

    var body: some View {
        List {
            if let problem {
                Text("Couldn't load the sound packs: \(problem)")
                Button("Try again") { Task { await load() } }
            } else if let packs {
                ForEach(packs) { p in row(p) }
            } else {
                ProgressView("Loading the sound packs")
            }
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
