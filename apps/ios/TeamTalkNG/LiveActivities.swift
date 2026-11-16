import ActivityKit
import Foundation
import Observation
import WidgetKit

/// How long a Live Activity stays after disconnecting.
enum LiveAfterDisconnect: Int, CaseIterable, Identifiable {
    case endAtOnce = 0, oneMinute = 1, fiveMinutes = 5, fifteenMinutes = 15, untilRemoved = -1
    var id: Self { self }
    var label: String {
        switch self {
        case .endAtOnce: "Remove it at once"
        case .oneMinute: "Show Disconnected for a minute"
        case .fiveMinutes: "Show Disconnected for 5 minutes"
        case .fifteenMinutes: "Show Disconnected for 15 minutes"
        case .untilRemoved: "Show Disconnected until I remove it"
        }
    }
}

/// Settings → Live Activities, and the activities themselves: one for each
/// server you're logged in to (not the Monitor's, which has no sound),
/// updated as things change, ended (or left saying Disconnected) when you
/// disconnect. Also keeps Control Center's switches up to date.
@MainActor @Observable
final class LiveActivities {
    static let shared = LiveActivities()

    var enabled: Bool { didSet { save(); refreshAll() } }
    /// Every server, or only those in `chosen`.
    var allServers: Bool { didSet { save(); refreshAll() } }
    var chosen: Set<String> { didSet { save(); refreshAll() } }
    var layout: LiveLayout { didSet { save(); refreshAll() } }
    var afterDisconnect: LiveAfterDisconnect { didSet { save() } }

    /// The servers showing one now (for Settings).
    private(set) var showing: [String] = []

    private let defaults = UserDefaults.standard
    private var loading = true

    private init() {
        enabled = defaults.object(forKey: "live.enabled") as? Bool ?? true
        allServers = defaults.object(forKey: "live.allServers") as? Bool ?? true
        chosen = Set(defaults.stringArray(forKey: "live.servers") ?? [])
        layout = (defaults.data(forKey: "live.layout")).flatMap { try? JSONDecoder().decode(LiveLayout.self, from: $0) } ?? LiveLayout()
        afterDisconnect = LiveAfterDisconnect(rawValue: defaults.object(forKey: "live.afterDisconnect") as? Int ?? 0) ?? .endAtOnce
        loading = false
    }

    private func save() {
        guard !loading else { return }
        defaults.set(enabled, forKey: "live.enabled")
        defaults.set(allServers, forKey: "live.allServers")
        defaults.set(Array(chosen), forKey: "live.servers")
        defaults.set(try? JSONEncoder().encode(layout), forKey: "live.layout")
        defaults.set(afterDisconnect.rawValue, forKey: "live.afterDisconnect")
    }

    /// At launch: Live Activities left from before (the app was closed or
    /// crashed while connected) show connections that are gone.
    func endLeftovers() {
        for a in Activity<ServerActivityAttributes>.activities { end(a.attributes.serverId, nil, .immediate) }
    }

    func reset() {
        enabled = true; allServers = true; chosen = []; layout = LiveLayout(); afterDisconnect = .endAtOnce
    }

    /// Live Activities allowed for this app (Settings → TeamTalk NG).
    var allowedBySystem: Bool { ActivityAuthorizationInfo().areActivitiesEnabled }

    func wanted(for serverId: String) -> Bool {
        enabled && (allServers || chosen.contains(serverId))
    }

    // MARK: Updates

    /// Changes come in bursts (someone talking, a refresh): sent at most
    /// every half second for each server.
    private var pending: Set<String> = []

