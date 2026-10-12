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

import UIKit
import AVFoundation

class SoundEventsViewController : UITableViewController {
    
    var soundevents_items = [UITableViewCell]()
    private var soundEventRows = [SoundEventRow]()

    private struct SoundEventRow {
        let sound: Sounds
        let title: String
        let detail: String
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "", style: .plain, target: self, action: #selector(SoundEventsViewController.toggleAllSoundEvents))
        
        addSoundEvent(.srv_LOST,
                      title: NSLocalizedString("Server Connection Lost", comment: "preferences"),
                      detail: NSLocalizedString("Play sound when connection is dropped", comment: "preferences"))
        addSoundEvent(.tx_ON,
                      title: NSLocalizedString("Voice Transmission On", comment: "preferences"),
                      detail: NSLocalizedString("Play sound when voice transmission starts", comment: "preferences"))
        addSoundEvent(.tx_OFF,
                      title: NSLocalizedString("Voice Transmission Off", comment: "preferences"),
                      detail: NSLocalizedString("Play sound when voice transmission stops", comment: "preferences"))
        addSoundEvent(.user_MSG,
                      title: NSLocalizedString("Private Text Message", comment: "preferences"),
                      detail: NSLocalizedString("Play sound when private text message is received", comment: "preferences"))
        addSoundEvent(.chan_MSG,
                      title: NSLocalizedString("Channel Text Message", comment: "preferences"),
                      detail: NSLocalizedString("Play sound when channel text message is received", comment: "preferences"))
        addSoundEvent(.broadcast_MSG,
                      title: NSLocalizedString("Broadcast Text Message", comment: "preferences"),
                      detail: NSLocalizedString("Play sound when broadcast text message is received", comment: "preferences"))
        addSoundEvent(.logged_IN,
                      title: NSLocalizedString("User Logged In", comment: "preferences"),
                      detail: NSLocalizedString("Play sound when user logs on to the server", comment: "preferences"))
        addSoundEvent(.logged_OUT,
                      title: NSLocalizedString("User Logged Out", comment: "preferences"),
                      detail: NSLocalizedString("Play sound when user logs off to the server", comment: "preferences"))
        addSoundEvent(.joined_CHAN,
                      title: NSLocalizedString("User Joins Channel", comment: "preferences"),
                      detail: NSLocalizedString("Play sound when a user joins the channel", comment: "preferences"))
        addSoundEvent(.left_CHAN,
                      title: NSLocalizedString("User Leaves Channel", comment: "preferences"),
                      detail: NSLocalizedString("Play sound when a user leaves the channel", comment: "preferences"))
        addSoundEvent(.transmit_ON,
                      title: NSLocalizedString("Exclusive Mode On", comment: "preferences"),
                      detail: NSLocalizedString("Play sound when you become ready to transmit in a \"No Interruptions\" channel", comment: "preferences"))
        addSoundEvent(.transmit_OFF,
                      title: NSLocalizedString("Exclusive Mode Off", comment: "preferences"),
                      detail: NSLocalizedString("Play sound when you are no longer ready to transmit in a \"No Interruptions\" channel", comment: "preferences"))
        addSoundEvent(.intercept_START,
                      title: NSLocalizedString("Interception Started", comment: "preferences"),
                      detail: NSLocalizedString("Play sound when interception starts", comment: "preferences"))
        addSoundEvent(.intercept_END,
                      title: NSLocalizedString("Interception Ended", comment: "preferences"),
                      detail: NSLocalizedString("Play sound when interception ends", comment: "preferences"))
        addSoundEvent(.file_UPDATE,
                      title: NSLocalizedString("Channel File Updated", comment: "preferences"),
                      detail: NSLocalizedString("Play sound when a file is added to or removed from your channel", comment: "preferences"))
        addSoundEvent(.filetx_COMPLETE,
                      title: NSLocalizedString("File Transfer Complete", comment: "preferences"),
                      detail: "")
        updateSoundEventsBulkButton()
    }

