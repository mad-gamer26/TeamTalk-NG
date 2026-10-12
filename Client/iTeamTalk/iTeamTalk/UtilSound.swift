/*
 * Copyright (c) 2005-2018, BearWare.dk
 *
 * Contact Information:
 *
 * Bjoern D. Rasmussen
 * Kirketoften 5
 * DK-8260 Viby J
 * Denmark
 * Email: contact@bearware.dk
 * Phone: +45 20 20 54 59
 * Web: http://www.bearware.dk
 *
 * This source code is part of the TeamTalk SDK owned by
 * BearWare.dk. Use of this file, or its compiled unit, requires a
 * TeamTalk SDK License Key issued by BearWare.dk.
 *
 * The TeamTalk SDK License Agreement along with its Terms and
 * Conditions are outlined in the file License.txt included with the
 * TeamTalk SDK distribution.
 *
 */

import Foundation
import AVFoundation

func refVolume(_ percent: Double) -> Int {
    //82.832*EXP(0.0508*x) - 50
    if percent == 0 {
        return 0
    }
    
    let d = 82.832 * exp(0.0508 * percent) - 50
    return Int(d)
}

func refVolumeToPercent(_ volume: Int) -> Int {
    if(volume == 0) {
        return 0
    }
    
    let d = (Double(volume) + 50.0) / 82.832
    let d1 = (log(d) / 0.0508) + 0.5
    return Int(d1)
}

enum Sounds : Int, CaseIterable {
    case tx_ON = 1,
         tx_OFF = 2,
         chan_MSG = 3,
         broadcast_MSG = 4,
         user_MSG = 5,
         srv_LOST = 6,
         joined_CHAN = 7,
         left_CHAN = 8,
         transmit_ON = 11,
         transmit_OFF = 12,
         logged_IN = 13,
         logged_OUT = 14,
         intercept_START = 15,
         intercept_END = 16,
         file_UPDATE = 17,
         filetx_COMPLETE = 18
}

extension Sounds {
    var defaultSoundName: String {
        switch self {
        case .tx_ON: return "on"
        case .tx_OFF: return "off"
        case .chan_MSG: return "channel_msg"
        case .broadcast_MSG: return "broadcast_msg"
        case .user_MSG: return "user_msg"
        case .srv_LOST: return "serverlost"
        case .joined_CHAN: return "newuser"
        case .left_CHAN: return "removeuser"
        case .transmit_ON: return "txqueue_start"
        case .transmit_OFF: return "txqueue_stop"
        case .logged_IN: return "logged_on"
        case .logged_OUT: return "logged_off"
        case .intercept_START: return "intercept"
        case .intercept_END: return "interceptEnd"
        case .file_UPDATE: return "fileupdate"
        case .filetx_COMPLETE: return "filetx_complete"
        }
    }

    var compatibleSoundNames: [String] {
        return [defaultSoundName]
    }

    var previewSequence: [Sounds] {
        return [self]
    }

    var title: String {
        switch self {
        case .tx_ON: return NSLocalizedString("Voice Transmission On", comment: "sound pack")
        case .tx_OFF: return NSLocalizedString("Voice Transmission Off", comment: "sound pack")
        case .chan_MSG: return NSLocalizedString("Channel Text Message", comment: "sound pack")
        case .broadcast_MSG: return NSLocalizedString("Broadcast Text Message", comment: "sound pack")
        case .user_MSG: return NSLocalizedString("Private Text Message", comment: "sound pack")
        case .srv_LOST: return NSLocalizedString("Server Connection Lost", comment: "sound pack")
        case .joined_CHAN: return NSLocalizedString("User Joins Channel", comment: "sound pack")
        case .left_CHAN: return NSLocalizedString("User Leaves Channel", comment: "sound pack")
        case .transmit_ON: return NSLocalizedString("Exclusive Mode On", comment: "sound pack")
        case .transmit_OFF: return NSLocalizedString("Exclusive Mode Off", comment: "sound pack")
        case .logged_IN: return NSLocalizedString("User Logged In", comment: "sound pack")
        case .logged_OUT: return NSLocalizedString("User Logged Out", comment: "sound pack")
        case .intercept_START: return NSLocalizedString("Interception Started", comment: "sound pack")
        case .intercept_END: return NSLocalizedString("Interception Ended", comment: "sound pack")
        case .file_UPDATE: return NSLocalizedString("Channel File Updated", comment: "sound pack")
        case .filetx_COMPLETE: return NSLocalizedString("File Transfer Complete", comment: "sound pack")
        }
    }
}

extension Notification.Name {
    /// Sound packs were added, changed, removed or chosen.
    static let soundPacksChanged = Notification.Name("SoundPacksChanged")
}

struct RemoteSoundPack: Codable, Hashable {
    let id: String
    let name: String
    let author: String
    let description: String?
    let version: String
    let downloadURL: URL
    /// Made by TeamTalk NG (the catalog lists these first).
    var official: Bool? = nil

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case author
        case description
        case version
        case downloadURL = "download_url"
        case official
    }
}

struct RemoteSoundPackCatalog: Codable, Hashable {
    let packs: [RemoteSoundPack]
}

struct SoundPack: Codable, Hashable {
    let id: String
    var name: String
    var author: String?
    var createdAt: Date
    var catalogID: String?
    var version: String?

    var isDefault: Bool {
        return id == SoundPackStore.defaultSoundPackID
    }
}

final class SoundPackStore {
    static let shared = SoundPackStore()
    static let defaultSoundPackID = "default"

    private let selectedSoundPackIDKey = "settings.selectedSoundPackID"
    private let metadataFilename = "metadata.json"
    private let supportedExtensions = ["mp3", "wav", "caf", "aiff", "aif", "m4a", "aac"]
    private let fileManager = FileManager.default
    private(set) var customPacks = [SoundPack]()
    private(set) var selectedPackID: String

    var defaultPack: SoundPack {
        return SoundPack(id: SoundPackStore.defaultSoundPackID,
                         name: NSLocalizedString("Default", comment: "sound pack"),
                         author: nil,
                         createdAt: Date.distantPast,
                         catalogID: nil,
                         version: nil)
    }

    var allPacks: [SoundPack] {
        return [defaultPack] + customPacks
    }

    var selectedPack: SoundPack {
        return pack(for: selectedPackID) ?? defaultPack
    }

    private init() {
        selectedPackID = UserDefaults.standard.string(forKey: selectedSoundPackIDKey) ?? SoundPackStore.defaultSoundPackID
        load()
    }

    func selectPack(_ packID: String) {
        storeSelection(packID)
        // Monitor notifications follow the selected pack.
        MonitorNotificationSounds.refresh()
        NotificationCenter.default.post(name: .soundPacksChanged, object: nil)
    }

    /// Remember the selected pack without side effects. load() runs while
    /// `shared` is being created, so anything it calls must not reach
    /// `SoundPackStore.shared` again (re-entering its initialization traps).
    private func storeSelection(_ packID: String) {
        selectedPackID = pack(for: packID)?.id ?? SoundPackStore.defaultSoundPackID
        UserDefaults.standard.set(selectedPackID, forKey: selectedSoundPackIDKey)
    }

    var soundPacksDirectoryURL: URL {
        packsRootURL()
    }

    func reloadFromDisk() {
        load()
        MonitorNotificationSounds.refresh()
    }

    func pack(for packID: String) -> SoundPack? {
        if packID == SoundPackStore.defaultSoundPackID {
            return defaultPack
        }
        return customPacks.first { $0.id == packID }
    }

    func createPack(named name: String) throws -> SoundPack {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            throw SoundPackError.invalidName
        }

