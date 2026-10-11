import AppIntents
import Foundation

let CONTROL_CENTER_APP_GROUP = "group.com.matthewdovi.TeamTalk-NG"
let CONTROL_CENTER_SERVER_LIST_KEY = "ControlCenterServerList"
let CONTROL_CENTER_PENDING_SERVER_KEY = "ControlCenterPendingServer"
let CONTROL_CENTER_PENDING_SERVER_NOTIFICATION = "com.matthewdovi.TeamTalk-NG.control.pending-server"
let CONTROL_CENTER_CONNECT_URL_SCHEME = "teamtalkng"
let CONTROL_CENTER_CONNECT_URL_HOST = "connect"
let CONTROL_CENTER_CONNECT_SERVER_QUERY_ITEM = "server"

struct ControlCenterServerRecord: Codable, Hashable, Identifiable {
    let id: String
    let name: String
}

enum ControlCenterServerStore {
    static var defaults: UserDefaults {
        UserDefaults(suiteName: CONTROL_CENTER_APP_GROUP) ?? UserDefaults.standard
    }

    static func loadServers() -> [ControlCenterServerRecord] {
        guard let data = defaults.data(forKey: CONTROL_CENTER_SERVER_LIST_KEY),
              let servers = try? JSONDecoder().decode([ControlCenterServerRecord].self, from: data) else {
            return []
        }
        return servers
    }

    static func saveServers(_ servers: [ControlCenterServerRecord]) {
        guard let data = try? JSONEncoder().encode(servers) else {
            return
        }
        defaults.set(data, forKey: CONTROL_CENTER_SERVER_LIST_KEY)
    }

    static func savePendingServerName(_ serverName: String) {
        defaults.set(serverName, forKey: CONTROL_CENTER_PENDING_SERVER_KEY)
        defaults.synchronize()
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(CONTROL_CENTER_PENDING_SERVER_NOTIFICATION as CFString),
            nil,
            nil,
            true
        )
    }

    static func consumePendingServerName() -> String? {
        let serverName = defaults.string(forKey: CONTROL_CENTER_PENDING_SERVER_KEY)
        defaults.removeObject(forKey: CONTROL_CENTER_PENDING_SERVER_KEY)
        return serverName
    }
}

enum ControlCenterConnectURL {
    static func url(for serverName: String) -> URL {
        var components = URLComponents()
        components.scheme = CONTROL_CENTER_CONNECT_URL_SCHEME
        components.host = CONTROL_CENTER_CONNECT_URL_HOST
        components.queryItems = [
            URLQueryItem(name: CONTROL_CENTER_CONNECT_SERVER_QUERY_ITEM, value: serverName)
        ]
        return components.url ?? URL(string: "\(CONTROL_CENTER_CONNECT_URL_SCHEME)://\(CONTROL_CENTER_CONNECT_URL_HOST)")!
    }

    static func serverName(from url: URL) -> String? {
        guard url.scheme == CONTROL_CENTER_CONNECT_URL_SCHEME,
              url.host == CONTROL_CENTER_CONNECT_URL_HOST,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }

        return components.queryItems?
            .first(where: { $0.name == CONTROL_CENTER_CONNECT_SERVER_QUERY_ITEM })?
            .value
    }
}

@available(iOS 18.0, *)
struct ControlCenterServerEntity: AppEntity, Identifiable {
    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Server")
    static var defaultQuery = ControlCenterServerQuery()

    let id: String
    let name: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }

    static var placeholder: ControlCenterServerEntity {
        ControlCenterServerEntity(id: "", name: "Server")
    }
}

@available(iOS 18.0, *)
struct ControlCenterServerQuery: EntityQuery, EntityStringQuery {
    func entities(for identifiers: [ControlCenterServerEntity.ID]) async throws -> [ControlCenterServerEntity] {
        ControlCenterServerStore.loadServers()
            .filter { identifiers.contains($0.id) }
            .map { ControlCenterServerEntity(id: $0.id, name: $0.name) }
    }

    func entities(matching string: String) async throws -> [ControlCenterServerEntity] {
        let query = string.trimmingCharacters(in: .whitespacesAndNewlines).localizedLowercase
        return ControlCenterServerStore.loadServers()
            .filter { query.isEmpty || $0.name.localizedLowercase.contains(query) }
            .map { ControlCenterServerEntity(id: $0.id, name: $0.name) }
    }

    func suggestedEntities() async throws -> [ControlCenterServerEntity] {
        ControlCenterServerStore.loadServers()
            .map { ControlCenterServerEntity(id: $0.id, name: $0.name) }
    }
}

@available(iOS 18.0, *)
struct ConnectServerControlConfigurationIntent: ControlConfigurationIntent {
    static var title: LocalizedStringResource = "Connect to Server"

    @Parameter(title: "Server")
    var server: ControlCenterServerEntity?

    init() {}

    init(server: ControlCenterServerEntity?) {
        self.server = server
    }
}

@available(iOS 18.0, *)
struct ConnectServerControlIntent: OpenIntent {
    static var title: LocalizedStringResource = "Connect to Server"

    @Parameter(title: "Server")
    var target: ControlCenterServerEntity

    init() {
        target = .placeholder
    }

    init(server: ControlCenterServerEntity) {
        target = server
    }

    func perform() async throws -> some IntentResult {
        ControlCenterServerStore.savePendingServerName(target.name)
        return .result()
    }
}