    override func numberOfSections(in tableView: UITableView) -> Int {
        return 1
    }
    
    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        return NSLocalizedString("Sound Events", comment:"text to speech")
    }
    
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return soundevents_items.count
    }
    
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        return soundevents_items[indexPath.row]
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        toggleSoundEvent(at: indexPath)
    }

    private func addSoundEvent(_ sound: Sounds, title: String, detail: String) {
        let row = SoundEventRow(sound: sound, title: title, detail: detail)
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        cell.textLabel?.text = title
        cell.detailTextLabel?.text = nil
        cell.tag = sound.rawValue
        cell.selectionStyle = .default
        cell.accessibilityCustomActions = [
            UIAccessibilityCustomAction(name: NSLocalizedString("Preview", comment: "sound pack"),
                                        target: self,
                                        selector: #selector(SoundEventsViewController.previewSoundEventAccessibility(_:)))
        ]
        configureSoundEventAccessory(for: cell, sound: sound)
        soundEventRows.append(row)
        soundevents_items.append(cell)
        configureSoundEventCell(cell, sound: sound)
    }

    private func configureSoundEventAccessory(for cell: UITableViewCell, sound: Sounds) {
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 76, height: 44))
        container.isAccessibilityElement = false
        container.accessibilityElementsHidden = true

        let checkmarkView = UIImageView(frame: CGRect(x: 0, y: 10, width: 24, height: 24))
        checkmarkView.tag = 1
        checkmarkView.contentMode = .center
        checkmarkView.tintColor = view.tintColor
        checkmarkView.isAccessibilityElement = false
        checkmarkView.accessibilityElementsHidden = true
        container.addSubview(checkmarkView)

        let previewButton = UIButton(type: .system)
        previewButton.frame = CGRect(x: 32, y: 4, width: 44, height: 36)
        previewButton.tag = sound.rawValue
        previewButton.isAccessibilityElement = false
        previewButton.accessibilityElementsHidden = true
        previewButton.addTarget(self, action: #selector(SoundEventsViewController.previewSoundEvent(_:)), for: .touchUpInside)
        if #available(iOS 13.0, *) {
            previewButton.setImage(UIImage(systemName: "play.fill"), for: .normal)
        }
        else {
            previewButton.setTitle("▶︎", for: .normal)
        }
        container.addSubview(previewButton)
        cell.accessoryView = container
    }

    private func configureSoundEventCell(_ cell: UITableViewCell, sound: Sounds) {
        let checkmarkView = cell.accessoryView?.viewWithTag(1) as? UIImageView
        if isSoundEventEnabled(sound) {
            if #available(iOS 13.0, *) {
                checkmarkView?.image = UIImage(systemName: "checkmark")
            }
            else {
                checkmarkView?.image = nil
                checkmarkView?.accessibilityLabel = "✓"
            }
            cell.accessibilityTraits = [.button, .selected]
        }
        else {
            checkmarkView?.image = nil
            cell.accessibilityTraits = [.button]
        }
    }

    private func toggleSoundEvent(at indexPath: IndexPath) {
        let sound = soundEventRows[indexPath.row].sound
        setSoundEvent(sound, enabled: isSoundEventEnabled(sound) == false)
        configureSoundEventCell(soundevents_items[indexPath.row], sound: sound)
        updateSoundEventsBulkButton()
    }

    @objc private func previewSoundEvent(_ sender: UIButton) {
        guard let sound = Sounds(rawValue: sender.tag) else {
            return
        }
        previewSoundEventSequence(sound)
    }

    @objc private func previewSoundEventAccessibility(_ action: UIAccessibilityCustomAction) -> Bool {
        guard let cell = soundevents_items.first(where: { cell in
            cell.accessibilityCustomActions?.contains(where: { $0 === action }) == true
        }), let sound = Sounds(rawValue: cell.tag) else {
            return false
        }
        previewSoundEventSequence(sound)
        return true
    }

    private func allSoundEventsEnabled() -> Bool {
        return soundEventRows.allSatisfy({isSoundEventEnabled($0.sound)})
    }

    private func updateSoundEventsBulkButton() {
        navigationItem.rightBarButtonItem?.title = allSoundEventsEnabled() ?
            NSLocalizedString("Disable All", comment: "preferences") :
            NSLocalizedString("Enable All", comment: "preferences")
    }

    @objc private func toggleAllSoundEvents() {
        let enable = allSoundEventsEnabled() == false
        for (index, row) in soundEventRows.enumerated() {
            setSoundEvent(row.sound, enabled: enable)
            configureSoundEventCell(soundevents_items[index], sound: row.sound)
        }
        updateSoundEventsBulkButton()
    }

    private func isSoundEventEnabled(_ sound: Sounds) -> Bool {
        let defaults = UserDefaults.standard
        switch sound {
        case .tx_ON:
            return isSoundEventPreferenceEnabled(PREF_SNDEVENT_VOICETX_ON, legacyKey: PREF_SNDEVENT_VOICETX)
        case .tx_OFF:
            return isSoundEventPreferenceEnabled(PREF_SNDEVENT_VOICETX_OFF, legacyKey: PREF_SNDEVENT_VOICETX)
        case .srv_LOST:
            return defaults.object(forKey: PREF_SNDEVENT_SERVERLOST) == nil || defaults.bool(forKey: PREF_SNDEVENT_SERVERLOST)
        case .chan_MSG:
            return defaults.object(forKey: PREF_SNDEVENT_CHANMSG) == nil || defaults.bool(forKey: PREF_SNDEVENT_CHANMSG)
        case .broadcast_MSG:
            return defaults.object(forKey: PREF_SNDEVENT_BCASTMSG) == nil || defaults.bool(forKey: PREF_SNDEVENT_BCASTMSG)
        case .joined_CHAN:
            return defaults.object(forKey: PREF_SNDEVENT_JOINEDCHAN) == nil || defaults.bool(forKey: PREF_SNDEVENT_JOINEDCHAN)
        case .left_CHAN:
            return defaults.object(forKey: PREF_SNDEVENT_LEFTCHAN) == nil || defaults.bool(forKey: PREF_SNDEVENT_LEFTCHAN)
        case .user_MSG:
            return defaults.object(forKey: PREF_SNDEVENT_USERMSG) == nil || defaults.bool(forKey: PREF_SNDEVENT_USERMSG)
        case .transmit_ON:
            return isSoundEventPreferenceEnabled(PREF_SNDEVENT_TRANSMITREADY_ON, legacyKey: PREF_SNDEVENT_TRANSMITREADY)
        case .transmit_OFF:
            return isSoundEventPreferenceEnabled(PREF_SNDEVENT_TRANSMITREADY_OFF, legacyKey: PREF_SNDEVENT_TRANSMITREADY)
        case .logged_IN:
            return defaults.object(forKey: PREF_SNDEVENT_LOGGEDIN) == nil || defaults.bool(forKey: PREF_SNDEVENT_LOGGEDIN)
        case .logged_OUT:
            return defaults.object(forKey: PREF_SNDEVENT_LOGGEDOUT) == nil || defaults.bool(forKey: PREF_SNDEVENT_LOGGEDOUT)
        case .intercept_START:
            return isSoundEventPreferenceEnabled(PREF_SNDEVENT_INTERCEPTION_START, legacyKey: PREF_SNDEVENT_INTERCEPTION)
        case .intercept_END:
            return isSoundEventPreferenceEnabled(PREF_SNDEVENT_INTERCEPTION_END, legacyKey: PREF_SNDEVENT_INTERCEPTION)
        case .file_UPDATE:
            return defaults.object(forKey: PREF_SNDEVENT_FILEUPDATE) == nil || defaults.bool(forKey: PREF_SNDEVENT_FILEUPDATE)
        case .filetx_COMPLETE:
            return defaults.object(forKey: PREF_SNDEVENT_FILETXCOMPLETE) == nil || defaults.bool(forKey: PREF_SNDEVENT_FILETXCOMPLETE)
        }
    }

    private func setSoundEvent(_ sound: Sounds, enabled: Bool) {
        let defaults = UserDefaults.standard
        switch sound {
        case Sounds.tx_ON:
            defaults.set(enabled, forKey: PREF_SNDEVENT_VOICETX_ON)
        case Sounds.tx_OFF:
            defaults.set(enabled, forKey: PREF_SNDEVENT_VOICETX_OFF)
        case Sounds.srv_LOST :
            defaults.set(enabled, forKey: PREF_SNDEVENT_SERVERLOST)
        case Sounds.chan_MSG :
            defaults.set(enabled, forKey: PREF_SNDEVENT_CHANMSG)
        case Sounds.broadcast_MSG :
            defaults.set(enabled, forKey: PREF_SNDEVENT_BCASTMSG)
        case Sounds.joined_CHAN :
            defaults.set(enabled, forKey: PREF_SNDEVENT_JOINEDCHAN)
        case Sounds.left_CHAN :
            defaults.set(enabled, forKey: PREF_SNDEVENT_LEFTCHAN)
        case Sounds.user_MSG :
            defaults.set(enabled, forKey: PREF_SNDEVENT_USERMSG)
        case Sounds.transmit_ON:
            defaults.set(enabled, forKey: PREF_SNDEVENT_TRANSMITREADY_ON)
        case Sounds.transmit_OFF:
            defaults.set(enabled, forKey: PREF_SNDEVENT_TRANSMITREADY_OFF)
        case Sounds.logged_IN :
            defaults.set(enabled, forKey: PREF_SNDEVENT_LOGGEDIN)
        case Sounds.logged_OUT :
            defaults.set(enabled, forKey: PREF_SNDEVENT_LOGGEDOUT)
        case Sounds.intercept_START:
            defaults.set(enabled, forKey: PREF_SNDEVENT_INTERCEPTION_START)
        case Sounds.intercept_END:
            defaults.set(enabled, forKey: PREF_SNDEVENT_INTERCEPTION_END)
        case Sounds.file_UPDATE:
            defaults.set(enabled, forKey: PREF_SNDEVENT_FILEUPDATE)
        case Sounds.filetx_COMPLETE:
            defaults.set(enabled, forKey: PREF_SNDEVENT_FILETXCOMPLETE)
        default :
            break
        }
    }
}

