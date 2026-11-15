import AVFoundation
import SwiftUI

@main
struct TeamTalkNGApp: App {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            ServerListView()
                .environment(model)
        }
        .onChange(of: phase) { _, p in
            // Away after a while in the background, as the desktop is after
            // a while without input.
            if p == .active { model.activeChanged(true) } else if p == .background { model.activeChanged(false) }
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
        if let name = UserDefaults.standard.string(forKey: "preferredInput"),
           let port = s.availableInputs?.first(where: { $0.uid == name }) {
            try? s.setPreferredInput(port)
        }
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
