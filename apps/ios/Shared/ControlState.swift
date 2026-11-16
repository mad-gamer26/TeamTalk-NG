import Foundation

/// What Control Center's switches show (the app writes it to the App Group
/// whenever it changes, for the server it acts on: the open one, or the
/// only one connected).
enum ControlState {
    static var group: UserDefaults? {
        let name = Bundle.main.object(forInfoDictionaryKey: "TTNGAppGroup") as? String ?? ""
        return UserDefaults(suiteName: name)
    }

    struct Values: Equatable {
        var connected = false
        var serverName = ""
        var microphoneOn = false
        var mutedEveryone = false
        var voiceActivation = false
    }

    static func read() -> Values {
        guard let d = group else { return Values() }
        return Values(connected: d.bool(forKey: "control.connected"),
                      serverName: d.string(forKey: "control.serverName") ?? "",
                      microphoneOn: d.bool(forKey: "control.microphoneOn"),
                      mutedEveryone: d.bool(forKey: "control.mutedEveryone"),
                      voiceActivation: d.bool(forKey: "control.voiceActivation"))
    }

    static func write(_ v: Values) {
        guard let d = group else { return }
        d.set(v.connected, forKey: "control.connected")
        d.set(v.serverName, forKey: "control.serverName")
        d.set(v.microphoneOn, forKey: "control.microphoneOn")
        d.set(v.mutedEveryone, forKey: "control.mutedEveryone")
        d.set(v.voiceActivation, forKey: "control.voiceActivation")
    }
}
