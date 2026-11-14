import Foundation
import Observation

/// Saved servers, the open connections (several at once), and settings.
@MainActor @Observable
final class AppModel {
    private(set) var servers: [SavedServer] = []
    private(set) var connections: [UUID: ServerConnection] = [:]

    var talkMode: TalkMode = .pushToTalk {
        didSet { save(); connections.values.forEach { $0.applyTalkMode() } }
    }
    /// Voice activation: the level that starts it (0–100).
    var voiceLevel: Double = 20 {
        didSet { save(); connections.values.forEach { $0.applyTalkMode() } }
    }
    var nickname = "" { didSet { save() } }
    let sounds = SoundStore()
    @ObservationIgnored private(set) lazy var account = NGAccountStore(app: self)

    private let defaults = UserDefaults.standard

    init() {
        if let d = defaults.data(forKey: "servers"), let s = try? JSONDecoder().decode([SavedServer].self, from: d) {
            servers = s
        }
        talkMode = TalkMode(rawValue: defaults.string(forKey: "talkMode") ?? "") ?? .pushToTalk
        voiceLevel = defaults.object(forKey: "voiceLevel") as? Double ?? 20
        nickname = defaults.string(forKey: "nickname") ?? ""
    }

    private func save() {
        defaults.set(try? JSONEncoder().encode(servers), forKey: "servers")
        defaults.set(talkMode.rawValue, forKey: "talkMode")
        defaults.set(voiceLevel, forKey: "voiceLevel")
        defaults.set(nickname, forKey: "nickname")
    }

    func upsert(_ server: SavedServer, password: String) {
        if let i = servers.firstIndex(where: { $0.id == server.id }) {
            servers[i] = server
        } else {
            servers.append(server)
        }
        Passwords.set(password, for: server.id)
        save()
        account.changed()
    }

    /// From NG Account: the servers as the account has them now (no sync
    /// back of this change).
    func applySynced(_ list: [SavedServer], passwords: [UUID: String]) {
        servers = list
        for (id, p) in passwords { Passwords.set(p, for: id) }
        save()
    }

    func delete(_ server: SavedServer) {
        connections[server.id]?.disconnect()
        connections[server.id] = nil
        servers.removeAll { $0.id == server.id }
        Passwords.set("", for: server.id)
        History.delete(for: server.id)
        save()
        account.deleted(server.key)
    }

    func move(from: IndexSet, to: Int) {
        servers.move(fromOffsets: from, toOffset: to)
        save()
        account.changed()
    }

    /// The server's connection, made (not connected) on first use.
    func connection(for server: SavedServer) -> ServerConnection {
        if let c = connections[server.id] {
            c.server = server
            return c
        }
        let c = ServerConnection(server: server, app: self)
        connections[server.id] = c
        return c
    }
}
