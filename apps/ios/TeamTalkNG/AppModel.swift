import MediaPlayer
import UIKit
import AVFoundation
import Foundation
import Observation

/// Saved servers, the open connections (several at once), and settings.
@MainActor @Observable
final class AppModel {
    private(set) var servers: [SavedServer] = []
    private(set) var connections: [UUID: ServerConnection] = [:]

    var talkMode: TalkMode = .pushToTalk {
        didSet {
            save()
            connections.values.forEach { $0.applyTalkMode() }
            LiveActivities.shared.refreshAll()
            if talkMode != oldValue && (talkMode == .voiceActivation || oldValue == .voiceActivation) {
                // Switching modes: vox_enable to voice activation, vox_disable
                // to push to talk (the owner's choice).
                if !loading { sounds.play(talkMode == .voiceActivation ? .voiceActivationOn : .voiceActivationOff) }
            }
        }
    }
    /// The desktop's voice activation level: 0–20, 2 by default.
    var voiceLevel: Double = 2 {
        didSet { save(); connections.values.forEach { $0.applyTalkMode() } }
    }
    var nickname = "" { didSet { save() } }
    /// Set on every server after logging in (the desktop's gender setting).
    var gender = Gender.neutral { didSet { save() } }

    /// The desktop's Sound System settings, for every server.
    var audio = defaultAudioSettings() {
        didSet {
            saveAudio()
            // Echo cancellation changes the audio session's mode first.
            if audio.echoCancellation != oldValue.echoCancellation {
                // iPhone's echo cancellation is one Voice-Processing unit
                // shared by every connection: all close, the audio session
                // changes mode, then all open again.
                let list = Array(connections.values)
                Task {
                    for c in list { await c.closeAudio() }
                    AudioSession.activate()
                    for c in list { await c.reopenAudio() }
                }
            } else {
                for c in connections.values { c.applyAudioSettings() }
            }
        }
    }

    /// Stream the video of video files too (VP8).
    var streamVideo = true {
        didSet {
            save()
            for c in connections.values { c.applyStreamVideo() }
        }
    }


    /// Recording as the desktop sets it up.
    var recordMP3 = true { didSet { save() } }
    var recordOneFile = true { didSet { save() } }
    var recordEachPerson = false { didSet { save() } }
    var recordMediaFiles = false { didSet { save() } }
    /// Each server's chat written to text files too.
    var saveChatLogs = false { didSet { save() } }

    /// The desktop's General settings for me: a status message to log in
    /// with, and going away when TeamTalk NG is in the background (or the
    /// iPhone is locked) this long, with its own message, maybe without
    /// voice activation.
    var statusMessage = "" { didSet { save() } }
    /// The desktop's 180 seconds of inactivity (here: in the background or locked).
    var awayAfterSeconds = 180 { didSet { save() } }
    var awayMessage = "" { didSet { save() } }
    var awayStopsVoiceActivation = false { didSet { save() } }
    @ObservationIgnored private var awayTimer: Task<Void, Never>?
    let sounds = SoundStore()
    /// AudioNet: its sign-in, devices and what's being sent.
    let audioNet = AudioNetStore()
    /// The live mix's volumes (the desktop's scale, 50 unchanged).
    var audioNetVolume = 50 { didSet { save(); applyMixGains() } }
    var mixFileVolume = 50 { didSet { save(); applyMixGains() } }

    private func applyMixGains() {
        for c in connections.values { c.mix?.setGains(file: mixFileVolume, audioNet: audioNetVolume) }
    }
    let speech = SpeechStore()
    let chatTemplates = ChatTemplateStore()
    let statusEvents = StatusEventStore()

    // MARK: Display (the desktop's Display tab)

    enum ChannelTap: String, CaseIterable, Identifiable {
        case joinOrLeave, join, nothing
        var id: Self { self }
        var label: String {
            switch self {
            case .join: "Joins it"
            case .joinOrLeave: "Joins it, or leaves it if you're there"
            case .nothing: "Nothing (use its actions)"
            }
        }
    }

