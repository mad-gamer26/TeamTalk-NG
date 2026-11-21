import AVFoundation
import CallKit
import SwiftUI

@main
struct TeamTalkNGApp: App {
    @UIApplicationDelegateAdaptor(PushDelegate.self) private var pushDelegate
    /// Nil until the settings can be read (see `SettingsAccess`): started
    /// in the background after a restart, before the first unlock, the
    /// app waits rather than read empty settings and save them.
    @State private var model: AppModel?

    init() {
        #if DEBUG
        // UI tests (apps/ios/UITests): every test starts as a fresh install.
        if ProcessInfo.processInfo.arguments.contains("-UITestReset") {
            UITestReset.wipe()
            // No animations to wait for (a context menu's never settles for
            // the UI tests' idle check).
            UIView.setAnimationsEnabled(false)
        }
        #endif
        if !Self.onMac, SettingsAccess.readable { _model = State(initialValue: Self.makeModel()) }
    }

    /// The iPhone app run on a Mac (Apple silicon Macs can run iPhone apps):
    /// not meant for it (the Mac version is its own app), so it does nothing
    /// there but say so.
    private static let onMac = ProcessInfo.processInfo.isiOSAppOnMac

    /// Reads the settings and makes the app's model; only once they can
    /// be read.
    @MainActor private static func makeModel() -> AppModel {
        // The old app's servers and settings (once, when this app replaced
        // it), then iCloud's newer settings, before anything reads them.
        OldAppImport.runIfNeeded()
        ICloudSync.shared.startAtLaunch()
        return AppModel()
    }

    /// The first unlock after a restart (or any later moment the settings
    /// became readable): the app starts now.
    private func startIfReadable() {
        guard model == nil, !Self.onMac, SettingsAccess.readable else { return }
        model = Self.makeModel()
    }
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            Group {
                if Self.onMac {
                    Text("TeamTalk NG for iPhone doesn't run on a Mac. The Mac version is its own app, on TeamTalk NG's GitHub releases.")
                        .padding()
                } else if let model {
                    main(model)
                } else {
                    Text("Unlock your iPhone to use TeamTalk NG.")
                        .padding()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.protectedDataDidBecomeAvailableNotification)) { _ in
                startIfReadable()
            }
            .onChange(of: phase) { _, p in if p == .active { startIfReadable() } }
            // A backup restored: everything reads the restored settings.
            // Everything erased: a fresh start, as a new install.
            .onReceive(NotificationCenter.default.publisher(for: .ttngErased)) { _ in
                model = nil
                DispatchQueue.main.async {
                    model = AppModel()
                    announce("TeamTalk NG erased")
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .ttngRestored)) { _ in
                model = nil
                DispatchQueue.main.async {
                    model = AppModel()
                    announce("Backup restored")
                }
            }
        }
        .onChange(of: phase) { _, p in
            guard let model else { return }
            // Away after a while in the background, as the desktop is after
            // a while without input.
            // Coming back leaves the sound as it is (the owner's choice: the
            // audio was set up again each time). An interruption that ends
            // (a phone call) makes the session active again (AppModel).
            if p == .active { model.activeChanged(true) } else if p == .background { model.activeChanged(false) }
            // My sound packs changed on another device meanwhile.
            if p == .active { Task { await model.sounds.syncPacksWithCloud() } }
        }
    }

    private func main(_ model: AppModel) -> some View {
            ServerListView()
                // A new model (after a restore) is a new screen: set up again.
                .id(ObjectIdentifier(model))
                .environment(model)
                .onOpenURL { model.open($0) }
                .task {
                    // No audio session at launch (only Sound System and a
                    // connection set one up).
                    AppModel.shared = model
                    LiveActivities.shared.endLeftovers()
                    // The Monitor's notifications: the device token to it.
                    PushDelegate.tokenArrived = { token in Task { await model.monitor.setPushToken(token) } }
                    model.connectOnStart()
                    if model.notifyInBackground { requestNotifications() }
                }
    }
}

/// The audio session every connection shares: talking and listening, out
/// of the speaker unless headphones are in, and kept going when locked.
enum AudioSession {
    /// `speaker`: the loudspeaker rather than the earpiece (when nothing
    /// is plugged in). `bluetoothMic`: Bluetooth headsets' microphones too
    /// (calls quality, both ways).
    /// `mixWithOthers`: plays along with other apps (music, VoiceOver's
    /// sounds stay). `echoCancellation`: the voice chat mode, which the
    /// SDK's Voice-Processing I/O unit (Apple's echo cancellation) needs.
    // MARK: When it's set up (the owner's rule, 2026-11-21)
    //
    // Only while Settings → Sound System is on screen (or its microphone
    // test runs), or once a server connection has succeeded (from the
    // first one; kept while it reconnects). Nothing else sets it up: when
    // neither holds, it's given back to other apps.

