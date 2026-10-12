// What the monitor code uses from the rest of the app.
import Foundation
enum Sounds { case logged_IN, logged_OUT, user_MSG, chan_MSG, broadcast_MSG, srv_LOST }
extension MonitorEventText {
    static func describe(_ e: MonitorEvent) -> String { describe(e, model: nil) ?? "(quiet)" }
}

/// The app's saved server, as far as the monitor code uses it.
class Server: NSObject {
    var name = ""
    var ipaddr = ""
    var tcpport = 10333
    var nickname = ""
    var username = ""
    var password = ""
    var encrypted = false
}

/// Preparing notification sounds needs the app's sound packs.
enum MonitorNotificationSounds {
    static func refresh() {}
}

/// The app's Settings nickname.
let PREF_GENERAL_NICKNAME = "nickname_preference"

/// The gender in Settings (0 male, 1 female, 2 neutral).
var stubGenderIndex = 2
func preferredGenderIndex() -> Int { stubGenderIndex }

/// NG Account as the monitor code sees it: which account this iPhone is
/// signed in to (the harness signs in with the real API client).
final class NGAccountCenter {
    static let shared = NGAccountCenter()
    var signIn: MonitorAccount?
    var isSignedIn: Bool { signIn != nil }
    var sessionsEnded = 0
    var remoteChanges = 0
    func sessionEnded() {
        signIn = nil
        sessionsEnded += 1
    }
    @MainActor func remoteChange() { remoteChanges += 1 }
    @MainActor func absorbOldSignUps() async {}
}
