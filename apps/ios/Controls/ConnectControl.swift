import AppIntents
import SwiftUI
import WidgetKit

/// The Control Center control (iOS 18): "Connect to <server>", the server
/// chosen when it's added (the old app's).
@main
struct TeamTalkControls: WidgetBundle {
    var body: some Widget { ConnectServerControl() }
}

struct ConnectServerControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        AppIntentControlConfiguration(kind: "TeamTalkNG.connect-server", provider: Provider()) { server in
            ControlWidgetButton(action: ConnectServerIntent(server: server)) {
                Label("Connect to \(server.name)", systemImage: "server.rack")
            }
        }
        .displayName("Connect to Server")
        .description("Connects to a server in your server list.")
        .promptsForUserConfiguration()
    }

    struct Provider: AppIntentControlValueProvider {
        func previewValue(configuration: ChooseServer) -> ServerEntity {
            configuration.server ?? ServerEntity.all().first ?? ServerEntity(id: "", name: "a server")
        }
        func currentValue(configuration: ChooseServer) async throws -> ServerEntity {
            previewValue(configuration: configuration)
        }
    }
}

struct ChooseServer: ControlConfigurationIntent {
    static let title: LocalizedStringResource = "Choose a Server"
    @Parameter(title: "Server") var server: ServerEntity?
}