class SoundPacksViewController: UITableViewController, UIDocumentPickerDelegate {
    private var soundPackRows = [SoundPackRow]()

    private enum SoundPackRow {
        case pack(String)
        case create
        case `import`
        case browse
        case deleteAll
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = NSLocalizedString("Sound Packs", comment: "sound pack")
        rebuildSoundPackRows()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        rebuildSoundPackRows()
        tableView.reloadData()
    }

    override func numberOfSections(in tableView: UITableView) -> Int {
        return 1
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        return NSLocalizedString("Sound Packs", comment: "sound pack")
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return soundPackRows.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        return soundPackCell(for: indexPath)
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)

        switch soundPackRows[indexPath.row] {
        case .pack(let packID):
            SoundPackStore.shared.selectPack(packID)
            rebuildSoundPackRows()
            tableView.reloadData()
        case .create:
            showCreateSoundPackAlert()
        case .import:
            let picker = UIDocumentPickerViewController(documentTypes: ["public.zip-archive", "com.pkware.zip-archive", "public.archive"], in: .import)
            picker.delegate = self
            picker.allowsMultipleSelection = false
            present(picker, animated: true)
        case .browse:
            navigationController?.pushViewController(SoundPackBrowserViewController(), animated: true)
        case .deleteAll:
            confirmDeleteAllSoundPacks()
        }
    }

    private func rebuildSoundPackRows() {
        let store = SoundPackStore.shared
        soundPackRows = store.allPacks.map { .pack($0.id) }
        soundPackRows.append(.create)
        soundPackRows.append(.import)
        soundPackRows.append(.browse)
        if !store.customPacks.isEmpty {
            soundPackRows.append(.deleteAll)
        }
    }

    private func soundPackCell(for indexPath: IndexPath) -> UITableViewCell {
        let row = soundPackRows[indexPath.row]
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        let store = SoundPackStore.shared
        cell.accessoryType = .none

        switch row {
        case .pack(let packID):
            let pack = store.pack(for: packID) ?? store.defaultPack
            cell.textLabel?.text = pack.name
            cell.detailTextLabel?.text = nil
            if store.selectedPackID == packID {
                cell.accessoryType = .checkmark
            }
            configureSoundPackActions(for: cell, pack: pack)
        case .create:
            cell.textLabel?.text = NSLocalizedString("Create Sound Pack", comment: "sound pack")
            cell.detailTextLabel?.text = nil
            cell.accessoryType = .disclosureIndicator
        case .import:
            cell.textLabel?.text = NSLocalizedString("Import Sound Pack", comment: "sound pack")
            cell.detailTextLabel?.text = nil
            cell.accessoryType = .disclosureIndicator
        case .browse:
            cell.textLabel?.text = NSLocalizedString("Browse Sound Packs", comment: "sound pack")
            cell.detailTextLabel?.text = nil
            cell.accessoryType = .disclosureIndicator
        case .deleteAll:
            cell.textLabel?.text = NSLocalizedString("Delete All Custom Sound Packs", comment: "sound pack")
            cell.detailTextLabel?.text = nil
            cell.textLabel?.textColor = .systemRed
        }

        return cell
    }

    override func tableView(_ tableView: UITableView,
                            contextMenuConfigurationForRowAt indexPath: IndexPath,
                            point: CGPoint) -> UIContextMenuConfiguration? {
        guard case .pack(let packID) = soundPackRows[indexPath.row],
              let pack = SoundPackStore.shared.pack(for: packID),
              !pack.isDefault else {
            return nil
        }

        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            let edit = UIAction(title: NSLocalizedString("Edit", comment: "sound pack")) { _ in
                self?.editSoundPack(packID)
            }
            let export = UIAction(title: NSLocalizedString("Export", comment: "sound pack")) { _ in
                self?.exportSoundPack(packID)
            }
            let delete = UIAction(title: NSLocalizedString("Delete", comment: "sound pack"),
                                  attributes: .destructive) { _ in
                self?.confirmDeleteSoundPack(packID)
            }
            return UIMenu(title: "", children: [edit, export, delete])
        }
    }

    private func configureSoundPackActions(for cell: UITableViewCell, pack: SoundPack) {
        guard !pack.isDefault else {
            cell.accessibilityCustomActions = nil
            return
        }

        cell.accessibilityCustomActions = [
            UIAccessibilityCustomAction(name: NSLocalizedString("Edit", comment: "sound pack")) { [weak self] _ in
                self?.editSoundPack(pack.id)
                return true
            },
            UIAccessibilityCustomAction(name: NSLocalizedString("Export", comment: "sound pack")) { [weak self] _ in
                self?.exportSoundPack(pack.id)
                return true
            },
            UIAccessibilityCustomAction(name: NSLocalizedString("Delete", comment: "sound pack")) { [weak self] _ in
                self?.confirmDeleteSoundPack(pack.id)
                return true
            }
        ]
    }

    private func editSoundPack(_ packID: String) {
        navigationController?.pushViewController(SoundPackEditorViewController(packID: packID), animated: true)
    }

    private func showCreateSoundPackAlert() {
        let alert = UIAlertController(title: NSLocalizedString("New Sound Pack", comment: "sound pack"),
                                      message: nil,
                                      preferredStyle: .alert)
        alert.addTextField { textField in
            textField.placeholder = NSLocalizedString("Sound Pack Name", comment: "sound pack")
        }
        alert.addAction(UIAlertAction(title: NSLocalizedString("Cancel", comment: "alert"), style: .cancel))
        alert.addAction(UIAlertAction(title: NSLocalizedString("Create", comment: "sound pack"), style: .default) { [weak self, weak alert] _ in
            guard let name = alert?.textFields?.first?.text else {
                return
            }
            do {
                let pack = try SoundPackStore.shared.createPack(named: name)
                self?.rebuildSoundPackRows()
                self?.tableView.reloadData()
                self?.navigationController?.pushViewController(SoundPackEditorViewController(packID: pack.id), animated: true)
            } catch {
                self?.showError(error)
            }
        })
        present(alert, animated: true)
    }

    private func exportSoundPack(_ packID: String) {
        do {
            let archiveURL = try SoundPackStore.shared.exportPackArchive(for: packID)
            let activity = UIActivityViewController(activityItems: [archiveURL], applicationActivities: nil)
            if let popover = activity.popoverPresentationController {
                popover.sourceView = view
                popover.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1)
            }
            present(activity, animated: true)
        } catch {
            showError(error)
        }
    }

    private func confirmDeleteAllSoundPacks() {
        var message = NSLocalizedString("This deletes every sound pack except the default one.", comment: "sound pack")
        let inAccount = SoundPackStore.shared.customPacks.compactMap { NGPackSync.shared.accountPack(forLocal: $0.id) }
        if !inAccount.isEmpty {
            let published = inAccount.filter(\.public).count
            message += "\n\n" + String(format: NSLocalizedString("%d of them are in your NG Account and will be deleted from it and your other iPhones too.", comment: "sound pack"), inAccount.count)
            if published > 0 {
                message += " " + String(format: NSLocalizedString("%d published ones will leave the catalog (people who installed them keep their copy).", comment: "sound pack"), published)
            }
        }
        let alert = UIAlertController(title: NSLocalizedString("Delete Custom Sound Packs?", comment: "sound pack"),
                                      message: message,
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: NSLocalizedString("Cancel", comment: "alert"), style: .cancel))
        alert.addAction(UIAlertAction(title: NSLocalizedString("Delete All", comment: "alert"), style: .destructive) { [weak self] _ in
            do {
                try SoundPackStore.shared.deleteAllCustomPacks()
                self?.rebuildSoundPackRows()
                self?.tableView.reloadData()
            } catch {
                self?.showError(error)
            }
        })
        present(alert, animated: true)
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else {
            return
        }
        defer {
            removeTemporaryImportFileIfNeeded(url)
        }
        do {
            let pack = try SoundPackStore.shared.importPackArchive(from: url)
            rebuildSoundPackRows()
            tableView.reloadData()
            showImportedSoundPackNameAlert(packID: pack.id)
        } catch {
            showError(error)
        }
    }

    private func showImportedSoundPackNameAlert(packID: String) {
        let alert = UIAlertController(title: NSLocalizedString("Sound Pack Name", comment: "sound pack"),
                                      message: NSLocalizedString("You can optionally choose a new name for this sound pack. Leave blank to keep the name of the zip file this sound pack was stored in.", comment: "sound pack"),
                                      preferredStyle: .alert)
        alert.addTextField { textField in
            textField.placeholder = NSLocalizedString("Sound Pack Name", comment: "sound pack")
            textField.clearButtonMode = .whileEditing
        }
        alert.addAction(UIAlertAction(title: NSLocalizedString("Cancel", comment: "alert"), style: .cancel) { [weak self] _ in
            self?.navigationController?.pushViewController(SoundPackEditorViewController(packID: packID), animated: true)
        })
        alert.addAction(UIAlertAction(title: NSLocalizedString("OK", comment: "alert"), style: .default) { [weak self, weak alert] _ in
            guard let self = self else {
                return
            }

            let name = alert?.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            do {
                if !name.isEmpty {
                    try SoundPackStore.shared.renamePack(packID, to: name)
                    self.rebuildSoundPackRows()
                    self.tableView.reloadData()
                }
                self.navigationController?.pushViewController(SoundPackEditorViewController(packID: packID), animated: true)
            } catch {
                self.showError(error)
            }
        })
        present(alert, animated: true)
    }

    private func removeTemporaryImportFileIfNeeded(_ url: URL) {
        let fileManager = FileManager.default
        let temporaryDirectoryPath = fileManager.temporaryDirectory.standardizedFileURL.path
        let importedFilePath = url.standardizedFileURL.path

        guard importedFilePath == temporaryDirectoryPath ||
              importedFilePath.hasPrefix(temporaryDirectoryPath + "/") else {
            return
        }

        try? fileManager.removeItem(at: url)
    }

    private func confirmDeleteSoundPack(_ packID: String) {
        let packName = SoundPackStore.shared.pack(for: packID)?.name ?? NSLocalizedString("Sound Pack", comment: "sound pack")
        var message = packName
        if let account = NGPackSync.shared.accountPack(forLocal: packID) {
            message += "\n\n" + (account.public
                ? NSLocalizedString("It's also deleted from your NG Account and your other iPhones, and leaves the catalog (people who installed it keep their copy).", comment: "sound pack")
                : NSLocalizedString("It's also deleted from your NG Account and your other iPhones.", comment: "sound pack"))
        }
        let alert = UIAlertController(title: NSLocalizedString("Delete Sound Pack?", comment: "sound pack"),
                                      message: message,
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: NSLocalizedString("Cancel", comment: "alert"), style: .cancel))
        alert.addAction(UIAlertAction(title: NSLocalizedString("Delete", comment: "alert"), style: .destructive) { [weak self] _ in
            do {
                try SoundPackStore.shared.deletePack(packID)
                self?.rebuildSoundPackRows()
                self?.tableView.reloadData()
            } catch {
                self?.showError(error)
            }
        })
        present(alert, animated: true)
    }

    private func showError(_ error: Error) {
        let alert = UIAlertController(title: NSLocalizedString("Sound Pack Error", comment: "sound pack"),
                                      message: error.localizedDescription,
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: NSLocalizedString("OK", comment: "alert"), style: .default))
        present(alert, animated: true)
    }
}

