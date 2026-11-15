import SwiftUI
import UIKit

/// The desktop's menu commands that have keyboard shortcuts.
enum DesktopCommand: Hashable {
    case record, speakClientStats
    case questionMode, hearMyself, pushToTalk, voiceActivation, speechEvents, soundEvents
    case userInfo, speakUserInfo, messages, op, volume, muteVoice, muteMedia
    case kickChannel, kickBanChannel, kickServer, kickBanServer
    case subscription(Subscription)
    case transmit(TransmitStream, all: Bool)
    case voiceUp, voiceDown, mediaUp, mediaDown, storeForMove, moveUsers, moveDialog, muteAll
    case join, leave, speakChannelInfo, speakChannelState, ttURL, channelBans, stream, pauseStream
    case accounts, serverBans, onlineUsers, broadcast, saveConfig
    case talk, tab(ServerView.Tab)
}

/// The desktop's keyboard shortcuts (mainwindow.ui), Ctrl as Command and
/// Alt as Option, for a hardware keyboard: UIKit key commands on the
/// window (not hidden buttons: those sat in the accessibility tree, around
/// the whole screen, the UI tests found). They act on the person or channel
/// VoiceOver is on, as the desktop's on the selected one.
struct DesktopShortcuts: View {
    let run: (DesktopCommand) -> Void

    typealias Key = (String, KeyEquivalent, EventModifiers, DesktopCommand)

    static let keys: [Key] = {
        var k: [Key] = [
            ("Record Conversations to Disk", "a", [.command, .option], .record),
            ("Speak Client Statistics", "t", .command, .speakClientStats),
            ("Hear Myself", "3", [.command, .shift], .hearMyself),
            ("Enable Push To Talk", "t", [.command, .shift], .pushToTalk),
            ("Enable Voice Activation", "a", [.command, .shift], .voiceActivation),
            ("Enable Text-To-Speech Events", "s", [.command, .option], .speechEvents),
            ("Enable Sound Events", "z", [.command, .option], .soundEvents),
            ("View User Information", "i", .command, .userInfo),
            ("Speak User Information", "g", .command, .speakUserInfo),
            ("Messages", "e", .command, .messages),
            ("Op", "o", .command, .op),
            ("Volume", "u", .command, .volume),
            ("Mute Voice", "m", [.command, .shift], .muteVoice),
            ("Mute Media File", "m", [.command, .option, .shift], .muteMedia),
            ("Kick From Channel", "k", .command, .kickChannel),
            ("Kick and Ban From Channel", "b", .command, .kickBanChannel),
            ("Kick From Server", "k", [.command, .option], .kickServer),
            ("Kick and Ban From Server", "b", [.command, .option], .kickBanServer),
            ("Increase Voice Volume", "y", .command, .voiceUp),
            ("Lower Voice Volume", "h", .command, .voiceDown),
            ("Increase Media File Volume", "y", [.command, .shift], .mediaUp),
            ("Lower Media File Volume", "h", [.command, .shift], .mediaDown),
            ("Store User(s) for Move", "x", [.command, .option], .storeForMove),
            ("Move User(s)", "v", [.command, .option], .moveUsers),
            ("Move Users Dialog", "m", [.command, .option], .moveDialog),
            ("Mute All", "m", .command, .muteAll),
            ("Join Channel", "j", .command, .join),
            ("Leave Channel", "l", .command, .leave),
            ("Speak Channel Info", "g", [.command, .option], .speakChannelInfo),
            ("Speak Channel State", "g", [.command, .shift], .speakChannelState),
            ("Generate tt:// URL to Clipboard", "r", [.command, .shift], .ttURL),
            ("Banned Users From Channel", "b", [.command, .option, .shift], .channelBans),
            ("Stream Media File to Channel", "s", .command, .stream),
            ("Pause/Resume Stream", "p", .command, .pauseStream),
            ("User Accounts", "l", [.command, .shift], .accounts),
            ("Banned Users", "b", [.command, .shift], .serverBans),
            ("Online Users", "u", [.command, .shift], .onlineUsers),
            ("Broadcast Message", "e", [.command, .shift], .broadcast),
            ("Save Configuration", "s", [.command, .shift], .saveConfig),
            // This app's own: talking, and its tabs (the desktop has neither).
            ("Talk or stop talking", "p", [.command, .shift], .talk),
            ("Channels", "1", .control, .tab(.channels)),
            ("Chat", "2", .control, .tab(.chat)),
            ("Files", "3", .control, .tab(.files)),
        ]
        // Subscriptions Ctrl+1–8, intercepts Ctrl+Shift+1–8 (the desktop's).
        let subs: [(Subscription, Character)] = [(.userMessages, "1"), (.channelMessages, "2"), (.broadcastMessages, "3"),
                                                 (.voice, "4"), (.video, "5"), (.desktop, "6"), (.mediaFile, "8")]
        for (s, c) in subs { k.append((ServerConnection.subscriptionMenuName(s), KeyEquivalent(c), .command, .subscription(s))) }
        let ints: [(Subscription, Character)] = [(.interceptUserMessages, "1"), (.interceptChannelMessages, "2"), (.interceptVoice, "4"),
                                                 (.interceptVideo, "5"), (.interceptDesktop, "6"), (.interceptMediaFile, "8")]
        for (s, c) in ints { k.append((ServerConnection.subscriptionMenuName(s), KeyEquivalent(c), [.command, .shift], .subscription(s))) }
        // Transmit control: Ctrl+Alt+T/Q/W/E/R, and with Shift for everyone.
        let tx: [(TransmitStream, Character, String)] = [(.channelMessages, "t", "Channel Text Messages"), (.voice, "q", "Voice Transmission"),
                                                         (.video, "w", "Video Transmission"), (.desktop, "e", "Desktop Transmission"),
                                                         (.mediaFile, "r", "Media File Transmission")]
        for (s, c, name) in tx {
            k.append(("Allow \(name)", KeyEquivalent(c), [.command, .option], .transmit(s, all: false)))
            k.append(("Allow All \(name)", KeyEquivalent(c), [.command, .option, .shift], .transmit(s, all: true)))
        }
        return k
    }()

