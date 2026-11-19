import SwiftUI
import UniformTypeIdentifiers

/// Settings → Sounds → Sound packs: every pack, a new one, importing one.
struct SoundPacksView: View {
    @Environment(AppModel.self) private var model
    @State private var naming = false
    @State private var newName = ""
    @State private var importing = false
    @State private var opened: String?
    @State private var askingLink = false
    @State private var link = ""
    @State private var downloading = false

    var body: some View {
        let sounds = model.sounds
        List {
            Section {
                ForEach(sounds.packs) { p in
                    NavigationLink {
                        SoundPackView(packId: p.id)
                    } label: {
                        Text(p.id == sounds.selectedId ? "\(p.name), \(p.kindText), in use" : "\(p.name), \(p.kindText)")
                    }
                }
            }
            Section {
                Button("New sound pack") { newName = ""; naming = true }
                Button("Import a sound pack") { importing = true }
                Button(downloading ? "Downloading the sound pack" : "Import a sound pack from a link") { link = ""; askingLink = true }
                    .disabled(downloading)
            } footer: {
                Text("A new pack starts with the built-in sounds; choose a file for any of them. A desktop client's pack imports as it is, from its folder, a .zip or a link to a .zip (its sounds have the desktop's names, such as logged_on.wav). Packs from the catalog and the built-in one are edited through a copy.")
            }
        }
        .navigationTitle("Sound packs")
        .navigationDestination(isPresented: Binding(get: { opened != nil }, set: { if !$0 { opened = nil } })) {
            if let opened { SoundPackView(packId: opened) }
        }
        .alert("New sound pack", isPresented: $naming) {
            TextField("Name", text: $newName)
            Button("Make") {
                let p = sounds.createPack(name: newName, author: "")
                announce("\(p.name) made")
                opened = p.id
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Its name.")
        }
        .alert("Import from a link", isPresented: $askingLink) {
            TextField("Link to a .zip", text: $link)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .accessibilityLabel("Link to a .zip")
            Button("Import") {
                downloading = true
                announce("Downloading the sound pack")
                let text = link
                Task {
                    let said = await sounds.importZip(fromLink: text)
                    downloading = false
                    announce(said)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("A link to a sound pack's .zip file, such as one from a website or a Dropbox share.")
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.folder, .zip]) { r in
            guard case .success(let url) = r else { return }
            let isZip = url.pathExtension.lowercased() == "zip"
            announce(isZip ? sounds.importZip(url) : sounds.importPack(from: url))
        }
    }
}

/// One pack: about it, using it, its sounds, and what can be done with it.
struct SoundPackView: View {
    let packId: String
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var author = ""
    @State private var about = ""
    @State private var choosingFor: SoundEvent?
    @State private var picking = false
    @State private var deleting = false
    @State private var copyOpened: String?
    @State private var publishing = false
    @State private var published: OwnPack?
    @State private var busy = false
    @FocusState private var typing: Bool

    var body: some View {
        let sounds = model.sounds
        if let p = sounds.pack(packId) {
            Form {
                aboutSection(p)
                Section {
                    if p.id == sounds.selectedId {
                        Text("In use")
                    } else {
                        Button("Use this pack") { sounds.selectedId = p.id; announce("\(p.name) in use") }
                    }
                }
                soundsSection(p)
                actionsSection(p)
            }
            // Scrolling puts the keyboard away (it hid what's below).
            .scrollDismissesKeyboard(.immediately)
            // The keyboard's Done puts it away (VoiceOver has no other quick way).
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") {
                        typing = false
                        sounds.update(p.id, name: name, author: author, description: about)
                    }
                }
            }
            .navigationTitle(p.name)
            .onAppear { name = p.name; author = p.author; about = p.description ?? "" }
            .task(id: p.id) { if p.kind != .builtIn { published = await model.account.publishedCopy(of: p.id) } }
            // Its own flag: SwiftUI closes the picker (setting this false)
            // before it hands over the file, so the sound it's for must
            // outlive that (it was cleared there, and nothing was saved).
            .fileImporter(isPresented: $picking, allowedContentTypes: [.audio]) { r in
                if case .success(let url) = r, let e = choosingFor {
                    if sounds.setSound(e, in: p, from: url) {
                        announce("\(e.label): \(url.lastPathComponent)")
                        sounds.preview(e, pack: sounds.pack(p.id))
                    } else {
                        announce("That file can't be played")
                    }
                }
                choosingFor = nil
            }
            .confirmationDialog("Delete \(p.name)?", isPresented: $deleting, titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    let id = p.id
                    sounds.remove(p)
                    if p.editable { Task { await model.account.forgetPack(localId: id) } }
                    announce("\(p.name) deleted")
                    dismiss()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(published?.public == true ? "Its sounds go, and it leaves the catalog." : "Its sounds go from this iPhone.")
            }
            .sheet(isPresented: $publishing) {
                PublishPackView(pack: p, published: $published)
            }
            .navigationDestination(isPresented: Binding(get: { copyOpened != nil }, set: { if !$0 { copyOpened = nil } })) {
                if let copyOpened { SoundPackView(packId: copyOpened) }
            }
        } else {
            Text("This pack is gone.").foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private func aboutSection(_ p: InstalledPack) -> some View {
        let sounds = model.sounds
        if p.editable {
            Section {
                TextField("Name", text: $name).accessibilityLabel("Name").focused($typing)
                    .onSubmit { sounds.update(p.id, name: name, author: author, description: about) }
                TextField("Author", text: $author).accessibilityLabel("Author").focused($typing)
                    .onSubmit { sounds.update(p.id, name: name, author: author, description: about) }
                TextField("Description", text: $about, axis: .vertical).accessibilityLabel("Description").focused($typing)
                    .onSubmit { sounds.update(p.id, name: name, author: author, description: about) }
            } header: {
                Text("About")
            } footer: {
                Text("Shown in the catalog if you publish it.")
            }
            .onDisappear { sounds.update(p.id, name: name, author: author, description: about) }
        } else {
            Section("About") {
                LabeledContent("Name", value: p.name)
                if !p.author.isEmpty { LabeledContent("Author", value: p.author) }
                if !p.version.isEmpty { LabeledContent("Version", value: p.version) }
                LabeledContent("Kind", value: p.kindText.capitalized)
            }
        }
    }

    @ViewBuilder private func soundsSection(_ p: InstalledPack) -> some View {
        let sounds = model.sounds
        let _ = sounds.packEdited
        Section {
            ForEach(SoundEvent.allCases) { e in
                let own = p.kind == .builtIn || sounds.packFile(e, in: p) != nil
                let where_ = p.kind == .builtIn ? "built in" : (own ? "from this pack" : "the built-in sound")
                Button { sounds.preview(e, pack: p) } label: {
                    Text("\(e.label), \(where_)").frame(maxWidth: .infinity, alignment: .leading)
                }
                .accessibilityHint("Plays it.")
                .contextMenu {
                    Button("Play") { sounds.preview(e, pack: p) }
                    if p.editable { Button("Choose a sound file") { choosingFor = e; picking = true } }
                    if p.editable && own { Button("Use the built-in sound") { sounds.removeSound(e, in: p) } }
                }
                // The menu's items as VoiceOver actions, reversed (the owner's rule).
                .accessibilityActions {
                    if p.editable && own { Button("Use the built-in sound") { sounds.removeSound(e, in: p) } }
                    if p.editable { Button("Choose a sound file") { choosingFor = e; picking = true } }
                    Button("Play") { sounds.preview(e, pack: p) }
                }
            }
        } header: {
            Text("Sounds")
        } footer: {
            Text(p.editable
                 ? "Tap a sound to play it. Its actions (swipe up or down with VoiceOver, or touch and hold): play it, choose a sound file for it, or use the built-in sound."
                 : "Tap a sound to play it. To change them, make an editable copy.")
        }
    }

    @ViewBuilder private func actionsSection(_ p: InstalledPack) -> some View {
        let sounds = model.sounds
        Section {
            if !p.editable, let mine = published {
                // My own pack, downloaded from the catalog: edited as my pack
                // again (tied to the published one, so updating it updates
                // that one), not a stranger's copy.
                Button("Edit my pack") {
                    if sounds.pack(mine.localId) == nil {
                        let c = sounds.duplicate(p, name: p.name, id: mine.localId)
                        sounds.update(c.id, name: mine.name, author: mine.author, description: mine.description)
                    }
                    announce("\(p.name), yours to edit")
                    copyOpened = mine.localId
                }
            } else {
                Button(p.editable ? "Duplicate" : "Make an editable copy") {
                    let c = sounds.duplicate(p, name: p.editable ? "\(p.name) copy" : "\(p.name) (my copy)")
                    announce("\(c.name) made")
                    copyOpened = c.id
                }
            }
            Button("Export and share") {
                if let zip = sounds.exportZip(p) { presentShareSheet([zip]) } else { announce("The pack couldn't be exported") }
            }
            if p.editable {
                Button(published?.public == true ? "Update it in the catalog" : "Publish to the catalog") { publishing = true }
            }
            if published?.public == true {
                Button("Withdraw from the catalog") {
                    busy = true
                    Task {
                        let problem = await model.account.withdraw(localId: p.id)
                        published = await model.account.publishedCopy(of: p.id)
                        busy = false
                        announce(problem ?? "\(p.name) is out of the catalog")
                    }
                }
            }
            if p.kind != .builtIn {
                Button("Delete sound pack", role: .destructive) { deleting = true }
            }
        } footer: {
            if p.editable {
                Text(published?.public == true
                     ? "In the catalog\(published.map { $0.installs > 0 ? ", installed \($0.installs) times" : "" } ?? "")."
                     : "Publishing puts it in the TeamTalk NG catalog for everyone, under the name and author you give (you need to be signed in to NG Account).")
            } else if let mine = published, mine.public {
                Text("Yours in the catalog (your NG Account)\(mine.installs > 0 ? ", installed \(mine.installs) times" : ""). To change its sounds, edit your pack, then update it in the catalog.")
            } else {
                Text("Export and share makes a .zip with the desktop's file names, which a desktop client or TeamTalk NG imports.")
            }
        }
        .disabled(busy)
    }
}

/// Publishing (or updating) one of my packs in the catalog.
private struct PublishPackView: View {
    let pack: InstalledPack
    @Binding var published: OwnPack?
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var author = ""
    @State private var about = ""
    @State private var busy = false
    @State private var problem: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name).accessibilityLabel("Name")
                    TextField("Author", text: $author).accessibilityLabel("Author")
                    TextField("Description", text: $about, axis: .vertical).accessibilityLabel("Description")
                } footer: {
                    Text(model.account.email == nil
                         ? "Sign in to NG Account first (Settings → NG Account)."
                         : "Everyone can find and install it from the catalog, with this name and author. Its sounds are sent from this iPhone; publishing again sends what changed.")
                }
                if let problem { Section { Text(problem) } }
            }
            .navigationTitle(published?.public == true ? "Update in the catalog" : "Publish to the catalog")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(published?.public == true ? "Update" : "Publish") {
                        busy = true
                        let sounds = model.sounds
                        sounds.update(pack.id, name: name, author: author, description: about)
                        let files = sounds.soundFiles(sounds.pack(pack.id) ?? pack)
                        Task {
                            problem = await model.account.publish(localId: pack.id, files: files, name: name, author: author, description: about)
                            published = await model.account.publishedCopy(of: pack.id)
                            busy = false
                            if problem == nil { announce("\(name) is in the catalog"); dismiss() } else { announce(problem!) }
                        }
                    }
                    .disabled(busy || model.account.email == nil || name.trimmingCharacters(in: .whitespaces).isEmpty
                              || author.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear { name = pack.name; author = pack.author; about = pack.description ?? "" }
        }
    }
}
