import Foundation
import UserNotifications

/// The sound of Monitor notifications (the old app's): the sound pack's
/// sounds (the default), the iPhone's own notification sound, or none.
/// iOS plays notification sounds only from the app's own files (WAV, AIFF
/// or CAF, at most 30 seconds), so the app copies the pack's sounds into
/// the App Group's Library/Sounds and this extension picks them by the
/// Monitor's sound name. Shared by the app and the notification extension.
enum MonitorSound {
    enum Choice: String, CaseIterable, Identifiable {
        case soundPack, system, none
        var id: Self { self }
        var label: String {
            switch self {
            case .soundPack: "The sound pack's sounds"
            case .system: "The iPhone's notification sound"
            case .none: "None"
            }
        }
    }

    static let group = Bundle.main.object(forInfoDictionaryKey: "TTNGAppGroup") as? String ?? ""
    static var defaults: UserDefaults? { UserDefaults(suiteName: group) }

    static var choice: Choice {
        get { defaults?.string(forKey: "monitorSound").flatMap(Choice.init(rawValue:)) ?? .soundPack }
        set { defaults?.set(newValue.rawValue, forKey: "monitorSound") }
    }

    /// The prepared sounds by the Monitor's name (`logged_on`): a file in
    /// `directory`, or "" when that sound event is off in the app.
    static var files: [String: String] {
        get { defaults?.dictionary(forKey: "monitorSoundFiles") as? [String: String] ?? [:] }
        set { defaults?.set(newValue, forKey: "monitorSoundFiles") }
    }

    static var directory: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)?
            .appendingPathComponent("Library/Sounds", isDirectory: true)
    }

    /// The sound for a push naming `service` (such as `logged_on.wav`).
    static func sound(service: String?) -> UNNotificationSound? {
        switch choice {
        case .none: return nil
        case .system: return .default
        case .soundPack:
            guard let service else { return .default }
            let name = (service as NSString).deletingPathExtension
            guard let file = files[name] else { return .default }
            if file.isEmpty { return nil }
            guard let dir = directory, FileManager.default.fileExists(atPath: dir.appendingPathComponent(file).path) else { return .default }
            return UNNotificationSound(named: UNNotificationSoundName(file))
        }
    }
}