private class SoundPackEditorViewController: UITableViewController, UIDocumentPickerDelegate {
    private let packID: String
    private var importingSound: Sounds?

    init(packID: String) {
        self.packID = packID
        super.init(style: .grouped)
    }

    required init?(coder: NSCoder) {
        return nil
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        updateTitle()
        // Find out whether this pack is one of the account's.
        Task { @MainActor [weak self] in
            await NGPackSync.shared.syncNow()
            self?.tableView.reloadData()
        }
    }

    /// Packs made here can be published; catalog packs only by their owner.
    private var canPublish: Bool {
        guard let pack = SoundPackStore.shared.pack(for: packID) else { return false }
        return pack.catalogID == nil || NGPackSync.shared.owns(catalogID: pack.catalogID)
    }

    private var ownedCatalogPack: NGPack? {
        SoundPackStore.shared.pack(for: packID)?.catalogID.flatMap { NGPackSync.shared.ownedCatalogPacks[$0] }
    }

    override func numberOfSections(in tableView: UITableView) -> Int {
        return canPublish ? 3 : 2
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        if section == 0 || section == 2 {
            return 1
        }
        return Sounds.allCases.count
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        switch section {
        case 1: return NSLocalizedString("Sounds", comment: "sound pack")
        case 2: return NSLocalizedString("NG Account", comment: "sound pack")
        default: return nil
        }
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        guard section == 2 else { return nil }
        if ownedCatalogPack != nil {
            return NSLocalizedString("This catalog pack is yours. Sounds you change here are published as a new version for everyone who installed it.", comment: "sound pack")
        }
        return NGAccountCenter.shared.isSignedIn
            ? NSLocalizedString("Your packs are backed up to your NG Account. Publish one to share it in the catalog.", comment: "sound pack")
            : NSLocalizedString("Sign in to your NG Account to back up your packs and share them in the catalog.", comment: "sound pack")
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        if indexPath.section == 2 {
            let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
            cell.textLabel?.text = ownedCatalogPack != nil
                ? NSLocalizedString("Manage in Catalog", comment: "sound pack")
                : NGAccountCenter.shared.isSignedIn
                    ? NSLocalizedString("Publish to Catalog", comment: "sound pack")
                    : NSLocalizedString("Sign In or Create Account", comment: "sound pack")
            cell.accessoryType = .disclosureIndicator
            return cell
        }
        if indexPath.section == 0 {
            let cell = UITableViewCell(style: .value1, reuseIdentifier: nil)
            let packName = SoundPackStore.shared.pack(for: packID)?.name ?? NSLocalizedString("Sound Pack", comment: "sound pack")
            cell.textLabel?.text = NSLocalizedString("Name", comment: "sound pack")
            cell.detailTextLabel?.text = packName
            cell.accessoryType = .disclosureIndicator
            cell.accessibilityLabel = NSLocalizedString("Name", comment: "sound pack")
            cell.accessibilityValue = packName
            return cell
        }

        let sound = Sounds.allCases[indexPath.row]
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        cell.textLabel?.text = sound.title
        if SoundPackStore.shared.hasCustomSound(sound, in: packID) {
            cell.detailTextLabel?.text = NSLocalizedString("Custom", comment: "sound pack")
        } else {
            cell.detailTextLabel?.text = NSLocalizedString("Default", comment: "sound pack")
        }
        cell.accessoryType = .none
        configureAccessibilityActions(for: cell, sound: sound)
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        if indexPath.section == 0 {
            showRenameSoundPackAlert()
            return
        }
        if indexPath.section == 2 {
            let next: UIViewController
            if let owned = ownedCatalogPack {
                next = NGPublishPackViewController(accountPackID: owned.id)
            } else {
                next = NGAccountCenter.shared.isSignedIn ? NGPublishPackViewController(localID: packID) : NGAccountViewController()
            }
            navigationController?.pushViewController(next, animated: true)
            return
        }

        preview(Sounds.allCases[indexPath.row])
    }

