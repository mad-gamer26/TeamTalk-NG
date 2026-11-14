import SwiftUI

/// Settings → Sounds: the pack, volume, and which events sound.
struct SoundsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let sounds = model.sounds
        @Bindable var b = sounds
        Form {
            Section {
                Picker("Sound pack", selection: $b.selectedId) {
                    ForEach(sounds.packs) { Text($0.name).tag($0.id) }
                }
                NavigationLink("Get sound packs") { CatalogView() }
                Slider(value: $b.volume, in: 0...1, step: 0.05) { Text("Sound volume") }
                    .accessibilityValue("\(Int(sounds.volume * 100)) percent")
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
                Text("To hear one, use the Play action (swipe up or down with VoiceOver), or touch and hold.")
            }
            if sounds.installed.isEmpty == false {
                Section("Downloaded packs") {
                    ForEach(sounds.installed) { p in
                        Text(p.version.isEmpty ? "\(p.name), by \(p.author)" : "\(p.name), by \(p.author), version \(p.version)")
                            .swipeActions { Button("Delete", role: .destructive) { sounds.remove(p) } }
                            .accessibilityActions { Button("Delete") { sounds.remove(p) } }
                    }
                }
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
        let size = ByteCountFormatter.string(fromByteCount: Int64(p.size), countStyle: .file)
        let state = have == nil ? "" : (have == p.version ? ", downloaded" : ", update available")
        return Button {
            Task { await install(p) }
        } label: {
            VStack(alignment: .leading) {
                Text(p.official ? "\(p.name) (official)" : p.name)
                Text("By \(p.author), \(size)\(state)").font(.caption).foregroundStyle(.secondary)
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
