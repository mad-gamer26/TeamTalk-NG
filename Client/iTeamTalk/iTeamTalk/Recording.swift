/*
 * Recording conversations, like TeamTalk for Windows and macOS: the
 * channel's audio into one file (everyone's voice mixed, and media files
 * streamed in the channel unless turned off), and/or a separate file for
 * each person. Audio files this app streams go out as voice, so they are
 * recorded as voice. Recordings go to the Recordings folder of TeamTalk NG's documents,
 * which the Files app shows.
 *
 * A channel can forbid recording (CHANNEL_NO_RECORDING); then only users
 * with the right to record voice in all channels, or administrators, may.
 * While recording is on it follows this session: joining another channel
 * starts new files there, and after a lost connection it starts again once
 * the channel is joined again.
 */

import AVFoundation
import QuickLook
import UIKit

let PREF_RECORD_CHANNEL_FILE = "RecordChannelFile"
let PREF_RECORD_USER_FILES = "RecordUserFiles"
let PREF_RECORD_MEDIA_FILES = "RecordMediaFiles"

// Recordings are WAV files, the format TeamTalk's iPhone library writes. It
// rewrites the header as it goes, so a recording survives the app closing.
/// What to record, as chosen in the recording settings.
struct RecordingChoices {
    var channelFile: Bool
    var userFiles: Bool
    /// Media files streamed in the channel (TeamTalk's media file stream)
    /// go into the channel file too.
    var mediaFiles: Bool

    static var current: RecordingChoices {
        let d = UserDefaults.standard
        return RecordingChoices(channelFile: d.object(forKey: PREF_RECORD_CHANNEL_FILE) == nil || d.bool(forKey: PREF_RECORD_CHANNEL_FILE),
                                userFiles: d.bool(forKey: PREF_RECORD_USER_FILES),
                                mediaFiles: d.object(forKey: PREF_RECORD_MEDIA_FILES) == nil || d.bool(forKey: PREF_RECORD_MEDIA_FILES))
    }
}

func recordingsDirectory() throws -> URL {
    let documents = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask,
                                                appropriateFor: nil, create: true)
    let folder = documents.appendingPathComponent("Recordings", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
}

/// Records one server session's channel. Used on the main thread.
final class ChannelRecorder {
    /// Recording is on (it may be waiting for a channel to be joined).
    private(set) var wanted = false
    /// The channel being recorded, 0 when none.
    private(set) var channelID: INT32 = 0
    private(set) var channelName = ""
    private(set) var since: Date?
    /// The channel file being written.
    private(set) var channelFile: URL?
    /// The folder the per-person files go to.
    private(set) var userFolder: URL?
    /// What the current files record.
    private var recording: RecordingChoices?
    /// The recorded channel's audio format (see `format(of:)`).
    private var codecFormat = ""
    /// Users whose audio is stored in `userFolder` (0 is this user).
    private var recordedUsers = Set<INT32>()

    private let instance: () -> UnsafeMutableRawPointer?
    private let serverName: () -> String

    /// Called after anything changes (for the toolbar and the screen).
    var changed: () -> Void = {}

    init(instance: @escaping () -> UnsafeMutableRawPointer?, serverName: @escaping () -> String) {
        self.instance = instance
        self.serverName = serverName
    }

    var isRecording: Bool { channelFile != nil || userFolder != nil }

    /// Starts recording the channel this user is in. Returns why it could
    /// not, in words.
    func start() -> String? {
        guard let inst = instance() else { return NSLocalizedString("Not connected.", comment: "recording") }
        let choices = RecordingChoices.current
        guard choices.channelFile || choices.userFiles else {
            return NSLocalizedString("Choose what to record: one file for the channel, a file for each person, or both.", comment: "recording")
        }
        let channel = TT_GetMyChannelID(inst)
        guard channel > 0 else { return NSLocalizedString("Join a channel to record it.", comment: "recording") }
        wanted = true
        if let error = begin(channel: channel) {
            wanted = false
            changed()
            return error
        }
        announce(NSLocalizedString("Recording started.", comment: "recording"))
        return nil
    }