    override func tableView(_ tableView: UITableView,
                            contextMenuConfigurationForRowAt indexPath: IndexPath,
                            point: CGPoint) -> UIContextMenuConfiguration? {
        guard indexPath.section == 1 else {
            return nil
        }

        let sound = Sounds.allCases[indexPath.row]
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            guard let self = self else {
                return nil
            }

            var actions = [UIAction]()
            actions.append(UIAction(title: NSLocalizedString("Replace", comment: "sound pack")) { [weak self] _ in
                self?.replace(sound)
            })
            if SoundPackStore.shared.hasCustomSound(sound, in: self.packID) {
                actions.append(UIAction(title: NSLocalizedString("Reset to Default", comment: "sound pack"),
                                        attributes: .destructive) { [weak self] _ in
                    self?.reset(sound, at: indexPath)
                })
            }
            return UIMenu(title: "", children: actions)
        }
    }

    private func updateTitle() {
        title = SoundPackStore.shared.pack(for: packID)?.name ?? NSLocalizedString("Sound Pack", comment: "sound pack")
    }

    private func showRenameSoundPackAlert() {
        let packName = SoundPackStore.shared.pack(for: packID)?.name ?? ""
        let alert = UIAlertController(title: NSLocalizedString("Name", comment: "sound pack"),
                                      message: nil,
                                      preferredStyle: .alert)
        alert.addTextField { textField in
            textField.placeholder = NSLocalizedString("Sound Pack Name", comment: "sound pack")
            textField.text = packName
            textField.clearButtonMode = .whileEditing
        }
        alert.addAction(UIAlertAction(title: NSLocalizedString("Cancel", comment: "alert"), style: .cancel))
        alert.addAction(UIAlertAction(title: NSLocalizedString("OK", comment: "alert"), style: .default) { [weak self, weak alert] _ in
            guard let self = self else {
                return
            }
            let name = alert?.textFields?.first?.text ?? ""
            do {
                try SoundPackStore.shared.renamePack(self.packID, to: name)
                self.updateTitle()
                self.tableView.reloadRows(at: [IndexPath(row: 0, section: 0)], with: .automatic)
            } catch {
                self.showError(error)
            }
        })
        present(alert, animated: true)
    }

    private func configureAccessibilityActions(for cell: UITableViewCell, sound: Sounds) {
        var actions = [
            UIAccessibilityCustomAction(name: NSLocalizedString("Replace", comment: "sound pack")) { [weak self] _ in
                self?.replace(sound)
                return true
            }
        ]
        if SoundPackStore.shared.hasCustomSound(sound, in: packID) {
            actions.append(UIAccessibilityCustomAction(name: NSLocalizedString("Reset to Default", comment: "sound pack")) { [weak self, weak cell] _ in
                guard let self = self,
                      let cell = cell,
                      let indexPath = self.tableView.indexPath(for: cell) else {
                    return false
                }
                self.reset(sound, at: indexPath)
                return true
            })
        }
        cell.accessibilityCustomActions = actions
        cell.accessibilityHint = NSLocalizedString("Double-tap to preview. Long-press for sound options.", comment: "sound pack")
    }

    private func replace(_ sound: Sounds) {
        importingSound = sound
        let picker = UIDocumentPickerViewController(documentTypes: ["public.audio"], in: .import)
        picker.delegate = self
        picker.allowsMultipleSelection = false
        present(picker, animated: true)
    }

    private func reset(_ sound: Sounds, at indexPath: IndexPath) {
        do {
            try SoundPackStore.shared.resetSound(sound, in: packID)
            tableView.reloadRows(at: [indexPath], with: .automatic)
        } catch {
            showError(error)
        }
    }

    private func preview(_ sound: Sounds) {
        do {
            try previewSound(sound, packID: packID)
        } catch {
            showError(error)
        }
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let sound = importingSound, let url = urls.first else {
            importingSound = nil
            return
        }
        importingSound = nil
        do {
            try SoundPackStore.shared.replaceSound(sound, in: packID, with: url)
            tableView.reloadData()
            preview(sound)
        } catch {
            showError(error)
        }
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        importingSound = nil
    }

    private func showError(_ error: Error) {
        let alert = UIAlertController(title: NSLocalizedString("Sound Pack Error", comment: "sound pack"),
                                      message: error.localizedDescription,
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: NSLocalizedString("OK", comment: "alert"), style: .default))
        present(alert, animated: true)
    }
}