        let pack = SoundPack(id: UUID().uuidString,
                             name: trimmedName,
                             author: nil,
                             createdAt: Date(),
                             catalogID: nil,
                             version: nil)
        try fileManager.createDirectory(at: packDirectoryURL(for: pack.id), withIntermediateDirectories: true)
        customPacks.append(pack)
        sortPacks()
        try save()
        selectPack(pack.id)
        return pack
    }

    func renamePack(_ packID: String, to name: String) throws {
        guard packID != SoundPackStore.defaultSoundPackID else {
            throw SoundPackError.defaultPackImmutable
        }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            throw SoundPackError.invalidName
        }
        guard let index = customPacks.firstIndex(where: { $0.id == packID }) else {
            throw SoundPackError.packNotFound
        }

        customPacks[index].name = trimmedName
        sortPacks()
        try save()
    }

    func deletePack(_ packID: String) throws {
        guard packID != SoundPackStore.defaultSoundPackID else {
            throw SoundPackError.defaultPackImmutable
        }
        customPacks.removeAll { $0.id == packID }
        try? fileManager.removeItem(at: packDirectoryURL(for: packID))
        if selectedPackID == packID {
            selectPack(SoundPackStore.defaultSoundPackID)
        }
        try save()
    }

    func deleteAllCustomPacks() throws {
        for pack in customPacks {
            try? fileManager.removeItem(at: packDirectoryURL(for: pack.id))
        }
        customPacks = []
        selectPack(SoundPackStore.defaultSoundPackID)
        try save()
    }

    func installedPack(catalogID: String) -> SoundPack? {
        return customPacks.first { $0.catalogID == catalogID }
    }

    func updatesAvailable(in catalogPacks: [RemoteSoundPack]) -> [RemoteSoundPack] {
        return catalogPacks.filter { remotePack in
            guard let installedPack = installedPack(catalogID: remotePack.id) else {
                return false
            }
            return installedPack.version != remotePack.version
        }
    }

    func exportPackArchive(for packID: String) throws -> URL {
        guard packID != SoundPackStore.defaultSoundPackID else {
            throw SoundPackError.defaultPackImmutable
        }
        guard let pack = pack(for: packID) else {
            throw SoundPackError.packNotFound
        }

        var entries = [ZIPArchiveEntry]()
        for sound in Sounds.allCases {
            guard let url = customSoundURL(for: sound, packID: pack.id) else {
                continue
            }
            entries.append(ZIPArchiveEntry(filename: sound.defaultSoundName + "." + url.pathExtension.lowercased(),
                                           data: try Data(contentsOf: url)))
        }

        let archiveURL = try temporaryExportURL(baseName: pack.name, fileExtension: "zip")
        try ZIPArchive.write(entries: entries, to: archiveURL)
        return archiveURL
    }

    func importPackArchive(from archiveURL: URL) throws -> SoundPack {
        let access = archiveURL.startAccessingSecurityScopedResource()
        defer {
            if access {
                archiveURL.stopAccessingSecurityScopedResource()
            }
        }

        let importedName = archiveURL.deletingPathExtension().lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !importedName.isEmpty else {
            throw SoundPackError.invalidName
        }
        let entryLookup = try supportedSoundEntries(from: ZIPArchive.read(from: archiveURL))
        let pack = SoundPack(id: UUID().uuidString,
                             name: uniquePackName(for: importedName),
                             author: nil,
                             createdAt: Date(),
                             catalogID: nil,
                             version: nil)
        try writeImportedPack(pack, entries: entryLookup)
        customPacks.append(pack)
        sortPacks()
        try save()
        selectPack(pack.id)
        return pack
    }

    func importCatalogPackArchive(from archiveURL: URL, remotePack: RemoteSoundPack, selectAfterImport: Bool = true) throws -> SoundPack {
        let access = archiveURL.startAccessingSecurityScopedResource()
        defer {
            if access {
                archiveURL.stopAccessingSecurityScopedResource()
            }
        }

        let entryLookup = try supportedSoundEntries(from: ZIPArchive.read(from: archiveURL))
        let existingPack = installedPack(catalogID: remotePack.id)
        let packID = existingPack?.id ?? UUID().uuidString
        let pack = SoundPack(id: packID,
                             name: remotePack.name,
                             author: remotePack.author,
                             createdAt: existingPack?.createdAt ?? Date(),
                             catalogID: remotePack.id,
                             version: remotePack.version)
        try writeImportedPack(pack, entries: entryLookup)
        if let index = customPacks.firstIndex(where: { $0.id == packID }) {
            customPacks[index] = pack
        } else {
            customPacks.append(pack)
        }
        sortPacks()
        try save()
        if selectAfterImport {
            selectPack(pack.id)
        }
        return pack
    }

    func hasCustomSounds(in packID: String) -> Bool {
        return Sounds.allCases.contains { hasCustomSound($0, in: packID) }
    }

    func hasCustomSound(_ sound: Sounds, in packID: String) -> Bool {
        return customSoundURL(for: sound, packID: packID) != nil
    }

    func soundURL(for sound: Sounds, packID: String? = nil) -> URL? {
        let resolvedPackID = packID ?? selectedPackID
        if let customURL = customSoundURL(for: sound, packID: resolvedPackID) {
            return customURL
        }
        return Bundle.main.url(forResource: sound.defaultSoundName, withExtension: "wav")
    }

    func replaceSound(_ sound: Sounds, in packID: String, with sourceURL: URL) throws {
        guard packID != SoundPackStore.defaultSoundPackID else {
            throw SoundPackError.defaultPackImmutable
        }
        guard pack(for: packID) != nil else {
            throw SoundPackError.packNotFound
        }

        let access = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if access {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        let directoryURL = packDirectoryURL(for: packID)
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        removeCustomSound(sound, in: packID)

        let fileExtension = sourceURL.pathExtension.isEmpty ? "wav" : sourceURL.pathExtension.lowercased()
        let destinationURL = directoryURL.appendingPathComponent(sound.defaultSoundName).appendingPathExtension(fileExtension)
        try fileManager.copyItem(at: sourceURL, to: destinationURL)
        MonitorNotificationSounds.refresh()
        NotificationCenter.default.post(name: .soundPacksChanged, object: nil)
    }

    func resetSound(_ sound: Sounds, in packID: String) throws {
        guard packID != SoundPackStore.defaultSoundPackID else {
            throw SoundPackError.defaultPackImmutable
        }
        removeCustomSound(sound, in: packID)
        MonitorNotificationSounds.refresh()
        NotificationCenter.default.post(name: .soundPacksChanged, object: nil)
    }

    func fetchCatalog(completion: @escaping (Result<[RemoteSoundPack], Error>) -> Void) {
        Task { @MainActor in
            do {
                completion(.success(try await self.catalog()))
            } catch {
                completion(.failure(error))
            }
        }
    }

    func downloadCatalogPack(_ pack: RemoteSoundPack, completion: @escaping (Result<URL, Error>) -> Void) {
        URLSession.shared.downloadTask(with: pack.downloadURL) { location, response, error in
            if let error = error {
                DispatchQueue.main.async {
                    completion(.failure(error))
                }
                return
            }
            guard let httpResponse = response as? HTTPURLResponse else {
                DispatchQueue.main.async {
                    completion(.failure(SoundPackError.invalidCatalogResponse))
                }
                return
            }
            guard (200...299).contains(httpResponse.statusCode) else {
                DispatchQueue.main.async {
                    completion(.failure(SoundPackError.catalogUnavailable(statusCode: httpResponse.statusCode)))
                }
                return
            }
            guard let location = location else {
                DispatchQueue.main.async {
                    completion(.failure(SoundPackError.invalidCatalogResponse))
                }
                return
            }
            do {
                let archiveURL = self.temporaryNamedFileURL(baseName: UUID().uuidString, fileExtension: "zip")
                if self.fileManager.fileExists(atPath: archiveURL.path) {
                    try self.fileManager.removeItem(at: archiveURL)
                }
                try self.fileManager.copyItem(at: location, to: archiveURL)
                DispatchQueue.main.async {
                    completion(.success(archiveURL))
                }
            } catch {
                DispatchQueue.main.async {
                    completion(.failure(error))
                }
            }
        }.resume()
    }

    private func removeCustomSound(_ sound: Sounds, in packID: String) {
        for soundName in sound.compatibleSoundNames {
            for fileExtension in supportedExtensions {
                let url = packDirectoryURL(for: packID).appendingPathComponent(soundName).appendingPathExtension(fileExtension)
                if fileManager.fileExists(atPath: url.path) {
                    try? fileManager.removeItem(at: url)
                }
            }
        }
    }

    /// Note a catalog pack's new version (its owner just published one).
    func setVersion(_ version: String, for packID: String) throws {
        guard let index = customPacks.firstIndex(where: { $0.id == packID }), customPacks[index].version != version else { return }
        customPacks[index].version = version
        try save()
    }

    /// Put one sound (by file name, such as `logged_on.wav`) into a pack,
    /// replacing whatever that sound was.
    func writeSound(_ data: Data, fileName: String, in packID: String) throws {
        let stem = (fileName as NSString).deletingPathExtension
        guard let sound = Sounds.allCases.first(where: { $0.defaultSoundName == stem }) else { return }
        let directoryURL = packDirectoryURL(for: packID)
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        removeCustomSound(sound, in: packID)
        try data.write(to: directoryURL.appendingPathComponent(fileName), options: .atomic)
        MonitorNotificationSounds.refresh()
        NotificationCenter.default.post(name: .soundPacksChanged, object: nil)
    }

    /// Take one sound (by file name) out of a pack: it plays the default.
    func removeSound(fileName: String, in packID: String) {
        let stem = (fileName as NSString).deletingPathExtension
        guard let sound = Sounds.allCases.first(where: { $0.defaultSoundName == stem }) else { return }
        removeCustomSound(sound, in: packID)
        MonitorNotificationSounds.refresh()
        NotificationCenter.default.post(name: .soundPacksChanged, object: nil)
    }

    /// A pack's own sounds, by file name (such as `logged_on.wav`).
    func customSoundFiles(in packID: String) -> [(name: String, url: URL)] {
        Sounds.allCases.compactMap { sound in
            customSoundURL(for: sound, packID: packID).map { (sound.defaultSoundName + "." + $0.pathExtension.lowercased(), $0) }
        }
    }

    /// Put back a pack from the NG Account, as the pack it was on the
    /// iPhone that backed it up.
    func restorePackArchive(from archiveURL: URL, id: String, name: String) throws -> SoundPack {
        let entryLookup = try supportedSoundEntries(from: ZIPArchive.read(from: archiveURL))
        let restored = SoundPack(id: id,
                                 name: name,
                                 author: nil,
                                 createdAt: pack(for: id)?.createdAt ?? Date(),
                                 catalogID: nil,
                                 version: nil)
        try writeImportedPack(restored, entries: entryLookup)
        if let index = customPacks.firstIndex(where: { $0.id == id }) {
            customPacks[index] = restored
        } else {
            customPacks.append(restored)
        }
        sortPacks()
        try save()
        return restored
    }

    /// The catalog of published sound packs (Official ones first).
    func catalog() async throws -> [RemoteSoundPack] {
        try await NGAccountAPI(baseURL: MonitorService.baseURL, token: nil).catalog().compactMap { p in
            guard let url = URL(string: p.downloadPath, relativeTo: MonitorService.baseURL)?.absoluteURL else { return nil }
            return RemoteSoundPack(id: p.id, name: p.name, author: p.author, description: p.description.isEmpty ? nil : p.description,
                                   version: p.version, downloadURL: url, official: p.official)
        }
    }

    func downloadCatalogPack(_ pack: RemoteSoundPack) async throws -> URL {
        try await withCheckedThrowingContinuation { c in
            downloadCatalogPack(pack) { c.resume(with: $0) }
        }
    }

    private func customSoundURL(for sound: Sounds, packID: String) -> URL? {
        guard packID != SoundPackStore.defaultSoundPackID else {
            return nil
        }
        for soundName in sound.compatibleSoundNames {
            for fileExtension in supportedExtensions {
                let url = packDirectoryURL(for: packID).appendingPathComponent(soundName).appendingPathExtension(fileExtension)
                if fileManager.fileExists(atPath: url.path) {
                    return url
                }
            }
        }
        return nil
    }

    private func writeImportedPack(_ pack: SoundPack, entries: [String: ZIPArchiveEntry]) throws {
        let directoryURL = packDirectoryURL(for: pack.id)
        if fileManager.fileExists(atPath: directoryURL.path) {
            try fileManager.removeItem(at: directoryURL)
        }
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        do {
            for sound in Sounds.allCases {
                guard let entry = matchingEntry(for: sound, in: entries) else {
                    continue
                }
                let sourceExtension = URL(fileURLWithPath: entry.filename).pathExtension
                let fileExtension = sourceExtension.isEmpty ? "wav" : sourceExtension.lowercased()
                let destinationURL = directoryURL.appendingPathComponent(sound.defaultSoundName).appendingPathExtension(fileExtension)
                try entry.data.write(to: destinationURL, options: .atomic)
            }
        } catch {
            try? fileManager.removeItem(at: directoryURL)
            throw error
        }
    }

    private func matchingEntry(for sound: Sounds, in entries: [String: ZIPArchiveEntry]) -> ZIPArchiveEntry? {
        for soundName in sound.compatibleSoundNames {
            for fileExtension in supportedExtensions {
                if let entry = entries[soundName + "." + fileExtension] {
                    return entry
                }
            }
        }
        return nil
    }

    private func supportedSoundEntries(from entries: [ZIPArchiveEntry]) throws -> [String: ZIPArchiveEntry] {
        let supportedSoundNames = Set(Sounds.allCases.flatMap(\.compatibleSoundNames))
        var soundEntries = [String: ZIPArchiveEntry]()

        for entry in entries {
            let filename = URL(fileURLWithPath: entry.filename).lastPathComponent
            let fileURL = URL(fileURLWithPath: filename)
            let fileExtension = fileURL.pathExtension.lowercased()
            let soundName = fileURL.deletingPathExtension().lastPathComponent

            guard supportedExtensions.contains(fileExtension),
                  supportedSoundNames.contains(soundName) else {
                continue
            }

            let normalizedFilename = soundName + "." + fileExtension
            if soundEntries[normalizedFilename] == nil {
                soundEntries[normalizedFilename] = entry
            }
        }

        guard !soundEntries.isEmpty else {
            throw SoundPackError.noSupportedSounds
        }

        return soundEntries
    }

    private func load() {
        do {
            selectedPackID = UserDefaults.standard.string(forKey: selectedSoundPackIDKey) ?? SoundPackStore.defaultSoundPackID
            let url = metadataURL()
            guard fileManager.fileExists(atPath: url.path) else {
                customPacks = []
                storeSelection(SoundPackStore.defaultSoundPackID)
                return
            }
            let data = try Data(contentsOf: url)
            customPacks = try JSONDecoder().decode([SoundPack].self, from: data)
            sortPacks()
            if pack(for: selectedPackID) == nil {
                storeSelection(SoundPackStore.defaultSoundPackID)
            }
        } catch {
            customPacks = []
            storeSelection(SoundPackStore.defaultSoundPackID)
        }
    }

    private func save() throws {
        let data = try JSONEncoder().encode(customPacks)
        try data.write(to: metadataURL(), options: .atomic)
        NotificationCenter.default.post(name: .soundPacksChanged, object: nil)
    }

    private func sortPacks() {
        customPacks.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func uniquePackName(for proposedName: String) -> String {
        let trimmedName = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            return NSLocalizedString("Imported Sound Pack", comment: "sound pack")
        }

        let existingNames = Set(allPacks.map { $0.name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current) })
        if !existingNames.contains(trimmedName.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)) {
            return trimmedName
        }

        var suffix = 2
        while true {
            let candidate = "\(trimmedName) \(suffix)"
            let normalizedCandidate = candidate.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            if !existingNames.contains(normalizedCandidate) {
                return candidate
            }
            suffix += 1
        }
    }

    private func temporaryNamedFileURL(baseName: String, fileExtension: String) -> URL {
        let base = sanitizedTemporaryFileBaseName(baseName)
        var url = fileManager.temporaryDirectory.appendingPathComponent(base).appendingPathExtension(fileExtension)
        var suffix = 1
        while fileManager.fileExists(atPath: url.path) {
            url = fileManager.temporaryDirectory.appendingPathComponent("\(base) \(suffix)").appendingPathExtension(fileExtension)
            suffix += 1
        }
        return url
    }

    private func temporaryExportURL(baseName: String, fileExtension: String) throws -> URL {
        let base = sanitizedTemporaryFileBaseName(baseName)
        let directory = fileManager.temporaryDirectory
        let duplicatePrefix = base + " "
        let candidates = try fileManager.contentsOfDirectory(at: directory,
                                                             includingPropertiesForKeys: nil,
                                                             options: [.skipsHiddenFiles])
        for candidate in candidates where candidate.pathExtension.caseInsensitiveCompare(fileExtension) == .orderedSame {
            let candidateBase = candidate.deletingPathExtension().lastPathComponent
            let isNumberedDuplicate: Bool
            if candidateBase.hasPrefix(duplicatePrefix) {
                isNumberedDuplicate = Int(candidateBase.dropFirst(duplicatePrefix.count)) != nil
            } else {
                isNumberedDuplicate = false
            }

            if candidateBase == base || isNumberedDuplicate {
                try fileManager.removeItem(at: candidate)
            }
        }
        return directory.appendingPathComponent(base).appendingPathExtension(fileExtension)
    }

    private func sanitizedTemporaryFileBaseName(_ baseName: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\?%*|\"<>:")
        let sanitized = baseName.components(separatedBy: invalid).joined(separator: "-").trimmingCharacters(in: .whitespacesAndNewlines)
        return sanitized.isEmpty ? "Sound Pack" : sanitized
    }

    private func metadataURL() -> URL {
        return packsRootURL().appendingPathComponent(metadataFilename)
    }

    private func packsRootURL() -> URL {
        let root = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("SoundPacks", isDirectory: true)
        try? fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func packDirectoryURL(for packID: String) -> URL {
        return packsRootURL().appendingPathComponent(packID, isDirectory: true)
    }
}