    func stop() {
        guard wanted || isRecording else { return }
        wanted = false
        let had = isRecording
        end()
        if had {
            announce(NSLocalizedString("Recording stopped. It is in the Recordings folder in the Files app.", comment: "recording"))
        }
    }

    // MARK: Following the session

    /// This user joined a channel.
    func joinedChannel(_ id: INT32) {
        guard wanted, id != channelID else { return }
        end()
        if let error = begin(channel: id) {
            wanted = false
            changed()
            announce(error)
        } else {
            announce(String(format: NSLocalizedString("Recording %@.", comment: "recording"), channelName))
        }
    }

    /// This user left the channel (recording waits for the next one).
    func leftChannel() {
        end()
    }

    /// The connection was lost: the files are closed; recording starts
    /// again in new files once a channel is joined.
    func connectionLost() {
        end()
    }

    func userJoined(_ user: User) {
        guard userFolder != nil, user.nChannelID == channelID, let inst = instance() else { return }
        let id = user.nUserID == TT_GetMyUserID(inst) ? 0 : user.nUserID
        storeUser(id, inst: inst)
    }

    func userLeft(_ user: User) {
        guard let inst = instance(), recordedUsers.remove(user.nUserID) != nil else { return }
        TT_SetUserMediaStorageDir(inst, user.nUserID, "", "", AFF_NONE)
    }

    /// The recorded channel changed: new files for a new codec; recording
    /// stops if the channel no longer allows it.
    func channelUpdated(_ channel: Channel) {
        guard isRecording, channel.nChannelID == channelID, let inst = instance() else { return }
        if allowed(channel, inst: inst) == false {
            wanted = false
            end()
            announce(NSLocalizedString("Recording stopped: this channel no longer allows recording.", comment: "recording"))
            return
        }
        if Self.format(of: channel) != codecFormat {
            end()
            if let error = begin(channel: channel.nChannelID) {
                wanted = false
                changed()
                announce(error)
            }
        }
    }

    /// A file of one person could not be written.
    func recordingEvent(userID: INT32, info: MediaFileInfo) {
        guard info.nStatus == MFS_ERROR, let inst = instance() else { return }
        var user = User()
        let name = userID == 0 || TT_GetUser(inst, userID, &user) == FALSE
            ? NSLocalizedString("your", comment: "recording: whose audio")
            : String(format: NSLocalizedString("%@'s", comment: "recording: whose audio"), getUser(user, strprop: NICKNAME))
        announce(String(format: NSLocalizedString("Could not record %@ audio.", comment: "recording"), name))
    }

    // MARK: Files

    private func allowed(_ channel: Channel, inst: UnsafeMutableRawPointer) -> Bool {
        if channel.uChannelType & CHANNEL_NO_RECORDING.rawValue == 0 { return true }
        if TT_GetMyUserRights(inst) & USERRIGHT_RECORD_VOICE.rawValue != 0 { return true }
        return TT_GetMyUserType(inst) & USERTYPE_ADMIN.rawValue != 0
    }

