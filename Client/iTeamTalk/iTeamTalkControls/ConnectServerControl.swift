import AppIntents
import SwiftUI
import WidgetKit

@available(iOS 18.0, *)
struct ConnectServerControlValue {
    let server: ControlCenterServerEntity

    var title: String {
        "Connect to \(server.name)"
    }
}

@available(iOS 18.0, *)
struct ConnectServerControl: ControlWidget {
    static let kind = "com.matthewdovi.TeamTalk-NG.control.connect-server"

    var body: some ControlWidgetConfiguration {
        AppIntentControlConfiguration(
            kind: Self.kind,
            provider: Provider()
        ) { value in
            ControlWidgetButton(action: ConnectServerControlIntent(server: value.server)) {
                Label(value.title, systemImage: "server.rack")
            }
        }
        .displayName("Connect to Server")
        .description("Connect to a server saved in your server list.")
        .promptsForUserConfiguration()
    }
}

@available(iOS 18.0, *)
extension ConnectServerControl {
    struct Provider: AppIntentControlValueProvider {
        func previewValue(configuration: ConnectServerControlConfigurationIntent) -> ConnectServerControlValue {
            ConnectServerControlValue(server: selectedServer(for: configuration))
        }

        func currentValue(configuration: ConnectServerControlConfigurationIntent) async throws -> ConnectServerControlValue {
            ConnectServerControlValue(server: selectedServer(for: configuration))
        }

        private func selectedServer(for configuration: ConnectServerControlConfigurationIntent) -> ControlCenterServerEntity {
            if let server = configuration.server {
                return server
            }

            if let first = ControlCenterServerStore.loadServers().first {
                return ControlCenterServerEntity(id: first.id, name: first.name)
            }

            return .placeholder
        }
    }
}
