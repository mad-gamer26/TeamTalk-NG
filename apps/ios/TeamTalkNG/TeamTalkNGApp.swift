import AVFoundation
import SwiftUI

@main
struct TeamTalkNGApp: App {
    @UIApplicationDelegateAdaptor(PushDelegate.self) private var pushDelegate
    @State private var model: AppModel

    init() {
        // The old app's servers and settings (once, when this app replaced
        // it), then iCloud's newer settings, before anything reads them.
        OldAppImport.runIfNeeded()
        ICloudSync.shared.startAtLaunch()
        _model = State(initialValue: AppModel())
    }
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            ServerListView()
                .environment(model)
                .onOpenURL { model.open($0) }
                .task {
                    // Set up at once, so sounds and speech play along with
                    // other apps from the start (not only once connected).
                    AudioSession.activate()
                    AppModel.shared = model
                    // The Monitor's notifications: the device token to it.
                    PushDelegate.tokenArrived = { token in Task { await model.monitor.setPushToken(token) } }
                    model.connectOnStart()
                    if model.notifyInBackground { requestNotifications() }
                }
        }
        .onChange(of: phase) { _, p in
            // Away after a while in the background, as the desktop is after
            // a while without input.
            if p == .active { model.activeChanged(true); AudioSession.activate() } else if p == .background { model.activeChanged(false) }
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
    static func activate(speaker: Bool = UserDefaults.standard.object(forKey: "speaker") as? Bool ?? true,
                         bluetoothMic: Bool = UserDefaults.standard.bool(forKey: "bluetoothMic"),
                         mixWithOthers: Bool = UserDefaults.standard.object(forKey: "mixWithOthers") as? Bool ?? true,
                         echoCancellation: Bool = (UserDefaults.standard.dictionary(forKey: "audio")?["echo"] as? Int) == 1) {
        let s = AVAudioSession.sharedInstance()
        var options: AVAudioSession.CategoryOptions = [.allowBluetoothA2DP]
        if speaker { options.insert(.defaultToSpeaker) }
        if bluetoothMic { options.insert(.allowBluetoothHFP) }
        if mixWithOthers { options.insert(.mixWithOthers) }
        try? s.setCategory(.playAndRecord, mode: echoCancellation ? .voiceChat : .default, options: options)
        try? s.setActive(true)
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
    guard UIAccessibility.isVoiceOverRunning else { return }
    AccessibilityNotification.Announcement(text).post()
}