    var showUsernames = false { didSet { save() } }
    var showTopics = false { didSet { save() } }
    /// The desktop's "Sort channels by": ascending (by name) or popularity
    /// (most people first). Kept as a Bool: true = ascending.
    var sortChannelsByName = true { didSet { save() } }
    /// The desktop's "Style of user and channel info": emoji (default),
    /// text or none.
    enum InfoStyle: String, CaseIterable, Identifiable {
        case emoji, text, none
        var id: Self { self }
        var label: String { switch self { case .emoji: "Emoji"; case .text: "Text"; case .none: "None" } }
    }
    /// Text by default (the owner's choice; the desktop's default is emoji).
    var infoStyle = InfoStyle.text { didSet { save() } }
    /// The desktop's "Show number of users in channel" (on).
    var showUserCount = true { didSet { save() } }
    /// The desktop's "Show last to talk in yellow" (on).
    var showLastTalk = true { didSet { save() } }
    /// The desktop's "Show user and channel icons" (on).
    var showIcons = true { didSet { save() } }
    /// The desktop's "Maximum text length in channel list" (50; what's
    /// shown is cut, what VoiceOver says isn't).
    var maxTextLength = 50 { didSet { save() } }
    /// The desktop's default: join, or leave the channel you're in.
    var channelTap = ChannelTap.joinOrLeave { didSet { save() } }
    /// The desktop's "Auto expand channels": channels appear expanded.
    var autoExpandChannels = false { didSet { save() } }
    /// The desktop's "Restore volume settings and subscriptions on login
    /// for Web Login users" (on by default).
    var restoreUserSettings = true { didSet { save() } }
    /// The desktop's "Timestamp format": empty = the system's short date
    /// and time; else a date pattern (such as "HH:mm:ss").
    var timestampFormat = "" { didSet { save() } }
    /// The desktop's "Popup dialog when receiving text message" (on): a
    /// private message opens its conversation.
    var messagePopup = true { didSet { save() } }
    /// The desktop's "Show dialog box when excluded from channel or
    /// server" (off).
    var excludedDialog = false { didSet { save() } }
    /// The desktop's "Show dialog box with server list on startup" (off).
    var serverListOnStart = false { didSet { save() } }

    /// A timestamp as the desktop writes it.
    func timestamp(_ t: Date) -> String {
        if timestampFormat.isEmpty { return t.formatted(date: .numeric, time: .shortened) }
        let f = DateFormatter()
        f.dateFormat = timestampFormat
        return f.string(from: t)
    }

    /// The desktop's "Display file name in status message when streaming" (off).
    var streamingStatus = false { didSet { save() } }

    /// The old app's "Return sends message" (on by default).
    var sendOnReturn = true { didSet { save() } }

    var showTimestamps = true { didSet { save() } }
    var showMOTD = true { didSet { save() } }
    /// The desktop's "Show statusbar events in chat-window", on by default.
    var eventsInChat = true { didSet { save() } }
    var notifyInBackground = true { didSet { save() } }

    // MARK: Connection (the desktop's Connection tab)

    var reconnect = true { didSet { save() } }
    var joinRoot = true { didSet { save() } }
    /// What's received from people by default (the rest is turned off for
    /// each one as they log in).
    var defaultSubscriptionsOff: Set<Subscription> = [] { didSet { save() } }
    @ObservationIgnored private(set) lazy var account = NGAccountStore(app: self)
    @ObservationIgnored private(set) lazy var monitor = MonitorStore(app: self)

    private let defaults = UserDefaults.standard

    @ObservationIgnored private var loading = true

