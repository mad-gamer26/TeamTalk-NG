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
