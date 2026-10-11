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
import SwiftUI
import IntentsUI
import OSLog

@available(iOS 14.0, *)
struct NativeDisclosureHeader: View {
    let title: String
    let subtitle: String?
    let isExpanded: Bool
    let leadingPadding: CGFloat
    /// VoiceOver actions of the header (a channel's).
    var actions: [(String, () -> Void)] = []
    let toggle: () -> Void

    var body: some View {
        DisclosureGroup(
            isExpanded: Binding(
                get: { isExpanded },
                set: { newValue in
                    if newValue != isExpanded {
                        toggle()
                    }
                }
            ),
            content: {
                EmptyView()
            },
            label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.body)
                        .foregroundColor(.primary)
                    if let subtitle = subtitle, subtitle.isEmpty == false {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
        )
        .accessibilityAddTraits([.isButton, .isHeader])
        .accessibilityActions {
            ForEach(Array(actions.enumerated()), id: \.offset) { _, action in
                Button(action.0, action: action.1)
            }
        }
        .padding(.leading, leadingPadding)
        .padding(.trailing, 16)
        .padding(.vertical, 8)
        .background(Color(CompactUI.secondaryBackgroundColor))
    }
}

class SettingsSectionHeaderView: UITableViewHeaderFooterView {
    let disclosureImageView = UIImageView()
    let titleLabel = UILabel()
    var accessibilityActivationHandler: (() -> Bool)?

    override init(reuseIdentifier: String?) {
        super.init(reuseIdentifier: reuseIdentifier)
        configureLayout()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureLayout()
    }

    func configureLayout() {
        contentView.backgroundColor = CompactUI.secondaryBackgroundColor

        disclosureImageView.translatesAutoresizingMaskIntoConstraints = false
        disclosureImageView.contentMode = .center
        disclosureImageView.tintColor = CompactUI.secondaryTextColor
        disclosureImageView.isAccessibilityElement = false

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        CompactUI.stylePrimaryLabel(titleLabel)
        titleLabel.isAccessibilityElement = false

        contentView.addSubview(disclosureImageView)
        contentView.addSubview(titleLabel)

        NSLayoutConstraint.activate([
            disclosureImageView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            disclosureImageView.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            disclosureImageView.widthAnchor.constraint(equalToConstant: 24),
            disclosureImageView.heightAnchor.constraint(equalToConstant: 24),

            titleLabel.leadingAnchor.constraint(equalTo: disclosureImageView.trailingAnchor, constant: 8),
            titleLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            titleLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),
            titleLabel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8)
        ])

        isAccessibilityElement = true
        accessibilityTraits = [.button, .header]
    }

    func configure(title: String, isExpanded: Bool) {
        titleLabel.text = title
        if #available(iOS 13.0, *) {
            disclosureImageView.image = UIImage(systemName: isExpanded ? "chevron.down" : "chevron.right")
        }
        else {
            disclosureImageView.image = nil
        }
        accessibilityLabel = title
        accessibilityValue = nil
        accessibilityHint = nil
    }

    override func accessibilityActivate() -> Bool {
        return accessibilityActivationHandler?() ?? super.accessibilityActivate()
    }
}

let PREF_GENERAL_NICKNAME = "nickname_preference"
let PREF_GENERAL_STATUSMESSAGE = "statusmsg_preference"
let PREF_GENERAL_GENDER = "gender_preference"
let PREF_GENERAL_GENDER_NEUTRAL_MIGRATED = "gender_neutral_migrated_preference"
let PREF_GENERAL_GENDER_ORDER_MIGRATED = "gender_order_migrated_preference"
let PREF_GENERAL_PTTLOCK = "general_pttlock_preference"
let PREF_GENERAL_SENDONRETURN = "general_sendonreturn_preference"
let PREF_JOINROOTCHANNEL = "joinroot_preference"

let PREF_DISPLAY_SHOWUSERNAME = "display_showusername_preference"
let PREF_DISPLAY_POPUPTXTMSG = "display_popuptxtmsg_preference"
let PREF_DISPLAY_LIMITTEXT = "display_limittext_preference"
let PREF_DISPLAY_SORTCHANNELS = "display_sortchannels_preference"
let PREF_FILES_SORT_FIELD = "files_sort_field_preference"
let PREF_FILES_SORT_ASCENDING = "files_sort_ascending_preference"

enum FileSortField: String, CaseIterable {
    case name
    case size
    case owner
    case date
}

func preferredFileSortField() -> FileSortField {
    guard let value = UserDefaults.standard.string(forKey: PREF_FILES_SORT_FIELD),
          let field = FileSortField(rawValue: value) else {
        return .name
    }
    return field
}

func preferredFileSortAscending() -> Bool {
    let defaults = UserDefaults.standard
    return defaults.object(forKey: PREF_FILES_SORT_ASCENDING) == nil
        || defaults.bool(forKey: PREF_FILES_SORT_ASCENDING)
}

func saveFileSortPreferences(field: FileSortField, ascending: Bool) {
    let defaults = UserDefaults.standard
    defaults.set(field.rawValue, forKey: PREF_FILES_SORT_FIELD)
    defaults.set(ascending, forKey: PREF_FILES_SORT_ASCENDING)
    NotificationCenter.default.post(name: .fileSortPreferenceDidChange, object: nil)
}

/// Audio files you stream start again when they end.
let PREF_STREAM_LOOP = "stream_loop_preference"

/// How loud what you stream is sent, 0 to 100 % like the other volume
/// sliders: 50 % leaves it unchanged.
let PREF_STREAM_FILE_VOLUME = "stream_file_volume_percent"
let PREF_STREAM_AUDIONET_VOLUME = "stream_audionet_volume_percent"

func streamVolumePercent(_ key: String) -> Double {
    let defaults = UserDefaults.standard
    guard defaults.object(forKey: key) != nil else { return Double(DEFAULT_AUDIO_LEVEL_PERCENT) }
    return min(100, max(0, defaults.double(forKey: key)))
}

/// A stream volume as a TeamTalk gain level, on the same curve as the
/// other volume sliders (50 % is SOUND_GAIN_DEFAULT, no change).
func streamGainLevel(percent: Double) -> Int {
    refVolume(percent)
}

/// Others' audio files relative to voice, 0 to 1 (BearWare's key).
let PREF_MEDIAFILE_VOLUME = "mediafile_volume_preference"

/// The media file volume in percent, nil while it has never been set.
func preferredAudioFileVolumePercent() -> Double? {
    guard UserDefaults.standard.object(forKey: PREF_MEDIAFILE_VOLUME) != nil else { return nil }
    return Double(UserDefaults.standard.float(forKey: PREF_MEDIAFILE_VOLUME)) * 100
}

func saveAudioFileVolume(percent: Double) {
    UserDefaults.standard.set(Float(percent / 100), forKey: PREF_MEDIAFILE_VOLUME)
    for session in ConnectedServerManager.shared.sessions {
        session.applyAudioFileVolumeToEveryone()
    }
}

let PREF_MASTER_VOLUME = "mastervolume_preference"
let PREF_MICROPHONE_GAIN = "microphonegain_preference"
let DEFAULT_AUDIO_LEVEL_PERCENT = 50
let PREF_SPEAKER_OUTPUT = "speakeroutput_preference"
let PREF_BLUETOOTH_A2DP = "bluetooth_a2dp_preference"
let PREF_ALLOW_BLUETOOTH_MICROPHONES = "allow_bluetooth_microphones_preference"
let PREF_VOICE_PROCESSING = "voiceprocessing_preference"
let PREF_SNDINPUT_PORT = "sndinput_port_preference" // postfix of key is AVAudioSessionPortDescription.uid. Value is dataSourceID
let PREF_SNDINPUT_DEVICE = "sndinput_device_preference" // AVAudioSessionPortDescription.uid

