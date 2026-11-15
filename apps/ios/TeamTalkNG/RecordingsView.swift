import QuickLook
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
        .quickLookPreview($previewing, in: files)
        // Quick Look's player leaves the audio session its own way.
        .onChange(of: previewing) { if previewing == nil { AudioSession.activate() } }
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
