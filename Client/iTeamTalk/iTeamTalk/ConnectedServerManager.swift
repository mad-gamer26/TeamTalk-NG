import UIKit

final class ConnectedServerManager {
    static let shared = ConnectedServerManager()

    private(set) var sessions = [MainTabBarController]()
    weak var activeSession: MainTabBarController?

    var hasSessions: Bool { sessions.isEmpty == false }
    var showsSessionTabs: Bool { sessions.count >= 2 }

    private init() {}

    func register(_ controller: MainTabBarController) {
        guard sessions.contains(where: { $0 === controller }) == false else { return }
        sessions.append(controller)
        activate(controller)
        notifyChanged()
    }

    /// Gives the audio session TeamTalk's settings again (after Apple's
    /// player in QuickLook took it over), keeping each microphone as it is.
    func restoreSoundDevices() {
        sessions.first?.restoreSoundDevices()
    }

    func remove(_ controller: MainTabBarController) {
        sessions.removeAll { $0 === controller }
        if activeSession === controller {
            activeSession = sessions.first
        }
        ttInst = activeSession?.teamTalkInstance
        notifyChanged()
    }

    func session(for server: Server) -> MainTabBarController? {
        sessions.first { $0.matches(server: server) }
    }

    func activate(_ controller: MainTabBarController) {
        guard sessions.contains(where: { $0 === controller }) else { return }
        activeSession = controller
        ttInst = controller.teamTalkInstance
        controller.refreshConnectedServerNavigation()
    }

    func show(_ controller: MainTabBarController, in navigationController: UINavigationController) {
        if navigationController.topViewController === controller {
            activate(controller)
            return
        }
        if let current = navigationController.topViewController as? MainTabBarController {
            current.prepareForSessionSwitch()
        }
        activate(controller)
        guard let root = navigationController.viewControllers.first else {
            navigationController.setViewControllers([controller], animated: false)
            return
        }
        navigationController.setViewControllers([root, controller], animated: false)
    }

    func adjacent(to controller: MainTabBarController, offset: Int) -> MainTabBarController? {
        guard sessions.count > 1,
              let index = sessions.firstIndex(where: { $0 === controller }) else { return nil }
        return sessions[(index + offset + sessions.count) % sessions.count]
    }

    func isConnectedServer(_ server: Server) -> Bool {
        session(for: server) != nil
    }

    func disconnectAll() {
        let connectedSessions = sessions
        connectedSessions.forEach { $0.closeConnectionResources() }
    }

    private func notifyChanged() {
        sessions.forEach { $0.refreshConnectedServerNavigation() }
        NotificationCenter.default.post(name: .connectedServerSessionsDidChange, object: nil)
    }
}

extension Notification.Name {
    static let connectedServerSessionsDidChange = Notification.Name("connectedServerSessionsDidChange")
}