let PREF_SNDEVENT_SERVERLOST = "snd_srvlost_preference"
let PREF_SNDEVENT_VOICETX = "snd_voicetx_preference"
let PREF_SNDEVENT_VOICETX_ON = "snd_voicetx_on_preference"
let PREF_SNDEVENT_VOICETX_OFF = "snd_voicetx_off_preference"
let PREF_SNDEVENT_CHANMSG = "snd_chanmsg_preference"
let PREF_SNDEVENT_USERMSG = "snd_usermsg_preference"
let PREF_SNDEVENT_BCASTMSG = "snd_bcastmsg_preference"
let PREF_SNDEVENT_JOINEDCHAN = "snd_joinedchan_preference"
let PREF_SNDEVENT_LEFTCHAN = "snd_leftchan_preference"
let PREF_SNDEVENT_TRANSMITREADY = "snd_transmitready_preference"
let PREF_SNDEVENT_TRANSMITREADY_ON = "snd_transmitready_on_preference"
let PREF_SNDEVENT_TRANSMITREADY_OFF = "snd_transmitready_off_preference"
let PREF_SNDEVENT_LOGGEDIN = "snd_loggedin_preference"
let PREF_SNDEVENT_LOGGEDOUT = "snd_loggedout_preference"
let PREF_SNDEVENT_INTERCEPTION = "snd_interception_preference"
let PREF_SNDEVENT_INTERCEPTION_START = "snd_interception_start_preference"
let PREF_SNDEVENT_INTERCEPTION_END = "snd_interception_end_preference"
let PREF_SNDEVENT_FILEUPDATE = "snd_fileupdate_preference"
let PREF_SNDEVENT_FILETXCOMPLETE = "snd_filetx_complete_preference"

let PREF_SUB_USERMSG = "sub_usertextmsg_preference"
let PREF_SUB_CHANMSG = "sub_chantextmsg_preference"
let PREF_SUB_BROADCAST = "sub_broadcastmsg_preference"
let PREF_SUB_VOICE = "sub_voice_preference"
let PREF_SUB_VIDEOCAP = "sub_videocapture_preference"
let PREF_SUB_MEDIAFILE = "sub_mediafile_preference"
let PREF_SUB_DESKTOP = "sub_desktop_preference"
let PREF_SUB_DESKTOPINPUT = "sub_desktopinput_preference"

let PREF_TTSEVENT_VOICEID = "tts_voiceid_preference"
let PREF_TTSEVENT_VOICELANG = "tts_voicelang_preference"
let PREF_TTSEVENT_JOINEDCHAN = "tts_joinedchan_preference"
let PREF_TTSEVENT_LEFTCHAN = "tts_leftchan_preference"
let PREF_TTSEVENT_CONLOST = "tts_conlost_preference"
let PREF_TTSEVENT_TEXTMSG = "tts_usertxtmsg_preference"
let PREF_TTSEVENT_CHANTEXTMSG = "tts_chantxtmsg_preference"
let PREF_TTSEVENT_BROADCASTMSG = "tts_broadcasttxtmsg_preference"
let PREF_TTSEVENT_RATE = "tts_rate_preference"
let PREF_TTSEVENT_VOL = "tts_volume_preference"
let PREF_TTSEVENT_USE_VOICEOVER = "tts_use_voiceover_preference"
let PREF_TTSEVENT_USERLOGIN = "tts_user_login"
let PREF_TTSEVENT_USERLOGOUT = "tts_user_logout"
let PREF_TTSEVENT_SUBSCRIPTIONS = "tts_subscriptions_preference"
let PREF_TTSEVENT_INTERCEPTION = "tts_interception_preference"
let PREF_TTSEVENT_INTERCEPTION_START = "tts_interception_start_preference"
let PREF_TTSEVENT_INTERCEPTION_END = "tts_interception_end_preference"
let PREF_TTSEVENT_FILEUPDATE = "tts_fileupdate_preference"


func preferredGenderIndex() -> Int {
    let defaults = UserDefaults.standard
    let hasSavedGender = defaults.object(forKey: PREF_GENERAL_GENDER) != nil
    var index = hasSavedGender ? defaults.integer(forKey: PREF_GENERAL_GENDER) : 2

    if defaults.object(forKey: PREF_GENERAL_GENDER_ORDER_MIGRATED) == nil {
        if defaults.object(forKey: PREF_GENERAL_GENDER_NEUTRAL_MIGRATED) == nil {
            if hasSavedGender == false {
                index = 2
            }
            else if index == 1 {
                index = 1
            }
            else {
                index = 0
            }
        }
        else {
            switch index {
            case 0:
                index = 2
            case 1:
                index = 0
            case 2:
                index = 1
            default:
                index = 2
            }
        }
        defaults.set(index, forKey: PREF_GENERAL_GENDER)
        defaults.set(true, forKey: PREF_GENERAL_GENDER_NEUTRAL_MIGRATED)
        defaults.set(true, forKey: PREF_GENERAL_GENDER_ORDER_MIGRATED)
    }

    return min(max(index, 0), 2)
}

func preferredStatusMode() -> INT32 {
    switch preferredGenderIndex() {
    case 1:
        return INT32(StatusMode.STATUSMODE_FEMALE.rawValue)
    case 2:
        return INT32(StatusMode.STATUSMODE_NEUTRAL.rawValue)
    default:
        return INT32(StatusMode.STATUSMODE_AVAILABLE.rawValue)
    }
}

func preferredStatusMessage() -> String {
    return UserDefaults.standard.string(forKey: PREF_GENERAL_STATUSMESSAGE) ?? ""
}

func applyPreferredStatus(message: String? = nil) {
    guard ttInst != nil && isConnectedToServer() else {
        return
    }

    let statusMessage = message ?? preferredStatusMessage()
    TT_DoChangeStatus(ttInst, preferredStatusMode(), statusMessage)
}

private enum DiagnosticLogExporter {
    static func export() throws -> URL {
        let archiveBaseName = "TTNG_Logs_\(archiveDateFormatter.string(from: Date()))"
        let archiveURL = uniqueTemporaryURL(fileName: "\(archiveBaseName).zip")
        var entries = [ZIPArchiveEntry]()

        entries.append(ZIPArchiveEntry(filename: "metadata.txt", data: metadataText().data(using: .utf8) ?? Data()))
        entries.append(ZIPArchiveEntry(filename: "app-unified.log", data: unifiedLogText().data(using: .utf8) ?? Data()))

        try ZIPArchive.write(entries: entries, to: archiveURL)
        return archiveURL
    }

    private static func unifiedLogText() -> String {
        guard #available(iOS 15.0, *) else {
            return "Unified log export requires iOS 15 or later.\n"
        }

