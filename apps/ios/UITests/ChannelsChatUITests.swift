import XCTest

/// Channels (joining, leaving, passwords, hidden ones) and chat (channel,
/// private and broadcast messages, both ways).
final class ChannelsChatUITests: NGTestCase {
    func channel(_ name: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", name)).firstMatch
    }

    func whereIsAlice() -> String? { Host.user("alice")?["channel"] as? String }

    func testJoiningAndLeavingByTapping() {
        connect()
        Host.until("Alice in the root channel") { whereIsAlice() == "/" }
        channel("Lobby").tap()
        Host.until("Alice in Lobby") { whereIsAlice() == "/Lobby/" }
        // The desktop's default: tapping my own channel leaves it.
        channel("Lobby").tap()
        Host.until("Alice out of channels") { whereIsAlice() == "" }
    }

    func testAPasswordChannelAsksAndAsksAgainWhenWrong() {
        connect()
        channel("Secret").tap()
        let alert = app.alerts["Channel password"]
        waitFor(alert, "the password asked")
        let pw = alert.textFields.firstMatch
        pw.tap(); pw.typeText("wrong")
        alert.buttons["Join"].tap()
        waitFor(app.alerts.firstMatch, "asked again after a wrong one")
        let again = app.alerts.firstMatch.textFields.firstMatch
        again.tap(); again.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 8) + "sesame")
        app.alerts.firstMatch.buttons["Join"].tap()
        Host.until("Alice in Secret") { whereIsAlice() == "/Secret/" }
    }

    func testAHiddenChannelIsJoinedByItsPath() {
        connect()
        more("Join a channel by its path")
        // An alert's field: VoiceOver reads its placeholder (SwiftUI drops
        // a label set on a field in an alert).
        let path = app.alerts.firstMatch.textFields.element(boundBy: 0)
        waitFor(path, "the path asked")
        path.tap(); path.typeText("/Hidden/")
        button("Join").tap()
        // Only admins see hidden channels (Bob wouldn't know where she is).
        Host.until("Alice in Hidden") { (Host.user("alice", seenBy: "admin")?["channel"] as? String) == "/Hidden/" }
    }

    func testChannelMessagesBothWays() {
        connect()
        Host.until("Alice in the root channel") { whereIsAlice() == "/" }
        app.buttons["Chat"].tap()
        let field = app.textFields["Message the channel"]
        waitFor(field, "the chat")
        field.tap(); field.typeText("Hello from the app")
        button("Send").tap()
        Host.until("Bob receiving it") { Host.messages().contains { $0["text"] as? String == "Hello from the app" && $0["kind"] as? String == "channel" } }
        Host.call("/say", ["bot": "bob", "text": "Hello from Bob"])
        waitFor(any("Hello from Bob"), "Bob's message in the chat")
        // A message longer than TeamTalk's limit arrives whole (split and joined).
        let long = String(repeating: "Long message words. ", count: 40)
        field.tap(); field.typeText(long)
        button("Send").tap()
        Host.until("Bob receiving the long one in parts") {
            Host.messages().filter { $0["kind"] as? String == "channel" }.compactMap { $0["text"] as? String }.joined().count >= long.count - 5
        }
    }

    func testPrivateMessagesBothWaysAndThePopup() {
        connect()
        // Bob writes first: the desktop's message popup opens the conversation.
        Host.until("Bob seeing Alice") { Host.user("alice") != nil }
        Host.call("/pm", ["bot": "bob", "to": "alice", "text": "Psst, Alice"])
        waitFor(any("Psst, Alice"), "Bob's private message, in its conversation")
        let field = app.textFields["Message Bob"]
        waitFor(field, "the conversation with Bob open")
        field.tap(); field.typeText("Hi Bob, privately")
        button("Send").tap()
        Host.until("Bob receiving it privately") { Host.messages().contains { $0["text"] as? String == "Hi Bob, privately" && $0["kind"] as? String == "private" } }
    }

    func testABroadcastReachesTheChat() {
        connect()
        app.buttons["Chat"].tap()
        Host.call("/broadcast", ["text": "Server going down soon"])
        waitFor(any("Server going down soon"), "the broadcast in the chat")
    }

    func testBroadcastingAsAdmin() {
        connect("admin")
        more("Broadcast message")
        let f = app.textFields["Message to everyone"]
        waitFor(f, "the broadcast box")
        f.tap(); f.typeText("Hello everyone")
        button("Send").tap()
        Host.until("Bob getting the broadcast") { Host.messages().contains { $0["kind"] as? String == "broadcast" && $0["text"] as? String == "Hello everyone" } }
    }

    func testOthersComingAndGoingShowInTheTree() {
        connect()
        waitFor(any("Carol"), "Carol listed")
        Host.call("/join", ["bot": "carol", "path": "/Lobby/"])
        // Carol under Lobby now: the tree shows her (Lobby's count changes).
        Host.until("Carol in Lobby") { (Host.user("carol")?["channel"] as? String) == "/Lobby/" }
        Host.call("/logout", ["bot": "carol"])
        let carolRow = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Carol,'")).firstMatch
        Host.until("Carol gone from the tree", timeout: 15) { !carolRow.exists }
        Host.call("/login", ["bot": "carol"])
        waitFor(carolRow, "Carol back in the tree")
    }
}