enum SoundPackError: LocalizedError {
    case invalidName
    case defaultPackImmutable
    case packNotFound
    case invalidCatalogResponse
    case catalogUnavailable(statusCode: Int)
    case noSupportedSounds

    var errorDescription: String? {
        switch self {
        case .invalidName:
            return NSLocalizedString("Enter a sound pack name.", comment: "sound pack")
        case .defaultPackImmutable:
            return NSLocalizedString("The default sound pack cannot be edited or deleted.", comment: "sound pack")
        case .packNotFound:
            return NSLocalizedString("The sound pack could not be found.", comment: "sound pack")
        case .invalidCatalogResponse:
            return NSLocalizedString("Invalid catalog response.", comment: "sound pack")
        case .catalogUnavailable(let statusCode):
            return String(format: NSLocalizedString("Catalog request failed with status %d.", comment: "sound pack"), statusCode)
        case .noSupportedSounds:
            return NSLocalizedString("This ZIP archive does not contain any supported TeamTalk sound files.", comment: "sound pack")
        }
    }
}

private var activeSoundPlayers = [AVAudioPlayer]()
private let soundPlayerDelegate = SoundPlayerDelegate()

private class SoundPlayerDelegate: NSObject, AVAudioPlayerDelegate {
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        activeSoundPlayers.removeAll { $0 === player }
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        activeSoundPlayers.removeAll { $0 === player }
    }
}