    init() {
        /// Settings converted to the desktop's ways while loading.
        var convertedSettings = false
        if let d = defaults.data(forKey: "servers"), let s = try? JSONDecoder().decode([SavedServer].self, from: d) {
            servers = s
        }
        talkMode = TalkMode(rawValue: defaults.string(forKey: "talkMode") ?? "") ?? .pushToTalk
        voiceLevel = defaults.object(forKey: "voiceLevel") as? Double ?? 2
        // Once: this app's earlier default (20 of 100) becomes the
        // desktop's (2 of 20).
        if !defaults.bool(forKey: "desktopVoiceLevel") {
            defaults.set(true, forKey: "desktopVoiceLevel")
            voiceLevel = voiceLevel == 20 ? 2 : min(voiceLevel, 20)
            convertedSettings = true
        }
        nickname = defaults.string(forKey: "nickname") ?? ""
        gender = ["male": Gender.male, "female": .female][defaults.string(forKey: "gender") ?? ""] ?? .neutral
        if let a = defaults.dictionary(forKey: "audio") as? [String: Int] {
            audio = AudioSettings(
                echoCancellation: a["echo"] == 1, gainControl: a["agc", default: 1] == 1, noiseSuppression: a["denoise", default: 1] == 1,
                micGain: Int32(a["mic", default: 50]), outputVolume: Int32(a["out", default: 50]), mediaVolume: Int32(a["media", default: 100]))
            // Once: levels saved on this app's earlier scale (100 normal, up
            // to 400, straight) onto the desktop's (0–100 on a curve, 50
            // normal), sounding the same.
            if !defaults.bool(forKey: "desktopVolumeScale") {
                func desktop(_ old: Int) -> Int32 {
                    guard old > 0 else { return 0 }
                    let level = Double(old) * 10, d = log((level + 50) / 82.832) / 0.0508
                    return Int32(min(100, max(0, Int(d + 0.5))))
                }
                audio.micGain = desktop(a["mic", default: 100])
                audio.outputVolume = desktop(a["out", default: 100])
                audio.mediaVolume = Int32(min(100, a["media", default: 100]))
                saveAudio()
            }
        }
        defaults.set(true, forKey: "desktopVolumeScale")
        recordMP3 = defaults.object(forKey: "recordMP3") as? Bool ?? true
        recordOneFile = defaults.object(forKey: "recordOneFile") as? Bool ?? true
        recordEachPerson = defaults.bool(forKey: "recordEachPerson")
        recordMediaFiles = defaults.bool(forKey: "recordMediaFiles")
        saveChatLogs = defaults.bool(forKey: "saveChatLogs")
        audioNetVolume = defaults.object(forKey: "audioNetVolume") as? Int ?? 50
        mixFileVolume = defaults.object(forKey: "mixFileVolume") as? Int ?? 50
        streamVideo = defaults.object(forKey: "streamVideo") as? Bool ?? true
        showUsernames = defaults.bool(forKey: "showUsernames")
        showTopics = defaults.object(forKey: "showTopics") as? Bool ?? false
        sortChannelsByName = defaults.object(forKey: "sortChannelsByName") as? Bool ?? true
        infoStyle = InfoStyle(rawValue: defaults.string(forKey: "infoStyle") ?? "") ?? .text
        // Once: the earlier default (emoji) becomes Text.
        if !defaults.bool(forKey: "infoStyleText") {
            defaults.set(true, forKey: "infoStyleText")
            if infoStyle == .emoji { infoStyle = .text; convertedSettings = true }
        }
        showUserCount = defaults.object(forKey: "showUserCount") as? Bool ?? true
        showLastTalk = defaults.object(forKey: "showLastTalk") as? Bool ?? true
        showIcons = defaults.object(forKey: "showIcons") as? Bool ?? true
        maxTextLength = defaults.object(forKey: "maxTextLength") as? Int ?? 50
        channelTap = ChannelTap(rawValue: defaults.string(forKey: "channelTap") ?? "") ?? .joinOrLeave
        // "Joins it" was the default before the desktop's join-or-leave.
        // (Version 2: the first didn't save its change.)
        if !defaults.bool(forKey: "channelTapDesktopDefault2") {
            defaults.set(true, forKey: "channelTapDesktopDefault2")
            if channelTap == .join { channelTap = .joinOrLeave }
            convertedSettings = true
        }
        autoExpandChannels = defaults.bool(forKey: "autoExpandChannels")
        restoreUserSettings = defaults.object(forKey: "restoreUserSettings") as? Bool ?? true
        sendOnReturn = defaults.object(forKey: "sendOnReturn") as? Bool ?? true
        timestampFormat = defaults.string(forKey: "timestampFormat") ?? ""
        streamingStatus = defaults.bool(forKey: "streamingStatus")
        messagePopup = defaults.object(forKey: "messagePopup") as? Bool ?? true
        excludedDialog = defaults.bool(forKey: "excludedDialog")
        serverListOnStart = defaults.bool(forKey: "serverListOnStart")
        showTimestamps = defaults.object(forKey: "showTimestamps") as? Bool ?? true
        showMOTD = defaults.object(forKey: "showMOTD") as? Bool ?? true
        eventsInChat = defaults.object(forKey: "eventsInChat") as? Bool ?? true
        notifyInBackground = defaults.object(forKey: "notifyInBackground") as? Bool ?? true
        reconnect = defaults.object(forKey: "reconnect") as? Bool ?? true
        joinRoot = defaults.object(forKey: "joinRoot") as? Bool ?? true
        defaultSubscriptionsOff = Set((defaults.stringArray(forKey: "subscriptionsOff") ?? []).compactMap { name in
            PersonView.normal.first { "\($0)" == name }
        })
        statusMessage = defaults.string(forKey: "statusMessage") ?? ""
        // The desktop counts seconds (0: off); earlier this app counted minutes.
        awayAfterSeconds = defaults.object(forKey: "awayAfterSeconds") as? Int
            ?? (defaults.object(forKey: "awayAfterMinutes") as? Int).map { $0 * 60 } ?? 180
        awayMessage = defaults.string(forKey: "awayMessage") ?? ""
        awayStopsVoiceActivation = defaults.bool(forKey: "awayStopsVoiceActivation")
        // Once: settings still at this app's earlier defaults take the
        // desktop's (settings changed by hand stay).
        // (Version 2: the first didn't save its changes.)
        if !defaults.bool(forKey: "desktopDefaults2") {
            defaults.set(true, forKey: "desktopDefaults2")
            if awayAfterSeconds == 0 { awayAfterSeconds = 180 }
            if showTopics { showTopics = false }
            if !eventsInChat { eventsInChat = true }
            convertedSettings = true
        }
        // Saved once everything's loaded (saving writes every setting).
        loading = false
        if convertedSettings { save() }
        sounds.packsChanged = { [weak self] in self?.account.changed() }
        // As the desktop when it starts (mainwindow.cpp, loading settings):
        // "Voice activation enabled" or "disabled" (vox_enable / vox_disable).
        sounds.play(talkMode == .voiceActivation ? .voiceActivationOn : .voiceActivationOff)
        setUpHeadsetButton()
        // The desktop's "Sound device detected" status messages (a headset
        // in or out), and the microphone menu kept current.
        NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] n in
            let reason = (n.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt).flatMap(AVAudioSession.RouteChangeReason.init(rawValue:))
            let text: String?
            switch reason {
            case .newDeviceAvailable:
                let name = AVAudioSession.sharedInstance().currentRoute.inputs.first?.portName
                    ?? AVAudioSession.sharedInstance().currentRoute.outputs.first?.portName ?? "a device"
                text = "New sound device available: \(name)."
            case .oldDeviceUnavailable:
                let old = n.userInfo?[AVAudioSessionRouteChangePreviousRouteKey] as? AVAudioSessionRouteDescription
                text = "Sound device removed: \(old?.outputs.first?.portName ?? old?.inputs.first?.portName ?? "a device")."
            default:
                text = nil
            }
            MainActor.assumeIsolated {
                self?.routeChanges += 1
                if let text { self?.connections.values.forEach { $0.status(.soundDevice, text) } }
            }
        }
    }

    /// Counts audio route changes (views showing devices refresh on it).
    var routeChanges = 0

    /// The desktop's "Reset preferences to default": every setting as it
    /// was at first (servers, accounts and sound packs stay).
    func resetPreferences() {
        let keep: Set<String> = ["servers", "installId", "ngEmail", "ngSyncState", "soundPacks", ICloudSync.enabledKey, "icloudAppliedTime"]
        for k in defaults.dictionaryRepresentation().keys where !keep.contains(k) && !k.hasPrefix("Apple") && !k.hasPrefix("NS") {
            defaults.removeObject(forKey: k)
        }
        LiveActivities.shared.reset()
        talkMode = .pushToTalk
        voiceLevel = 2
        nickname = ""
        audio = defaultAudioSettings()
        recordMP3 = true; recordOneFile = true; recordEachPerson = false; recordMediaFiles = false; saveChatLogs = false
        statusMessage = ""; awayAfterSeconds = 180; awayMessage = ""; awayStopsVoiceActivation = false
        showUsernames = false; showTopics = false; sortChannelsByName = true; infoStyle = .text; showUserCount = true; showLastTalk = true; showIcons = true; maxTextLength = 50; channelTap = .joinOrLeave; autoExpandChannels = false; restoreUserSettings = true; sendOnReturn = true
        timestampFormat = ""; streamingStatus = false; messagePopup = true; excludedDialog = false; serverListOnStart = false
        showTimestamps = true; showMOTD = true; eventsInChat = true; notifyInBackground = true
        reconnect = true; joinRoot = true; defaultSubscriptionsOff = []
        sounds.revert()
        sounds.volume = 1
        sounds.selectedId = InstalledPack.builtIn.id
        speech.revert()
        chatTemplates.revert()
        statusEvents.revert()
        AudioSession.activate()
    }

    /// A server from a .tt file, tt:// link, join code or the public list
    /// (the same server already saved is updated instead).
    @discardableResult
    func addFromEntry(_ e: HostEntry, connect: Bool = false) -> SavedServer {
        var s = SavedServer(e)
        if let same = servers.first(where: { $0.host.caseInsensitiveCompare(e.host) == .orderedSame && $0.tcpPort == e.tcpPort && $0.username == e.username }) {
            let id = same.id
            s.id = id
            s.syncKey = same.syncKey
        }
        upsert(s, password: e.password.isEmpty ? Passwords.get(s.id) : e.password)
        if connect { connection(for: s).connect() }
        return s
    }

    /// Opens what iOS hands the app: tt:// links (connect) and .tt files.
    func open(_ url: URL) {
        #if DEBUG
        // UI tests only: the actions Siri, Control Center and Live
        // Activities run (Siri itself can't be driven by a test).
        if url.scheme?.lowercased() == "teamtalkng", url.host == "uitest-action",
           ProcessInfo.processInfo.arguments.contains("-UITestReset") {
            ShortcutActions.runForUITest(url)
            return
        }
        #endif
        // A Live Activity tapped: that server's screen.
        if url.scheme?.lowercased() == "teamtalkng", url.host == "server" {
            openServer(id: url.lastPathComponent)
            return
        }
        if url.scheme?.lowercased() == "tt", let e = parseTtLink(link: url.absoluteString) {
            addFromEntry(e, connect: true)
            announce("Connecting to \(e.host)")
            return
        }
        let reading = url.startAccessingSecurityScopedResource()
        defer { if reading { url.stopAccessingSecurityScopedResource() } }
        guard let xml = try? String(contentsOf: url, encoding: .utf8) else {
            announce("That file couldn't be read")
            return
        }
        do {
            let list = try parseTtFile(xml: xml)
            for e in list { addFromEntry(e) }
            announce(list.count == 1 ? "Added \(list[0].name)" : "Added \(list.count) servers")
        } catch {
            announce(words(error))
        }
    }

    /// Servers marked to connect when the app starts.
    /// The server screens open (so Siri and Control Center can open one).
    var navigation: [SavedServer] = []

    /// Opens a saved server's screen and connects (Siri, Control Center).
    func openServer(id: String) {
        guard let s = servers.first(where: { $0.id.uuidString == id }) else { return }
        connection(for: s).connect()
        navigation = [s]
    }

    /// The app, for App Intents (Siri and Control Center run in it).
    @MainActor static weak var shared: AppModel?
    #if DEBUG
    /// UI tests: what the last test action said (shown on the server list).
    var uiTestActionResult = ""
    #endif

    func connectOnStart() {
        for s in servers where s.connectOnStart == true { connection(for: s).connect() }
    }

    /// The app went to the background (or was locked), or came back.
    func activeChanged(_ active: Bool) {
        awayTimer?.cancel()
        awayTimer = nil
        if active {
            for c in connections.values { c.setAutoAway(false) }
            return
        }
        guard awayAfterSeconds > 0 else { return }
        let seconds = awayAfterSeconds
        awayTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self else { return }
            for c in self.connections.values { c.setAutoAway(true) }
        }
    }

    private func saveAudio() {
        defaults.set(["echo": audio.echoCancellation ? 1 : 0, "agc": audio.gainControl ? 1 : 0,
                      "denoise": audio.noiseSuppression ? 1 : 0, "mic": Int(audio.micGain),
                      "out": Int(audio.outputVolume), "media": Int(audio.mediaVolume)], forKey: "audio")
    }

    private func save() {
        // Not while loading: with @Observable, setting a property in init
        // runs its didSet, and saving then would write the settings not
        // loaded yet back to their defaults.
        guard !loading else { return }
        defaults.set(try? JSONEncoder().encode(servers), forKey: "servers")
        // Their names for Siri and the Control Center control.
        Service.group?.set(servers.map { ["id": $0.id.uuidString, "name": $0.title] }, forKey: "shortcutServers")
        defaults.set(talkMode.rawValue, forKey: "talkMode")
        defaults.set(voiceLevel, forKey: "voiceLevel")
        defaults.set(nickname, forKey: "nickname")
        defaults.set(gender == .male ? "male" : gender == .female ? "female" : "neutral", forKey: "gender")
        defaults.set(recordMP3, forKey: "recordMP3")
        defaults.set(recordOneFile, forKey: "recordOneFile")
        defaults.set(recordEachPerson, forKey: "recordEachPerson")
        defaults.set(recordMediaFiles, forKey: "recordMediaFiles")
        defaults.set(saveChatLogs, forKey: "saveChatLogs")
        defaults.set(audioNetVolume, forKey: "audioNetVolume")
        defaults.set(mixFileVolume, forKey: "mixFileVolume")
        defaults.set(streamVideo, forKey: "streamVideo")
        defaults.set(showUsernames, forKey: "showUsernames")
        defaults.set(showTopics, forKey: "showTopics")
        defaults.set(sortChannelsByName, forKey: "sortChannelsByName")
        defaults.set(infoStyle.rawValue, forKey: "infoStyle")
        defaults.set(showUserCount, forKey: "showUserCount")
        defaults.set(showLastTalk, forKey: "showLastTalk")
        defaults.set(showIcons, forKey: "showIcons")
        defaults.set(maxTextLength, forKey: "maxTextLength")
        defaults.set(channelTap.rawValue, forKey: "channelTap")
        defaults.set(autoExpandChannels, forKey: "autoExpandChannels")
        defaults.set(restoreUserSettings, forKey: "restoreUserSettings")
        defaults.set(sendOnReturn, forKey: "sendOnReturn")
        defaults.set(timestampFormat, forKey: "timestampFormat")
        defaults.set(streamingStatus, forKey: "streamingStatus")
        defaults.set(messagePopup, forKey: "messagePopup")
        defaults.set(excludedDialog, forKey: "excludedDialog")
        defaults.set(serverListOnStart, forKey: "serverListOnStart")
        defaults.set(showTimestamps, forKey: "showTimestamps")
        defaults.set(showMOTD, forKey: "showMOTD")
        defaults.set(eventsInChat, forKey: "eventsInChat")
        defaults.set(notifyInBackground, forKey: "notifyInBackground")
        defaults.set(reconnect, forKey: "reconnect")
        defaults.set(joinRoot, forKey: "joinRoot")
        defaults.set(defaultSubscriptionsOff.map { "\($0)" }, forKey: "subscriptionsOff")
        defaults.set(statusMessage, forKey: "statusMessage")
        defaults.set(awayAfterSeconds, forKey: "awayAfterSeconds")
        defaults.set(awayMessage, forKey: "awayMessage")
        defaults.set(awayStopsVoiceActivation, forKey: "awayStopsVoiceActivation")
    }

    func upsert(_ server: SavedServer, password: String) {
        if let i = servers.firstIndex(where: { $0.id == server.id }) {
            servers[i] = server
        } else {
            servers.append(server)
        }
        Passwords.set(password, for: server.id)
        save()
        account.changed()
    }

    /// From NG Account: the servers as the account has them now (no sync
    /// back of this change).
    /// A server's own volumes changed (kept on this iPhone, not synced).
    func setVolumes(of server: SavedServer) {
        guard let i = servers.firstIndex(where: { $0.id == server.id }) else { return }
        servers[i].outputVolume = server.outputVolume
        servers[i].micGain = server.micGain
        servers[i].mediaVolume = server.mediaVolume
        save()
        if let c = connections[server.id] {
            c.server = servers[i]
            c.applyAudioSettings()
        }
    }

    func applySynced(_ list: [SavedServer], passwords: [UUID: String]) {
        servers = list
        for (id, p) in passwords { Passwords.set(p, for: id) }
        save()
    }

    func delete(_ server: SavedServer) {
        connections[server.id]?.disconnect()
        connections[server.id] = nil
        servers.removeAll { $0.id == server.id }
        Passwords.set("", for: server.id)
        History.delete(for: server.id)
        save()
        account.deleted(server.key)
    }

    func move(from: IndexSet, to: Int) {
        servers.move(fromOffsets: from, toOffset: to)
        save()
        account.changed()
    }

    /// The server's connection, made (not connected) on first use.
    /// The Monitor's connections, shown as server screens (monitor mode).
    @ObservationIgnored private var monitorConnections: [Int64: ServerConnection] = [:]

    func monitorConnection(for m: MonitorServer) -> ServerConnection {
        if let c = monitorConnections[m.id] { return c }
        let c = ServerConnection(monitorServer: m, app: self)
        monitorConnections[m.id] = c
        return c
    }

    func connection(for server: SavedServer) -> ServerConnection {
        // The saved server as it is now: the navigation path holds a copy
        // from when it was opened, and every redraw passing that back undid
        // changes made since (this server's own volumes, the UI tests found).
        let server = servers.first { $0.id == server.id } ?? server
        if let c = connections[server.id] {
            c.server = server
            return c
        }
        let c = ServerConnection(server: server, app: self)
        connections[server.id] = c
        return c
    }

    // MARK: The headset button (the old app's)

    /// The open server, or the only connected one.
    var activeConnection: ServerConnection? {
        if let id = navigation.last?.id, let c = connections[id], c.isConnected, c.hasAudio { return c }
        let live = connections.values.filter { $0.isConnected && $0.hasAudio }
        return live.count == 1 ? live.first : nil
    }

    /// A headset's or AirPods' button: one press talks or stops (or mutes
    /// and unmutes, as Magic Tap); next and previous start talking, pause
    /// stops (the old app's). iOS sends them only while this app is the one
    /// playing: with other apps' audio playing too, they may go to that app.
    private func setUpHeadsetButton() {
        let center = MPRemoteCommandCenter.shared()
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            guard let c = self?.activeConnection else { return .noActionableNowPlayingItem }
            c.toggleTalking()
            return .success
        }
        let start: (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus = { [weak self] _ in
            guard let c = self?.activeConnection else { return .noActionableNowPlayingItem }
            if self?.talkMode == .pushToTalk { if !c.transmitting { c.toggleTalking() } } else if c.muted { c.toggleTalking() }
            return .success
        }
        let stop: (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus = { [weak self] _ in
            guard let c = self?.activeConnection else { return .noActionableNowPlayingItem }
            if self?.talkMode == .pushToTalk { if c.transmitting { c.toggleTalking() } } else if !c.muted { c.toggleTalking() }
            return .success
        }
        center.playCommand.addTarget(handler: start)
        center.nextTrackCommand.addTarget(handler: start)
        center.previousTrackCommand.addTarget(handler: start)
        center.pauseCommand.addTarget(handler: stop)
        UIApplication.shared.beginReceivingRemoteControlEvents()
    }
}
