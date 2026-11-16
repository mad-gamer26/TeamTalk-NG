import Foundation

/// What Siri, the Shortcuts app, Control Center and Live Activities do (the
/// intents in Shared/AppActions.swift call these, in the app). Each returns
/// what's said back, or throws a ShortcutProblem that's said instead.
@MainActor
enum ShortcutActions {
    /// The connection meant: the server named, or the open one, or the only
    /// one connected.
    static func connection(_ serverId: String?) throws -> ServerConnection {
        guard let model = AppModel.shared else { throw ShortcutProblem("TeamTalk NG isn't ready yet. Try again.") }
        if let serverId {
            guard let c = model.connections.first(where: { $0.key.uuidString == serverId })?.value, c.isConnected else {
                let name = model.servers.first { $0.id.uuidString == serverId }?.title ?? "that server"
                throw ShortcutProblem("You're not connected to \(name).")
            }
            return c
        }
        if let c = model.activeConnection { return c }
        let live = model.connections.values.filter { $0.isConnected && $0.hasAudio }
        if live.isEmpty { throw ShortcutProblem("You're not connected to a server.") }
        throw ShortcutProblem("You're connected to more than one server. Say which one.")
    }

    /// Every connected server (for the status), or the one named.
    static func connections(_ serverId: String?) throws -> [ServerConnection] {
        if serverId != nil { return [try connection(serverId)] }
        let live = (AppModel.shared?.connections.values).map { Array($0.filter(\.isConnected)) } ?? []
        if live.isEmpty { throw ShortcutProblem("You're not connected to a server.") }
        return live
    }

    static func name(_ c: ServerConnection) -> String {
        c.snapshot?.server.name.nonEmpty ?? c.server.title
    }

    /// The desktop's Refresh Sound Devices: the server named, or every
    /// connected one (they share the sound devices).
    static func refreshSoundDevices(_ serverId: String?) async throws -> String {
        let list = try connections(serverId).filter(\.hasAudio)
        guard !list.isEmpty else { throw ShortcutProblem("The Monitor has no sound.") }
        AudioSession.activate()
        var failed: [String] = []
        for c in list where !(await c.reopenAudio()) { failed.append(name(c)) }
        if !failed.isEmpty { throw ShortcutProblem("The sound devices couldn't be opened on \(failed.joined(separator: ", ")).") }
        return "Sound devices refreshed."
    }

    static func disconnect(_ serverId: String?) throws -> String {
        let c = try connection(serverId)
        let n = name(c)
        c.disconnect()
        c.leaveScreen()
        return "Disconnected from \(n)."
    }

    static func disconnectAll() throws -> String {
        let live = try connections(nil)
        for c in live { c.disconnect(); c.leaveScreen() }
        return live.count == 1 ? "Disconnected from \(name(live[0]))." : "Disconnected from \(live.count) servers."
    }

    static func muteEveryone(_ serverId: String?, _ action: SwitchAction) throws -> String {
        let c = try connection(serverId)
        guard c.hasAudio else { throw ShortcutProblem("The Monitor has no sound.") }
        let now = c.snapshot?.mutedAll ?? false
        let on = action.resolve(now)
        if on != now { c.setMuteAll(on) }
        return on ? "Everyone muted for you on \(name(c))." : "Everyone unmuted for you on \(name(c))."
    }

    static func talkMode(_ mode: TalkModeChoice) throws -> String {
        guard let model = AppModel.shared else { throw ShortcutProblem("TeamTalk NG isn't ready yet. Try again.") }
        let next: TalkMode
        switch mode {
        case .pushToTalk: next = .pushToTalk
        case .voiceActivation: next = .voiceActivation
        case .switchMode: next = model.talkMode == .pushToTalk ? .voiceActivation : .pushToTalk
        }
        model.talkMode = next
        return next == .pushToTalk ? "Push to talk on." : "Voice activation on."
    }

    /// Push to talk: talking or not. Voice activation: the microphone
    /// unmuted or muted.
    static func microphone(_ serverId: String?, _ action: SwitchAction) throws -> String {
        let c = try connection(serverId)
        guard c.hasAudio, let model = AppModel.shared else { throw ShortcutProblem("The Monitor has no sound.") }
        if model.talkMode == .pushToTalk {
            let on = action.resolve(c.transmitting)
            if on != c.transmitting { c.toggleTalking() }
            return on ? "Talking on \(name(c))." : "Stopped talking on \(name(c))."
        }
        let on = action.resolve(!c.muted)
        if on == c.muted { c.toggleTalking() }
        return on ? "Microphone on, on \(name(c))." : "Microphone muted on \(name(c))."
    }