func isSoundEventPreferenceEnabled(_ key: String, legacyKey: String? = nil) -> Bool {
    let settings = UserDefaults.standard
    if settings.object(forKey: key) != nil {
        return settings.bool(forKey: key)
    }
    if let legacyKey = legacyKey, settings.object(forKey: legacyKey) != nil {
        return settings.bool(forKey: legacyKey)
    }
    return true
}

func getSoundFile(_ s: Sounds) -> String? {
    
    let settings = UserDefaults.standard
    
    switch s {
    case .tx_ON:
        if isSoundEventPreferenceEnabled(PREF_SNDEVENT_VOICETX_ON, legacyKey: PREF_SNDEVENT_VOICETX) {
            return s.defaultSoundName
        }
    case .tx_OFF:
        if isSoundEventPreferenceEnabled(PREF_SNDEVENT_VOICETX_OFF, legacyKey: PREF_SNDEVENT_VOICETX) {
            return s.defaultSoundName
        }
    case .chan_MSG:
        if settings.object(forKey: PREF_SNDEVENT_CHANMSG) == nil ||
            settings.bool(forKey: PREF_SNDEVENT_CHANMSG) {
                return s.defaultSoundName
        }
    case .user_MSG:
        if settings.object(forKey: PREF_SNDEVENT_USERMSG) == nil ||
            settings.bool(forKey: PREF_SNDEVENT_USERMSG) {
                return s.defaultSoundName
        }
    case .broadcast_MSG:
        if settings.object(forKey: PREF_SNDEVENT_BCASTMSG) == nil ||
            settings.bool(forKey: PREF_SNDEVENT_BCASTMSG) {
            return s.defaultSoundName
        }
    case .srv_LOST:
        if settings.object(forKey: PREF_SNDEVENT_SERVERLOST) == nil ||
            settings.bool(forKey: PREF_SNDEVENT_SERVERLOST) {
                return s.defaultSoundName
        }
    case .joined_CHAN:
        if settings.object(forKey: PREF_SNDEVENT_JOINEDCHAN) == nil ||
            settings.bool(forKey: PREF_SNDEVENT_JOINEDCHAN) {
                return s.defaultSoundName
        }
    case .left_CHAN:
        if settings.object(forKey: PREF_SNDEVENT_LEFTCHAN) == nil ||
            settings.bool(forKey: PREF_SNDEVENT_LEFTCHAN) {
                return s.defaultSoundName
        }
    case .transmit_ON:
        if isSoundEventPreferenceEnabled(PREF_SNDEVENT_TRANSMITREADY_ON, legacyKey: PREF_SNDEVENT_TRANSMITREADY) {
            return s.defaultSoundName
        }
    case .transmit_OFF:
        if isSoundEventPreferenceEnabled(PREF_SNDEVENT_TRANSMITREADY_OFF, legacyKey: PREF_SNDEVENT_TRANSMITREADY) {
            return s.defaultSoundName
        }
    case .logged_IN :
        if settings.object(forKey: PREF_SNDEVENT_LOGGEDIN) == nil ||
            settings.bool(forKey: PREF_SNDEVENT_LOGGEDIN) {
            return s.defaultSoundName
        }
    case .logged_OUT :
        if settings.object(forKey: PREF_SNDEVENT_LOGGEDOUT) == nil ||
            settings.bool(forKey: PREF_SNDEVENT_LOGGEDOUT) {
            return s.defaultSoundName
        }
    case .intercept_START:
        if isSoundEventPreferenceEnabled(PREF_SNDEVENT_INTERCEPTION_START, legacyKey: PREF_SNDEVENT_INTERCEPTION) {
            return s.defaultSoundName
        }
    case .intercept_END:
        if isSoundEventPreferenceEnabled(PREF_SNDEVENT_INTERCEPTION_END, legacyKey: PREF_SNDEVENT_INTERCEPTION) {
            return s.defaultSoundName
        }
    case .file_UPDATE:
        if settings.object(forKey: PREF_SNDEVENT_FILEUPDATE) == nil ||
            settings.bool(forKey: PREF_SNDEVENT_FILEUPDATE) {
            return s.defaultSoundName
        }
    case .filetx_COMPLETE:
        if settings.object(forKey: PREF_SNDEVENT_FILETXCOMPLETE) == nil ||
            settings.bool(forKey: PREF_SNDEVENT_FILETXCOMPLETE) {
            return s.defaultSoundName
        }
    }

    return nil
}