        do {
            let store = try OSLogStore(scope: .currentProcessIdentifier)
            let position = store.position(date: Date(timeIntervalSinceNow: -7 * 24 * 60 * 60))
            let entries = try store.getEntries(with: [], at: position, matching: nil)
            var lines = [String]()
            for entry in entries {
                lines.append(formatLogEntry(entry))
            }
            return lines.isEmpty ? "No unified log entries were available for this app process.\n" : lines.joined(separator: "\n") + "\n"
        } catch {
            return "Failed to export unified logs: \(error.localizedDescription)\n"
        }
    }

    @available(iOS 15.0, *)
    private static func formatLogEntry(_ entry: OSLogEntry) -> String {
        let timestamp = logDateFormatter.string(from: entry.date)
        var fields = [timestamp]

        if let processEntry = entry as? OSLogEntryFromProcess {
            fields.append("pid=\(processEntry.processIdentifier)")
            fields.append("process=\(processEntry.process)")
            fields.append("sender=\(processEntry.sender)")
        }

        if let logEntry = entry as? OSLogEntryLog {
            fields.append("level=\(levelName(logEntry.level))")
            fields.append("subsystem=\(logEntry.subsystem)")
            fields.append("category=\(logEntry.category)")
        }

        fields.append(entry.composedMessage)
        return fields.joined(separator: " | ")
    }

    @available(iOS 15.0, *)
    private static func levelName(_ level: OSLogEntryLog.Level) -> String {
        switch level {
        case .debug:
            return "debug"
        case .info:
            return "info"
        case .notice:
            return "notice"
        case .error:
            return "error"
        case .fault:
            return "fault"
        case .undefined:
            fallthrough
        @unknown default:
            return "undefined"
        }
    }

    private static func metadataText() -> String {
        var lines = [String]()
        lines.append("Generated: \(logDateFormatter.string(from: Date()))")
        lines.append("App: \(AppInfo.getAppName()) \(AppInfo.getAppVersionLong())")
        lines.append("Bundle Identifier: \(Bundle.main.bundleIdentifier ?? "")")
        lines.append("TeamTalk Library: \(String(cString: TT_GetVersion()))")
        lines.append("System: \(UIDevice.current.systemName) \(UIDevice.current.systemVersion)")
        lines.append("Device: \(UIDevice.current.model)")
        return lines.joined(separator: "\n") + "\n"
    }

    private static func uniqueTemporaryURL(fileName: String) -> URL {
        let baseURL = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        var candidateURL = baseURL
        var index = 1
        while FileManager.default.fileExists(atPath: candidateURL.path) {
            let name = baseURL.deletingPathExtension().lastPathComponent
            let ext = baseURL.pathExtension
            let indexedName = ext.isEmpty ? "\(name)-\(index)" : "\(name)-\(index).\(ext)"
            candidateURL = baseURL.deletingLastPathComponent().appendingPathComponent(indexedName)
            index += 1
        }
        return candidateURL
    }

    private static let archiveDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return formatter
    }()

    private static let logDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS ZZZZZ"
        return formatter
    }()
}

/// The Media File Volume slider (others' media files relative to voice).
func newMediaFileVolumeCell() -> UITableViewCell {
    let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
    let percent = ((preferredAudioFileVolumePercent() ?? Double(DEFAULT_MEDIAFILE_VOLUME) * 100) / 10).rounded() * 10
    let slider = newTableCellSlider(cell, label: NSLocalizedString("Media File Volume", comment: "preferences"),
                                    min: 0, max: 1, initial: Float(percent / 100))
    cell.detailTextLabel?.text = "\(Int(percent)) %"
    slider.addAction(UIAction { [weak cell] action in
        guard let slider = action.sender as? UISlider else { return }
        let percent = Double(Int(slider.value * 10.0) * 10)
        cell?.detailTextLabel?.text = "\(Int(percent)) %"
        saveAudioFileVolume(percent: percent)
    }, for: .valueChanged)
    return cell
}

class SettingsViewController : UITableViewController, UITextFieldDelegate, TeamTalkEvent, INUIAddVoiceShortcutViewControllerDelegate {
    
    var nicknamefield : UITextField?
    var statusmsgfield : UITextField?
    
    var users = Set<INT32>()
    
    var limittextcell : UITableViewCell?
    var limittextfield : UITextField?
    var mastervolcell : UITableViewCell?
    var microphonecell : UITableViewCell?
    var ttsratecell : UITableViewCell?
    var ttsvolcell : UITableViewCell?
    var ttsvoicecell : UITableViewCell?
    var iCloudSwitch: UISwitch?
    var fileSortButton: UIButton?

    var general_items = [UITableViewCell]()
    var display_items = [UITableViewCell]()
    var soundevents_items = [UITableViewCell]()
    var sound_items  = [UITableViewCell]()
    var subscription_items = [UITableViewCell]()
    var connection_items = [UITableViewCell]()
    var ttsevents_items = [UITableViewCell]()
    var siri_shortcuts_items = [UITableViewCell]()
    var version_items = [UITableViewCell]()
    var iCloud_items = [UITableViewCell]()
    var expandedSections = Set<Int>()
    var settingsSectionHeaderHosts = [Int: UIViewController]()
    
    let SECTION_GENERAL = 0,
        SECTION_DISPLAY = 1,
        SECTION_SOUND = 2,
        SECTION_SOUNDEVENTS = 3,
        SECTION_TTSEVENTS = 4,
        SECTION_CONNECTION = 5,
        SECTION_SUBSCRIPTIONS = 6,
        SECTION_SIRI_SHORTCUTS = 7,
        SECTION_ICLOUD = 8,
        SECTION_VERSION = 9,
        SECTIONS_COUNT = 10

    var visibleSettingsSections: [Int] {
        var sections = Array(0..<SECTIONS_COUNT)
        if isConnectedToServer() {
            sections.removeAll { $0 == SECTION_SOUND }
        }
        return sections
    }

    func logicalSettingsSection(for visibleSection: Int) -> Int {
        let sections = visibleSettingsSections
        guard visibleSection < sections.count else {
            return visibleSection
        }
        return sections[visibleSection]
    }