    /// Settings → Sound System on screen.
    @MainActor static var settingsOpen = false { didSet { update() } }
    /// Its "Test Selected" running.
    @MainActor static var micTest = false { didSet { update() } }
    /// Set up by this app now.
    @MainActor private(set) static var isSetUp = false
    /// Times it was taken back after something else had it (UI tests).
    @MainActor private(set) static var resumes = 0

    @MainActor static var wanted: Bool {
        settingsOpen || micTest || (AppModel.shared?.connections.values.contains { $0.holdsAudioSession } ?? false)
    }

    /// Set up as the settings are now, or given back, as the rule says.
    @MainActor static func update() {
        if wanted {
            _ = configure()
            isSetUp = true
            Recovery.shared.start()
        } else if isSetUp {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            isSetUp = false
        }
    }

    /// Something else had the session (dictation, a phone call, Siri,
    /// another app, iOS resetting its audio): taken back and every
    /// connection's sound devices opened again, so TeamTalk keeps playing.
    @MainActor @discardableResult
    static func resume() -> Bool {
        guard wanted else { return true }
        guard configure() else { return false }
        isSetUp = true
        resumes += 1
        for c in AppModel.shared?.connections.values.filter({ $0.holdsAudioSession }) ?? [] {
            Task { await c.reopenAudio() }
        }
        return true
    }

    /// The call-style session (talking, listening, echo cancellation):
    /// `speaker`, the loudspeaker rather than the earpiece (when nothing is
    /// plugged in); `bluetoothMic`, Bluetooth headsets' microphones too
    /// (call quality, both ways); `mixWithOthers`, along with other apps
    /// (music, VoiceOver's sounds stay); `echoCancellation`, the voice chat
    /// mode the SDK's Voice-Processing I/O unit needs. False: iOS refused
    /// (a phone call has it).
    private static func configure(speaker: Bool = UserDefaults.standard.object(forKey: "speaker") as? Bool ?? true,
                                  bluetoothMic: Bool = UserDefaults.standard.bool(forKey: "bluetoothMic"),
                                  mixWithOthers: Bool = UserDefaults.standard.object(forKey: "mixWithOthers") as? Bool ?? true,
                                  echoCancellation: Bool = (UserDefaults.standard.dictionary(forKey: "audio")?["echo"] as? Int) == 1) -> Bool {
        let s = AVAudioSession.sharedInstance()
        var options: AVAudioSession.CategoryOptions = [.allowBluetoothA2DP]
        if speaker { options.insert(.defaultToSpeaker) }
        if bluetoothMic { options.insert(.allowBluetoothHFP) }
        if mixWithOthers { options.insert(.mixWithOthers) }
        try? s.setCategory(.playAndRecord, mode: echoCancellation ? .voiceChat : .default, options: options)
        do { try s.setActive(true) } catch { return false }
        let choice = UserDefaults.standard.string(forKey: "preferredInput") ?? ""
        if echoCancellation {
            // Voice chat: the iPhone's microphone as iOS sets it up for
            // calls (mono, its own position); another microphone as chosen.
            let builtIn = BuiltInMic(tag: choice) != nil || s.availableInputs?.first(where: { $0.uid == choice })?.portType == .builtInMic
            if builtIn, let mic = s.availableInputs?.first(where: { $0.portType == .builtInMic }) {
                try? s.setPreferredInput(mic)
            } else if let port = s.availableInputs?.first(where: { $0.uid == choice }) {
                try? s.setPreferredInput(port)
            }
            try? s.setPreferredInputNumberOfChannels(1)
        } else if let built = BuiltInMic(tag: choice) {
            useBuiltIn(built, s)
        } else if let port = s.availableInputs?.first(where: { $0.uid == choice }) {
            // The built-in microphone picked before it had a submenu: the bottom one.
            if port.portType == .builtInMic { useBuiltIn(.bottom, s) } else { try? s.setPreferredInput(port) }
        }
        return true
    }

    /// The iPhone's own microphone: the bottom one (as phone calls use it),
    /// or the front or back one in stereo.
    enum BuiltInMic: String, CaseIterable, Identifiable {
        case bottom, front, back
        var id: String { rawValue }
        var tag: String { "builtin:\(rawValue)" }
        var label: String {
            switch self {
            case .bottom: "Bottom"
            case .front: "Front, stereo"
            case .back: "Back, stereo"
            }
        }
        var orientation: AVAudioSession.Orientation {
            switch self {
            case .bottom: .bottom
            case .front: .front
            case .back: .back
            }
        }
        init?(tag: String) {
            guard tag.hasPrefix("builtin:"), let m = BuiltInMic(rawValue: String(tag.dropFirst(8))) else { return nil }
            self = m
        }
    }