func getCategory(_ opt: AVAudioSession.CategoryOptions) -> String {
    var str = ""
    if opt.contains(.defaultToSpeaker) {
        str += "defaultToSpeaker|"
    }
    if opt.contains(.mixWithOthers) {
        str += "mixWithOthers|"
    }
    if opt.contains(.allowBluetoothA2DP) {
        str += "allowBluetoothA2DP|"
    }
    if opt.contains(.allowBluetoothHFP) {
        str += "allowBluetoothHFP|"
    }
    if opt.contains(.duckOthers) {
        str += "duckOthers|"
    }
    if opt.contains(.interruptSpokenAudioAndMixWithOthers) {
        str += "interruptSpokenAudioAndMixWithOthers|"
    }
    if #available(iOS 14.5, *) {
        if opt.contains(.overrideMutedMicrophoneInterruption) {
            str += "overrideMutedMicrophoneInterruption|"
        }
    }
    if #available(iOS 10.0, *) {
        if opt.contains(.allowAirPlay) {
            str += "allowAirPlay|"
        }
        if opt.contains(.allowBluetoothA2DP) {
            str += "allowBluetoothA2DP|"
        }
    }
    return str
}

func getAudioPortDataSource(descr: AVAudioSessionPortDescription) -> NSNumber? {
    let defaults = UserDefaults.standard
    let prefname = PREF_SNDINPUT_PORT + "_" + descr.uid
    if let id = defaults.object(forKey: prefname) as? NSNumber {
        return id
    }
    return nil
}

func setAudioPortDataSource(descr: AVAudioSessionPortDescription, dsrc: AVAudioSessionDataSourceDescription) {
    let defaults = UserDefaults.standard
    let prefname = PREF_SNDINPUT_PORT + "_" + descr.uid
    defaults.set(dsrc.dataSourceID, forKey: prefname)
}

func removeAudioPortDataSource(descr: AVAudioSessionPortDescription) {
    let defaults = UserDefaults.standard
    let prefname = PREF_SNDINPUT_PORT + "_" + descr.uid
    defaults.removeObject(forKey: prefname)
}

func applyPreferredAudioInput(_ input: AVAudioSessionPortDescription,
                              dataSource: AVAudioSessionDataSourceDescription?,
                              session: AVAudioSession = AVAudioSession.sharedInstance(),
                              allowStereo: Bool = isVoiceProcessingEnabled() == false) throws {
    try session.setPreferredInput(input)

    if #available(iOS 14.0, *) {
        if let selectedDataSource = dataSource {
            if allowStereo, let patterns = selectedDataSource.supportedPolarPatterns, patterns.contains(.stereo) {
                try selectedDataSource.setPreferredPolarPattern(.stereo)
                print("Setting \(selectedDataSource.dataSourceName) to stereo")
            }
            try input.setPreferredDataSource(selectedDataSource)
            try session.setInputDataSource(selectedDataSource)
        } else {
            if allowStereo,
               let defaultSource = input.preferredDataSource ?? input.selectedDataSource,
               let patterns = defaultSource.supportedPolarPatterns,
               patterns.contains(.stereo) {
                try defaultSource.setPreferredPolarPattern(.stereo)
                print("Setting \(defaultSource.dataSourceName) to stereo")
            }
            try input.setPreferredDataSource(nil)
        }
        // The Voice-Processing I/O unit is mono only, so asking the session for a
        // stereo input while it is in use fails and would take the microphone with it.
        try? session.setPreferredInputNumberOfChannels(allowStereo ? 2 : 1)
    } else if let selectedDataSource = dataSource {
        try input.setPreferredDataSource(selectedDataSource)
        try session.setInputDataSource(selectedDataSource)
    } else {
        try input.setPreferredDataSource(nil)
    }
}

func availableSelectableAudioInputs(for session: AVAudioSession = AVAudioSession.sharedInstance()) -> [AVAudioSessionPortDescription] {
    let inputs = session.availableInputs ?? []
    let allowBluetoothMicrophones = UserDefaults.standard.object(forKey: PREF_ALLOW_BLUETOOTH_MICROPHONES) != nil &&
        UserDefaults.standard.bool(forKey: PREF_ALLOW_BLUETOOTH_MICROPHONES)
    guard allowBluetoothMicrophones == false else {
        return inputs
    }
    return inputs.filter { $0.portType != .bluetoothHFP }
}

func applySpeakerOutputOverride(_ speakerOutputEnabled: Bool, session: AVAudioSession = AVAudioSession.sharedInstance()) throws {
    try session.overrideOutputAudioPort(speakerOutputEnabled ? .speaker : .none)
}

// Apple's supported way of getting acoustic echo cancellation on iOS is the
// Voice-Processing I/O audio unit (kAudioUnitSubType_VoiceProcessingIO). The
// TeamTalk AudioUnit sound system exposes that unit as sound device ID
// TT_SOUNDDEVICE_ID_VOICEPREPROCESSINGIO, so enabling voice preprocessing is a
// matter of initializing that device instead of the plain Remote I/O unit and
// telling AVAudioSession we are doing two-way voice communication.
// Matches the TeamTalk iOS AudioUnit backend's default sample rate, and its
// default shared-device frame size of nDefaultSampleRate * 0.04 (40 msec).
let AUDIOUNIT_SAMPLERATE = INT32(48000)
let AUDIOUNIT_FRAMESIZE = INT32(Double(AUDIOUNIT_SAMPLERATE) * 0.04)

func isVoiceProcessingEnabled() -> Bool {
    let defaults = UserDefaults.standard
    return defaults.object(forKey: PREF_VOICE_PROCESSING) != nil && defaults.bool(forKey: PREF_VOICE_PROCESSING)
}

// Sound device ID to hand to TT_InitSoundInputDevice()/TT_InitSoundOutputDevice().
func preferredSoundDeviceID(voiceProcessingEnabled: Bool) -> INT32 {
    return voiceProcessingEnabled ? TT_SOUNDDEVICE_ID_VOICEPREPROCESSINGIO : TT_SOUNDDEVICE_ID_REMOTEIO
}

// The Voice-Processing I/O unit requires the playAndRecord category, and Apple
// documents .voiceChat as the matching mode for VoIP. Setting it up front avoids
// the implicit mode change the system would otherwise make when the unit starts.
func preferredAudioSessionMode(voiceProcessingEnabled: Bool) -> AVAudioSession.Mode {
    return voiceProcessingEnabled ? .voiceChat : .default
}

var soundDevicesAllowedForConnection = false
var soundDevicesInitializedForConnection = false

func closeSoundDevices() {
    if ttInst != nil {
        TT_CloseSoundInputDevice(ttInst)
        TT_CloseSoundOutputDevice(ttInst)
    }
}

func isConnectedToServer() -> Bool {
    return ttInst != nil && TT_GetFlags(ttInst) & CLIENT_CONNECTED.rawValue != 0
}

func isLoggedInToServer() -> Bool {
    return ttInst != nil && TT_GetFlags(ttInst) & CLIENT_AUTHORIZED.rawValue != 0
}

func resetSoundDevicesToLaunchState() {
    soundDevicesAllowedForConnection = false

    if ttInst != nil {
        closeSoundDevices()
    }

    soundDevicesInitializedForConnection = false

    let session = AVAudioSession.sharedInstance()
    do {
        try session.setActive(false, options: .notifyOthersOnDeactivation)
    }
    catch {
        print("Failed to deactivate audio session")
    }
}

func teardownInitializedSoundDevices() {
    if ttInst != nil {
        closeSoundDevices()
    }

    soundDevicesInitializedForConnection = false

    let session = AVAudioSession.sharedInstance()
    do {
        try session.setActive(false, options: .notifyOthersOnDeactivation)
    }
    catch {
        print("Failed to deactivate audio session")
    }
}

func allowSoundDevicesForConnectedServer() {
    soundDevicesAllowedForConnection = true
}

func canConfigureSoundDevicesForConnectedServer() -> Bool {
    return soundDevicesAllowedForConnection && isLoggedInToServer()
}

func canReconfigureInitializedSoundDevices() -> Bool {
    return soundDevicesInitializedForConnection && canConfigureSoundDevicesForConnectedServer()
}