    var body: some View {
        // Nothing on screen: the server screen's keys while it's open (a
        // responder of its own, so they work when nothing else has focus).
        KeyResponder()
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .onAppear { KeyCommands.handler = run }
            .onDisappear { KeyCommands.handler = nil }
    }
}

/// The shortcuts as UIKit key commands, offered by an invisible responder
/// on the server screen (SwiftUI's hosting controller ignores commands
/// added to it from outside).
@MainActor
enum KeyCommands {
    static var handler: ((DesktopCommand) -> Void)?

    private static func flags(_ m: EventModifiers) -> UIKeyModifierFlags {
        var f: UIKeyModifierFlags = []
        if m.contains(.command) { f.insert(.command) }
        if m.contains(.shift) { f.insert(.shift) }
        if m.contains(.option) { f.insert(.alternate) }
        if m.contains(.control) { f.insert(.control) }
        return f
    }

    private static func input(_ k: KeyEquivalent) -> String {
        switch k {
        case .return: "\r"
        case .delete: "\u{8}"
        default: String(k.character)
        }
    }

    static let all: [UIKeyCommand] = DesktopShortcuts.keys.enumerated().map { i, k in
        let c = UIKeyCommand(title: k.0, action: #selector(UIWindow.ttngDesktopShortcut(_:)),
                             input: input(k.1), modifierFlags: flags(k.2), propertyList: i)
        c.wantsPriorityOverSystemBehavior = true
        return c
    }

    static func run(_ c: UIKeyCommand) {
        guard let i = c.propertyList as? Int, DesktopShortcuts.keys.indices.contains(i) else { return }
        handler?(DesktopShortcuts.keys[i].3)
    }
}

/// An invisible view that holds the keyboard focus on the server screen
/// and offers the shortcuts as key commands. While a text field is being
/// typed in it has the focus (and its own keys); when typing ends, this
/// takes it back.
struct KeyResponder: UIViewRepresentable {
    final class View: UIView {
        override var canBecomeFirstResponder: Bool { true }
        // (The window offers them: see the UIWindow extension.)
        @objc func ttngDesktopShortcut(_ sender: UIKeyCommand) { KeyCommands.run(sender) }
        private var observers: [NSObjectProtocol] = []

        override func didMoveToWindow() {
            super.didMoveToWindow()
            isAccessibilityElement = false
            accessibilityElementsHidden = true
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            guard window != nil else { return }
            takeFocus()
            for name in [UITextField.textDidEndEditingNotification, UITextView.textDidEndEditingNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.takeFocus() }
                })
            }
        }

        /// Takes the focus, never from something being typed in.
        private func takeFocus() {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.window != nil, !(FirstResponder.current is UITextInput) else { return }
                self.becomeFirstResponder()
            }
        }
    }
    func makeUIView(context: Context) -> View { View() }
    func updateUIView(_ v: View, context: Context) {}
}

/// Whatever has the keyboard focus now (nil: nothing).
@MainActor
enum FirstResponder {
    fileprivate static weak var found: UIResponder?
    static var current: UIResponder? {
        found = nil
        UIApplication.shared.sendAction(#selector(UIResponder.ttngReportFirstResponder), to: nil, from: nil, for: nil)
        return found
    }
}

extension UIResponder {
    @objc fileprivate func ttngReportFirstResponder() {
        MainActor.assumeIsolated { FirstResponder.found = self }
    }
}

/// The window offers the shortcuts while a server screen is open: it's in
/// every responder chain, so they work while typing in a text field too.
extension UIWindow {
    override open var keyCommands: [UIKeyCommand]? {
        let mine = super.keyCommands ?? []
        return MainActor.assumeIsolated { KeyCommands.handler == nil ? mine : mine + KeyCommands.all }
    }

    @objc func ttngDesktopShortcut(_ sender: UIKeyCommand) {
        MainActor.assumeIsolated { KeyCommands.run(sender) }
    }
}
