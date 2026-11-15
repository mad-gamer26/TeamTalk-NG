import AppIntents
import Foundation

// "Connect to Server" for Siri and the Control Center control (the old
// app's): a saved server, by name, from the list the app shares in its App
// Group. Built into the app and the controls extension; it runs in the app.

struct ServerEntity: AppEntity, Identifiable {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Server"
    static let defaultQuery = ServerQuery()
    let id: String
    let name: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }

    static func all() -> [ServerEntity] {
        let group = Bundle.main.object(forInfoDictionaryKey: "TTNGAppGroup") as? String ?? ""
        let list = UserDefaults(suiteName: group)?.array(forKey: "shortcutServers") as? [[String: String]] ?? []
        return list.compactMap { d in d["id"].map { ServerEntity(id: $0, name: d["name"] ?? $0) } }
    }
}

struct ServerQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [ServerEntity] {
        ServerEntity.all().filter { identifiers.contains($0.id) }
    }
    func entities(matching string: String) async throws -> [ServerEntity] {
        ServerEntity.all().filter { $0.name.localizedCaseInsensitiveContains(string) }
    }
    func suggestedEntities() async throws -> [ServerEntity] { ServerEntity.all() }
}

struct ConnectServerIntent: OpenIntent {
    static let title: LocalizedStringResource = "Connect to Server"
    static let description = IntentDescription("Connects to a server in your server list.")
    @Parameter(title: "Server") var target: ServerEntity

    init() {}
    init(server: ServerEntity) { target = server }

    @MainActor
    func perform() async throws -> some IntentResult {
        #if TTNG_APP
        AppModel.shared?.openServer(id: target.id)
        #endif
        return .result()
    }
}