    private static func useBuiltIn(_ choice: BuiltInMic, _ s: AVAudioSession) {
        guard let mic = s.availableInputs?.first(where: { $0.portType == .builtInMic }) else { return }
        try? s.setPreferredInput(mic)
        guard let source = mic.dataSources?.first(where: { $0.orientation == choice.orientation }) else { return }
        let patterns = source.supportedPolarPatterns ?? []
        if choice != .bottom, patterns.contains(.stereo) {
            try? source.setPreferredPolarPattern(.stereo)
            try? mic.setPreferredDataSource(source)
            try? s.setPreferredInputNumberOfChannels(min(2, s.maximumInputNumberOfChannels))
        } else {
            if patterns.contains(.omnidirectional) { try? source.setPreferredPolarPattern(.omnidirectional) }
            try? mic.setPreferredDataSource(source)
            try? s.setPreferredInputNumberOfChannels(1)
        }
    }

    /// What the microphone setting says, in words.
    static func inputLabel(_ choice: String, echoCancellation: Bool = false) -> String {
        if choice.isEmpty { return "Automatic" }
        if echoCancellation, BuiltInMic(tag: choice) != nil || inputs.first(where: { $0.uid == choice })?.portType == .builtInMic {
            return inputs.first { $0.portType == .builtInMic }?.portName ?? "iPhone Microphone"
        }
        if let m = BuiltInMic(tag: choice) {
            let name = inputs.first { $0.portType == .builtInMic }?.portName ?? "iPhone Microphone"
            return "\(name), \(m.label)"
        }
        guard let port = inputs.first(where: { $0.uid == choice }) else { return "Automatic (not connected)" }
        return port.portType == .builtInMic ? "\(port.portName), Bottom" : port.portName
    }

    /// The microphones there are now (built in, wired, Bluetooth).
    static var inputs: [AVAudioSessionPortDescription] { AVAudioSession.sharedInstance().availableInputs ?? [] }

    static func requestMicrophone() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }
}

/// What went wrong, in the core's words.
func words(_ error: Error) -> String {
    switch error as? TtError {
    case .NotConnected(let m), .Timeout(let m), .Connection(let m), .Refused(let m): m
    case .Server(_, let m): m
    case nil: error.localizedDescription
    }
}

/// Says something to VoiceOver now (when it's running).
@MainActor func announce(_ text: String) {
    #if DEBUG
    // What the app said, for the UI tests (uitest-action "announced").
    announcedForTests.append(text)
    if announcedForTests.count > 200 { announcedForTests.removeFirst(100) }
    #endif
    guard UIAccessibility.isVoiceOverRunning else { return }
    AccessibilityNotification.Announcement(text).post()
}

#if DEBUG
import Security

/// Everything announce() said (UI tests only).
@MainActor var announcedForTests: [String] = []

/// Everything the app keeps, gone (UI tests only, never in a release).
enum UITestReset {
    static func wipe() {
        let d = UserDefaults.standard
        if let id = Bundle.main.bundleIdentifier { d.removePersistentDomain(forName: id) }
        d.set(true, forKey: "setUp")  // no welcome sheet
        // The test lane's own service and catalog (scripts/test-ios-ui.sh).
        let env = ProcessInfo.processInfo.environment
        if let u = env["UITEST_SERVICE_URL"], !u.isEmpty { d.set(u, forKey: "uitestServiceURL") }
        if let u = env["UITEST_CATALOG_URL"], !u.isEmpty { d.set(u, forKey: "uitestCatalogURL") }
        if let g = Bundle.main.object(forInfoDictionaryKey: "TTNGAppGroup") as? String, let gd = UserDefaults(suiteName: g) {
            for k in gd.dictionaryRepresentation().keys { gd.removeObject(forKey: k) }
        }
        // This device's keychain items. iCloud Keychain's too only when no
        // iCloud account is signed in (then they're only here anyway): on a
        // signed-in Simulator, deleting them would delete them on every
        // device of that account.
        SecItemDelete([kSecClass as String: kSecClassGenericPassword,
                       kSecAttrSynchronizable as String: FileManager.default.ubiquityIdentityToken == nil
                           ? kSecAttrSynchronizableAny as Any : kCFBooleanFalse as Any] as CFDictionary)
        // Paired with the test's own Monitor (scripts/test-ios-ui.sh):
        // {"monitor_id", "name", "key", "phone_key"}, keys in base64.
        if let json = ProcessInfo.processInfo.environment["UITEST_OWN_MONITOR"], !json.isEmpty,
           let m = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: String],
           let id = m["monitor_id"], let key = m["key"], let phone = m["phone_key"] {
            let stored = ["id": id, "name": m["name"] ?? "Monitor", "key": key]
            if let d = try? JSONSerialization.data(withJSONObject: stored) {
                Passwords.setSecret(String(decoding: d, as: UTF8.self), "TeamTalk NG own monitor", "monitor")
            }
            Passwords.setSecret(phone, "TeamTalk NG own monitor", "phone key")
        }
        let fm = FileManager.default
        for dir in [FileManager.SearchPathDirectory.documentDirectory, .applicationSupportDirectory] {
            if let u = fm.urls(for: dir, in: .userDomainMask).first,
               let items = try? fm.contentsOfDirectory(at: u, includingPropertiesForKeys: nil) {
                for i in items { try? fm.removeItem(at: i) }
            }
        }
    }
}
#endif