@discardableResult
func setupSoundDevices(enableInput: Bool = false,
                       allowWithoutConnection: Bool = false,
                       coordinatingMultipleServers: Bool = false,
                       forceVoiceProcessing: Bool? = nil,
                       configureSharedDevice: Bool = true,
                       devicesAlreadyClosed: Bool = false) -> Bool {
    if coordinatingMultipleServers == false && ConnectedServerManager.shared.sessions.count > 1 {
        return setupSoundDevicesForConnectedServers(requestedInstance: ttInst,
                                                    requestedInputEnabled: enableInput)
    }

    let canConfigureWithoutServer = allowWithoutConnection && isConnectedToServer() == false
    guard canConfigureSoundDevicesForConnectedServer() || canConfigureWithoutServer else {
        return false
    }
    
    do {
        if devicesAlreadyClosed == false {
            closeSoundDevices()
        }
        
        let session = AVAudioSession.sharedInstance()

        print("preset: " + session.mode.rawValue)
        
        let defaults = UserDefaults.standard
        let useVoiceProcessing = forceVoiceProcessing ?? (enableInput && isVoiceProcessingEnabled())
        let speaker = defaults.object(forKey: PREF_SPEAKER_OUTPUT) != nil && defaults.bool(forKey: PREF_SPEAKER_OUTPUT)
        let allowBluetoothMicrophones = defaults.object(forKey: PREF_ALLOW_BLUETOOTH_MICROPHONES) != nil && defaults.bool(forKey: PREF_ALLOW_BLUETOOTH_MICROPHONES)

        var catoptions : AVAudioSession.CategoryOptions
        
        // Toggling 'speaker' on iPad has no effect since it can only output to speaker.
        // When Bluetooth headset is connected to iPad then toggling 'speaker' will have
        // no effect. However, on iPhone toggling 'speaker' has the desired effect both
        // when switching output from Receiver and Bluetooth to 'speaker'.
        if speaker {
            catoptions = [ .defaultToSpeaker ]
        }
        else {
            if #available(iOS 10.0, *) {
                catoptions = allowBluetoothMicrophones ? [ .allowAirPlay, .allowBluetoothHFP ] : [ .allowAirPlay, .allowBluetoothA2DP]
                if allowBluetoothMicrophones == false, #available(iOS 26.0, *) {
                    catoptions.update(with: .bluetoothHighQualityRecording)
                }
            } else {
                catoptions = allowBluetoothMicrophones ? [ .allowBluetoothHFP ] : []
            }
        }
        if allowBluetoothMicrophones {
            catoptions.update(with: .allowBluetoothHFP)
            if #available(iOS 10.0, *) {
                catoptions.remove(.allowBluetoothA2DP)
            }
        }
        catoptions.update(with: .mixWithOthers)

        // Apple recommends setting category and mode in a single call. The mode is
        // .voiceChat when voice preprocessing is on so the session is configured for
        // the Voice-Processing I/O unit before it gets initialized below.
        try session.setCategory(.playAndRecord,
                                mode: preferredAudioSessionMode(voiceProcessingEnabled: useVoiceProcessing),
                                options: catoptions)
        try session.setActive(true)

        // Changing the category can make AVAudioSession drop its current
        // input. Restore the user's persisted choice immediately so speaker
        // output changes never select a different microphone implicitly.
        //
        // This is best-effort on purpose: some data source configurations are
        // rejected outright depending on the session mode, and a throw here must
        // never stop the sound devices below from being initialized.
        if let savedInputUID = defaults.string(forKey: PREF_SNDINPUT_DEVICE),
           let savedInput = availableSelectableAudioInputs(for: session).first(where: { $0.uid == savedInputUID }) {
            do {
                if let savedDataSourceID = getAudioPortDataSource(descr: savedInput),
                   let savedDataSource = savedInput.dataSources?.first(where: { $0.dataSourceID == savedDataSourceID }) {
                    try applyPreferredAudioInput(savedInput,
                                                 dataSource: savedDataSource,
                                                 session: session,
                                                 allowStereo: !useVoiceProcessing)
                } else {
                    try applyPreferredAudioInput(savedInput,
                                                 dataSource: nil,
                                                 session: session,
                                                 allowStereo: !useVoiceProcessing)
                }
            }
            catch {
                print("Failed to restore preferred audio input: \(error)")
            }
        }

        let sndid = preferredSoundDeviceID(voiceProcessingEnabled: useVoiceProcessing)

        // Voice-Processing I/O is one coupled, mono input/output unit. TeamTalk
        // exposes both sides through its shared-device layer, so configure both sides
        // identically before opening either one. Configuring only capture leaves the
        // playback side at its stereo default and can prevent the unit from delivering
        // processed microphone samples.
        let sharedSampleRate = useVoiceProcessing ? AUDIOUNIT_SAMPLERATE : 0
        let sharedChannels: INT32 = useVoiceProcessing ? 1 : 0
        let sharedFrameSize = useVoiceProcessing ? AUDIOUNIT_FRAMESIZE : 0
        if configureSharedDevice {
            guard TT_InitSoundInputSharedDevice(sharedSampleRate, sharedChannels, sharedFrameSize) != FALSE,
                  TT_InitSoundOutputSharedDevice(sharedSampleRate, sharedChannels, sharedFrameSize) != FALSE else {
                print("Failed to configure shared sound device")
                soundDevicesInitializedForConnection = false
                return false
            }
        }

        var inputInitialized = !enableInput
        var outputInitialized = !isConnectedToServer()
        if ttInst != nil && enableInput {
            inputInitialized = TT_InitSoundInputDevice(ttInst, sndid) != FALSE
            print(inputInitialized ? "Using sound input device: \(sndid)" : "Failed to initialize sound input device: \(sndid)")
        }
        if ttInst != nil && isConnectedToServer() {
            outputInitialized = TT_InitSoundOutputDevice(ttInst, sndid) != FALSE
            print(outputInitialized ? "Using sound output device: \(sndid)" : "Failed to initialize sound output device: \(sndid)")
        }
        guard inputInitialized && outputInitialized else {
            closeSoundDevices()
            soundDevicesInitializedForConnection = false
            return false
        }
        print("postset. Mode \(session.mode.rawValue), category \(session.category.rawValue), options \(getCategory(session.categoryOptions))")
        
        // Restore stereo preference on the selected data source after RemoteIO
        // initialization. Skipped entirely under voice preprocessing, which is mono.
        if #available(iOS 14.0, *), useVoiceProcessing == false {
            for input in availableSelectableAudioInputs(for: session) {
                if let dataSourceID = getAudioPortDataSource(descr: input) {
                    if let dataSource = input.dataSources?.first(where: { $0.dataSourceID == dataSourceID }) {
                        do {
                            try applyPreferredAudioInput(input, dataSource: dataSource, session: session)
                        }
                        catch {
                            print("Failed to restore stereo on \(input.portName): \(error)")
                        }
                    }
                }
            }
        }

        try applySpeakerOutputOverride(speaker, session: session)
        soundDevicesInitializedForConnection = true
        return true
    }
    catch {
        closeSoundDevices()
        soundDevicesInitializedForConnection = false
        print("Failed to configure sound devices: \(error)")
        return false
    }
}