    private func begin(channel id: INT32) -> String? {
        guard let inst = instance() else { return NSLocalizedString("Not connected.", comment: "recording") }
        var channel = Channel()
        guard TT_GetChannel(inst, id, &channel) == TRUE else {
            return NSLocalizedString("The channel could not be found.", comment: "recording")
        }
        guard allowed(channel, inst: inst) else {
            return NSLocalizedString("This channel does not allow recording.", comment: "recording")
        }
        let choices = RecordingChoices.current
        let name = getChannel(channel, strprop: NAME)
        channelName = name.isEmpty ? serverName() : name
        let folder: URL
        do {
            folder = try recordingsDirectory()
        } catch {
            return NSLocalizedString("The Recordings folder could not be made.", comment: "recording")
        }
        let stamp = Self.stamp.string(from: Date())
        let base = Self.safe("\(stamp) \(serverName()) - \(channelName)")
        codecFormat = Self.format(of: channel)
        recording = choices

        if choices.channelFile {
            if channel.audiocodec.nCodec == NO_CODEC {
                return NSLocalizedString("This channel has no audio to record.", comment: "recording")
            }
            let url = folder.appendingPathComponent("\(base).wav")
            var streams = STREAMTYPE_VOICE.rawValue
            if choices.mediaFiles { streams |= STREAMTYPE_MEDIAFILE_AUDIO.rawValue }
            var reference = channel.audiocodec
            guard TT_StartRecordingMuxedStreams(inst, streams, &reference, url.path, AFF_WAVE_FORMAT) == TRUE else {
                return NSLocalizedString("TeamTalk could not start recording the channel to a file.", comment: "recording")
            }
            channelFile = url
        }
        if choices.userFiles {
            let users = folder.appendingPathComponent(base, isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: users, withIntermediateDirectories: true)
            } catch {
                end()
                return NSLocalizedString("The folder for each person's files could not be made.", comment: "recording")
            }
            userFolder = users
            let me = TT_GetMyUserID(inst)
            for user in Self.users(in: id, inst: inst) {
                storeUser(user.nUserID == me ? 0 : user.nUserID, inst: inst)
            }
            if recordedUsers.contains(0) == false { storeUser(0, inst: inst) }
        }
        channelID = id
        since = Date()
        recording = choices
        changed()
        return nil
    }

    private func storeUser(_ id: INT32, inst: UnsafeMutableRawPointer) {
        guard let userFolder else { return }
        if TT_SetUserMediaStorageDir(inst, id, userFolder.path, "%Y%m%d-%H%M%S %nickname%", AFF_WAVE_FORMAT) == TRUE {
            recordedUsers.insert(id)
        }
    }

    private func end() {
        if let inst = instance() {
            if channelFile != nil {
                TT_StopRecordingMuxedAudioFile(inst)
            }
            for id in recordedUsers {
                TT_SetUserMediaStorageDir(inst, id, "", "", AFF_NONE)
            }
        }
        recordedUsers.removeAll()
        channelFile = nil
        userFolder = nil
        channelID = 0
        since = nil
        recording = nil
        changed()
    }

    private func announce(_ text: String) {
        UIAccessibility.post(notification: .announcement, argument: text)
    }

    /// What a recording of this channel looks like (its codec's format).
    private static func format(of channel: Channel) -> String {
        var c = channel.audiocodec
        switch c.nCodec {
        case OPUS_CODEC:
            let o = getOpusCodec(&c).pointee
            return "opus \(o.nSampleRate) \(o.nChannels)"
        case SPEEX_CODEC:
            return "speex \(getSpeexCodec(&c).pointee.nBandmode)"
        case SPEEX_VBR_CODEC:
            return "speex \(getSpeexVBRCodec(&c).pointee.nBandmode)"
        default:
            return "\(c.nCodec.rawValue)"
        }
    }

    private static func users(in channel: INT32, inst: UnsafeMutableRawPointer) -> [User] {
        var count: INT32 = 0
        guard TT_GetChannelUsers(inst, channel, nil, &count) == TRUE, count > 0 else { return [] }
        var users = [User](repeating: User(), count: Int(count))
        guard TT_GetChannelUsers(inst, channel, &users, &count) == TRUE else { return [] }
        return Array(users.prefix(Int(count)))
    }

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return f
    }()

    /// A name usable as a file name.
    private static func safe(_ name: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:?%*|\"<>").union(.controlCharacters)
        let cleaned = name.components(separatedBy: bad).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(cleaned.prefix(120))
    }
}

/// The recording screen: start and stop, what to record and in which
/// format, and the recordings made.
final class RecordingViewController: UITableViewController {
    var recorder: ChannelRecorder?
    /// Whether this user may record the current channel, and why not.
    var problem: () -> String? = { nil }

    private enum Row {
        case status, toggle
        case channelFile, mediaFiles, userFiles
        case recordings
    }

    private var sections: [(title: String?, footer: String?, rows: [Row])] = []