private class SoundPackBrowserViewController: UITableViewController {
    private enum InstallationState {
        case notInstalled
        case installed
        case updateAvailable

        var title: String {
            switch self {
            case .notInstalled:
                return NSLocalizedString("Download", comment: "sound pack")
            case .installed:
                return NSLocalizedString("Installed", comment: "sound pack")
            case .updateAvailable:
                return NSLocalizedString("Update", comment: "sound pack")
            }
        }
    }

    private var packs = [RemoteSoundPack]()
    private var isLoading = false
    private var activeDownloadPackID: String?

    init() {
        super.init(style: .grouped)
    }

    required init?(coder: NSCoder) {
        return nil
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = NSLocalizedString("Browse Sound Packs", comment: "sound pack")
        updateDownloadAllButton()
        loadPacks()
    }

    override func numberOfSections(in tableView: UITableView) -> Int {
        return 1
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        if isLoading || packs.isEmpty {
            return 1
        }
        return packs.count
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        return NSLocalizedString("Sound Packs", comment: "sound pack")
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        if isLoading {
            let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
            cell.textLabel?.text = NSLocalizedString("Retrieving Sound Packs...", comment: "sound pack")
            cell.selectionStyle = .none
            return cell
        }
        if packs.isEmpty {
            let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
            cell.textLabel?.text = NSLocalizedString("No packs available.", comment: "sound pack")
            cell.selectionStyle = .none
            return cell
        }

        let pack = packs[indexPath.row]
        let state = installationState(for: pack)
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        cell.textLabel?.text = pack.name
        var detail = String(format: NSLocalizedString("Created by %@", comment: "sound pack"), pack.author)
        if pack.official == true {
            detail = NSLocalizedString("Official", comment: "sound pack") + " · " + detail
        }
        detail += "\n" + String(format: NSLocalizedString("Version %@", comment: "sound pack"), pack.version)
        if let description = pack.description, !description.isEmpty {
            detail += "\n" + description
        }
        cell.detailTextLabel?.numberOfLines = 0
        cell.detailTextLabel?.text = detail
        var accessibilityDetail = String(format: NSLocalizedString("Created by %@, Version %@", comment: "sound pack"), pack.author, pack.version)
        if pack.official == true {
            accessibilityDetail = NSLocalizedString("Official", comment: "sound pack") + ", " + accessibilityDetail
        }
        if pack.official != true {
            cell.accessibilityCustomActions = [UIAccessibilityCustomAction(name: NSLocalizedString("Report", comment: "sound pack")) { [weak self] _ in
                self?.report(pack)
                return true
            }]
        }
        if let description = pack.description, !description.isEmpty {
            accessibilityDetail += ", " + description
        }
        cell.accessibilityLabel = pack.name
        cell.accessibilityValue = accessibilityDetail
        cell.accessoryType = state == .installed ? .checkmark : .disclosureIndicator
        if activeDownloadPackID == pack.id {
            cell.textLabel?.text = pack.name + " - " + NSLocalizedString("Downloading...", comment: "sound pack")
            cell.selectionStyle = .none
        }
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard !isLoading, packs.indices.contains(indexPath.row) else {
            return
        }
        let pack = packs[indexPath.row]
        guard installationState(for: pack) != .installed, activeDownloadPackID == nil else {
            return
        }
        download(pack)
    }

