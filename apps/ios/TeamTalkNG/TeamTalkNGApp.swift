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
    static func activate() {
        let s = AVAudioSession.sharedInstance()
        try? s.setCategory(.playAndRecord, mode: .default, options: [.allowBluetoothA2DP, .defaultToSpeaker])
        try? s.setActive(true)
    }

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