    override func viewDidLoad() {
        super.viewDidLoad()
        title = NSLocalizedString("Record", comment: "recording")
        navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .done, target: self, action: #selector(done))
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "Recording")
        reload()
    }

    @objc private func done() {
        dismiss(animated: true)
    }

    func reload() {
        let choices = RecordingChoices.current
        var what: [Row] = [.channelFile]
        if choices.channelFile { what.append(.mediaFiles) }
        what.append(.userFiles)
        sections = [
            (nil, problem(), [.status, .toggle]),
            (NSLocalizedString("What to Record", comment: "recording"),
             NSLocalizedString("Your own voice is included. Changes apply to the next recording.", comment: "recording"), what),
            (nil, NSLocalizedString("Recordings are also in the Files app: On My iPhone, TeamTalk NG, Recordings.", comment: "recording"), [.recordings]),
        ]
        tableView.reloadData()
    }

    private func statusText() -> String {
        guard let recorder else { return "" }
        if recorder.isRecording, let since = recorder.since {
            let time = DateFormatter.localizedString(from: since, dateStyle: .none, timeStyle: .short)
            var parts = [String(format: NSLocalizedString("Recording %@ since %@.", comment: "recording"), recorder.channelName, time)]
            if let file = recorder.channelFile { parts.append(String(format: NSLocalizedString("File: %@.", comment: "recording"), file.lastPathComponent)) }
            if let folder = recorder.userFolder { parts.append(String(format: NSLocalizedString("Each person's files: %@.", comment: "recording"), folder.lastPathComponent)) }
            return parts.joined(separator: " ")
        }
        if recorder.wanted {
            return NSLocalizedString("Recording starts when you join a channel.", comment: "recording")
        }
        return NSLocalizedString("Not recording.", comment: "recording")
    }

    override func numberOfSections(in tableView: UITableView) -> Int { sections.count }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { sections[section].rows.count }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? { sections[section].title }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? { sections[section].footer }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        cell.textLabel?.numberOfLines = 0
        let choices = RecordingChoices.current
        let active = recorder?.wanted == true
        switch sections[indexPath.section].rows[indexPath.row] {
        case .status:
            cell.textLabel?.text = statusText()
            cell.selectionStyle = .none
            cell.accessibilityTraits = .staticText
        case .toggle:
            cell.textLabel?.text = active ? NSLocalizedString("Stop Recording", comment: "recording")
                                          : NSLocalizedString("Start Recording", comment: "recording")
            cell.textLabel?.textColor = active ? .systemRed : view.tintColor
            cell.accessibilityTraits = .button
        case .channelFile:
            switchCell(cell, NSLocalizedString("One file for the whole channel", comment: "recording"), choices.channelFile, PREF_RECORD_CHANNEL_FILE)
        case .mediaFiles:
            switchCell(cell, NSLocalizedString("Include Media Files", comment: "recording"), choices.mediaFiles, PREF_RECORD_MEDIA_FILES)
        case .userFiles:
            switchCell(cell, NSLocalizedString("A separate file for each person", comment: "recording"), choices.userFiles, PREF_RECORD_USER_FILES)
        case .recordings:
            cell.textLabel?.text = NSLocalizedString("Recordings", comment: "recording")
            cell.accessoryType = .disclosureIndicator
            cell.accessibilityTraits = .button
        }
        return cell
    }

    private func switchCell(_ cell: UITableViewCell, _ text: String, _ on: Bool, _ key: String) {
        cell.textLabel?.text = text
        cell.selectionStyle = .none
        let toggle = UISwitch()
        toggle.isOn = on
        toggle.accessibilityLabel = text
        toggle.addAction(UIAction { [weak self] action in
            UserDefaults.standard.set((action.sender as? UISwitch)?.isOn == true, forKey: key)
            self?.reload()
        }, for: .valueChanged)
        cell.accessoryView = toggle
        // The switch is the control VoiceOver lands on.
        cell.isAccessibilityElement = false
        cell.textLabel?.isAccessibilityElement = false
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        switch sections[indexPath.section].rows[indexPath.row] {
        case .toggle:
            guard let recorder else { return }
            if recorder.wanted {
                recorder.stop()
            } else if let error = recorder.start() {
                let alert = UIAlertController(title: NSLocalizedString("Record", comment: "recording"), message: error, preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: NSLocalizedString("OK", comment: "message dialog"), style: .default))
                present(alert, animated: true)
            }
            reload()
        case .recordings:
            if let folder = try? recordingsDirectory() {
                navigationController?.pushViewController(RecordingsListViewController(folder: folder), animated: true)
            }
        default:
            break
        }
    }
}

/// QuickLook for one file. Its player leaves the audio session with its
/// own settings, so TeamTalk's go back once the preview has closed.
final class TeamTalkPreviewController: QLPreviewController, QLPreviewControllerDataSource {
    private let url: URL