@discardableResult
private func setupSoundDevicesForConnectedServers(requestedInstance: UnsafeMutableRawPointer?,
                                                  requestedInputEnabled: Bool) -> Bool {
    let connectedSessions = ConnectedServerManager.shared.sessions.compactMap { controller -> (UnsafeMutableRawPointer, Bool)? in
        guard let instance = controller.teamTalkInstance,
              TT_GetFlags(instance) & CLIENT_AUTHORIZED.rawValue != 0 else {
            return nil
        }

        let inputEnabled = instance == requestedInstance
            ? requestedInputEnabled
            : isTransmitting(instance, stream: STREAMTYPE_VOICE)
        return (instance, inputEnabled)
    }

    guard connectedSessions.isEmpty == false else { return false }

    // Voice-Processing I/O is a single shared, coupled audio unit. Reconfiguring
    // it independently for each TeamTalk instance leaves only the final instance
    // attached. Close every endpoint first, configure the shared unit once, then
    // attach all connected sessions to that same configuration.
    connectedSessions.forEach { instance, _ in
        TT_CloseSoundInputDevice(instance)
        TT_CloseSoundOutputDevice(instance)
    }

    let useVoiceProcessing = isVoiceProcessingEnabled() && connectedSessions.contains { $0.1 }
    var allInitialized = true

    for (index, session) in connectedSessions.enumerated() {
        let initialized = withTeamTalkInstance(session.0) {
            setupSoundDevices(enableInput: session.1,
                              coordinatingMultipleServers: true,
                              forceVoiceProcessing: useVoiceProcessing,
                              configureSharedDevice: index == 0,
                              devicesAlreadyClosed: true)
        }
        allInitialized = allInitialized && initialized
    }

    soundDevicesInitializedForConnection = allInitialized
    return allInitialized
}

@discardableResult
func playSoundFile(at url: URL) throws -> TimeInterval {
    let player = try AVAudioPlayer(contentsOf: url)
    player.delegate = soundPlayerDelegate
    activeSoundPlayers.append(player)
    player.prepareToPlay()
    player.play()
    return player.duration
}

func previewSound(_ s: Sounds, packID: String) throws {
    if let url = SoundPackStore.shared.soundURL(for: s, packID: packID) {
        try playSoundFile(at: url)
    }
}

func previewSoundEventSequence(_ sound: Sounds) {
    let sequence = sound.previewSequence

    func playNext(at index: Int) {
        guard index < sequence.count else {
            return
        }
        guard let url = SoundPackStore.shared.soundURL(for: sequence[index]) else {
            playNext(at: index + 1)
            return
        }

        do {
            let duration = try playSoundFile(at: url)
            guard index + 1 < sequence.count else {
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
                playNext(at: index + 1)
            }
        } catch {
            print("Failed to preview sound: \(error)")
            playNext(at: index + 1)
        }
    }

    playNext(at: 0)
}

func playSound(_ s: Sounds) {
    guard getSoundFile(s) != nil,
          let url = SoundPackStore.shared.soundURL(for: s) else {
        return
    }

    do {
        try playSoundFile(at: url)
    }
    catch {
        print("Failed to play")
    }
}

struct ZIPArchiveEntry {
    let filename: String
    let data: Data
}

enum ZIPArchive {
    static func read(from url: URL) throws -> [ZIPArchiveEntry] {
        let data = try Data(contentsOf: url)
        let centralDirectory = try centralDirectory(from: data)
        return try centralDirectory.compactMap { record in
            if record.filename.hasSuffix("/") {
                return nil
            }

            guard record.compressionMethod == 0 || record.compressionMethod == 8 else {
                throw ZIPArchiveError.unsupportedCompressionMethod
            }

            var reader = ZIPDataReader(data: data)
            try reader.seek(to: Int(record.localHeaderOffset))

            let localHeaderSignature = try reader.readUInt32()
            guard localHeaderSignature == 0x04034b50 else {
                throw ZIPArchiveError.invalidArchive
            }

            _ = try reader.readUInt16()
            _ = try reader.readUInt16()
            let compressionMethod = try reader.readUInt16()
            guard compressionMethod == record.compressionMethod else {
                throw ZIPArchiveError.unsupportedCompressionMethod
            }

            _ = try reader.readUInt16()
            _ = try reader.readUInt16()
            _ = try reader.readUInt32()
            _ = try reader.readUInt32()
            _ = try reader.readUInt32()
            let filenameLength = try reader.readUInt16()
            let extraFieldLength = try reader.readUInt16()

            _ = try reader.readData(count: Int(filenameLength))
            _ = try reader.readData(count: Int(extraFieldLength))
            let compressedData = try reader.readData(count: Int(record.compressedSize))
            let entryData: Data
            switch compressionMethod {
            case 0:
                entryData = compressedData
            case 8:
                entryData = try inflateRawDeflate(compressedData, uncompressedSize: Int(record.uncompressedSize))
            default:
                throw ZIPArchiveError.unsupportedCompressionMethod
            }
            return ZIPArchiveEntry(filename: record.filename, data: entryData)
        }
    }

    static func write(entries: [ZIPArchiveEntry], to url: URL) throws {
        let compressedEntries = try entries.map { entry in
            (entry: entry, compressedData: try deflateRaw(entry.data))
        }
        var archive = Data()
        var centralDirectory = Data()
        var localHeaderOffsets = [UInt32]()

        for compressedEntry in compressedEntries {
            let entry = compressedEntry.entry
            let compressedData = compressedEntry.compressedData
            let filenameData = Data(entry.filename.utf8)
            let crc = ZIPCRC32.checksum(of: entry.data)
            let compressedSize = UInt32(compressedData.count)
            let uncompressedSize = UInt32(entry.data.count)
            let localHeaderOffset = UInt32(archive.count)
            localHeaderOffsets.append(localHeaderOffset)

            archive.appendLittleEndian(UInt32(0x04034b50))
            archive.appendLittleEndian(UInt16(20))
            archive.appendLittleEndian(UInt16(0))
            archive.appendLittleEndian(UInt16(8))
            archive.appendLittleEndian(UInt16(0))
            archive.appendLittleEndian(UInt16(0))
            archive.appendLittleEndian(crc)
            archive.appendLittleEndian(compressedSize)
            archive.appendLittleEndian(uncompressedSize)
            archive.appendLittleEndian(UInt16(filenameData.count))
            archive.appendLittleEndian(UInt16(0))
            archive.append(filenameData)
            archive.append(compressedData)
        }

        for (index, compressedEntry) in compressedEntries.enumerated() {
            let entry = compressedEntry.entry
            let compressedData = compressedEntry.compressedData
            let filenameData = Data(entry.filename.utf8)
            let crc = ZIPCRC32.checksum(of: entry.data)
            let compressedSize = UInt32(compressedData.count)
            let uncompressedSize = UInt32(entry.data.count)

            centralDirectory.appendLittleEndian(UInt32(0x02014b50))
            centralDirectory.appendLittleEndian(UInt16(20))
            centralDirectory.appendLittleEndian(UInt16(20))
            centralDirectory.appendLittleEndian(UInt16(0))
            centralDirectory.appendLittleEndian(UInt16(8))
            centralDirectory.appendLittleEndian(UInt16(0))
            centralDirectory.appendLittleEndian(UInt16(0))
            centralDirectory.appendLittleEndian(crc)
            centralDirectory.appendLittleEndian(compressedSize)
            centralDirectory.appendLittleEndian(uncompressedSize)
            centralDirectory.appendLittleEndian(UInt16(filenameData.count))
            centralDirectory.appendLittleEndian(UInt16(0))
            centralDirectory.appendLittleEndian(UInt16(0))
            centralDirectory.appendLittleEndian(UInt16(0))
            centralDirectory.appendLittleEndian(UInt16(0))
            centralDirectory.appendLittleEndian(UInt32(0))
            centralDirectory.appendLittleEndian(localHeaderOffsets[index])
            centralDirectory.append(filenameData)
        }

        let centralDirectoryOffset = UInt32(archive.count)
        archive.append(centralDirectory)
        archive.appendLittleEndian(UInt32(0x06054b50))
        archive.appendLittleEndian(UInt16(0))
        archive.appendLittleEndian(UInt16(0))
        archive.appendLittleEndian(UInt16(entries.count))
        archive.appendLittleEndian(UInt16(entries.count))
        archive.appendLittleEndian(UInt32(centralDirectory.count))
        archive.appendLittleEndian(centralDirectoryOffset)
        archive.appendLittleEndian(UInt16(0))

        try archive.write(to: url, options: .atomic)
    }

