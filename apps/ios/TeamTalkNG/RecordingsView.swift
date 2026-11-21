import AVFoundation
import SwiftUI

/// The recordings made (Documents/Recordings, with the folders of
/// per-person files), newest first: play, share or delete them (the old
/// app's recordings list).
struct RecordingsView: View {
    @State private var files: [URL] = []
    @State private var previewing: URL?
    @State private var deleting: URL?

    private static var folder: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Recordings", isDirectory: true)
    }

    var body: some View {
        List {
            if files.isEmpty {
                Text("No recordings yet.").foregroundStyle(.secondary)
            }
            ForEach(files, id: \.self) { f in
                Button { previewing = f } label: {
                    VStack(alignment: .leading) {
                        Text(name(f))
                        Text(details(f)).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .foregroundStyle(.primary)
                .accessibilityElement(children: .combine)
                .accessibilityHint("Double-tap to play.")
                .contextMenu {
                    Button("Play") { previewing = f }
                    ShareLink(item: f) { Text("Share") }
                    Button("Delete", role: .destructive) { deleting = f }
                }
                .accessibilityActions {
                    Button("Delete") { deleting = f }
                    Button("Play") { previewing = f }
                }
                .swipeActions { Button("Delete", role: .destructive) { deleting = f } }
            }
        }
        .navigationTitle("Recordings")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: load)
        .refreshable { load() }
        // The app's own player (in TeamTalk NG's audio session).
        .sheet(item: Binding(get: { previewing.map(PlayItem.init) }, set: { previewing = $0?.url })) { item in
            RecordingPlayer(url: item.url, title: name(item.url))
        }
        .confirmationDialog("Delete \(deleting.map(name) ?? "it")?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let f = deleting { try? FileManager.default.removeItem(at: f); announce("Deleted"); load() }
            }
        }
    }

    private func name(_ f: URL) -> String {
        let parent = f.deletingLastPathComponent().lastPathComponent
        return parent == "Recordings" ? f.lastPathComponent : "\(parent): \(f.lastPathComponent)"
    }

    private func details(_ f: URL) -> String {
        let v = try? f.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let size = ByteCountFormatter.string(fromByteCount: Int64(v?.fileSize ?? 0), countStyle: .file)
        return [v?.contentModificationDate?.formatted(date: .abbreviated, time: .shortened), size].compactMap { $0 }.joined(separator: ", ")
    }

    private func load() {
        let fm = FileManager.default
        var all: [URL] = []
        for item in (try? fm.contentsOfDirectory(at: Self.folder, includingPropertiesForKeys: [.isDirectoryKey])) ?? [] {
            if (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                all += (try? fm.contentsOfDirectory(at: item, includingPropertiesForKeys: nil)) ?? []
            } else {
                all.append(item)
            }
        }
        let date = { (u: URL) in (try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast }
        files = all.filter { ["wav", "mp3", "ogg", "m4a"].contains($0.pathExtension.lowercased()) }.sorted { date($0) > date($1) }
    }
}

private struct PlayItem: Identifiable {
    let url: URL
    var id: URL { url }
}

/// Plays a recording in the app's own audio session (mixing with other
/// apps as everything else does): play or pause, 10 seconds back or
/// forward, the position.
struct RecordingPlayer: View {
    let url: URL
    let title: String
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVAudioPlayer?
    @State private var position = 0.0
    @State private var playing = false
    @State private var problem: String?
    private let tick = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    private var duration: Double { player?.duration ?? 0 }

    private func time(_ t: Double) -> String {
        let s = Int(t.rounded())
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    var body: some View {
        NavigationStack {
            Form {
                if let problem {
                    Text(problem)
                } else {
                    Section {
                        Button(playing ? "Pause" : "Play") { toggle() }
                            .font(.title3)
                        HStack {
                            Button("10 seconds back") { seek(by: -10) }
                            Spacer()
                            Button("10 seconds forward") { seek(by: 10) }
                        }
                        .buttonStyle(.borderless)
                        NamedSlider("Position", value: Binding(get: { position }, set: { position = $0; player?.currentTime = $0 }),
                                    in: 0...max(duration, 1), step: duration >= 2 ? 1 : 0.1, spoken: { "\(time($0)) of \(time(duration))" })
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .onAppear(perform: start)
            .onDisappear { player?.stop() }
            .onReceive(tick) { _ in
                guard let p = player else { return }
                position = p.currentTime
                if playing && !p.isPlaying { playing = false }
            }
        }
    }

    private func start() {
        do {
            let p = try AVAudioPlayer(contentsOf: url)
            p.prepareToPlay()
            player = p
            p.play()
            playing = true
        } catch {
            problem = "This recording can't be played: \(error.localizedDescription)"
        }
    }

    private func toggle() {
        guard let p = player else { return }
        if p.isPlaying { p.pause(); playing = false } else { p.play(); playing = true }
    }

    private func seek(by s: Double) {
        guard let p = player else { return }
        p.currentTime = min(max(0, p.currentTime + s), p.duration)
        position = p.currentTime
        announce(time(position))
    }
}