    override func tableView(_ tableView: UITableView, contextMenuConfigurationForRowAt indexPath: IndexPath, point: CGPoint) -> UIContextMenuConfiguration? {
        guard !isLoading, packs.indices.contains(indexPath.row), packs[indexPath.row].official != true else { return nil }
        let pack = packs[indexPath.row]
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            UIMenu(title: "", children: [UIAction(title: NSLocalizedString("Report", comment: "sound pack"), attributes: .destructive) { _ in
                self?.report(pack)
            }])
        }
    }

    /// Tell TeamTalk NG about a pack that shouldn't be in the catalog.
    private func report(_ pack: RemoteSoundPack) {
        guard NGAccountCenter.shared.isSignedIn else {
            let alert = UIAlertController(title: NSLocalizedString("Sign In to Report", comment: "sound pack"),
                                          message: NSLocalizedString("Reporting a pack needs an NG Account.", comment: "sound pack"), preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: NSLocalizedString("OK", comment: "alert"), style: .default))
            present(alert, animated: true)
            return
        }
        let alert = UIAlertController(title: String(format: NSLocalizedString("Report %@", comment: "sound pack"), pack.name),
                                      message: NSLocalizedString("What's wrong with this pack?", comment: "sound pack"), preferredStyle: .alert)
        alert.addTextField { $0.placeholder = NSLocalizedString("Reason", comment: "sound pack") }
        alert.addAction(UIAlertAction(title: NSLocalizedString("Cancel", comment: "alert"), style: .cancel))
        alert.addAction(UIAlertAction(title: NSLocalizedString("Report", comment: "sound pack"), style: .destructive) { [weak self, weak alert] _ in
            let reason = alert?.textFields?.first?.text ?? ""
            Task { @MainActor in
                do {
                    try await NGAccountCenter.shared.signed { try await $0.report(pack.id, reason: reason) }
                    UIAccessibility.post(notification: .announcement, argument: NSLocalizedString("Reported. Thank you.", comment: "sound pack"))
                } catch {
                    self?.showError(error)
                }
            }
        })
        present(alert, animated: true)
    }

    private func loadPacks() {
        guard !isLoading else {
            return
        }
        isLoading = true
        tableView.reloadData()
        SoundPackStore.shared.fetchCatalog { [weak self] result in
            guard let self = self else { return }
            self.isLoading = false
            switch result {
            case .success(let packs):
                self.packs = packs
            case .failure(let error):
                self.packs = []
                self.showError(error)
            }
            self.updateDownloadAllButton()
            self.tableView.reloadData()
        }
    }

    private func installationState(for pack: RemoteSoundPack) -> InstallationState {
        guard let installedPack = SoundPackStore.shared.installedPack(catalogID: pack.id) else {
            return .notInstalled
        }
        return installedPack.version == pack.version ? .installed : .updateAvailable
    }

    private func download(_ pack: RemoteSoundPack, selectAfterImport: Bool = true, completion: (() -> Void)? = nil) {
        activeDownloadPackID = pack.id
        tableView.reloadData()
        SoundPackStore.shared.downloadCatalogPack(pack) { [weak self] result in
            guard let self = self else { return }
            defer {
                self.activeDownloadPackID = nil
                self.updateDownloadAllButton()
                self.tableView.reloadData()
                completion?()
            }
            do {
                let archiveURL = try result.get()
                _ = try SoundPackStore.shared.importCatalogPackArchive(from: archiveURL, remotePack: pack, selectAfterImport: selectAfterImport)
                Task { await NGAccountAPI(baseURL: MonitorService.baseURL, token: nil).countInstall(pack.id) }
            } catch {
                self.showError(error)
            }
        }
    }

    @objc private func downloadAllPacks() {
        guard activeDownloadPackID == nil else {
            return
        }
        let packsToDownload = packs.filter { installationState(for: $0) != .installed }
        guard !packsToDownload.isEmpty else {
            return
        }
        let originalSelectedPackID = SoundPackStore.shared.selectedPackID
        downloadNext(packsToDownload, originalSelectedPackID: originalSelectedPackID)
    }

    private func downloadNext(_ packs: [RemoteSoundPack], originalSelectedPackID: String) {
        guard let pack = packs.first else {
            SoundPackStore.shared.selectPack(originalSelectedPackID)
            updateDownloadAllButton()
            return
        }
        download(pack, selectAfterImport: false) { [weak self] in
            self?.downloadNext(Array(packs.dropFirst()), originalSelectedPackID: originalSelectedPackID)
        }
    }

    private func updateDownloadAllButton() {
        let hasDownloadablePacks = packs.contains { installationState(for: $0) != .installed }
        navigationItem.rightBarButtonItem = hasDownloadablePacks ?
            UIBarButtonItem(title: NSLocalizedString("Download All", comment: "sound pack"),
                            style: .plain,
                            target: self,
                            action: #selector(downloadAllPacks)) :
            nil
    }

    private func showError(_ error: Error) {
        let alert = UIAlertController(title: NSLocalizedString("Sound Pack Error", comment: "sound pack"),
                                      message: error.localizedDescription,
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: NSLocalizedString("OK", comment: "alert"), style: .default))
        present(alert, animated: true)
    }
}

