import Foundation

/// The Monitor's notifications worded as the app says its events (Settings
/// → Spoken events), as the app's own notifications are. The app keeps the
/// wording in the shared App Group ("monitorWording": the Monitor's event
/// name → its template, such as "{user} has logged in on {server}"); the
/// notification extension rewords each push with it. Without it, or for
/// events with no wording of the app's, the Monitor's own text stays.
enum MonitorWording {
    static let groupKey = "monitorWording"

    /// The Monitor's event names and the app's spoken events they are.
    static let events = ["logged_in", "logged_out", "private_message", "channel_message", "broadcast"]

    /// The text for a push: `data` its event data, `title` the server's
    /// name (as in the server list), `body` the Monitor's own text.
    static func reword(data: [String: Any], title: String, body: String, wording: [String: String]) -> String? {
        guard let event = data["event"] as? String, var t = wording[event], !t.isEmpty else { return nil }
        var vars: [String: String] = ["server": title, "username": data["username"] as? String ?? ""]
        var nickname = data["nickname"] as? String ?? ""
        if event.hasSuffix("message") || event == "broadcast" {
            // "… message from Bob: the text": the person (when the data
            // hasn't them) and the text after them.
            guard let from = body.range(of: " from ") else { return nil }
            let rest = body[from.upperBound...]
            if !nickname.isEmpty, rest.hasPrefix(nickname + ": ") {
                vars["message"] = String(rest.dropFirst(nickname.count + 2))
            } else if let colon = rest.range(of: ": ") {
                if nickname.isEmpty { nickname = String(rest[..<colon.lowerBound]) }
                vars["message"] = String(rest[colon.upperBound...])
            } else {
                return nil
            }
        }
        vars["user"] = nickname.isEmpty ? vars["username"] : nickname
        for (k, v) in vars { t = t.replacingOccurrences(of: "{\(k)}", with: v ?? "") }
        let out = t.trimmingCharacters(in: .whitespacesAndNewlines)
        return out.isEmpty || out.contains("{") ? nil : out
    }
}