    func visibleSettingsSection(for logicalSection: Int) -> Int? {
        return visibleSettingsSections.firstIndex(of: logicalSection)
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(ttsVoiceDidChange),
                                               name: .ttsVoiceDidChange,
                                               object: nil)
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(fileSortPreferenceChanged),
                                               name: .fileSortPreferenceDidChange,
                                               object: nil)
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(fileSortPreferenceChanged),
                                               name: .iCloudSettingsDidApply,
                                               object: nil)
        
        tableView.dataSource = self
        tableView.delegate = self
        CompactUI.apply(to: self, title: NSLocalizedString("Settings", comment: "preferences"))
        CompactUI.apply(to: tableView)
        
        let settings = UserDefaults.standard
        
        let nickname = settings.string(forKey: PREF_GENERAL_NICKNAME) ?? ""
        let statusmsg = preferredStatusMessage()
        
        // general items
        
        let nicknamecell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        nicknamefield = newTableCellTextField(nicknamecell, label: NSLocalizedString("Nickname", comment: "preferences"), initial: nickname)
        nicknamefield?.addTarget(self, action: #selector(SettingsViewController.nicknameChanged(_:)), for: .editingDidEnd)
        nicknamefield?.delegate = self
        general_items.append(nicknamecell)

        let statusmsgcell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        statusmsgfield = newTableCellTextField(statusmsgcell, label: NSLocalizedString("Status Message", comment: "preferences"), initial: statusmsg)
        statusmsgfield?.addTarget(self, action: #selector(SettingsViewController.statusMessageChanged(_:)), for: .editingDidEnd)
        statusmsgfield?.delegate = self
        general_items.append(statusmsgcell)
        
        let gendercell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        let genderoptions = [ NSLocalizedString("Male", comment: "preferences"), NSLocalizedString("Female", comment: "preferences"), NSLocalizedString("Neutral", comment: "preferences")]
        let gendersegctl = newTableCellSegCtrl(gendercell, label: NSLocalizedString("Gender", comment: "preferences"), values: genderoptions)
        gendersegctl.selectedSegmentIndex = preferredGenderIndex()
        gendersegctl.addTarget(self, action: #selector(SettingsViewController.genderChanged(_:)), for: .valueChanged)
        general_items.append(gendercell)
        
        let unmuteByDefault = settings.object(forKey: PREF_GENERAL_PTTLOCK) != nil && settings.bool(forKey: PREF_GENERAL_PTTLOCK)
        let unmuteByDefaultCell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        let unmuteByDefaultSwitch = newTableCellSwitch(unmuteByDefaultCell, label: NSLocalizedString("Unmute by Default", comment: "preferences"), initial: unmuteByDefault)
        unmuteByDefaultSwitch.addTarget(self, action: #selector(SettingsViewController.unmuteByDefaultChanged(_:)), for: .valueChanged)
        general_items.append(unmuteByDefaultCell)
        
        let sendonenter = settings.object(forKey: PREF_GENERAL_SENDONRETURN) == nil || settings.bool(forKey: PREF_GENERAL_SENDONRETURN)
        let sendonentercell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        let sendonenterswitch = newTableCellSwitch(sendonentercell, label: NSLocalizedString("Return Sends Message", comment: "preferences"), initial: sendonenter)
        sendonenterswitch.addTarget(self, action: #selector(SettingsViewController.sendonenterChanged(_:)), for: .valueChanged)
        general_items.append(sendonentercell)
        
        // display items

        let txtmsgpopcell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        let txtmsgpopup = settings.object(forKey: PREF_DISPLAY_POPUPTXTMSG) == nil || settings.bool(forKey: PREF_DISPLAY_POPUPTXTMSG)
        let txtmsgswitch = newTableCellSwitch(txtmsgpopcell, label: NSLocalizedString("Show Text Messages Instantly", comment: "preferences"), initial: txtmsgpopup)
        txtmsgswitch.addTarget(self, action: #selector(SettingsViewController.showtextmessagesChanged(_:)), for: .valueChanged)
        display_items.append(txtmsgpopcell)
        
        limittextcell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        let limittext = settings.object(forKey: PREF_DISPLAY_LIMITTEXT) == nil ? DEFAULT_LIMIT_TEXT : settings.integer(forKey: PREF_DISPLAY_LIMITTEXT)
        limittextfield = newTableCellTextField(limittextcell!, label: NSLocalizedString("Maximum Text Length", comment: "preferences"), initial: "\(within(1, max_v: DEFAULT_LIMIT_TEXT, value: limittext))")
        limittextfield?.keyboardType = .numberPad
        limittextfield?.textAlignment = .right
        limittextfield?.delegate = self
        limittextfield?.addTarget(self, action: #selector(SettingsViewController.limittextChanged(_:)), for: .editingDidEnd)
        limittextChanged(limittextfield!)
        display_items.append(limittextcell!)
        
        let showusernamecell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        let showusername = settings.object(forKey: PREF_DISPLAY_SHOWUSERNAME) != nil && settings.bool(forKey: PREF_DISPLAY_SHOWUSERNAME)
        let showusernameswitch = newTableCellSwitch(showusernamecell, label: NSLocalizedString("Show Usernames Instead of Nicknames", comment: "preferences"), initial: showusername)
        showusernameswitch.addTarget(self, action: #selector(SettingsViewController.showusernameChanged(_:)), for: .valueChanged)
        display_items.append(showusernamecell)
        
        let sortchancell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        let options = [ NSLocalizedString("Ascending", comment: "preferences"), NSLocalizedString("Popularity", comment: "preferences")]
        let sortchansegctl = newTableCellSegCtrl(sortchancell, label: NSLocalizedString("Sort Channels", comment: "preferences"), values: options)
        let chansort = settings.object(forKey: PREF_DISPLAY_SORTCHANNELS) == nil ? ChanSort.ASCENDING.rawValue : settings.integer(forKey: PREF_DISPLAY_SORTCHANNELS)
        sortchansegctl.selectedSegmentIndex = chansort
        sortchansegctl.addTarget(self, action: #selector(SettingsViewController.channelSortChanged(_:)), for: .valueChanged)
        display_items.append(sortchancell)

        // file display preferences

        let fileSortCell = UITableViewCell(style: .default, reuseIdentifier: nil)
        fileSortCell.selectionStyle = .none
        let fileSortButton = UIButton(type: .system)
        fileSortButton.showsMenuAsPrimaryAction = true
        fileSortButton.contentHorizontalAlignment = .leading
        fileSortButton.titleLabel?.font = UIFont.preferredFont(forTextStyle: .body)
        fileSortButton.titleLabel?.adjustsFontForContentSizeCategory = true
        fileSortButton.titleLabel?.numberOfLines = 0
        fileSortButton.translatesAutoresizingMaskIntoConstraints = false
        fileSortCell.contentView.addSubview(fileSortButton)
        NSLayoutConstraint.activate([
            fileSortButton.leadingAnchor.constraint(equalTo: fileSortCell.contentView.layoutMarginsGuide.leadingAnchor),
            fileSortButton.trailingAnchor.constraint(equalTo: fileSortCell.contentView.layoutMarginsGuide.trailingAnchor),
            fileSortButton.topAnchor.constraint(equalTo: fileSortCell.contentView.topAnchor, constant: 6),
            fileSortButton.bottomAnchor.constraint(equalTo: fileSortCell.contentView.bottomAnchor, constant: -6),
            fileSortButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44)
        ])
        self.fileSortButton = fileSortButton
        updateFileSortButton()
        display_items.append(fileSortCell)
        
        // sound preferences
        
        mastervolcell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        let output_pct = settings.object(forKey: PREF_MASTER_VOLUME) == nil ? DEFAULT_AUDIO_LEVEL_PERCENT : settings.integer(forKey: PREF_MASTER_VOLUME)
        let mastervolslider = newTableCellSlider(mastervolcell!, label: NSLocalizedString("Master Volume", comment: "preferences"), min: 0, max: 1, initial: Float(output_pct) / 100)
        mastervolslider.addTarget(self, action: #selector(SettingsViewController.masterVolumeChanged(_:)), for: .valueChanged)
        masterVolumeChanged(mastervolslider)
        sound_items.append(mastervolcell!)
        
        microphonecell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        let input_pct = settings.object(forKey: PREF_MICROPHONE_GAIN) == nil ? DEFAULT_AUDIO_LEVEL_PERCENT : settings.integer(forKey: PREF_MICROPHONE_GAIN)
        let microphoneslider = newTableCellSlider(microphonecell!, label: NSLocalizedString("Input Gain", comment: "preferences"), min: 0, max: 1, initial: Float(input_pct) / 100)
        microphoneslider.addTarget(self, action: #selector(SettingsViewController.microphoneGainChanged(_:)), for: .valueChanged)
        microphoneGainChanged(microphoneslider)
        sound_items.append(microphonecell!)

        sound_items.append(newMediaFileVolumeCell())
        
        let sndinputscell = tableView.dequeueReusableCell(withIdentifier: "SelectSoundDevices")
        sndinputscell?.detailTextLabel?.text = nil
        sound_items.append(sndinputscell!)
                

        // sound events
        
        let sndeventscell = tableView.dequeueReusableCell(withIdentifier: "SoundEvents")
        sndeventscell?.detailTextLabel?.text = nil
        soundevents_items.append(sndeventscell!)

        let soundpackscell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        soundpackscell.textLabel?.text = NSLocalizedString("Sound Packs", comment: "sound pack")
        soundpackscell.accessoryType = .disclosureIndicator
        soundevents_items.append(soundpackscell)


        // connection items
        
        let joinroot = settings.object(forKey: PREF_JOINROOTCHANNEL) == nil || settings.bool(forKey: PREF_JOINROOTCHANNEL)
        let joinrootcell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        let joinrootswitch = newTableCellSwitch(joinrootcell, label: NSLocalizedString("Join Root Channel", comment: "preferences"), initial: joinroot)
        joinrootswitch.addTarget(self, action: #selector(SettingsViewController.joinrootChanged(_:)), for: .valueChanged)
        connection_items.append(joinrootcell)
        
        // subscription items
        
        let subs = getDefaultSubscriptions()

        let subusermsgcell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        let subusermsgswitch = newTableCellSwitch(subusermsgcell, label: NSLocalizedString("User Messages", comment: "preferences"), initial: (subs & SUBSCRIBE_USER_MSG.rawValue) != 0)
        subusermsgswitch.tag = Int(SUBSCRIBE_USER_MSG.rawValue)
        subusermsgswitch.addTarget(self, action: #selector(SettingsViewController.subscriptionChanged(_:)), for: .valueChanged)
        subscription_items.append(subusermsgcell)
        
        let subchanmsgcell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        let subchanmsgswitch = newTableCellSwitch(subchanmsgcell, label: NSLocalizedString("Channel Messages", comment: "preferences"), initial: (subs & SUBSCRIBE_CHANNEL_MSG.rawValue) != 0)
        subchanmsgswitch.tag = Int(SUBSCRIBE_CHANNEL_MSG.rawValue)
        subchanmsgswitch.addTarget(self, action: #selector(SettingsViewController.subscriptionChanged(_:)), for: .valueChanged)
        subscription_items.append(subchanmsgcell)
        
        let subbcastmsgcell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        let subbcastmsgswitch = newTableCellSwitch(subbcastmsgcell, label: NSLocalizedString("Broadcast Messages", comment: "preferences"), initial: (subs & SUBSCRIBE_BROADCAST_MSG.rawValue) != 0)
        subbcastmsgswitch.tag = Int(SUBSCRIBE_BROADCAST_MSG.rawValue)
        subbcastmsgswitch.addTarget(self, action: #selector(SettingsViewController.subscriptionChanged(_:)), for: .valueChanged)
        subscription_items.append(subbcastmsgcell)

        let subvoicecell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        let subvoiceswitch = newTableCellSwitch(subvoicecell, label: NSLocalizedString("Voice", comment: "preferences"), initial: (subs & SUBSCRIBE_VOICE.rawValue) != 0)
        subvoiceswitch.tag = Int(SUBSCRIBE_VOICE.rawValue)
        subvoiceswitch.addTarget(self, action: #selector(SettingsViewController.subscriptionChanged(_:)), for: .valueChanged)
        subscription_items.append(subvoicecell)
        
        let subwebcamcell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        let subwebcamswitch = newTableCellSwitch(subwebcamcell, label: NSLocalizedString("WebCam", comment: "preferences"), initial: (subs & SUBSCRIBE_VIDEOCAPTURE.rawValue) != 0)
        subwebcamswitch.tag = Int(SUBSCRIBE_VIDEOCAPTURE.rawValue)
        subwebcamswitch.addTarget(self, action: #selector(SettingsViewController.subscriptionChanged(_:)), for: .valueChanged)
        subscription_items.append(subwebcamcell)
        
        let submediafilecell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        let submediafileswitch = newTableCellSwitch(submediafilecell, label: NSLocalizedString("Media File", comment: "preferences"), initial: (subs & SUBSCRIBE_MEDIAFILE.rawValue) != 0)
        submediafileswitch.tag = Int(SUBSCRIBE_MEDIAFILE.rawValue)
        submediafileswitch.addTarget(self, action: #selector(SettingsViewController.subscriptionChanged(_:)), for: .valueChanged)
        subscription_items.append(submediafilecell)
        
        let subdesktopcell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        let subdesktopswitch = newTableCellSwitch(subdesktopcell, label: NSLocalizedString("Desktop", comment: "preferences"), initial: (subs & SUBSCRIBE_DESKTOP.rawValue) != 0)
        subdesktopswitch.tag = Int(SUBSCRIBE_DESKTOP.rawValue)
        subdesktopswitch.addTarget(self, action: #selector(SettingsViewController.subscriptionChanged(_:)), for: .valueChanged)
        subscription_items.append(subdesktopcell)
        
        
        // text to speech events
        
        let ttsvoiceovercell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        let useVoiceOver = settings.object(forKey: PREF_TTSEVENT_USE_VOICEOVER) == nil || settings.bool(forKey: PREF_TTSEVENT_USE_VOICEOVER)
        let ttsvoiceoverswitch = newTableCellSwitch(ttsvoiceovercell, label: NSLocalizedString("Use VoiceOver when Available", comment: "preferences"), initial: useVoiceOver)
        ttsvoiceoverswitch.addTarget(self, action: #selector(SettingsViewController.ttsVoiceOverChanged(_:)), for: .valueChanged)
        ttsevents_items.append(ttsvoiceovercell)

        ttsvoicecell = tableView.dequeueReusableCell(withIdentifier: "Speech Cell")
        ttsvoicecell?.textLabel?.text = NSLocalizedString("Voice", comment: "preferences")
        ttsvoicecell?.detailTextLabel?.text = selectedTTSVoiceName()
        ttsevents_items.append(ttsvoicecell!)

        ttsratecell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        var ttsrate = AVSpeechUtteranceDefaultSpeechRate
        if settings.value(forKey: PREF_TTSEVENT_RATE) != nil {
            ttsrate = settings.float(forKey: PREF_TTSEVENT_RATE)
        }
        let ttsrateslider = newTableCellSlider(ttsratecell!, label: NSLocalizedString("Speech Rate", comment: "preferences"),
            min: AVSpeechUtteranceMinimumSpeechRate, max: AVSpeechUtteranceMaximumSpeechRate, initial: Float(ttsrate))
        ttsrateslider.addTarget(self, action: #selector(SettingsViewController.ttsrateChanged(_:)), for: .valueChanged)
        ttsrateChanged(ttsrateslider)
        ttsevents_items.append(ttsratecell!)
        
        ttsvolcell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        var ttsvol = DEFAULT_TTS_VOL
        if settings.value(forKey: PREF_TTSEVENT_VOL) != nil {
            ttsvol = settings.float(forKey: PREF_TTSEVENT_VOL)
        }
        let ttsvolslider = newTableCellSlider(ttsvolcell!, label: NSLocalizedString("Speech Volume", comment: "preferences"),
            min: 0, max: 1, initial: Float(ttsvol))
        ttsvolslider.addTarget(self, action: #selector(SettingsViewController.ttsvolChanged(_:)), for: .valueChanged)
        ttsvolChanged(ttsvolslider)
        ttsevents_items.append(ttsvolcell!)

        let ttsselectcell = tableView.dequeueReusableCell(withIdentifier: "TextToSpeech")
        ttsselectcell?.detailTextLabel?.text = nil
        ttsevents_items.append(ttsselectcell!)

        // Siri Shortcuts

        let siriconfigcell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        let siriconfigbutton = newTableCellBtn(siriconfigcell,
                                               label: "",
                                               btntext: NSLocalizedString("Add Shortcut", comment: "preferences"))
        siriconfigcell.textLabel?.text = nil
        siriconfigbutton.addTarget(self, action: #selector(SettingsViewController.configureSiriShortcuts(_:)), for: .touchUpInside)
        siri_shortcuts_items.append(siriconfigcell)

        
        // version items
        
        let versioncell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        versioncell.textLabel?.text = NSLocalizedString("App Version", comment: "preferences")
        let v_str = String(cString: TT_GetVersion())
        versioncell.detailTextLabel?.text = "\(AppInfo.getAppName()) v\(AppInfo.getAppVersionLong()), Library v\(v_str)"
        version_items.append(versioncell)

        let diagnosticLogsCell = UITableViewCell(style: .default, reuseIdentifier: nil)
        diagnosticLogsCell.textLabel?.text = NSLocalizedString("Share Diagnostic Logs", comment: "preferences")
        if #available(iOS 13.0, *) {
            diagnosticLogsCell.imageView?.image = UIImage(systemName: "square.and.arrow.up")
        }
        diagnosticLogsCell.accessoryType = .disclosureIndicator
        diagnosticLogsCell.accessibilityLabel = NSLocalizedString("Share Diagnostic Logs", comment: "preferences")
        diagnosticLogsCell.accessibilityHint = NSLocalizedString("Creates a zip file of app logs and opens sharing options.", comment: "preferences")
        version_items.append(diagnosticLogsCell)

        let iCloudCell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        iCloudSwitch = newTableCellSwitch(iCloudCell,
                                           label: NSLocalizedString("Sync with iCloud", comment: "preferences"),
                                           initial: ICloudSync.shared.isEnabled)
        iCloudSwitch?.addTarget(self, action: #selector(SettingsViewController.iCloudSyncChanged(_:)), for: .valueChanged)
        iCloud_items.append(iCloudCell)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        iCloudSwitch?.setOn(ICloudSync.shared.isEnabled, animated: false)
        updateFileSortButton()
        if isConnectedToServer() {
            expandedSections.remove(SECTION_SOUND)
        }
        tableView.reloadData()
    }

    private func selectedTTSVoiceName() -> String? {
        if let identifier = UserDefaults.standard.string(forKey: PREF_TTSEVENT_VOICEID),
           let voice = AVSpeechSynthesisVoice(identifier: identifier) {
            return voice.name
        }
        if let language = UserDefaults.standard.string(forKey: PREF_TTSEVENT_VOICELANG),
           let voice = AVSpeechSynthesisVoice(language: language) {
            return voice.name
        }
        return NSLocalizedString("Default", comment: "speech voice")
    }

    private func updateFileSortButton() {
        let field = preferredFileSortField()
        let ascending = preferredFileSortAscending()
        let fieldName: String
        switch field {
        case .name:
            fieldName = NSLocalizedString("Name", comment: "files")
        case .size:
            fieldName = NSLocalizedString("Size", comment: "files")
        case .owner:
            fieldName = NSLocalizedString("Owner", comment: "files")
        case .date:
            fieldName = NSLocalizedString("Date", comment: "files")
        }
        let orderName = ascending
            ? NSLocalizedString("Ascending", comment: "files")
            : NSLocalizedString("Descending", comment: "files")
        let displayedValue = "\(fieldName) (\(orderName))"
        let buttonTitle = String(format: NSLocalizedString("Sort Files By: %@", comment: "preferences"), displayedValue)
        fileSortButton?.setTitle(buttonTitle, for: .normal)
        fileSortButton?.menu = makeFileSortMenu(field: field, ascending: ascending)
        fileSortButton?.accessibilityLabel = NSLocalizedString("Sort Files By", comment: "preferences")
        fileSortButton?.accessibilityValue = displayedValue
    }

    private func makeFileSortMenu(field: FileSortField, ascending: Bool) -> UIMenu {
        let fieldMenu = UIMenu(title: NSLocalizedString("Sort By", comment: "files"),
                               options: .displayInline,
                               children: [
                                settingsFileSortFieldAction(title: NSLocalizedString("Name", comment: "files"), value: .name, selected: field),
                                settingsFileSortFieldAction(title: NSLocalizedString("Size", comment: "files"), value: .size, selected: field),
                                settingsFileSortFieldAction(title: NSLocalizedString("Owner", comment: "files"), value: .owner, selected: field),
                                settingsFileSortFieldAction(title: NSLocalizedString("Date", comment: "files"), value: .date, selected: field)
                               ])
        let orderMenu = UIMenu(title: NSLocalizedString("Order", comment: "files"),
                               options: .displayInline,
                               children: [
                                settingsFileSortOrderAction(title: NSLocalizedString("Ascending", comment: "files"), value: true, selected: ascending),
                                settingsFileSortOrderAction(title: NSLocalizedString("Descending", comment: "files"), value: false, selected: ascending)
                               ])
        return UIMenu(title: NSLocalizedString("Sort Files", comment: "files"), children: [fieldMenu, orderMenu])
    }

    private func settingsFileSortFieldAction(title: String,
                                             value: FileSortField,
                                             selected: FileSortField) -> UIAction {
        UIAction(title: title, state: value == selected ? .on : .off) { _ in
            saveFileSortPreferences(field: value, ascending: preferredFileSortAscending())
        }
    }

    private func settingsFileSortOrderAction(title: String, value: Bool, selected: Bool) -> UIAction {
        UIAction(title: title, state: value == selected ? .on : .off) { _ in
            saveFileSortPreferences(field: preferredFileSortField(), ascending: value)
        }
    }

    @objc private func fileSortPreferenceChanged() {
        DispatchQueue.main.async { [weak self] in
            self?.updateFileSortButton()
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func ttsVoiceDidChange() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.ttsvoicecell?.detailTextLabel?.text = self.selectedTTSVoiceName()
            self.tableView.reloadData()
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)

        // Keep the expanded state while navigating into a child settings
        // screen. Clear it only when Settings itself is dismissed/popped so
        // the next visit starts collapsed.
        if (isMovingFromParent || navigationController?.isBeingDismissed == true),
           expandedSections.isEmpty == false {
            expandedSections.removeAll()
            tableView.reloadData()
        }
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textField.resignFirstResponder()
        return false
    }

    func textField(_ textField: UITextField, shouldChangeCharactersIn range: NSRange, replacementString string: String) -> Bool {
        guard textField == limittextfield else { return true }
        return string.rangeOfCharacter(from: CharacterSet.decimalDigits.inverted) == nil
    }
    
    @objc func subscriptionChanged(_ sender: UISwitch) {
        
        let defaults = UserDefaults.standard
        
        switch UInt32(sender.tag) {
        case SUBSCRIBE_USER_MSG.rawValue :
            defaults.set(sender.isOn, forKey: PREF_SUB_USERMSG)
        case SUBSCRIBE_CHANNEL_MSG.rawValue :
            defaults.set(sender.isOn, forKey: PREF_SUB_CHANMSG)
        case SUBSCRIBE_BROADCAST_MSG.rawValue :
            defaults.set(sender.isOn, forKey: PREF_SUB_BROADCAST)
        case SUBSCRIBE_VOICE.rawValue :
            defaults.set(sender.isOn, forKey: PREF_SUB_VOICE)
        case SUBSCRIBE_VIDEOCAPTURE.rawValue :
            defaults.set(sender.isOn, forKey: PREF_SUB_VIDEOCAP)
        case SUBSCRIBE_MEDIAFILE.rawValue :
            defaults.set(sender.isOn, forKey: PREF_SUB_MEDIAFILE)
        case SUBSCRIBE_DESKTOP.rawValue :
            defaults.set(sender.isOn, forKey: PREF_SUB_DESKTOP)
        default :
            break
        }
    }
    
    @objc func nicknameChanged(_ sender: UITextField) {
        TT_DoChangeNickname(ttInst, sender.text!)
        
        let defaults = UserDefaults.standard
        defaults.setValue(sender.text!, forKey: PREF_GENERAL_NICKNAME)
    }

    @objc func statusMessageChanged(_ sender: UITextField) {
        let defaults = UserDefaults.standard
        defaults.setValue(sender.text ?? "", forKey: PREF_GENERAL_STATUSMESSAGE)
        applyPreferredStatus()
    }
    
    @objc func unmuteByDefaultChanged(_ sender: UISwitch) {
        let defaults = UserDefaults.standard
        defaults.set(sender.isOn, forKey: PREF_GENERAL_PTTLOCK)
    }

    @objc func sendonenterChanged(_ sender: UISwitch) {
        let defaults = UserDefaults.standard
        defaults.set(sender.isOn, forKey: PREF_GENERAL_SENDONRETURN)
    }
    
    @objc func masterVolumeChanged(_ sender: UISlider) {
        let percent : Int = Int(sender.value * 10.0) * 10
        let vol = refVolume(Double(percent))
        if ttInst != nil && isLoggedInToServer() {
            TT_SetSoundOutputVolume(ttInst, INT32(vol))
        }
        
        mastervolcell!.detailTextLabel!.text = "\(percent) %"
        
        let defaults = UserDefaults.standard
        defaults.set(percent, forKey: PREF_MASTER_VOLUME)
    }
    
    @objc func showtextmessagesChanged(_ sender: UISwitch) {
        let defaults = UserDefaults.standard
        defaults.set(sender.isOn, forKey: PREF_DISPLAY_POPUPTXTMSG)
    }

    @objc func limittextChanged(_ sender: UITextField) {
        let value = within(1, max_v: DEFAULT_LIMIT_TEXT, value: Int(sender.text ?? "") ?? DEFAULT_LIMIT_TEXT)
        sender.text = "\(value)"

        let defaults = UserDefaults.standard
        defaults.set(value, forKey: PREF_DISPLAY_LIMITTEXT)
        limittextcell!.detailTextLabel!.text = nil
    }
    
    @objc func showusernameChanged(_ sender: UISwitch) {
        let defaults = UserDefaults.standard
        defaults.set(sender.isOn, forKey: PREF_DISPLAY_SHOWUSERNAME)
    }
    
    @objc func microphoneGainChanged(_ sender: UISlider) {
        let vol_pct : Int = Int(sender.value * 10.0) * 10
        let vol = refVolume(Double(vol_pct))
        if ttInst != nil && isLoggedInToServer() {
            TT_SetSoundInputGainLevel(ttInst, INT32(vol))
        }
        
        microphonecell!.detailTextLabel!.text = "\(vol_pct) %"
        
        let defaults = UserDefaults.standard
        defaults.set(vol_pct, forKey: PREF_MICROPHONE_GAIN)
    }

    @objc func ttsrateChanged(_ sender: UISlider) {
        let defaults = UserDefaults.standard
        defaults.set(Float(sender.value), forKey: PREF_TTSEVENT_RATE)
        ttsratecell!.detailTextLabel!.text = nil
    }
    
    @objc func ttsvolChanged(_ sender: UISlider) {
        let defaults = UserDefaults.standard
        defaults.set(Float(sender.value), forKey: PREF_TTSEVENT_VOL)
        ttsvolcell!.detailTextLabel!.text = nil
    }

    @objc func ttsVoiceOverChanged(_ sender: UISwitch) {
        let defaults = UserDefaults.standard
        defaults.set(sender.isOn, forKey: PREF_TTSEVENT_USE_VOICEOVER)
    }
    
    @objc func joinrootChanged(_ sender: UISwitch) {
        
        let defaults = UserDefaults.standard
        defaults.set(sender.isOn, forKey: PREF_JOINROOTCHANNEL)
    }
    
    @objc func channelSortChanged(_ segctrl: UISegmentedControl) {
        let defaults = UserDefaults.standard
        defaults.set(segctrl.selectedSegmentIndex == 0 ? ChanSort.ASCENDING.rawValue : ChanSort.POPULARITY.rawValue,
                     forKey: PREF_DISPLAY_SORTCHANNELS)
    }

    @objc func configureSiriShortcuts(_ sender: Any?) {
        let servers = loadLocalServers().filter({ $0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false })
        guard servers.isEmpty == false else {
            let alert = UIAlertController(title: NSLocalizedString("Siri Shortcuts", comment: "preferences"),
                                          message: NSLocalizedString("No saved servers are available.", comment: "preferences"),
                                          preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: NSLocalizedString("OK", comment: "message dialog"), style: .default, handler: nil))
            present(alert, animated: true, completion: nil)
            return
        }

        let alert = UIAlertController(title: NSLocalizedString("Select a Shortcut", comment: "preferences"),
                                      message: nil,
                                      preferredStyle: .actionSheet)
        for server in servers {
            let title = String(format: NSLocalizedString("Connect to %@", comment: "siri shortcuts"), server.name)
            alert.addAction(UIAlertAction(title: title, style: .default) { [weak self] _ in
                self?.showAddSiriShortcut(for: server)
            })
        }
        alert.addAction(UIAlertAction(title: NSLocalizedString("Cancel", comment: "message dialog"), style: .cancel, handler: nil))

        if let sourceView = sender as? UIView {
            alert.popoverPresentationController?.sourceView = sourceView
            alert.popoverPresentationController?.sourceRect = sourceView.bounds
        }
        else {
            alert.popoverPresentationController?.sourceView = tableView
            alert.popoverPresentationController?.sourceRect = tableView.bounds
        }
        present(alert, animated: true, completion: nil)
    }

    func showAddSiriShortcut(for server: Server) {
        let shortcut = SiriShortcutSupport.connectServerShortcut(for: server)
        let viewController = INUIAddVoiceShortcutViewController(shortcut: shortcut)
        viewController.delegate = self
        viewController.modalPresentationStyle = .formSheet
        present(viewController, animated: true, completion: nil)
    }

    func addVoiceShortcutViewController(_ controller: INUIAddVoiceShortcutViewController,
                                        didFinishWith voiceShortcut: INVoiceShortcut?,
                                        error: Error?) {
        controller.dismiss(animated: true, completion: nil)
    }

    func addVoiceShortcutViewControllerDidCancel(_ controller: INUIAddVoiceShortcutViewController) {
        controller.dismiss(animated: true, completion: nil)
    }

    @IBAction func genderChanged(_ sender: UISegmentedControl) {
        let defaults = UserDefaults.standard
        defaults.set(sender.selectedSegmentIndex, forKey: PREF_GENERAL_GENDER)
        defaults.set(true, forKey: PREF_GENERAL_GENDER_NEUTRAL_MIGRATED)
        applyPreferredStatus()
    }

    override func prepare(for segue: UIStoryboardSegue, sender: Any?) {
        if segue.identifier == "Select Voice" {
        }
    }
    
    override func numberOfSections(in tableView: UITableView) -> Int {
        return visibleSettingsSections.count
    }
    
    func titleForSettingsSection(_ section: Int) -> String? {
        switch section {
        case SECTION_GENERAL :
            return NSLocalizedString("General", comment: "preferences")
        case SECTION_DISPLAY :
            return NSLocalizedString("Display", comment: "preferences")
        case SECTION_SOUNDEVENTS :
            return NSLocalizedString("Sound Events", comment: "preferences")
        case SECTION_SOUND :
            return NSLocalizedString("Sound System", comment: "preferences")
        case SECTION_CONNECTION :
            return NSLocalizedString("Connection", comment: "preferences")
        case SECTION_SUBSCRIPTIONS :
            return NSLocalizedString("Default Subscriptions", comment: "preferences")
        case SECTION_TTSEVENTS :
            return NSLocalizedString("Text To Speech Events", comment: "preferences")
        case SECTION_SIRI_SHORTCUTS :
            return NSLocalizedString("Siri Shortcuts", comment: "preferences")
        case SECTION_VERSION :
            return NSLocalizedString("About", comment: "preferences")
        case SECTION_ICLOUD :
            return NSLocalizedString("iCloud", comment: "preferences")
        default :
            return nil
        }
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        return nil
    }

    override func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        let logicalSection = logicalSettingsSection(for: section)
        guard let title = titleForSettingsSection(logicalSection) else {
            return nil
        }

        if #available(iOS 14.0, *) {
            if let existingHost = settingsSectionHeaderHosts[logicalSection] {
                existingHost.willMove(toParent: nil)
                existingHost.view.removeFromSuperview()
                existingHost.removeFromParent()
            }

            let headerView = NativeDisclosureHeader(title: title, subtitle: nil, isExpanded: expandedSections.contains(logicalSection), leadingPadding: 16) { [weak self] in
                self?.toggleSettingsSection(section)
            }
            let host = UIHostingController(rootView: headerView)
            host.view.backgroundColor = CompactUI.secondaryBackgroundColor
            addChild(host)
            host.didMove(toParent: self)
            settingsSectionHeaderHosts[logicalSection] = host
            return host.view
        }

        let header = SettingsSectionHeaderView(reuseIdentifier: nil)
        header.tag = section
        header.configure(title: title, isExpanded: expandedSections.contains(logicalSection))
        header.accessibilityActivationHandler = { [weak self] in
            self?.toggleSettingsSection(section)
            return true
        }
        header.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(settingsSectionHeaderTapped(_:))))
        return header
    }

    override func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
        return UITableView.automaticDimension
    }

    override func tableView(_ tableView: UITableView, estimatedHeightForHeaderInSection section: Int) -> CGFloat {
        return 44
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        let logicalSection = logicalSettingsSection(for: section)
        guard logicalSection == SECTION_SIRI_SHORTCUTS && expandedSections.contains(logicalSection) else {
            return nil
        }

        return NSLocalizedString("Siri Shortcuts allows you to quickly connect to a server you have saved in your server list.", comment: "preferences")
    }

    @objc func settingsSectionHeaderTapped(_ sender: UITapGestureRecognizer) {
        guard let section = sender.view?.tag else { return }
        toggleSettingsSection(section)
    }

    func toggleSettingsSection(_ section: Int) {
        let logicalSection = logicalSettingsSection(for: section)
        if expandedSections.contains(logicalSection) {
            expandedSections.remove(logicalSection)
        }
        else {
            expandedSections.insert(logicalSection)
        }
        tableView.reloadSections(IndexSet(integer: section), with: .automatic)
    }
    
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        let logicalSection = logicalSettingsSection(for: section)
        guard expandedSections.contains(logicalSection) else {
            return 0
        }

        switch logicalSection {
        case SECTION_GENERAL :
            return general_items.count
        case SECTION_DISPLAY :
            return display_items.count
        case SECTION_SOUNDEVENTS :
            return soundevents_items.count
        case SECTION_SOUND :
            return sound_items.count
        case SECTION_CONNECTION :
            return connection_items.count
        case SECTION_SUBSCRIPTIONS :
            return subscription_items.count
        case SECTION_TTSEVENTS :
            return ttsevents_items.count
        case SECTION_SIRI_SHORTCUTS :
            return siri_shortcuts_items.count
        case SECTION_VERSION :
            return version_items.count
        case SECTION_ICLOUD :
            return iCloud_items.count
        default :
            return 0
        }
    }
    
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell: UITableViewCell
        let logicalSection = logicalSettingsSection(for: indexPath.section)
        
        switch logicalSection {
        case SECTION_GENERAL :
            cell = general_items[indexPath.row]
        case SECTION_DISPLAY :
            cell = display_items[indexPath.row]
        case SECTION_SOUNDEVENTS:
            cell = soundevents_items[indexPath.row]
        case SECTION_SOUND :
            cell = sound_items[indexPath.row]
        case SECTION_CONNECTION :
            cell = connection_items[indexPath.row]
        case SECTION_SUBSCRIPTIONS :
            cell = subscription_items[indexPath.row]
        case SECTION_TTSEVENTS:
            cell = ttsevents_items[indexPath.row]
        case SECTION_SIRI_SHORTCUTS :
            cell = siri_shortcuts_items[indexPath.row]
        case SECTION_VERSION :
            cell = version_items[indexPath.row]
        case SECTION_ICLOUD :
            cell = iCloud_items[indexPath.row]
        default :
            cell = UITableViewCell()
        }

        cell.backgroundColor = CompactUI.secondaryBackgroundColor
        CompactUI.stylePrimaryLabel(cell.textLabel)
        CompactUI.styleSecondaryLabel(cell.detailTextLabel)
        return cell
    }

    @objc func iCloudSyncChanged(_ sender: UISwitch) {
        ICloudSync.shared.setEnabled(sender.isOn)
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        let logicalSection = logicalSettingsSection(for: indexPath.section)
        if logicalSection == SECTION_SOUNDEVENTS && indexPath.row == 1 {
            tableView.deselectRow(at: indexPath, animated: true)
            navigationController?.pushViewController(SoundPacksViewController(style: .grouped), animated: true)
        }
        else if logicalSection == SECTION_SIRI_SHORTCUTS {
            tableView.deselectRow(at: indexPath, animated: true)
            configureSiriShortcuts(tableView.cellForRow(at: indexPath))
        }
        else if logicalSection == SECTION_VERSION && indexPath.row == 1 {
            tableView.deselectRow(at: indexPath, animated: true)
            confirmShareDiagnosticLogs(from: tableView.cellForRow(at: indexPath))
        }
    }

    private func confirmShareDiagnosticLogs(from sourceView: UIView?) {
        let alert = UIAlertController(title: NSLocalizedString("Share Diagnostic Logs?", comment: "preferences"),
                                      message: NSLocalizedString("Diagnostic logs may contain sensitive information, including server addresses, usernames, file names, and error details. Only share them with people you trust.", comment: "preferences"),
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: NSLocalizedString("Cancel", comment: "message dialog"), style: .cancel))
        alert.addAction(UIAlertAction(title: NSLocalizedString("Share", comment: "preferences"), style: .default) { [weak self, weak sourceView] _ in
            self?.shareDiagnosticLogs(from: sourceView)
        })
        present(alert, animated: true)
    }

    private func shareDiagnosticLogs(from sourceView: UIView?) {
        let activityIndicator = UIActivityIndicatorView(style: .medium)
        let loadingItem = UIBarButtonItem(customView: activityIndicator)
        navigationItem.rightBarButtonItem = loadingItem
        activityIndicator.startAnimating()

        DispatchQueue.global(qos: .userInitiated).async { [weak self, weak sourceView] in
            let result = Result { try DiagnosticLogExporter.export() }
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.navigationItem.rightBarButtonItem = nil

                switch result {
                case .success(let archiveURL):
                    self.presentDiagnosticLogsShareSheet(for: archiveURL, sourceView: sourceView)
                case .failure(let error):
                    self.showDiagnosticLogsError(error.localizedDescription)
                }
            }
        }
    }

    private func presentDiagnosticLogsShareSheet(for archiveURL: URL, sourceView: UIView?) {
        let activity = UIActivityViewController(activityItems: [archiveURL], applicationActivities: nil)
        if let popover = activity.popoverPresentationController {
            popover.sourceView = sourceView ?? view
            popover.sourceRect = sourceView?.bounds ?? CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1)
        }
        present(activity, animated: true)
    }

    private func showDiagnosticLogsError(_ message: String) {
        let alert = UIAlertController(title: NSLocalizedString("Diagnostic Logs", comment: "preferences"),
                                      message: message,
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: NSLocalizedString("OK", comment: "message dialog"), style: .default))
        present(alert, animated: true)
    }
    
    func handleTTMessage(_ m: TTMessage) {
        var m = m
        
        switch m.nClientEvent {
            
        case CLIENTEVENT_CMD_USER_JOINED :
            let user = getUser(&m).pointee
            users.insert(user.nUserID)
        case CLIENTEVENT_CMD_USER_LEFT :
            let user = getUser(&m).pointee
            users.remove(user.nUserID)
        default : break
        }
    }
}
