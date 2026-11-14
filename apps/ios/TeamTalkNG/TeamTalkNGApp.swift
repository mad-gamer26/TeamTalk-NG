import AVFoundation
import SwiftUI

@main
struct TeamTalkNGApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ServerListView()
                .environment(model)
        }
    }
}

/// The audio session every connection shares: talking and listening, out
/// of the speaker unless headphones are in, and kept going when locked.
enum AudioSession {
    /// `speaker`: the loudspeaker rather than the earpiece (when nothing
    /// is plugged in). `bluetoothMic`: Bluetooth headsets' microphones too
    /// (calls quality, both ways).
    static func activate(speaker: Bool = UserDefaults.standard.object(forKey: "speaker") as? Bool ?? true,
                         bluetoothMic: Bool = UserDefaults.standard.bool(forKey: "bluetoothMic")) {
        let s = AVAudioSession.sharedInstance()
        var options: AVAudioSession.CategoryOptions = [.allowBluetoothA2DP]
        if speaker { options.insert(.defaultToSpeaker) }
        if bluetoothMic { options.insert(.allowBluetoothHFP) }
        try? s.setCategory(.playAndRecord, mode: .default, options: options)
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