class SoundPackUpdatesViewController: UITableViewController {
    private var packs: [RemoteSoundPack]
    private var activeDownloadPackID: String?

    init(packs: [RemoteSoundPack]) {
        self.packs = packs
        super.init(style: .grouped)
    }

    required init?(coder: NSCoder) {
        return nil
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = NSLocalizedString("Sound Pack Updates", comment: "sound pack")
        updateAllButton()
    }

    override func numberOfSections(in tableView: UITableView) -> Int {
        return 1
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return packs.isEmpty ? 1 : packs.count
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        return nil
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        if packs.isEmpty {
            let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
            cell.textLabel?.text = NSLocalizedString("No updates available.", comment: "sound pack")
            cell.selectionStyle = .none
            return cell
        }

        let pack = packs[indexPath.row]
        let installedVersion = SoundPackStore.shared.installedPack(catalogID: pack.id)?.version ?? NSLocalizedString("Unknown", comment: "sound pack")
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        cell.textLabel?.text = activeDownloadPackID == pack.id ?
            pack.name + " - " + NSLocalizedString("Updating...", comment: "sound pack") :
            pack.name
        cell.detailTextLabel?.text = String(format: NSLocalizedString("Your version: %@\nNew version: %@", comment: "sound pack"), installedVersion, pack.version)
        cell.detailTextLabel?.numberOfLines = 0
        cell.accessoryType = activeDownloadPackID == nil ? .disclosureIndicator : .none
        cell.selectionStyle = activeDownloadPackID == nil ? .default : .none
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard activeDownloadPackID == nil, packs.indices.contains(indexPath.row) else {
            return
        }

        update(pack: packs[indexPath.row])
    }

    @objc private func updateAllPacks() {
        guard activeDownloadPackID == nil else {
            return
        }

        updateNext(packs)
    }

    private func updateNext(_ packsToUpdate: [RemoteSoundPack]) {
        guard let pack = packsToUpdate.first else {
            return
        }

        update(pack: pack) { [weak self] in
            self?.updateNext(Array(packsToUpdate.dropFirst()))
        }
    }

    private func update(pack: RemoteSoundPack, completion: (() -> Void)? = nil) {
        activeDownloadPackID = pack.id
        tableView.reloadData()
        SoundPackStore.shared.downloadCatalogPack(pack) { [weak self] result in
            guard let self = self else { return }
            defer {
                self.activeDownloadPackID = nil
                self.removePackFromUpdateList(pack)
                self.updateAllButton()
                self.tableView.reloadData()
                completion?()
            }

            do {
                let archiveURL = try result.get()
                _ = try SoundPackStore.shared.importCatalogPackArchive(from: archiveURL, remotePack: pack, selectAfterImport: false)
            } catch {
                self.showError(error)
            }
        }
    }

    private func removePackFromUpdateList(_ pack: RemoteSoundPack) {
        if SoundPackStore.shared.installedPack(catalogID: pack.id)?.version == pack.version {
            packs.removeAll { $0.id == pack.id }
        }
    }

    private func updateAllButton() {
        navigationItem.rightBarButtonItem = packs.isEmpty ?
            nil :
            UIBarButtonItem(title: NSLocalizedString("Update All", comment: "sound pack"),
                            style: .plain,
                            target: self,
                            action: #selector(updateAllPacks))
    }

    private func showError(_ error: Error) {
        let alert = UIAlertController(title: NSLocalizedString("Sound Pack Error", comment: "sound pack"),
                                      message: error.localizedDescription,
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: NSLocalizedString("OK", comment: "alert"), style: .default))
        present(alert, animated: true)
    }
}