    private static func centralDirectory(from data: Data) throws -> [ZIPCentralDirectoryRecord] {
        let endSignature = Data([0x50, 0x4b, 0x05, 0x06])
        guard let endRange = data.range(of: endSignature, options: .backwards) else {
            throw ZIPArchiveError.invalidArchive
        }

        var endReader = ZIPDataReader(data: data)
        try endReader.seek(to: endRange.lowerBound)
        _ = try endReader.readUInt32()
        _ = try endReader.readUInt16()
        _ = try endReader.readUInt16()
        _ = try endReader.readUInt16()
        let entryCount = try endReader.readUInt16()
        let centralDirectorySize = try endReader.readUInt32()
        let centralDirectoryOffset = try endReader.readUInt32()
        let commentLength = try endReader.readUInt16()
        _ = try endReader.readData(count: Int(commentLength))

        var reader = ZIPDataReader(data: data)
        try reader.seek(to: Int(centralDirectoryOffset))
        let directoryEnd = Int(centralDirectoryOffset + centralDirectorySize)

        var records: [ZIPCentralDirectoryRecord] = []
        while reader.offset < directoryEnd && records.count < Int(entryCount) {
            let signature = try reader.readUInt32()
            guard signature == 0x02014b50 else {
                throw ZIPArchiveError.invalidArchive
            }

            _ = try reader.readUInt16()
            _ = try reader.readUInt16()
            let generalPurposeBitFlag = try reader.readUInt16()
            let compressionMethod = try reader.readUInt16()
            _ = try reader.readUInt16()
            _ = try reader.readUInt16()
            _ = try reader.readUInt32()
            let compressedSize = try reader.readUInt32()
            let uncompressedSize = try reader.readUInt32()
            let filenameLength = try reader.readUInt16()
            let extraFieldLength = try reader.readUInt16()
            let commentLength = try reader.readUInt16()
            _ = try reader.readUInt16()
            _ = try reader.readUInt16()
            _ = try reader.readUInt32()
            let localHeaderOffset = try reader.readUInt32()

            let filenameData = try reader.readData(count: Int(filenameLength))
            let filename = String(decoding: filenameData, as: UTF8.self)
            _ = try reader.readData(count: Int(extraFieldLength))
            _ = try reader.readData(count: Int(commentLength))

            records.append(ZIPCentralDirectoryRecord(filename: filename,
                                                     generalPurposeBitFlag: generalPurposeBitFlag,
                                                     compressionMethod: compressionMethod,
                                                     compressedSize: compressedSize,
                                                     uncompressedSize: uncompressedSize,
                                                     localHeaderOffset: localHeaderOffset))
        }

        return records
    }

    private static func deflateRaw(_ data: Data) throws -> Data {
        var input = [UInt8](data)
        if input.isEmpty {
            input.append(0)
        }

        let outputCapacity = max(Int(compressBound(uLong(data.count))), 64)
        var output = [UInt8](repeating: 0, count: outputCapacity)
        var stream = z_stream()
        let initStatus = deflateInit2_(&stream,
                                       Z_DEFAULT_COMPRESSION,
                                       Z_DEFLATED,
                                       -15,
                                       8,
                                       Z_DEFAULT_STRATEGY,
                                       ZLIB_VERSION,
                                       Int32(MemoryLayout<z_stream>.size))
        guard initStatus == Z_OK else {
            throw ZIPArchiveError.unsupportedCompressionMethod
        }
        defer {
            deflateEnd(&stream)
        }

        let status = input.withUnsafeMutableBytes { inputBuffer in
            output.withUnsafeMutableBytes { outputBuffer in
                stream.next_in = inputBuffer.bindMemory(to: Bytef.self).baseAddress
                stream.avail_in = uInt(data.count)
                stream.next_out = outputBuffer.bindMemory(to: Bytef.self).baseAddress
                stream.avail_out = uInt(outputCapacity)
                return deflate(&stream, Z_FINISH)
            }
        }

        guard status == Z_STREAM_END else {
            throw ZIPArchiveError.unsupportedCompressionMethod
        }
        return Data(output.prefix(Int(stream.total_out)))
    }

    private static func inflateRawDeflate(_ data: Data, uncompressedSize: Int) throws -> Data {
        guard uncompressedSize >= 0 else {
            throw ZIPArchiveError.invalidArchive
        }
        guard uncompressedSize > 0 else {
            return Data()
        }
        guard !data.isEmpty else {
            throw ZIPArchiveError.invalidArchive
        }

        var output = Data(count: uncompressedSize)
        let outputCount = output.count
        var stream = z_stream()
        let initStatus = inflateInit2_(&stream, -15, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard initStatus == Z_OK else {
            throw ZIPArchiveError.unsupportedCompressionMethod
        }
        defer {
            inflateEnd(&stream)
        }

        let status: Int32 = data.withUnsafeBytes { inputBuffer in
            output.withUnsafeMutableBytes { outputBuffer in
                guard let inputBase = inputBuffer.bindMemory(to: Bytef.self).baseAddress,
                      let outputBase = outputBuffer.bindMemory(to: Bytef.self).baseAddress else {
                    return Z_DATA_ERROR
                }

                stream.next_in = UnsafeMutablePointer<Bytef>(mutating: inputBase)
                stream.avail_in = uInt(data.count)
                stream.next_out = outputBase
                stream.avail_out = uInt(outputCount)
                return inflate(&stream, Z_FINISH)
            }
        }

        guard status == Z_STREAM_END,
              stream.total_out == uLong(uncompressedSize) else {
            throw ZIPArchiveError.invalidArchive
        }

        return output
    }
}

enum ZIPArchiveError: LocalizedError {
    case invalidArchive
    case unsupportedCompressionMethod

    var errorDescription: String? {
        switch self {
        case .invalidArchive:
            return NSLocalizedString("The ZIP archive is invalid.", comment: "sound pack")
        case .unsupportedCompressionMethod:
            return NSLocalizedString("This ZIP archive uses an unsupported compression method.", comment: "sound pack")
        }
    }
}

private struct ZIPCentralDirectoryRecord {
    let filename: String
    let generalPurposeBitFlag: UInt16
    let compressionMethod: UInt16
    let compressedSize: UInt32
    let uncompressedSize: UInt32
    let localHeaderOffset: UInt32
}

private struct ZIPDataReader {
    let data: Data
    private(set) var offset: Int = 0

    mutating func seek(to offset: Int) throws {
        guard data.indices.contains(offset) || offset == data.count else {
            throw ZIPArchiveError.invalidArchive
        }
        self.offset = offset
    }

    mutating func readUInt16() throws -> UInt16 {
        let bytes = try readData(count: 2)
        return bytes.withUnsafeBytes { $0.load(as: UInt16.self) }.littleEndian
    }

    mutating func readUInt32() throws -> UInt32 {
        let bytes = try readData(count: 4)
        return bytes.withUnsafeBytes { $0.load(as: UInt32.self) }.littleEndian
    }

    mutating func readData(count: Int) throws -> Data {
        guard count >= 0, offset + count <= data.count else {
            throw ZIPArchiveError.invalidArchive
        }
        let chunk = data.subdata(in: offset..<(offset + count))
        offset += count
        return chunk
    }
}

private enum ZIPCRC32 {
    static func checksum(of data: Data) -> UInt32 {
        var value: UInt32 = 0xffff_ffff
        for byte in data {
            let index = Int((value ^ UInt32(byte)) & 0xff)
            value = table[index] ^ (value >> 8)
        }
        return value ^ 0xffff_ffff
    }

    private static let table: [UInt32] = {
        (0..<256).map { value in
            var current = UInt32(value)
            for _ in 0..<8 {
                if current & 1 == 1 {
                    current = 0xedb8_8320 ^ (current >> 1)
                } else {
                    current >>= 1
                }
            }
            return current
        }
    }()
}

private extension Data {
    mutating func appendLittleEndian(_ value: UInt16) {
        var littleEndianValue = value.littleEndian
        append(Data(bytes: &littleEndianValue, count: MemoryLayout<UInt16>.size))
    }

    mutating func appendLittleEndian(_ value: UInt32) {
        var littleEndianValue = value.littleEndian
        append(Data(bytes: &littleEndianValue, count: MemoryLayout<UInt32>.size))
    }
}