    static func setStatus(_ serverId: String?, _ status: StatusChoice, _ message: String?) throws -> String {
        let live = try connections(serverId)
        for c in live {
            // No message given: the one already set stays.
            let msg = message ?? c.me?.statusMessage ?? AppModel.shared?.statusMessage ?? ""
            c.setStatus(status.mode, msg)
        }
        let where_ = live.count == 1 ? name(live[0]) : "\(live.count) servers"
        return "Status set to \(status.label) on \(where_)."
    }

    /// To the channel I'm in, or privately to someone (by nickname or
    /// username) on that server.
    static func sendMessage(_ serverId: String?, _ text: String, to person: String?) throws -> String {
        let c = try connection(serverId)
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ShortcutProblem("There's nothing to send.") }
        if let person = person?.trimmingCharacters(in: .whitespaces), !person.isEmpty {
            let users = c.snapshot?.users ?? []
            guard let u = users.first(where: { $0.displayName.localizedCaseInsensitiveCompare(person) == .orderedSame
                || $0.username.localizedCaseInsensitiveCompare(person) == .orderedSame })
                ?? users.first(where: { $0.displayName.localizedCaseInsensitiveContains(person) }) else {
                throw ShortcutProblem("Nobody called \(person) is on \(name(c)).")
            }
            c.send(text, to: u)
            return "Sent to \(u.displayName)."
        }
        guard (c.snapshot?.myChannelId ?? 0) > 0 else { throw ShortcutProblem("You're not in a channel on \(name(c)).") }
        c.send(text)
        return "Sent to the channel."
    }
}

#if DEBUG
extension ShortcutActions {
    /// teamtalkng://uitest-action?do=NAME&...: the result announced.
    static func runForUITest(_ url: URL) {
        let q = Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        let server = q["server"].flatMap { name in AppModel.shared?.servers.first { $0.title == name }?.id.uuidString }
        let sw = SwitchAction(rawValue: q["value"] ?? "toggle") ?? .toggle
        do {
            let said: String
            switch q["do"] ?? "" {
            case "refreshSoundDevices":
                Task { @MainActor in
                    do { AppModel.shared?.uiTestActionResult = try await refreshSoundDevices(server) } catch let p as ShortcutProblem {
                        AppModel.shared?.uiTestActionResult = p.text
                    } catch {}
                }
                return
            case "packSound":
                // What choosing a sound file does (the file picker can't be
                // driven by a test): a built-in sound for an event in a pack.
                let sounds = AppModel.shared?.sounds
                if let p = sounds?.packs.first(where: { $0.name == q["pack"] }), let e = SoundEvent(rawValue: q["event"] ?? ""),
                   let src = Bundle.main.url(forResource: q["from"] ?? "user_msg", withExtension: "wav") {
                    said = sounds?.setSound(e, in: p, from: src) == true ? "Sound set" : "Sound refused"
                } else {
                    said = "No such pack or sound"
                }
            case "disconnect": said = try disconnect(server)
            case "disconnectAll": said = try disconnectAll()
            case "muteEveryone": said = try muteEveryone(server, sw)
            case "talkMode": said = try talkMode(TalkModeChoice(rawValue: q["value"] ?? "") ?? .switchMode)
            case "microphone": said = try microphone(server, sw)
            case "status": said = try setStatus(server, StatusChoice(rawValue: q["value"] ?? "") ?? .available, q["message"])
            case "message": said = try sendMessage(server, q["text"] ?? "", to: q["to"])
            default: said = "Unknown action"
            }
            AppModel.shared?.uiTestActionResult = said
        } catch let p as ShortcutProblem {
            AppModel.shared?.uiTestActionResult = p.text
        } catch {
            AppModel.shared?.uiTestActionResult = "\(error)"
        }
    }
}
#endif

extension StatusChoice {
    var mode: StatusMode {
        switch self {
        case .available: .available
        case .away: .away
        case .question: .question
        }
    }
}