extension AudioSession {
    /// Takes the session back after anything that took it: an interruption
    /// that ends (or never says so), iOS resetting its audio, dictation
    /// ending, a phone call ending, another app changing the session. Not
    /// while a phone call or dictation still has it.
    @MainActor final class Recovery: NSObject, CXCallObserverDelegate {
        static let shared = Recovery()
        private let calls = CXCallObserver()
        private var started = false
        /// Waiting to take it back (something has it).
        private var pending = false
        private var retry: Timer?

        private var onCall: Bool { calls.calls.contains { !$0.hasEnded } }
        /// The keyboard of the text field in use is dictating.
        private var dictating: Bool { UIResponder.current?.textInputMode?.primaryLanguage == "dictation" }

        func start() {
            guard !started else { return }
            started = true
            calls.setDelegate(self, queue: .main)
            let nc = NotificationCenter.default
            nc.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { n in
                let type = (n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap(AVAudioSession.InterruptionType.init(rawValue:))
                MainActor.assumeIsolated {
                    if type == .began { self.lost() } else { self.tryBack() }
                }
            }
            nc.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { self.lost(); self.tryBack() }
            }
            // Another app (or iOS) set the session to something else.
            nc.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { n in
                let reason = (n.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt).flatMap(AVAudioSession.RouteChangeReason.init(rawValue:))
                MainActor.assumeIsolated {
                    if reason == .categoryChange, AudioSession.isSetUp, AVAudioSession.sharedInstance().category != .playAndRecord {
                        self.lost(); self.tryBack()
                    }
                }
            }
            // Dictation in this app: when the keyboard leaves it.
            nc.addObserver(forName: UITextInputMode.currentInputModeDidChangeNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated {
                    if self.dictating { self.lost() } else if self.pending { self.tryBack(after: 0.5) }
                }
            }
            nc.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { if self.pending { self.tryBack() } }
            }
        }

        nonisolated func callObserver(_ callObserver: CXCallObserver, callChanged call: CXCall) {
            let ended = call.hasEnded
            MainActor.assumeIsolated {
                if ended { if self.pending { self.tryBack(after: 1) } } else { self.lost() }
            }
        }

        /// Something else has it now.
        private func lost() {
            guard AudioSession.isSetUp else { return }
            pending = true
            // An interruption doesn't always say it ended: tried again
            // every few seconds while nothing (a call, dictation) has it.
            if retry == nil {
                retry = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { _ in
                    MainActor.assumeIsolated { self.tryBack() }
                }
            }
        }

        private func tryBack(after delay: TimeInterval = 0) {
            guard delay == 0 else {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { MainActor.assumeIsolated { self.tryBack() } }
                return
            }
            guard pending || !AudioSession.isSetUp || AVAudioSession.sharedInstance().category != .playAndRecord else { return }
            guard AudioSession.wanted else { done(); return }
            guard !onCall, !dictating else { return }
            if AudioSession.resume() { done() }
        }

        private func done() {
            pending = false
            retry?.invalidate()
            retry = nil
        }

        #if DEBUG
        /// UI tests: as if something took the session and gave it back.
        func simulateInterruption() {
            lost()
            tryBack(after: 1)
        }
        #endif
    }
}

extension UIResponder {
    private static weak var found: UIResponder?
    /// What has the keyboard now (the first responder), if anything.
    @MainActor static var current: UIResponder? {
        found = nil
        UIApplication.shared.sendAction(#selector(ttngFound), to: nil, from: nil, for: nil)
        return found
    }
    @objc private func ttngFound() { UIResponder.found = self }
}