    func changed(_ c: ServerConnection) {
        guard c.hasAudio else { return }
        let id = c.server.id.uuidString
        guard pending.insert(id).inserted else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            pending.remove(id)
            apply(c)
            updateControls()
        }
    }

    func refreshAll() {
        guard let model = AppModel.shared else { return }
        for c in model.connections.values { changed(c) }
        // Servers no longer wanted: their activity ends.
        for a in Activity<ServerActivityAttributes>.activities where !wanted(for: a.attributes.serverId) {
            end(a.attributes.serverId, nil, .immediate)
        }
        updateControls()
    }

    private func activity(_ id: String) -> Activity<ServerActivityAttributes>? {
        Activity<ServerActivityAttributes>.activities.first { $0.attributes.serverId == id && $0.activityState == .active }
    }

    private func apply(_ c: ServerConnection) {
        let id = c.server.id.uuidString
        let existing = activity(id)
        switch c.state {
        case .loggedIn, .reconnecting:
            guard wanted(for: id) else {
                if existing != nil { end(id, nil, .immediate) }
                return
            }
            let content = ActivityContent(state: state(c), staleDate: nil)
            if let existing {
                if existing.content.state != content.state {
                    Task { @MainActor in
                        for a in Activity<ServerActivityAttributes>.activities where a.attributes.serverId == id && a.activityState == .active {
                            await a.update(content)
                        }
                    }
                }
            } else if c.state == .loggedIn, allowedBySystem {
                // Started only while logged in (iOS starts them from the app).
                _ = try? Activity.request(attributes: ServerActivityAttributes(serverId: id), content: content, pushType: nil)
                refreshShowing()
            }
        default:
            guard existing != nil else { return }
            var s = state(c)
            s.connection = "Disconnected"
            s.talking = []
            s.microphoneOn = false
            let policy: ActivityUIDismissalPolicy
            switch afterDisconnect {
            case .endAtOnce: policy = .immediate
            case .untilRemoved: policy = .default
            default: policy = .after(.now.addingTimeInterval(TimeInterval(afterDisconnect.rawValue * 60)))
            }
            end(id, ActivityContent(state: s, staleDate: nil), policy)
        }
    }

    /// Ends a server's activities (looked up in the task: they can't be sent to it).
    private func end(_ id: String, _ last: ActivityContent<ServerActivityAttributes.ContentState>?, _ policy: ActivityUIDismissalPolicy) {
        Task { @MainActor in
            for a in Activity<ServerActivityAttributes>.activities where a.attributes.serverId == id {
                await a.end(last, dismissalPolicy: policy)
            }
            self.refreshShowing()
        }
    }

    private func refreshShowing() {
        let names = Activity<ServerActivityAttributes>.activities.filter { $0.activityState == .active }.compactMap { a in
            AppModel.shared?.servers.first { $0.id.uuidString == a.attributes.serverId }?.title
        }
        showing = names.sorted()
    }

    /// What a connection's activity shows now.
    func state(_ c: ServerConnection) -> ServerActivityAttributes.ContentState {
        let snap = c.snapshot
        let mine = snap?.myChannelId ?? 0
        let channel = snap?.channels.first { $0.id == mine }
        let channelName = mine == 0 ? "" : (channel?.parentId == 0 ? "Root channel" : channel?.name ?? "")
        let here = (snap?.users ?? []).filter { $0.channelId == mine && mine != 0 }
        let me = snap?.myUserId
        let voiceActivation = AppModel.shared?.talkMode == .voiceActivation
        let connection: String
        switch c.state {
        case .loggedIn: connection = "Connected"
        case .reconnecting: connection = "Reconnecting"
        default: connection = "Disconnected"
        }
        let status: String
        if let u = c.me {
            let mode = u.status == .away ? "Away" : u.status == .question ? "Question" : "Available"
            status = u.statusMessage.isEmpty ? mode : "\(mode), \(u.statusMessage)"
        } else {
            status = "Available"
        }
        let lastChannel = c.lines.last { $0.privateWith == nil && $0.kind == .channelMessage }
        let lastPrivate = c.lines.last { $0.privateWith != nil && $0.kind == .privateMessage && $0.from != "Me" }
        return .init(
            serverName: snap?.server.name.nonEmpty ?? c.server.title,
            connection: connection,
            channel: channelName,
            peopleInChannel: here.count,
            talking: here.filter { $0.talking && $0.id != me }.map(\.displayName),
            microphoneOn: voiceActivation ? !c.muted : c.transmitting,
            voiceActivation: voiceActivation,
            mutedEveryone: snap?.mutedAll ?? false,
            status: status,
            lastMessage: lastChannel.map { LiveMessage(from: $0.from, text: $0.text) },
            lastPrivate: lastPrivate.map { LiveMessage(from: $0.from, text: $0.text) },
            unreadPrivate: c.unread.count,
            layout: layout)
    }

    // MARK: Control Center

    private var controls = ControlState.Values()

    func updateControls() {
        let model = AppModel.shared
        let c = model?.activeConnection
        var v = ControlState.Values()
        v.voiceActivation = model?.talkMode == .voiceActivation
        if let c {
            v.connected = true
            v.serverName = c.snapshot?.server.name.nonEmpty ?? c.server.title
            v.microphoneOn = v.voiceActivation ? !c.muted : c.transmitting
            v.mutedEveryone = c.snapshot?.mutedAll ?? false
        }
        guard v != controls else { return }
        controls = v
        ControlState.write(v)
        if #available(iOS 18.0, *) { ControlCenter.shared.reloadAllControls() }
    }
}
