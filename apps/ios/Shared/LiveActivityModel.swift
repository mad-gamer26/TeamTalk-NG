import ActivityKit
import Foundation

// A Live Activity for each connected server (Lock Screen and Dynamic
// Island), shared by the app (which starts and updates it) and the
// controls extension (which draws it). The owner's layout travels in each
// update, so a change in Settings → Live Activities shows at once.

struct ServerActivityAttributes: ActivityAttributes {
    /// The saved server's ID (its buttons act on it).
    let serverId: String

    struct ContentState: Codable, Hashable {
        var serverName: String
        /// "Connected", "Reconnecting", "Disconnected".
        var connection: String
        var channel: String
        var peopleInChannel: Int
        var talking: [String]
        /// Push to talk: talking. Voice activation: unmuted.
        var microphoneOn: Bool
        var voiceActivation: Bool
        var mutedEveryone: Bool
        var status: String
        var lastMessage: LiveMessage?
        var lastPrivate: LiveMessage?
        var unreadPrivate: Int
        var layout: LiveLayout
    }
}

struct LiveMessage: Codable, Hashable {
    var from: String
    var text: String
}

/// What a Live Activity shows (every part can be turned off), in the
/// order of LiveItem.allCases.
enum LiveItem: String, Codable, CaseIterable, Identifiable {
    case server, connection, channel, people, talking, microphone, talkMode, muteEveryone, status, lastMessage, lastPrivate, unread
    var id: Self { self }
    var label: String {
        switch self {
        case .server: "Server name"
        case .connection: "Connection (reconnecting, disconnected)"
        case .channel: "Channel"
        case .people: "People in the channel"
        case .talking: "Who's talking"
        case .microphone: "My microphone"
        case .talkMode: "Talk mode"
        case .muteEveryone: "Everyone muted for me"
        case .status: "My status"
        case .lastMessage: "Last channel message"
        case .lastPrivate: "Last private message"
        case .unread: "Unread private messages"
        }
    }
}

/// The buttons a Live Activity can have (the owner picks them and their order).
enum LiveButton: String, Codable, CaseIterable, Identifiable {
    case microphone, muteEveryone, talkMode, disconnect
    var id: Self { self }
    var label: String {
        switch self {
        case .microphone: "Microphone on or off"
        case .muteEveryone: "Mute Everyone for Me"
        case .talkMode: "Switch talk mode"
        case .disconnect: "Disconnect"
        }
    }
}

/// One thing in a small space (the Dynamic Island's compact and minimal views).
enum LiveGlance: String, Codable, CaseIterable, Identifiable {
    case microphone, talking, people, channel, server, unread, nothing
    var id: Self { self }
    var label: String {
        switch self {
        case .microphone: "My microphone"
        case .talking: "Who's talking"
        case .people: "People in the channel"
        case .channel: "Channel"
        case .server: "Server name"
        case .unread: "Unread private messages"
        case .nothing: "Nothing"
        }
    }
}

enum LiveMessageText: String, Codable, CaseIterable, Identifiable {
    case full, senderOnly
    var id: Self { self }
    var label: String {
        switch self {
        case .full: "Who wrote it and what they wrote"
        case .senderOnly: "Only who wrote it"
        }
    }
}

enum LiveTalkingStyle: String, Codable, CaseIterable, Identifiable {
    case names, count
    var id: Self { self }
    var label: String {
        switch self {
        case .names: "Their names"
        case .count: "How many"
        }
    }
}

enum LiveButtonStyle: String, Codable, CaseIterable, Identifiable {
    case icons, iconsAndWords
    var id: Self { self }
    var label: String {
        switch self {
        case .icons: "Icons only (VoiceOver still says their names)"
        case .iconsAndWords: "Icons and words"
        }
    }
}

struct LiveLayout: Codable, Hashable {
    var shown: [LiveItem] = [.server, .connection, .channel, .people, .talking, .microphone, .muteEveryone, .lastMessage, .unread]
    var buttons: [LiveButton] = [.microphone, .muteEveryone, .disconnect]
    var messageText: LiveMessageText = .full
    var talkingStyle: LiveTalkingStyle = .names
    var compactLeading: LiveGlance = .microphone
    var compactTrailing: LiveGlance = .talking
    var minimal: LiveGlance = .microphone
    var buttonStyle: LiveButtonStyle = .icons

    init() {}
    /// Saved layouts from before a setting existed keep working.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = LiveLayout()
        shown = try c.decodeIfPresent([LiveItem].self, forKey: .shown) ?? d.shown
        buttons = try c.decodeIfPresent([LiveButton].self, forKey: .buttons) ?? d.buttons
        messageText = try c.decodeIfPresent(LiveMessageText.self, forKey: .messageText) ?? d.messageText
        talkingStyle = try c.decodeIfPresent(LiveTalkingStyle.self, forKey: .talkingStyle) ?? d.talkingStyle
        compactLeading = try c.decodeIfPresent(LiveGlance.self, forKey: .compactLeading) ?? d.compactLeading
        compactTrailing = try c.decodeIfPresent(LiveGlance.self, forKey: .compactTrailing) ?? d.compactTrailing
        minimal = try c.decodeIfPresent(LiveGlance.self, forKey: .minimal) ?? d.minimal
        buttonStyle = try c.decodeIfPresent(LiveButtonStyle.self, forKey: .buttonStyle) ?? d.buttonStyle
    }

    func shows(_ item: LiveItem) -> Bool { shown.contains(item) }
    /// At most four buttons fit.
    static let maxButtons = 4
}