    init(url: URL) {
        self.url = url
        super.init(nibName: nil, bundle: nil)
        dataSource = self
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isBeingDismissed || presentingViewController == nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                ConnectedServerManager.shared.restoreSoundDevices()
            }
        }
    }

    func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }

    func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
        url as NSURL
    }
}

/// The recordings in a folder, newest first: play, share or delete them.
final class RecordingsListViewController: UITableViewController, QLPreviewControllerDataSource {
    private let folder: URL
    private var items: [URL] = []
    private var previewing: URL?

    init(folder: URL) {
        self.folder = folder
        super.init(style: .insetGrouped)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = folder.lastPathComponent
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "Recording")
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        load()
    }

    private func load() {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isDirectoryKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys,
                                                                 options: .skipsHiddenFiles)) ?? []
        items = urls.sorted {
            let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return a > b
        }
        tableView.reloadData()
    }

    private func isFolder(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        max(items.count, 1)
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        cell.textLabel?.numberOfLines = 0
        guard items.isEmpty == false else {
            cell.textLabel?.text = NSLocalizedString("No recordings yet.", comment: "recording")
            cell.selectionStyle = .none
            return cell
        }
        let url = items[indexPath.row]
        cell.textLabel?.text = url.lastPathComponent
        if isFolder(url) {
            let count = (try? FileManager.default.contentsOfDirectory(atPath: url.path).count) ?? 0
            cell.detailTextLabel?.text = String(format: NSLocalizedString("Folder, %d files", comment: "recording"), count)
            cell.accessoryType = .disclosureIndicator
        } else {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            cell.detailTextLabel?.text = ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
        }
        cell.accessibilityTraits = .button
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard items.isEmpty == false else { return }
        let url = items[indexPath.row]
        if isFolder(url) {
            navigationController?.pushViewController(RecordingsListViewController(folder: url), animated: true)
            return
        }
        let sheet = UIAlertController(title: url.lastPathComponent, message: nil, preferredStyle: .actionSheet)
        sheet.addAction(UIAlertAction(title: NSLocalizedString("Play", comment: "recording"), style: .default) { [weak self] _ in
            self?.play(url)
        })
        sheet.addAction(UIAlertAction(title: NSLocalizedString("Share", comment: "recording"), style: .default) { [weak self] _ in
            self?.share(url, from: tableView.cellForRow(at: indexPath))
        })
        sheet.addAction(UIAlertAction(title: NSLocalizedString("Delete", comment: "recording"), style: .destructive) { [weak self] _ in
            self?.delete(url)
        })
        sheet.addAction(UIAlertAction(title: NSLocalizedString("Cancel", comment: "recording"), style: .cancel))
        sheet.popoverPresentationController?.sourceView = tableView.cellForRow(at: indexPath) ?? view
        present(sheet, animated: true)
    }

    override func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard items.isEmpty == false else { return nil }
        let url = items[indexPath.row]
        let delete = UIContextualAction(style: .destructive, title: NSLocalizedString("Delete", comment: "recording")) { [weak self] _, _, done in
            self?.delete(url)
            done(true)
        }
        return UISwipeActionsConfiguration(actions: [delete])
    }

    private func play(_ url: URL) {
        previewing = url
        let preview = TeamTalkPreviewController(url: url)
        present(preview, animated: true)
    }

    private func share(_ url: URL, from cell: UITableViewCell?) {
        let share = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        share.popoverPresentationController?.sourceView = cell ?? view
        present(share, animated: true)
    }

    private func delete(_ url: URL) {
        do {
            try FileManager.default.removeItem(at: url)
            UIAccessibility.post(notification: .announcement,
                                 argument: String(format: NSLocalizedString("Deleted %@.", comment: "recording"), url.lastPathComponent))
        } catch {
            UIAccessibility.post(notification: .announcement,
                                 argument: NSLocalizedString("The recording could not be deleted. It may still be recording.", comment: "recording"))
        }
        load()
    }

    func numberOfPreviewItems(in controller: QLPreviewController) -> Int { previewing == nil ? 0 : 1 }

    func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
        (previewing ?? folder) as NSURL
    }
}
